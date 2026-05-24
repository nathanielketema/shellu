const std = @import("std");
const Io = std.Io;
const ArrayList = std.ArrayList;
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const mem = std.mem;
const StringHashMap = std.StringHashMap;

const readline = @import("readline");

const Input = @import("Input.zig");

pub fn maybe(ok: bool) void {
    assert(ok or !ok);
}

pub const ShellOption = struct {
    writer: *Io.Writer,
    input: Input,
    arena: Allocator,
};

pub const ShellConfig = struct {
    path_env: []const u8,
    home_env: []const u8,

    pub fn from_environment(environment: *std.process.Environ.Map) ShellConfig {
        return .{
            .path_env = environment.get("PATH").?,
            .home_env = environment.get("HOME").?,
        };
    }
};

pub const BuiltinContext = struct {
    writer: *Io.Writer,
    input: Input,
    shell: *Shell,
    arena: Allocator,
};

pub const Shell = struct {
    path_dirs: []PathDir,
    home_path: []const u8,
    records: StringHashMap([]const u8),
    current_working_directory: [:0]const u8,
    io: Io,
    gpa: Allocator,

    pub const PathDir = struct {
        string: []const u8,
        dir: Io.Dir,
    };

    pub fn init(io: Io, gpa: Allocator, config: ShellConfig) !Shell {
        assert(config.home_env.len > 0);
        assert(config.path_env.len > 0);

        var path_dirs: ArrayList(PathDir) = .empty;
        var it = std.mem.tokenizeAny(u8, config.path_env, " :;");
        while (it.next()) |path| {
            const dir = Io.Dir.openDir(.cwd(), io, path, .{}) catch continue;
            try path_dirs.append(gpa, .{
                .string = path,
                .dir = dir,
            });
        }

        return .{
            .path_dirs = try path_dirs.toOwnedSlice(gpa),
            .home_path = config.home_env,
            .records = .init(gpa),
            .current_working_directory = try std.process.currentPathAlloc(io, gpa),
            .io = io,
            .gpa = gpa,
        };
    }

    pub fn deinit(shell: *Shell) void {
        for (shell.path_dirs) |path_dir| path_dir.dir.close(shell.io);
        shell.gpa.free(shell.path_dirs);
        shell.gpa.free(shell.current_working_directory);
        var keys = shell.records.keyIterator();
        while (keys.next()) |key| shell.gpa.free(key.*);
        var values = shell.records.valueIterator();
        while (values.next()) |value| shell.gpa.free(value.*);
        shell.records.deinit();
    }

    pub fn run_external(shell: *Shell, option: ShellOption) !void {
        const input = option.input;
        const writer = option.writer;

        const command = switch (input.command) {
            .external => |command| command,
            .builtin => unreachable,
        };
        assert(command.len > 0);

        for (shell.path_dirs) |path_dir| {
            path_dir.dir.access(shell.io, command, .{
                .execute = true,
            }) catch continue;

            var argv: ArrayList([]const u8) = .empty;
            defer assert(argv.items.len > 0);

            try argv.append(option.arena, command);
            for (input.args) |arg| {
                const expand_arg = if (mem.startsWith(u8, arg, "~"))
                    try mem.concat(option.arena, u8, &.{ shell.home_path, arg[1..] })
                else
                    arg;

                try argv.append(option.arena, expand_arg);
            }

            var child = try std.process.spawn(shell.io, .{ .argv = argv.items });
            _ = try child.wait(shell.io);
            return;
        }

        try writer.print("{s}: command not found\n", .{command});
    }

    pub fn run_builtin(shell: *Shell, option: ShellOption) !void {
        maybe(option.input.args.len == 0);

        const context: BuiltinContext = .{
            .writer = option.writer,
            .input = option.input,
            .shell = shell,
            .arena = option.arena,
        };

        const command = switch (context.input.command) {
            .builtin => |command| command,
            .external => unreachable,
        };
        switch (command) {
            .echo => try builtin.echo(context),
            .type => try builtin.type(context),
            .cd => try builtin.cd(context),
            .pwd => try builtin.pwd(context),
            .history => try builtin.history(context),
            .declare => try builtin.declare(context),
            .exit => std.process.exit(0),
        }
    }

    pub const builtin = struct {
        pub const Command = enum {
            echo,
            type,
            cd,
            pwd,
            history,
            declare,
            exit,

            pub fn parse(command: []const u8) ?Command {
                return std.meta.stringToEnum(Command, command);
            }
        };

        pub fn echo(context: BuiltinContext) !void {
            const writer = context.writer;

            var first: bool = true;
            for (context.input.args) |arg| {
                if (!first) try writer.print(" ", .{});
                try writer.print("{s}", .{arg});
                first = false;
            }
            try writer.print("\n", .{});
        }

        pub fn @"type"(context: BuiltinContext) !void {
            const input = context.input;
            const shell = context.shell;
            const writer = context.writer;
            if (input.args.len == 0) return;

            for (input.args) |arg| bigLoop: {
                if (builtin.Command.parse(arg)) |cmd| {
                    try writer.print("{s} is a shell builtin\n", .{@tagName(cmd)});
                    continue;
                }

                for (shell.path_dirs) |path_dir| {
                    path_dir.dir.access(shell.io, arg, .{ .execute = true }) catch continue;
                    try writer.print("{s} is {s}/{s}\n", .{ arg, path_dir.string, arg });
                    break :bigLoop;
                }

                try writer.print("{s}: not found\n", .{arg});
            }
        }

        pub fn cd(context: BuiltinContext) !void {
            const input = context.input;
            const shell = context.shell;
            const writer = context.writer;

            if (input.args.len > 1) {
                try writer.print("Error: too many arguments\n", .{});
                try writer.print("Usage: cd [path]\n", .{});
                return;
            }
            const arg = if (input.args.len == 0) shell.home_path else input.args[0];

            Io.Threaded.chdir(arg) catch {
                try writer.print("cd: {s}: No such file or directory\n", .{arg});
            };
            const cwd = try std.process.currentPathAlloc(shell.io, shell.gpa);
            shell.gpa.free(shell.current_working_directory);
            shell.current_working_directory = cwd;
        }

        pub fn pwd(context: BuiltinContext) !void {
            if (context.input.args.len > 0) {
                try context.writer.print("Error: too many arguments\n", .{});
                return;
            }
            try context.writer.print("{s}\n", .{context.shell.current_working_directory});
        }

        pub fn history(context: BuiltinContext) !void {
            const input = context.input;
            const writer = context.writer;

            const history_state: [*c]readline.HISTORY_STATE = readline.history_get_history_state();
            const history_count: usize = @intCast(history_state.*.length);

            if (input.args.len > 1) {
                try writer.print("Error: too many arguments provided\n", .{});
                try writer.print("Usage: history [limit]\n", .{});
                return;
            }

            var start: usize = 1;
            if (input.args.len == 1) {
                const arg = input.args[0];
                const limit = try std.fmt.parseInt(u8, arg, 10);
                if (limit > history_count) {
                    try writer.print("Error: limit exceeds history count\n", .{});
                    return;
                }
                start = history_count - limit + 1;
            }

            for (start..history_count + 1) |i| {
                const entry: [*c]readline.HIST_ENTRY =
                    readline.history_get(@intCast(i)) orelse continue;
                const line: [*c]const u8 = entry.*.line orelse continue;
                try writer.print("    {d} {s}\n", .{ i, mem.span(line) });
            }
        }

        pub fn declare(context: BuiltinContext) !void {
            const gpa = context.shell.gpa;
            const writer = context.writer;
            const args = context.input.args;
            var records = &context.shell.records;
            if (args.len == 0 or args.len > 2) return;

            if (!mem.eql(u8, args[0], "-p")) {
                const record = mem.cut(u8, args[0], "=") orelse return;
                const key = try gpa.dupe(u8, record.@"0");
                const value = try gpa.dupe(u8, record.@"1");
                if (std.ascii.isDigit(key[0]) or
                    mem.containsAtLeastScalar(u8, key, 1, '-'))
                {
                    try writer.print(
                        "declare: `{s}': not a valid identifier\n",
                        .{args[0]},
                    );
                    return;
                }
                try records.put(key, value);
                return;
            }

            if (records.contains(args[1])) {
                try writer.print("declare -- {s}=\"{s}\"\n", .{
                    args[1],
                    records.get(args[1]).?,
                });
            } else try writer.print("declare: {s}: not found\n", .{args[1]});
        }
    };
};
