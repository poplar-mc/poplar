// mcfun calls: arguments, the call graph, and saving values around a recursive call.
const std = @import("std");
const Compiler = @import("../Compiler.zig");
const Ast = @import("../Ast.zig");
const Commands = @import("../Commands.zig");
const Environment = @import("../Environment.zig");
const Ir = @import("../Ir.zig");
const Lexer = @import("../Lexer.zig");
const Parser = @import("../Parser.zig");
const Data = @import("Data.zig");
const Declarations = @import("Declarations.zig");
const Load = @import("Load.zig");
const MinecraftText = @import("MinecraftText.zig");
const Scores = @import("Scores.zig");
const Values = @import("Values.zig");

// Returns the command that calls an mcfun. Commands that write a runtime `with` compound go into `commands` first.
pub fn compileMcfnCall(self: *Compiler, call: Ast.Call, located: Compiler.Located, env: *Environment, commands: *std.ArrayList(Ir.Command)) Compiler.CompileError!?Ir.Command {
    const function = located.function;
    var keys: std.StringArrayHashMapUnmanaged(void) = .empty;
    try Compiler.collectMacroKeys(self.gpa, function.body, &keys);
    if (call.args.len > 0) {
        try self.addError("mcfun '{s}' takes no arguments. Pass them as a compound: '{s}() with {s}'", .{ function.name, function.name, try exampleCompound(self, keys.keys()) });
        return null;
    }
    const with = call.with orelse {
        if (keys.count() > 0) try self.addError("mcfun '{s}' uses '$({s})', so it needs a compound: '{s}() with {s}'", .{ function.name, keys.keys()[0], function.name, try exampleCompound(self, keys.keys()) });
        return .{ .function = located.ir_name };
    };
    const value = switch (with) {
        .raw => |text| return .{ .function_with = .{ .name = located.ir_name, .arguments = .{ .raw = text } } },
        .value => |value| value,
    };

    if (Data.isDataIdentifier(value)) {
        const path = try Data.dataPathOf(self, value.kind.identifier, env) orelse return null;
        if (try nonCompoundGlobal(self, value.kind.identifier, env)) |initial| {
            const outer_position = self.enterExpression(value);
            defer self.restorePosition(outer_position);
            try self.addError("'with' needs a compound, but '${s}' is {s}. Declare it as a compound: 'var ${s} = {{name: {s}}};'", .{ value.kind.identifier.name, initial, value.kind.identifier.name, initial });
            return null;
        }
        return .{ .function_with = .{ .name = located.ir_name, .arguments = .{ .data_path = path } } };
    }
    const entries = switch (value.kind) {
        .compound => |entries| entries,
        else => {
            const outer_position = self.enterExpression(value);
            defer self.restorePosition(outer_position);
            try self.addError("'with' needs a compound ('{{name: ...}}'), a '$' variable, 'entity <selector>' or 'block <position>'", .{});
            return null;
        },
    };

    for (keys.keys()) |key| {
        for (entries) |entry| {
            if (std.mem.eql(u8, entry.key, key)) break;
        } else {
            const outer_position = self.enterExpression(value);
            defer self.restorePosition(outer_position);
            try self.addError("mcfun '{s}' uses '$({s})', but this compound has no key '{s}'", .{ function.name, key, key });
            return null;
        }
    }

    var is_inline = true;
    for (entries) |entry| {
        if (Values.containsRuntimeValue(self, entry.value, env) and entry.value.kind != .macro_key) is_inline = false;
    }
    if (is_inline) {
        var compound: std.ArrayList(u8) = .empty;
        try compound.append(self.gpa, '{');
        for (entries, 0..) |entry, index| {
            if (index > 0) try compound.append(self.gpa, ',');
            try compound.print(self.gpa, "{s}:{s}", .{ try Values.snbtKey(self, entry.key), try argumentSnbt(self, entry.value, env) orelse return null });
        }
        try compound.append(self.gpa, '}');
        return .{ .function_with = .{ .name = located.ir_name, .arguments = .{ .compound = try compound.toOwnedSlice(self.gpa) } } };
    }

    // Math is computed before any key is written, so a call inside a value cannot overwrite them.
    const scores = try self.gpa.alloc(?Ir.Score, entries.len);
    for (entries, scores) |entry, *score| {
        score.* = null;
        const entry_value = entry.value;
        if (!Values.containsRuntimeValue(self, entry_value, env) or entry_value.kind == .macro_key) continue;
        if (entry_value.kind == .call and Data.isStringCall(entry_value.kind.call)) continue;
        if (entry_value.kind == .list or entry_value.kind == .compound) continue;

        if (entry_value.kind == .identifier) {
            if (entry_value.kind.identifier.storage == .score) score.* = try Scores.scoreSource(self, entry_value.kind.identifier, env) orelse return null;
            continue;
        }

        score.* = try Scores.newTemp(self);
        try Scores.compileInto(self, score.*.?, entry_value, env, commands);
    }

    for (entries, scores) |entry, entry_score| {
        const outer_position = self.enterExpression(entry.value);
        defer self.restorePosition(outer_position);
        const target: Ir.DataPath = .inStorage(.args, try Values.snbtKey(self, entry.key));
        const entry_value = entry.value;
        if (entry_score) |score| {
            try commands.append(self.gpa, .{ .score_to_data = .{ .target = target, .score = score } });
        } else if (entry_value.kind == .call and Data.isStringCall(entry_value.kind.call) and Values.containsRuntimeValue(self, entry_value, env)) {
            try Data.compileStringInto(self, target, entry_value.kind.call, env, commands);
        } else if (Data.isDataIdentifier(entry_value)) {
            const source = try Data.dataPathOf(self, entry_value.kind.identifier, env) orelse return null;
            try commands.append(self.gpa, .{ .data_copy = .{ .target = target, .source = source } });
        } else if ((entry_value.kind == .list or entry_value.kind == .compound) and Values.containsRuntimeValue(self, entry_value, env)) {
            try Data.compileLiteralAssign(self, target, entry_value, env, commands);
        } else {
            const snbt = try argumentSnbt(self, entry.value, env) orelse return null;
            try commands.append(self.gpa, .{ .data_set = .{ .target = target, .snbt = snbt } });
        }
    }
    return .{ .function_with = .{ .name = located.ir_name, .arguments = .args_storage } };
}

// The initial value of a whole `$` global that is not a compound and that no code changes. A global that code sets
// can hold a compound by the time of the call, so it is not reported. Null otherwise.
fn nonCompoundGlobal(self: *Compiler, identifier: Ast.Identifier, env: *const Environment) Compiler.CompileError!?[]const u8 {
    if (identifier.storage != .data or !std.mem.eql(u8, Compiler.pathRoot(identifier.name), identifier.name)) return null;
    if (identifier.namespace == null and Compiler.localOf(env, '$', identifier.name) != null) return null;
    const namespace = try Declarations.resolveNamespace(self, identifier.namespace) orelse return null;
    const global = self.data_globals.get(try Declarations.qualifiedKey(self, namespace, identifier.name)) orelse return null;
    if (global.initial_snbt[0] == '{') return null;
    for (self.functions.values()) |located| {
        if (setsData(located.function.body, identifier.name)) return null;
    }
    return global.initial_snbt;
}

// True if a statement assigns `$name`, or a raw command names it. A raw command is not read, so any mention counts.
fn setsData(body: []const Ast.Stmt, name: []const u8) bool {
    for (body) |statement| switch (statement.kind) {
        .assign => |assign| if (assign.target.storage == .data and std.mem.eql(u8, Compiler.pathRoot(assign.target.name), name)) return true,
        .@"if" => |if_statement| {
            if (setsData(if_statement.then_body, name)) return true;
            if (if_statement.else_body) |else_body| if (setsData(else_body, name)) return true;
        },
        .@"while" => |loop| if (setsData(loop.body, name)) return true,
        .@"for" => |loop| if (setsData(loop.body, name)) return true,
        .execute => |execute| if (setsData(execute.body, name)) return true,
        .command => |command| if (std.mem.indexOf(u8, command.text, name) != null) return true,
        else => {},
    };
    return false;
}

// `{a: ..., b: ...}` for the keys an mcfun uses, for error messages.
fn exampleCompound(self: *Compiler, keys: []const []const u8) Compiler.CompileError![]const u8 {
    if (keys.len == 0) return "{name: ...}";
    var text: std.ArrayList(u8) = .empty;
    try text.append(self.gpa, '{');
    for (keys, 0..) |key, index| try text.print(self.gpa, "{s}{s}: ...", .{ if (index == 0) "" else ", ", key });
    try text.append(self.gpa, '}');
    return text.toOwnedSlice(self.gpa);
}

// A compile-time value as SNBT. A macro key is `"$(name)"`, so the line becomes a macro line.
pub fn argumentSnbt(self: *Compiler, arg: *const Ast.Expr, env: *Environment) Compiler.CompileError!?[]const u8 {
    const outer_position = self.enterExpression(arg);
    defer self.restorePosition(outer_position);
    if (arg.kind == .macro_key) return try std.fmt.allocPrint(self.gpa, "\"$({s})\"", .{arg.kind.macro_key});

    const value = try Values.evaluate(self, arg, env) orelse return null;
    if (value == .null) {
        try self.addError("null cannot be passed to an mcfun", .{});
        return null;
    }
    return try Values.valueToSnbt(self, value);
}

// Calls a generated function. In an mcfun that uses macro arguments, they are passed on, because the body can use them.
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
        .score => try saved_scores.append(self.gpa, .{ .holder = local.generated_name, .owner = local.owner, .namespace = self.scope.output_namespace }),
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
    for (saved_data.items) |key| try commands.append(self.gpa, .{ .data_copy = .{ .target = try frameSlot(self, key), .source = Data.dataLocal(self, key) } });
    try commands.append(self.gpa, call);
    for (saved_scores.items) |score| try commands.append(self.gpa, .{ .data_to_score = .{ .source = try frameSlot(self, score.holder), .score = score } });
    for (saved_data.items) |key| try commands.append(self.gpa, .{ .data_copy = .{ .target = Data.dataLocal(self, key), .source = try frameSlot(self, key) } });
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
        .minecraft_check => |parts| try collectInsertCalls(self, parts, calls),
        .list => |elements| for (elements) |element| try collectExpressionCalls(self, element, calls),
        .compound => |entries| for (entries) |entry| try collectExpressionCalls(self, entry.value, calls),
        .call => |call| {
            for (call.args) |arg| try collectExpressionCalls(self, arg, calls);
            if (call.with) |with| if (with == .value) try collectExpressionCalls(self, with.value, calls);
            if (call.callee.kind != .identifier) return;

            // An event callback is called from `load`, as far as the call graph is concerned.
            const is_event = call.callee.kind.identifier.namespace == null and Load.event_builtins.has(call.callee.kind.identifier.name);
            if (is_event and call.args.len > 0 and call.args[call.args.len - 1].kind == .identifier) {
                if (try calledKey(self, call.args[call.args.len - 1].kind.identifier)) |callback| try calls.put(self.gpa, callback, {});
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

    if (call.callee.kind.identifier.namespace == null and Load.event_builtins.has(name)) return Load.compileEvent(self, call, name, env);
    if (Data.isStringCall(call) or Data.isStringTest(call)) return self.addError("'{s}' gives a value. Use it: '$x = {s}(...);' or 'if ({s}(...))'", .{ name, name, name });
    if (call.callee.kind.identifier.namespace == null and isBuiltin(name)) return Data.compileListBuiltin(self, name, call, env, commands);
    const callee = try Declarations.findFunction(self, call.callee.kind.identifier) orelse return;

    self.temp_count = 0;
    const command = try compileMcfnCall(self, call, callee.located, env, commands) orelse return;
    if (self.live_locals.items.len > 0 and try canReach(self, callee.key, self.mcfun.key)) return appendWithSavedValues(self, command, null, 0, commands);
    try commands.append(self.gpa, command);
}

pub const builtin_names = [_][]const u8{ "append", "prepend", "insert", "remove", "len", "text", "onEvent", "onTrigger", "onDeath", "onFirstJoin", "onJoin", "onRespawn", "slice", "str", "startsWith", "endsWith" };

pub fn isBuiltin(name: []const u8) bool {
    for (builtin_names) |builtin| {
        if (std.mem.eql(u8, builtin, name)) return true;
    }
    return false;
}

pub fn isBuiltinCall(call: Ast.Call, name: []const u8) bool {
    if (call.callee.kind != .identifier or call.callee.kind.identifier.namespace != null) return false;
    return std.mem.eql(u8, call.callee.kind.identifier.name, name);
}

test "a recursive call saves the locals of an mcfun in another namespace where they are" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const command_tree = try arena.allocator().create(Commands);
    command_tree.* = try .load(arena.allocator());
    var compiler = Compiler.init(arena.allocator(), command_tree);

    var parser = try Parser.init(arena.allocator(), Lexer.init(
        \\namespace magic;
        \\mcfun down() {
        \\    var #i = 1;
        \\    var $name = "a";
        \\    if (#i > 0) { down(); }
        \\    /say {{#i}} {{$name}};
        \\}
    ));
    try compiler.addProgram("magic.poplar", try parser.parseProgram(), .project);
    const program = try compiler.compile();
    try std.testing.expectEqual(0, compiler.errors.items.len);

    try std.testing.expectEqualStrings(
        \\data modify storage ns:poplar stack append value {}
        \\execute store result storage ns:poplar stack[-1].s_i_down int 1 run scoreboard players get #i_down poplar.magic
        \\data modify storage ns:poplar stack[-1].d_name_down set from storage magic:data name_down
        \\function magic:down
        \\execute store result score #i_down poplar.magic run data get storage ns:poplar stack[-1].s_i_down
        \\data modify storage magic:data name_down set from storage ns:poplar stack[-1].d_name_down
        \\data remove storage ns:poplar stack[-1]
        \\
    , try Compiler.renderForTest(arena.allocator(), program, "magic:poplar/down/if_0"));
}

test "a name with a namespace is never a builtin, and an mcfun is not known at build time" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    var compiler = try Compiler.compileForTest(arena.allocator(),
        \\var $list = [];
        \\var #n = 0;
        \\mcfun main() { #n = ns:len($list); }
        \\mcfun one() { return 1; }
        \\mcfun range() { for (0..one()) |i| { /say {{i}}; } }
    );
    _ = try compiler.compile();

    const errors = compiler.errors.items;
    try std.testing.expectEqual(2, errors.len);
    try std.testing.expectEqualStrings("unknown function 'len'", errors[0].message);
    try std.testing.expectEqualStrings("mcfun 'one' runs in the game, so its result is not known when the pack is built", errors[1].message);
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

test "with compounds become macro arguments" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    var compiler = try Compiler.compileForTest(arena.allocator(),
        \\var #hp = 0;
        \\mcfun heal() {
        \\    #hp = #hp + $(amount);
        \\    if (#hp > 10) { /say $(amount); #hp = 10; }
        \\}
        \\mcfun main() {
        \\    heal() with {amount: 5};
        \\    heal() with {amount: #hp * 2};
        \\}
    );
    const program = try compiler.compile();
    try std.testing.expectEqual(0, compiler.errors.items.len);

    try std.testing.expectEqualStrings(
        \\$scoreboard players set #poplar.heal.t0 poplar.ns $(amount)
        \\scoreboard players operation #global ns.hp += #poplar.heal.t0 poplar.ns
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
        \\scoreboard players operation #poplar.main.t0 poplar.ns = #global ns.hp
        \\execute store result storage ns:poplar args.amount int 1 run scoreboard players operation #poplar.main.t0 poplar.ns *= #poplar.c2 poplar.ns
        \\function ns:heal with storage ns:poplar args
        \\
    , try Compiler.renderForTest(arena.allocator(), program, "main"));
}

test "with: a compound must have the keys the body uses, and a declared non-compound is an error" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    var compiler = try Compiler.compileForTest(arena.allocator(),
        \\var $num = 0.05f;
        \\var $list = [1];
        \\var $later = 0;
        \\var $raw = 0;
        \\var $comp = {a: 1};
        \\var #hp = 0;
        \\mcfun two() { if ($(a) > 0) { /say $(b); } }
        \\mcfun plain() { /say x; }
        \\mcfun set() { $later = {a: 1, b: 2}; /data modify storage self:data raw set value {a: 1, b: 2}; }
        \\mcfun main() {
        \\    two() with {a: 1};
        \\    two() with {a: #hp};
        \\    two() with {a: 1, b: 2, extra: 3};
        \\    plain() with {a: 1};
        \\    two() with $comp;
        \\    two() with $later;
        \\    two() with $raw;
        \\    two() with $num;
        \\    two() with $list;
        \\}
    );
    _ = try compiler.compile();
    const errors = compiler.errors.items;
    try std.testing.expectEqual(4, errors.len);
    try std.testing.expectEqualStrings("mcfun 'two' uses '$(b)', but this compound has no key 'b'", errors[0].message);
    try std.testing.expectEqualStrings("mcfun 'two' uses '$(b)', but this compound has no key 'b'", errors[1].message);
    try std.testing.expectEqualStrings("'with' needs a compound, but '$num' is 0.05f. Declare it as a compound: 'var $num = {name: 0.05f};'", errors[2].message);
    try std.testing.expectEqualStrings("'with' needs a compound, but '$list' is [1]. Declare it as a compound: 'var $list = {name: [1]};'", errors[3].message);
}

test "mcfun call errors" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    var compiler = try Compiler.compileForTest(arena.allocator(),
        \\mcfun heal() {
        \\    var copy = $(amount);
        \\}
        \\mcfun main() { heal(); heal(5); heal() with 5; }
    );
    _ = try compiler.compile();

    const errors = compiler.errors.items;
    try std.testing.expectEqual(4, errors.len);
    try std.testing.expectEqualStrings("'copy' is a build-time constant, but this value only exists in the game. Use 'var #copy' for a score or 'var $copy' for data", errors[0].message);
    try std.testing.expectEqualStrings("mcfun 'heal' uses '$(amount)', so it needs a compound: 'heal() with {amount: ...}'", errors[1].message);
    try std.testing.expectEqualStrings("mcfun 'heal' takes no arguments. Pass them as a compound: 'heal() with {amount: ...}'", errors[2].message);
    try std.testing.expectEqualStrings("'with' needs a compound ('{name: ...}'), a '$' variable, 'entity <selector>' or 'block <position>'", errors[3].message);
}

test "recursive calls save live temps in a frame" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    var compiler = try Compiler.compileForTest(arena.allocator(),
        \\var #x = 0;
        \\mcfun fact() {
        \\    if ($(n) <= 1) { return 1; }
        \\    return $(n) * fact() with {n: $(n) - 1};
        \\}
        \\mcfun double() { return $(v) * 2; }
        \\mcfun main() { #x = 2 * double() with {v: 3}; }
    );
    const program = try compiler.compile();
    try std.testing.expectEqual(0, compiler.errors.items.len);

    try std.testing.expectEqualStrings(
        \\$scoreboard players set #poplar.fact.t0 poplar.ns $(n)
        \\execute if score #poplar.fact.t0 poplar.ns matches ..1 run return 1
        \\scoreboard players operation #poplar.fact.t2 poplar.ns = #poplar.fact.t0 poplar.ns
        \\execute store result storage ns:poplar args.n int 1 run scoreboard players remove #poplar.fact.t2 poplar.ns 1
        \\data modify storage ns:poplar stack append value {}
        \\execute store result storage ns:poplar stack[-1].t0 int 1 run scoreboard players get #poplar.fact.t0 poplar.ns
        \\execute store result score #poplar.fact.t1 poplar.ns run function ns:fact with storage ns:poplar args
        \\execute store result score #poplar.fact.t0 poplar.ns run data get storage ns:poplar stack[-1].t0
        \\data remove storage ns:poplar stack[-1]
        \\return run scoreboard players operation #poplar.fact.t0 poplar.ns *= #poplar.fact.t1 poplar.ns
        \\
    , try Compiler.renderForTest(arena.allocator(), program, "fact"));
    try std.testing.expectEqualStrings(
        \\scoreboard players set #global ns.x 2
        \\execute store result score #poplar.main.t0 poplar.ns run function ns:double {v:3}
        \\scoreboard players operation #global ns.x *= #poplar.main.t0 poplar.ns
        \\
    , try Compiler.renderForTest(arena.allocator(), program, "main"));
    try std.testing.expectEqual(Ir.Command.stack_clear, program.load.?.commands[0]);
}
