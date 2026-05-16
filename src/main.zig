const std = @import("std");
const Io = std.Io;
const ArrayList = std.ArrayList;
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const mem = std.mem;

const readline = @import("readline");

const Input = @import("Input.zig");
const Shell = @import("shell.zig").Shell;
const Snapshot = @import("Snapshot.zig");
const snap = Snapshot.snap;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer: Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const stdout = &stdout_writer.interface;

    var shell: Shell = try .init(io, gpa, .from_environment(init.environ_map));
    defer shell.deinit();

    _ = readline.rl_bind_key('\t', readline.rl_complete);
    readline.using_history();
    while (true) {
        // Input using readline
        const raw_input_c: [*c]u8 = readline.readline("$ ") orelse return;
        defer std.c.free(raw_input_c);
        assert(raw_input_c != null);
        const raw_input: []u8 = mem.span(raw_input_c);
        if (raw_input.len == 0) continue; // Empty commands are ignored
        _ = readline.add_history(raw_input_c);

        var input: Input = try .parse(gpa, raw_input);
        defer input.deinit();

        if (input.command.builtin) |_| {
            try shell.run_builtin(stdout, input);
        } else try shell.run_external(stdout, input);

        try stdout.flush();
    }
}
