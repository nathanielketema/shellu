const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;

pub fn maybe(ok: bool) void {
    assert(ok or !ok);
}
