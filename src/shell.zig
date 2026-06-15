const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const Environ = std.process.Environ;

const readline = @import("readline");
const builtins = @import("builtins.zig");

pub const EnvConfig = struct {
    path: []const u8,
    home: []const u8,
    hist: ?[]const u8,

    pub fn from_environment(env: *std.process.Environ.Map) EnvConfig {
        return .{
            .path = env.get("PATH") orelse "/usr/bin:/bin",
            .home = env.get("HOME") orelse "/",
            .hist = env.get("HISTFILE") orelse null,
        };
    }
};

pub const Job = struct {
    id: u32,
    pid: i32,
    status: enum { Running, Done },
    command_string: []const u8,

    pub const IdGenerator = struct {
        last: u32 = 0,
        free: std.PriorityQueue(u32, void, struct {
            fn less_than(_: void, a: u32, b: u32) std.math.Order {
                return std.math.order(a, b);
            }
        }.less_than) = .empty,

        pub fn new(id_generator: *IdGenerator) u32 {
            return id_generator.free.pop() orelse blk: {
                id_generator.last += 1;
                break :blk id_generator.last;
            };
        }

        pub fn remove(id_generator: *IdGenerator, gpa: Allocator, id: u32) !void {
            try id_generator.free.push(gpa, id);
        }

        pub fn deinit(id_generator: *IdGenerator, gpa: Allocator) void {
            id_generator.free.deinit(gpa);
        }
    };
};

const CompletionDatabase = struct {
    executables: std.ArrayList([:0]const u8) = .empty,

    pub fn deinit(self: *CompletionDatabase, gpa: Allocator) void {
        for (self.executables.items) |exe| {
            gpa.free(exe);
        }
        self.executables.deinit(gpa);
    }
};

pub const Specification = struct {
    path: []const u8,
    cmd: []const u8,
};

var active_shell: ?*Shell = null;
var spec_candidates: [128][:0]const u8 = undefined;
var spec_num_candidates: usize = 0;
pub const Shell = struct {
    io: Io,
    cwd: [:0]const u8,
    gpa: Allocator,
    jobs: std.array_hash_map.Auto(u32, Job), // job_id: Job
    records: std.StringHashMap([]const u8),
    path_dirs: []SearchDir,
    home_path: []const u8,
    hist_file: ?[]const u8,
    id_generator: Job.IdGenerator,
    completion_db: CompletionDatabase,
    specification: std.StringHashMap(Specification),
    history_offset: usize,
    environ_map: *Environ.Map,

    pub const SearchDir = struct {
        dir: Io.Dir,
        path: []const u8,
    };

    pub fn init(io: Io, gpa: Allocator, config: EnvConfig, environ_map: *Environ.Map) !Shell {
        assert(config.home.len > 0);
        assert(config.path.len > 0);

        var path_dirs: std.ArrayList(SearchDir) = .empty;
        var it = std.mem.tokenizeScalar(u8, config.path, ':');
        while (it.next()) |path| {
            assert(path.len > 0);

            // If the directory can't be opened, skip it.
            const dir = Io.Dir.openDir(
                .cwd(),
                io,
                path,
                .{ .iterate = true },
            ) catch continue;
            try path_dirs.append(gpa, .{
                .path = path,
                .dir = dir,
            });
        }

        readline.rl_attempted_completion_function = attempted_completion_function;
        _ = readline.rl_bind_key('\t', readline.rl_complete);
        readline.using_history();

        const history_count: usize = blk: {
            if (config.hist) |hist_file| {
                const hist = try gpa.dupeSentinel(u8, hist_file, 0);
                defer gpa.free(hist);
                _ = readline.read_history(hist);
            }
            break :blk @intCast(readline.history_get_history_state().*.length);
        };

        var completion_db: CompletionDatabase = .{};
        for (path_dirs.items) |path_dir| {
            var exes = path_dir.dir.iterate();

            while (exes.next(io) catch break) |entry| {
                path_dir.dir.access(io, entry.name, .{ .execute = true }) catch continue;

                const duped_entry = try gpa.dupeSentinel(u8, entry.name, 0);
                try completion_db.executables.append(gpa, duped_entry);
            }
        }

        return .{
            .io = io,
            .gpa = gpa,
            .cwd = try std.process.currentPathAlloc(io, gpa),
            .jobs = .empty,
            .records = .init(gpa),
            .path_dirs = try path_dirs.toOwnedSlice(gpa),
            .home_path = config.home,
            .hist_file = config.hist,
            .id_generator = .{},
            .completion_db = completion_db,
            .specification = .init(gpa),
            .history_offset = history_count,
            .environ_map = environ_map,
        };
    }

    pub fn activate(shell: *Shell) void {
        active_shell = shell;
    }

    pub fn deinit(shell: *Shell) void {
        assert(shell.path_dirs.len > 0);
        assert(shell.cwd.len > 0);

        {
            var keys = shell.records.keyIterator();
            while (keys.next()) |key| shell.gpa.free(key.*);
            var values = shell.records.valueIterator();
            while (values.next()) |value| shell.gpa.free(value.*);
            shell.records.deinit();
        }

        {
            var keys = shell.specification.keyIterator();
            while (keys.next()) |key| shell.gpa.free(key.*);
            var values = shell.specification.valueIterator();
            while (values.next()) |value| shell.gpa.destroy(value);
            shell.specification.deinit();
        }

        shell.jobs.deinit(shell.gpa);
        shell.id_generator.deinit(shell.gpa);
        shell.gpa.free(shell.cwd);
        shell.completion_db.deinit(shell.gpa);

        for (shell.path_dirs) |path_dir| {
            path_dir.dir.close(shell.io);
        }
        shell.gpa.free(shell.path_dirs);

        if (shell.hist_file) |hist_file| {
            const hist = shell.gpa.dupeSentinel(u8, hist_file, 0) catch return;
            defer shell.gpa.free(hist);

            const curr_count: usize = @intCast(readline.history_get_history_state().*.length);
            const delta = curr_count - @min(curr_count, shell.history_offset);
            if (delta > 0) {
                _ = readline.append_history(@intCast(delta), hist.ptr);
            }
            shell.history_offset = curr_count;
        }
        if (active_shell == shell) active_shell = null;
    }

    pub fn reap_job(shell: *Shell, stdout: *Io.Writer) !void {
        const count = shell.jobs.values().len;
        const gpa = shell.gpa;
        var done_job_ids: std.ArrayList(u32) = .empty;
        defer done_job_ids.deinit(gpa);
        for (shell.jobs.values(), 0..) |*job, i| {
            if (std.c.waitpid(job.pid, null, std.c.W.NOHANG) != 0) {
                job.status = .Done;
            }
            if (job.status == .Running) continue;

            try done_job_ids.append(gpa, job.id);
            const job_id = job.id;
            const marker = if (i == count - 1) "+" else if (i == count - 2) "-" else "";
            const status = @tagName(job.status);
            const command = std.mem.trimEnd(u8, job.command_string, "&");

            try stdout.print("[{d}]{s: <2} {s: <24}{s}\n", .{
                job_id,
                marker,
                status,
                command,
            });
        }

        for (done_job_ids.items) |job_id| {
            if (shell.jobs.get(job_id)) |job| {
                try shell.id_generator.remove(gpa, job_id);
                gpa.free(job.command_string);
            }
            _ = shell.jobs.fetchOrderedRemove(job_id);
        }
    }

    fn spec_completion_generator(_: [*c]const u8, index: c_int) callconv(.c) [*c]u8 {
        if (index < 0) return null;
        const idx: usize = @intCast(index);
        if (idx < spec_num_candidates) {
            return readline.strdup(spec_candidates[idx]);
        }
        return null;
    }

    fn attempted_completion_function(
        text: [*c]const u8,
        start: c_int,
        _: c_int,
    ) callconv(.c) [*c][*c]u8 {
        if (start == 0) {
            return readline.rl_completion_matches(text, completion_matches);
        }

        if (active_shell) |shell| {
            const line = std.mem.span(readline.rl_line_buffer orelse
                return readline.rl_completion_matches(
                    text,
                    readline.rl_filename_completion_function,
                ));
            const trimmed = std.mem.trimStart(u8, line, " \t");
            if (trimmed.len > 0) {
                const end = std.mem.indexOfAny(u8, trimmed, " \t") orelse trimmed.len;
                const cmd = trimmed[0..end];

                if (shell.specification.get(cmd)) |spec| {
                    const text_slice = std.mem.span(text);
                    const leading_spaces = line.len - trimmed.len;
                    const args_before = line[leading_spaces..@intCast(start)];
                    const prev_word: []const u8 = if (args_before.len == 0) "" else blk: {
                        var end_idx: usize = args_before.len;
                        while (end_idx > 0 and
                            (args_before[end_idx - 1] == ' ' or
                                args_before[end_idx - 1] == '\t'))
                        {
                            end_idx -= 1;
                        }
                        if (end_idx == 0) break :blk "";
                        const before = args_before[0..end_idx];
                        const last_space = std.mem.lastIndexOfAny(u8, before, " \t");
                        break :blk if (last_space) |idx| before[idx + 1 ..] else before;
                    };

                    const comp_line = line;
                    var comp_point_buf: [20]u8 = undefined;
                    const comp_point_str = std.fmt.bufPrint(
                        &comp_point_buf,
                        "{}",
                        .{@as(usize, @intCast(readline.rl_point))},
                    ) catch "0";

                    const result = result: {
                        var comp_env = shell.environ_map.clone(shell.gpa) catch
                            break :result std.process.run(shell.gpa, shell.io, .{
                                .argv = &.{ spec.path, cmd, text_slice, prev_word },
                            }) catch return readline.rl_completion_matches(
                                text,
                                readline.rl_filename_completion_function,
                            );
                        defer comp_env.deinit();
                        comp_env.put("COMP_LINE", comp_line) catch {};
                        comp_env.put("COMP_POINT", comp_point_str) catch {};
                        break :result std.process.run(shell.gpa, shell.io, .{
                            .argv = &.{ spec.path, cmd, text_slice, prev_word },
                            .environ_map = &comp_env,
                        }) catch return readline.rl_completion_matches(
                            text,
                            readline.rl_filename_completion_function,
                        );
                    };
                    defer shell.gpa.free(result.stdout);
                    defer shell.gpa.free(result.stderr);

                    const stdout = std.mem.trimEnd(u8, result.stdout, "\n\r");
                    if (stdout.len == 0) {
                        return readline.rl_completion_matches(
                            text,
                            readline.rl_filename_completion_function,
                        );
                    }

                    spec_num_candidates = 0;
                    var lines_iter = std.mem.splitScalar(u8, stdout, '\n');
                    while (lines_iter.next()) |candidate_line| {
                        const trimmed_line = std.mem.trim(u8, candidate_line, " \t\r");
                        if (trimmed_line.len > 0 and spec_num_candidates < spec_candidates.len) {
                            spec_candidates[spec_num_candidates] = shell.gpa.dupeSentinel(
                                u8,
                                trimmed_line,
                                0,
                            ) catch continue;
                            spec_num_candidates += 1;
                        }
                    }

                    std.mem.sort([:0]const u8, spec_candidates[0..spec_num_candidates], {}, struct {
                        fn lessThan(_: void, a: [:0]const u8, b: [:0]const u8) bool {
                            var i: usize = 0;
                            while (a[i] != 0 and b[i] != 0) : (i += 1) {
                                if (a[i] < b[i]) return true;
                                if (a[i] > b[i]) return false;
                            }
                            return a[i] == 0 and b[i] != 0;
                        }
                    }.lessThan);

                    return readline.rl_completion_matches(text, spec_completion_generator);
                }
            }
        }

        return readline.rl_completion_matches(text, readline.rl_filename_completion_function);
    }

    fn completion_matches(input: [*c]const u8, index: c_int) callconv(.c) [*c]u8 {
        const input_slice = std.mem.span(input);
        var curr_index: c_int = 0;

        for (std.enums.values(builtins.Command)) |cmd| {
            if (std.mem.startsWith(u8, @tagName(cmd), input_slice)) {
                if (index == curr_index) {
                    return readline.strdup(@tagName(cmd));
                }
                curr_index += 1;
            }
        }

        if (active_shell) |shell| {
            for (shell.completion_db.executables.items) |exe| {
                if (std.mem.startsWith(u8, exe, input_slice)) {
                    if (index == curr_index) {
                        return readline.strdup(exe);
                    }
                    curr_index += 1;
                }
            }
        }

        return null;
    }
};
