const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Pipeline = struct {
    /// This always contains atleast one command
    commands: []Command,

    pub const Command = struct {
        /// Cannot be empty
        program: []const u8,
        args: []const []const u8,
        redirects: []Redirect,

        pub const Redirect = struct {
            /// Cannot be empty
            file: []const u8,
            kind: Kind,

            const Kind = enum {
                stdin, // <
                append, // >>
                truncate, // >
            };
        };
    };
};

pub fn parse(arena: Allocator, input: []const u8) Pipeline {
    _ = arena;
    _ = input;
    @panic("TODO: implement parse()");
}
