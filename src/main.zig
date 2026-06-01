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

        { // Reap a job
            const count = shell.jobs.values().len;
            var done_job_ids: std.ArrayList(u32) = .empty;
            defer done_job_ids.deinit(gpa);
            for (shell.jobs.values(), 0..) |*job, i| {
                if (std.c.waitpid(job.PID, null, std.c.W.NOHANG) != 0) {
                    job.status = .Done;
                }
                if (job.status == .Running) continue;

                try done_job_ids.append(gpa, job.job_id);
                const job_id = job.job_id;
                const marker = mk: {
                    var marker_tmp: []const u8 = undefined;
                    if (i == count - 1) {
                        marker_tmp = "+";
                    } else if (i == count - 2) {
                        marker_tmp = "-";
                    } else marker_tmp = "";
                    break :mk marker_tmp;
                };
                const status = @tagName(job.status);
                const command = std.mem.trimEnd(u8, job.command_string, "&");

                try output.stdout().print("[{d}]{s: <2} {s: <24}{s}\n", .{
                    job_id,
                    marker,
                    status,
                    command,
                });
            }

            for (done_job_ids.items) |job_id| {
                if (shell.jobs.get(job_id)) |job| {
                    try shell.job_id_generator.remove(gpa, job_id);
                    gpa.free(job.command_string);
                }
                _ = shell.jobs.fetchOrderedRemove(job_id);
            }
        }

        try output.flush();
    }
}

pub fn run(context: CommandContext) !void {
    switch (context.input.command) {
        .builtin => try builtins.run(context),
        .external => try external.run(context),
    }
}
