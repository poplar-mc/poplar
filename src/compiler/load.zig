//! What the game runs on its own: `poplar/load`, the `load` and `tick` of each namespace, and events.

const std = @import("std");
const Compiler = @import("../Compiler.zig");
const ast = @import("../ast.zig");
const Environment = @import("../Environment.zig");
const ir = @import("../ir.zig");
const Lexer = @import("../Lexer.zig");
const optimizer = @import("../optimizer.zig");
const Parser = @import("../Parser.zig");
const datapack_writer = @import("../datapack_writer.zig");
const declarations = @import("declarations.zig");
const scores = @import("scores.zig");
const values = @import("values.zig");

/// The IR names of `load` or `tick` of each namespace that has one. A namespace comes after the namespaces it
/// imports. Namespaces that import each other are in alphabetical order.
pub fn hookNames(compiler: *Compiler, namespaces: std.StringArrayHashMapUnmanaged(void), hook: []const u8) Compiler.CompileError![]const []const u8 {
    var names: std.ArrayList([]const u8) = .empty;
    for (try namespaceOrder(compiler)) |namespace| {
        if (namespaces.contains(namespace)) try names.append(compiler.arena, try declarations.functionName(compiler, namespace, hook));
    }
    return names.items;
}

fn namespaceOrder(compiler: *Compiler) Compiler.CompileError![]const []const u8 {
    const sorted = try compiler.arena.dupe([]const u8, compiler.namespace_imports.keys());
    std.mem.sort([]const u8, sorted, {}, lessThanString);
    var order: std.ArrayList([]const u8) = .empty;
    var visited: std.StringHashMapUnmanaged(void) = .empty;
    for (sorted) |namespace| try visitNamespace(compiler, namespace, &visited, &order);
    return order.items;
}

fn visitNamespace(compiler: *Compiler, namespace: []const u8, visited: *std.StringHashMapUnmanaged(void), order: *std.ArrayList([]const u8)) Compiler.CompileError!void {
    if ((try visited.getOrPut(compiler.arena, namespace)).found_existing) return;
    if (compiler.namespace_imports.get(namespace)) |imports| {
        const sorted = try compiler.arena.dupe([]const u8, imports.keys());
        std.mem.sort([]const u8, sorted, {}, lessThanString);
        for (sorted) |imported| try visitNamespace(compiler, imported, visited, order);
    }
    try order.append(compiler.arena, namespace);
}

fn lessThanString(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

/// The mcfuns that a project mcfun can call, directly or through others. Event callbacks count as calls from `load`.
pub fn reachableFromProject(compiler: *Compiler) Compiler.CompileError!std.StringHashMapUnmanaged(void) {
    var reached: std.StringHashMapUnmanaged(void) = .empty;
    var pending: std.ArrayList([]const u8) = .empty;
    for (compiler.mcfuns.keys(), compiler.mcfuns.values()) |mcfun_key, declaration| {
        if (declaration.origin != .std) try pending.append(compiler.arena, mcfun_key);
    }
    while (pending.pop()) |name| {
        const entry = try reached.getOrPut(compiler.arena, name);
        if (entry.found_existing) continue;
        const calls = compiler.mcfun_calls.get(name) orelse continue;
        for (calls.keys()) |called| try pending.append(compiler.arena, called);
    }
    return reached;
}

/// For each event: `poplar/event_<n>` resets the player's score and runs the callback as `@s` at the player.
/// `poplar/tick` runs it for every player with a count, then the user's `tick`.
pub fn appendEventFunctions(compiler: *Compiler, functions: *std.ArrayList(ir.McFunction), ticks: []const []const u8) Compiler.CompileError!void {
    if (compiler.events.items.len == 0) return;

    var tick: std.ArrayList(ir.Command) = .empty;
    for (compiler.events.items, 0..) |event, index| {
        const objective = try eventObjective(compiler, event, index);
        const name = try std.fmt.allocPrint(compiler.arena, "poplar/event_{d}", .{index});
        const reset: ir.Command = .{ .raw = try std.fmt.allocPrint(compiler.arena, "scoreboard players reset @s {s}", .{objective}) };
        // A player without the tag `<objective>` has not joined before.
        const mark: ir.Command = .{ .raw = try std.fmt.allocPrint(compiler.arena, "tag @s add {s}", .{objective}) };
        const body: []const ir.Command = switch (event.kind) {
            .criteria, .trigger, .respawn => &.{ reset, .{ .function = event.callback } },
            .first_join => &.{ mark, .{ .function = event.callback } },
            .join => &.{ reset, mark, .{ .function = event.callback } },
        };
        try functions.append(compiler.arena, .{ .name = name, .commands = try compiler.arena.dupe(ir.Command, body) });

        const players: []const []const u8 = switch (event.kind) {
            .criteria, .trigger => &.{try std.fmt.allocPrint(compiler.arena, "@a[scores={{{s}=1..}}]", .{objective})},
            .first_join => &.{try std.fmt.allocPrint(compiler.arena, "@a[tag=!{s}]", .{objective})},
            // A rejoin: the score of `leave_game` counted when the player left.
            .join => &.{ try std.fmt.allocPrint(compiler.arena, "@a[tag=!{s}]", .{objective}), try std.fmt.allocPrint(compiler.arena, "@a[scores={{{s}=1..}}]", .{objective}) },
            // Dead, and alive again: `time_since_death` only counts while the player is alive.
            .respawn => &.{try std.fmt.allocPrint(compiler.arena, "@a[scores={{{s}=1..,{s}_alive=1..}}]", .{ objective, objective })},
        };
        for (players) |selector| {
            const subcommands = try std.fmt.allocPrint(compiler.arena, "as {s} at @s", .{selector});
            try tick.append(compiler.arena, .{ .execute_raw = .{ .subcommands = subcommands, .run = try compiler.createCommand(.{ .function = name }) } });
        }
    }
    for (compiler.events.items) |event| {
        const trigger = event.trigger orelse continue;
        try tick.append(compiler.arena, .{ .raw = try std.fmt.allocPrint(compiler.arena, "scoreboard players enable @a {s}", .{trigger}) });
    }
    for (ticks) |name| try tick.append(compiler.arena, .{ .function = name });
    try functions.append(compiler.arena, .{ .name = "poplar/tick", .commands = try tick.toOwnedSlice(compiler.arena) });
}

fn eventObjective(compiler: *Compiler, event: Compiler.Event, index: usize) Compiler.CompileError![]const u8 {
    return event.trigger orelse std.fmt.allocPrint(compiler.arena, "{s}.event_{d}", .{ event.namespace orelse compiler.pack_namespace, index });
}

/// The optimizer can remove the last use of a constant, for example `*= #poplar.c1`.
pub fn removeUnusedConstants(compiler: *Compiler, functions: []const ir.McFunction) Compiler.CompileError!void {
    var index = compiler.constants.count();
    while (index > 0) {
        index -= 1;
        const constant = try ir.Score.constant(compiler.arena, compiler.constants.keys()[index]);
        if (!isScoreRead(functions, constant)) compiler.constants.orderedRemoveAt(index);
    }
}

fn isScoreRead(functions: []const ir.McFunction, score: ir.Score) bool {
    for (functions) |function| {
        for (function.commands) |command| {
            if (optimizer.readsScore(command, score)) return true;
        }
    }
    return false;
}

/// A score that is only used on entities (`@s.#mana`) needs no initial value on `#global`. A text part such as
/// `text(#mana)` names `#global` in the command text, so that counts as a use too.
fn isGlobalValueUsed(compiler: *Compiler, functions: []const ir.McFunction, global: Compiler.GlobalScore) Compiler.CompileError!bool {
    const score = scores.globalScore(global);
    const objective = try std.fmt.allocPrint(compiler.arena, "\"{s}.{s}\"", .{ global.output_namespace orelse compiler.pack_namespace, global.name });
    for (functions) |function| {
        for (function.commands) |command| {
            if (optimizer.readsScore(command, score) or mentionsGlobalHolder(command, objective)) return true;
        }
    }
    return false;
}

fn mentionsGlobalHolder(command: ir.Command, objective: []const u8) bool {
    const text = switch (command) {
        .raw, .macro => |text| text,
        .function_with => |call| if (call.arguments == .compound) call.arguments.compound else return false,
        .execute => |execute| return mentionsGlobalHolder(execute.run.*, objective),
        .execute_raw => |execute| return mentionsGlobalHolder(execute.run.*, objective),
        .store_result => |store| return mentionsGlobalHolder(store.run.*, objective),
        .return_run => |run| return mentionsGlobalHolder(run.*, objective),
        else => return false,
    };
    return std.mem.indexOf(u8, text, Compiler.global_holder) != null and std.mem.indexOf(u8, text, objective) != null;
}

/// Runs after all mcfuns, so that every constant they use is known.
pub fn buildLoadFunction(compiler: *Compiler, functions: []const ir.McFunction) Compiler.CompileError!ir.McFunction {
    var commands: std.ArrayList(ir.Command) = .empty;

    // A run that stopped in the middle of a recursive call can leave frames behind.
    if (compiler.uses_stack) try commands.append(compiler.arena, .stack_clear);
    try commands.append(compiler.arena, .{ .add_objective = .{} });
    for (try declarations.outputNamespaces(compiler)) |namespace| try commands.append(compiler.arena, .{ .add_objective = .{ .namespace = namespace } });
    for (compiler.globals.values()) |global| try commands.append(compiler.arena, .{ .add_objective = .{ .namespace = global.output_namespace, .name = global.name } });
    for (compiler.events.items, 0..) |event, index| {
        const objective = try eventObjective(compiler, event, index);
        const criteria = switch (event.kind) {
            .criteria, .trigger => event.criteria,
            .first_join => continue,
            .join => "minecraft.custom:minecraft.leave_game",
            .respawn => "deathCount",
        };
        try commands.append(compiler.arena, .{ .raw = try std.fmt.allocPrint(compiler.arena, "scoreboard objectives add {s} {s}", .{ objective, criteria }) });
        if (event.kind == .respawn) {
            try commands.append(compiler.arena, .{ .raw = try std.fmt.allocPrint(compiler.arena, "scoreboard objectives add {s}_alive minecraft.custom:minecraft.time_since_death", .{objective}) });
        }
    }

    for (compiler.constants.keys()) |constant| {
        try commands.append(compiler.arena, .{ .score_set = .{
            .score = try scores.constantScore(compiler, constant),
            .value = constant,
        } });
    }

    for (compiler.globals.values()) |global| {
        if (!try isGlobalValueUsed(compiler, functions, global)) continue;
        try commands.append(compiler.arena, .{ .score_set_if_unset = .{
            .score = scores.globalScore(global),
            .value = global.initial_value,
        } });
    }

    for (compiler.data_globals.values()) |global| {
        var target: ir.DataPath = .inStorage(global.storage, global.name);
        target.namespace = global.output_namespace;
        try commands.append(compiler.arena, .{ .data_set_if_unset = .{ .target = target, .snbt = global.initial_snbt } });
    }

    // A `load` with only `onEvent` lines has no commands, so `poplar/load` does not call it.
    for (try hookNames(compiler, compiler.load_namespaces, "load")) |name| {
        const is_empty = for (functions) |function| {
            if (std.mem.eql(u8, function.name, name)) break function.commands.len == 0;
        } else true;
        if (!is_empty) try commands.append(compiler.arena, .{ .function = name });
    }

    return .{ .name = "poplar/load", .commands = try commands.toOwnedSlice(compiler.arena) };
}

/// The event builtins, and the kind of event each one registers.
pub const event_builtins = std.StaticStringMap(Compiler.Event.Kind).initComptime(.{
    .{ "onEvent", .criteria },
    .{ "onTrigger", .trigger },
    .{ "onDeath", .criteria },
    .{ "onFirstJoin", .first_join },
    .{ "onJoin", .join },
    .{ "onRespawn", .respawn },
});

/// `onEvent(criteria, callback)` and the other event builtins in `load`. It registers the event at compile time and writes
/// no command.
pub fn compileEvent(compiler: *Compiler, call: ast.Call, builtin: []const u8, env: *Environment) Compiler.CompileError!void {
    const kind = event_builtins.get(builtin).?;
    const is_trigger = kind == .trigger;
    if (!compiler.in_load) return compiler.addError("'{s}' must be in 'mcfun load'", .{builtin});
    if (isInRuntimeBranch(env)) return compiler.addError("'{s}' registers the event when the pack is compiled, so it cannot be in a runtime 'if', 'while' or 'execute'", .{builtin});

    // `onEvent(criteria, callback)` and `onTrigger(name, callback)` take a name first; the player events only a callback.
    const takes_name = std.mem.eql(u8, builtin, "onEvent") or is_trigger;
    const first = if (is_trigger) "name" else "criteria";
    if (takes_name and call.args.len != 2) return compiler.addError("'{s}' expects 2 arguments ({s}, callback), found {d}", .{ builtin, first, call.args.len });
    if (!takes_name and call.args.len != 1) return compiler.addError("'{s}' expects 1 argument (callback), found {d}", .{ builtin, call.args.len });

    var criteria: []const u8 = if (std.mem.eql(u8, builtin, "onDeath")) "deathCount" else "";
    var trigger: ?[]const u8 = null;
    if (takes_name) {
        const value = try values.evaluate(compiler, call.args[0], env) orelse return;
        if (value != .string or value.string.len == 0) {
            return compiler.addError("the {s} of '{s}' must be a string, for example \"{s}\"", .{ first, builtin, if (is_trigger) "showoff" else "deathCount" });
        }
        if (is_trigger) for (value.string) |char| {
            if (!std.ascii.isAlphanumeric(char) and std.mem.indexOfScalar(u8, "_-.+", char) == null) {
                return compiler.addError("the trigger name '{s}' can only have letters, 0-9, '_', '-', '.' and '+'", .{value.string});
            }
        };
        if (is_trigger) if (try poplarObjectiveClash(compiler, value.string)) |prefix| {
            return compiler.addError("the trigger name '{s}' starts with '{s}', which Poplar uses for its own objectives", .{ value.string, prefix });
        };
        criteria = if (is_trigger) "trigger" else value.string;
        if (is_trigger) trigger = value.string;
    }

    const callback = try callbackOf(compiler, call.args[call.args.len - 1], builtin) orelse return;
    try compiler.events.append(compiler.arena, .{ .kind = kind, .criteria = criteria, .callback = callback, .namespace = compiler.scope.output_namespace, .trigger = trigger });
}

/// The IR name of an event's callback: an mcfun that uses no macro arguments. Null after an error.
fn callbackOf(compiler: *Compiler, callback: *const ast.Expression, builtin: []const u8) Compiler.CompileError!?[]const u8 {
    const outer_position = compiler.enterExpression(callback);
    defer compiler.restorePosition(outer_position);
    if (callback.kind != .identifier or callback.kind.identifier.kind != .compile_time) {
        try compiler.addError("the callback of '{s}' must be the name of an mcfun", .{builtin});
        return null;
    }
    const name = callback.kind.identifier.name;
    const found = try declarations.findMcfun(compiler, callback.kind.identifier) orelse return null;
    var keys: std.StringArrayHashMapUnmanaged(void) = .empty;
    try Compiler.collectMacroKeys(compiler.arena, found.declaration.mcfun.body, &keys);
    if (keys.count() > 0) {
        try compiler.addError("the callback '{s}' is run by the game, so it gets no macro arguments and cannot use '$({s})'", .{ name, keys.keys()[0] });
        return null;
    }
    return found.declaration.ir_name;
}

/// Poplar's objectives are `poplar.<ns>` and `<ns>.<name>`. Gives the prefix that a trigger name clashes with.
fn poplarObjectiveClash(compiler: *Compiler, name: []const u8) Compiler.CompileError!?[]const u8 {
    if (std.mem.startsWith(u8, name, "poplar.")) return "poplar.";
    const namespaces = try std.mem.concat(compiler.arena, []const u8, &.{ &.{compiler.pack_namespace}, try declarations.outputNamespaces(compiler) });
    for (namespaces) |namespace| {
        const prefix = try std.fmt.allocPrint(compiler.arena, "{s}.", .{namespace});
        if (std.mem.startsWith(u8, name, prefix)) return prefix;
    }
    return null;
}

fn isInRuntimeBranch(env: *const Environment) bool {
    var scope: ?*const Environment = env;
    while (scope) |current| : (scope = current.outer) {
        if (current.runtime_branch) return true;
    }
    return false;
}

test "selectors as values, text parts and events" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    var compiler = try Compiler.compileForTest(arena.allocator(),
        \\var #hp = 7;
        \\var $stats = {maxHp: 20};
        \\mcfun tellraw() { /tellraw $(target) $(message); }
        \\mcfun load() { onEvent("deathCount", playerDied); }
        \\mcfun playerDied() { var #left = 3; tellraw() with {target: @a, message: ["HP ", text(#hp), text($stats.maxHp), text(@s.$CustomName), text(#left)]}; }
        \\mcfun greet() { /say $(target); }
        \\mcfun main() { greet() with {target: @p}; }
    );
    const program = try compiler.compile();
    try std.testing.expectEqual(0, compiler.errors.items.len);

    try std.testing.expectEqualStrings(
        \\scoreboard players set #left_playerDied poplar.ns 3
        \\function ns:tellraw {target:"@a",message:["HP ",{score:{name:"#global",objective:"ns.hp"}},{storage:"ns:data",nbt:"stats.maxHp"},{entity:"@s",nbt:"CustomName"},{score:{name:"#left_playerDied",objective:"poplar.ns"}}]}
        \\
    , try Compiler.renderForTest(arena.allocator(), program, "playerDied"));
    try std.testing.expectEqualStrings("function ns:greet {target:\"@p\"}\n", try Compiler.renderForTest(arena.allocator(), program, "main"));
    try std.testing.expectEqualStrings(
        \\scoreboard players reset @s ns.event_0
        \\function ns:player_died
        \\
    , try Compiler.renderForTest(arena.allocator(), program, "poplar/event_0"));
    try std.testing.expectEqualStrings(
        \\execute as @a[scores={ns.event_0=1..}] at @s run function ns:poplar/event_0
        \\
    , try Compiler.renderForTest(arena.allocator(), program, "poplar/tick"));
    try std.testing.expectEqualDeep(&[_][]const u8{"poplar/tick"}, program.tick);

    const load = try datapack_writer.renderFunction(arena.allocator(), "ns", program.load.?);
    try std.testing.expect(std.mem.indexOf(u8, load, "scoreboard objectives add ns.event_0 deathCount\n") != null);
    // `load` has only the event, so `poplar/load` does not call it.
    try std.testing.expect(std.mem.indexOf(u8, load, "function ns:load") == null);
}

test "onEvent errors" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    var compiler = try Compiler.compileForTest(arena.allocator(),
        \\mcfun load() {
        \\    onEvent("deathCount", withMacroArgument);
        \\    onEvent("deathCount", missing);
        \\}
        \\mcfun withMacroArgument() { /say $(x); }
        \\mcfun other() { onEvent("deathCount", other); }
    );
    _ = try compiler.compile();

    const errors = compiler.errors.items;
    try std.testing.expectEqual(3, errors.len);
    try std.testing.expectEqualStrings("the callback 'withMacroArgument' is run by the game, so it gets no macro arguments and cannot use '$(x)'", errors[0].message);
    try std.testing.expectEqualStrings("unknown function 'missing'", errors[1].message);
    try std.testing.expectEqualStrings("'onEvent' must be in 'mcfun load'", errors[2].message);
}

test "load and tick of a project namespace are run by the game, std's are not" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    var compiler = try Compiler.compileForTest(arena.allocator(),
        \\var #mana = 0;
        \\mcfun load() { /say loaded; }
        \\mcfun tick() { /say tick; }
    );
    const program = try compiler.compile();
    try std.testing.expectEqualStrings(
        \\scoreboard objectives add poplar.ns dummy
        \\scoreboard objectives add ns.mana dummy
        \\function ns:load
        \\
    , try datapack_writer.renderFunction(arena.allocator(), "ns", program.load.?));
    try std.testing.expectEqualDeep(&[_][]const u8{"tick"}, program.tick);

    var parser = try Parser.init(arena.allocator(), Lexer.init("mcfun load() {} mcfun tick() {}"));
    var library = Compiler.init(arena.allocator(), compiler.command_tree);
    try library.addProgram("lib.poplar", try parser.parseProgram(), .std);
    const library_program = try library.compile();
    try std.testing.expectEqual(null, library_program.load);
    try std.testing.expectEqual(0, library_program.tick.len);
}

test "onTrigger makes a trigger objective, runs the callback and enables it again, even with the namespace name" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    var compiler = try Compiler.compileForTest(arena.allocator(),
        \\mcfun load() {
        \\    onTrigger("ns", show);
        \\    onTrigger("bad name", show);
        \\    onTrigger("ns.mana", show);
        \\}
        \\mcfun show() { /say shown; }
    );
    const program = try compiler.compile();
    try std.testing.expectEqual(2, compiler.errors.items.len);
    try std.testing.expectEqualStrings("the trigger name 'bad name' can only have letters, 0-9, '_', '-', '.' and '+'", compiler.errors.items[0].message);
    try std.testing.expectEqualStrings("the trigger name 'ns.mana' starts with 'ns.', which Poplar uses for its own objectives", compiler.errors.items[1].message);

    try std.testing.expectEqualStrings(
        \\execute as @a[scores={ns=1..}] at @s run function ns:poplar/event_0
        \\scoreboard players enable @a ns
        \\
    , try Compiler.renderForTest(arena.allocator(), program, "poplar/tick"));
    try std.testing.expectEqualStrings(
        \\scoreboard players reset @s ns
        \\function ns:show
        \\
    , try Compiler.renderForTest(arena.allocator(), program, "poplar/event_0"));
    const load = try datapack_writer.renderFunction(arena.allocator(), "ns", program.load.?);
    try std.testing.expect(std.mem.indexOf(u8, load, "scoreboard objectives add poplar.ns dummy\nscoreboard objectives add ns trigger\n") != null);
}

test "player events: first join, join, death and respawn" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    var compiler = try Compiler.compileForTest(arena.allocator(),
        \\mcfun load() { onFirstJoin(welcome); onJoin(greet); onRespawn(back); onJoin(); }
        \\mcfun welcome() {}
        \\mcfun greet() {}
        \\mcfun back() {}
    );
    const program = try compiler.compile();
    try std.testing.expectEqual(1, compiler.errors.items.len);
    try std.testing.expectEqualStrings("'onJoin' expects 1 argument (callback), found 0", compiler.errors.items[0].message);
    try std.testing.expectEqualStrings(
        \\execute as @a[tag=!ns.event_0] at @s run function ns:poplar/event_0
        \\execute as @a[tag=!ns.event_1] at @s run function ns:poplar/event_1
        \\execute as @a[scores={ns.event_1=1..}] at @s run function ns:poplar/event_1
        \\execute as @a[scores={ns.event_2=1..,ns.event_2_alive=1..}] at @s run function ns:poplar/event_2
        \\
    , try Compiler.renderForTest(arena.allocator(), program, "poplar/tick"));
}
