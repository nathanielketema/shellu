const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

const cmdline = @import("cmd_line.zig");
const StdioContext = cmdline.StdioContext;
const CommandContext = cmdline.CommandContext;
const Shell = @import("Shell.zig");

pub fn run(context: CommandContext) !void {
    const arena = context.arena;
    const shell = context.shell;
    const input = context.input;
    const stdio = context.stdio;
    const command = input.command.external;
    assert(command.len > 0);

    for (shell.path_dirs) |path_dir| {
        path_dir.dir.access(shell.io, command, .{
            .execute = true,
        }) catch continue;

        var argv: std.ArrayList([]const u8) = try .initCapacity(
            arena,
            input.args.len + 1,
        );

        try argv.append(arena, command);
        for (input.args) |arg| {
            try argv.append(arena, arg);
        }
        assert(argv.items.len > 0);
        assert(argv.items.len == input.args.len + 1);

        var child = try std.process.spawn(shell.io, .{
            .argv = argv.items,
            .stdout = if (stdio.stdout_file) |file|
                .{ .file = file }
            else
                .inherit,
            .stderr = if (stdio.stderr_file) |file|
                .{ .file = file }
            else
                .inherit,
        });
        _ = try child.wait(shell.io);
        return;
    }

    try stdio.stderr.print("{s}: command not found\n", .{command});
}
