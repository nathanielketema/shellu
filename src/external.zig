const std = @import("std");
const assert = std.debug.assert;
const Io = std.Io;

const Shell = @import("shell.zig").Shell;
const CommandContext = Shell.CommandContext;

pub fn run(shell: *Shell, ctx: *CommandContext, background: bool) !void {
    const arena = shell.arena.allocator();

    const env_path = shell.env.get("PATH") orelse {
        try ctx.out.interface.print("shellu: PATH env not defined.\n", .{});
        return error.RunFailed;
    };
    var it = std.mem.tokenizeScalar(u8, env_path, Io.Dir.path.delimiter_posix);
    while (it.next()) |path_dir| {
        Io.Dir.access(.cwd(), shell.io, path_dir, .{ .execute = true }) catch continue;
        break;
    } else {
        try ctx.err.interface.print("<{s}>: command not found.\n", .{ctx.command.program});
        return error.RunFailed;
    }

    // Join program name and commandline args
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.append(arena, ctx.command.program);
    for (ctx.command.args) |arg| try argv.append(arena, arg);
    assert(argv.items.len == ctx.command.args.len + 1);

    var child = std.process.spawn(shell.io, .{
        .argv = argv.items,
        .stdin = if (ctx.in_file) |file| .{ .file = file } else .inherit,
        .stdout = if (ctx.out_file) |file| .{ .file = file } else .inherit,
        .stderr = if (ctx.err_file) |file| .{ .file = file } else .inherit,
    }) catch {
        try ctx.err.interface.print("<{s}>: command not found.\n", .{ctx.command.program});
        return error.RunFailed;
    };

    if (!background) {
        _ = try child.wait(shell.io);
        return;
    }

    const id = shell.id_generator.create();
    const pid = child.id.?;
    try argv.append(arena, "&");
    try shell.jobs.put(arena, id, .{
        .id = id,
        .pid = pid,
        .status = .Running,
        .cmd_text = try std.mem.join(shell.gpa, " ", argv.items),
    });
    try ctx.out.interface.print("[{d}] {d}\n", .{ @intFromEnum(id), pid });
}
