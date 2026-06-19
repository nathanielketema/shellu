const std = @import("std");
const assert = std.debug.assert;
const ArrayList = std.ArrayList;
const Allocator = std.mem.Allocator;

const Tokenizer = @import("tokenizer.zig").Tokenizer;
const Token = @import("tokenizer.zig").Token;

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
            dest: ?Dest,

            pub const Kind = enum {
                in,
                append,
                truncate,
            };

            pub const Dest = enum {
                stdout,
                stderr,
            };
        };
    };
};

// TODO: pretty print error msg. Use fish as a guide
pub const Errors = struct {
    count: usize = 0,

    pub fn add_invalid_program(errors: *Errors, tag: Token.Tag) void {
        errors.emit("shellu: Expected a string, but found a {s}\n", .{@tagName(tag)});
    }

    pub fn add_invalid_token(errors: *Errors) void {
        errors.emit("shellu: Invalid token\n", .{});
    }

    pub fn emit(errors: *Errors, comptime fmt: []const u8, args: anytype) void {
        comptime assert(fmt[fmt.len - 1] == '\n');
        errors.count += 1;
        std.debug.print(fmt, args);
    }
};

pub const Parser = struct {
    source: [:0]const u8,
    tokens: ArrayList(Token),
    errors: Errors,
    variables: std.StringHashMap([]const u8),
    home_path: []const u8,
    token_index: usize,
    arena: Allocator,

    pub fn init(
        arena: Allocator,
        input: [:0]const u8,
        variables: std.StringHashMap([]const u8),
        home_path: []const u8,
    ) !Parser {
        var tokens: ArrayList(Token) = .empty;
        var tokenizer: Tokenizer = .init(input);
        while (true) {
            const token = tokenizer.next();
            try tokens.append(arena, token);
            if (token.tag == .eol) break;
        }

        return .{
            .source = input,
            .tokens = tokens,
            .errors = .{},
            .variables = variables,
            .home_path = home_path,
            .token_index = 0,
            .arena = arena,
        };
    }

    pub fn parse(parser: *Parser) !Pipeline {
        var commands: ArrayList(Pipeline.Command) = .empty;
        while (parser.token_index < parser.tokens.items.len) {
            const command = try parser.parse_command();
            try commands.append(parser.arena, command);
        }

        for (commands.items) |command| {
            std.debug.print("prgram name: {s}\n", .{command.program});
            std.debug.print("args:\n", .{});
            for (command.args) |arg| std.debug.print("  - {s}\n", .{arg});
            std.debug.print("redirects:\n", .{});
            for (command.redirects) |redirect| {
                std.debug.print("  - {s} -> {s} -> {s}\n", .{
                    redirect.file,
                    @tagName(redirect.kind),
                    if (redirect.dest) |d| @tagName(d) else "",
                });
            }
        }
        return .{ .commands = commands.items };
    }

    pub fn parse_command(parser: *Parser) !Pipeline.Command {
        const first = parser.tokens.items[parser.token_index];
        if (first.tag != .literal) {
            parser.errors.add_invalid_program(first.tag);
            return error.ParseFailed;
        }
        const program = parser.source[first.loc.start..first.loc.end];
        parser.token_index += 1;

        var args: ArrayList([]const u8) = .empty;
        var redirects: ArrayList(Pipeline.Command.Redirect) = .empty;
        while (parser.token_index < parser.tokens.items.len) {
            const token = parser.tokens.items[parser.token_index];
            switch (token.tag) {
                .invalid => {
                    parser.errors.add_invalid_token();
                    return error.ParseFailed;
                },
                .eol, .pipe => {
                    parser.token_index += 1;
                    return .{
                        .program = program,
                        .args = args.items,
                        .redirects = redirects.items,
                    };
                },
                .tilde => {
                    if (parser.source[token.loc.end] != ' ' and
                        parser.tokens.items[parser.token_index + 1].tag == .literal)
                    {
                        parser.token_index += 1;
                        const literal = parser.tokens.items[parser.token_index];
                        const arg = try std.mem.concat(parser.arena, u8, &.{
                            parser.home_path,
                            parser.source[literal.loc.start..literal.loc.end],
                        });
                        try args.append(parser.arena, arg);
                    } else try args.append(parser.arena, parser.home_path);
                    parser.token_index += 1;
                },
                .literal => {
                    try args.append(parser.arena, parser.source[token.loc.start..token.loc.end]);
                    parser.token_index += 1;
                },
                .variable => {
                    const name = parser.source[token.loc.start..token.loc.end];
                    const value = parser.variables.get(name) orelse "";

                    if (token.loc.end + 1 < parser.source.len and
                        parser.source[token.loc.end] == '}' and
                        parser.source[token.loc.end + 1] != ' ' and
                        parser.tokens.items[parser.token_index + 1].tag == .literal)
                    {
                        parser.token_index += 1;
                        const literal = parser.tokens.items[parser.token_index];
                        const arg = try std.mem.concat(parser.arena, u8, &.{
                            value,
                            parser.source[literal.loc.start..literal.loc.end],
                        });
                        try args.append(parser.arena, arg);
                    } else try args.append(parser.arena, value);
                    parser.token_index += 1;
                },
                .redirect_in, .redirect_append, .redirect_truncate => {
                    const Kind = Pipeline.Command.Redirect.Kind;
                    const Dest = Pipeline.Command.Redirect.Dest;

                    const next = parser.tokens.items[parser.token_index + 1];
                    if (next.tag != .literal) {
                        // parser.errors.
                        return error.ParseFailed;
                    }
                    const file = parser.source[next.loc.start..next.loc.end];
                    const kind: Kind = switch (token.tag) {
                        .redirect_in => .in,
                        .redirect_append => .append,
                        .redirect_truncate => .truncate,
                        else => {
                            // parser.errors.
                            return error.ParseFailed;
                        },
                    };
                    const dest: ?Dest = dst: {
                        if (kind == .in) break :dst null;
                        if (parser.source[token.loc.start] == '2') {
                            break :dst .stderr;
                        } else break :dst .stdout;
                    };

                    try redirects.append(parser.arena, .{
                        .file = file,
                        .kind = kind,
                        .dest = dest,
                    });
                    parser.token_index += 2;
                },
            }
        }

        return .{
            .program = program,
            .args = args.items,
            .redirects = redirects.items,
        };
    }
};
