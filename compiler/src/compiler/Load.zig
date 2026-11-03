// What the game runs on its own: `poplar/load`, the `load` and `tick` of each namespace, and events.
const std = @import("std");
const Compiler = @import("../Compiler.zig");
const Ast = @import("../Ast.zig");
const Environment = @import("../Environment.zig");
const Ir = @import("../Ir.zig");
const Lexer = @import("../Lexer.zig");
const Optimizer = @import("../Optimizer.zig");
const Parser = @import("../Parser.zig");
const Writer = @import("../Writer.zig");
const Declarations = @import("Declarations.zig");
const Scores = @import("Scores.zig");
const Values = @import("Values.zig");

// The IR names of `load` or `tick` of each namespace that has one. A namespace comes after the namespaces it
// imports. Namespaces that import each other are in alphabetical order.
pub fn hookNames(self: *Compiler, namespaces: std.StringArrayHashMapUnmanaged(void), hook: []const u8) Compiler.CompileError![]const []const u8 {
    var names: std.ArrayList([]const u8) = .empty;
    for (try namespaceOrder(self)) |namespace| {
        if (namespaces.contains(namespace)) try names.append(self.gpa, try Declarations.functionName(self, namespace, hook));
    }
    return names.items;
}

pub fn namespaceOrder(self: *Compiler) Compiler.CompileError![]const []const u8 {
    const sorted = try self.gpa.dupe([]const u8, self.namespace_imports.keys());
    std.mem.sort([]const u8, sorted, {}, lessThanString);
    var order: std.ArrayList([]const u8) = .empty;
    var visited: std.StringHashMapUnmanaged(void) = .empty;
    for (sorted) |namespace| try visitNamespace(self, namespace, &visited, &order);
    return order.items;
}

pub fn visitNamespace(self: *Compiler, namespace: []const u8, visited: *std.StringHashMapUnmanaged(void), order: *std.ArrayList([]const u8)) Compiler.CompileError!void {
    if ((try visited.getOrPut(self.gpa, namespace)).found_existing) return;
    if (self.namespace_imports.get(namespace)) |imports| {
        const sorted = try self.gpa.dupe([]const u8, imports.keys());
        std.mem.sort([]const u8, sorted, {}, lessThanString);
        for (sorted) |imported| try visitNamespace(self, imported, visited, order);
    }
    try order.append(self.gpa, namespace);
}

pub fn lessThanString(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

// The mcfuns that a project mcfun can call, directly or through others. Compiler.Event callbacks count as calls from `load`.
pub fn reachableFromProject(self: *Compiler) Compiler.CompileError!std.StringHashMapUnmanaged(void) {
    var reached: std.StringHashMapUnmanaged(void) = .empty;
    var pending: std.ArrayList([]const u8) = .empty;
    for (self.functions.keys(), self.functions.values()) |function_key, located| {
        if (located.origin != .std) try pending.append(self.gpa, function_key);
    }
    while (pending.pop()) |name| {
        const entry = try reached.getOrPut(self.gpa, name);
        if (entry.found_existing) continue;
        const calls = self.mcfun_calls.get(name) orelse continue;
        for (calls.keys()) |called| try pending.append(self.gpa, called);
    }
    return reached;
}

// For each event: `poplar/event_<n>` resets the player's score and runs the callback as `@s` at the player.
// `poplar/tick` runs it for every player with a count, then the user's `tick`.
pub fn appendEventFunctions(self: *Compiler, functions: *std.ArrayList(Ir.McFunction), ticks: []const []const u8) Compiler.CompileError!void {
    if (self.events.items.len == 0) return;

    var tick: std.ArrayList(Ir.Command) = .empty;
    for (self.events.items, 0..) |event, index| {
        const objective = try eventObjective(self, event, index);
        const name = try std.fmt.allocPrint(self.gpa, "poplar/event_{d}", .{index});
        const reset: Ir.Command = .{ .raw = try std.fmt.allocPrint(self.gpa, "scoreboard players reset @s {s}", .{objective}) };
        // A player without the tag `<objective>` has not joined before.
        const mark: Ir.Command = .{ .raw = try std.fmt.allocPrint(self.gpa, "tag @s add {s}", .{objective}) };
        const body: []const Ir.Command = switch (event.kind) {
            .criteria, .trigger, .respawn => &.{ reset, .{ .function = event.callback } },
            .first_join => &.{ mark, .{ .function = event.callback } },
            .join => &.{ reset, mark, .{ .function = event.callback } },
        };
        try functions.append(self.gpa, .{ .name = name, .commands = try self.gpa.dupe(Ir.Command, body) });

        const players: []const []const u8 = switch (event.kind) {
            .criteria, .trigger => &.{try std.fmt.allocPrint(self.gpa, "@a[scores={{{s}=1..}}]", .{objective})},
            .first_join => &.{try std.fmt.allocPrint(self.gpa, "@a[tag=!{s}]", .{objective})},
            // A rejoin: the score of `leave_game` counted when the player left.
            .join => &.{ try std.fmt.allocPrint(self.gpa, "@a[tag=!{s}]", .{objective}), try std.fmt.allocPrint(self.gpa, "@a[scores={{{s}=1..}}]", .{objective}) },
            // Dead, and alive again: `time_since_death` only counts while the player is alive.
            .respawn => &.{try std.fmt.allocPrint(self.gpa, "@a[scores={{{s}=1..,{s}_alive=1..}}]", .{ objective, objective })},
        };
        for (players) |selector| {
            const subcommands = try std.fmt.allocPrint(self.gpa, "as {s} at @s", .{selector});
            try tick.append(self.gpa, .{ .execute_raw = .{ .subcommands = subcommands, .run = try self.createCommand(.{ .function = name }) } });
        }
    }
    for (self.events.items) |event| {
        const trigger = event.trigger orelse continue;
        try tick.append(self.gpa, .{ .raw = try std.fmt.allocPrint(self.gpa, "scoreboard players enable @a {s}", .{trigger}) });
    }
    for (ticks) |name| try tick.append(self.gpa, .{ .function = name });
    try functions.append(self.gpa, .{ .name = "poplar/tick", .commands = try tick.toOwnedSlice(self.gpa) });
}

pub fn eventObjective(self: *Compiler, event: Compiler.Event, index: usize) Compiler.CompileError![]const u8 {
    return event.trigger orelse std.fmt.allocPrint(self.gpa, "{s}.event_{d}", .{ event.namespace orelse self.namespace, index });
}

// The optimizer can remove the last use of a constant, for example `*= #poplar.c1`.
pub fn removeUnusedConstants(self: *Compiler, functions: []const Ir.McFunction) Compiler.CompileError!void {
    var index = self.constants.count();
    while (index > 0) {
        index -= 1;
        const holder = try std.fmt.allocPrint(self.gpa, "#poplar.c{d}", .{self.constants.keys()[index]});
        if (!isScoreRead(functions, .{ .holder = holder })) self.constants.orderedRemoveAt(index);
    }
}

pub fn isScoreRead(functions: []const Ir.McFunction, score: Ir.Score) bool {
    for (functions) |function| {
        for (function.commands) |command| {
            if (Optimizer.readsScore(command, score)) return true;
        }
    }
    return false;
}

// A score that is only used on entities (`@s.#mana`) needs no initial value on `#global`. A text part such as
// `text(#mana)` names `#global` in the command text, so that counts as a use too.
pub fn isGlobalValueUsed(self: *Compiler, functions: []const Ir.McFunction, global: Compiler.GlobalScore) Compiler.CompileError!bool {
    const score = Scores.globalScore(global);
    const objective = try std.fmt.allocPrint(self.gpa, "\"{s}.{s}\"", .{ global.output_namespace orelse self.namespace, global.name });
    for (functions) |function| {
        for (function.commands) |command| {
            if (Optimizer.readsScore(command, score) or mentionsGlobalHolder(command, objective)) return true;
        }
    }
    return false;
}

pub fn mentionsGlobalHolder(command: Ir.Command, objective: []const u8) bool {
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

// Runs after all mcfuns, so that every constant they use is known.
pub fn buildLoadFunction(self: *Compiler, functions: []const Ir.McFunction) Compiler.CompileError!Ir.McFunction {
    var commands: std.ArrayList(Ir.Command) = .empty;

    // A run that stopped in the middle of a recursive call can leave frames behind.
    if (self.uses_stack) try commands.append(self.gpa, .stack_clear);
    try commands.append(self.gpa, .{ .add_objective = .{} });
    for (try Declarations.outputNamespaces(self)) |namespace| try commands.append(self.gpa, .{ .add_objective = .{ .namespace = namespace } });
    for (self.globals.values()) |global| try commands.append(self.gpa, .{ .add_objective = .{ .namespace = global.output_namespace, .name = global.name } });
    for (self.events.items, 0..) |event, index| {
        const objective = try eventObjective(self, event, index);
        const criteria = switch (event.kind) {
            .criteria, .trigger => event.criteria,
            .first_join => continue,
            .join => "minecraft.custom:minecraft.leave_game",
            .respawn => "deathCount",
        };
        try commands.append(self.gpa, .{ .raw = try std.fmt.allocPrint(self.gpa, "scoreboard objectives add {s} {s}", .{ objective, criteria }) });
        if (event.kind == .respawn) {
            try commands.append(self.gpa, .{ .raw = try std.fmt.allocPrint(self.gpa, "scoreboard objectives add {s}_alive minecraft.custom:minecraft.time_since_death", .{objective}) });
        }
    }

    for (self.constants.keys()) |constant| {
        try commands.append(self.gpa, .{ .score_set = .{
            .score = try Scores.constantScore(self, constant),
            .value = constant,
        } });
    }

    for (self.globals.values()) |global| {
        if (!try isGlobalValueUsed(self, functions, global)) continue;
        try commands.append(self.gpa, .{ .score_set_if_unset = .{
            .score = Scores.globalScore(global),
            .value = global.initial_value,
        } });
    }

    for (self.data_globals.values()) |global| {
        var target: Ir.DataPath = .inStorage(global.storage, global.name);
        target.namespace = global.output_namespace;
        try commands.append(self.gpa, .{ .data_set_if_unset = .{ .target = target, .snbt = global.initial_snbt } });
    }

    // A `load` with only `onEvent` lines has no commands, so `poplar/load` does not call it.
    for (try hookNames(self, self.load_namespaces, "load")) |name| {
        const is_empty = for (functions) |function| {
            if (std.mem.eql(u8, function.name, name)) break function.commands.len == 0;
        } else true;
        if (!is_empty) try commands.append(self.gpa, .{ .function = name });
    }

    return .{ .name = "poplar/load", .commands = try commands.toOwnedSlice(self.gpa) };
}

// `onEvent(criteria, callback)` or `onTrigger(name, callback)` in the entry file's `load`. It registers the event
// at compile time and writes no command.
// The event builtins, and the kind of event each one registers.
pub const event_builtins = std.StaticStringMap(Compiler.Event.Kind).initComptime(.{
    .{ "onEvent", .criteria },
    .{ "onTrigger", .trigger },
    .{ "onDeath", .criteria },
    .{ "onFirstJoin", .first_join },
    .{ "onJoin", .join },
    .{ "onRespawn", .respawn },
});

pub fn compileEvent(self: *Compiler, call: Ast.Call, builtin: []const u8, env: *Environment) Compiler.CompileError!void {
    const kind = event_builtins.get(builtin).?;
    const is_trigger = kind == .trigger;
    if (!self.in_load) return self.addError("'{s}' must be in 'mcfun load'", .{builtin});
    if (isInRuntimeBranch(env)) return self.addError("'{s}' registers the event when the pack is compiled, so it cannot be in a runtime 'if', 'while' or 'execute'", .{builtin});

    // `onEvent(criteria, callback)` and `onTrigger(name, callback)` take a name first; the player events only a callback.
    const takes_name = std.mem.eql(u8, builtin, "onEvent") or is_trigger;
    const first = if (is_trigger) "name" else "criteria";
    if (takes_name and call.args.len != 2) return self.addError("'{s}' expects 2 arguments ({s}, callback), found {d}", .{ builtin, first, call.args.len });
    if (!takes_name and call.args.len != 1) return self.addError("'{s}' expects 1 argument (callback), found {d}", .{ builtin, call.args.len });

    var criteria: []const u8 = if (std.mem.eql(u8, builtin, "onDeath")) "deathCount" else "";
    var trigger: ?[]const u8 = null;
    if (takes_name) {
        const value = try Values.evaluate(self, call.args[0], env) orelse return;
        if (value != .string or value.string.len == 0) {
            return self.addError("the {s} of '{s}' must be a string, for example \"{s}\"", .{ first, builtin, if (is_trigger) "showoff" else "deathCount" });
        }
        if (is_trigger) for (value.string) |char| {
            if (!std.ascii.isAlphanumeric(char) and std.mem.indexOfScalar(u8, "_-.+", char) == null) {
                return self.addError("the trigger name '{s}' can only have letters, 0-9, '_', '-', '.' and '+'", .{value.string});
            }
        };
        if (is_trigger) if (try poplarObjectiveClash(self, value.string)) |prefix| {
            return self.addError("the trigger name '{s}' starts with '{s}', which Poplar uses for its own objectives", .{ value.string, prefix });
        };
        criteria = if (is_trigger) "trigger" else value.string;
        if (is_trigger) trigger = value.string;
    }

    const callback = try callbackOf(self, call.args[call.args.len - 1], builtin) orelse return;
    try self.events.append(self.gpa, .{ .kind = kind, .criteria = criteria, .callback = callback, .namespace = self.scope.output_namespace, .trigger = trigger });
}

// The IR name of an event's callback: an mcfun that uses no macro arguments. Null after an error.
fn callbackOf(self: *Compiler, callback: *const Ast.Expr, builtin: []const u8) Compiler.CompileError!?[]const u8 {
    const outer_position = self.enterExpression(callback);
    defer self.restorePosition(outer_position);
    if (callback.kind != .identifier or callback.kind.identifier.storage != .compile_time) {
        try self.addError("the callback of '{s}' must be the name of an mcfun", .{builtin});
        return null;
    }
    const name = callback.kind.identifier.name;
    const found = try Declarations.findFunction(self, callback.kind.identifier) orelse return null;
    var keys: std.StringArrayHashMapUnmanaged(void) = .empty;
    try Compiler.collectMacroKeys(self.gpa, found.located.function.body, &keys);
    if (keys.count() > 0) {
        try self.addError("the callback '{s}' is run by the game, so it gets no macro arguments and cannot use '$({s})'", .{ name, keys.keys()[0] });
        return null;
    }
    return found.located.ir_name;
}

// Poplar's objectives are `poplar.<ns>` and `<ns>.<name>`. Gives the prefix that a trigger name clashes with.
fn poplarObjectiveClash(self: *Compiler, name: []const u8) Compiler.CompileError!?[]const u8 {
    if (std.mem.startsWith(u8, name, "poplar.")) return "poplar.";
    const namespaces = try std.mem.concat(self.gpa, []const u8, &.{ &.{self.namespace}, try Declarations.outputNamespaces(self) });
    for (namespaces) |namespace| {
        const prefix = try std.fmt.allocPrint(self.gpa, "{s}.", .{namespace});
        if (std.mem.startsWith(u8, name, prefix)) return prefix;
    }
    return null;
}

pub fn isInRuntimeBranch(env: *const Environment) bool {
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

    const load = try Writer.renderFunction(arena.allocator(), "ns", program.load.?);
    try std.testing.expect(std.mem.indexOf(u8, load, "scoreboard objectives add ns.event_0 deathCount\n") != null);
    // `load` has only the event, so `poplar/load` does not call it.
    try std.testing.expect(std.mem.indexOf(u8, load, "function ns:load") == null);
}

test "onEvent errors" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    var compiler = try Compiler.compileForTest(arena.allocator(),
        \\mcfun load() {
        \\    onEvent("deathCount", withParam);
        \\    onEvent("deathCount", missing);
        \\}
        \\mcfun withParam() { /say $(x); }
        \\mcfun other() { onEvent("deathCount", other); }
    );
    _ = try compiler.compile();

    const errors = compiler.errors.items;
    try std.testing.expectEqual(3, errors.len);
    try std.testing.expectEqualStrings("the callback 'withParam' is run by the game, so it gets no macro arguments and cannot use '$(x)'", errors[0].message);
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
    , try Writer.renderFunction(arena.allocator(), "ns", program.load.?));
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
    const load = try Writer.renderFunction(arena.allocator(), "ns", program.load.?);
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
