const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Io = std.Io;

pub const Errors = struct {
    count: usize = 0,
};

pub const Shell = struct {
    io: Io,
    gpa: Allocator,
    arena: Allocator,
    env: std.process.Environ.Map,
    //jobs: std.array_hash_map.Auto(u32, Job), // job_id: Job
    errors: Errors,
    stdout: *Io.Writer,
    stderr: *Io.Writer,

    pub fn init(io: Io, gpa: Allocator, env: *std.process.Environ.Map) Shell {
        _ = io;
        _ = gpa;
        _ = env;
        @panic("TODO: init");
    }

    pub fn deinit(shell: *Shell) void {
        _ = shell;
        @panic("TODO: deinit");
    }

    pub fn flush(shell: *Shell) !void {
        try shell.stdout.flush();
        try shell.stderr.flush();
    }
};
