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

    // Check if command is in path
    for (shell.path_dirs) |path_dir| {
        path_dir.dir.access(shell.io, command, .{
            .execute = true,
        }) catch continue;
        break;
    } else {
        try stdio.stderr.print("{s}: command not found\n", .{command});
        return;
    }

    var argv: std.ArrayList([]const u8) = .empty;
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
    errdefer child.kill(shell.io);

    if (!input.background) {
        _ = try child.wait(shell.io);
        return;
    }

    const id = shell.job_id_generator.new();
    const pid = child.id.?;
    try argv.append(arena, "&");
    try shell.jobs.put(shell.gpa, id, .{
        .job_id = id,
        .PID = pid,
        .status = .Running,
        .command_string = try std.mem.join(shell.gpa, " ", argv.items),
    });
    try stdio.stdout.print("[{d}] {d}\n", .{ id, pid });
}
