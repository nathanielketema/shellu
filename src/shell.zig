const std = @import("std");
const Io = std.Io;
const ArrayList = std.ArrayList;
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const mem = std.mem;

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
            .current_working_directory = try std.process.currentPathAlloc(io, gpa),
            .io = io,
            .gpa = gpa,
        };
    }

    pub fn deinit(shell: *Shell) void {
        for (shell.path_dirs) |path_dir| path_dir.dir.close(shell.io);
        shell.gpa.free(shell.path_dirs);
        shell.gpa.free(shell.current_working_directory);
    }

    pub fn run_external(shell: *Shell, option: ShellOption) !void {
        const input = option.input;
        const writer = option.writer;

        assert(input.command.builtin == null);
        assert(input.command.string.len > 0);

        for (shell.path_dirs) |path_dir| {
            path_dir.dir.access(shell.io, input.command.string, .{
                .execute = true,
            }) catch continue;

            var argv: ArrayList([]const u8) = .empty;
            defer assert(argv.items.len > 0);

            try argv.append(option.arena, input.command.string);
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

        try writer.print("{s}: command not found\n", .{input.command.string});
    }

    pub fn run_builtin(shell: *Shell, option: ShellOption) !void {
        assert(option.input.command.builtin != null);
        maybe(option.input.args.len == 0);

        const builtin_context: BuiltinContext = .{
            .writer = option.writer,
            .input = option.input,
            .shell = shell,
            .arena = option.arena,
        };

        const command = builtin_context.input.command.builtin.?;
        switch (command) {
            .echo => try Builtin.echo(builtin_context),
            .type => try Builtin.type(builtin_context),
            .cd => try Builtin.cd(builtin_context),
            .pwd => try Builtin.pwd(builtin_context),
            .history => try Builtin.history(builtin_context),
            .exit => std.process.exit(0),
        }
    }

    pub const Builtin = struct {
        pub const Command = enum {
            echo,
            type,
            cd,
            pwd,
            history,
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
                if (Builtin.Command.parse(arg)) |builtin| {
                    try writer.print("{s} is a shell builtin\n", .{@tagName(builtin)});
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
            const arena = context.arena;

            if (input.args.len > 1) {
                try writer.print("Error: too many arguments\n", .{});
                try writer.print("Usage: cd [path]\n", .{});
                return;
            }

            const arg = if (input.args.len == 0) shell.home_path else input.args[0];
            const dir_path = if (mem.startsWith(u8, arg, "~"))
                try mem.concat(arena, u8, &.{ shell.home_path, arg[1..] })
            else
                arg;

            Io.Threaded.chdir(dir_path) catch {
                try writer.print("cd: {s}: No such file or directory\n", .{dir_path});
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
    };
};
