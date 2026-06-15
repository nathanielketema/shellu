const std = @import("std");
const assert = std.debug.assert;

const readline = @import("readline");

const cmdline = @import("cmdline.zig");
const Pipeline = cmdline.Pipeline;
const shl = @import("shell2.zig");

pub fn main(init: std.process.Init) !void {
    var shell: shl.Shell = .init(init.io, init.gpa, init.environ_map);
    defer shell.deinit();

    while (true) {
        // Empty input is ignored
        const input: []const u8 = get_input() orelse continue;
        if (input.len == 0) continue;

        const pipeline: Pipeline = cmdline.parse(init.arena.allocator(), input);
        defer _ = init.arena.reset(.free_all);
        _ = pipeline;

        //shell.run(pipeline);
        //shell.reap_jobs();
        try shell.flush();
    }
}

pub fn get_input() ?[]const u8 {
    const input: [*c]u8 = readline.readline("$ ") orelse return null;
    defer std.c.free(input);
    assert(input != null);
    _ = readline.add_history(input);
    return std.mem.span(input);
}
