const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Environ = std.process.Environ;
const StringHashMap = std.StringHashMap;
const ArrayList = std.ArrayList;

const readline = @import("readline");
const builtins = @import("builtins.zig");
const Builtin = builtins.Builtin;
const cmdline = @import("cmdline.zig");
const Parser = cmdline.Parser;
const Pipeline = cmdline.Pipeline;
const Command = cmdline.Pipeline.Command;
const external = @import("external.zig");

pub const Errors = struct {
    count: usize = 0,
};

pub const Job = struct {
    id: Id,
    pid: i32,
    status: Status,
    cmd_text: []const u8,

    pub const Status = enum { Running, Done };

    pub const Id = enum(u32) {
        first = 0,
        _,

        pub const Generator = struct {
            last: Id = .first,
            free: std.PriorityDequeue(Id, void, struct {
                fn less_than(_: void, a: Id, b: Id) std.math.Order {
                    return std.math.order(@intFromEnum(a), @intFromEnum(b));
                }
            }.less_than) = .empty,

            pub fn create(g: *Generator) Id {
                return g.free.popMin() orelse blk: {
                    g.last = @enumFromInt(@intFromEnum(g.last) + 1);
                    break :blk g.last;
                };
            }

            pub fn delete(g: *Generator, gpa: Allocator, id: Id) !void {
                try g.free.push(gpa, id);
            }

            pub fn deinit(g: *Generator, gpa: Allocator) void {
                g.free.deinit(gpa);
            }
        };
    };
};

var g_env: ?*Environ.Map = null;
var g_io: ?Io = null;

pub const Shell = struct {
    io: Io,
    gpa: Allocator,
    arena: std.heap.ArenaAllocator,
    cwd: [:0]const u8,
    env: *Environ.Map,
    variables: StringHashMap([]const u8),
    path_home: []const u8,
    jobs: std.array_hash_map.Auto(Job.Id, Job),
    id_generator: Job.Id.Generator,
    errors: ArrayList(Errors),
    history_file: []const u8,
    history_offset: usize,

    pub fn init(io: Io, gpa: Allocator, env: *Environ.Map) !Shell {
        var arena: std.heap.ArenaAllocator = .init(gpa);
        errdefer arena.deinit();

        const home_path = env.get("HOME") orelse "/";
        const history_file = env.get("HISTFILE") orelse try Io.Dir.path.join(gpa, &.{
            home_path,
            ".shellu_history",
        });
        const history_offset = try read_history(gpa, history_file);

        readline_completion(io, env);

        const cwd = try std.process.currentPathAlloc(io, gpa);
        errdefer gpa.free(cwd);
        assert(cwd.len > 0);

        return .{
            .io = io,
            .gpa = gpa,
            .arena = arena,
            .cwd = cwd,
            .env = env,
            .jobs = .empty,
            .id_generator = .{},
            .errors = .empty,
            .variables = .init(gpa),
            .path_home = home_path,
            .history_file = history_file,
            .history_offset = history_offset,
        };
    }

    pub fn deinit(shell: *Shell) void {
        shell.append_history() catch {};
        {
            var key_it = shell.variables.keyIterator();
            while (key_it.next()) |key| shell.gpa.free(key.*);
            var val_it = shell.variables.valueIterator();
            while (val_it.next()) |val| shell.gpa.free(val.*);
            shell.variables.deinit();
        }
        shell.gpa.free(shell.cwd);
        shell.gpa.free(shell.history_file);
        shell.arena.deinit();
    }

    pub fn readline_completion(io: Io, env: *Environ.Map) void {
        g_io = io;
        g_env = env;
        readline.rl_attempted_completion_function = attempted_completion_function;
        _ = readline.rl_bind_key('\t', readline.rl_complete);
        readline.using_history();
    }

    fn attempted_completion_function(
        text: [*c]const u8,
        start: c_int,
        _: c_int,
    ) callconv(.c) [*c][*c]u8 {
        if (start == 0) {
            return readline.rl_completion_matches(text, completion_matches);
        }
        return readline.rl_completion_matches(text, readline.rl_filename_completion_function);
    }

    fn completion_matches(input: [*c]const u8, index: c_int) callconv(.c) [*c]u8 {
        const input_slice = std.mem.span(input);
        var curr_index: c_int = 0;

        for (std.enums.values(builtins.Builtin)) |cmd| {
            if (std.mem.startsWith(u8, @tagName(cmd), input_slice)) {
                if (index == curr_index) {
                    return readline.strdup(@tagName(cmd));
                }
                curr_index += 1;
            }
        }

        if (path_completion_match(input_slice, index, &curr_index)) |match| {
            return match;
        }

        return null;
    }

    fn path_completion_match(prefix: []const u8, index: c_int, curr_index: *c_int) ?[*c]u8 {
        const io = g_io orelse return null;
        const env = g_env orelse return null;
        const path_value = env.get("PATH") orelse return null;

        var dir_it = std.mem.tokenizeScalar(u8, path_value, ':');
        while (dir_it.next()) |dir_path| {
            var dir = Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch continue;
            defer dir.close(io);

            var entry_it = dir.iterate();
            while (entry_it.next(io) catch null) |entry| {
                if (entry.kind != .file and entry.kind != .sym_link) continue;
                if (!std.mem.startsWith(u8, entry.name, prefix)) continue;

                const stat = dir.statFile(io, entry.name, .{}) catch continue;
                if (stat.permissions.toMode() & 0o111 == 0) continue;

                if (index == curr_index.*) {
                    var name_buf: [256]u8 = undefined;
                    const name_z = std.fmt.bufPrintZ(
                        &name_buf,
                        "{s}",
                        .{entry.name},
                    ) catch continue;
                    return readline.strdup(name_z);
                }
                curr_index.* += 1;
            }
        }

        return null;
    }

    pub fn append_history(shell: *Shell) !void {
        const history_file_c = try shell.gpa.dupeSentinel(u8, shell.history_file, 0);
        defer shell.gpa.free(history_file_c);

        const curr_offset: usize = @intCast(readline.history_get_history_state().*.length);
        const diff = curr_offset - @min(curr_offset, shell.history_offset);
        if (diff > 0) {
            _ = readline.append_history(@intCast(diff), history_file_c.ptr);
            shell.history_offset = curr_offset;
        }
    }

    fn read_history(gpa: Allocator, history_file: []const u8) !usize {
        const history_file_c = try gpa.dupeSentinel(u8, history_file, 0);
        defer gpa.free(history_file_c);

        _ = readline.read_history(history_file_c.ptr);
        return @intCast(readline.history_get_history_state().*.length);
    }

    pub fn cwd_update(shell: *Shell) !void {
        const cwd = try std.process.currentPathAlloc(shell.io, shell.gpa);
        assert(cwd.len > 0);

        shell.gpa.free(shell.cwd);
        shell.cwd = cwd;
    }

    pub fn variables_update(shell: *Shell, name: []const u8, value: []const u8) !void {
        const result = try shell.variables.getOrPut(name);
        if (result.found_existing) shell.gpa.free(result.value_ptr.*);
        result.value_ptr.* = value;
    }

    pub fn parse(shell: *Shell, arena: Allocator, input: [:0]const u8) !Pipeline {
        var parser: Parser = try .init(arena, input, shell.variables, shell.path_home);
        return parser.parse();
    }

    pub const CommandContext = struct {
        command: Command,
        in: ?Io.File.Reader,
        out: Io.File.Writer,
        err: Io.File.Writer,

        in_buffer: [4096]u8 = undefined,
        out_buffer: [4096]u8 = undefined,
        err_buffer: [4096]u8 = undefined,

        in_file: ?Io.File,
        out_file: ?Io.File,
        err_file: ?Io.File,

        pub fn init(command: Command) CommandContext {
            return .{
                .command = command,
                .in = null,
                .out = undefined,
                .err = undefined,
                .in_file = null,
                .out_file = null,
                .err_file = null,
            };
        }

        pub fn flush(ctx: *CommandContext) !void {
            try ctx.out.interface.flush();
            try ctx.err.interface.flush();
        }

        pub fn close(ctx: *CommandContext, io: Io) void {
            if (ctx.in_file) |f| f.close(io);
            if (ctx.out_file) |f| f.close(io);
            if (ctx.err_file) |f| f.close(io);
        }
    };

    pub const Pipe = struct {
        read: Io.File,
        write: Io.File,
    };

    pub fn run(shell: *Shell, pipeline: Pipeline) !void {
        var pipes: std.ArrayList(Pipe) = .empty;

        const cmds_count = pipeline.commands.len;
        for (0..cmds_count - 1) |_| {
            var fds: [2]std.os.linux.fd_t = undefined;
            const rc = std.c.pipe(&fds);
            if (rc != 0) return error.RunFailed;
            try pipes.append(shell.arena.allocator(), .{
                .read = Io.File{ .handle = fds[0], .flags = .{ .nonblocking = false } },
                .write = Io.File{ .handle = fds[1], .flags = .{ .nonblocking = false } },
            });
        }

        for (0..cmds_count) |i| {
            const cmd: Command = pipeline.commands[i];

            var ctx: CommandContext = .init(cmd);
            defer {
                ctx.flush() catch {};
                ctx.close(shell.io);
            }

            // Skip the first command for stdin. The pipe chain looks
            // as follows: A -> B -> C
            if (i > 0) {
                const pipe_read = pipes.items[i - 1].read;
                ctx.in = Io.File.Reader.init(pipe_read, shell.io, &ctx.in_buffer);
                ctx.in_file = pipe_read;
            }

            ctx.out = Io.File.Writer.init(.stdout(), shell.io, &ctx.out_buffer);
            ctx.err = Io.File.Writer.init(.stderr(), shell.io, &ctx.err_buffer);
            for (cmd.redirects) |redirect| {
                const file = Io.Dir.createFile(
                    .cwd(),
                    shell.io,
                    redirect.file,
                    switch (redirect.kind) {
                        .truncate => .{},
                        .append => .{ .truncate = false },
                        .in => .{ .read = true },
                    },
                ) catch {
                    std.debug.print(
                        "shellu: invalid redirection target, {s}.\n",
                        .{redirect.file},
                    );
                    return error.RunFailed;
                };

                const dest = redirect.dest orelse {
                    ctx.in = Io.File.Reader.init(file, shell.io, &ctx.in_buffer);
                    ctx.in_file = file;
                    break;
                };

                switch (dest) {
                    .stdout => {
                        ctx.out = Io.File.Writer.init(file, shell.io, &ctx.out_buffer);
                        ctx.out_file = file;
                        if (redirect.kind == .append) {
                            const stat = file.stat(shell.io) catch {
                                return error.RunFailed;
                            };
                            ctx.out.seekTo(stat.size) catch return error.RunFailed;
                        }
                    },
                    .stderr => {
                        ctx.err = Io.File.Writer.init(file, shell.io, &ctx.err_buffer);
                        ctx.err_file = file;
                        if (redirect.kind == .append) {
                            const stat = file.stat(shell.io) catch {
                                return error.RunFailed;
                            };
                            ctx.err.seekTo(stat.size) catch return error.RunFailed;
                        }
                    },
                }
            }

            if (ctx.out_file == null and i < cmds_count - 1) {
                const pipe_write = pipes.items[i].write;
                ctx.out = Io.File.Writer.init(pipe_write, shell.io, &ctx.out_buffer);
                ctx.out_file = pipe_write;
            }

            if (Builtin.parse(ctx.command.program)) |_| {
                try builtins.run(shell, &ctx);
                try ctx.flush();
            } else {
                var background: bool = false;
                if (ctx.command.args.len > 1 and
                    std.mem.eql(u8, ctx.command.args[ctx.command.args.len - 1], "&"))
                {
                    ctx.command.args = ctx.command.args[0 .. ctx.command.args.len - 1];
                    background = true;
                }
                try external.run(shell, &ctx, background);
            }

            if (i < cmds_count - 1) {
                pipes.items[i].write.close(shell.io);
                ctx.out_file = null;
            }
        }
    }

    pub fn reap_jobs(shell: *Shell) !void {
        const job_count = shell.jobs.values().len;
        var job_done_ids: std.ArrayList(Job.Id) = .empty;
        defer job_done_ids.deinit(shell.gpa);

        for (shell.jobs.values(), 0..) |*job, i| {
            if (std.c.waitpid(job.pid, null, std.c.W.NOHANG) != 0) {
                job.status = .Done;
            }
            if (job.status == .Running) continue;

            try job_done_ids.append(shell.gpa, job.id);
            const marker = if (i == job_count - 1) "+" else if (i == job_count - 2) "-" else "";
            const status = @tagName(job.status);
            const command = std.mem.trimEnd(u8, job.cmd_text, "&");

            std.debug.print("shellu: [{d}]{s: <2} {s: <24}{s}\n", .{
                @intFromEnum(job.id),
                marker,
                status,
                command,
            });
        }

        for (job_done_ids.items) |job_id| {
            if (shell.jobs.get(job_id)) |job| {
                try shell.id_generator.delete(shell.gpa, job_id);
                shell.gpa.free(job.cmd_text);
            }
            _ = shell.jobs.fetchOrderedRemove(job_id);
        }
    }
};
