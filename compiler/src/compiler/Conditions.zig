// `if` and `while` conditions: comparisons, data tests and Minecraft checks, in OR-of-ANDs form.
const std = @import("std");
const Compiler = @import("../Compiler.zig");
const Ast = @import("../Ast.zig");
const Environment = @import("../Environment.zig");
const Ir = @import("../Ir.zig");
const Token = @import("../Token.zig");
const Data = @import("Data.zig");
const MinecraftText = @import("MinecraftText.zig");
const Scores = @import("Scores.zig");
const Values = @import("Values.zig");

pub fn lowerCondition(self: *Compiler, expression: *const Ast.Expr, env: *Environment, negated: bool, setup: *std.ArrayList(Ir.Command)) Compiler.CompileError!?Compiler.Condition {
    const outer_position = self.enterExpression(expression);
    defer self.restorePosition(outer_position);
    if (!Values.containsRuntimeValue(self, expression, env)) {
        const value = try Values.evaluate(self, expression, env) orelse return null;
        if (value != .boolean) {
            try self.addError("a condition must be a comparison, a data path, true or false, found {s}", .{@tagName(value)});
            return null;
        }
        return .{ .constant = value.boolean != negated };
    }

    switch (expression.kind) {
        .prefix => |prefix| if (prefix.op == .bang) return lowerCondition(self, prefix.operand, env, !negated, setup),
        .infix => |infix| switch (infix.op) {
            .@"and", .@"or" => {
                const left = try lowerCondition(self, infix.left, env, negated, setup) orelse return null;
                const right = try lowerCondition(self, infix.right, env, negated, setup) orelse return null;

                const is_and = (infix.op == .@"and") != negated;
                return if (is_and) try combineAnd(self, left, right) else try combineOr(self, left, right);
            },
            .less, .less_eql, .greater, .greater_eql, .eql_eql, .bang_eql => {
                return lowerComparison(self, infix, env, negated, setup);
            },
            else => {},
        },
        .call => |call| if (Data.isStringTest(call)) return Data.stringTest(self, call, env, negated, setup),
        .minecraft_check => |parts| return minecraftCheck(self, parts, expression.column, env, negated),
        // `if ($x)` is Minecraft's `if data`: the path exists, whatever its value. A bool needs `== true`.
        .identifier => |identifier| if (identifier.storage == .data or identifier.storage == .entity_data) {
            const path = try Data.dataPathOf(self, identifier, env) orelse return null;
            return try singleCheck(self, .{ .negated = negated, .score_test = .{ .data_test = path } });
        },
        else => {},
    }

    if (expression.kind == .identifier and expression.kind.identifier.storage == .score) {
        try self.addError("a score needs a comparison in a condition: 'if (#{s} != 0)'", .{expression.kind.identifier.name});
        return null;
    }
    try self.addError("a condition must be a comparison, a data path, or 'and', 'or' and '!' of those", .{});
    return null;
}

// `block ~ ~-1 ~ stone` → `if block ~ ~-1 ~ stone`, checked like the subcommands of `execute (...)`.
pub fn minecraftCheck(self: *Compiler, parts: []const Ast.CommandPart, column: usize, env: *Environment, negated: bool) Compiler.CompileError!?Compiler.Condition {
    const check = try MinecraftText.buildCommandText(self, parts, env) orelse return null;
    if (check.is_macro) {
        try self.addError("a game value in a Minecraft check is not supported yet. Use 'execute (if ...) {{ }}'", .{});
        return null;
    }

    const text = try MinecraftText.checkMinecraftText(self, parts, check, column, "execute if ", " run say x") orelse return null;
    return try singleCheck(self, .{ .negated = negated, .score_test = .{ .raw = text } });
}

// `$name == "Steve"` → `if data storage ns:data {name:"Steve"}`. The path becomes a nested filter.
pub fn dataCondition(self: *Compiler, identifier: Ast.Identifier, value: Compiler.Value, cast_type: ?Ast.NumberType, negated: bool, env: *const Environment) Compiler.CompileError!?Compiler.Condition {
    const path = try Data.dataPathOf(self, identifier, env) orelse return null;
    if (std.mem.indexOfAny(u8, path.path, "[\"") != null) {
        try self.addError("a condition on '{s}' is not supported yet: the path must only have keys", .{identifier.name});
        return null;
    }

    var filter: std.ArrayList(u8) = .empty;
    var keys = std.mem.splitScalar(u8, path.path, '.');
    var depth: usize = 0;
    while (keys.next()) |key| : (depth += 1) try filter.print(self.gpa, "{{{s}:", .{key});
    // Minecraft stores a bool as a byte, so the filter says `1b` or `0b`.
    const snbt = if (value == .boolean) (if (value.boolean) "1b" else "0b") else try Data.castSnbt(self, value, cast_type) orelse return null;
    try filter.appendSlice(self.gpa, snbt);
    try filter.appendNTimes(self.gpa, '}', depth);

    return try singleCheck(self, .{ .negated = negated, .score_test = .{ .data_test = path.withPath(try filter.toOwnedSlice(self.gpa)) } });
}

pub fn lowerComparison(self: *Compiler, infix: Ast.Infix, env: *Environment, negated: bool, setup: *std.ArrayList(Ir.Command)) Compiler.CompileError!?Compiler.Condition {
    const check_negated = negated != (infix.op == .bang_eql);
    const op = compareOperator(infix.op);

    if ((infix.op == .eql_eql or infix.op == .bang_eql) and isTextComparison(self, infix.left, infix.right, env)) {
        if (Data.isDataIdentifier(infix.left)) return dataComparison(self, infix.left, infix.right, env, check_negated);
        if (Data.isDataIdentifier(infix.right)) return dataComparison(self, infix.right, infix.left, env, check_negated);
    }

    const left = try lowerOperand(self, infix.left, env, setup) orelse return null;
    const right = try lowerOperand(self, infix.right, env, setup) orelse return null;

    // At least one side has a score, so two numbers cannot happen here.
    return switch (left) {
        .number => |number| try matchesCondition(self, right.score, flipCompare(op), number, check_negated),
        .score => |left_score| switch (right) {
            .number => |number| try matchesCondition(self, left_score, op, number, check_negated),
            .score => |right_score| try singleCheck(self, .{
                .negated = check_negated,
                .score_test = .{ .compare = .{ .left = left_score, .op = op, .right = right_score } },
            }),
        },
    };
}

// `==` between data and a compile-time string, bool, list, compound or `as` number is an NBT filter.
// A number comparison still goes through a score, which also works for other number types.
pub fn dataComparison(self: *Compiler, data_side: *const Ast.Expr, other: *const Ast.Expr, env: *Environment, negated: bool) Compiler.CompileError!?Compiler.Condition {
    const outer_position = self.enterExpression(other);
    defer self.restorePosition(outer_position);
    if (Values.containsRuntimeValue(self, other, env)) {
        try self.addError("comparing two runtime values that are not numbers is not supported yet", .{});
        return null;
    }
    const expression, const cast_type = Data.splitCast(other);
    const value = try Values.evaluate(self, expression, env) orelse return null;
    return dataCondition(self, data_side.kind.identifier, value, cast_type, negated, env);
}

// True when one side is data and the other is a compile-time value that is not a plain int.
pub fn isTextComparison(self: *Compiler, left: *const Ast.Expr, right: *const Ast.Expr, env: *Environment) bool {
    if (!Data.isDataIdentifier(left) and !Data.isDataIdentifier(right)) return false;
    for ([_]*const Ast.Expr{ left, right }) |side| {
        if (Data.isDataIdentifier(side) or Values.containsRuntimeValue(self, side, env)) continue;
        switch (side.kind) {
            .string, .boolean, .list, .compound, .cast, .typed_number => return true,
            .prefix => |prefix| if (prefix.operand.kind == .typed_number) return true,
            else => {},
        }
    }
    return false;
}

pub fn lowerOperand(self: *Compiler, expression: *const Ast.Expr, env: *Environment, setup: *std.ArrayList(Ir.Command)) Compiler.CompileError!?Compiler.Operand {
    const outer_position = self.enterExpression(expression);
    defer self.restorePosition(outer_position);
    if (!Values.containsRuntimeValue(self, expression, env)) {
        const value = try Values.evaluate(self, expression, env) orelse return null;
        if (value == .typed_number) {
            try self.addError("a score holds whole numbers with no suffix, so it cannot be compared with '{s}'", .{value.typed_number.text});
            return null;
        }
        if (value != .number) {
            try self.addError("only numbers can be compared with scores, found {s}", .{@tagName(value)});
            return null;
        }
        return .{ .number = value.number };
    }

    if (expression.kind == .identifier and expression.kind.identifier.storage == .score) {
        return .{ .score = try Scores.scoreSource(self, expression.kind.identifier, env) orelse return null };
    }

    const temp = try Scores.newTemp(self);
    try Scores.compileInto(self, temp, expression, env, setup);
    return .{ .score = temp };
}

pub fn matchesCondition(self: *Compiler, score: Ir.Score, op: Ir.CompareOp, number: i64, negated: bool) Compiler.CompileError!Compiler.Condition {
    var min: ?i64 = null;
    var max: ?i64 = null;

    switch (op) {
        .lt => max = number -| 1,
        .le => max = number,
        .eq => {
            min = number;
            max = number;
        },
        .ge => min = number,
        .gt => min = number +| 1,
    }

    const score_min = std.math.minInt(i32);
    const score_max = std.math.maxInt(i32);

    const is_never_true = (max != null and max.? < score_min) or (min != null and min.? > score_max);
    if (is_never_true) return .{ .constant = negated };

    const range_min: ?i32 = if (min != null and min.? > score_min) @intCast(min.?) else null;
    const range_max: ?i32 = if (max != null and max.? < score_max) @intCast(max.?) else null;
    if (range_min == null and range_max == null) return .{ .constant = !negated };

    return singleCheck(self, .{
        .negated = negated,
        .score_test = .{ .matches = .{ .score = score, .min = range_min, .max = range_max } },
    });
}

pub fn singleCheck(self: *Compiler, check: Ir.Check) Compiler.CompileError!Compiler.Condition {
    const checks = try self.gpa.dupe(Ir.Check, &.{check});
    return .{ .clauses = try self.gpa.dupe([]const Ir.Check, &.{checks}) };
}

pub fn combineAnd(self: *Compiler, left: Compiler.Condition, right: Compiler.Condition) Compiler.CompileError!Compiler.Condition {
    if (left == .constant) return if (left.constant) right else left;
    if (right == .constant) return if (right.constant) left else right;

    var clauses: std.ArrayList([]const Ir.Check) = .empty;
    for (left.clauses) |left_checks| {
        for (right.clauses) |right_checks| {
            try clauses.append(self.gpa, try std.mem.concat(self.gpa, Ir.Check, &.{ left_checks, right_checks }));
        }
    }

    return .{ .clauses = try clauses.toOwnedSlice(self.gpa) };
}

pub fn combineOr(self: *Compiler, left: Compiler.Condition, right: Compiler.Condition) Compiler.CompileError!Compiler.Condition {
    if (left == .constant) return if (left.constant) left else right;
    if (right == .constant) return if (right.constant) right else left;

    return .{ .clauses = try std.mem.concat(self.gpa, []const Ir.Check, &.{ left.clauses, right.clauses }) };
}

pub fn compareOperator(op: Token.TokenType) Ir.CompareOp {
    return switch (op) {
        .less => .lt,
        .less_eql => .le,
        .greater => .gt,
        .greater_eql => .ge,
        .eql_eql, .bang_eql => .eq,
        else => unreachable,
    };
}

pub fn flipCompare(op: Ir.CompareOp) Ir.CompareOp {
    return switch (op) {
        .lt => .gt,
        .le => .ge,
        .eq => .eq,
        .ge => .le,
        .gt => .lt,
    };
}

test "negated and becomes or" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    var compiler = try Compiler.compileForTest(arena.allocator(),
        \\var #a = 0;
        \\var #b = 0;
        \\mcfun main() { if (!(#a > 1 and #b == 2)) { /say x; } }
    );
    const program = try compiler.compile();
    try std.testing.expectEqual(0, compiler.errors.items.len);

    try std.testing.expectEqualStrings(
        \\execute unless score #global ns.a matches 2.. run return run say x
        \\execute unless score #global ns.b matches 2 run return run say x
        \\
    , try Compiler.renderForTest(arena.allocator(), program, "main"));
}

test "Minecraft checks in conditions mix with score checks" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    var compiler = try Compiler.compileForTest(arena.allocator(),
        \\predicate isSitting { "type": "minecraft:random_chance", "chance": 0.5 }
        \\var #mana = 0;
        \\mcfun main() {
        \\    if (block ~ ~-1 ~ #minecraft:logs and #mana > 5) { /say log; }
        \\    if (!predicate self:isSitting or entity @s[type=pig]) { /say hi; }
        \\    if (block ~ ~ ~ stoen) { /say typo; }
        \\}
    );
    const program = try compiler.compile();
    try std.testing.expectEqual(1, compiler.errors.items.len);
    try std.testing.expectEqualStrings("unknown block 'stoen'. Did you mean 'stone'?", compiler.errors.items[0].message);
    try std.testing.expectEqual(21, compiler.errors.items[0].column);

    try std.testing.expectEqualStrings(
        \\execute if block ~ ~-1 ~ #minecraft:logs if score #global ns.mana matches 6.. run say log
        \\execute unless predicate ns:is_sitting run return run say hi
        \\execute if entity @s[type=pig] run return run say hi
        \\
    , try Compiler.renderForTest(arena.allocator(), program, "main"));
}
