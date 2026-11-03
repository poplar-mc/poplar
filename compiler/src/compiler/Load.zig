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
        const reset = try std.fmt.allocPrint(self.gpa, "scoreboard players reset @s {s}", .{objective});
        try functions.append(self.gpa, .{ .name = name, .commands = try self.gpa.dupe(Ir.Command, &.{ .{ .raw = reset }, .{ .function = event.callback } }) });

        const subcommands = try std.fmt.allocPrint(self.gpa, "as @a[scores={{{s}=1..}}] at @s", .{objective});
        try tick.append(self.gpa, .{ .execute_raw = .{ .subcommands = subcommands, .run = try self.createCommand(.{ .function = name }) } });
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
        const add = try std.fmt.allocPrint(self.gpa, "scoreboard objectives add {s} {s}", .{ try eventObjective(self, event, index), event.criteria });
        try commands.append(self.gpa, .{ .raw = add });
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
        var target: Ir.DataPath = .inStorage(.data, global.name);
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
pub fn compileEvent(self: *Compiler, call: Ast.Call, builtin: []const u8, env: *Environment) Compiler.CompileError!void {
    const is_trigger = std.mem.eql(u8, builtin, "onTrigger");
    if (!self.in_load) return self.addError("'{s}' must be in 'mcfun load'", .{builtin});
    if (isInRuntimeBranch(env)) return self.addError("'{s}' registers the event when the pack is compiled, so it cannot be in a runtime 'if', 'while' or 'execute'", .{builtin});
    const first = if (is_trigger) "name" else "criteria";
    if (call.args.len != 2) return self.addError("'{s}' expects 2 arguments ({s}, callback), found {d}", .{ builtin, first, call.args.len });

    const value = try Values.evaluate(self, call.args[0], env) orelse return;
    if (value != .string or value.string.len == 0) {
        return self.addError("the {s} of '{s}' must be a string, for example \"{s}\"", .{ first, builtin, if (is_trigger) "showoff" else "deathCount" });
    }
    if (is_trigger) for (value.string) |char| {
        if (!std.ascii.isAlphanumeric(char) and std.mem.indexOfScalar(u8, "_-.+", char) == null) {
            return self.addError("the trigger name '{s}' can only have letters, 0-9, '_', '-', '.' and '+'", .{value.string});
        }
    };

    const callback = call.args[1];
    const outer_position = self.enterExpression(callback);
    defer self.restorePosition(outer_position);
    if (callback.kind != .identifier or callback.kind.identifier.storage != .compile_time) return self.addError("the callback of '{s}' must be the name of an mcfun", .{builtin});
    const name = callback.kind.identifier.name;
    const found = try Declarations.findFunction(self, callback.kind.identifier) orelse return;
    if (found.located.function.params.len > 0) return self.addError("the callback '{s}' is run by the game, so it cannot have parameters", .{name});

    const callback_name = found.located.ir_name;
    if (is_trigger) {
        try self.events.append(self.gpa, .{ .criteria = "trigger", .callback = callback_name, .namespace = self.scope.output_namespace, .trigger = value.string });
    } else {
        try self.events.append(self.gpa, .{ .criteria = value.string, .callback = callback_name, .namespace = self.scope.output_namespace });
    }
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
        \\mcfun tellraw(target, message) { /tellraw {{target}} {{message}}; }
        \\mcfun load() { onEvent("deathCount", playerDied); }
        \\mcfun playerDied() { var #left = 3; tellraw(@a, ["HP ", text(#hp), text($stats.maxHp), text(@s.$CustomName), text(#left)]); }
        \\mcfun greet(target) { /say {{target}}; }
        \\mcfun main() { greet(@p); }
    );
    const program = try compiler.compile();
    try std.testing.expectEqual(0, compiler.errors.items.len);

    try std.testing.expectEqualStrings(
        \\scoreboard players set #left_playerDied ns 3
        \\function ns:tellraw {target:"@a",message:["HP ",{score:{name:"#global",objective:"ns.hp"}},{storage:"ns:data",nbt:"stats.maxHp"},{entity:"@s",nbt:"CustomName"},{score:{name:"#left_playerDied",objective:"ns"}}]}
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
        \\mcfun withParam(x) { }
        \\mcfun other() { onEvent("deathCount", other); }
    );
    _ = try compiler.compile();

    const errors = compiler.errors.items;
    try std.testing.expectEqual(3, errors.len);
    try std.testing.expectEqualStrings("the callback 'withParam' is run by the game, so it cannot have parameters", errors[0].message);
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
        \\scoreboard objectives add ns dummy
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

test "onTrigger makes a trigger objective, runs the callback and enables it again" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    var compiler = try Compiler.compileForTest(arena.allocator(),
        \\mcfun load() {
        \\    onTrigger("showoff", show);
        \\    onTrigger("bad name", show);
        \\}
        \\mcfun show() { /say shown; }
    );
    const program = try compiler.compile();
    try std.testing.expectEqual(1, compiler.errors.items.len);
    try std.testing.expectEqualStrings("the trigger name 'bad name' can only have letters, 0-9, '_', '-', '.' and '+'", compiler.errors.items[0].message);

    try std.testing.expectEqualStrings(
        \\execute as @a[scores={showoff=1..}] at @s run function ns:poplar/event_0
        \\scoreboard players enable @a showoff
        \\
    , try Compiler.renderForTest(arena.allocator(), program, "poplar/tick"));
    try std.testing.expectEqualStrings(
        \\scoreboard players reset @s showoff
        \\function ns:show
        \\
    , try Compiler.renderForTest(arena.allocator(), program, "poplar/event_0"));
    const load = try Writer.renderFunction(arena.allocator(), "ns", program.load.?);
    try std.testing.expect(std.mem.indexOf(u8, load, "scoreboard objectives add showoff trigger\n") != null);
}
