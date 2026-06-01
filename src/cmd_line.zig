const std = @import("std");
const ArrayList = std.ArrayList;
const Io = std.Io;
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const mem = std.mem;

const builtins = @import("builtins.zig");
const Shell = @import("Shell.zig");

pub const StdioContext = struct {
    stdout: *Io.Writer,
    stderr: *Io.Writer,
    stdout_file: ?Io.File = null,
    stderr_file: ?Io.File = null,
};

pub const CommandContext = struct {
    arena: Allocator,
    shell: *Shell,
    stdio: StdioContext,
    input: Input,
};

pub const Input = struct {
    command: Command,
    args: []const []const u8,
    redirects: ?Redirect,
    background: bool = false,

    pub const Command = union(enum) {
        builtin: builtins.Command,
        external: []const u8,
    };

    pub const Redirect = struct {
        output: enum { stdout, stderr },
        mode: enum { truncate, append },
        file: []const u8,
    };

    pub const State = enum {
        seeking,
        parsing,
        single,
        double,
        expanding,
    };

    pub const Token = enum(u8) {
        space = ' ',
        tilde = '~',
        single_quote = '\'',
        double_quote = '"',
        dollar = '$',
        left_curly = '{',
        right_curly = '}',
        back_slash = '\\',
        end_of_file,
        _,
    };

    pub fn parse(
        arena: Allocator,
        text: []const u8,
        records: *std.StringHashMap([]const u8),
        home_path: []const u8,
    ) !Input {
        assert(text.len > 0);
        var words: ArrayList([]const u8) = try .initCapacity(arena, text.len);
        var word: ArrayList(u8) = try .initCapacity(arena, text.len);
        var expansion_name: ArrayList(u8) = try .initCapacity(arena, text.len);

        var state: State = .seeking;
        var index: usize = 0;
        while (index < text.len) {
            const token: Token = @enumFromInt(text[index]);
            const next_token: Token = if (index < text.len - 1)
                @enumFromInt(text[index + 1])
            else
                .end_of_file;
            switch (state) {
                .seeking => switch (token) {
                    .space => index += 1,
                    .single_quote => {
                        state = .single;
                        index += 1;
                    },
                    .double_quote => {
                        state = .double;
                        index += 1;
                    },
                    .tilde => {
                        state = .parsing;
                        try word.appendSlice(arena, home_path);
                        index += 1;
                    },
                    .dollar => {
                        state = .expanding;
                        index += 1;
                    },
                    .back_slash => {
                        try word.append(arena, @intFromEnum(next_token));
                        index += 2;
                    },
                    else => {
                        state = .parsing;
                        try word.append(arena, @intFromEnum(token));
                        index += 1;
                    },
                },
                .expanding => switch (token) {
                    .space, .dollar, .right_curly => {
                        state = .parsing;
                        const value = records.get(expansion_name.items);
                        if (value) |record_value| {
                            try word.appendSlice(arena, record_value);
                        }
                        expansion_name.clearRetainingCapacity();
                    },
                    .left_curly => state = .parsing,
                    else => {
                        try expansion_name.append(arena, @intFromEnum(token));
                        index += 1;
                    },
                },
                .parsing => switch (token) {
                    .single_quote => {
                        state = .single;
                        index += 1;
                    },
                    .double_quote => {
                        state = .double;
                        index += 1;
                    },
                    .space => {
                        state = .seeking;
                        if (word.items.len != 0) {
                            try words.append(arena, try word.toOwnedSlice(arena));
                            word.clearRetainingCapacity();
                        }
                        index += 1;
                    },
                    .dollar, .left_curly => {
                        state = .expanding;
                        index += 1;
                    },
                    .back_slash => {
                        try word.append(arena, @intFromEnum(next_token));
                        index += 2;
                    },
                    .right_curly => index += 1,
                    else => {
                        try word.append(arena, @intFromEnum(token));
                        index += 1;
                    },
                },
                .single => switch (token) {
                    .single_quote => {
                        state = .parsing;
                        index += 1;
                    },
                    else => {
                        try word.append(arena, @intFromEnum(token));
                        index += 1;
                    },
                },
                .double => switch (token) {
                    .double_quote => {
                        state = .parsing;
                        index += 1;
                    },
                    .back_slash => {
                        try word.append(arena, @intFromEnum(next_token));
                        index += 2;
                    },
                    else => {
                        try word.append(arena, @intFromEnum(token));
                        index += 1;
                    },
                },
            }
        }

        switch (state) {
            .seeking => {},
            .expanding => {
                const value = records.get(expansion_name.items);
                if (value) |record_value| {
                    assert(record_value.len > 0);
                    try word.appendSlice(arena, record_value);
                }
                if (word.items.len != 0) {
                    try words.append(arena, try word.toOwnedSlice(arena));
                }
            },
            else => try words.append(arena, try word.toOwnedSlice(arena)),
        }
        assert(index >= text.len);
        assert(words.items.len > 0);
        assert(words.items[0].len > 0);

        const is_background: bool = bck: {
            if (mem.eql(u8, words.getLast(), "&")) {
                _ = words.pop();
                break :bck true;
            } else break :bck false;
        };
        const redirect_result = try redirect(arena, words.items[1..]);

        const command: Command = if (builtins.Command.parse(
            words.items[0],
        )) |builtin_command|
            .{ .builtin = builtin_command }
        else
            .{ .external = words.items[0] };

        return .{
            .command = command,
            .args = redirect_result.args,
            .redirects = redirect_result.redirect,
            .background = is_background,
        };
    }

    pub fn redirect(arena: Allocator, words: []const []const u8) !struct {
        args: []const []const u8,
        redirect: ?Redirect,
    } {
        var arguments: ArrayList([]const u8) = .empty;
        var redirect_result: ?Redirect = null;
        var word_index: usize = 0;

        // The last redirect wins. Earlier redirects are omitted from arguments.
        while (word_index < words.len) : (word_index += 1) {
            if (mem.eql(u8, words[word_index], "1>") or
                mem.eql(u8, words[word_index], ">"))
            {
                if (word_index + 1 >= words.len) {
                    return error.MissingRedirectTarget;
                }
                redirect_result = .{
                    .output = .stdout,
                    .mode = .truncate,
                    .file = words[word_index + 1],
                };
                word_index += 1; // skip the file
            } else if (mem.eql(u8, words[word_index], "2>")) {
                if (word_index + 1 >= words.len) {
                    return error.MissingRedirectTarget;
                }
                redirect_result = .{
                    .output = .stderr,
                    .mode = .truncate,
                    .file = words[word_index + 1],
                };
                word_index += 1; // skip the file
            } else if (mem.eql(u8, words[word_index], "1>>") or
                mem.eql(u8, words[word_index], ">>"))
            {
                if (word_index + 1 >= words.len) {
                    return error.MissingRedirectTarget;
                }
                redirect_result = .{
                    .output = .stdout,
                    .mode = .append,
                    .file = words[word_index + 1],
                };
                word_index += 1; // skip the file
            } else if (mem.eql(u8, words[word_index], "2>>")) {
                if (word_index + 1 >= words.len) {
                    return error.MissingRedirectTarget;
                }
                redirect_result = .{
                    .output = .stderr,
                    .mode = .append,
                    .file = words[word_index + 1],
                };
                word_index += 1; // skip the file
            } else try arguments.append(arena, words[word_index]);
        }

        return .{
            .args = try arguments.toOwnedSlice(arena),
            .redirect = redirect_result,
        };
    }
};

pub const Output = struct {
    stdout_writer: Io.File.Writer,
    stderr_writer: Io.File.Writer,
    redirects: ?Input.Redirect,

    pub fn init(
        io: Io,
        directory: Io.Dir,
        redirects: ?Input.Redirect,
        stdout_buffer: *[4096]u8,
        stderr_buffer: *[4096]u8,
    ) !Output {
        var stdout_writer: Io.File.Writer = undefined;
        var stderr_writer: Io.File.Writer = undefined;
        if (redirects) |redirect| {
            assert(redirect.file.len > 0);
            const sub_path = redirect.file;
            var file: Io.File = undefined;
            switch (redirect.mode) {
                .append => file = try Io.Dir.createFile(directory, io, sub_path, .{
                    .truncate = false,
                }),
                .truncate => file = try Io.Dir.createFile(directory, io, sub_path, .{}),
            }

            switch (redirect.output) {
                .stdout => {
                    stdout_writer = .initStreaming(file, io, stdout_buffer);
                    if (redirect.mode == .append) {
                        try stdout_writer.seekTo((try file.stat(io)).size);
                    }
                    stderr_writer = .init(.stderr(), io, stderr_buffer);
                },
                .stderr => {
                    stdout_writer = .init(.stdout(), io, stdout_buffer);
                    stderr_writer = .initStreaming(file, io, stderr_buffer);
                    if (redirect.mode == .append) {
                        try stderr_writer.seekTo((try file.stat(io)).size);
                    }
                },
            }
        } else {
            stdout_writer = .init(.stdout(), io, stdout_buffer);
            stderr_writer = .init(.stderr(), io, stderr_buffer);
        }
        return .{
            .stdout_writer = stdout_writer,
            .stderr_writer = stderr_writer,
            .redirects = redirects,
        };
    }

    pub fn stdout(output: *Output) *Io.Writer {
        return &output.stdout_writer.interface;
    }

    pub fn stderr(output: *Output) *Io.Writer {
        return &output.stderr_writer.interface;
    }

    pub fn flush(output: *Output) !void {
        try output.stdout().flush();
        try output.stderr().flush();
    }

    pub fn deinit(output: *Output, io: Io) void {
        if (output.redirects) |redirects| {
            assert(redirects.file.len > 0);
            switch (redirects.output) {
                .stdout => output.stdout_writer.file.close(io),
                .stderr => output.stderr_writer.file.close(io),
            }
        }
    }
};
