// `if` and `while` conditions: comparisons, data tests and Minecraft checks, in OR-of-ANDs form.
const std = @import("std");
const Compiler = @import("../Compiler.zig");
const ast = @import("../ast.zig");
const Environment = @import("../Environment.zig");
const ir = @import("../ir.zig");
const Token = @import("../Token.zig");
const data = @import("data.zig");
const minecraft_text = @import("minecraft_text.zig");
const scores = @import("scores.zig");
const values = @import("values.zig");

pub fn lowerCondition(compiler: *Compiler, expression: *const ast.Expr, env: *Environment, negated: bool, setup: *std.ArrayList(ir.Command)) Compiler.CompileError!?Compiler.Condition {
    const outer_position = compiler.enterExpression(expression);
    defer compiler.restorePosition(outer_position);
    if (!values.containsRuntimeValue(compiler, expression, env)) {
        const value = try values.evaluate(compiler, expression, env) orelse return null;
        if (value != .boolean) {
            try compiler.addError("a condition must be a comparison, a data path, true or false, found {s}", .{@tagName(value)});
            return null;
        }
        return .{ .constant = value.boolean != negated };
    }

    switch (expression.kind) {
        .prefix => |prefix| if (prefix.op == .bang) return lowerCondition(compiler, prefix.operand, env, !negated, setup),
        .infix => |infix| switch (infix.op) {
            .@"and", .@"or" => {
                const left = try lowerCondition(compiler, infix.left, env, negated, setup) orelse return null;
                const right = try lowerCondition(compiler, infix.right, env, negated, setup) orelse return null;

                const is_and = (infix.op == .@"and") != negated;
                return if (is_and) try combineAnd(compiler, left, right) else try combineOr(compiler, left, right);
            },
            .less, .less_eql, .greater, .greater_eql, .eql_eql, .bang_eql => {
                return lowerComparison(compiler, infix, env, negated, setup);
            },
            else => {},
        },
        .call => |call| if (data.isStringTest(call)) return data.stringTest(compiler, call, env, negated, setup),
        .minecraft_check => |parts| return minecraftCheck(compiler, parts, expression.column, env, negated),
        // `if ($x)` is Minecraft's `if data`: the path exists, whatever its value. A bool needs `== true`.
        .identifier => |identifier| if (identifier.storage == .data or identifier.storage == .entity_data) {
            const path = try data.dataPathOf(compiler, identifier, env) orelse return null;
            return try singleCheck(compiler, .{ .negated = negated, .score_test = .{ .data_test = path } });
        },
        else => {},
    }

    if (expression.kind == .identifier and expression.kind.identifier.storage == .score) {
        try compiler.addError("a score needs a comparison in a condition: 'if (#{s} != 0)'", .{expression.kind.identifier.name});
        return null;
    }
    try compiler.addError("a condition must be a comparison, a data path, or 'and', 'or' and '!' of those", .{});
    return null;
}

// `block ~ ~-1 ~ stone` → `if block ~ ~-1 ~ stone`, checked like the subcommands of `execute (...)`.
pub fn minecraftCheck(compiler: *Compiler, parts: []const ast.CommandPart, column: usize, env: *Environment, negated: bool) Compiler.CompileError!?Compiler.Condition {
    const check = try minecraft_text.buildCommandText(compiler, parts, env) orelse return null;
    if (check.is_macro) {
        try compiler.addError("a game value in a Minecraft check is not supported yet. Use 'execute (if ...) {{ }}'", .{});
        return null;
    }

    const text = try minecraft_text.checkMinecraftText(compiler, parts, check, column, "execute if ", " run say x") orelse return null;
    return try singleCheck(compiler, .{ .negated = negated, .score_test = .{ .raw = text } });
}

// `$name == "Steve"` → `if data storage ns:data {name:"Steve"}`. The path becomes a nested filter.
pub fn dataCondition(compiler: *Compiler, identifier: ast.Identifier, value: Compiler.Value, negated: bool, env: *const Environment) Compiler.CompileError!?Compiler.Condition {
    const path = try data.dataPathOf(compiler, identifier, env) orelse return null;
    if (std.mem.indexOfAny(u8, path.path, "[\"") != null) {
        try compiler.addError("a condition on '{s}' is not supported yet: the path must only have keys", .{identifier.name});
        return null;
    }

    var filter: std.ArrayList(u8) = .empty;
    var keys = std.mem.splitScalar(u8, path.path, '.');
    var depth: usize = 0;
    while (keys.next()) |key| : (depth += 1) try filter.print(compiler.gpa, "{{{s}:", .{key});
    // Minecraft stores a bool as a byte, so the filter says `1b` or `0b`.
    const snbt = if (value == .boolean) (if (value.boolean) "1b" else "0b") else try values.valueToSnbt(compiler, value);
    try filter.appendSlice(compiler.gpa, snbt);
    try filter.appendNTimes(compiler.gpa, '}', depth);

    return try singleCheck(compiler, .{ .negated = negated, .score_test = .{ .data_test = path.withPath(try filter.toOwnedSlice(compiler.gpa)) } });
}

pub fn lowerComparison(compiler: *Compiler, infix: ast.Infix, env: *Environment, negated: bool, setup: *std.ArrayList(ir.Command)) Compiler.CompileError!?Compiler.Condition {
    const check_negated = negated != (infix.op == .bang_eql);
    const op = compareOperator(infix.op);

    if ((infix.op == .eql_eql or infix.op == .bang_eql) and isTextComparison(compiler, infix.left, infix.right, env)) {
        if (data.isDataIdentifier(infix.left)) return dataComparison(compiler, infix.left, infix.right, env, check_negated);
        if (data.isDataIdentifier(infix.right)) return dataComparison(compiler, infix.right, infix.left, env, check_negated);
    }

    const left = try lowerOperand(compiler, infix.left, env, setup) orelse return null;
    const right = try lowerOperand(compiler, infix.right, env, setup) orelse return null;

    // At least one side has a score, so two numbers cannot happen here.
    return switch (left) {
        .number => |number| try matchesCondition(compiler, right.score, flipCompare(op), number, check_negated),
        .score => |left_score| switch (right) {
            .number => |number| try matchesCondition(compiler, left_score, op, number, check_negated),
            .score => |right_score| try singleCheck(compiler, .{
                .negated = check_negated,
                .score_test = .{ .compare = .{ .left = left_score, .op = op, .right = right_score } },
            }),
        },
    };
}

// `==` between data and a compile-time string, bool, list, compound or typed number is an NBT filter.
// A number comparison still goes through a score, which also works for other number types.
pub fn dataComparison(compiler: *Compiler, data_side: *const ast.Expr, other: *const ast.Expr, env: *Environment, negated: bool) Compiler.CompileError!?Compiler.Condition {
    const outer_position = compiler.enterExpression(other);
    defer compiler.restorePosition(outer_position);
    if (values.containsRuntimeValue(compiler, other, env)) {
        try compiler.addError("comparing two runtime values that are not numbers is not supported yet", .{});
        return null;
    }
    const value = try values.evaluate(compiler, other, env) orelse return null;
    return dataCondition(compiler, data_side.kind.identifier, value, negated, env);
}

// True when one side is data and the other is a compile-time value that is not a plain int.
pub fn isTextComparison(compiler: *Compiler, left: *const ast.Expr, right: *const ast.Expr, env: *Environment) bool {
    if (!data.isDataIdentifier(left) and !data.isDataIdentifier(right)) return false;
    for ([_]*const ast.Expr{ left, right }) |side| {
        if (data.isDataIdentifier(side) or values.containsRuntimeValue(compiler, side, env)) continue;
        switch (side.kind) {
            .string, .boolean, .list, .compound, .typed_number => return true,
            .prefix => |prefix| if (prefix.operand.kind == .typed_number) return true,
            else => {},
        }
    }
    return false;
}

pub fn lowerOperand(compiler: *Compiler, expression: *const ast.Expr, env: *Environment, setup: *std.ArrayList(ir.Command)) Compiler.CompileError!?Compiler.Operand {
    const outer_position = compiler.enterExpression(expression);
    defer compiler.restorePosition(outer_position);
    if (!values.containsRuntimeValue(compiler, expression, env)) {
        const value = try values.evaluate(compiler, expression, env) orelse return null;
        if (value == .typed_number) {
            try compiler.addError("a score holds whole numbers with no suffix, so it cannot be compared with '{s}'", .{value.typed_number.text});
            return null;
        }
        if (value != .number) {
            try compiler.addError("only numbers can be compared with scores, found {s}", .{@tagName(value)});
            return null;
        }
        return .{ .number = value.number };
    }

    if (expression.kind == .identifier and expression.kind.identifier.storage == .score) {
        return .{ .score = try scores.scoreSource(compiler, expression.kind.identifier, env) orelse return null };
    }

    const temp = try scores.newTemp(compiler);
    try scores.compileInto(compiler, temp, expression, env, setup);
    return .{ .score = temp };
}

pub fn matchesCondition(compiler: *Compiler, score: ir.Score, op: ir.CompareOp, number: i64, negated: bool) Compiler.CompileError!Compiler.Condition {
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

    return singleCheck(compiler, .{
        .negated = negated,
        .score_test = .{ .matches = .{ .score = score, .min = range_min, .max = range_max } },
    });
}

pub fn singleCheck(compiler: *Compiler, check: ir.Check) Compiler.CompileError!Compiler.Condition {
    const checks = try compiler.gpa.dupe(ir.Check, &.{check});
    return .{ .clauses = try compiler.gpa.dupe([]const ir.Check, &.{checks}) };
}

pub fn combineAnd(compiler: *Compiler, left: Compiler.Condition, right: Compiler.Condition) Compiler.CompileError!Compiler.Condition {
    if (left == .constant) return if (left.constant) right else left;
    if (right == .constant) return if (right.constant) left else right;

    var clauses: std.ArrayList([]const ir.Check) = .empty;
    for (left.clauses) |left_checks| {
        for (right.clauses) |right_checks| {
            try clauses.append(compiler.gpa, try std.mem.concat(compiler.gpa, ir.Check, &.{ left_checks, right_checks }));
        }
    }

    return .{ .clauses = try clauses.toOwnedSlice(compiler.gpa) };
}

pub fn combineOr(compiler: *Compiler, left: Compiler.Condition, right: Compiler.Condition) Compiler.CompileError!Compiler.Condition {
    if (left == .constant) return if (left.constant) left else right;
    if (right == .constant) return if (right.constant) right else left;

    return .{ .clauses = try std.mem.concat(compiler.gpa, []const ir.Check, &.{ left.clauses, right.clauses }) };
}

pub fn compareOperator(op: Token.TokenType) ir.CompareOp {
    return switch (op) {
        .less => .lt,
        .less_eql => .le,
        .greater => .gt,
        .greater_eql => .ge,
        .eql_eql, .bang_eql => .eq,
        else => unreachable,
    };
}

pub fn flipCompare(op: ir.CompareOp) ir.CompareOp {
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
