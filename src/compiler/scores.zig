// Score math: computing into a score, operands, temps and constants.
const std = @import("std");
const Compiler = @import("../Compiler.zig");
const ast = @import("../ast.zig");
const Environment = @import("../Environment.zig");
const ir = @import("../ir.zig");
const Token = @import("../Token.zig");
const datapack_writer = @import("../datapack_writer.zig");
const calls = @import("calls.zig");
const data = @import("data.zig");
const declarations = @import("declarations.zig");
const values = @import("values.zig");

pub fn compileScoreAssign(compiler: *Compiler, identifier: ast.Identifier, expression: *const ast.Expression, env: *Environment, commands: *std.ArrayList(ir.Command)) Compiler.CompileError!void {
    const target = try resolveScore(compiler, identifier, env) orelse return;
    compiler.temp_count = 0;

    if (isSafeInPlace(expression, identifier)) return compileInto(compiler, target, expression, env, commands);
    if (try swappedInPlace(compiler, expression, identifier)) |swapped| return compileInto(compiler, target, swapped, env, commands);

    const temp = try newTemp(compiler);
    try compileInto(compiler, temp, expression, env, commands);
    try appendOperation(compiler, commands, target, .assign, temp);
}

// `#n = 3 + #n` is the same as `#n = #n + 3`, which is computed in `#n` with no temp.
pub fn swappedInPlace(compiler: *Compiler, expression: *const ast.Expression, target: ast.Identifier) Compiler.CompileError!?*const ast.Expression {
    if (expression.kind != .infix) return null;
    const infix = expression.kind.infix;
    if (infix.op != .plus and infix.op != .star) return null;
    if (infix.right.kind != .identifier or !referencesScore(infix.right, target) or referencesScore(infix.left, target)) return null;
    return try compiler.createExpression(.{ .line = expression.line, .column = expression.column, .kind = .{ .infix = .{ .op = infix.op, .left = infix.right, .right = infix.left } } });
}

pub fn compileInto(compiler: *Compiler, target: ir.Score, expression: *const ast.Expression, env: *Environment, commands: *std.ArrayList(ir.Command)) Compiler.CompileError!void {
    const outer_position = compiler.enterExpression(expression);
    defer compiler.restorePosition(outer_position);
    if (!values.containsRuntimeValue(compiler, expression, env)) {
        const value = try values.evaluate(compiler, expression, env) orelse return;
        const number = try toScoreValue(compiler, value) orelse return;
        return commands.append(compiler.gpa, .{ .score_set = .{ .score = target, .value = number } });
    }

    switch (expression.kind) {
        .macro_key => |name| return commands.append(compiler.gpa, .{ .score_set_macro_argument = .{ .score = target, .macro_argument = name } }),
        .identifier => |identifier| {
            if (identifier.kind == .data or identifier.kind == .entity_data) {
                const source = try data.dataPathOf(compiler, identifier, env) orelse return;
                return commands.append(compiler.gpa, .{ .data_to_score = .{ .source = source, .score = target } });
            }

            const source = try resolveScore(compiler, identifier, env) orelse return;
            if (source.eql(target)) return;
            if (!try checkSingleEntity(compiler, identifier)) return;
            try appendOperation(compiler, commands, target, .assign, source);
        },
        .prefix => |prefix| {
            if (prefix.op != .minus) {
                return compiler.addError("operator '{s}' cannot be used with scores", .{values.operatorText(prefix.op)});
            }
            try compileInto(compiler, target, prefix.operand, env, commands);
            try appendOperation(compiler, commands, target, .mul, try constantScore(compiler, -1));
        },
        .infix => |infix| {
            const op = scoreOperator(infix.op) orelse {
                return compiler.addError("operator '{s}' on scores needs 'if' (not supported yet)", .{values.operatorText(infix.op)});
            };
            try compileInto(compiler, target, infix.left, env, commands);
            try applyOperand(compiler, target, op, infix.right, env, commands);
        },
        .call => |call| {
            if (calls.isBuiltinCall(call, "len")) return data.compileLength(compiler, target, call, env, commands);
            if (data.isStringCall(call)) return compiler.addError("'{s}' gives a string, so it cannot be a score. Store it in data: '$x = {s}(...);'", .{ call.callee.kind.identifier.name, call.callee.kind.identifier.name });
            if (data.isStringTest(call)) return compiler.addError("'{s}' is a condition. Use it in 'if' or 'while'", .{call.callee.kind.identifier.name});
            if (call.callee.kind != .identifier) return compiler.addError("only an mcfun call can be used as a runtime value", .{});
            const found = try declarations.findMcfun(compiler, call.callee.kind.identifier) orelse return;
            // Temps made after this point hold arguments. They are not needed after the call.
            const live_count = compiler.temp_count;
            const run = try calls.compileMcfunCall(compiler, call, found.declaration, env, commands) orelse return;
            compiler.temp_count = live_count;
            const store: ir.Command = .{ .store_result = .{ .target = .{ .score = target }, .run = try compiler.createCommand(run) } };

            if (!try calls.canReach(compiler, found.key, compiler.mcfun.key)) return commands.append(compiler.gpa, store);
            try calls.appendWithSavedValues(compiler, store, target, live_count, commands);
        },
        else => try compiler.addError("this expression cannot be used with scores", .{}),
    }
}

pub fn applyOperand(compiler: *Compiler, target: ir.Score, op: ir.Operator, operand: *const ast.Expression, env: *Environment, commands: *std.ArrayList(ir.Command)) Compiler.CompileError!void {
    const outer_position = compiler.enterExpression(operand);
    defer compiler.restorePosition(outer_position);
    if (!values.containsRuntimeValue(compiler, operand, env)) {
        const value = try values.evaluate(compiler, operand, env) orelse return;
        const number = try toScoreValue(compiler, value) orelse return;

        if ((op == .add or op == .sub) and number != std.math.minInt(i32)) {
            const score_value: ir.ScoreValue = .{ .score = target, .value = if (number < 0) -number else number };
            const is_add = (op == .add) == (number >= 0);
            return commands.append(compiler.gpa, if (is_add) .{ .score_add = score_value } else .{ .score_remove = score_value });
        }

        if ((op == .div or op == .mod) and number == 0) return compiler.addError("division by zero", .{});

        return appendOperation(compiler, commands, target, op, try constantScore(compiler, number));
    }

    if (operand.kind == .identifier and operand.kind.identifier.kind == .score) {
        const source = try scoreSource(compiler, operand.kind.identifier, env) orelse return;
        return appendOperation(compiler, commands, target, op, source);
    }

    const temp = try newTemp(compiler);
    try compileInto(compiler, temp, operand, env, commands);
    try appendOperation(compiler, commands, target, op, temp);
}

pub fn appendOperation(compiler: *Compiler, commands: *std.ArrayList(ir.Command), target: ir.Score, op: ir.Operator, source: ir.Score) Compiler.CompileError!void {
    try commands.append(compiler.gpa, .{ .score_operation = .{ .target = target, .op = op, .source = source } });
}

// Resolves a score that is read. An entity score must name one entity.
pub fn scoreSource(compiler: *Compiler, identifier: ast.Identifier, env: *const Environment) Compiler.CompileError!?ir.Score {
    const score = try resolveScore(compiler, identifier, env) orelse return null;
    if (!try checkSingleEntity(compiler, identifier)) return null;
    return score;
}

// `#x` is the global value of objective `<ns>.x`. `@s.#x` is the value of an entity in the same objective.
// A local `#x` is the fake player `#x_<mcfun>` in `<ns>`.
pub fn resolveScore(compiler: *Compiler, identifier: ast.Identifier, env: *const Environment) Compiler.CompileError!?ir.Score {
    if (Compiler.localOf(env, '#', identifier.name)) |local| {
        if (identifier.selector != null) {
            try compiler.addError("'#{s}' is local, so it has no entity values. Declare it at the top level", .{identifier.name});
            return null;
        }
        return .{ .holder = local.generated_name, .owner = local.owner, .namespace = compiler.scope.output_namespace };
    }
    const namespace = try declarations.resolveNamespace(compiler, identifier.namespace) orelse return null;
    const global = compiler.globals.get(try declarations.qualifiedKey(compiler, namespace, identifier.name)) orelse {
        try compiler.addError("unknown score '#{s}'", .{identifier.name});
        return null;
    };
    return .{ .holder = identifier.selector orelse Compiler.global_holder, .objective = global.name, .namespace = global.output_namespace };
}

pub fn checkSingleEntity(compiler: *Compiler, identifier: ast.Identifier) Compiler.CompileError!bool {
    const selector = identifier.selector orelse return true;
    if (try compiler.command_tree.checkSelector(compiler.gpa, selector)) |failure| {
        try compiler.addError("{s}", .{failure.message});
        return false;
    }
    if (isSingleEntitySelector(selector)) return true;

    const sigil = if (identifier.kind == .entity_data) "$" else "#";
    try compiler.addError("'{s}.{s}{s}' needs a selector for one entity (@s, @p, @r, @n or limit=1)", .{ selector, sigil, identifier.name });
    return false;
}

pub fn isSingleEntitySelector(selector: []const u8) bool {
    if (std.mem.indexOfScalar(u8, "sprn", selector[1]) != null) return true;

    const limit_start = std.mem.indexOf(u8, selector, "limit=1") orelse return false;
    const after = limit_start + "limit=1".len;
    return after < selector.len and (selector[after] == ',' or selector[after] == ']');
}

pub fn toScoreValue(compiler: *Compiler, value: Compiler.Value) Compiler.CompileError!?i32 {
    if (value == .typed_number) {
        const number = value.typed_number;
        if (number.hasFraction()) {
            try compiler.addError("a score holds whole numbers, so it cannot hold '{s}'", .{number.text});
        } else {
            try compiler.addError("a score has no number types: write '{s}' with no suffix", .{number.text});
        }
        return null;
    }
    if (value != .number) {
        try compiler.addError("a score must hold a number, found {s}", .{@tagName(value)});
        return null;
    }

    return std.math.cast(i32, value.number) orelse {
        try compiler.addError("value {d} does not fit in a score (32-bit)", .{value.number});
        return null;
    };
}

pub fn globalScore(global: Compiler.GlobalScore) ir.Score {
    return .{ .holder = Compiler.global_holder, .objective = global.name, .namespace = global.output_namespace };
}

pub fn constantScore(compiler: *Compiler, value: i32) Compiler.CompileError!ir.Score {
    try compiler.constants.put(compiler.gpa, value, {});
    return .{ .holder = try std.fmt.allocPrint(compiler.gpa, "#poplar.c{d}", .{value}) };
}

pub fn newTemp(compiler: *Compiler) Compiler.CompileError!ir.Score {
    defer compiler.temp_count += 1;
    return tempScore(compiler, compiler.temp_count);
}

// Each mcfun has its own temps, so a call to another mcfun cannot overwrite them.
pub fn tempScore(compiler: *Compiler, index: usize) Compiler.CompileError!ir.Score {
    return .{ .holder = try std.fmt.allocPrint(compiler.gpa, "#poplar.{s}.t{d}", .{ compiler.mcfun.folder, index }), .namespace = compiler.scope.output_namespace };
}

pub fn scoreOperator(op: Token.Tag) ?ir.Operator {
    return switch (op) {
        .plus => .add,
        .minus => .sub,
        .star => .mul,
        .slash => .div,
        .percent => .mod,
        else => null,
    };
}

pub fn referencesScore(expression: *const ast.Expression, target: ast.Identifier) bool {
    return switch (expression.kind) {
        .identifier => |identifier| identifier.kind == .score and
            std.mem.eql(u8, identifier.name, target.name) and
            std.mem.eql(u8, identifier.selector orelse "", target.selector orelse ""),
        .prefix => |prefix| referencesScore(prefix.operand, target),
        .infix => |infix| referencesScore(infix.left, target) or referencesScore(infix.right, target),
        else => false,
    };
}

// The target can only be computed in place if it is read before it is first written,
// which is true when it appears only as the leftmost operand.
pub fn isSafeInPlace(expression: *const ast.Expression, target: ast.Identifier) bool {
    return switch (expression.kind) {
        .infix => |infix| isSafeInPlace(infix.left, target) and !referencesScore(infix.right, target),
        .prefix => |prefix| isSafeInPlace(prefix.operand, target),
        else => true,
    };
}

test "lowers score expression in place" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    var compiler = try Compiler.compileForTest(arena.allocator(),
        \\var #a = 0;
        \\var #b = 1;
        \\var #c = 2;
        \\mcfun f() { #a = (#b + 3) * #c; }
    );
    const program = try compiler.compile();
    try std.testing.expectEqual(0, compiler.errors.items.len);

    try std.testing.expectEqualStrings(
        \\scoreboard players operation #global ns.a = #global ns.b
        \\scoreboard players add #global ns.a 3
        \\scoreboard players operation #global ns.a *= #global ns.c
        \\
    , try Compiler.renderForTest(arena.allocator(), program, "f"));
}

test "uses temp when target is read after write" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    var compiler = try Compiler.compileForTest(arena.allocator(),
        \\var #a = 0;
        \\var #b = 1;
        \\mcfun f() { #a = #b - #a; }
    );
    const program = try compiler.compile();
    try std.testing.expectEqual(0, compiler.errors.items.len);

    try std.testing.expectEqualStrings(
        \\scoreboard players operation #poplar.f.t0 poplar.ns = #global ns.b
        \\execute store result score #global ns.a run scoreboard players operation #poplar.f.t0 poplar.ns -= #global ns.a
        \\
    , try Compiler.renderForTest(arena.allocator(), program, "f"));
}

test "entity scores and execute blocks" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    var compiler = try Compiler.compileForTest(arena.allocator(),
        \\var #mana = 0;
        \\var #max = 100;
        \\mcfun tick() {
        \\    @a.#mana = 0;
        \\    execute (as @a at @s) {
        \\        @s.#mana = @s.#mana + 1;
        \\        if (@s.#mana > #max) { @s.#mana = #max; }
        \\        /particle heart ~ ~2 ~;
        \\    }
        \\}
    );
    const program = try compiler.compile();
    try std.testing.expectEqual(0, compiler.errors.items.len);

    try std.testing.expectEqualStrings(
        \\scoreboard players set @a ns.mana 0
        \\execute as @a at @s run function ns:poplar/tick/execute_0
        \\
    , try Compiler.renderForTest(arena.allocator(), program, "tick"));
    try std.testing.expectEqualStrings(
        \\scoreboard players add @s ns.mana 1
        \\execute if score @s ns.mana > #global ns.max run scoreboard players operation @s ns.mana = #global ns.max
        \\particle heart ~ ~2 ~
        \\
    , try Compiler.renderForTest(arena.allocator(), program, "poplar/tick/execute_0"));
    try std.testing.expectEqualStrings(
        \\scoreboard objectives add poplar.ns dummy
        \\scoreboard objectives add ns.mana dummy
        \\scoreboard objectives add ns.max dummy
        \\execute unless score #global ns.max matches -2147483648.. run scoreboard players set #global ns.max 100
        \\
    , try datapack_writer.renderFunction(arena.allocator(), "ns", program.load.?));
}

test "entity score errors" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    var compiler = try Compiler.compileForTest(arena.allocator(),
        \\var #mana = 0;
        \\mcfun main() {
        \\    #mana = @a.#mana;
        \\    execute (az @a) { /say hi; }
        \\    @s.$Health = #mana;
        \\}
    );
    _ = try compiler.compile();

    const errors = compiler.errors.items;
    try std.testing.expectEqual(2, errors.len);
    try std.testing.expectEqualStrings("'@a.#mana' needs a selector for one entity (@s, @p, @r, @n or limit=1)", errors[0].message);
    try std.testing.expectEqualStrings("expected a subcommand, found 'az'", errors[1].message);
    try std.testing.expectEqual(14, errors[1].column);
}
