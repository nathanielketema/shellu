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
const Shell = @import("Shell.zig");
const Snapshot = @import("stdx.zig").Snapshot;
const snap = Snapshot.snap;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;
    const arena = init.arena.allocator();

    var stdout_buffer: [4096]u8 = undefined;
    var stderr_buffer: [4096]u8 = undefined;

    var shell: Shell = try .init(io, gpa, .from_environment(init.environ_map));
    defer shell.deinit();

    _ = readline.rl_bind_key('\t', readline.rl_complete);
    readline.using_history();
    while (true) {
        defer _ = init.arena.reset(.free_all); // reset after each command

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

        try run(.{
            .arena = arena,
            .shell = &shell,
            .stdio = .{
                .stdout = output.stdout(),
                .stderr = output.stderr(),
                .stdout_file = output.stdout_writer.file,
                .stderr_file = output.stderr_writer.file,
            },
            .input = parsed,
        });

        try output.flush();
    }
}

pub fn run(context: CommandContext) !void {
    switch (context.input.command) {
        .builtin => try builtins.run(context),
        .external => try external.run(context),
    }
}

test "snapshot testing" {
    const T = struct {
        fn check(raw_input: []const u8, want: Snapshot) !void {
            try check_many(&.{raw_input}, want);
        }

        fn check_many(raw_inputs: []const []const u8, want: Snapshot) !void {
            const io = testing.io;
            const gpa = testing.allocator;

            assert(raw_inputs.len > 0);

            var allocating: Io.Writer.Allocating = .init(gpa);
            defer allocating.deinit();

            var environ = try testing.environ.createMap(gpa);
            defer environ.deinit();

            var shell: Shell = try .init(io, gpa, .from_environment(&environ));
            defer shell.deinit();

            var arena: std.heap.ArenaAllocator = .init(gpa);
            defer arena.deinit();

            for (raw_inputs) |raw_input| {
                defer _ = arena.reset(.free_all);

                const parsed = try Input.parse(
                    arena.allocator(),
                    raw_input,
                    &shell.records,
                    shell.home_path,
                );
                try run(.{
                    .arena = arena.allocator(),
                    .shell = &shell,
                    .stdio = .{
                        .stdout = &allocating.writer,
                        .stderr = &allocating.writer,
                    },
                    .input = parsed,
                });
            }

            const got = allocating.written();
            try Snapshot.diff(&want, got);
        }
    };

    try T.check("echo Hello ..    World  !~", snap(@src(),
        \\Hello .. World !~
        \\
    ));

    try T.check("echo", snap(@src(),
        \\
        \\
    ));

    try T.check("type", snap(@src(),
        \\
    ));

    try T.check("type echo", snap(@src(),
        \\echo is a shell builtin
        \\
    ));

    try T.check("type foo", snap(@src(),
        \\foo: not found
        \\
    ));

    try T.check("type which", snap(@src(),
        \\which is /usr/bin/which
        \\
    ));

    try T.check("type zsh bash ls exit", snap(@src(),
        \\zsh is /bin/zsh
        \\bash is /bin/bash
        \\ls is /bin/ls
        \\exit is a shell builtin
        \\
    ));

    try T.check("declare -p", snap(@src(),
        \\Error: invalid arguments
        \\
    ));

    try T.check("declare =x", snap(@src(),
        \\declare: `=x': not a valid identifier
        \\
    ));

    try T.check("declare 1x=y", snap(@src(),
        \\declare: `1x=y': not a valid identifier
        \\
    ));

    try T.check("declare x=y extra", snap(@src(),
        \\Error: invalid arguments
        \\
    ));

    try T.check_many(&.{
        "declare x=old",
        "declare x=new",
        "declare -p x",
    }, snap(@src(),
        \\declare -- x="new"
        \\
    ));
}

test "redirection" {
    const T = struct {
        fn run_command(shell: *Shell, directory: Io.Dir, raw_input: []const u8) !void {
            const io = testing.io;
            const gpa = testing.allocator;

            assert(raw_input.len > 0);

            var arena: std.heap.ArenaAllocator = .init(gpa);
            defer arena.deinit();

            var stdout_buffer: [4096]u8 = undefined;
            var stderr_buffer: [4096]u8 = undefined;

            const parsed = try Input.parse(
                arena.allocator(),
                raw_input,
                &shell.records,
                shell.home_path,
            );
            var output = try Output.init(
                io,
                directory,
                parsed.redirects,
                &stdout_buffer,
                &stderr_buffer,
            );
            defer output.deinit(io);

            try run(.{
                .arena = arena.allocator(),
                .shell = shell,
                .stdio = .{
                    .stdout = output.stdout(),
                    .stderr = output.stderr(),
                    .stdout_file = output.stdout_writer.file,
                    .stderr_file = output.stderr_writer.file,
                },
                .input = parsed,
            });
            try output.flush();
        }

        fn expect_file(directory: Io.Dir, path: []const u8, want: []const u8) !void {
            const io = testing.io;
            const gpa = testing.allocator;

            assert(path.len > 0);

            const actual = try directory.readFileAlloc(io, path, gpa, .limited(4096));
            defer gpa.free(actual);
            try testing.expectEqualStrings(want, actual);
        }
    };

    const io = testing.io;
    const gpa = testing.allocator;

    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    var environ = try testing.environ.createMap(gpa);
    defer environ.deinit();

    var shell: Shell = try .init(io, gpa, .from_environment(&environ));
    defer shell.deinit();

    try T.run_command(&shell, tmp_dir.dir, "echo first > out.txt");
    try T.run_command(&shell, tmp_dir.dir, "echo second >> out.txt");
    try T.expect_file(tmp_dir.dir, "out.txt", "first\nsecond\n");

    try T.run_command(&shell, tmp_dir.dir, "printf external > external.txt");
    try T.expect_file(tmp_dir.dir, "external.txt", "external");

    try T.run_command(&shell, tmp_dir.dir, "ls missing 2> error.txt");
    const error_text = try tmp_dir.dir.readFileAlloc(io, "error.txt", gpa, .limited(4096));
    defer gpa.free(error_text);
    try testing.expect(std.mem.indexOf(u8, error_text, "missing") != null);
}
