//! `if` and `while` conditions: comparisons, data tests and Minecraft checks, in OR-of-ANDs form.

const std = @import("std");
const Compiler = @import("../Compiler.zig");
const ast = @import("../ast.zig");
const Environment = @import("../Environment.zig");
const ir = @import("../ir.zig");
const data = @import("data.zig");
const minecraft_text = @import("minecraft_text.zig");
const scores = @import("scores.zig");
const values = @import("values.zig");

pub fn lowerCondition(compiler: *Compiler, expression: *const ast.Expression, env: *Environment, negated: bool, setup: *std.ArrayList(ir.Command)) Compiler.Error!Compiler.Condition {
    const outer_position = compiler.enterExpression(expression);
    defer compiler.restorePosition(outer_position);
    if (!values.containsRuntimeValue(compiler, expression, env)) {
        const value = try values.evaluate(compiler, expression, env);
        if (value != .boolean) {
            return compiler.fail("a condition must be a comparison, a data path, true or false, found {s}", .{@tagName(value)});
        }
        return .{ .constant = value.boolean != negated };
    }

    switch (expression.kind) {
        .prefix => |prefix| if (prefix.op == .not) return lowerCondition(compiler, prefix.operand, env, !negated, setup),
        .infix => |infix| switch (infix.op) {
            .@"and", .@"or" => {
                const left = try lowerCondition(compiler, infix.left, env, negated, setup);
                const right = try lowerCondition(compiler, infix.right, env, negated, setup);

                const is_and = (infix.op == .@"and") != negated;
                return if (is_and) try combineAnd(compiler, left, right) else try combineOr(compiler, left, right);
            },
            .less, .less_equal, .greater, .greater_equal, .equal, .not_equal => {
                return lowerComparison(compiler, infix, env, negated, setup);
            },
            else => {},
        },
        .call => |call| if (data.isStringTest(call)) return data.stringTest(compiler, call, env, negated, setup),
        .minecraft_check => |parts| return minecraftCheck(compiler, parts, expression.position.column, env, negated),
        // `if ($x)` is Minecraft's `if data`: the path exists, whatever its value. A bool needs `== true`.
        .identifier => |identifier| if (identifier.kind == .data or identifier.kind == .entity_data) {
            const path = try data.dataPathOf(compiler, identifier, env);
            return try singleCheck(compiler, .{ .negated = negated, .condition = .{ .data_test = path } });
        },
        else => {},
    }

    if (expression.kind == .identifier and expression.kind.identifier.kind == .score) {
        return compiler.fail("a score needs a comparison in a condition: 'if (#{s} != 0)'", .{expression.kind.identifier.name});
    }
    return compiler.fail("a condition must be a comparison, a data path, or 'and', 'or' and '!' of those", .{});
}

/// `block ~ ~-1 ~ stone` → `if block ~ ~-1 ~ stone`, checked like the subcommands of `execute (...)`.
fn minecraftCheck(compiler: *Compiler, parts: []const ast.CommandPart, column: usize, env: *Environment, negated: bool) Compiler.Error!Compiler.Condition {
    const check = try minecraft_text.buildCommandText(compiler, parts, env);
    if (check.is_macro) {
        return compiler.fail("a game value in a Minecraft check is not supported yet. Use 'execute (if ...) {{ }}'", .{});
    }

    const text = try minecraft_text.checkMinecraftText(compiler, parts, check, column, "execute if ", " run say x");
    return try singleCheck(compiler, .{ .negated = negated, .condition = .{ .raw = text } });
}

/// `$name == "Steve"` → `if data storage ns:data {name:"Steve"}`. The path becomes a nested filter.
fn dataCondition(compiler: *Compiler, identifier: ast.Identifier, value: Compiler.Value, negated: bool, env: *const Environment) Compiler.Error!Compiler.Condition {
    const path = try data.dataPathOf(compiler, identifier, env);
    if (std.mem.indexOfAny(u8, path.path, "[\"") != null) {
        return compiler.fail("a condition on '{s}' is not supported yet: the path must only have keys", .{identifier.name});
    }

    var filter: std.ArrayList(u8) = .empty;
    var keys = std.mem.splitScalar(u8, path.path, '.');
    var depth: usize = 0;
    while (keys.next()) |key| : (depth += 1) try filter.print(compiler.arena, "{{{s}:", .{key});
    // Minecraft stores a bool as a byte, so the filter says `1b` or `0b`.
    const snbt = if (value == .boolean) (if (value.boolean) "1b" else "0b") else try values.valueToSnbt(compiler, value);
    try filter.appendSlice(compiler.arena, snbt);
    try filter.appendNTimes(compiler.arena, '}', depth);

    return try singleCheck(compiler, .{ .negated = negated, .condition = .{ .data_test = path.withPath(try filter.toOwnedSlice(compiler.arena)) } });
}

fn lowerComparison(compiler: *Compiler, infix: ast.Infix, env: *Environment, negated: bool, setup: *std.ArrayList(ir.Command)) Compiler.Error!Compiler.Condition {
    const check_negated = negated != (infix.op == .not_equal);
    const op = compareOperator(infix.op);

    if ((infix.op == .equal or infix.op == .not_equal) and isNbtFilterComparison(compiler, infix.left, infix.right, env)) {
        if (data.isDataIdentifier(infix.left)) return dataComparison(compiler, infix.left, infix.right, env, check_negated);
        if (data.isDataIdentifier(infix.right)) return dataComparison(compiler, infix.right, infix.left, env, check_negated);
    }

    const left = try lowerOperand(compiler, infix.left, env, setup);
    const right = try lowerOperand(compiler, infix.right, env, setup);

    // At least one side has a score, so two numbers cannot happen here.
    return switch (left) {
        .number => |number| try matchesCondition(compiler, right.score, flipCompare(op), number, check_negated),
        .score => |left_score| switch (right) {
            .number => |number| try matchesCondition(compiler, left_score, op, number, check_negated),
            .score => |right_score| try singleCheck(compiler, .{
                .negated = check_negated,
                .condition = .{ .compare = .{ .left = left_score, .op = op, .right = right_score } },
            }),
        },
    };
}

/// `==` between data and a compile-time string, bool, list, compound or typed number is an NBT filter.
/// A number comparison still goes through a score, which also works for other number types.
fn dataComparison(compiler: *Compiler, data_side: *const ast.Expression, other: *const ast.Expression, env: *Environment, negated: bool) Compiler.Error!Compiler.Condition {
    const outer_position = compiler.enterExpression(other);
    defer compiler.restorePosition(outer_position);
    if (values.containsRuntimeValue(compiler, other, env)) {
        return compiler.fail("comparing two runtime values that are not numbers is not supported yet", .{});
    }
    const value = try values.evaluate(compiler, other, env);
    return dataCondition(compiler, data_side.kind.identifier, value, negated, env);
}

/// True when one side is data and the other is a compile-time value that is not a plain int.
fn isNbtFilterComparison(compiler: *Compiler, left: *const ast.Expression, right: *const ast.Expression, env: *Environment) bool {
    if (!data.isDataIdentifier(left) and !data.isDataIdentifier(right)) return false;
    for ([_]*const ast.Expression{ left, right }) |side| {
        if (data.isDataIdentifier(side) or values.containsRuntimeValue(compiler, side, env)) continue;
        switch (side.kind) {
            .string, .boolean, .list, .compound, .typed_number => return true,
            .prefix => |prefix| if (prefix.operand.kind == .typed_number) return true,
            else => {},
        }
    }
    return false;
}

fn lowerOperand(compiler: *Compiler, expression: *const ast.Expression, env: *Environment, setup: *std.ArrayList(ir.Command)) Compiler.Error!Compiler.Operand {
    const outer_position = compiler.enterExpression(expression);
    defer compiler.restorePosition(outer_position);
    if (!values.containsRuntimeValue(compiler, expression, env)) {
        const value = try values.evaluate(compiler, expression, env);
        if (value == .typed_number) {
            return compiler.fail("a score holds whole numbers with no suffix, so it cannot be compared with '{s}'", .{value.typed_number.text});
        }
        if (value != .number) {
            return compiler.fail("only numbers can be compared with scores, found {s}", .{@tagName(value)});
        }
        return .{ .number = value.number };
    }

    if (expression.kind == .identifier and expression.kind.identifier.kind == .score) {
        return .{ .score = try scores.scoreSource(compiler, expression.kind.identifier, env) };
    }

    const temp = try scores.newTemp(compiler);
    try scores.compileInto(compiler, temp, expression, env, setup);
    return .{ .score = temp };
}

fn matchesCondition(compiler: *Compiler, score: ir.Score, op: ir.CompareOp, number: i64, negated: bool) std.mem.Allocator.Error!Compiler.Condition {
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
        .condition = .{ .matches = .{ .score = score, .min = range_min, .max = range_max } },
    });
}

pub fn singleCheck(compiler: *Compiler, check: ir.Check) std.mem.Allocator.Error!Compiler.Condition {
    const checks = try compiler.arena.dupe(ir.Check, &.{check});
    return .{ .clauses = try compiler.arena.dupe([]const ir.Check, &.{checks}) };
}

fn combineAnd(compiler: *Compiler, left: Compiler.Condition, right: Compiler.Condition) std.mem.Allocator.Error!Compiler.Condition {
    if (left == .constant) return if (left.constant) right else left;
    if (right == .constant) return if (right.constant) left else right;

    var clauses: std.ArrayList([]const ir.Check) = .empty;
    for (left.clauses) |left_checks| {
        for (right.clauses) |right_checks| {
            try clauses.append(compiler.arena, try std.mem.concat(compiler.arena, ir.Check, &.{ left_checks, right_checks }));
        }
    }

    return .{ .clauses = try clauses.toOwnedSlice(compiler.arena) };
}

fn combineOr(compiler: *Compiler, left: Compiler.Condition, right: Compiler.Condition) std.mem.Allocator.Error!Compiler.Condition {
    if (left == .constant) return if (left.constant) left else right;
    if (right == .constant) return if (right.constant) right else left;

    return .{ .clauses = try std.mem.concat(compiler.arena, []const ir.Check, &.{ left.clauses, right.clauses }) };
}

fn compareOperator(op: ast.Infix.Operator) ir.CompareOp {
    return switch (op) {
        .less => .lt,
        .less_equal => .le,
        .greater => .gt,
        .greater_equal => .ge,
        .equal, .not_equal => .eq,
        else => unreachable,
    };
}

fn flipCompare(op: ir.CompareOp) ir.CompareOp {
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
    try std.testing.expectEqual(21, compiler.errors.items[0].position.?.column);

    try std.testing.expectEqualStrings(
        \\execute if block ~ ~-1 ~ #minecraft:logs if score #global ns.mana matches 6.. run say log
        \\execute unless predicate ns:is_sitting run return run say hi
        \\execute if entity @s[type=pig] run return run say hi
        \\
    , try Compiler.renderForTest(arena.allocator(), program, "main"));
}
