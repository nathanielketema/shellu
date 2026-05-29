const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

const Shell = @This();

path_dirs: []SearchDir,
home_path: []const u8,
records: std.StringHashMap([]const u8),
cwd: [:0]const u8,
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

    for (shell.path_dirs) |path_dir| {
        path_dir.dir.close(shell.io);
    }
    shell.gpa.free(shell.path_dirs);
    shell.gpa.free(shell.cwd);
}
