const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

const Shell = @This();

path_dirs: []SearchDir,
home_path: []const u8,
records: std.StringHashMap([]const u8),
cwd: [:0]const u8,
jobs: std.array_hash_map.Auto(u32, Job), // job_id: Job
job_id_generator: Job.IdGenerator,
io: Io,
gpa: Allocator,

pub const SearchDir = struct {
    path: []const u8,
    dir: Io.Dir,
};

pub const Config = struct {
    path_env: []const u8,
    home_env: []const u8,

    pub fn from_environment(environment: *std.process.Environ.Map) Config {
        return .{
            .path_env = environment.get("PATH") orelse "/usr/bin:/bin",
            .home_env = environment.get("HOME") orelse "/",
        };
    }
};

pub const Job = struct {
    job_id: u32,
    PID: i32,
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

pub fn init(io: Io, gpa: Allocator, config: Config) !Shell {
    assert(config.home_env.len > 0);
    assert(config.path_env.len > 0);

    var path_dirs: std.ArrayList(SearchDir) = .empty;
    var it = std.mem.tokenizeScalar(u8, config.path_env, ':');
    while (it.next()) |path| {
        assert(path.len > 0);

        // If the directory can't be opened, skip it.
        const dir = Io.Dir.openDir(.cwd(), io, path, .{}) catch continue;
        try path_dirs.append(gpa, .{
            .path = path,
            .dir = dir,
        });
    }

    return .{
        .path_dirs = try path_dirs.toOwnedSlice(gpa),
        .home_path = config.home_env,
        .records = .init(gpa),
        .cwd = try std.process.currentPathAlloc(io, gpa),
        .jobs = .empty,
        .job_id_generator = .{},
        .io = io,
        .gpa = gpa,
    };
}

pub fn deinit(shell: *Shell) void {
    assert(shell.path_dirs.len > 0);
    assert(shell.cwd.len > 0);

    var keys = shell.records.keyIterator();
    while (keys.next()) |key| shell.gpa.free(key.*);
    var values = shell.records.valueIterator();
    while (values.next()) |value| shell.gpa.free(value.*);
    shell.records.deinit();

    shell.jobs.deinit(shell.gpa);
    shell.job_id_generator.deinit(shell.gpa);

    for (shell.path_dirs) |path_dir| {
        path_dir.dir.close(shell.io);
    }
    shell.gpa.free(shell.path_dirs);
    shell.gpa.free(shell.cwd);
}
