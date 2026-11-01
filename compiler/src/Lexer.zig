const std = @import("std");
const Token = @import("Token.zig");

const Self = @This();

input: []const u8,
pos: usize = 0,
readPos: usize = 0,
ch: u8 = '\x00',
line: usize = 1,
line_start: usize = 0,
token_start: usize = 0,
previous_type: ?Token.TokenType = null,

pub fn init(input: []const u8) Self {
    var l = Self{
        .input = input,
    };

    l.readChar();

    return l;
}

fn readChar(self: *Self) void {
    if (self.readPos >= self.input.len) {
        self.ch = '\x00';
    } else {
        self.ch = self.input[self.readPos];
    }

    self.pos = self.readPos;
    self.readPos += 1;
}

pub fn nextToken(self: *Self) Token {
    const tok = self.readToken();
    self.previous_type = tok.type;
    return tok;
}

fn readToken(self: *Self) Token {
    var tok: Token = undefined;

    self.skipWhitespaceAndComments();
    self.token_start = self.pos;

    switch (self.ch) {
        '(' => {
            if (self.previous_type == .execute) return self.readExecuteSubcommands();
            tok = self.newToken(.left_paren, "(");
        },
        '@' => return self.readSelector(),
        ')' => tok = self.newToken(.right_paren, ")"),
        '{' => tok = self.newToken(.left_brace, "{"),
        '}' => tok = self.newToken(.right_brace, "}"),
        ',' => tok = self.newToken(.comma, ","),
        '.' => {
            if (self.previous_type == .selector and self.peekChar() == '$') return self.readEntityDataPath();
            if (self.peekChar() == '.') {
                self.readChar();
                tok = self.newToken(.dot_dot, "..");
            } else {
                tok = self.newToken(.dot, ".");
            }
        },
        '|' => tok = self.newToken(.pipe, "|"),
        '[' => tok = self.newToken(.left_bracket, "["),
        ']' => tok = self.newToken(.right_bracket, "]"),
        ':' => tok = self.newToken(.colon, ":"),
        '$', '#' => {
            const token_type: Token.TokenType = if (self.ch == '#') .score_identifier else .data_identifier;
            if (isLetter(self.peekChar())) {
                self.readChar();
                if (token_type == .data_identifier) return self.readDataPath(.data_identifier);
                return self.newToken(token_type, self.readIdentifier());
            }
            tok = self.newToken(.illegal, self.input[self.pos .. self.pos + 1]);
        },
        '-' => tok = self.newToken(.minus, "-"),
        '+' => tok = self.newToken(.plus, "+"),
        ';' => tok = self.newToken(.semicolon, ";"),
        '*' => tok = self.newToken(.star, "*"),
        '/' => {
            if (self.startsStatement()) {
                const text = self.readCommand() orelse return self.newToken(.unclosed, "\"");
                return self.newToken(.command, text);
            }
            tok = self.newToken(.slash, "/");
        },
        '%' => tok = self.newToken(.percent, "%"),
        '!' => {
            if (self.peekChar() == '=') {
                self.readChar();
                tok = self.newToken(.bang_eql, "!=");
            } else {
                tok = self.newToken(.bang, "!");
            }
        },
        '=' => {
            if (self.peekChar() == '=') {
                self.readChar();
                tok = self.newToken(.eql_eql, "==");
            } else {
                tok = self.newToken(.eql, "=");
            }
        },
        '<' => {
            if (self.peekChar() == '=') {
                self.readChar();
                tok = self.newToken(.less_eql, "<=");
            } else {
                tok = self.newToken(.less, "<");
            }
        },
        '>' => {
            if (self.peekChar() == '=') {
                self.readChar();
                tok = self.newToken(.greater_eql, ">=");
            } else {
                tok = self.newToken(.greater, ">");
            }
        },
        '"' => {
            const text = self.readString() orelse return self.newToken(.unclosed, "\"");
            tok = self.newToken(.string, text);
        },
        else => {
            if (isLetter(self.ch)) {
                const literal = self.readIdentifier();
                return self.newToken(Token.Keywords.get(literal) orelse .identifier, literal);
            } else if (std.ascii.isDigit(self.ch)) {
                return self.newToken(.number, self.readNumber());
            } else if (self.pos >= self.input.len) {
                return self.newToken(.eof, "\x00");
            } else {
                tok = self.newToken(.illegal, self.input[self.pos .. self.pos + 1]);
            }
        },
    }
    self.readChar();
    return tok;
}

fn newToken(self: *Self, t: Token.TokenType, literal: []const u8) Token {
    return Token.init(t, literal, self.line, self.token_start - self.line_start + 1);
}

// Division cannot follow these tokens, so a `/` here starts a command.
fn startsStatement(self: *Self) bool {
    const previous = self.previous_type orelse return true;
    return previous == .semicolon or previous == .left_brace or previous == .right_brace;
}

// Reads to the `;` that ends the command. A `;` inside quotes or brackets (NBT, JSON) is part of the text.
fn readCommand(self: *Self) ?[]const u8 {
    self.readChar();
    const text = self.readBalanced(';') orelse return null;
    return std.mem.trimEnd(u8, text, " \t\r");
}

// Reads `as @a at @s` from `execute (as @a at @s)`, to the matching `)`.
// The token starts at the text, so its column is the column of the first subcommand.
fn readExecuteSubcommands(self: *Self) Token {
    self.readChar();
    while (self.ch == ' ' or self.ch == '\t') self.readChar();
    self.token_start = self.pos;

    const text = self.readBalanced(')') orelse return self.newToken(.unclosed, "\"");
    if (self.ch != ')') {
        // Lex the rest of the line again as normal tokens, so a `{` on it still opens the body.
        self.readPos = self.token_start;
        self.readChar();
        return self.newToken(.unclosed, ")");
    }

    self.readChar();
    return self.newToken(.execute_subcommands, std.mem.trimEnd(u8, text, " \t\r"));
}

// Reads `@s` or `@a[tag=x,limit=1]`.
fn readSelector(self: *Self) Token {
    const is_selector = std.mem.indexOfScalar(u8, "aeprsn", self.peekChar()) != null and !isLetter(self.peekCharAt(2));
    if (!is_selector) {
        const tok = self.newToken(.illegal, "@");
        self.readChar();
        return tok;
    }

    self.readChar();
    self.readChar();
    if (self.ch == '[') {
        self.readChar();
        _ = self.readBalanced(']') orelse return self.newToken(.unclosed, "\"");
        if (self.ch != ']') return self.newToken(.unclosed, "]");
        self.readChar();
    }

    return self.newToken(.selector, self.input[self.token_start..self.pos]);
}

// Reads `.$Inventory[0].count` after a selector. The literal is the NBT path without `.$`.
fn readEntityDataPath(self: *Self) Token {
    self.readChar();
    self.readChar();
    return self.readDataPath(.entity_data);
}

// Reads an NBT path: keys, `.`, `[0]`, `[{Slot:0b}]` and `"quoted keys"`. A `.` that is not followed
// by a key ends the path, so `$a..` is still a range.
fn readDataPath(self: *Self, token_type: Token.TokenType) Token {
    const start = self.pos;
    var depth: usize = 0;
    var quote: ?u8 = null;

    while (self.ch != '\n' and self.ch != '\x00') : (self.readChar()) {
        if (quote) |q| {
            if (self.ch == '\\') {
                self.readChar();
            } else if (self.ch == q) {
                quote = null;
            }
            continue;
        }

        if (depth == 0 and self.ch == '.' and !isLetter(self.peekChar()) and self.peekChar() != '"') break;
        switch (self.ch) {
            '"', '\'' => quote = self.ch,
            '[', '{' => depth += 1,
            ']', '}' => {
                if (depth == 0) break;
                depth -= 1;
            },
            else => if (depth == 0 and !isLetter(self.ch) and !std.ascii.isDigit(self.ch) and self.ch != '.') break,
        }
    }

    if (quote != null) return self.newToken(.unclosed, "\"");
    if (depth > 0) return self.newToken(.unclosed, "]");
    if (self.pos == start) return self.newToken(.illegal, ".$");
    return self.newToken(token_type, self.input[start..self.pos]);
}

// Reads up to `end` outside quotes and brackets, or up to the end of the line.
// Returns null if a quote is still open.
fn readBalanced(self: *Self, end: u8) ?[]const u8 {
    const start = self.pos;
    var depth: usize = 0;
    var quote: ?u8 = null;

    while (self.ch != '\n' and self.ch != '\x00') : (self.readChar()) {
        if (quote) |q| {
            if (self.ch == '\\') {
                self.readChar();
            } else if (self.ch == q) {
                quote = null;
            }
            continue;
        }

        if (self.ch == end and depth == 0) break;
        switch (self.ch) {
            '"', '\'' => quote = self.ch,
            '[', '{', '(' => depth += 1,
            ']', '}', ')' => depth -|= 1,
            else => {},
        }
    }

    if (quote != null) return null;
    return self.input[start..self.pos];
}

fn isLetter(ch: u8) bool {
    return std.ascii.isAlphabetic(ch) or ch == '_';
}

fn readIdentifier(self: *Self) []const u8 {
    const start = self.pos;

    while (isLetter(self.ch) or (self.ch >= '0' and self.ch <= '9')) {
        self.readChar();
    }

    return self.input[start..self.pos];
}

fn readString(self: *Self) ?[]const u8 {
    const start = self.pos;

    self.readChar();

    while (self.ch != '"') : (self.readChar()) {
        if (self.pos >= self.input.len) return null;
        // The escaped character cannot end the string. The parser decodes the escape.
        if (self.ch == '\\') self.readChar();
    }

    return self.input[start + 1 .. self.pos];
}

fn readNumber(self: *Self) []const u8 {
    const start = self.pos;

    while (std.ascii.isDigit(self.ch)) {
        self.readChar();
    }

    return self.input[start..self.pos];
}

fn skipWhitespaceAndComments(self: *Self) void {
    while (true) {
        switch (self.ch) {
            ' ', '\t', '\r' => self.readChar(),
            '\n' => {
                self.line += 1;
                self.readChar();
                self.line_start = self.pos;
            },
            '/' => {
                if (self.peekChar() != '/') return;
                while (self.ch != '\n' and self.ch != '\x00') self.readChar();
            },
            else => return,
        }
    }
}

fn peekChar(self: *Self) u8 {
    return self.peekCharAt(1);
}

fn peekCharAt(self: *Self, distance: usize) u8 {
    const index = self.pos + distance;
    if (index >= self.input.len) return '\x00';

    return self.input[index];
}

test "skips comments" {
    var l = Self.init("// first\nvar // second\n");

    const tok = l.nextToken();
    try std.testing.expectEqual(.@"var", tok.type);
    try std.testing.expectEqual(.eof, l.nextToken().type);
}

test "reads slash" {
    var l = Self.init("a / b");

    _ = l.nextToken();
    try std.testing.expectEqual(.slash, l.nextToken().type);
}

test "reads commands and keeps division" {
    var l = Self.init("x = a / b; /give @s stone{a:[I;1]} 1;");

    for (0..3) |_| _ = l.nextToken();
    try std.testing.expectEqual(.slash, l.nextToken().type);
    _ = l.nextToken();
    try std.testing.expectEqual(.semicolon, l.nextToken().type);

    const command = l.nextToken();
    try std.testing.expectEqual(.command, command.type);
    try std.testing.expectEqualStrings("give @s stone{a:[I;1]} 1", command.literal);
    try std.testing.expectEqual(.semicolon, l.nextToken().type);
}

test "reads full string content" {
    var l = Self.init("\"hello\"");

    const tok = l.nextToken();
    try std.testing.expectEqual(.string, tok.type);
    try std.testing.expectEqualStrings("hello", tok.literal);
}

test "sets line on every token" {
    var l = Self.init("mcfun\nname\n42\n\"text\"");

    try std.testing.expectEqual(1, l.nextToken().line);
    try std.testing.expectEqual(2, l.nextToken().line);
    try std.testing.expectEqual(3, l.nextToken().line);
    try std.testing.expectEqual(4, l.nextToken().line);
}

test "reads illegal characters as tokens" {
    var l = Self.init("a \\ \"open");

    _ = l.nextToken();
    try std.testing.expectEqualStrings("\\", l.nextToken().literal);
    try std.testing.expectEqual(.unclosed, l.nextToken().type);
    try std.testing.expectEqual(.eof, l.nextToken().type);
}

test "reads null keyword" {
    var l = Self.init("null");

    try std.testing.expectEqual(.null, l.nextToken().type);
}

test "reads entity data paths after a selector" {
    var l = Self.init("@s.$Inventory[{Slot:0b}].count * 2; @p.$\"a.b\"");

    try std.testing.expectEqual(.selector, l.nextToken().type);
    const path = l.nextToken();
    try std.testing.expectEqual(.entity_data, path.type);
    try std.testing.expectEqualStrings("Inventory[{Slot:0b}].count", path.literal);
    try std.testing.expectEqual(.star, l.nextToken().type);
    _ = l.nextToken();
    _ = l.nextToken();
    _ = l.nextToken();
    try std.testing.expectEqualStrings("\"a.b\"", l.nextToken().literal);

    var data = Self.init("$stats.inventory[0].count + $a..");
    try std.testing.expectEqualStrings("stats.inventory[0].count", data.nextToken().literal);
    _ = data.nextToken();
    try std.testing.expectEqualStrings("a", data.nextToken().literal);
    try std.testing.expectEqual(.dot_dot, data.nextToken().type);
}
