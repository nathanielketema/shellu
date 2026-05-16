const std = @import("std");
const Io = std.Io;
const ArrayList = std.ArrayList;
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const mem = std.mem;

const Shell = @import("shell.zig").Shell;

const Input = @This();

pub fn maybe(ok: bool) void {
    assert(ok or !ok);
}

command: Command,
args: []const []const u8,
gpa: Allocator,

const Command = struct {
    builtin: ?Shell.Builtin.Command,
    string: []const u8,
};

pub fn parse(gpa: Allocator, raw_input: []const u8) !Input {
    assert(raw_input.len > 0);

    var args: ArrayList([]const u8) = .empty;
    errdefer args.deinit(gpa);

    var it = mem.tokenizeAny(u8, raw_input, " ");
    const command_string = it.next().?;
    assert(command_string.len > 0);

    const command: Command = .{
        .builtin = .parse(command_string),
        .string = command_string,
    };

    while (it.next()) |arg| try args.append(gpa, arg);
    maybe(args.items.len == 0);

    return .{
        .command = command,
        .args = try args.toOwnedSlice(gpa),
        .gpa = gpa,
    };
}

pub fn deinit(input: *Input) void {
    input.gpa.free(input.args);
}
