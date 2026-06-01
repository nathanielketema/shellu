const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const mem = std.mem;

const readline = @import("readline");

const cmdline = @import("cmd_line.zig");
const StdioContext = cmdline.StdioContext;
const CommandContext = cmdline.CommandContext;
const maybe = @import("stdx.zig").maybe;
const Shell = @import("Shell.zig");
const Job = Shell.Job;
const IdGenerator = Job.IdGenerator;

pub const Command = enum {
    echo,
    type,
    cd,
    pwd,
    history,
    declare,
    jobs,
    exit,

    pub fn parse(command: []const u8) ?Command {
        return std.meta.stringToEnum(Command, command);
    }
};

pub fn run(context: CommandContext) !void {
    maybe(context.input.args.len > 0);
    const args = context.input.args;
    const stdio = context.stdio;
    const shell = context.shell;
    const gpa = context.shell.gpa;
    switch (context.input.command.builtin) {
        .echo => try echo(args, stdio),
        .type => try @"type"(shell, args, stdio),
        .cd => try cd(shell, args, stdio),
        .pwd => try pwd(shell.cwd, stdio),
        .history => try history(args, stdio),
        .declare => try declare(gpa, &shell.records, args, stdio),
        .jobs => try jobs(gpa, &shell.jobs, &shell.job_id_generator, stdio),
        .exit => std.process.exit(0),
    }
}

pub fn echo(args: []const []const u8, stdio: StdioContext) !void {
    const stdout = stdio.stdout;
    var first: bool = true;
    for (args) |arg| {
        if (!first) try stdout.print(" ", .{});
        try stdout.print("{s}", .{arg});
        first = false;
    }
    try stdout.print("\n", .{});
}

pub fn @"type"(shell: *Shell, args: []const []const u8, stdio: StdioContext) !void {
    if (args.len == 0) return;
    const stdout = stdio.stdout;
    const stderr = stdio.stderr;

    for (args) |arg| bigLoop: {
        if (Command.parse(arg)) |cmd| {
            try stdout.print("{s} is a shell builtin\n", .{@tagName(cmd)});
            continue;
        }

        for (shell.path_dirs) |path_dir| {
            path_dir.dir.access(shell.io, arg, .{ .execute = true }) catch continue;
            try stdout.print("{s} is {s}/{s}\n", .{ arg, path_dir.path, arg });
            break :bigLoop;
        }

        try stderr.print("{s}: not found\n", .{arg});
    }
}

pub fn cd(shell: *Shell, args: []const []const u8, stdio: StdioContext) !void {
    const stderr = stdio.stderr;

    if (args.len > 1) {
        try stderr.print("Error: too many arguments\n", .{});
        return;
    }
    const directory = if (args.len == 0)
        shell.home_path
    else
        args[0];
    assert(directory.len > 0);
    assert(args.len <= 1);

    Io.Threaded.chdir(directory) catch {
        try stderr.print("cd: {s}: No such file or directory\n", .{directory});
        return;
    };
    const cwd = try std.process.currentPathAlloc(shell.io, shell.gpa);
    shell.gpa.free(shell.cwd);
    shell.cwd = cwd;
    assert(shell.cwd.len > 0);
}

pub fn pwd(cwd: [:0]const u8, stdio: StdioContext) !void {
    const stdout = stdio.stdout;
    const stderr = stdio.stderr;
    if (cwd.len == 0) {
        try stderr.print("Error: no current directory\n", .{});
        return;
    }
    try stdout.print("{s}\n", .{cwd});
}

pub fn history(args: []const []const u8, stdio: StdioContext) !void {
    const stdout = stdio.stdout;
    const stderr = stdio.stderr;
    const history_state: [*c]readline.HISTORY_STATE = readline.history_get_history_state();
    const history_count: usize = @intCast(history_state.*.length);

    if (args.len > 1) {
        try stderr.print("Error: too many arguments\n", .{});
        return;
    }

    var history_start: usize = 1;
    if (args.len == 1) {
        const limit_text = args[0];
        assert(limit_text.len > 0);

        const limit = std.fmt.parseInt(u8, limit_text, 10) catch |parse_error| {
            try stderr.print("{}\n", .{parse_error});
            return;
        };
        if (limit > history_count) {
            try stderr.print("Error: limit exceeds history count\n", .{});
            return;
        }
        history_start = history_count - limit + 1;
    }

    assert(history_start >= 1);
    assert(history_start <= history_count + 1);
    for (history_start..history_count + 1) |history_index| {
        const entry: [*c]readline.HIST_ENTRY =
            readline.history_get(@intCast(history_index)) orelse continue;
        const line: [*c]const u8 = entry.*.line orelse continue;
        try stdout.print("    {d} {s}\n", .{ history_index, mem.span(line) });
    }
}

pub fn declare(
    gpa: Allocator,
    records: *std.StringHashMap([]const u8),
    args: []const []const u8,
    stdio: StdioContext,
) !void {
    const stdout = stdio.stdout;
    const stderr = stdio.stderr;
    if (args.len == 0 or args.len > 2) {
        try stderr.print("Error: invalid arguments\n", .{});
        return;
    }

    if (mem.eql(u8, args[0], "-p")) {
        if (args.len != 2) {
            try stderr.print("Error: invalid arguments\n", .{});
            return;
        }

        const value = records.get(args[1]) orelse {
            try stderr.print("declare: {s}: not found\n", .{args[1]});
            return;
        };
        assert(value.len > 0);
        try stdout.print("declare -- {s}=\"{s}\"\n", .{ args[1], value });
        return;
    }

    if (args.len != 1) {
        try stderr.print("Error: invalid arguments\n", .{});
        return;
    }
    assert(args.len == 1);

    const record = mem.cut(u8, args[0], "=") orelse {
        try stderr.print("Error: invalid arguments\n", .{});
        return;
    };
    const key_source = record.@"0";
    if (key_source.len == 0 or
        std.ascii.isDigit(key_source[0]) or
        mem.containsAtLeastScalar(u8, key_source, 1, '-'))
    {
        try stderr.print(
            "declare: `{s}': not a valid identifier\n",
            .{args[0]},
        );
        return;
    }
    assert(key_source.len > 0);
    assert(!std.ascii.isDigit(key_source[0]));

    const value = try gpa.dupe(u8, record.@"1");
    errdefer gpa.free(value);

    if (records.getEntry(key_source)) |entry| {
        gpa.free(entry.value_ptr.*);
        entry.value_ptr.* = value;
        return;
    }

    const key = try gpa.dupe(u8, key_source);
    errdefer gpa.free(key);
    try records.put(key, value);
}

pub fn jobs(
    gpa: Allocator,
    jobs_table: *std.array_hash_map.Auto(u32, Job),
    id_genrator: *IdGenerator,
    stdio: StdioContext,
) !void {
    const count = jobs_table.values().len;
    var done_job_ids: std.ArrayList(u32) = .empty;
    defer done_job_ids.deinit(gpa);
    for (jobs_table.values(), 0..) |*job, i| {
        if (std.c.waitpid(job.PID, null, std.c.W.NOHANG) != 0) {
            job.status = .Done;
        }

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
        const command = if (job.status == .Done)
            mem.trimEnd(u8, job.command_string, "&")
        else
            job.command_string;

        try stdio.stdout.print("[{d}]{s: <2} {s: <24}{s}\n", .{
            job_id,
            marker,
            status,
            command,
        });

        if (job.status == .Done) {
            try done_job_ids.append(gpa, job.job_id);
        }
    }

    for (done_job_ids.items) |job_id| {
        try id_genrator.remove(gpa, job_id);
        if (jobs_table.get(job_id)) |job| {
            gpa.free(job.command_string);
        }
        _ = jobs_table.fetchOrderedRemove(job_id);
    }
}
