const std = @import("std");
const assert = std.debug.assert;

const readline = @import("readline");

const cmdline = @import("cmdline.zig");
const Pipeline = cmdline.Pipeline;
const Shell = @import("shell.zig").Shell;

pub fn main(init: std.process.Init) !void {
    var shell = try Shell.init(init.io, init.gpa, init.environ_map);
    defer shell.deinit();

    while (true) {
        const input_raw: [*c]u8 = readline.readline("$ ") orelse return;
        defer std.c.free(input_raw);
        _ = readline.add_history(input_raw);

        // Empty input is ignored
        const input: [:0]const u8 = std.mem.span(input_raw);
        if (input.len == 0) continue;

        const pipeline = shell.parse(init.arena.allocator(), input) catch |err| {
            switch (err) {
                error.ParseFailed => continue,
                else => return err,
            }
        };
        defer _ = init.arena.reset(.free_all);

        shell.run(pipeline) catch |err| {
            switch (err) {
                error.Reported => continue,
                error.Exit => return,
                else => |e| return e,
            }
        };
        try shell.reap_jobs();
    }
}
