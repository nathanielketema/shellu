const std = @import("std");
const assert = std.debug.assert;
const Io = std.Io;

const readline = @import("readline");

const Job = @import("shell.zig").Job;
const Shell = @import("shell.zig").Shell;
const CommandContext = Shell.CommandContext;

pub const Builtin = enum {
    cd,
    pwd,
    echo,
    jobs,
    type,
    declare,
    history,
    exit,

    pub fn parse(program: []const u8) ?Builtin {
        return std.meta.stringToEnum(Builtin, program);
    }
};

pub fn run(shell: *Shell, ctx: *CommandContext) !void {
    const builtin = Builtin.parse(ctx.command.program).?;
    switch (builtin) {
        .cd => try cd(shell, ctx),
        .pwd => try pwd(shell, ctx),
        .echo => try echo(ctx),
        .jobs => try jobs(shell, ctx),
        .type => try @"type"(shell, ctx),
        .declare => try declare(shell, ctx),
        .history => try history(shell, ctx),
        .exit => return errors.tag.Exit,
    }
}

pub const errors = struct {
    const tag = error{ Reported, Exit };

    pub fn add_too_many_arguments(
        writer: *Io.Writer,
        cmd: []const u8,
        want: usize,
        got: usize,
    ) !void {
        try emit(writer, "{s}: expected {d} arguments, got {d}.\n", .{ cmd, want, got });
    }

    pub fn add_history_usage(writer: *Io.Writer) !void {
        const usage =
            \\Usage: history [limit | flags file_name]
            \\
            \\flags:
            \\    -r    read history from a file 
            \\    -w    write history to a file
        ;
        try emit(writer, "{s}\n", .{usage});
    }

    pub fn add_history_write_failed(writer: *Io.Writer, file_name: []const u8) !void {
        try emit(writer, "history: failed to write to file, {s}.\n", .{file_name});
    }

    pub fn add_history_read_failed(writer: *Io.Writer, file_name: []const u8) !void {
        try emit(writer, "history: failed to read from file, {s}.\n", .{file_name});
    }

    pub fn add_history_limit_cannot_exceed_history_count(writer: *Io.Writer, limit: usize) !void {
        try emit(writer, "history: limit cannot exceed history count, got {d}.\n", .{limit});
    }

    pub fn add_history_limit_cannot_be_zero(writer: *Io.Writer) !void {
        try emit(writer, "history: limit cannot be zero.\n", .{});
    }

    pub fn add_history_limit_parse_error(writer: *Io.Writer, err_name: []const u8) !void {
        try emit(writer, "history: limit parse error, {s}.\n", .{err_name});
    }

    pub fn add_type_path_env_not_available(writer: *Io.Writer) !void {
        try emit(writer, "shellu: PATH env not defined.\n", .{});
    }

    pub fn add_declare_invalid_identifier(writer: *Io.Writer, identifier: []const u8) !void {
        try emit(writer, "declare: invalid identifier, got {s}.\n", .{identifier});
    }

    pub fn add_declare_variable_not_found(writer: *Io.Writer, variable: []const u8) !void {
        try emit(writer, "declare: <{s}> variable not found.\n", .{variable});
    }

    pub fn add_declare_bad_option(writer: *Io.Writer, bad_option: []const u8) !void {
        try emit(writer, "declare: bad option, got {s}.\n", .{bad_option});
    }

    pub fn add_cd_dir_does_not_exist(writer: *Io.Writer, dir_not_found: []const u8) !void {
        try emit(writer, "cd: <{s}> directory does not exist.\n", .{dir_not_found});
    }

    pub fn add_type_not_found(writer: *Io.Writer, type_not_found: []const u8) !void {
        try emit(writer, "type: <{s}> not found.\n", .{type_not_found});
    }

    pub fn emit(writer: *Io.Writer, comptime fmt: []const u8, args: anytype) !void {
        comptime assert(fmt[fmt.len - 1] == '\n');
        try writer.print(fmt, args);
    }
};

pub fn echo(ctx: *CommandContext) !void {
    var first: bool = true;
    for (ctx.command.args) |arg| {
        if (!first) try ctx.out.interface.print(" ", .{});
        try ctx.out.interface.print("{s}", .{arg});
        first = false;
    }
    try ctx.out.interface.print("\n", .{});
}

pub fn @"type"(shell: *Shell, ctx: *CommandContext) !void {
    if (ctx.command.args.len == 0) return;

    for (ctx.command.args) |arg| forLoop: {
        if (Builtin.parse(arg)) |builtin| {
            try ctx.out.interface.print("{s} is a builtin.\n", .{@tagName(builtin)});
            continue;
        }

        const env_path = shell.env.get("PATH") orelse {
            try errors.add_type_path_env_not_available(&ctx.err.interface);
            return errors.tag.Reported;
        };
        var it = std.mem.tokenizeScalar(u8, env_path, Io.Dir.path.delimiter_posix);
        while (it.next()) |path_dir| {
            Io.Dir.access(.cwd(), shell.io, arg, .{ .execute = true }) catch continue;
            try ctx.out.interface.print("{s} is {s}/{s}\n", .{ arg, path_dir, arg });
            break :forLoop;
        }

        try errors.add_type_not_found(&ctx.err.interface, arg);
        try ctx.flush();
    }
}

pub fn pwd(shell: *Shell, ctx: *CommandContext) !void {
    const args = ctx.command.args;
    if (args.len > 0) {
        try errors.add_too_many_arguments(&ctx.err.interface, ctx.command.program, 0, args.len);
        return errors.tag.Reported;
    }
    try ctx.out.interface.print("{s}\n", .{shell.cwd});
}

pub fn cd(shell: *Shell, ctx: *CommandContext) !void {
    const args = ctx.command.args;
    if (args.len > 1) {
        try errors.add_too_many_arguments(&ctx.err.interface, ctx.command.program, 1, args.len);
        return errors.tag.Reported;
    }

    const directory = if (args.len == 0) shell.path_home else args[0];
    assert(directory.len > 0);

    Io.Threaded.chdir(directory) catch {
        try errors.add_cd_dir_does_not_exist(&ctx.err.interface, directory);
        return errors.tag.Reported;
    };

    try shell.cwd_update();
}

pub fn declare(shell: *Shell, ctx: *CommandContext) !void {
    const args = ctx.command.args;
    switch (args.len) {
        0 => {
            var it = shell.variables.iterator();
            while (it.next()) |variable| {
                try ctx.out.interface.print(
                    "{s}={s}\n",
                    .{ variable.key_ptr.*, variable.value_ptr.* },
                );
            }
        },
        1 => {
            var name_tmp: []const u8 = undefined;
            var value_tmp: []const u8 = undefined;
            if (!std.mem.containsAtLeast(u8, args[0], 1, "=")) {
                name_tmp = args[0];
                value_tmp = "";
            } else {
                const cut = std.mem.cut(u8, args[0], "=").?;
                if (cut.@"0".len == 0 or
                    std.ascii.isDigit(cut.@"0"[0]) or
                    std.mem.containsAtLeastScalar(u8, cut.@"0", 1, '-'))
                {
                    try errors.add_declare_invalid_identifier(&ctx.err.interface, cut.@"0");
                    return errors.tag.Reported;
                }
                name_tmp = cut.@"0";
                value_tmp = cut.@"1";
            }

            const name = try shell.gpa.dupe(u8, name_tmp);
            const value = try shell.gpa.dupe(u8, value_tmp);
            try shell.variables_update(name, value);
        },
        2 => {
            const option = args[0];
            const name = args[1];
            if (std.mem.eql(u8, option, "-p")) {
                const value = shell.variables.get(name) orelse {
                    try errors.add_declare_variable_not_found(&ctx.err.interface, name);
                    return errors.tag.Reported;
                };
                try ctx.out.interface.print("declare: {s}='{s}'\n", .{ name, value });
            } else {
                try errors.add_declare_bad_option(&ctx.err.interface, option);
                return errors.tag.Reported;
            }
        },
        else => {
            try errors.add_too_many_arguments(&ctx.err.interface, ctx.command.program, 2, args.len);
            return errors.tag.Reported;
        },
    }
}

pub fn history(shell: *Shell, ctx: *CommandContext) !void {
    const args = ctx.command.args;
    const history_state = readline.history_get_history_state();
    const history_count: usize = @intCast(history_state.*.length);
    switch (args.len) {
        0 => for (1..history_count + 1) |history_index| {
            const entry = readline.history_get(@intCast(history_index)) orelse continue;
            const line = entry.*.line orelse continue;
            try ctx.out.interface.print("    {d} {s}\n", .{ history_index, std.mem.span(line) });
        },
        1 => { // history limit, where 1 <= limit <= history_count <= 255
            const limit_text = args[0];

            const limit = std.fmt.parseInt(u8, limit_text, 10) catch |err| {
                try errors.add_history_limit_parse_error(&ctx.err.interface, @errorName(err));
                return errors.tag.Reported;
            };

            if (limit == 0) {
                try errors.add_history_limit_cannot_be_zero(&ctx.err.interface);
                return errors.tag.Reported;
            }
            if (limit > history_count) {
                try errors.add_history_limit_cannot_exceed_history_count(
                    &ctx.err.interface,
                    limit_text.len,
                );
                return errors.tag.Reported;
            }

            const history_start = history_count - limit + 1;
            for (history_start..history_count + 1) |history_index| {
                const entry = readline.history_get(@intCast(history_index)) orelse continue;
                const line = entry.*.line orelse continue;
                try ctx.out.interface.print(
                    "    {d} {s}\n",
                    .{ history_index, std.mem.span(line) },
                );
            }
        },
        2 => {
            const arena = shell.arena.allocator();
            const option = args[0];
            const file_name = args[1];
            if (std.mem.eql(u8, option, "-r")) {
                const file_name_c = try arena.dupeSentinel(u8, file_name, 0);
                const result = readline.read_history(file_name_c.ptr);
                if (result != 0) {
                    try errors.add_history_read_failed(&ctx.err.interface, file_name);
                    return errors.tag.Reported;
                }
            } else if (std.mem.eql(u8, option, "-w")) {
                const file_name_c = try arena.dupeSentinel(u8, file_name, 0);
                const result = readline.write_history(file_name_c.ptr);
                if (result != 0) {
                    try errors.add_history_write_failed(&ctx.err.interface, file_name);
                    return errors.tag.Reported;
                }
            } else {
                try errors.add_history_usage(&ctx.err.interface);
                return errors.tag.Reported;
            }
        },
        else => {
            try errors.add_history_usage(&ctx.err.interface);
            return errors.tag.Reported;
        },
    }
}

pub fn jobs(shell: *Shell, ctx: *CommandContext) !void {
    const job_count = shell.jobs.values().len;
    var job_done_ids: std.ArrayList(Job.Id) = .empty;
    defer job_done_ids.deinit(shell.gpa);

    for (shell.jobs.values(), 0..) |*job, i| {
        if (std.c.waitpid(job.pid, null, std.c.W.NOHANG) != 0) {
            job.status = .Done;
        }

        const marker = if (i == job_count - 1) "+" else if (i == job_count - 2) "-" else "";
        const status = @tagName(job.status);
        const command = if (job.status == .Done)
            std.mem.trimEnd(u8, job.cmd_text, "&")
        else
            job.cmd_text;

        try ctx.out.interface.print("[{d}]{s: <2} {s: <24}{s}\n", .{
            @intFromEnum(job.id),
            marker,
            status,
            command,
        });

        if (job.status == .Done) {
            try job_done_ids.append(shell.gpa, job.id);
        }
    }

    for (job_done_ids.items) |job_id| {
        try shell.id_generator.delete(shell.gpa, job_id);
        if (shell.jobs.get(job_id)) |job| {
            shell.gpa.free(job.cmd_text);
        }
        _ = shell.jobs.fetchOrderedRemove(job_id);
    }
}
