const std = @import("std");
const Io = std.Io;
const assert = std.debug.assert;
const testing = std.testing;

const readline = @import("readline");

const builtins = @import("builtins.zig");
const cmdline = @import("cmd_line.zig");
const Input = cmdline.Input;
const Output = cmdline.Output;
const CommandContext = cmdline.CommandContext;
const external = @import("external.zig");
const Shell = @import("shell.zig").Shell;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;
    const arena = init.arena.allocator();

    var stdout_buffer: [4096]u8 = undefined;
    var stderr_buffer: [4096]u8 = undefined;

    var shell: Shell = try .init(io, gpa, .from_environment(init.environ_map), init.environ_map);
    defer shell.deinit();
    shell.activate();

    while (true) {
        defer _ = init.arena.reset(.free_all); // Reset after each command

        const raw_input_c_string: [*c]u8 = readline.readline("$ ") orelse return;
        defer std.c.free(raw_input_c_string);
        assert(raw_input_c_string != null);

        const raw_input: []u8 = std.mem.span(raw_input_c_string);
        if (raw_input.len == 0) continue; // Empty commands are ignored

        _ = readline.add_history(raw_input_c_string);

        const parsed = Input.parse(
            arena,
            raw_input,
            &shell.records,
            shell.home_path,
        ) catch |err| {
            std.log.err("failed to parse <{s}>: {}", .{ raw_input, err });
            continue;
        };

        var output = try Output.init(
            io,
            .cwd(),
            parsed.redirects,
            &stdout_buffer,
            &stderr_buffer,
        );
        defer output.deinit(io);

        // Ideal refactor:
        // var shell: Shell = .init();
        // defer shell.deinit();
        // while (true) {
        //     const command: Command = cmdline.parse(raw_input);
        //     shell.run(command);
        //     shell.reap_jobs();
        //     shell.flush();
        // }
        run(.{
            .arena = arena,
            .shell = &shell,
            .stdio = .{
                .stdout = output.stdout(),
                .stderr = output.stderr(),
                .stdout_file = output.stdout_writer.file,
                .stderr_file = output.stderr_writer.file,
            },
            .input = parsed,
        }) catch |err| switch (err) {
            error.Exit => break,
            else => return err,
        };

        try shell.reap_job(output.stdout());
        try output.flush();
    }
}

pub fn run(context: CommandContext) !void {
    switch (context.input.command) {
        .builtin => try builtins.run(context),
        .external => try external.run(context),
    }
}
