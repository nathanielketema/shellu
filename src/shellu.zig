const std = @import("std");
const readline = @import("readline");
const Io = std.Io;
const mem = std.mem;

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

pub fn main(init: std.process.Init) !void {
    const io = init.io;
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
        // max is set at 40KB
        _ = init.arena.reset(.{ .retain_with_limit = 10 * 4096 });
        const c_cmdline: [*c]u8 = readline.readline("$ ") orelse continue;
        defer std.c.free(c_cmdline);
        _ = readline.add_history(c_cmdline);

        const cmdline: []u8 = mem.span(c_cmdline);
        var cmdline_it = mem.tokenizeAny(u8, cmdline, " ");
        const command_string = cmdline_it.next() orelse continue;

        if (BuiltinCommand.parse(command_string)) |command| {
            switch (command) {
                .echo => {
                    var first: bool = true;
                    while (cmdline_it.next()) |arg| {
                        if (!first) try stdout.print(" ", .{});
                        try stdout.print("{s}", .{arg});
                        first = false;
                    }
                    try stdout.print("\n", .{});
                },
                .type => {
                    const arg_string = cmdline_it.next() orelse continue;
                    if (BuiltinCommand.parse(arg_string)) |arg| {
                        try stdout.print("{s} is a shell builtin\n", .{@tagName(arg)});
                    } else {
                        var path_it = std.mem.tokenizeAny(u8, path, " :;");
                        while (path_it.next()) |sub_path| {
                            const dir = Io.Dir.openDir(.cwd(), io, sub_path, .{}) catch continue;

                            if (dir.access(io, arg_string, .{ .execute = true })) |_| {
                                try stdout.print("{s} is {s}/{s}\n", .{
                                    arg_string,
                                    sub_path,
                                    arg_string,
                                });
                                break;
                            } else |_| continue;
                        } else try stdout.print("{s}: not found\n", .{arg_string});
                    }
                },
                .pwd => {
                    const current_path = try std.process.currentPathAlloc(io, arena);
                    try stdout.print("{s}\n", .{current_path});
                },
                .cd => {
                    const arg_string = cmdline_it.next() orelse continue;
                    const dir_path = if (mem.startsWith(u8, arg_string, "~"))
                        try mem.concat(arena, u8, &.{ home, arg_string[1..] })
                    else
                        arg_string;

                    Io.Threaded.chdir(dir_path) catch {
                        try stdout.print("cd: {s}: No such file or directory\n", .{dir_path});
                    };
                },
                .history => {
                    const history_state: [*c]readline.HISTORY_STATE = readline.history_get_history_state();
                    const history_count: usize = @intCast(history_state.*.length);

                    if (cmdline_it.next()) |arg| {
                        const limit = try std.fmt.parseInt(u8, arg, 10);
                        if (limit > history_count) @panic("don't do that");
                        const start = history_count - limit + 1;
                        for (start..history_count + 1) |i| {
                            const entry: [*c]readline.HIST_ENTRY = readline.history_get(@intCast(i)) orelse continue;
                            const line: [*c]const u8 = entry.*.line orelse continue;
                            try stdout.print("    {d} {s}\n", .{ i, mem.span(line) });
                        }
                    } else {
                        for (1..history_count + 1) |i| {
                            const entry: [*c]readline.HIST_ENTRY = readline.history_get(@intCast(i)) orelse continue;
                            const line: [*c]const u8 = entry.*.line orelse continue;
                            try stdout.print("    {d} {s}\n", .{ i, mem.span(line) });
                        }
                    }
                },
                .exit => return,
            }
        } else {
            var path_it = std.mem.tokenizeAny(u8, path, " :;");
            while (path_it.next()) |sub_path| {
                const dir = Io.Dir.openDir(.cwd(), io, sub_path, .{}) catch continue;

                if (dir.access(io, command_string, .{ .execute = true })) |_| {
                    var argv: std.ArrayList([]const u8) = .empty;
                    cmdline_it.reset();
                    while (cmdline_it.next()) |arg| {
                        if (mem.startsWith(u8, arg, "~")) {
                            try argv.append(
                                arena,
                                try mem.concat(arena, u8, &.{ home, arg[1..] }),
                            );
                        } else try argv.append(arena, arg);
                    }

                    var child = try std.process.spawn(io, .{ .argv = argv.items });
                    _ = try child.wait(io);
                    break;
                } else |_| continue;
            } else try stdout.print("{s}: command not found\n", .{command_string});
        }

        try stdout.flush();
    }
}
