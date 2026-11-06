const std = @import("std");
const Ast = @import("Ast.zig");
const Lexer = @import("Lexer.zig");
const Token = @import("Token.zig");

const Self = @This();

pub const ParseError = std.mem.Allocator.Error;

pub const Error = struct {
    line: usize,
    column: ?usize = null,
    message: []const u8,
};

const Precedence = enum {
    lowest,
    @"or",
    @"and",
    equals,
    less_greater,
    sum,
    product,
    prefix,
    call,
};

gpa: std.mem.Allocator,
lexer: Lexer,
current: Token = undefined,
peek: Token = undefined,
errors: std.ArrayList(Error) = .empty,
// What the end of the input is called in a message. An insert has its own.
end_of_input: []const u8 = "end of file",

pub fn init(gpa: std.mem.Allocator, lexer: Lexer) ParseError!Self {
    var p = Self{
        .gpa = gpa,
        .lexer = lexer,
    };

    try p.nextToken();
    try p.nextToken();

    return p;
}

pub fn parseProgram(self: *Self) ParseError!Ast.Program {
    var namespace: ?Ast.Import = null;
    if (self.currentIs(.namespace)) {
        namespace = try self.parseNamespaceStatement();
        try self.nextToken();
    }
    var imports: std.ArrayList(Ast.Import) = .empty;
    var functions: std.ArrayList(Ast.Function) = .empty;
    var globals: std.ArrayList(Ast.Global) = .empty;
    var data_files: std.ArrayList(Ast.DataFile) = .empty;

    while (!self.currentIs(.eof)) {
        if (self.currentIs(.namespace)) {
            try self.addError("'namespace' must be the first statement of the file", .{});
            try self.skipToDeclaration();
        } else if (self.currentIs(.import)) {
            if (try self.parseImport()) |import| {
                try imports.append(self.gpa, import);
            } else {
                try self.skipToDeclaration();
            }
        } else if (self.currentIs(.@"var")) {
            const line = self.current.line;
            const column = self.current.column;
            if (try self.parseVarStatement()) |kind| {
                try globals.append(self.gpa, .{ .decl = kind.var_decl, .line = line, .column = column });
            } else {
                try self.skipToDeclaration();
            }
        } else if (self.currentIs(.identifier)) {
            if (try self.parseDataFile()) |data_file| {
                try data_files.append(self.gpa, data_file);
            } else {
                try self.skipToDeclaration();
            }
        } else if (try self.parseFunction()) |function| {
            try functions.append(self.gpa, function);
        } else {
            try self.skipToDeclaration();
        }
        try self.nextToken();
    }

    return .{
        .namespace = namespace,
        .imports = try imports.toOwnedSlice(self.gpa),
        .functions = try functions.toOwnedSlice(self.gpa),
        .globals = try globals.toOwnedSlice(self.gpa),
        .data_files = try data_files.toOwnedSlice(self.gpa),
    };
}

// `import magic;`
fn parseImport(self: *Self) ParseError!?Ast.Import {
    const line = self.current.line;
    const column = self.current.column;
    if (self.peekIs(.string)) {
        try self.addError("imports are by namespace: 'import magic;'. A file is part of the pack when it is in src/", .{});
        return null;
    }
    if (!try self.expectPeek(.identifier)) return null;
    const name = try self.parseNamespaceName() orelse return null;
    if (!try self.expectPeek(.semicolon)) return null;
    return .{ .name = name, .line = line, .column = column };
}

// `namespace combat;`
fn parseNamespaceStatement(self: *Self) ParseError!?Ast.Import {
    const line = self.current.line;
    const column = self.current.column;
    if (!try self.expectPeek(.identifier)) return null;
    const name = try self.parseNamespaceName() orelse return null;
    if (!try self.expectPeek(.semicolon)) return null;
    return .{ .name = name, .line = line, .column = column };
}

// `bs.math`: identifiers joined by `.`, starting at the current token.
fn parseNamespaceName(self: *Self) ParseError!?[]const u8 {
    var name: std.ArrayList(u8) = .empty;
    try name.appendSlice(self.gpa, self.current.literal);
    while (self.peekIs(.dot)) {
        try self.nextToken();
        if (!try self.expectPeek(.identifier)) return null;
        try name.print(self.gpa, ".{s}", .{self.current.literal});
    }
    return name.items;
}

// `predicate isSneaking { ... }` or `lootTable "minecraft:entities/zombie" { ... }`. The Compiler checks the type word.
fn parseDataFile(self: *Self) ParseError!?Ast.DataFile {
    const type_word = self.current.literal;
    const line = self.current.line;
    const column = self.current.column;

    try self.nextToken();
    const name: Ast.DataFile.Name = switch (self.current.type) {
        .identifier => .{ .identifier = self.current.literal },
        .string => .{ .id = try self.decodeString(self.current.literal) orelse return null },
        else => {
            try self.addError("expected a name after '{s}', found {s}", .{ type_word, try self.describe(self.current) });
            return null;
        },
    };
    if (!self.peekIs(.json_body)) {
        if (self.peekIs(.unclosed)) {
            try self.addError("the JSON of {s} '{s}' is not closed", .{ type_word, self.current.literal });
        } else {
            try self.addError("expected the JSON of {s} '{s}' (an object or a list), found {s}", .{ type_word, self.current.literal, try self.describe(self.peek) });
        }
        return null;
    }
    try self.nextToken();

    return .{
        .type_word = type_word,
        .name = name,
        .json = self.current.literal,
        .line = line,
        .column = column,
        .json_line = self.current.line,
        .json_column = self.current.column,
    };
}

fn parseFunction(self: *Self) ParseError!?Ast.Function {
    if (!self.currentIs(.mcfun)) {
        try self.addError("expected 'import', 'var', 'mcfun' or a data file, found {s}", .{try self.describe(self.current)});
        return null;
    }
    const line = self.current.line;

    if (!try self.expectPeek(.identifier)) return null;
    const name = self.current.literal;

    if (!try self.expectPeek(.left_paren)) return null;
    if (!self.peekIs(.right_paren)) {
        try self.nextToken();
        try self.addError("an mcfun has no parameter list. Pass a compound with 'f() with {{name: ...}}' and read it with '$(name)'", .{});
        return null;
    }
    try self.nextToken();

    if (!try self.expectPeek(.left_brace)) return null;
    const body = try self.parseBlock() orelse return null;

    return .{
        .name = name,
        .body = body,
        .line = line,
    };
}

fn parseBlock(self: *Self) ParseError!?[]const Ast.Stmt {
    var statements: std.ArrayList(Ast.Stmt) = .empty;

    try self.nextToken();

    while (!self.currentIs(.right_brace)) {
        if (self.currentIs(.eof)) {
            try self.addError("expected '}}', found {s}", .{self.end_of_input});
            return null;
        }

        if (try self.parseStatement()) |statement| {
            try statements.append(self.gpa, statement);
        } else {
            try self.skipStatement();
        }
        try self.nextToken();
    }

    return try statements.toOwnedSlice(self.gpa);
}

// Skips the rest of a broken statement, so one mistake gives one error.
fn skipStatement(self: *Self) ParseError!void {
    var depth: usize = 0;

    while (!self.currentIs(.eof)) {
        switch (self.current.type) {
            .left_brace => depth += 1,
            .right_brace => depth -|= 1,
            .semicolon => if (depth == 0) return,
            else => {},
        }
        if (depth == 0 and self.peekIs(.right_brace)) return;
        try self.nextToken();
    }
}

// Skips the rest of a broken declaration, so a statement in its body is not read as a declaration. It stops
// after the `;`, `}` or JSON body that ends the declaration, or before a word that starts a new one.
fn skipToDeclaration(self: *Self) ParseError!void {
    var depth: usize = if (self.currentIs(.left_brace)) 1 else 0;

    while (!self.peekIs(.eof)) {
        const starts_declaration = self.peekIs(.import) or self.peekIs(.@"var") or self.peekIs(.mcfun);
        if (depth == 0 and starts_declaration) return;

        const ends_declaration = switch (self.peek.type) {
            .left_brace => blk: {
                depth += 1;
                break :blk false;
            },
            .right_brace => blk: {
                depth -|= 1;
                break :blk depth == 0;
            },
            .semicolon, .json_body => depth == 0,
            else => false,
        };
        try self.nextToken();
        if (ends_declaration) return;
    }
}

fn parseStatement(self: *Self) ParseError!?Ast.Stmt {
    const line = self.current.line;
    const column = self.current.column;
    const kind = try self.parseStatementKind() orelse return null;

    return .{ .line = line, .column = column, .kind = kind };
}

fn parseStatementKind(self: *Self) ParseError!?Ast.Stmt.Kind {
    const is_assignment = (self.currentIdentifier() != null and self.peekIs(.eql)) or self.currentIs(.selector);
    if (is_assignment) return self.parseAssignStatement();

    return switch (self.current.type) {
        .@"var" => self.parseVarStatement(),
        .@"return" => self.parseReturnStatement(),
        .@"break", .@"continue" => blk: {
            const kind: Ast.Stmt.Kind = if (self.currentIs(.@"break")) .@"break" else .@"continue";
            if (!try self.expectPeek(.semicolon)) return null;
            break :blk kind;
        },
        .@"if" => self.parseIfStatement(),
        .@"for" => self.parseForStatement(),
        .@"while" => self.parseWhileStatement(),
        .command => self.parseCommandStatement(),
        .execute => self.parseExecuteStatement(),
        else => self.parseExpressionStatement(),
    };
}

fn parseCommandStatement(self: *Self) ParseError!?Ast.Stmt.Kind {
    const command: Ast.Command = .{
        .text = self.current.literal,
        .parts = try self.parseCommandParts(self.current.literal, self.current.column + 1) orelse return null,
    };
    if (!try self.expectPeek(.semicolon)) return null;

    return .{ .command = command };
}

// Splits command text into plain text and `{{expr}}` inserts.
// `text_column` is the column where `text` starts in the file, so an expression in an insert has its real position.
fn parseCommandParts(self: *Self, text: []const u8, text_column: usize) ParseError!?[]const Ast.CommandPart {
    var parts: std.ArrayList(Ast.CommandPart) = .empty;
    var pos: usize = 0;

    while (std.mem.indexOfPos(u8, text, pos, "{{")) |open| {
        const close = std.mem.indexOfPos(u8, text, open + 2, "}}") orelse {
            try self.addError("missing '}}}}' in command", .{});
            return null;
        };

        if (open > pos) try parts.append(self.gpa, .{ .offset = pos, .content = .{ .text = text[pos..open] } });
        const expression = try self.parseInsert(text[open + 2 .. close], text_column + open + 2) orelse return null;
        try parts.append(self.gpa, .{ .offset = open, .content = .{ .insert = expression } });
        pos = close + 2;
    }

    if (pos < text.len) try parts.append(self.gpa, .{ .offset = pos, .content = .{ .text = text[pos..] } });
    return try parts.toOwnedSlice(self.gpa);
}

fn parseInsert(self: *Self, source: []const u8, column: usize) ParseError!?*Ast.Expr {
    var lexer = Lexer.init(source);
    lexer.line = self.current.line;
    lexer.first_line_column = column - 1;
    var insert_parser = try Self.init(self.gpa, lexer);
    insert_parser.end_of_input = "the end of '{{...}}'";
    const expression = try insert_parser.parseExpression(.lowest);

    if (expression != null and !insert_parser.peekIs(.eof)) {
        try insert_parser.addError("unexpected {s} in '{{{{...}}}}'", .{try insert_parser.describe(insert_parser.peek)});
    }
    for (insert_parser.errors.items) |err| try self.appendError(err);

    if (insert_parser.errors.items.len > 0) return null;
    return expression;
}

fn parseExecuteStatement(self: *Self) ParseError!?Ast.Stmt.Kind {
    if (!try self.expectPeek(.execute_subcommands)) return null;
    const subcommands_column = self.current.column;
    const subcommands = try self.parseCommandParts(self.current.literal, subcommands_column) orelse return null;

    if (!try self.expectPeek(.left_brace)) return null;
    const body = try self.parseBlock() orelse return null;

    return .{ .execute = .{
        .subcommands = subcommands,
        .subcommands_column = subcommands_column,
        .body = body,
    } };
}

fn parseVarStatement(self: *Self) ParseError!?Ast.Stmt.Kind {
    try self.nextToken();
    const target = self.currentIdentifier() orelse {
        try self.addError("expected a variable name, found {s}", .{try self.describe(self.current)});
        return null;
    };

    if (!try self.expectPeek(.eql)) return null;
    try self.nextToken();

    const value = try self.parseExpression(.lowest) orelse return null;
    if (!try self.expectPeek(.semicolon)) return null;

    return .{ .var_decl = .{ .target = target, .value = value } };
}

fn parseAssignStatement(self: *Self) ParseError!?Ast.Stmt.Kind {
    const target = try self.parseIdentifier() orelse return null;

    if (!try self.expectPeek(.eql)) return null;
    try self.nextToken();

    const value = try self.parseExpression(.lowest) orelse return null;
    if (!try self.expectPeek(.semicolon)) return null;

    return .{ .assign = .{ .target = target, .value = value } };
}

fn parseReturnStatement(self: *Self) ParseError!?Ast.Stmt.Kind {
    if (self.peekIs(.semicolon)) {
        try self.nextToken();
        return .{ .@"return" = null };
    }

    try self.nextToken();

    const value = try self.parseExpression(.lowest) orelse return null;
    if (!try self.expectPeek(.semicolon)) return null;

    return .{ .@"return" = value };
}

fn parseIfStatement(self: *Self) ParseError!?Ast.Stmt.Kind {
    const condition = try self.parseCondition() orelse return null;

    if (!try self.expectPeek(.left_brace)) return null;
    const then_body = try self.parseBlock() orelse return null;

    var else_body: ?[]const Ast.Stmt = null;

    if (self.peekIs(.@"else")) {
        try self.nextToken();

        if (self.peekIs(.@"if")) {
            try self.nextToken();
            const else_if = try self.parseStatement() orelse return null;
            else_body = try self.gpa.dupe(Ast.Stmt, &.{else_if});
        } else {
            if (!try self.expectPeek(.left_brace)) return null;
            else_body = try self.parseBlock() orelse return null;
        }
    }

    return .{ .@"if" = .{
        .condition = condition,
        .then_body = then_body,
        .else_body = else_body,
    } };
}

fn parseForStatement(self: *Self) ParseError!?Ast.Stmt.Kind {
    if (!try self.expectPeek(.left_paren)) return null;
    try self.nextToken();
    const start = try self.parseExpression(.lowest) orelse return null;

    if (!try self.expectPeek(.dot_dot)) return null;
    try self.nextToken();
    const end = try self.parseExpression(.lowest) orelse return null;

    if (!try self.expectPeek(.right_paren)) return null;

    if (!try self.expectPeek(.pipe)) return null;
    if (!try self.expectPeek(.identifier)) return null;
    const capture = self.current.literal;
    if (!try self.expectPeek(.pipe)) return null;

    if (!try self.expectPeek(.left_brace)) return null;
    const body = try self.parseBlock() orelse return null;

    return .{ .@"for" = .{
        .start = start,
        .end = end,
        .capture = capture,
        .body = body,
    } };
}

fn parseWhileStatement(self: *Self) ParseError!?Ast.Stmt.Kind {
    const condition = try self.parseCondition() orelse return null;

    if (!try self.expectPeek(.left_brace)) return null;
    const body = try self.parseBlock() orelse return null;

    return .{ .@"while" = .{ .condition = condition, .body = body } };
}

fn parseCondition(self: *Self) ParseError!?*Ast.Expr {
    if (!try self.expectPeek(.left_paren)) return null;
    try self.nextToken();

    const condition = try self.parseExpression(.lowest) orelse return null;
    if (!try self.expectPeek(.right_paren)) return null;

    return condition;
}

fn parseExpressionStatement(self: *Self) ParseError!?Ast.Stmt.Kind {
    const expression = try self.parseExpression(.lowest) orelse return null;
    if (!try self.expectPeek(.semicolon)) return null;

    return .{ .expression = expression };
}

fn parseExpression(self: *Self, precedence: Precedence) ParseError!?*Ast.Expr {
    var left = try self.parsePrefix() orelse return null;

    while (!self.peekIs(.semicolon) and @backingInt(precedence) < @backingInt(self.peekPrecedence())) {
        try self.nextToken();
        left = try self.parseInfix(left) orelse return null;
    }

    return left;
}

fn parsePrefix(self: *Self) ParseError!?*Ast.Expr {
    const start = self.current;
    const kind: Ast.Expr.Kind = switch (self.current.type) {
        .selector => if (self.peekIs(.dot) or self.peekIs(.entity_data))
            .{ .identifier = try self.parseIdentifier() orelse return null }
        else
            .{ .selector = self.current.literal },
        .identifier, .score_identifier, .data_identifier => .{ .identifier = try self.parseIdentifier() orelse return null },
        .string => .{ .string = try self.decodeString(self.current.literal) orelse return null },
        .number => try self.parseNumber() orelse return null,
        .left_bracket => .{ .list = try self.parseListLiteral() orelse return null },
        .left_brace => .{ .compound = try self.parseCompoundLiteral() orelse return null },
        .true => .{ .boolean = true },
        .false => .{ .boolean = false },
        .null => .null,
        .bang, .minus => blk: {
            const op = self.current.type;
            try self.nextToken();
            const operand = try self.parseExpression(.prefix) orelse return null;
            break :blk .{ .prefix = .{ .op = op, .operand = operand } };
        },
        .self => {
            try self.addError("'self:' is only for ids in commands and checks. In code, a plain name already means this namespace", .{});
            return null;
        },
        .condition_text => .{ .minecraft_check = try self.parseCommandParts(self.current.literal, self.current.column) orelse return null },
        .macro_key => .{ .macro_key = self.current.literal },
        .left_paren => return self.parseGroupedExpression(),
        else => {
            try self.addError("expected an expression, found {s}", .{try self.describe(self.current)});
            return null;
        },
    };

    return try self.createExpr(start.line, start.column, kind);
}

fn parseNumber(self: *Self) ParseError!?Ast.Expr.Kind {
    const literal = self.current.literal;
    const number_type: ?Ast.NumberType = switch (std.ascii.toLower(literal[literal.len - 1])) {
        'b' => .byte,
        's' => .short,
        'l' => .long,
        'f' => .float,
        'd' => .double,
        else => null,
    };
    const number: Ast.TypedNumber = .{ .text = if (number_type == null) literal else literal[0 .. literal.len - 1], .type = number_type };

    if (number_type == null and !number.hasFraction()) {
        return .{ .number = std.fmt.parseInt(i64, literal, 10) catch {
            try self.addError("number '{s}' is too large", .{literal});
            return null;
        } };
    }
    if (number.hasFraction() and (number_type == .byte or number_type == .short or number_type == .long)) {
        try self.addError("a {t} is a whole number, so '{s}' cannot have a fraction", .{ number_type.?, literal });
        return null;
    }
    return .{ .typed_number = number };
}

// Only `\"` and `\\` are allowed, because a string ends up in a one-line command or in SNBT.
fn decodeString(self: *Self, literal: []const u8) ParseError!?[]const u8 {
    if (std.mem.indexOfScalar(u8, literal, '\\') == null) return literal;

    var decoded: std.ArrayList(u8) = .empty;
    var index: usize = 0;
    while (index < literal.len) : (index += 1) {
        if (literal[index] != '\\') {
            try decoded.append(self.gpa, literal[index]);
            continue;
        }

        index += 1;
        const escaped = literal[index];
        if (escaped != '"' and escaped != '\\') {
            try self.addError("unknown escape '\\{c}' in string. Only \\\" and \\\\ are allowed", .{escaped});
            return null;
        }
        try decoded.append(self.gpa, escaped);
    }
    return try decoded.toOwnedSlice(self.gpa);
}

fn parseGroupedExpression(self: *Self) ParseError!?*Ast.Expr {
    try self.nextToken();

    const expression = try self.parseExpression(.lowest) orelse return null;
    if (!try self.expectPeek(.right_paren)) return null;

    return expression;
}

fn parseInfix(self: *Self, left: *Ast.Expr) ParseError!?*Ast.Expr {
    if (self.currentIs(.left_paren)) return self.parseCallExpression(left);

    const op = self.current.type;
    const precedence = self.currentPrecedence();
    try self.nextToken();

    const right = try self.parseExpression(precedence) orelse return null;

    return try self.createExpr(left.line, left.column, .{ .infix = .{ .op = op, .left = left, .right = right } });
}

// `[1, 2, 3]`
fn parseListLiteral(self: *Self) ParseError!?[]const *Ast.Expr {
    var elements: std.ArrayList(*Ast.Expr) = .empty;
    while (!self.peekIs(.right_bracket)) {
        try self.nextToken();
        try elements.append(self.gpa, try self.parseExpression(.lowest) orelse return null);
        if (!self.peekIs(.comma)) break;
        try self.nextToken();
    }
    if (!try self.expectPeek(.right_bracket)) return null;
    return try elements.toOwnedSlice(self.gpa);
}

// `{hp: 20, "custom name": "x"}`
fn parseCompoundLiteral(self: *Self) ParseError!?[]const Ast.Entry {
    var entries: std.ArrayList(Ast.Entry) = .empty;
    while (!self.peekIs(.right_brace)) {
        try self.nextToken();
        const key = switch (self.current.type) {
            .identifier => self.current.literal,
            .string => try self.decodeString(self.current.literal) orelse return null,
            else => {
                try self.addError("expected a key, found {s}", .{try self.describe(self.current)});
                return null;
            },
        };
        if (!try self.expectPeek(.colon)) return null;
        try self.nextToken();
        try entries.append(self.gpa, .{ .key = key, .value = try self.parseExpression(.lowest) orelse return null });
        if (!self.peekIs(.comma)) break;
        try self.nextToken();
    }
    if (!try self.expectPeek(.right_brace)) return null;
    return try entries.toOwnedSlice(self.gpa);
}

fn parseCallExpression(self: *Self, callee: *Ast.Expr) ParseError!?*Ast.Expr {
    var args: std.ArrayList(*Ast.Expr) = .empty;

    if (self.peekIs(.right_paren)) {
        try self.nextToken();
    } else {
        try self.nextToken();
        try args.append(self.gpa, try self.parseExpression(.lowest) orelse return null);

        while (self.peekIs(.comma)) {
            try self.nextToken();
            try self.nextToken();
            try args.append(self.gpa, try self.parseExpression(.lowest) orelse return null);
        }

        if (!try self.expectPeek(.right_paren)) return null;
    }

    var with: ?Ast.Call.With = null;
    if (self.peekIs(.with)) {
        try self.nextToken();
        try self.nextToken();
        with = if (self.currentIs(.with_source))
            .{ .raw = self.current.literal }
        else
            .{ .value = try self.parseExpression(.call) orelse return null };
    }

    return try self.createExpr(callee.line, callee.column, .{ .call = .{
        .callee = callee,
        .args = try args.toOwnedSlice(self.gpa),
        .with = with,
    } });
}

fn createExpr(self: *Self, line: usize, column: usize, kind: Ast.Expr.Kind) ParseError!*Ast.Expr {
    const ptr = try self.gpa.create(Ast.Expr);
    ptr.* = .{ .line = line, .column = column, .kind = kind };
    return ptr;
}

// Illegal and unclosed tokens are reported here and skipped, so they do not cause more errors later.
fn nextToken(self: *Self) ParseError!void {
    self.current = self.peek;
    self.peek = self.lexer.nextToken();

    while (self.peek.type == .illegal or self.peek.type == .unclosed) {
        const literal = self.peek.literal;
        const message = if (self.peek.type == .illegal)
            try std.fmt.allocPrint(self.gpa, "unexpected character '{s}'", .{literal})
        else if (literal[0] == '"')
            "unterminated string"
        else
            try std.fmt.allocPrint(self.gpa, "missing '{s}'", .{literal});
        try self.appendError(.{ .line = self.peek.line, .column = self.peek.column, .message = message });
        self.peek = self.lexer.nextToken();
    }
}

// Reads `x`, `#x`, `$x`, an entity score such as `@s.#mana`, or entity data such as `@s.$Health`.
fn parseIdentifier(self: *Self) ParseError!?Ast.Identifier {
    if (self.currentIs(.identifier) and (self.peekIs(.colon) or self.peekIs(.dot))) return self.parseQualifiedName();
    if (!self.currentIs(.selector)) return self.currentIdentifier();

    const selector = self.current.literal;
    if (self.peekIs(.entity_data)) {
        try self.nextToken();
        return .{ .name = self.current.literal, .storage = .entity_data, .selector = selector };
    }
    if (!try self.expectPeek(.dot)) return null;
    if (!try self.expectPeek(.score_identifier)) return null;

    const name, const namespace = splitNamespace(self.current.literal);
    return .{ .name = name, .storage = .score, .selector = selector, .namespace = namespace };
}

// `magic:heal` or `bs.math:clamp` as a value or a callee.
fn parseQualifiedName(self: *Self) ParseError!?Ast.Identifier {
    const namespace = try self.parseNamespaceName() orelse return null;
    if (!try self.expectPeek(.colon)) return null;
    if (!try self.expectPeek(.identifier)) return null;
    return .{ .name = self.current.literal, .storage = .compile_time, .namespace = namespace };
}

fn currentIdentifier(self: *Self) ?Ast.Identifier {
    const storage: Ast.Storage = switch (self.current.type) {
        .identifier => .compile_time,
        .score_identifier => .score,
        .data_identifier => .data,
        else => return null,
    };

    const name, const namespace = splitNamespace(self.current.literal);
    return .{ .name = name, .storage = storage, .namespace = namespace };
}

// The lexer keeps `magic:` on a `#` or `$` name: `magic:item.count` → `item.count` in `magic`.
fn splitNamespace(literal: []const u8) struct { []const u8, ?[]const u8 } {
    const colon = std.mem.indexOfScalar(u8, literal, ':') orelse return .{ literal, null };
    const path_start = std.mem.indexOfAny(u8, literal, "[\"") orelse literal.len;
    if (colon > path_start) return .{ literal, null };
    return .{ literal[colon + 1 ..], literal[0..colon] };
}

fn currentIs(self: *Self, token_type: Token.TokenType) bool {
    return self.current.type == token_type;
}

fn peekIs(self: *Self, token_type: Token.TokenType) bool {
    return self.peek.type == token_type;
}

fn expectPeek(self: *Self, token_type: Token.TokenType) ParseError!bool {
    if (self.peekIs(token_type)) {
        try self.nextToken();
        return true;
    }

    try self.addError("expected {s}, found {s}", .{ expectedText(token_type), try self.describe(self.peek) });
    return false;
}

// How a message names a token that `expectPeek` wants.
fn expectedText(token_type: Token.TokenType) []const u8 {
    return switch (token_type) {
        .semicolon => "';'",
        .eql => "'='",
        .left_paren => "'('",
        .right_paren => "')'",
        .left_brace => "'{'",
        .right_brace => "'}'",
        .right_bracket => "']'",
        .colon => "':'",
        .dot => "'.'",
        .dot_dot => "'..'",
        .pipe => "'|'",
        .identifier => "a name",
        .score_identifier => "a score name",
        .execute_subcommands => "'(...)' after 'execute'",
        else => @tagName(token_type),
    };
}

fn currentPrecedence(self: *Self) Precedence {
    return precedenceOf(self.current.type);
}

fn peekPrecedence(self: *Self) Precedence {
    return precedenceOf(self.peek.type);
}

fn precedenceOf(token_type: Token.TokenType) Precedence {
    return switch (token_type) {
        .@"or" => .@"or",
        .@"and" => .@"and",
        .eql_eql, .bang_eql => .equals,
        .less, .less_eql, .greater, .greater_eql => .less_greater,
        .plus, .minus => .sum,
        .star, .slash, .percent => .product,
        .left_paren => .call,
        else => .lowest,
    };
}

fn addError(self: *Self, comptime format: []const u8, args: anytype) ParseError!void {
    const message = try std.fmt.allocPrint(self.gpa, format, args);
    try self.appendError(.{ .line = self.current.line, .column = self.current.column, .message = message });
}

// Only the first error on a line is kept. Later ones on that line are usually caused by it.
fn appendError(self: *Self, err: Error) ParseError!void {
    if (self.errors.getLastOrNull()) |last| {
        if (last.line == err.line) return;
    }
    try self.errors.append(self.gpa, err);
}

fn describe(self: *const Self, token: Token) ParseError![]const u8 {
    if (token.type == .eof) return self.end_of_input;
    return std.fmt.allocPrint(self.gpa, "'{s}'", .{token.literal});
}

const TestResult = struct {
    program: Ast.Program,
    errors: []const Error,
};

fn parseForTest(arena: std.mem.Allocator, source: []const u8) !TestResult {
    var parser = try Self.init(arena, Lexer.init(source));
    const program = try parser.parseProgram();
    return .{ .program = program, .errors = parser.errors.items };
}

fn parseValidForTest(arena: std.mem.Allocator, source: []const u8) !Ast.Program {
    const result = try parseForTest(arena, source);
    for (result.errors) |err| std.debug.print("line {d}: {s}\n", .{ err.line, err.message });
    try std.testing.expectEqual(0, result.errors.len);
    return result.program;
}

fn firstStatement(program: Ast.Program) Ast.Stmt {
    return program.functions[0].body[0];
}

test "parse hello.poplar" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    const program = try parseValidForTest(arena.allocator(),
        \\// creates hello.mcfunction
        \\mcfun hello() {
        \\    say("hello");
        \\}
    );

    try std.testing.expectEqual(1, program.functions.len);

    const function = program.functions[0];
    try std.testing.expectEqualStrings("hello", function.name);
    try std.testing.expectEqual(2, function.line);

    const call = function.body[0].kind.expression.kind.call;
    try std.testing.expectEqualStrings("say", call.callee.kind.identifier.name);
    try std.testing.expectEqualStrings("hello", call.args[0].kind.string);
}

test "parse calls with a macro compound, a path or raw text, and macro keys" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    const program = try parseValidForTest(arena.allocator(), "mcfun f() { g() with {name: $(name)}; g() with $players[0]; g() with entity @s; }");

    const body = program.functions[0].body;
    try std.testing.expectEqualStrings("name", body[0].kind.expression.kind.call.with.?.value.kind.compound[0].value.kind.macro_key);
    try std.testing.expectEqualStrings("players[0]", body[1].kind.expression.kind.call.with.?.value.kind.identifier.name);
    try std.testing.expectEqualStrings("entity @s", body[2].kind.expression.kind.call.with.?.raw);
}

test "an expression in an insert has its position in the file" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    const program = try parseValidForTest(arena.allocator(),
        \\mcfun f() {
        \\    /say x{{ #a }};
        \\    execute (as {{ #b }}) { }
        \\    if (entity {{ #c }}) { }
        \\}
    );

    const body = program.functions[0].body;
    const command_insert = body[0].kind.command.parts[1].content.insert;
    const execute_insert = body[1].kind.execute.subcommands[1].content.insert;
    const check_insert = body[2].kind.@"if".condition.kind.minecraft_check[1].content.insert;
    try std.testing.expectEqual(2, command_insert.line);
    try std.testing.expectEqual(14, command_insert.column);
    try std.testing.expectEqual(3, execute_insert.line);
    try std.testing.expectEqual(20, execute_insert.column);
    try std.testing.expectEqual(4, check_insert.line);
    try std.testing.expectEqual(19, check_insert.column);
}

test "SNBT numbers keep their text and type, and a range still works" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    const program = try parseValidForTest(arena.allocator(), "mcfun f() { g(0.05f, 0.05, 1b, 5L, 20D, 5); for (1..5) |i| {} }");

    const args = program.functions[0].body[0].kind.expression.kind.call.args;
    try std.testing.expectEqualStrings("0.05", args[0].kind.typed_number.text);
    try std.testing.expectEqual(.float, args[0].kind.typed_number.type.?);
    try std.testing.expectEqualStrings("0.05", args[1].kind.typed_number.text);
    try std.testing.expectEqual(null, args[1].kind.typed_number.type);
    try std.testing.expectEqual(.byte, args[2].kind.typed_number.type.?);
    try std.testing.expectEqual(.long, args[3].kind.typed_number.type.?);
    try std.testing.expectEqual(.double, args[4].kind.typed_number.type.?);
    try std.testing.expectEqual(5, args[5].kind.number);
    try std.testing.expectEqual(5, program.functions[0].body[1].kind.@"for".end.kind.number);
}

test "parse operator precedence" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    const program = try parseValidForTest(arena.allocator(), "mcfun f() { 1 + 2 * 3; }");

    const sum = firstStatement(program).kind.expression.kind.infix;
    try std.testing.expectEqual(.plus, sum.op);
    try std.testing.expectEqual(1, sum.left.kind.number);

    const product = sum.right.kind.infix;
    try std.testing.expectEqual(.star, product.op);
    try std.testing.expectEqual(2, product.left.kind.number);
    try std.testing.expectEqual(3, product.right.kind.number);
}

test "parse grouped and prefix expressions" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    const program = try parseValidForTest(arena.allocator(), "mcfun f() { -(1 + 2) * 3; }");

    const product = firstStatement(program).kind.expression.kind.infix;
    try std.testing.expectEqual(.star, product.op);

    const negation = product.left.kind.prefix;
    try std.testing.expectEqual(.minus, negation.op);
    try std.testing.expectEqual(.plus, negation.operand.kind.infix.op);
}

test "parse call with args" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    const program = try parseValidForTest(arena.allocator(), "mcfun f() { add(1, x + 2, \"three\"); }");

    const call = firstStatement(program).kind.expression.kind.call;
    try std.testing.expectEqualStrings("add", call.callee.kind.identifier.name);
    try std.testing.expectEqual(3, call.args.len);
    try std.testing.expectEqual(1, call.args[0].kind.number);
    try std.testing.expectEqual(.plus, call.args[1].kind.infix.op);
    try std.testing.expectEqualStrings("three", call.args[2].kind.string);
}

test "parse if else" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    const program = try parseValidForTest(arena.allocator(),
        \\mcfun f() {
        \\    if (x < 1) { a(); } else if (x == 2) { b(); } else { c(); }
        \\}
    );

    const if_statement = firstStatement(program).kind.@"if";
    try std.testing.expectEqual(.less, if_statement.condition.kind.infix.op);
    try std.testing.expectEqual(1, if_statement.then_body.len);

    const else_if = if_statement.else_body.?[0].kind.@"if";
    try std.testing.expectEqual(.eql_eql, else_if.condition.kind.infix.op);
    try std.testing.expectEqual(1, else_if.else_body.?.len);
}

test "parse storage sigils" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    const program = try parseValidForTest(arena.allocator(), "mcfun f() { var #hp = 1; var $name = 2; }");

    const body = program.functions[0].body;
    try std.testing.expectEqual(.score, body[0].kind.var_decl.target.storage);
    try std.testing.expectEqualStrings("hp", body[0].kind.var_decl.target.name);
    try std.testing.expectEqual(.data, body[1].kind.var_decl.target.storage);
}

test "missing semicolon reports line" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    const result = try parseForTest(arena.allocator(),
        \\mcfun hello() {
        \\    say("hello")
        \\}
    );

    try std.testing.expectEqual(1, result.errors.len);
    try std.testing.expectEqual(2, result.errors[0].line);
    try std.testing.expectEqualStrings("expected ';', found '}'", result.errors[0].message);
}

test "errors have a column, also in an insert, and name the end of the insert" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    const result = try parseForTest(arena.allocator(),
        \\mcfun f() {
        \\    /say {{ 1 + }};
        \\    var x 5;
        \\}
    );

    try std.testing.expectEqualStrings("expected an expression, found the end of '{{...}}'", result.errors[0].message);
    try std.testing.expectEqual(2, result.errors[0].line);
    try std.testing.expectEqual(17, result.errors[0].column);
    try std.testing.expectEqualStrings("expected '=', found '5'", result.errors[1].message);
    try std.testing.expectEqual(9, result.errors[1].column);
}

test "after a broken declaration, its body is skipped and the next declaration is read" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    const result = try parseForTest(arena.allocator(),
        \\mcfun broken( {
        \\    var x = 1;
        \\}
        \\recipe a {}
        \\mcfun f() {}
    );

    try std.testing.expectEqual(1, result.errors.len);
    try std.testing.expectEqual(0, result.program.globals.len);
    try std.testing.expectEqual(1, result.program.data_files.len);
    try std.testing.expectEqual(1, result.program.functions.len);
}

test "decodes string escapes" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    const program = try parseValidForTest(arena.allocator(), "mcfun f() { g(\"a \\\"b\\\" \\\\ c\"); }");
    const call = firstStatement(program).kind.expression.kind.call;
    try std.testing.expectEqualStrings("a \"b\" \\ c", call.args[0].kind.string);

    const result = try parseForTest(arena.allocator(), "mcfun f() { g(\"bad \\q\"); }");
    try std.testing.expectEqualStrings("unknown escape '\\q' in string. Only \\\" and \\\\ are allowed", result.errors[0].message);
}

test "reads namespace, imports and names of other namespaces" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    const program = try parseValidForTest(arena.allocator(),
        \\namespace combat;
        \\import bs.math;
        \\mcfun f() { bs.math:clamp(#magic:mana, $magic:item.count); }
    );
    try std.testing.expectEqualStrings("combat", program.namespace.?.name);
    try std.testing.expectEqualStrings("bs.math", program.imports[0].name);
    const call = firstStatement(program).kind.expression.kind.call;
    try std.testing.expectEqualStrings("bs.math", call.callee.kind.identifier.namespace.?);
    try std.testing.expectEqualStrings("clamp", call.callee.kind.identifier.name);
    try std.testing.expectEqualStrings("magic", call.args[0].kind.identifier.namespace.?);
    try std.testing.expectEqualStrings("item.count", call.args[1].kind.identifier.name);

    const late = try parseForTest(arena.allocator(), "mcfun f() {}\nnamespace late;\n");
    try std.testing.expectEqualStrings("'namespace' must be the first statement of the file", late.errors[0].message);
}
