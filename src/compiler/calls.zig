//! mcfun calls: arguments, the call graph, and saving values around a recursive call.

const std = @import("std");
const Compiler = @import("../Compiler.zig");
const ast = @import("../ast.zig");
const CommandTree = @import("../CommandTree.zig");
const Config = @import("../Config.zig");
const Environment = @import("../Environment.zig");
const ir = @import("../ir.zig");
const Lexer = @import("../Lexer.zig");
const Parser = @import("../Parser.zig");
const data = @import("data.zig");
const declarations = @import("declarations.zig");
const load = @import("load.zig");
const minecraft_text = @import("minecraft_text.zig");
const scores = @import("scores.zig");
const values = @import("values.zig");

/// Returns the command that calls an mcfun. CommandTree that write a runtime `with` compound go into `commands` first.
pub fn compileMcfunCall(
    compiler: *Compiler,
    call: ast.Call,
    declaration: Compiler.McfunDeclaration,
    env: *Environment,
    commands: *std.ArrayList(ir.Command),
) Compiler.Error!ir.Command {
    const mcfun = declaration.mcfun;
    var keys: std.StringArrayHashMapUnmanaged(void) = .empty;
    try Compiler.collectMacroKeys(compiler.arena, mcfun.body, &keys);
    if (call.args.len > 0) {
        return compiler.fail(
            "mcfun '{s}' takes no arguments. Pass them as a compound: '{s}() with {s}'",
            .{ mcfun.name, mcfun.name, try exampleCompound(compiler, keys.keys()) },
        );
    }
    const with = call.with orelse {
        if (keys.count() > 0) {
            return compiler.fail(
                "mcfun '{s}' uses '$({s})', so it needs a compound: '{s}() with {s}'",
                .{ mcfun.name, keys.keys()[0], mcfun.name, try exampleCompound(compiler, keys.keys()) },
            );
        }
        return .{ .function = declaration.ir_name };
    };

    const arguments: ir.FunctionWith.Arguments = switch (with) {
        .raw => |text| .{ .raw = text },
        .value => |value| if (data.isDataIdentifier(value))
            try dataArguments(compiler, value, env)
        else
            try compoundArguments(compiler, mcfun.name, keys.keys(), value, env, commands),
    };
    return .{ .function_with = .{ .name = declaration.ir_name, .arguments = arguments } };
}

/// `f() with $player`: the `$` variable is read as it is.
fn dataArguments(compiler: *Compiler, value: *const ast.Expression, env: *Environment) Compiler.Error!ir.FunctionWith.Arguments {
    const identifier = value.kind.identifier;
    const path = try data.dataPathOf(compiler, identifier, env);
    if (try nonCompoundGlobal(compiler, identifier, env)) |initial| {
        return compiler.failOn(
            value,
            "'with' needs a compound, but '${s}' is {s}. Declare it as a compound: 'var ${s} = {{name: {s}}};'",
            .{ identifier.name, initial, identifier.name, initial },
        );
    }
    return .{ .data_path = path };
}

/// `f() with {name: ...}`: written in the call when every value is known, else stored in `<ns>:poplar args` first.
fn compoundArguments(
    compiler: *Compiler,
    mcfun_name: []const u8,
    keys: []const []const u8,
    value: *const ast.Expression,
    env: *Environment,
    commands: *std.ArrayList(ir.Command),
) Compiler.Error!ir.FunctionWith.Arguments {
    if (value.kind != .compound) {
        return compiler.failOn(
            value,
            "'with' needs a compound ('{{name: ...}}'), a '$' variable, 'entity <selector>' or 'block <position>'",
            .{},
        );
    }
    const entries = value.kind.compound;

    for (keys) |key| {
        for (entries) |entry| {
            if (std.mem.eql(u8, entry.key, key)) break;
        } else {
            return compiler.failOn(value, "mcfun '{s}' uses '$({s})', but this compound has no key '{s}'", .{ mcfun_name, key, key });
        }
    }

    const is_inline = for (entries) |entry| {
        if (values.containsRuntimeValue(entry.value) and entry.value.kind != .macro_key) break false;
    } else true;
    if (is_inline) return .{ .compound = try inlineCompound(compiler, entries, env) };

    try storeArguments(compiler, entries, env, commands);
    return .args_storage;
}

fn inlineCompound(compiler: *Compiler, entries: []const ast.Entry, env: *Environment) Compiler.Error![]const u8 {
    var compound: std.ArrayList(u8) = .empty;
    try compound.append(compiler.arena, '{');
    for (entries, 0..) |entry, index| {
        if (index > 0) try compound.append(compiler.arena, ',');
        try compound.print(
            compiler.arena,
            "{s}:{s}",
            .{ try values.snbtKey(compiler, entry.key), try argumentSnbt(compiler, entry.value, env) },
        );
    }
    try compound.append(compiler.arena, '}');
    return compound.items;
}

/// Writes each key of `<ns>:poplar args`. Math is computed before any key is written, so a call inside a value cannot
/// overwrite them.
fn storeArguments(
    compiler: *Compiler,
    entries: []const ast.Entry,
    env: *Environment,
    commands: *std.ArrayList(ir.Command),
) Compiler.Error!void {
    const entry_scores = try compiler.arena.alloc(?ir.Score, entries.len);
    for (entries, entry_scores) |entry, *score| score.* = try scoreOfArgument(compiler, entry.value, env, commands);

    for (entries, entry_scores) |entry, entry_score| {
        const outer_position = compiler.enterExpression(entry.value);
        defer compiler.restorePosition(outer_position);
        const target: ir.DataPath = .inStorage(.args, try values.snbtKey(compiler, entry.key));
        const value = entry.value;
        const is_runtime = values.containsRuntimeValue(value);
        if (entry_score) |score| {
            try commands.append(compiler.arena, .{ .score_to_data = .{ .target = target, .score = score } });
        } else if (value.kind == .call and data.isStringCall(value.kind.call) and is_runtime) {
            try data.compileStringInto(compiler, target, value.kind.call, env, commands);
        } else if (data.isDataIdentifier(value)) {
            const source = try data.dataPathOf(compiler, value.kind.identifier, env);
            try commands.append(compiler.arena, .{ .data_copy = .{ .target = target, .source = source } });
        } else if ((value.kind == .list or value.kind == .compound) and is_runtime) {
            try data.compileLiteralAssign(compiler, target, value, env, commands);
        } else {
            const snbt = try argumentSnbt(compiler, value, env);
            try commands.append(compiler.arena, .{ .data_set = .{ .target = target, .snbt = snbt } });
        }
    }
}

/// The score that holds a value that is a score or math. Null for any other value.
fn scoreOfArgument(
    compiler: *Compiler,
    value: *const ast.Expression,
    env: *Environment,
    commands: *std.ArrayList(ir.Command),
) Compiler.Error!?ir.Score {
    if (!values.containsRuntimeValue(value) or value.kind == .macro_key) return null;
    if (value.kind == .call and data.isStringCall(value.kind.call)) return null;
    if (value.kind == .list or value.kind == .compound) return null;

    if (value.kind == .identifier) {
        if (value.kind.identifier.kind != .score) return null;
        return try scores.scoreSource(compiler, value.kind.identifier, env);
    }

    const temp = try scores.newTemp(compiler);
    try scores.compileInto(compiler, temp, value, env, commands);
    return temp;
}

/// The initial value of a whole `$` global that is not a compound and that no code changes. A global that code sets
/// can hold a compound by the time of the call, so it is not reported. Null otherwise.
fn nonCompoundGlobal(compiler: *Compiler, identifier: ast.Identifier, env: *const Environment) Compiler.Error!?[]const u8 {
    if (identifier.kind != .data or !std.mem.eql(u8, Compiler.pathRoot(identifier.name), identifier.name)) return null;
    if (identifier.namespace == null and env.getLocal(.data, identifier.name) != null) return null;
    const namespace = try declarations.resolveNamespace(compiler, identifier.namespace);
    const global = compiler.data_globals.get(try declarations.qualifiedKey(compiler, namespace, identifier.name)) orelse return null;
    if (global.initial_snbt[0] == '{') return null;
    for (compiler.mcfuns.values()) |declaration| {
        if (setsData(declaration.mcfun.body, identifier.name)) return null;
    }
    return global.initial_snbt;
}

/// True if a statement assigns `$name`, or a raw command names it. A raw command is not read, so any mention counts.
fn setsData(body: []const ast.Statement, name: []const u8) bool {
    for (body) |statement| switch (statement.kind) {
        .assign => |assign| if (assign.target.kind == .data and std.mem.eql(u8, Compiler.pathRoot(assign.target.name), name)) return true,
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

/// `{a: ..., b: ...}` for the keys an mcfun uses, for error messages.
fn exampleCompound(compiler: *Compiler, keys: []const []const u8) std.mem.Allocator.Error![]const u8 {
    if (keys.len == 0) return "{name: ...}";
    var text: std.ArrayList(u8) = .empty;
    try text.append(compiler.arena, '{');
    for (keys, 0..) |key, index| try text.print(compiler.arena, "{s}{s}: ...", .{ if (index == 0) "" else ", ", key });
    try text.append(compiler.arena, '}');
    return text.toOwnedSlice(compiler.arena);
}

/// A compile-time value as SNBT. A macro key is `"$(name)"`, so the line becomes a macro line.
fn argumentSnbt(compiler: *Compiler, arg: *const ast.Expression, env: *Environment) Compiler.Error![]const u8 {
    const outer_position = compiler.enterExpression(arg);
    defer compiler.restorePosition(outer_position);
    if (arg.kind == .macro_key) return try std.fmt.allocPrint(compiler.arena, "\"$({s})\"", .{arg.kind.macro_key});

    const value = try values.evaluate(compiler, arg, env);
    if (value == .null) {
        return compiler.fail("null cannot be passed to an mcfun", .{});
    }
    return try values.valueToSnbt(compiler, value);
}

/// Calls a generated function. In an mcfun that uses macro arguments, they are passed on, because the body can use them.
pub fn generatedCall(compiler: *Compiler, name: []const u8) ir.Command {
    const forwarded = compiler.mcfun.forwarded_args orelse return .{ .function = name };
    return .{ .function_with = .{ .name = name, .arguments = .{ .compound = forwarded } } };
}

/// A recursive call runs this mcfun again, which overwrites its temps and locals. The live temps and the visible
/// locals are saved in a frame around the call. `target` gets the result of the call, so it is not restored.
pub fn appendWithSavedValues(
    compiler: *Compiler,
    call: ir.Command,
    target: ?ir.Score,
    live_temp_count: usize,
    commands: *std.ArrayList(ir.Command),
) std.mem.Allocator.Error!void {
    var saved_scores: std.ArrayList(ir.Score) = .empty;
    var saved_data: std.ArrayList([]const u8) = .empty;
    for (0..live_temp_count) |index| try saved_scores.append(compiler.arena, try scores.tempScore(compiler, index));
    for (compiler.mcfun.live_locals.items) |local| switch (local.kind) {
        .score => try saved_scores.append(
            compiler.arena,
            ir.Score.local(local.generated_name, local.owner, compiler.scope.output_namespace),
        ),
        .data => try saved_data.append(compiler.arena, local.generated_name),
    };
    if (target) |result| for (saved_scores.items, 0..) |score, index| {
        if (score.eql(result)) {
            _ = saved_scores.orderedRemove(index);
            break;
        }
    };
    if (saved_scores.items.len + saved_data.items.len == 0) return commands.append(compiler.arena, call);

    compiler.uses_stack = true;
    try commands.append(compiler.arena, .frame_push);
    for (saved_scores.items) |score| try commands.append(
        compiler.arena,
        .{ .score_to_data = .{ .target = try scoreFrameSlot(compiler, score), .score = score } },
    );
    for (saved_data.items) |key| try commands.append(
        compiler.arena,
        .{ .data_copy = .{ .target = try dataFrameSlot(compiler, key), .source = data.dataLocal(compiler, key) } },
    );
    try commands.append(compiler.arena, call);
    for (saved_scores.items) |score| try commands.append(
        compiler.arena,
        .{ .data_to_score = .{ .source = try scoreFrameSlot(compiler, score), .score = score } },
    );
    for (saved_data.items) |key| try commands.append(
        compiler.arena,
        .{ .data_copy = .{ .target = data.dataLocal(compiler, key), .source = try dataFrameSlot(compiler, key) } },
    );
    try commands.append(compiler.arena, .frame_pop);
}

/// The key in the frame: `t0` for the temp `#poplar.<mcfun>.t0`, and `s_i_countdown` for the local `#i_countdown`.
fn scoreFrameSlot(compiler: *Compiler, score: ir.Score) std.mem.Allocator.Error!ir.DataPath {
    const key = switch (score.kind) {
        .temp => |temp| try std.fmt.allocPrint(compiler.arena, "t{d}", .{temp.index}),
        .local => try std.fmt.allocPrint(compiler.arena, "s_{s}", .{score.holder[1..]}),
        .global, .constant => unreachable,
    };
    return .inStorage(.frame, key);
}

/// The key in the frame of the data local `names_countdown`: `d_names_countdown`.
fn dataFrameSlot(compiler: *Compiler, key: []const u8) std.mem.Allocator.Error!ir.DataPath {
    return .inStorage(.frame, try std.fmt.allocPrint(compiler.arena, "d_{s}", .{key}));
}

pub fn buildCallGraph(compiler: *Compiler) std.mem.Allocator.Error!void {
    for (compiler.mcfuns.keys(), compiler.mcfuns.values()) |mcfun_key, declaration| {
        compiler.scope = compiler.scopeOf(declaration.namespace, declaration.imports);
        var calls: std.StringArrayHashMapUnmanaged(void) = .empty;
        try collectCalls(compiler, declaration.mcfun.body, &calls);
        try compiler.mcfun_calls.put(compiler.arena, mcfun_key, calls);
    }
}

/// The key of a called name, without errors: the compile step reports a missing import or name.
pub fn calledKey(compiler: *Compiler, identifier: ast.Identifier) std.mem.Allocator.Error!?[]const u8 {
    const namespace = identifier.namespace orelse compiler.scope.namespace;
    const mcfun_key = try declarations.qualifiedKey(compiler, namespace, identifier.name);
    return if (compiler.mcfuns.contains(mcfun_key)) mcfun_key else null;
}

/// Finds the mcfun calls in a body. This can find calls that a compile-time branch removes later. That only adds saves.
fn collectCalls(
    compiler: *Compiler,
    body: []const ast.Statement,
    calls: *std.StringArrayHashMapUnmanaged(void),
) std.mem.Allocator.Error!void {
    for (body) |statement| switch (statement.kind) {
        .var_decl => |var_decl| try collectExpressionCalls(compiler, var_decl.value, calls),
        .assign => |assign| try collectExpressionCalls(compiler, assign.value, calls),
        .@"return" => |value| if (value) |expression| try collectExpressionCalls(compiler, expression, calls),
        .@"break", .@"continue" => {},
        .@"if" => |if_statement| {
            try collectExpressionCalls(compiler, if_statement.condition, calls);
            try collectCalls(compiler, if_statement.then_body, calls);
            if (if_statement.else_body) |else_body| try collectCalls(compiler, else_body, calls);
        },
        .@"for" => |loop| try collectCalls(compiler, loop.body, calls),
        .@"while" => |loop| {
            try collectExpressionCalls(compiler, loop.condition, calls);
            try collectCalls(compiler, loop.body, calls);
        },
        .execute => |execute| {
            try collectInsertCalls(compiler, execute.subcommands, calls);
            try collectCalls(compiler, execute.body, calls);
        },
        .expression => |expression| try collectExpressionCalls(compiler, expression, calls),
        .command => |command| try collectInsertCalls(compiler, command.parts, calls),
    };
}

/// `/say {{double(2)}};` calls `double` too, and `/function std:clamp {...};` is a use of `std:clamp`.
fn collectInsertCalls(
    compiler: *Compiler,
    parts: []const ast.CommandPart,
    calls: *std.StringArrayHashMapUnmanaged(void),
) std.mem.Allocator.Error!void {
    for (parts) |part| switch (part.content) {
        .text => |text| try collectStdIds(compiler, text, calls),
        .insert => |expression| try collectExpressionCalls(compiler, expression, calls),
    };
}

/// A std mcfun is only written when something uses it, so a `std:name` in Minecraft text counts as a use.
fn collectStdIds(compiler: *Compiler, text: []const u8, calls: *std.StringArrayHashMapUnmanaged(void)) std.mem.Allocator.Error!void {
    const prefix = Compiler.std_namespace ++ ":";
    var index: usize = 0;
    while (std.mem.indexOfPos(u8, text, index, prefix)) |start| {
        index = start + prefix.len;
        if (start > 0 and Config.isResourceNameChar(text[start - 1])) continue;
        var end = index;
        while (end < text.len and (std.ascii.isAlphanumeric(text[end]) or text[end] == '_')) end += 1;
        const mcfun_key = try declarations.qualifiedKey(compiler, Compiler.std_namespace, text[index..end]);
        if (compiler.mcfuns.contains(mcfun_key)) try calls.put(compiler.arena, mcfun_key, {});
    }
}

fn collectExpressionCalls(
    compiler: *Compiler,
    expression: *const ast.Expression,
    calls: *std.StringArrayHashMapUnmanaged(void),
) std.mem.Allocator.Error!void {
    switch (expression.kind) {
        .prefix => |prefix| try collectExpressionCalls(compiler, prefix.operand, calls),
        .infix => |infix| {
            try collectExpressionCalls(compiler, infix.left, calls);
            try collectExpressionCalls(compiler, infix.right, calls);
        },
        .minecraft_check => |parts| try collectInsertCalls(compiler, parts, calls),
        .list => |elements| for (elements) |element| try collectExpressionCalls(compiler, element, calls),
        .compound => |entries| for (entries) |entry| try collectExpressionCalls(compiler, entry.value, calls),
        .call => |call| {
            for (call.args) |arg| try collectExpressionCalls(compiler, arg, calls);
            if (call.with) |with| if (with == .value) try collectExpressionCalls(compiler, with.value, calls);
            if (call.callee.kind != .identifier) return;

            // An event callback is called from `load`, as far as the call graph is concerned.
            const is_event = call.callee.kind.identifier.namespace == null and load.event_builtins.has(call.callee.kind.identifier.name);
            if (is_event and call.args.len > 0 and call.args[call.args.len - 1].kind == .identifier) {
                if (try calledKey(compiler, call.args[call.args.len - 1].kind.identifier)) |callback| try calls.put(
                    compiler.arena,
                    callback,
                    {},
                );
            }
            const called = try calledKey(compiler, call.callee.kind.identifier) orelse return;
            try calls.put(compiler.arena, called, {});
        },
        else => {},
    }
}

/// True if `from` can call `to`, directly or through other mcfuns.
pub fn canReach(compiler: *Compiler, from: []const u8, to: []const u8) std.mem.Allocator.Error!bool {
    var pending: std.ArrayList([]const u8) = .empty;
    var visited: std.StringHashMapUnmanaged(void) = .empty;
    try pending.append(compiler.arena, from);

    while (pending.pop()) |name| {
        if (std.mem.eql(u8, name, to)) return true;
        if ((try visited.getOrPut(compiler.arena, name)).found_existing) continue;

        const calls = compiler.mcfun_calls.get(name) orelse continue;
        try pending.appendSlice(compiler.arena, calls.keys());
    }
    return false;
}

pub fn compileCall(compiler: *Compiler, call: ast.Call, env: *Environment, commands: *std.ArrayList(ir.Command)) Compiler.Error!void {
    if (call.callee.kind != .identifier) return compiler.fail("only named functions can be called", .{});
    const name = call.callee.kind.identifier.name;

    if (call.callee.kind.identifier.namespace == null and load.event_builtins.has(name)) return load.compileEvent(
        compiler,
        call,
        name,
        env,
    );
    if (data.isStringCall(call) or data.isStringTest(call)) return compiler.fail(
        "'{s}' gives a value. Use it: '$x = {s}(...);' or 'if ({s}(...))'",
        .{ name, name, name },
    );
    if (call.callee.kind.identifier.namespace == null and isBuiltin(name)) return data.compileListBuiltin(
        compiler,
        name,
        call,
        env,
        commands,
    );
    const callee = try declarations.findMcfun(compiler, call.callee.kind.identifier);

    compiler.mcfun.temp_count = 0;
    const command = try compileMcfunCall(compiler, call, callee.declaration, env, commands);
    if (compiler.mcfun.live_locals.items.len > 0 and try canReach(compiler, callee.key, compiler.mcfun.key)) return appendWithSavedValues(
        compiler,
        command,
        null,
        0,
        commands,
    );
    try commands.append(compiler.arena, command);
}

pub const builtin_names = [_][]const u8{
    "append",
    "prepend",
    "insert",
    "remove",
    "len",
    "text",
    "onEvent",
    "onTrigger",
    "onDeath",
    "onFirstJoin",
    "onJoin",
    "onRespawn",
    "slice",
    "str",
    "startsWith",
    "endsWith",
};

pub fn isBuiltin(name: []const u8) bool {
    for (builtin_names) |builtin| {
        if (std.mem.eql(u8, builtin, name)) return true;
    }
    return false;
}

pub fn isBuiltinCall(call: ast.Call, name: []const u8) bool {
    if (call.callee.kind != .identifier or call.callee.kind.identifier.namespace != null) return false;
    return std.mem.eql(u8, call.callee.kind.identifier.name, name);
}

test "a recursive call saves the locals of an mcfun in another namespace where they are" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const command_tree = try arena.allocator().create(CommandTree);
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
    try std.testing.expectEqualStrings(
        "mcfun 'one' runs in the game, so its result is not known when the pack is built",
        errors[1].message,
    );
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
    try std.testing.expectEqualStrings(
        "'with' needs a compound, but '$num' is 0.05f. Declare it as a compound: 'var $num = {name: 0.05f};'",
        errors[2].message,
    );
    try std.testing.expectEqualStrings(
        "'with' needs a compound, but '$list' is [1]. Declare it as a compound: 'var $list = {name: [1]};'",
        errors[3].message,
    );
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
    try std.testing.expectEqualStrings(
        "'copy' is a build-time constant, but this value only exists in the game. Use 'var #copy' for a score or 'var $copy' for data",
        errors[0].message,
    );
    try std.testing.expectEqualStrings(
        "mcfun 'heal' uses '$(amount)', so it needs a compound: 'heal() with {amount: ...}'",
        errors[1].message,
    );
    try std.testing.expectEqualStrings(
        "mcfun 'heal' takes no arguments. Pass them as a compound: 'heal() with {amount: ...}'",
        errors[2].message,
    );
    try std.testing.expectEqualStrings(
        "'with' needs a compound ('{name: ...}'), a '$' variable, 'entity <selector>' or 'block <position>'",
        errors[3].message,
    );
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
    try std.testing.expectEqual(ir.Command.stack_clear, program.load.?.commands[0]);
}
