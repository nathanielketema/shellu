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
const Shell = @import("shell.zig").Shell;
const Job = @import("shell.zig").Job;
const IdGenerator = Job.IdGenerator;

pub const Command = enum {
    cd,
    complete,
    declare,
    echo,
    exit,
    history,
    jobs,
    pwd,
    type,

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
        .cd => try cd(shell, args, stdio),
        .complete => try complete(shell, args, stdio),
        .declare => try declare(gpa, &shell.records, args, stdio),
        .echo => try echo(args, stdio),
        .exit => return error.Exit,
        .history => try history(context.arena, shell, args, stdio),
        .jobs => try jobs(gpa, &shell.jobs, &shell.id_generator, stdio),
        .pwd => try pwd(shell.cwd, stdio),
        .type => try @"type"(shell, args, stdio),
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

pub fn complete(shell: *Shell, args: []const []const u8, stdio: StdioContext) !void {
    const usage =
        \\Usage: complete -pC [path] command
    ;
    switch (args.len) {
        2 => {
            if (mem.eql(u8, args[0], "-p")) {
                if (shell.specification.get(args[1])) |spec| {
                    try stdio.stdout.print("complete -C '{s}' {s}\n", .{ spec.path, spec.cmd });
                } else try stdio.stdout.print("complete: {s}: no completion specification\n", .{
                    args[1],
                });
            } else if (mem.eql(u8, args[0], "-r")) {
                _ = shell.specification.remove(args[1]);
            } else try stdio.stderr.print("{s}\n", .{usage});
        },
        3 => {
            if (mem.eql(u8, args[0], "-C")) {
                const path = try shell.gpa.dupe(u8, args[1]);
                const cmd = try shell.gpa.dupe(u8, args[2]);
                try shell.specification.put(cmd, .{
                    .path = path,
                    .cmd = cmd,
                });
            } else try stdio.stderr.print("{s}\n", .{usage});
        },
        else => try stdio.stderr.print("{s}\n", .{usage}),
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

pub fn history(
    arena: Allocator,
    shell: *Shell,
    args: []const []const u8,
    stdio: StdioContext,
) !void {
    const stdout = stdio.stdout;
    const stderr = stdio.stderr;
    const history_state: [*c]readline.HISTORY_STATE = readline.history_get_history_state();
    const history_count: usize = @intCast(history_state.*.length);

    const usage =
        \\Usage: history [limit | flags file_name]
        \\
        \\flags:
        \\    -r    read history from a file 
        \\    -w    write history to a file
        \\    -a    append history to a file
    ;

    switch (args.len) {
        0 => { // history
            for (1..history_count + 1) |history_index| {
                const entry: [*c]readline.HIST_ENTRY =
                    readline.history_get(@intCast(history_index)) orelse continue;
                const line: [*c]const u8 = entry.*.line orelse continue;
                try stdout.print("    {d} {s}\n", .{ history_index, mem.span(line) });
            }
        },
        1 => { // history limit, where 1 <= limit <= history_count <= 255
            const limit_text = args[0];
            if (limit_text.len == 0) {
                try stderr.print("Error: limit must be greater than zero\n", .{});
                return;
            }
            const limit = std.fmt.parseInt(u8, limit_text, 10) catch |err| {
                return switch (err) {
                    error.Overflow => try stderr.print(
                        "Error: limit overflows\n",
                        .{},
                    ),
                    error.InvalidCharacter => try stderr.print(
                        "Error: invalid character used for limit\n",
                        .{},
                    ),
                };
            };
            if (limit > history_count) {
                try stderr.print("Error: limit exceeds history count\n", .{});
                return;
            }
            const history_start = history_count - limit + 1;
            assert(history_start >= 1);
            assert(history_start <= history_count + 1);
            for (history_start..history_count + 1) |history_index| {
                const entry: [*c]readline.HIST_ENTRY =
                    readline.history_get(@intCast(history_index)) orelse continue;
                const line: [*c]const u8 = entry.*.line orelse continue;
                try stdout.print("    {d} {s}\n", .{ history_index, mem.span(line) });
            }
        },
        2 => { // history flag file_name
            if (mem.eql(u8, args[0], "-r")) {
                const file_name = try arena.dupeSentinel(u8, args[1], 0);
                if (readline.read_history(file_name.ptr) != 0) {
                    try stderr.print(
                        "Error: failed to read history from file <{s}>\n",
                        .{file_name},
                    );
                    return;
                }
            } else if (mem.eql(u8, args[0], "-w")) {
                const file_name = try arena.dupeSentinel(u8, args[1], 0);
                if (readline.write_history(file_name.ptr) != 0) {
                    try stderr.print(
                        "Error: failed to write history to file <{s}>\n",
                        .{file_name},
                    );
                    return;
                }
            } else if (mem.eql(u8, args[0], "-a")) {
                const file_name = try arena.dupeSentinel(u8, args[1], 0);
                const curr_count: usize = @intCast(readline.history_get_history_state().*.length);
                const delta = curr_count - @min(curr_count, shell.history_offset);
                if (delta > 0) {
                    if (readline.append_history(@intCast(delta), file_name.ptr) != 0) {
                        try stderr.print(
                            "Error: failed to read history from file <{s}>\n",
                            .{file_name},
                        );
                        return;
                    }
                    shell.history_offset = curr_count;
                }
            } else try stderr.print("{s}\n", .{usage});
        },
        else => try stderr.print("{s}\n", .{usage}),
    }
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
        if (std.c.waitpid(job.pid, null, std.c.W.NOHANG) != 0) {
            job.status = .Done;
        }

        const job_id = job.id;
        const marker = if (i == count - 1) "+" else if (i == count - 2) "-" else "";
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
            try done_job_ids.append(gpa, job.id);
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

pub fn pwd(cwd: [:0]const u8, stdio: StdioContext) !void {
    const stdout = stdio.stdout;
    const stderr = stdio.stderr;
    if (cwd.len == 0) {
        try stderr.print("Error: no current directory\n", .{});
        return;
    }
    try stdout.print("{s}\n", .{cwd});
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
