const std = @import("std");
const Token = @import("Token.zig");

const Lexer = @This();

input: []const u8,
pos: usize = 0,
readPos: usize = 0,
ch: u8 = '\x00',
line: usize = 1,
line_start: usize = 0,
token_start: usize = 0,
previous_type: ?Token.TokenType = null,
// The number of `{` that are open, so that a `{` or `[` at the top level after a name starts a data file body.
brace_depth: usize = 0,
// The open `(` of an `if` or `while` condition, counted from its first `(`. Zero outside a condition.
condition_paren_depth: usize = 0,
// Added to the column of each token on the first line: the column where a `{{...}}` insert starts in its file.
first_line_column: usize = 0,

pub fn init(input: []const u8) Lexer {
    var l = Lexer{
        .input = input,
    };

    l.readChar();

    return l;
}

fn readChar(self: *Lexer) void {
    if (self.readPos >= self.input.len) {
        self.ch = '\x00';
    } else {
        self.ch = self.input[self.readPos];
    }

    self.pos = self.readPos;
    self.readPos += 1;
}

pub fn nextToken(self: *Lexer) Token {
    const tok = self.readToken();
    self.previous_type = tok.type;
    return tok;
}

fn readToken(self: *Lexer) Token {
    var tok: Token = undefined;

    self.skipWhitespaceAndComments();
    self.token_start = self.pos;

    switch (self.ch) {
        '(' => {
            if (self.previous_type == .execute) return self.readExecuteSubcommands();
            const opens_condition = self.previous_type == .@"if" or self.previous_type == .@"while";
            if (opens_condition or self.condition_paren_depth > 0) self.condition_paren_depth += 1;
            tok = self.newToken(.left_paren, "(");
        },
        '@' => return self.readSelector(),
        ')' => {
            self.condition_paren_depth -|= 1;
            tok = self.newToken(.right_paren, ")");
        },
        '{' => {
            const after_name = self.previous_type == .identifier or self.previous_type == .string;
            if (self.brace_depth == 0 and after_name) return self.readJsonBody();
            self.brace_depth += 1;
            tok = self.newToken(.left_brace, "{");
        },
        '}' => {
            self.brace_depth -|= 1;
            tok = self.newToken(.right_brace, "}");
        },
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
        '[' => {
            const after_name = self.previous_type == .identifier or self.previous_type == .string;
            if (self.brace_depth == 0 and after_name) return self.readJsonBody();
            tok = self.newToken(.left_bracket, "[");
        },
        ']' => tok = self.newToken(.right_bracket, "]"),
        ':' => tok = self.newToken(.colon, ":"),
        '$', '#' => {
            if (self.ch == '$' and self.peekChar() == '(') return self.readMacroKey();
            const token_type: Token.TokenType = if (self.ch == '#') .score_identifier else .data_identifier;
            if (isLetter(self.peekChar())) {
                self.readChar();
                // `#magic:mana` and `$magic:item.count` name a variable of another namespace.
                const start = self.pos;
                while (isLetter(self.ch) or std.ascii.isDigit(self.ch) or self.ch == '.') self.readChar();
                if (self.ch == ':' and isLetter(self.peekChar())) {
                    self.readChar();
                } else {
                    self.readPos = start;
                    self.readChar();
                }
                if (token_type == .data_identifier) return self.readDataPathFrom(start);
                _ = self.readIdentifier();
                return self.newToken(token_type, self.input[start..self.pos]);
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
                if (self.startsWithSource()) {
                    const text = self.readBalanced(';') orelse return self.newToken(.unclosed, "\"");
                    return self.newToken(.with_source, std.mem.trimEnd(u8, text, " \t\r"));
                }
                if (self.startsConditionCheck()) return self.newToken(.condition_text, self.readConditionText());
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

fn newToken(self: *Lexer, t: Token.TokenType, literal: []const u8) Token {
    const offset = if (self.line_start == 0) self.first_line_column else 0;
    return Token.init(t, literal, self.line, self.token_start - self.line_start + 1 + offset);
}

// Division cannot follow these tokens, so a `/` here starts a command.
fn startsStatement(self: *Lexer) bool {
    const previous = self.previous_type orelse return true;
    return previous == .semicolon or previous == .left_brace or previous == .right_brace;
}

// Reads to the `;` that ends the command. A `;` inside quotes or brackets (NBT, JSON) is part of the text.
fn readCommand(self: *Lexer) ?[]const u8 {
    self.readChar();
    const text = self.readBalanced(';') orelse return null;
    return std.mem.trimEnd(u8, text, " \t\r");
}

// Reads `as @a at @s` from `execute (as @a at @s)`, to the matching `)`.
// The token starts at the text, so its column is the column of the first subcommand.
fn readExecuteSubcommands(self: *Lexer) Token {
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

// Reads `$(name)`. The literal is the name.
fn readMacroKey(self: *Lexer) Token {
    self.readChar();
    self.readChar();
    const name = self.readIdentifier();
    if (name.len == 0 or self.ch != ')') return self.newToken(.illegal, "$(");
    self.readChar();
    return self.newToken(.macro_key, name);
}

// `entity` or `block` right after `with`.
fn startsWithSource(self: *Lexer) bool {
    if (self.previous_type != .with) return false;
    var end = self.pos;
    while (end < self.input.len and isLetter(self.input[end])) end += 1;
    const word = self.input[self.pos..end];
    return std.mem.eql(u8, word, "entity") or std.mem.eql(u8, word, "block");
}

// Reads `@s` or `@a[tag=x,limit=1]`.
fn readSelector(self: *Lexer) Token {
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
fn readEntityDataPath(self: *Lexer) Token {
    self.readChar();
    self.readChar();
    return self.readDataPath(.entity_data);
}

// Reads an NBT path: keys, `.`, `[0]`, `[{Slot:0b}]` and `"quoted keys"`. A `.` that is not followed
// by a key ends the path, so `$a..` is still a range.
fn readDataPath(self: *Lexer, token_type: Token.TokenType) Token {
    return self.readDataPathAt(token_type, self.pos);
}

fn readDataPathFrom(self: *Lexer, start: usize) Token {
    return self.readDataPathAt(.data_identifier, start);
}

// `start` is where the token text starts, which can be before the current character (a `ns:` prefix).
fn readDataPathAt(self: *Lexer, token_type: Token.TokenType, start: usize) Token {
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

// The `execute if` subcommands of Minecraft 26.3. In a condition, `block ~ ~-1 ~ stone` is raw text.
const condition_words = std.StaticStringMap(void).initComptime(.{
    .{"biome"}, .{"block"},  .{"blocks"},    .{"data"},  .{"dimension"}, .{"entity"},    .{"function"},
    .{"items"}, .{"loaded"}, .{"predicate"}, .{"score"}, .{"slots"},     .{"stopwatch"},
});

// A check starts a condition part (after `(`, `and`, `or` or `!`) with one of the words, then a space and
// something that is not an operator. So `block == 1` and `(block)` still read `block` as a name.
fn startsConditionCheck(self: *Lexer) bool {
    if (self.condition_paren_depth == 0) return false;
    const previous = self.previous_type orelse return false;
    if (previous != .left_paren and previous != .@"and" and previous != .@"or" and previous != .bang) return false;

    var end = self.pos;
    while (end < self.input.len and isLetter(self.input[end])) end += 1;
    if (!condition_words.has(self.input[self.pos..end])) return false;
    if (end >= self.input.len or self.input[end] != ' ') return false;
    while (end < self.input.len and self.input[end] == ' ') end += 1;
    if (end >= self.input.len) return false;
    return std.mem.indexOfScalar(u8, "=<>!)+-*/%,;", self.input[end]) == null;
}

// Reads to the `)` that closes the condition part, or to an `and` or `or` word, outside brackets and quotes.
fn readConditionText(self: *Lexer) []const u8 {
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
        switch (self.ch) {
            '"', '\'' => quote = self.ch,
            '[', '{', '(' => depth += 1,
            ']', '}' => depth -|= 1,
            ')' => if (depth == 0) break else {
                depth -= 1;
            },
            ' ' => if (depth == 0 and (self.isWordAhead("and") or self.isWordAhead("or"))) break,
            else => {},
        }
    }
    return std.mem.trimEnd(u8, self.input[start..self.pos], " ");
}

fn isWordAhead(self: *Lexer, word: []const u8) bool {
    const start = self.pos + 1;
    const end = start + word.len;
    if (end > self.input.len or !std.mem.eql(u8, self.input[start..end], word)) return false;
    return end == self.input.len or !isLetter(self.input[end]) and !std.ascii.isDigit(self.input[end]);
}

// Reads `{ ... }` or `[ ... ]` over many lines, to the bracket that closes the first one. Braces in JSON strings do not count.
fn readJsonBody(self: *Lexer) Token {
    const start = self.pos;
    const start_line = self.line;
    const start_column = self.token_start - self.line_start + 1;
    var depth: usize = 0;
    var in_string = false;

    while (self.ch != '\x00') : (self.readChar()) {
        if (self.ch == '\n') {
            self.line += 1;
            self.line_start = self.pos + 1;
        }
        if (in_string) {
            if (self.ch == '\\') {
                self.readChar();
            } else if (self.ch == '"') {
                in_string = false;
            }
            continue;
        }
        switch (self.ch) {
            '"' => in_string = true,
            '{', '[' => depth += 1,
            '}', ']' => {
                depth -|= 1;
                if (depth == 0) {
                    self.readChar();
                    return Token.init(.json_body, self.input[start..self.pos], start_line, start_column);
                }
            },
            else => {},
        }
    }
    return Token.init(.unclosed, "}", start_line, start_column);
}

// Reads up to `end` outside quotes and brackets, or up to the end of the line.
// Returns null if a quote is still open.
fn readBalanced(self: *Lexer, end: u8) ?[]const u8 {
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

fn readIdentifier(self: *Lexer) []const u8 {
    const start = self.pos;

    while (isLetter(self.ch) or (self.ch >= '0' and self.ch <= '9')) {
        self.readChar();
    }

    return self.input[start..self.pos];
}

fn readString(self: *Lexer) ?[]const u8 {
    const start = self.pos;

    self.readChar();

    while (self.ch != '"') : (self.readChar()) {
        // A string is one line, because it ends up in a one-line command or in SNBT.
        if (self.ch == '\n' or self.pos >= self.input.len) return null;
        // The escaped character cannot end the string. The parser decodes the escape.
        if (self.ch == '\\' and self.peekChar() != '\n') self.readChar();
    }

    return self.input[start + 1 .. self.pos];
}

// Reads an SNBT number: `5`, `0.05`, `0.05f` or `1b`. A `.` needs a digit after it, so `1..5` is still a range.
fn readNumber(self: *Lexer) []const u8 {
    const start = self.pos;

    while (std.ascii.isDigit(self.ch)) self.readChar();
    if (self.ch == '.' and std.ascii.isDigit(self.peekChar())) {
        self.readChar();
        while (std.ascii.isDigit(self.ch)) self.readChar();
    }

    const next = self.peekChar();
    const ends_after = !isLetter(next) and !std.ascii.isDigit(next);
    if (std.mem.indexOfScalar(u8, "bBsSlLfFdD", self.ch) != null and ends_after) self.readChar();

    return self.input[start..self.pos];
}

fn skipWhitespaceAndComments(self: *Lexer) void {
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

fn peekChar(self: *Lexer) u8 {
    return self.peekCharAt(1);
}

fn peekCharAt(self: *Lexer, distance: usize) u8 {
    const index = self.pos + distance;
    if (index >= self.input.len) return '\x00';

    return self.input[index];
}

test "reads a Minecraft check in a condition up to 'and'" {
    var l = Lexer.init("if (block ~ ~-1 ~ stone[a=b] and #a > 1) {} if (block == 1)");
    try std.testing.expectEqual(.@"if", l.nextToken().type);
    try std.testing.expectEqual(.left_paren, l.nextToken().type);
    const check = l.nextToken();
    try std.testing.expectEqual(.condition_text, check.type);
    try std.testing.expectEqualStrings("block ~ ~-1 ~ stone[a=b]", check.literal);
    try std.testing.expectEqual(.@"and", l.nextToken().type);
    for (0..8) |_| _ = l.nextToken();
    try std.testing.expectEqual(.identifier, l.nextToken().type);
}

test "reads a data file body over many lines" {
    var l = Lexer.init("predicate p {\n  \"a\": \"}\\\"{\",\n  \"b\": [1, {}]\n}\nmcfun");
    try std.testing.expectEqual(.identifier, l.nextToken().type);
    try std.testing.expectEqual(.identifier, l.nextToken().type);
    const body = l.nextToken();
    try std.testing.expectEqual(.json_body, body.type);
    try std.testing.expectEqualStrings("{\n  \"a\": \"}\\\"{\",\n  \"b\": [1, {}]\n}", body.literal);
    const after = l.nextToken();
    try std.testing.expectEqual(.mcfun, after.type);
    try std.testing.expectEqual(5, after.line);

    var unclosed = Lexer.init("recipe r { \"a\": 1");
    _ = unclosed.nextToken();
    _ = unclosed.nextToken();
    try std.testing.expectEqual(.unclosed, unclosed.nextToken().type);
}

test "skips comments" {
    var l = Lexer.init("// first\nvar // second\n");

    const tok = l.nextToken();
    try std.testing.expectEqual(.@"var", tok.type);
    try std.testing.expectEqual(.eof, l.nextToken().type);
}

test "reads commands and keeps division" {
    var l = Lexer.init("x = a / b; /give @s stone{a:[I;1]} 1;");

    for (0..3) |_| _ = l.nextToken();
    try std.testing.expectEqual(.slash, l.nextToken().type);
    _ = l.nextToken();
    try std.testing.expectEqual(.semicolon, l.nextToken().type);

    const command = l.nextToken();
    try std.testing.expectEqual(.command, command.type);
    try std.testing.expectEqualStrings("give @s stone{a:[I;1]} 1", command.literal);
    try std.testing.expectEqual(.semicolon, l.nextToken().type);
}

test "reads illegal characters as tokens" {
    var l = Lexer.init("a \\ \"open");

    _ = l.nextToken();
    try std.testing.expectEqualStrings("\\", l.nextToken().literal);
    try std.testing.expectEqual(.unclosed, l.nextToken().type);
    try std.testing.expectEqual(.eof, l.nextToken().type);
}

test "a string ends at the end of its line" {
    var l = Lexer.init("\"a\nb");

    try std.testing.expectEqual(.unclosed, l.nextToken().type);
    const next = l.nextToken();
    try std.testing.expectEqualStrings("b", next.literal);
    try std.testing.expectEqual(2, next.line);
}

test "reads entity data paths after a selector" {
    var l = Lexer.init("@s.$Inventory[{Slot:0b}].count * 2; @p.$\"a.b\"");

    try std.testing.expectEqual(.selector, l.nextToken().type);
    const path = l.nextToken();
    try std.testing.expectEqual(.entity_data, path.type);
    try std.testing.expectEqualStrings("Inventory[{Slot:0b}].count", path.literal);
    try std.testing.expectEqual(.star, l.nextToken().type);
    _ = l.nextToken();
    _ = l.nextToken();
    _ = l.nextToken();
    try std.testing.expectEqualStrings("\"a.b\"", l.nextToken().literal);

    var data = Lexer.init("$stats.inventory[0].count + $a..");
    try std.testing.expectEqualStrings("stats.inventory[0].count", data.nextToken().literal);
    _ = data.nextToken();
    try std.testing.expectEqualStrings("a", data.nextToken().literal);
    try std.testing.expectEqual(.dot_dot, data.nextToken().type);
}
