const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;
const Io = std.Io;
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const SourceLocation = std.builtin.SourceLocation;
const Snapshot = @This();

location: SourceLocation,
text: []const u8,
update_this: bool = false,

/// Creates a new Snap.
///
/// For the update logic to work, *must* be formatted as:
///
/// ```
/// snap(@src(),
///     \\Text of the snapshot.
/// )
/// ```
pub fn snap(location: SourceLocation, text: []const u8) Snapshot {
    return .{
        .location = location,
        .text = text,
    };
}

pub fn update(snapshot: *const Snapshot) Snapshot {
    return .{
        .location = snapshot.location,
        .text = snapshot.text,
        .update_this = true,
    };
}

fn should_update(snapshot: Snapshot) bool {
    return snapshot.update_this;
}

pub fn diff(snapshot: *const Snapshot, got: []const u8) !void {
    if (std.mem.eql(u8, snapshot.text, got)) return;

    std.debug.print(
        \\Snapshot differs.
        \\Want:
        \\----
        \\{s}
        \\----
        \\Got:
        \\----
        \\{s}
        \\----
        \\
    , .{ snapshot.text, got });

    if (!snapshot.should_update()) return error.SnapDiff;

    var io_threaded: Io.Threaded = .init(std.testing.allocator, .{});
    defer io_threaded.deinit();
    const io = io_threaded.io();

    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const file_text = try std.Io.Dir.cwd().readFileAlloc(
        io,
        snapshot.location.file,
        allocator,
        .limited(1024 * 1024),
    );
    var file_text_updated: ArrayList(u8) = try .initCapacity(allocator, file_text.len);

    const line_zero_based = snapshot.location.line - 1;
    const range = snap_range(file_text, line_zero_based);

    const snapshot_prefix = file_text[0..range.start];
    const snapshot_text = file_text[range.start..range.end];
    const snapshot_suffix = file_text[range.end..];

    const indent = get_indent(snapshot_text);

    try file_text_updated.appendSlice(allocator, snapshot_prefix);
    {
        var lines = std.mem.splitScalar(u8, got, '\n');
        while (lines.next()) |line| {
            try file_text_updated.print(allocator, "{s}\\\\{s}\n", .{ indent, line });
        }
    }
    try file_text_updated.appendSlice(allocator, snapshot_suffix);

    try std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = snapshot.location.file,
        .data = file_text_updated.items,
    });

    std.debug.print("Updated {s}\n", .{snapshot.location.file});
    return error.SnapUpdated;
}

pub fn diff_fmt(want: *const Snapshot, comptime fmt: []const u8, fmt_args: anytype) !void {
    const got = try std.fmt.allocPrint(testing.allocator, fmt, fmt_args);
    defer testing.allocator.free(got);
    try want.diff(got);
}

const Range = struct {
    start: usize,
    end: usize,
};

fn snap_range(text: []const u8, src_line: u32) Range {
    var offset: usize = 0;
    var line_number: u32 = 0;

    var lines = std.mem.splitScalar(u8, text, '\n');
    const snap_start = while (lines.next()) |line| : (line_number += 1) {
        if (line_number == src_line) {
            assert(std.mem.indexOf(u8, line, "@src()") != null);
        }
        if (line_number == src_line + 1) {
            assert(is_multiline_string(line));
            break offset;
        }
        offset += line.len + 1; // 1 for \n
    } else unreachable;

    lines = std.mem.splitScalar(u8, text[snap_start..], '\n');
    const snap_end = while (lines.next()) |line| {
        if (!is_multiline_string(line)) {
            break offset;
        }
        offset += line.len + 1; // 1 for \n
    } else unreachable;

    return Range{ .start = snap_start, .end = snap_end };
}

fn is_multiline_string(line: []const u8) bool {
    for (line, 0..) |c, i| {
        switch (c) {
            ' ' => {},
            '\\' => return (i + 1 < line.len and line[i + 1] == '\\'),
            else => return false,
        }
    }
    return false;
}

fn get_indent(line: []const u8) []const u8 {
    for (line, 0..) |c, i| {
        if (c != ' ') return line[0..i];
    }
    return line;
}

fn check(got: []const u8, want: Snapshot) !void {
    try want.diff(got);
}

test "usage" {
    try check("Hey", snap(@src(),
        \\Hey
    ));
}

test "basic arithmetics" {
    const result = 2 + 2;

    try snap(@src(),
        \\2 + 2 = 4
    ).update().diff_fmt("2 + 2 = {}", .{result});
}
