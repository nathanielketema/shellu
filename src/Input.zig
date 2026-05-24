const std = @import("std");
const ArrayList = std.ArrayList;
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const testing = std.testing;
const log = std.log;

const Shell = @import("shell.zig").Shell;
const builtin = Shell.builtin;

const Input = @This();

command: Command,
args: []const []const u8,

const Command = union(enum) {
    builtin: builtin.Command,
    external: []const u8,
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
    _,
};

pub fn parse(arena: Allocator, shell: *Shell, text: []const u8) !Input {
    assert(text.len > 0);
    var words: ArrayList([]const u8) = try .initCapacity(arena, text.len);
    var word: ArrayList(u8) = try .initCapacity(arena, text.len);
    var temp: ArrayList(u8) = try .initCapacity(arena, text.len);

    var state: State = .seeking;
    var index: usize = 0;
    while (index < text.len) {
        const token: Token = @enumFromInt(text[index]);
        const next_token: Token = if (index < text.len - 1)
            @enumFromInt(text[index + 1])
        else
            @enumFromInt(0);
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
                    try word.appendSlice(arena, shell.home_path);
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
                    const value = shell.records.get(temp.items);
                    if (value) |val| {
                        try word.appendSlice(arena, val);
                    }
                    temp.clearRetainingCapacity();
                },
                .left_curly => state = .parsing,
                else => {
                    try temp.append(arena, @intFromEnum(token));
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
    if (state != .seeking) {
        if (state == .expanding) {
            const value = shell.records.get(temp.items);
            if (value) |val| {
                try word.appendSlice(arena, val);
            }
            if (word.items.len != 0) {
                try words.append(arena, try word.toOwnedSlice(arena));
            }
        } else try words.append(arena, try word.toOwnedSlice(arena));
    }
    assert(index >= text.len);
    assert(words.items.len > 0);

    const argv = try words.toOwnedSlice(arena);
    const cmd_str = argv[0];

    const command: Command = if (builtin.Command.parse(cmd_str)) |cmd|
        .{ .builtin = cmd }
    else
        .{ .external = cmd_str };

    return .{
        .command = command,
        .args = argv[1..],
    };
}
