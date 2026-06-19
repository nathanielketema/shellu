const std = @import("std");

pub const Token = struct {
    tag: Tag,
    loc: Location,

    pub const Location = struct {
        start: usize,
        end: usize,
    };

    pub const Tag = enum {
        eol, // end of line
        invalid,
        pipe,
        tilde,
        literal,
        variable,
        redirect_in,
        redirect_append,
        redirect_truncate,

        pub fn lexeme(tag: Tag) ?[]const u8 {
            return switch (tag) {
                .pipe => "|",
                .tilde => "~",
                .redirect_append => ">>",
                .redirect_truncate => ">",
                .redirect_in => "<",
                .eol, .variable, .literal, .invalid => null,
            };
        }
    };
};

pub const Tokenizer = struct {
    buffer: [:0]const u8,
    index: usize,

    pub fn init(buffer: [:0]const u8) Tokenizer {
        return .{
            .buffer = buffer,
            .index = 0,
        };
    }

    const State = enum {
        start,
        invalid,
        literal,
        redirect,
        variable,
        double_quote,
        single_quote,
        variable_braced,
    };

    /// An eol token will always be returned at the end.
    pub fn next(self: *Tokenizer) Token {
        var result: Token = .{
            .tag = undefined,
            .loc = .{
                .start = self.index,
                .end = undefined,
            },
        };

        state: switch (State.start) {
            .start => switch (self.buffer[self.index]) {
                0 => return .{
                    .tag = .eol,
                    .loc = .{
                        .start = self.index,
                        .end = self.index,
                    },
                },
                ' ', '\t' => {
                    self.index += 1;
                    result.loc.start = self.index;
                    continue :state .start;
                },
                '#' => {
                    while (self.buffer[self.index] != 0) self.index += 1;
                    result.loc.start = self.index;
                    continue :state .start;
                },
                '|' => {
                    result.tag = .pipe;
                    self.index += 1;
                    result.loc.end = self.index;
                    return result;
                },
                '~' => {
                    result.tag = .tilde;
                    self.index += 1;
                    result.loc.end = self.index;
                    return result;
                },
                '<' => {
                    result.tag = .redirect_in;
                    self.index += 1;
                    result.loc.end = self.index;
                    return result;
                },
                '>' => {
                    continue :state .redirect;
                },
                '1', '2' => {
                    if (self.buffer[self.index + 1] == '>') {
                        self.index += 1;
                        continue :state .start;
                    }
                    continue :state .literal;
                },
                '$' => {
                    self.index += 1;
                    if (self.buffer[self.index] == '{') {
                        self.index += 1;
                        continue :state .variable_braced;
                    } else if (self.buffer[self.index] == ' ' or
                        self.buffer[self.index] == 0)
                    {
                        continue :state .literal;
                    } else continue :state .variable;
                },
                '"' => {
                    self.index += 1;
                    continue :state .double_quote;
                },
                '\'' => {
                    self.index += 1;
                    continue :state .single_quote;
                },
                else => {
                    continue :state .literal;
                },
            },
            .invalid => {
                result.tag = .invalid;
                while (self.buffer[self.index] != ' ' and
                    self.buffer[self.index] != 0) self.index += 1;
                result.loc.end = self.index;
                return result;
            },
            .literal => switch (self.buffer[self.index]) {
                0, ' ', '\t', '|', '>', '<', '$', '"', '\'' => {
                    result.tag = .literal;
                    result.loc.end = self.index;
                    return result;
                },
                '\\' => {
                    self.index += 1;
                    if (self.buffer[self.index] != 0) self.index += 1;
                    continue :state .literal;
                },
                else => {
                    self.index += 1;
                    continue :state .literal;
                },
            },
            .double_quote => switch (self.buffer[self.index]) {
                0 => continue :state .invalid,
                '"' => {
                    self.index += 1;
                    result.tag = .literal;
                    result.loc.end = self.index;
                    return result;
                },
                '\\' => {
                    self.index += 1;
                    if (self.buffer[self.index] != 0) self.index += 1;
                    continue :state .double_quote;
                },
                else => {
                    self.index += 1;
                    continue :state .double_quote;
                },
            },
            .single_quote => switch (self.buffer[self.index]) {
                0 => continue :state .invalid,
                '\'' => {
                    self.index += 1;
                    result.tag = .literal;
                    result.loc.end = self.index;
                    return result;
                },
                else => {
                    self.index += 1;
                    continue :state .single_quote;
                },
            },
            .variable => switch (self.buffer[self.index]) {
                'a'...'z', 'A'...'Z', '0'...'9', '_' => {
                    self.index += 1;
                    continue :state .variable;
                },
                0, ' ', '\t', '|', '>', '<', '"', '\'' => {
                    result.tag = .variable;
                    result.loc.start += 1;
                    result.loc.end = self.index;
                    return result;
                },
                else => continue :state .invalid,
            },
            .variable_braced => switch (self.buffer[self.index]) {
                'a'...'z', 'A'...'Z', '0'...'9', '_' => {
                    self.index += 1;
                    continue :state .variable_braced;
                },
                '}' => {
                    self.index += 1;
                    result.tag = .variable;
                    result.loc.start += 2;
                    result.loc.end = self.index - 1;
                    return result;
                },
                else => continue :state .invalid,
            },
            .redirect => {
                self.index += 1;
                if (self.buffer[self.index] == '>') {
                    self.index += 1;
                    result.tag = .redirect_append;
                } else result.tag = .redirect_truncate;
                result.loc.end = self.index;
                return result;
            },
        }
    }
};

test "tokenizer" {
    const T = struct {
        fn check(input: [:0]const u8, expected_token_tags: []const Token.Tag) !void {
            var tokenizer: Tokenizer = .init(input);
            for (expected_token_tags) |want| {
                const got = tokenizer.next();
                try std.testing.expectEqual(want, got.tag);
            }
            const last_token = tokenizer.next();
            try std.testing.expectEqual(Token.Tag.eol, last_token.tag);
            try std.testing.expectEqual(input.len, last_token.loc.start);
            try std.testing.expectEqual(input.len, last_token.loc.end);
        }
    };

    try T.check(
        \\echo hello world!
    , &.{ .literal, .literal, .literal });

    try T.check(
        \\echo "hello    world! Yay!"
    , &.{ .literal, .literal });

    try T.check(
        \\echo $foo hello ${bar}_foo
    , &.{ .literal, .variable, .literal, .variable, .literal });

    try T.check(
        \\echo $hey2
    , &.{ .literal, .variable });

    try T.check(
        \\echo "hello
    , &.{ .literal, .invalid });

    try T.check(
        \\echo $foo-bar
    , &.{ .literal, .invalid });

    try T.check(
        \\echo ${foo-bar
    , &.{ .literal, .invalid });

    try T.check(
        \\echo ${foo-bar}
    , &.{ .literal, .invalid });

    try T.check(
        \\echo "hello           # " world ""
    , &.{ .literal, .literal, .literal, .literal });

    try T.check(
        \\echo \$hello
    , &.{ .literal, .literal });

    try T.check(
        \\|
    , &.{.pipe});

    try T.check(
        \\echo $
    , &.{ .literal, .literal });

    try T.check(
        \\echo hello\ world
    , &.{ .literal, .literal });

    try T.check(
        \\grep -i "hello" input.txt > matches.txt | wc -l
    , &.{
        .literal,
        .literal,
        .literal,
        .literal,
        .redirect_truncate,
        .literal,
        .pipe,
        .literal,
        .literal,
    });

    try T.check(
        \\echo "hello" $world world_${foo} > matches.txt | wc -l # This is so cool
    , &.{
        .literal,
        .literal,
        .variable,
        .literal,
        .variable,
        .redirect_truncate,
        .literal,
        .pipe,
        .literal,
        .literal,
    });
}

test "token loc" {
    var tokenizer: Tokenizer = .init("echo >> > 2>> 1>");
    var token = tokenizer.next();
    while (token.tag != .eol) {
        defer token = tokenizer.next();
        std.debug.print("{s:>8}: [{d:<2}, {d:>2}]\n", .{
            @tagName(token.tag),
            token.loc.start,
            token.loc.end,
        });
    }
    for (0..tokenizer.buffer.len) |i| {
        std.debug.print("{d} ", .{i});
    }
    std.debug.print("\n", .{});
    for (tokenizer.buffer, 0..) |char, i| {
        if (i < 10) {
            std.debug.print("{c} ", .{char});
        } else {
            std.debug.print("{c}  ", .{char});
        }
    }
    std.debug.print("\n", .{});
}
