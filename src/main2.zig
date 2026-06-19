const std = @import("std");
const assert = std.debug.assert;

const readline = @import("readline");

const cmdline = @import("cmdline.zig");
const Pipeline = cmdline.Pipeline;
const Shell = @import("shell2.zig").Shell;

pub fn main(init: std.process.Init) !void {
    var shell: Shell = .init(init.io, init.gpa, init.environ_map);
    defer shell.deinit();

    while (true) {
        const raw_input: [*c]u8 = readline.readline("$ ") orelse continue;
        defer std.c.free(raw_input);
        _ = readline.add_history(raw_input);

        // Empty input is ignored
        const input: [:0]const u8 = std.mem.span(raw_input);
        if (input.len == 0) continue;

        const pipeline = shell.parse(init.arena.allocator(), input) catch |err| {
            switch (err) {
                error.ParseFailed => return,
                else => return err,
            }
        };
        defer _ = init.arena.reset(.free_all);

        try shell.run(pipeline);
        //shell.reap_jobs();
        try shell.flush();
    }
}
