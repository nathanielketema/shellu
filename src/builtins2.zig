const std = @import("std");
const assert = std.debug.assert;
const Io = std.Io;

const Shell = @import("shell2.zig").Shell;
const Command = @import("cmdline.zig").Pipeline.Command;

pub fn run(shell: *Shell, command: Command) !void {
    try echo(command.args, shell.writers.stdout);
}

pub fn echo(args: []const []const u8, stdout: *Io.Writer) !void {
    var first: bool = true;
    for (args) |arg| {
        if (!first) try stdout.print(" ", .{});
        try stdout.print("{s}", .{arg});
        first = false;
    }
    try stdout.print("\n", .{});
}
