// mcfun calls: arguments, the call graph, and saving values around a recursive call.
const std = @import("std");
const Compiler = @import("../Compiler.zig");
const Ast = @import("../Ast.zig");
const Commands = @import("../Commands.zig");
const Environment = @import("../Environment.zig");
const Ir = @import("../Ir.zig");
const Data = @import("Data.zig");
const Declarations = @import("Declarations.zig");
const Load = @import("Load.zig");
const MinecraftText = @import("MinecraftText.zig");
const Scores = @import("Scores.zig");
const Values = @import("Values.zig");

// Returns the command that calls an mcfun. Commands that prepare runtime arguments go into `commands` first.
pub fn compileMcfnCall(self: *Compiler, call: Ast.Call, located: Compiler.Located, env: *Environment, commands: *std.ArrayList(Ir.Command)) Compiler.CompileError!?Ir.Command {
    const function = located.function;
    if (call.args.len != function.params.len) {
        try self.addError("mcfun '{s}' expects {d} arguments, found {d}", .{ function.name, function.params.len, call.args.len });
        return null;
    }
    if (function.params.len == 0) return .{ .function = located.ir_name };

    var has_runtime_argument = false;
    for (call.args) |arg| {
        if (Values.containsRuntimeValue(self, arg, env) and !Values.isParam(arg, env)) has_runtime_argument = true;
    }

    if (!has_runtime_argument) {
        var compound: std.ArrayList(u8) = .empty;
        for (function.params, call.args, 0..) |param, arg, index| {
            try compound.appendSlice(self.gpa, if (index == 0) "{" else ",");
            try compound.print(self.gpa, "{s}:{s}", .{ param.name, try argumentSnbt(self, arg, env) orelse return null });
        }
        try compound.append(self.gpa, '}');
        return .{ .function_with = .{ .name = located.ir_name, .arguments = .{ .compound = try compound.toOwnedSlice(self.gpa) } } };
    }

    // Math is computed before any argument is written, so a call inside an argument cannot overwrite them.
    const scores = try self.gpa.alloc(?Ir.Score, call.args.len);
    for (call.args, scores) |arg, *score| {
        score.* = null;
        if (!Values.containsRuntimeValue(self, arg, env) or Values.isParam(arg, env)) continue;
        const value, _ = Data.splitCast(arg);
        if (value.kind == .call and Data.isStringCall(value.kind.call)) continue;

        if (value.kind == .identifier) {
            if (value.kind.identifier.storage == .score) score.* = try Scores.scoreSource(self, value.kind.identifier, env) orelse return null;
            continue;
        }

        score.* = try Scores.newTemp(self);
        try Scores.compileInto(self, score.*.?, value, env, commands);
    }

    for (function.params, call.args, scores) |param, arg, argument_score| {
        const outer_position = self.enterExpression(arg);
        defer self.restorePosition(outer_position);
        const target: Ir.DataPath = .inStorage(.args, param.name);
        if (argument_score) |score| {
            _, const cast_type = Data.splitCast(arg);
            try commands.append(self.gpa, .{ .score_to_data = .{ .target = target, .score = score, .type = cast_type orelse .int } });
        } else if (arg.kind == .call and Data.isStringCall(arg.kind.call) and Values.containsRuntimeValue(self, arg, env)) {
            try Data.compileStringInto(self, target, arg.kind.call, env, commands);
        } else if (Data.isDataIdentifier(arg)) {
            const source = try Data.dataPathOf(self, arg.kind.identifier, env) orelse return null;
            try commands.append(self.gpa, .{ .data_copy = .{ .target = target, .source = source } });
        } else {
            const snbt = try argumentSnbt(self, arg, env) orelse return null;
            try commands.append(self.gpa, .{ .data_set = .{ .target = target, .snbt = snbt } });
        }
    }
    return .{ .function_with = .{ .name = located.ir_name, .arguments = .args_storage } };
}

// A compile-time argument as SNBT. A forwarded parameter is `"$(name)"`.
pub fn argumentSnbt(self: *Compiler, arg: *const Ast.Expr, env: *Environment) Compiler.CompileError!?[]const u8 {
    const outer_position = self.enterExpression(arg);
    defer self.restorePosition(outer_position);
    if (Values.isParam(arg, env)) return try std.fmt.allocPrint(self.gpa, "\"$({s})\"", .{arg.kind.identifier.name});

    const expression, const cast_type = Data.splitCast(arg);
    const value = try Values.evaluate(self, expression, env) orelse return null;
    if (value == .null) {
        try self.addError("null cannot be passed to an mcfun", .{});
        return null;
    }
    return try Data.castSnbt(self, value, cast_type);
}

// Calls a generated function. In an mcfun with parameters, the arguments are passed on, because the body can use them.
pub fn generatedCall(self: *Compiler, name: []const u8) Ir.Command {
    const forwarded = self.forwarded_args orelse return .{ .function = name };
    return .{ .function_with = .{ .name = name, .arguments = .{ .compound = forwarded } } };
}

// A recursive call runs this mcfun again, which overwrites its temps and locals. The live temps and the visible
// locals are saved in a frame around the call. `target` gets the result of the call, so it is not restored.
pub fn appendWithSavedValues(self: *Compiler, call: Ir.Command, target: ?Ir.Score, live_temp_count: usize, commands: *std.ArrayList(Ir.Command)) Compiler.CompileError!void {
    var saved_scores: std.ArrayList(Ir.Score) = .empty;
    var saved_data: std.ArrayList([]const u8) = .empty;
    for (0..live_temp_count) |index| try saved_scores.append(self.gpa, try Scores.tempScore(self, index));
    for (self.live_locals.items) |local| switch (local.kind) {
        .score => try saved_scores.append(self.gpa, .{ .holder = local.generated_name, .owner = local.owner }),
        .data => try saved_data.append(self.gpa, local.generated_name),
    };
    if (target) |result| for (saved_scores.items, 0..) |score, index| {
        if (score.eql(result)) {
            _ = saved_scores.orderedRemove(index);
            break;
        }
    };
    if (saved_scores.items.len + saved_data.items.len == 0) return commands.append(self.gpa, call);

    self.uses_stack = true;
    try commands.append(self.gpa, .frame_push);
    for (saved_scores.items) |score| try commands.append(self.gpa, .{ .score_to_data = .{ .target = try frameSlot(self, score.holder), .score = score } });
    for (saved_data.items) |key| try commands.append(self.gpa, .{ .data_copy = .{ .target = try frameSlot(self, key), .source = .inStorage(.data, key) } });
    try commands.append(self.gpa, call);
    for (saved_scores.items) |score| try commands.append(self.gpa, .{ .data_to_score = .{ .source = try frameSlot(self, score.holder), .score = score } });
    for (saved_data.items) |key| try commands.append(self.gpa, .{ .data_copy = .{ .target = .inStorage(.data, key), .source = try frameSlot(self, key) } });
    try commands.append(self.gpa, .frame_pop);
}

// The key in the frame: `t0` for the temp `#poplar.<mcfun>.t0`, `s_i_countdown` for the local `#i_countdown`,
// and `d_names_countdown` for the data local `names_countdown`.
pub fn frameSlot(self: *Compiler, name: []const u8) Compiler.CompileError!Ir.DataPath {
    if (std.mem.startsWith(u8, name, "#poplar.")) return .inStorage(.frame, name[std.mem.lastIndexOfScalar(u8, name, '.').? + 1 ..]);
    if (name[0] == '#') return .inStorage(.frame, try std.fmt.allocPrint(self.gpa, "s_{s}", .{name[1..]}));
    return .inStorage(.frame, try std.fmt.allocPrint(self.gpa, "d_{s}", .{name}));
}

pub fn buildCallGraph(self: *Compiler) Compiler.CompileError!void {
    for (self.functions.keys(), self.functions.values()) |function_key, located| {
        self.scope = self.scopeOf(located.namespace, located.imports);
        var calls: std.StringArrayHashMapUnmanaged(void) = .empty;
        try collectCalls(self, located.function.body, &calls);
        try self.mcfun_calls.put(self.gpa, function_key, calls);
    }
}

// The key of a called name, without errors: the compile step reports a missing import or name.
pub fn calledKey(self: *Compiler, identifier: Ast.Identifier) Compiler.CompileError!?[]const u8 {
    const namespace = identifier.namespace orelse self.scope.namespace;
    const function_key = try Declarations.qualifiedKey(self, namespace, identifier.name);
    return if (self.functions.contains(function_key)) function_key else null;
}

// Finds the mcfun calls in a body. This can find calls that a compile-time branch removes later. That only adds saves.
pub fn collectCalls(
    self: *Compiler,
    body: []const Ast.Stmt,
    calls: *std.StringArrayHashMapUnmanaged(void),
) Compiler.CompileError!void {
    for (body) |statement| switch (statement.kind) {
        .var_decl => |var_decl| try collectExpressionCalls(self, var_decl.value, calls),
        .assign => |assign| try collectExpressionCalls(self, assign.value, calls),
        .@"return" => |value| if (value) |expression| try collectExpressionCalls(self, expression, calls),
        .@"break", .@"continue" => {},
        .@"if" => |if_statement| {
            try collectExpressionCalls(self, if_statement.condition, calls);
            try collectCalls(self, if_statement.then_body, calls);
            if (if_statement.else_body) |else_body| try collectCalls(self, else_body, calls);
        },
        .@"for" => |loop| try collectCalls(self, loop.body, calls),
        .@"while" => |loop| {
            try collectExpressionCalls(self, loop.condition, calls);
            try collectCalls(self, loop.body, calls);
        },
        .execute => |execute| {
            try collectInsertCalls(self, execute.subcommands, calls);
            try collectCalls(self, execute.body, calls);
        },
        .expression => |expression| try collectExpressionCalls(self, expression, calls),
        .command => |command| try collectInsertCalls(self, command.parts, calls),
    };
}

// `/say {{double(2)}};` calls `double` too, and `/function std:clamp {...};` is a use of `std:clamp`.
pub fn collectInsertCalls(
    self: *Compiler,
    parts: []const Ast.CommandPart,
    calls: *std.StringArrayHashMapUnmanaged(void),
) Compiler.CompileError!void {
    for (parts) |part| switch (part.content) {
        .text => |text| try collectStdIds(self, text, calls),
        .insert => |expression| try collectExpressionCalls(self, expression, calls),
    };
}

// A std mcfun is only written when something uses it, so a `std:name` in Minecraft text counts as a use.
pub fn collectStdIds(self: *Compiler, text: []const u8, calls: *std.StringArrayHashMapUnmanaged(void)) Compiler.CompileError!void {
    const prefix = Compiler.std_namespace ++ ":";
    var index: usize = 0;
    while (std.mem.indexOfPos(u8, text, index, prefix)) |start| {
        index = start + prefix.len;
        if (start > 0 and MinecraftText.isNamespaceChar(text[start - 1])) continue;
        var end = index;
        while (end < text.len and (std.ascii.isAlphanumeric(text[end]) or text[end] == '_')) end += 1;
        const function_key = try Declarations.qualifiedKey(self, Compiler.std_namespace, text[index..end]);
        if (self.functions.contains(function_key)) try calls.put(self.gpa, function_key, {});
    }
}

pub fn collectExpressionCalls(
    self: *Compiler,
    expression: *const Ast.Expr,
    calls: *std.StringArrayHashMapUnmanaged(void),
) Compiler.CompileError!void {
    switch (expression.kind) {
        .prefix => |prefix| try collectExpressionCalls(self, prefix.operand, calls),
        .infix => |infix| {
            try collectExpressionCalls(self, infix.left, calls);
            try collectExpressionCalls(self, infix.right, calls);
        },
        .cast => |cast| try collectExpressionCalls(self, cast.value, calls),
        .minecraft_check => |parts| try collectInsertCalls(self, parts, calls),
        .call => |call| {
            for (call.args) |arg| try collectExpressionCalls(self, arg, calls);
            if (call.callee.kind != .identifier) return;

            // An event callback is called from `load`, as far as the call graph is concerned.
            if ((isBuiltinCall(call, "onEvent") or isBuiltinCall(call, "onTrigger")) and call.args.len == 2 and call.args[1].kind == .identifier) {
                if (try calledKey(self, call.args[1].kind.identifier)) |callback| try calls.put(self.gpa, callback, {});
            }
            const called = try calledKey(self, call.callee.kind.identifier) orelse return;
            try calls.put(self.gpa, called, {});
        },
        else => {},
    }
}

// True if `from` can call `to`, directly or through other mcfuns.
pub fn canReach(self: *Compiler, from: []const u8, to: []const u8) Compiler.CompileError!bool {
    var pending: std.ArrayList([]const u8) = .empty;
    var visited: std.StringHashMapUnmanaged(void) = .empty;
    try pending.append(self.gpa, from);

    while (pending.pop()) |name| {
        if (std.mem.eql(u8, name, to)) return true;
        if ((try visited.getOrPut(self.gpa, name)).found_existing) continue;

        const calls = self.mcfun_calls.get(name) orelse continue;
        try pending.appendSlice(self.gpa, calls.keys());
    }
    return false;
}

pub fn compileCall(self: *Compiler, call: Ast.Call, env: *Environment, commands: *std.ArrayList(Ir.Command)) Compiler.CompileError!void {
    if (call.callee.kind != .identifier) return self.addError("only named functions can be called", .{});
    const name = call.callee.kind.identifier.name;

    if (isBuiltinCall(call, "onEvent")) return Load.compileEvent(self, call, "onEvent", env);
    if (isBuiltinCall(call, "onTrigger")) return Load.compileEvent(self, call, "onTrigger", env);
    if (Data.isStringCall(call) or Data.isStringTest(call)) return self.addError("'{s}' gives a value. Use it: '$x = {s}(...);' or 'if ({s}(...))'", .{ name, name, name });
    if (call.callee.kind.identifier.namespace == null and isBuiltin(name)) return Data.compileListBuiltin(self, name, call, env, commands);
    const callee = try Declarations.findFunction(self, call.callee.kind.identifier) orelse return;

    self.temp_count = 0;
    const command = try compileMcfnCall(self, call, callee.located, env, commands) orelse return;
    if (self.live_locals.items.len > 0 and try canReach(self, callee.key, self.mcfun.key)) return appendWithSavedValues(self, command, null, 0, commands);
    try commands.append(self.gpa, command);
}

pub const builtin_names = [_][]const u8{ "append", "prepend", "insert", "remove", "len", "text", "onEvent", "onTrigger", "slice", "str", "startsWith", "endsWith" };

pub fn isBuiltin(name: []const u8) bool {
    for (builtin_names) |builtin| {
        if (std.mem.eql(u8, builtin, name)) return true;
    }
    return false;
}

pub fn isBuiltinCall(call: Ast.Call, name: []const u8) bool {
    return call.callee.kind == .identifier and std.mem.eql(u8, call.callee.kind.identifier.name, name);
}

test "return values, mcfun calls as values and while" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    var compiler = try Compiler.compileForTest(arena.allocator(),
        \\var #x = 0;
        \\mcfun sign() {
        \\    if (#x > 0) { return 1; } else if (#x < 0) { return -1; }
        \\    return 0;
        \\}
        \\mcfun main() {
        \\    #x = sign() + 1;
        \\    while (#x < 5) { #x = #x + 1; }
        \\}
    );
    const program = try compiler.compile();
    try std.testing.expectEqual(0, compiler.errors.items.len);

    try std.testing.expectEqualStrings(
        \\execute if score #global ns.x matches 1.. run return 1
        \\execute if score #global ns.x matches ..-1 run return -1
        \\return 0
        \\
    , try Compiler.renderForTest(arena.allocator(), program, "sign"));
    try std.testing.expectEqualStrings(
        \\execute store result score #global ns.x run function ns:sign
        \\scoreboard players add #global ns.x 1
        \\execute if score #global ns.x matches ..4 run function ns:poplar/main/while_0_body
        \\
    , try Compiler.renderForTest(arena.allocator(), program, "main"));
    try std.testing.expectError(error.TestUnexpectedResult, Compiler.renderForTest(arena.allocator(), program, "poplar/main/while_0"));
    try std.testing.expectEqualStrings(
        \\scoreboard players add #global ns.x 1
        \\execute if score #global ns.x matches ..4 run function ns:poplar/main/while_0_body
        \\
    , try Compiler.renderForTest(arena.allocator(), program, "poplar/main/while_0_body"));
}

test "mcfun parameters become macro arguments" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    var compiler = try Compiler.compileForTest(arena.allocator(),
        \\var #hp = 0;
        \\mcfun heal(amount) {
        \\    #hp = #hp + amount;
        \\    if (#hp > 10) { /say {{amount}}; #hp = 10; }
        \\}
        \\mcfun main() {
        \\    heal(5);
        \\    heal(#hp * 2);
        \\}
    );
    const program = try compiler.compile();
    try std.testing.expectEqual(0, compiler.errors.items.len);

    try std.testing.expectEqualStrings(
        \\$scoreboard players set #poplar.heal.t0 ns $(amount)
        \\scoreboard players operation #global ns.hp += #poplar.heal.t0 ns
        \\$execute if score #global ns.hp matches 11.. run function ns:poplar/heal/if_0 {amount:"$(amount)"}
        \\
    , try Compiler.renderForTest(arena.allocator(), program, "heal"));
    try std.testing.expectEqualStrings(
        \\$say $(amount)
        \\scoreboard players set #global ns.hp 10
        \\
    , try Compiler.renderForTest(arena.allocator(), program, "poplar/heal/if_0"));
    try std.testing.expectEqualStrings(
        \\function ns:heal {amount:5}
        \\scoreboard players operation #poplar.main.t0 ns = #global ns.hp
        \\execute store result storage ns:poplar args.amount int 1 run scoreboard players operation #poplar.main.t0 ns *= #poplar.c2 ns
        \\function ns:heal with storage ns:poplar args
        \\
    , try Compiler.renderForTest(arena.allocator(), program, "main"));
}

test "mcfun parameter errors" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    var compiler = try Compiler.compileForTest(arena.allocator(),
        \\mcfun heal(amount) {
        \\    var copy = amount;
        \\}
        \\mcfun main() { heal(); }
    );
    _ = try compiler.compile();

    const errors = compiler.errors.items;
    try std.testing.expectEqual(2, errors.len);
    try std.testing.expectEqualStrings("'copy' is a build-time constant, but this value only exists in the game. Use 'var #copy' for a score or 'var $copy' for data", errors[0].message);
    try std.testing.expectEqualStrings("mcfun 'heal' expects 1 arguments, found 0", errors[1].message);
}

test "recursive calls save live temps in a frame" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    var compiler = try Compiler.compileForTest(arena.allocator(),
        \\var #x = 0;
        \\mcfun fact(n) {
        \\    if (n <= 1) { return 1; }
        \\    return n * fact(n - 1);
        \\}
        \\mcfun double(v) { return v * 2; }
        \\mcfun main() { #x = 2 * double(3); }
    );
    const program = try compiler.compile();
    try std.testing.expectEqual(0, compiler.errors.items.len);

    try std.testing.expectEqualStrings(
        \\$scoreboard players set #poplar.fact.t0 ns $(n)
        \\execute if score #poplar.fact.t0 ns matches ..1 run return 1
        \\scoreboard players operation #poplar.fact.t2 ns = #poplar.fact.t0 ns
        \\execute store result storage ns:poplar args.n int 1 run scoreboard players remove #poplar.fact.t2 ns 1
        \\data modify storage ns:poplar stack append value {}
        \\execute store result storage ns:poplar stack[-1].t0 int 1 run scoreboard players get #poplar.fact.t0 ns
        \\execute store result score #poplar.fact.t1 ns run function ns:fact with storage ns:poplar args
        \\execute store result score #poplar.fact.t0 ns run data get storage ns:poplar stack[-1].t0
        \\data remove storage ns:poplar stack[-1]
        \\return run scoreboard players operation #poplar.fact.t0 ns *= #poplar.fact.t1 ns
        \\
    , try Compiler.renderForTest(arena.allocator(), program, "fact"));
    try std.testing.expectEqualStrings(
        \\scoreboard players set #global ns.x 2
        \\execute store result score #poplar.main.t0 ns run function ns:double {v:3}
        \\scoreboard players operation #global ns.x *= #poplar.main.t0 ns
        \\
    , try Compiler.renderForTest(arena.allocator(), program, "main"));
    try std.testing.expectEqual(Ir.Command.stack_clear, program.load.?.commands[0]);
}
