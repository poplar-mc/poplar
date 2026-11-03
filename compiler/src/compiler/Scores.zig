// Score math: computing into a score, operands, temps and constants.
const std = @import("std");
const Compiler = @import("../Compiler.zig");
const Ast = @import("../Ast.zig");
const Environment = @import("../Environment.zig");
const Ir = @import("../Ir.zig");
const Token = @import("../Token.zig");
const Writer = @import("../Writer.zig");
const Calls = @import("Calls.zig");
const Data = @import("Data.zig");
const Declarations = @import("Declarations.zig");
const Values = @import("Values.zig");

pub fn compileScoreAssign(self: *Compiler, identifier: Ast.Identifier, expression: *const Ast.Expr, env: *Environment, commands: *std.ArrayList(Ir.Command)) Compiler.CompileError!void {
    const target = try resolveScore(self, identifier, env) orelse return;
    self.temp_count = 0;

    if (isSafeInPlace(expression, identifier)) return compileInto(self, target, expression, env, commands);
    if (try swappedInPlace(self, expression, identifier)) |swapped| return compileInto(self, target, swapped, env, commands);

    const temp = try newTemp(self);
    try compileInto(self, temp, expression, env, commands);
    try appendOperation(self, commands, target, .assign, temp);
}

// `#n = 3 + #n` is the same as `#n = #n + 3`, which is computed in `#n` with no temp.
pub fn swappedInPlace(self: *Compiler, expression: *const Ast.Expr, target: Ast.Identifier) Compiler.CompileError!?*const Ast.Expr {
    if (expression.kind != .infix) return null;
    const infix = expression.kind.infix;
    if (infix.op != .plus and infix.op != .star) return null;
    if (infix.right.kind != .identifier or !referencesScore(infix.right, target) or referencesScore(infix.left, target)) return null;
    return try self.createExpr(.{ .line = expression.line, .column = expression.column, .kind = .{ .infix = .{ .op = infix.op, .left = infix.right, .right = infix.left } } });
}

pub fn compileInto(self: *Compiler, target: Ir.Score, expression: *const Ast.Expr, env: *Environment, commands: *std.ArrayList(Ir.Command)) Compiler.CompileError!void {
    const outer_position = self.enterExpression(expression);
    defer self.restorePosition(outer_position);
    if (!Values.containsRuntimeValue(self, expression, env)) {
        const value = try Values.evaluate(self, expression, env) orelse return;
        const number = try toScoreValue(self, value) orelse return;
        return commands.append(self.gpa, .{ .score_set = .{ .score = target, .value = number } });
    }

    switch (expression.kind) {
        .identifier => |identifier| {
            if (identifier.storage == .compile_time) {
                return commands.append(self.gpa, .{ .score_set_param = .{ .score = target, .param = identifier.name } });
            }
            if (identifier.storage == .data or identifier.storage == .entity_data) {
                const source = try Data.dataPathOf(self, identifier, env) orelse return;
                return commands.append(self.gpa, .{ .data_to_score = .{ .source = source, .score = target } });
            }

            const source = try resolveScore(self, identifier, env) orelse return;
            if (source.eql(target)) return;
            if (!try checkSingleEntity(self, identifier)) return;
            try appendOperation(self, commands, target, .assign, source);
        },
        .prefix => |prefix| {
            if (prefix.op != .minus) {
                return self.addError("operator '{s}' cannot be used with scores", .{Values.operatorText(prefix.op)});
            }
            try compileInto(self, target, prefix.operand, env, commands);
            try appendOperation(self, commands, target, .mul, try constantScore(self, -1));
        },
        .infix => |infix| {
            const op = scoreOperator(infix.op) orelse {
                return self.addError("operator '{s}' on scores needs 'if' (not supported yet)", .{Values.operatorText(infix.op)});
            };
            try compileInto(self, target, infix.left, env, commands);
            try applyOperand(self, target, op, infix.right, env, commands);
        },
        .call => |call| {
            if (Calls.isBuiltinCall(call, "len")) return Data.compileLength(self, target, call, env, commands);
            if (Data.isStringCall(call)) return self.addError("'{s}' gives a string, so it cannot be a score. Store it in data: '$x = {s}(...);'", .{ call.callee.kind.identifier.name, call.callee.kind.identifier.name });
            if (Data.isStringTest(call)) return self.addError("'{s}' is a condition. Use it in 'if' or 'while'", .{call.callee.kind.identifier.name});
            const found = try Declarations.findMcfn(self, call) orelse return;
            // Temps made after this point hold arguments. They are not needed after the call.
            const live_count = self.temp_count;
            const run = try Calls.compileMcfnCall(self, call, found.located, env, commands) orelse return;
            self.temp_count = live_count;
            const store: Ir.Command = .{ .store_result = .{ .target = .{ .score = target }, .run = try self.createCommand(run) } };

            if (!try Calls.canReach(self, found.key, self.mcfun.key)) return commands.append(self.gpa, store);
            try Calls.appendWithSavedValues(self, store, target, live_count, commands);
        },
        .cast => try self.addError(Values.cast_error, .{}),
        else => try self.addError("this expression cannot be used with scores", .{}),
    }
}

pub fn applyOperand(self: *Compiler, target: Ir.Score, op: Ir.Operator, operand: *const Ast.Expr, env: *Environment, commands: *std.ArrayList(Ir.Command)) Compiler.CompileError!void {
    const outer_position = self.enterExpression(operand);
    defer self.restorePosition(outer_position);
    if (!Values.containsRuntimeValue(self, operand, env)) {
        const value = try Values.evaluate(self, operand, env) orelse return;
        const number = try toScoreValue(self, value) orelse return;

        if ((op == .add or op == .sub) and number != std.math.minInt(i32)) {
            const score_value: Ir.ScoreValue = .{ .score = target, .value = if (number < 0) -number else number };
            const is_add = (op == .add) == (number >= 0);
            return commands.append(self.gpa, if (is_add) .{ .score_add = score_value } else .{ .score_remove = score_value });
        }

        if ((op == .div or op == .mod) and number == 0) return self.addError("division by zero", .{});

        return appendOperation(self, commands, target, op, try constantScore(self, number));
    }

    if (operand.kind == .identifier and operand.kind.identifier.storage == .score) {
        const source = try scoreSource(self, operand.kind.identifier, env) orelse return;
        return appendOperation(self, commands, target, op, source);
    }

    const temp = try newTemp(self);
    try compileInto(self, temp, operand, env, commands);
    try appendOperation(self, commands, target, op, temp);
}

pub fn appendOperation(self: *Compiler, commands: *std.ArrayList(Ir.Command), target: Ir.Score, op: Ir.Operator, source: Ir.Score) Compiler.CompileError!void {
    try commands.append(self.gpa, .{ .score_operation = .{ .target = target, .op = op, .source = source } });
}

// Resolves a score that is read. An entity score must name one entity.
pub fn scoreSource(self: *Compiler, identifier: Ast.Identifier, env: *const Environment) Compiler.CompileError!?Ir.Score {
    const score = try resolveScore(self, identifier, env) orelse return null;
    if (!try checkSingleEntity(self, identifier)) return null;
    return score;
}

// `#x` is the global value of objective `<ns>.x`. `@s.#x` is the value of an entity in the same objective.
// A local `#x` is the fake player `#x_<mcfun>` in `<ns>`.
pub fn resolveScore(self: *Compiler, identifier: Ast.Identifier, env: *const Environment) Compiler.CompileError!?Ir.Score {
    if (Compiler.localOf(env, '#', identifier.name)) |local| {
        if (identifier.selector != null) {
            try self.addError("'#{s}' is local, so it has no entity values. Declare it at the top level", .{identifier.name});
            return null;
        }
        return .{ .holder = local.generated_name, .owner = local.owner, .namespace = self.scope.output_namespace };
    }
    const namespace = try Declarations.resolveNamespace(self, identifier.namespace) orelse return null;
    const global = self.globals.get(try Declarations.qualifiedKey(self, namespace, identifier.name)) orelse {
        try self.addError("unknown score '#{s}'", .{identifier.name});
        return null;
    };
    return .{ .holder = identifier.selector orelse Compiler.global_holder, .objective = global.name, .namespace = global.output_namespace };
}

pub fn checkSingleEntity(self: *Compiler, identifier: Ast.Identifier) Compiler.CompileError!bool {
    const selector = identifier.selector orelse return true;
    if (isSingleEntitySelector(selector)) return true;

    const sigil = if (identifier.storage == .entity_data) "$" else "#";
    try self.addError("'{s}.{s}{s}' needs a selector for one entity (@s, @p, @r, @n or limit=1)", .{ selector, sigil, identifier.name });
    return false;
}

pub fn isSingleEntitySelector(selector: []const u8) bool {
    if (std.mem.indexOfScalar(u8, "sprn", selector[1]) != null) return true;

    const limit_start = std.mem.indexOf(u8, selector, "limit=1") orelse return false;
    const after = limit_start + "limit=1".len;
    return after < selector.len and (selector[after] == ',' or selector[after] == ']');
}

pub fn toScoreValue(self: *Compiler, value: Compiler.Value) Compiler.CompileError!?i32 {
    if (value != .number) {
        try self.addError("a score must hold a number, found {s}", .{@tagName(value)});
        return null;
    }

    return std.math.cast(i32, value.number) orelse {
        try self.addError("value {d} does not fit in a score (32-bit)", .{value.number});
        return null;
    };
}

pub fn globalScore(global: Compiler.GlobalScore) Ir.Score {
    return .{ .holder = Compiler.global_holder, .objective = global.name, .namespace = global.output_namespace };
}

pub fn constantScore(self: *Compiler, value: i32) Compiler.CompileError!Ir.Score {
    try self.constants.put(self.gpa, value, {});
    return .{ .holder = try std.fmt.allocPrint(self.gpa, "#poplar.c{d}", .{value}) };
}

pub fn newTemp(self: *Compiler) Compiler.CompileError!Ir.Score {
    defer self.temp_count += 1;
    return tempScore(self, self.temp_count);
}

// Each mcfun has its own temps, so a call to another mcfun cannot overwrite them.
pub fn tempScore(self: *Compiler, index: usize) Compiler.CompileError!Ir.Score {
    return .{ .holder = try std.fmt.allocPrint(self.gpa, "#poplar.{s}.t{d}", .{ self.mcfun.folder, index }), .namespace = self.scope.output_namespace };
}

pub fn scoreOperator(op: Token.TokenType) ?Ir.Operator {
    return switch (op) {
        .plus => .add,
        .minus => .sub,
        .star => .mul,
        .slash => .div,
        .percent => .mod,
        else => null,
    };
}

pub fn referencesScore(expression: *const Ast.Expr, target: Ast.Identifier) bool {
    return switch (expression.kind) {
        .identifier => |identifier| identifier.storage == .score and
            std.mem.eql(u8, identifier.name, target.name) and
            std.mem.eql(u8, identifier.selector orelse "", target.selector orelse ""),
        .prefix => |prefix| referencesScore(prefix.operand, target),
        .infix => |infix| referencesScore(infix.left, target) or referencesScore(infix.right, target),
        else => false,
    };
}

// The target can only be computed in place if it is read before it is first written,
// which is true when it appears only as the leftmost operand.
pub fn isSafeInPlace(expression: *const Ast.Expr, target: Ast.Identifier) bool {
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
        \\scoreboard players operation #poplar.f.t0 ns = #global ns.b
        \\execute store result score #global ns.a run scoreboard players operation #poplar.f.t0 ns -= #global ns.a
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
        \\scoreboard objectives add ns dummy
        \\scoreboard objectives add ns.mana dummy
        \\scoreboard objectives add ns.max dummy
        \\execute unless score #global ns.max matches -2147483648.. run scoreboard players set #global ns.max 100
        \\
    , try Writer.renderFunction(arena.allocator(), "ns", program.load.?));
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
    try std.testing.expectEqual(3, errors.len);
    try std.testing.expectEqualStrings("'@a.#mana' needs a selector for one entity (@s, @p, @r, @n or limit=1)", errors[0].message);
    try std.testing.expectEqualStrings("expected a subcommand, found 'az'", errors[1].message);
    try std.testing.expectEqual(14, errors[1].column);
    try std.testing.expectEqualStrings("a score or math in entity data needs its NBT type: '@s.$Health = ... as float;' (byte, short, int, long, float, double)", errors[2].message);
}
