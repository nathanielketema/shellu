const std = @import("std");
const Io = std.Io;
const mem = std.mem;
const ArrayList = std.ArrayList;
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

const readline = @import("readline");

pub fn maybe(ok: bool) void {
    assert(ok or !ok);
}

pub const ShellErrors = error{
    EnvironmentVariableNotFound,
};

pub const BuiltinCommand = enum {
    echo,
    exit,
    type,
    pwd,
    cd,
    history,

    fn parse(command: []const u8) ?BuiltinCommand {
        return std.meta.stringToEnum(BuiltinCommand, command);
    }
};

const Input = struct {
    command: Command,
    args: []const []const u8,
    gpa: Allocator,

    const Command = struct {
        builtin: ?BuiltinCommand,
        string: []const u8,
    };

    pub fn parse(gpa: Allocator, raw_input: []u8) !Input {
        assert(raw_input.len > 0);

        var args: ArrayList([]const u8) = .empty;
        errdefer args.deinit(gpa);

        var it = mem.tokenizeAny(u8, raw_input, " ");
        const command_string = it.next().?;
        const command: Command = .{
            .builtin = BuiltinCommand.parse(command_string),
            .string = command_string,
        };

        while (it.next()) |arg| {
            try args.append(gpa, arg);
        }
        maybe(args.items.len == 0);

        return .{
            .command = command,
            .args = try args.toOwnedSlice(gpa),
            .gpa = gpa,
        };
    }

    pub fn deinit(input: *Input) void {
        input.gpa.free(input.args);
    }
};

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;
    const arena = init.arena.allocator();

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer: Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const stdout = &stdout_writer.interface;

    const home = init.environ_map.get("HOME") orelse {
        return ShellErrors.EnvironmentVariableNotFound;
    };
    const path = init.environ_map.get("PATH") orelse {
        return ShellErrors.EnvironmentVariableNotFound;
    };

    _ = readline.rl_bind_key('\t', readline.rl_complete);
    readline.using_history();
    while (true) {
        // max is set at around 40KB
        _ = init.arena.reset(.{ .retain_with_limit = 10 * 4096 });

        const raw_input_c: [*c]u8 = readline.readline("$ ") orelse continue;
        defer std.c.free(raw_input_c);
        const raw_input: []u8 = mem.span(raw_input_c);

        if (raw_input.len == 0) continue;
        _ = readline.add_history(raw_input_c);

        var input: Input = try .parse(gpa, raw_input);
        defer input.deinit();

        if (input.command.builtin) |builtin| {
            switch (builtin) {
                .echo => {
                    var first: bool = true;
                    for (input.args) |arg| {
                        if (!first) try stdout.print(" ", .{});
                        try stdout.print("{s}", .{arg});
                        first = false;
                    }
                    try stdout.print("\n", .{});
                },
                .type => {
                    if (input.args.len == 0) continue;
                    for (input.args) |arg| {
                        if (BuiltinCommand.parse(arg)) |cmd| {
                            try stdout.print("{s} is a shell builtin\n", .{@tagName(cmd)});
                            continue;
                        }

                        var path_it = std.mem.tokenizeAny(u8, path, " :;");
                        while (path_it.next()) |sub_path| {
                            const dir = Io.Dir.openDir(.cwd(), io, sub_path, .{}) catch continue;

                            if (dir.access(io, arg, .{ .execute = true })) |_| {
                                try stdout.print("{s} is {s}/{s}\n", .{
                                    arg,
                                    sub_path,
                                    arg,
                                });
                                break;
                            } else |_| continue;
                        } else try stdout.print("{s}: not found\n", .{arg});
                    }
                },
                .pwd => {
                    const current_path = try std.process.currentPathAlloc(io, arena);
                    try stdout.print("{s}\n", .{current_path});
                },
                .cd => {
                    if (input.args.len > 1) {
                        try stdout.print("Error: too many arguments provided\n", .{});
                        try stdout.print("Usage: cd [path]\n", .{});
                        try stdout.flush();
                        continue;
                    }

                    const arg = if (input.args.len == 0) home else input.args[0];
                    const dir_path = if (mem.startsWith(u8, arg, "~"))
                        try mem.concat(gpa, u8, &.{ home, arg[1..] })
                    else
                        arg;

                    Io.Threaded.chdir(dir_path) catch {
                        try stdout.print("cd: {s}: No such file or directory\n", .{dir_path});
                    };
                },
                .history => {
                    const history_state: [*c]readline.HISTORY_STATE = readline.history_get_history_state();
                    const history_count: usize = @intCast(history_state.*.length);

                    if (input.args.len > 1) {
                        try stdout.print("Error: too many arguments provided\n", .{});
                        try stdout.print("Usage: history [limit]\n", .{});
                        try stdout.flush();
                        continue;
                    }

                    var start: usize = 1;
                    if (input.args.len == 1) {
                        const arg = input.args[0];
                        const limit = try std.fmt.parseInt(u8, arg, 10);
                        if (limit > history_count) {
                            try stdout.print("Error: limit exceeds history count\n", .{});
                            try stdout.flush();
                            continue;
                        }
                        start = history_count - limit + 1;
                    }

                    for (start..history_count + 1) |i| {
                        const entry: [*c]readline.HIST_ENTRY = readline.history_get(@intCast(i)) orelse continue;
                        const line: [*c]const u8 = entry.*.line orelse continue;
                        try stdout.print("    {d} {s}\n", .{ i, mem.span(line) });
                    }
                },
                .exit => return,
            }
        } else {
            var path_it = std.mem.tokenizeAny(u8, path, " :;");
            while (path_it.next()) |sub_path| {
                const dir = Io.Dir.openDir(.cwd(), io, sub_path, .{}) catch continue;

                var argv: ArrayList([]const u8) = .empty;
                defer argv.deinit(gpa);

                try argv.append(gpa, input.command.string);
                for (input.args) |arg| {
                    const ready_arg = if (mem.startsWith(u8, arg, "~"))
                        try mem.concat(
                            gpa,
                            u8,
                            &.{ home, arg[1..] },
                        )
                    else
                        arg;

                    try argv.append(gpa, ready_arg);
                }

                assert(argv.items.len > 0);
                if (dir.access(io, input.command.string, .{ .execute = true })) |_| {
                    var child = try std.process.spawn(io, .{ .argv = argv.items });
                    _ = try child.wait(io);
                    break;
                } else |_| continue;
            } else try stdout.print("{s}: command not found\n", .{input.command.string});
        }

        try stdout.flush();
    }
}
