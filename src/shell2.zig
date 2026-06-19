const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Environ = std.process.Environ;
const StringHashMap = std.StringHashMap;
const ArrayList = std.ArrayList;

const builtins = @import("builtins2.zig");
const cmdline = @import("cmdline.zig");
const Parser = cmdline.Parser;
const Pipeline = cmdline.Pipeline;

pub const Errors = struct {
    count: usize = 0,
};

pub const Shell = struct {
    io: Io,
    gpa: Allocator,
    arena: std.heap.ArenaAllocator,
    env: *Environ.Map,
    variables: StringHashMap([]const u8),
    home_path: []const u8,
    //jobs: std.array_hash_map.Auto(u32, Job), // job_id: Job
    errors: ArrayList(Errors),
    writers: Writers,

    pub const Writers = struct {
        stdout: *Io.Writer,
        stderr: *Io.Writer,
        stdout_buffer: [4086]u8 = undefined,
        stderr_buffer: [4086]u8 = undefined,

        pub fn init(io: Io) Writers {
            var w: Writers = undefined;

            var stdout_writer: Io.File.Writer = .init(.stdout(), io, &w.stdout_buffer);
            var stderr_writer: Io.File.Writer = .init(.stderr(), io, &w.stderr_buffer);

            w.stdout = &stdout_writer.interface;
            w.stderr = &stderr_writer.interface;

            return w;
        }
    };

    pub fn init(io: Io, gpa: Allocator, env: *Environ.Map) Shell {
        var arena: std.heap.ArenaAllocator = .init(gpa);
        errdefer arena.deinit();

        const home_path = env.get("HOME") orelse "/";
        const writers: Writers = .init(io);

        return .{
            .io = io,
            .gpa = gpa,
            .arena = arena,
            .env = env,
            .variables = .init(gpa),
            .home_path = home_path,
            .errors = .empty,
            .writers = writers,
        };
    }

    pub fn deinit(shell: *Shell) void {
        const gpa = shell.gpa;
        {
            var key_it = shell.variables.keyIterator();
            while (key_it.next()) |key| gpa.free(key.*);
            var val_it = shell.variables.valueIterator();
            while (val_it.next()) |val| gpa.free(val.*);
            shell.variables.deinit();
        }
        shell.arena.deinit();
    }

    pub fn flush(shell: *Shell) !void {
        try shell.writers.stdout.flush();
        try shell.writers.stderr.flush();
    }

    pub fn parse(shell: *Shell, arena: Allocator, input: [:0]const u8) !Pipeline {
        var parser: Parser = try .init(arena, input, shell.variables, shell.home_path);
        return parser.parse();
    }

    pub fn run(shell: *Shell, pipeline: Pipeline) !void {
        for (pipeline.commands) |command| {
            try builtins.run(shell, command);
        }
    }

    pub fn reap_jobs(shell: *Shell) void {
        _ = shell;
        @panic("TODO: reap_jobs");
    }
};
