//! NBT data: assigning, paths and literals, list builtins, and the string helpers.

const std = @import("std");
const Compiler = @import("../Compiler.zig");
const ast = @import("../ast.zig");
const Environment = @import("../Environment.zig");
const ir = @import("../ir.zig");
const datapack_writer = @import("../datapack_writer.zig");
const calls = @import("calls.zig");
const conditions = @import("conditions.zig");
const declarations = @import("declarations.zig");
const scores = @import("scores.zig");
const values = @import("values.zig");

/// Sets data in storage or an entity path. A score or math is stored as an int.
pub fn compileDataAssign(compiler: *Compiler, target: ir.DataPath, expression: *const ast.Expression, env: *Environment, commands: *std.ArrayList(ir.Command)) Compiler.Error!void {
    const outer_position = compiler.enterExpression(expression);
    defer compiler.restorePosition(outer_position);

    if (!values.containsRuntimeValue(expression)) {
        const value = try values.evaluate(compiler, expression, env);
        if (value == .null) return compiler.fail("data cannot be set to null", .{});
        return commands.append(compiler.arena, .{ .data_set = .{ .target = target, .snbt = try values.valueToSnbt(compiler, value) } });
    }

    if (expression.kind == .call and isStringCall(expression.kind.call)) return compileStringInto(compiler, target, expression.kind.call, env, commands);
    if (expression.kind == .list or expression.kind == .compound) return compileLiteralAssign(compiler, target, expression, env, commands);

    // A macro argument is text in the command, so Minecraft reads its type, as in a hand-written datapack.
    if (expression.kind == .macro_key) {
        return commands.append(compiler.arena, .{ .data_set = .{ .target = target, .snbt = try std.fmt.allocPrint(compiler.arena, "$({s})", .{expression.kind.macro_key}) } });
    }

    if (expression.kind == .identifier) {
        const identifier = expression.kind.identifier;
        switch (identifier.kind) {
            .score => {
                const score = try scores.scoreSource(compiler, identifier, env);
                return commands.append(compiler.arena, .{ .score_to_data = .{ .target = target, .score = score } });
            },
            .data, .entity_data => {
                const source = try dataPathOf(compiler, identifier, env);
                if (std.meta.eql(source.holder, target.holder) and std.mem.eql(u8, source.path, target.path)) return;
                return commands.append(compiler.arena, .{ .data_copy = .{ .target = target, .source = source } });
            },
            .compile_time => {},
        }
    }

    compiler.mcfun.temp_count = 0;
    const temp = try scores.newTemp(compiler);
    try scores.compileInto(compiler, temp, expression, env, commands);
    try commands.append(compiler.arena, .{ .score_to_data = .{ .target = target, .score = temp } });
}

/// A runtime value inside a literal, and where it goes: `[1]` in `pos[1]`, `.hp` in `stats.hp`.
pub const LiteralPart = struct {
    path: []const u8,
    value: *const ast.Expression,
};

/// `$pos = [#x, #y, 0];` sets the literal with a `0` for each runtime part, then stores each part at its path.
pub fn compileLiteralAssign(compiler: *Compiler, target: ir.DataPath, expression: *const ast.Expression, env: *Environment, commands: *std.ArrayList(ir.Command)) Compiler.Error!void {
    var parts: std.ArrayList(LiteralPart) = .empty;
    const template = try literalTemplate(compiler, expression, "", env, &parts);

    try commands.append(compiler.arena, .{ .data_set = .{ .target = target, .snbt = try values.valueToSnbt(compiler, template) } });
    for (parts.items) |part| {
        const part_target = target.withPath(try std.mem.concat(compiler.arena, u8, &.{ target.path, part.path }));
        try compileDataAssign(compiler, part_target, part.value, env, commands);
    }
}

/// The literal as a value, with `0` in the place of each runtime part.
fn literalTemplate(compiler: *Compiler, expression: *const ast.Expression, path: []const u8, env: *Environment, parts: *std.ArrayList(LiteralPart)) Compiler.Error!Compiler.Value {
    if (!values.containsRuntimeValue(expression)) return try values.evaluate(compiler, expression, env);

    switch (expression.kind) {
        .list => |elements| {
            const template = try compiler.arena.alloc(Compiler.Value, elements.len);
            for (elements, template, 0..) |element, *value, index| {
                const element_path = try std.fmt.allocPrint(compiler.arena, "{s}[{d}]", .{ path, index });
                value.* = try literalTemplate(compiler, element, element_path, env, parts);
            }
            return .{ .list = template };
        },
        .compound => |entries| {
            const template = try compiler.arena.alloc(Compiler.Value.Entry, entries.len);
            for (entries, template) |entry, *value| {
                const entry_path = try std.fmt.allocPrint(compiler.arena, "{s}.{s}", .{ path, try values.snbtKey(compiler, entry.key) });
                const entry_value = try literalTemplate(compiler, entry.value, entry_path, env, parts);
                value.* = .{ .key = entry.key, .value = entry_value };
            }
            return .{ .compound = template };
        },
        else => {
            try parts.append(compiler.arena, .{ .path = path, .value = expression });
            return .{ .number = 0 };
        },
    }
}

pub fn isDataIdentifier(expression: *const ast.Expression) bool {
    return expression.kind == .identifier and (expression.kind.identifier.kind == .data or expression.kind.identifier.kind == .entity_data);
}

/// A `$` variable in `<ns>:data`, or the NBT path of one entity.
pub fn dataPathOf(compiler: *Compiler, identifier: ast.Identifier, env: *const Environment) Compiler.Error!ir.DataPath {
    if (identifier.kind == .entity_data) return entityDataPath(compiler, identifier);
    return dataPath(compiler, identifier, env);
}

pub fn entityDataPath(compiler: *Compiler, identifier: ast.Identifier) Compiler.Error!ir.DataPath {
    try scores.checkSingleEntity(compiler, identifier);
    return .ofEntity(identifier.selector.?, identifier.name);
}

/// Checks that the root of a `$` path is declared, and gives the path in `<ns>:data`.
pub fn dataPath(compiler: *Compiler, identifier: ast.Identifier, env: *const Environment) Compiler.Error!ir.DataPath {
    const name = identifier.name;
    const root = Compiler.pathRoot(name);
    if (identifier.namespace == null) {
        if (env.getLocal(.data, root)) |local| return dataLocal(compiler, try std.mem.concat(compiler.arena, u8, &.{ local.generated_name, name[root.len..] }));
    }
    const namespace = try declarations.resolveNamespace(compiler, identifier.namespace);
    const global = compiler.data_globals.get(try declarations.qualifiedKey(compiler, namespace, root)) orelse {
        return compiler.fail("unknown data '${s}'", .{root});
    };
    var path: ir.DataPath = .inStorage(global.storage, name);
    path.namespace = global.output_namespace;
    return path;
}

/// A data local in `<ns>:data` of the mcfun's namespace, or in `<pack>:std` for std.
pub fn dataLocal(compiler: *const Compiler, key_name: []const u8) ir.DataPath {
    var path: ir.DataPath = .inStorage(storageOf(compiler.scope.namespace), key_name);
    path.namespace = compiler.scope.output_namespace;
    return path;
}

/// std shares the pack namespace, so its `$` variables have their own storage, apart from the pack's.
pub fn storageOf(namespace: []const u8) ir.Storage {
    return if (std.mem.eql(u8, namespace, Compiler.std_namespace)) .std else .data;
}

/// `text(#hp)` → `{score:{name:"#global",objective:"<ns>.hp"}}`, `text($x)` → `{storage:"<ns>:data",nbt:"x"}`,
/// `text(@s.$Name)` → `{entity:"@s",nbt:"Name"}`. A compile-time value becomes a string.
pub fn textComponent(compiler: *Compiler, argument: *const ast.Expression, env: *Environment) Compiler.Error!Compiler.Value {
    if (argument.kind == .identifier) {
        const identifier = argument.kind.identifier;
        switch (identifier.kind) {
            .score => {
                const score = try scores.resolveScore(compiler, identifier, env);
                const objective = try std.fmt.allocPrint(compiler.arena, "{f}", .{datapack_writer.objectiveText(score.namespace orelse compiler.pack_namespace, score.objective)});
                const holder: Compiler.Value = .{ .compound = try compiler.arena.dupe(Compiler.Value.Entry, &.{ .{ .key = "name", .value = .{ .string = score.holder } }, .{ .key = "objective", .value = .{ .string = objective } } }) };
                return .{ .compound = try compiler.arena.dupe(Compiler.Value.Entry, &.{.{ .key = "score", .value = holder }}) };
            },
            .data => {
                const path = try dataPath(compiler, identifier, env);
                const storage = try std.fmt.allocPrint(compiler.arena, "{s}:{s}", .{ path.namespace orelse compiler.pack_namespace, path.holder.storage.variablesName() });
                return .{ .compound = try compiler.arena.dupe(Compiler.Value.Entry, &.{ .{ .key = "storage", .value = .{ .string = storage } }, .{ .key = "nbt", .value = .{ .string = path.path } } }) };
            },
            .entity_data => return .{ .compound = try compiler.arena.dupe(Compiler.Value.Entry, &.{ .{ .key = "entity", .value = .{ .string = identifier.selector.? } }, .{ .key = "nbt", .value = .{ .string = identifier.name } } }) },
            .compile_time => {},
        }
    }
    const value = try values.evaluate(compiler, argument, env);
    return .{ .string = try values.valueToText(compiler, value) };
}

/// `append($list, v)`, `prepend($list, v)`, `insert($list, i, v)` and `remove($list, i)`.
pub fn compileListBuiltin(compiler: *Compiler, name: []const u8, call: ast.Call, env: *Environment, commands: *std.ArrayList(ir.Command)) Compiler.Error!void {
    if (std.mem.eql(u8, name, "len")) return compiler.fail("'len' gives a value. Use it as one: '#n = len($list);'", .{});
    const arity: usize = if (std.mem.eql(u8, name, "insert")) 3 else 2;
    if (call.args.len != arity) return compiler.fail("'{s}' expects {d} arguments, found {d}", .{ name, arity, call.args.len });

    const list = try listArgument(compiler, name, call.args[0], env);

    const has_index = std.mem.eql(u8, name, "insert") or std.mem.eql(u8, name, "remove");
    const index: i32 = if (has_index) blk: {
        const value = try values.evaluate(compiler, call.args[1], env);
        break :blk try scores.toScoreValue(compiler, value);
    } else 0;

    if (std.mem.eql(u8, name, "remove")) {
        return commands.append(compiler.arena, .{ .data_remove = list.withPath(try std.fmt.allocPrint(compiler.arena, "{s}[{d}]", .{ list.path, index })) });
    }

    const position: ir.DataAdd.Position = if (std.mem.eql(u8, name, "append")) .append else if (std.mem.eql(u8, name, "prepend")) .prepend else .{ .insert = index };
    const element_path = switch (position) {
        .append => "[-1]",
        .prepend => "[0]",
        .insert => try std.fmt.allocPrint(compiler.arena, "[{d}]", .{index}),
    };
    const value = call.args[arity - 1];

    if (!values.containsRuntimeValue(value)) {
        const constant = try values.evaluate(compiler, value, env);
        const snbt = try values.valueToSnbt(compiler, constant);
        return commands.append(compiler.arena, .{ .data_add = .{ .list = list, .position = position, .source = .{ .snbt = snbt } } });
    }
    if (isDataIdentifier(value)) {
        const source = try dataPathOf(compiler, value.kind.identifier, env);
        return commands.append(compiler.arena, .{ .data_add = .{ .list = list, .position = position, .source = .{ .from = source } } });
    }

    // Add a `0`, then store the runtime value into it.
    try commands.append(compiler.arena, .{ .data_add = .{ .list = list, .position = position, .source = .{ .snbt = "0" } } });
    const element = list.withPath(try std.mem.concat(compiler.arena, u8, &.{ list.path, element_path }));
    try compileDataAssign(compiler, element, value, env, commands);
}

/// The first argument of a list helper: a `$` variable or entity data.
fn listArgument(compiler: *Compiler, name: []const u8, argument: *const ast.Expression, env: *const Environment) Compiler.Error!ir.DataPath {
    const outer_position = compiler.enterExpression(argument);
    defer compiler.restorePosition(outer_position);
    if (!isDataIdentifier(argument)) {
        return compiler.fail("the first argument of '{s}' must be a list: '$list' or '@s.$path'", .{name});
    }
    return dataPathOf(compiler, argument.kind.identifier, env);
}

/// `slice(text, start, end)` and `str(value)` give a string. `startsWith` and `endsWith` are conditions.
pub fn isStringCall(call: ast.Call) bool {
    return calls.isBuiltinCall(call, "slice") or calls.isBuiltinCall(call, "str");
}

pub fn isStringTest(call: ast.Call) bool {
    return calls.isBuiltinCall(call, "startsWith") or calls.isBuiltinCall(call, "endsWith");
}

/// The result of a nested string helper, and the substring that `startsWith` and `endsWith` compare.
pub const string_scratch: ir.DataPath = .inStorage(.poplar, "string");

pub const string_test_key = "string_test";

/// `data modify <target> set string <source> [start] [end]`. A score or math goes into the scratch value first,
/// because `set string` reads data: a number there becomes its text.
pub fn compileStringInto(compiler: *Compiler, target: ir.DataPath, call: ast.Call, env: *Environment, commands: *std.ArrayList(ir.Command)) Compiler.Error!void {
    const outer_position = compiler.enterExpression(call.callee);
    defer compiler.restorePosition(outer_position);
    if (calls.isBuiltinCall(call, "slice")) {
        if (call.args.len != 2 and call.args.len != 3) return compiler.fail("'slice' expects 2 or 3 arguments (text, start, end), found {d}", .{call.args.len});
        const start = try constantIndex(compiler, call.args[1], env);
        const end: ?i32 = if (call.args.len == 3) try constantIndex(compiler, call.args[2], env) else null;
        const source = try stringSource(compiler, call.args[0], env, commands);
        return commands.append(compiler.arena, .{ .data_set_string = .{ .target = target, .source = source, .start = start, .end = end } });
    }

    if (call.args.len != 1) return compiler.fail("'str' expects 1 argument, found {d}", .{call.args.len});
    const argument = call.args[0];
    if (argument.kind == .call and isStringCall(argument.kind.call)) return compileStringInto(compiler, target, argument.kind.call, env, commands);
    if (isDataIdentifier(argument)) {
        const source = try dataPathOf(compiler, argument.kind.identifier, env);
        return commands.append(compiler.arena, .{ .data_set_string = .{ .target = target, .source = source } });
    }
    const score = if (argument.kind == .identifier and argument.kind.identifier.kind == .score)
        try scores.scoreSource(compiler, argument.kind.identifier, env)
    else blk: {
        const temp = try scores.newTemp(compiler);
        try scores.compileInto(compiler, temp, argument, env, commands);
        break :blk temp;
    };
    try commands.append(compiler.arena, .{ .score_to_data = .{ .target = string_scratch, .score = score } });
    try commands.append(compiler.arena, .{ .data_set_string = .{ .target = target, .source = string_scratch } });
}

/// The data that a string helper reads: a `$` path, entity data, or another string helper (through the scratch value).
fn stringSource(compiler: *Compiler, argument: *const ast.Expression, env: *Environment, commands: *std.ArrayList(ir.Command)) Compiler.Error!ir.DataPath {
    if (isDataIdentifier(argument)) return try dataPathOf(compiler, argument.kind.identifier, env);
    if (argument.kind == .call and isStringCall(argument.kind.call)) {
        try compileStringInto(compiler, string_scratch, argument.kind.call, env, commands);
        return string_scratch;
    }
    return compiler.failOn(argument, "the text must be data ('$x' or '@s.$path') or another string helper. For a score, use 'str(#x)'", .{});
}

fn constantIndex(compiler: *Compiler, expression: *const ast.Expression, env: *Environment) Compiler.Error!i32 {
    if (values.containsRuntimeValue(expression)) {
        return compiler.failOn(expression, "the bounds of 'slice' must be constant integers", .{});
    }
    const value = try values.evaluate(compiler, expression, env);
    return scores.toScoreValue(compiler, value);
}

/// `startsWith(text, "minecraft:")`: the first characters go into the test value, which starts as "" so that a
/// text that is too short (the `set string` fails) does not match. Then one NBT filter compares them.
pub fn stringTest(compiler: *Compiler, call: ast.Call, env: *Environment, negated: bool, setup: *std.ArrayList(ir.Command)) Compiler.Error!Compiler.Condition {
    const name = call.callee.kind.identifier.name;
    if (call.args.len != 2) {
        return compiler.fail("'{s}' expects 2 arguments (text, {s}), found {d}", .{ name, if (calls.isBuiltinCall(call, "startsWith")) "prefix" else "suffix", call.args.len });
    }
    const affix = try constantString(compiler, call.args[1], env, name);
    const length: i32 = @intCast(std.unicode.calcUtf16LeLen(affix) catch affix.len);
    if (length == 0) return .{ .constant = !negated };

    const source = try stringSource(compiler, call.args[0], env, setup);
    const test_value: ir.DataPath = .inStorage(.poplar, string_test_key);
    try setup.append(compiler.arena, .{ .data_set = .{ .target = test_value, .snbt = "\"\"" } });
    const is_start = calls.isBuiltinCall(call, "startsWith");
    try setup.append(compiler.arena, .{ .data_set_string = .{ .target = test_value, .source = source, .start = if (is_start) 0 else -length, .end = if (is_start) length else null } });
    const filter = try std.fmt.allocPrint(compiler.arena, "{{{s}:{s}}}", .{ string_test_key, try values.valueToSnbt(compiler, .{ .string = affix }) });
    return try conditions.singleCheck(compiler, .{ .negated = negated, .condition = .{ .data_test = .{ .holder = .{ .storage = .poplar }, .path = filter } } });
}

fn constantString(compiler: *Compiler, expression: *const ast.Expression, env: *Environment, builtin: []const u8) Compiler.Error![]const u8 {
    const outer_position = compiler.enterExpression(expression);
    defer compiler.restorePosition(outer_position);
    if (!values.containsRuntimeValue(expression)) {
        const value = try values.evaluate(compiler, expression, env);
        if (value == .string) return value.string;
    }
    return compiler.fail("the second argument of '{s}' must be a constant string", .{builtin});
}

/// The string helpers on constants run when the pack is built. Indices count UTF-16 units, the same as the game.
pub fn evaluateStringCall(compiler: *Compiler, call: ast.Call, env: *Environment) Compiler.Error!Compiler.Value {
    const name = call.callee.kind.identifier.name;
    const arity_ok = if (calls.isBuiltinCall(call, "slice")) call.args.len == 2 or call.args.len == 3 else if (calls.isBuiltinCall(call, "str")) call.args.len == 1 else call.args.len == 2;
    if (!arity_ok) {
        return compiler.fail("'{s}' has the wrong number of arguments", .{name});
    }
    const first = try values.evaluate(compiler, call.args[0], env);
    const text = switch (first) {
        .string => |text| text,
        .number => |number| try std.fmt.allocPrint(compiler.arena, "{d}", .{number}),
        .typed_number => |number| number.text,
        else => {
            return compiler.fail("'{s}' needs a string or a number, found {s}", .{ name, @tagName(first) });
        },
    };
    if (calls.isBuiltinCall(call, "str")) return .{ .string = text };
    if (isStringTest(call)) {
        const affix = try constantString(compiler, call.args[1], env, name);
        const matches = if (calls.isBuiltinCall(call, "startsWith")) std.mem.startsWith(u8, text, affix) else std.mem.endsWith(u8, text, affix);
        return .{ .boolean = matches };
    }

    const units = std.unicode.utf8ToUtf16LeAlloc(compiler.arena, text) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidUtf8 => {
            return compiler.fail("'slice' needs valid UTF-8 text", .{});
        },
    };
    const length: i64 = @intCast(units.len);
    const start = try constantIndex(compiler, call.args[1], env);
    const end: i64 = if (call.args.len == 3) try constantIndex(compiler, call.args[2], env) else length;
    const from: i64 = if (start < 0) length + start else start;
    const to: i64 = if (end < 0) length + end else end;
    if (from < 0 or to > length or from > to) {
        return compiler.fail("'slice' bounds {d}..{d} are out of range for a text of length {d}", .{ start, end, length });
    }
    const sliced = std.unicode.utf16LeToUtf8Alloc(compiler.arena, units[@intCast(from)..@intCast(to)]) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            return compiler.fail("'slice' cuts a character in two", .{});
        },
    };
    return .{ .string = sliced };
}

/// `len($list)`: `data get` on a list, compound or string gives its size.
pub fn compileLength(compiler: *Compiler, target: ir.Score, call: ast.Call, env: *const Environment, commands: *std.ArrayList(ir.Command)) Compiler.Error!void {
    if (call.args.len != 1) return compiler.fail("'len' expects 1 argument, found {d}", .{call.args.len});
    const argument = call.args[0];
    if (!isDataIdentifier(argument)) return compiler.fail("'len' needs a list, a compound or a string in data", .{});
    const source = try dataPathOf(compiler, argument.kind.identifier, env);
    try commands.append(compiler.arena, .{ .data_to_score = .{ .source = source, .score = target } });
}

test "data variables use storage and macros" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    var compiler = try Compiler.compileForTest(arena.allocator(),
        \\var $item = "diamond";
        \\var $count = 3;
        \\var #kills = 0;
        \\mcfun main() {
        \\    $count = #kills;
        \\    /give @p {{$item}} {{$count}};
        \\}
    );
    const program = try compiler.compile();
    try std.testing.expectEqual(0, compiler.errors.items.len);

    try std.testing.expectEqualStrings(
        \\execute store result storage ns:data count int 1 run scoreboard players get #global ns.kills
        \\function ns:poplar/main/macro_0 with storage ns:data
        \\
    , try Compiler.renderForTest(arena.allocator(), program, "main"));
    try std.testing.expectEqualStrings("$give @p $(item) $(count)\n", try Compiler.renderForTest(arena.allocator(), program, "poplar/main/macro_0"));
    try std.testing.expectEqualStrings(
        \\scoreboard objectives add poplar.ns dummy
        \\scoreboard objectives add ns.kills dummy
        \\execute unless score #global ns.kills matches -2147483648.. run scoreboard players set #global ns.kills 0
        \\execute unless data storage ns:data item run data modify storage ns:data item set value "diamond"
        \\execute unless data storage ns:data count run data modify storage ns:data count set value 3
        \\
    , try datapack_writer.renderFunction(arena.allocator(), "ns", program.load.?));
}

test "reads and writes entity data" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    var compiler = try Compiler.compileForTest(arena.allocator(),
        \\var #hp = 0;
        \\var $pos = 0;
        \\mcfun main() {
        \\    #hp = @s.$Health * 10;
        \\    @s.$Health = #hp;
        \\    @s.$data.x = #hp + 1;
        \\    $pos = @s.$Pos;
        \\    @s.$Glowing = 1b;
        \\}
    );
    const program = try compiler.compile();
    try std.testing.expectEqual(0, compiler.errors.items.len);

    try std.testing.expectEqualStrings(
        \\execute store result score #global ns.hp run data get entity @s Health 10
        \\execute store result entity @s Health int 1 run scoreboard players get #global ns.hp
        \\scoreboard players operation #poplar.main.t0 poplar.ns = #global ns.hp
        \\execute store result entity @s data.x int 1 run scoreboard players add #poplar.main.t0 poplar.ns 1
        \\data modify storage ns:data pos set from entity @s Pos
        \\data modify entity @s Glowing set value 1b
        \\
    , try Compiler.renderForTest(arena.allocator(), program, "main"));
}

test "SNBT numbers are written as they are, and scores reject them" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    var compiler = try Compiler.compileForTest(arena.allocator(),
        \\var $small = 0.05f;
        \\var $item = {myNum: 0.05f, count: 1b, list: [5s, 5L, 0.5]};
        \\var #hp = 0;
        \\mcfun main() {
        \\    $small = -0.5d;
        \\    if ($small == 0.05f) { /say same; }
        \\    if ($small == -0.5d) { /say negative; }
        \\    #hp = 0.05;
        \\    #hp = 5b;
        \\    if (#hp > 0.5f) { /say big; }
        \\    $small = 0.5 + 1;
        \\}
    );
    const program = try compiler.compile();
    const errors = compiler.errors.items;
    try std.testing.expectEqual(4, errors.len);
    try std.testing.expectEqualStrings("a score holds whole numbers, so it cannot hold '0.05'", errors[0].message);
    try std.testing.expectEqualStrings("a score has no number types: write '5' with no suffix", errors[1].message);
    try std.testing.expectEqualStrings("a score holds whole numbers with no suffix, so it cannot be compared with '0.5'", errors[2].message);
    try std.testing.expectEqualStrings("build-time math only works on whole numbers with no suffix, so '+' cannot be used here", errors[3].message);

    const load = try datapack_writer.renderFunction(arena.allocator(), "ns", program.load.?);
    try std.testing.expect(std.mem.indexOf(u8, load, "small set value 0.05f") != null);
    try std.testing.expect(std.mem.indexOf(u8, load, "item set value {myNum:0.05f,count:1b,list:[5s,5L,0.5]}") != null);
    const main = try Compiler.renderForTest(arena.allocator(), program, "main");
    try std.testing.expect(std.mem.indexOf(u8, main, "data modify storage ns:data small set value -0.5d\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, main, "{small:0.05f}") != null);
    try std.testing.expect(std.mem.indexOf(u8, main, "{small:-0.5d}") != null);
}

test "a score or math is stored as an int, and a macro argument as its own text" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    var compiler = try Compiler.compileForTest(arena.allocator(),
        \\var #a = 3;
        \\var $ratio = 0f;
        \\var $speeds = [1, 2];
        \\mcfun heal() { /say $(label) $(amount); }
        \\mcfun main() {
        \\    $ratio = #a * 2;
        \\    $speeds = #a;
        \\    heal() with {amount: #a, label: "hi"};
        \\}
        \\mcfun setSpeed() {
        \\    $ratio = $(speed);
        \\    @s.$Health = $(speed);
        \\    $speeds = {first: $(speed)};
        \\}
    );
    const program = try compiler.compile();
    try std.testing.expectEqual(0, compiler.errors.items.len);

    try std.testing.expectEqualStrings(
        \\scoreboard players operation #poplar.main.t0 poplar.ns = #global ns.a
        \\execute store result storage ns:data ratio int 1 run scoreboard players operation #poplar.main.t0 poplar.ns *= #poplar.c2 poplar.ns
        \\execute store result storage ns:data speeds int 1 run scoreboard players get #global ns.a
        \\execute store result storage ns:poplar args.amount int 1 run scoreboard players get #global ns.a
        \\data modify storage ns:poplar args.label set value "hi"
        \\function ns:heal with storage ns:poplar args
        \\
    , try Compiler.renderForTest(arena.allocator(), program, "main"));
    try std.testing.expectEqualStrings(
        \\$data modify storage ns:data ratio set value $(speed)
        \\$data modify entity @s Health set value $(speed)
        \\data modify storage ns:data speeds set value {first:0}
        \\$data modify storage ns:data speeds.first set value $(speed)
        \\
    , try Compiler.renderForTest(arena.allocator(), program, "setSpeed"));
    const load = try datapack_writer.renderFunction(arena.allocator(), "ns", program.load.?);
    try std.testing.expect(std.mem.indexOf(u8, load, "ratio set value 0f") != null);
    try std.testing.expect(std.mem.indexOf(u8, load, "speeds set value [1,2]") != null);
}

test "paths, literals with runtime parts, list helpers and data conditions" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    var compiler = try Compiler.compileForTest(arena.allocator(),
        \\var #x = 3;
        \\var $stats = {hp: 20, name: "x"};
        \\var $pos = [0, 0];
        \\var $names = [];
        \\var $flag = true;
        \\mcfun main() {
        \\    $stats.hp = #x;
        \\    $pos = [#x, 1];
        \\    append($names, "Steve");
        \\    append($names, #x);
        \\    #x = len($names);
        \\    if ($stats.name == "x" and $flag == true) { /say ok; }
        \\    if ($stats.bonus) { /say bonus; }
        \\    if (!@s.$SelectedItem.components.enchantments) { /say plain; }
        \\}
    );
    const program = try compiler.compile();
    try std.testing.expectEqual(0, compiler.errors.items.len);

    try std.testing.expectEqualStrings(
        \\execute store result storage ns:data stats.hp int 1 run scoreboard players get #global ns.x
        \\data modify storage ns:data pos set value [0,1]
        \\execute store result storage ns:data pos[0] int 1 run scoreboard players get #global ns.x
        \\data modify storage ns:data names append value "Steve"
        \\data modify storage ns:data names append value 0
        \\execute store result storage ns:data names[-1] int 1 run scoreboard players get #global ns.x
        \\execute store result score #global ns.x run data get storage ns:data names
        \\execute if data storage ns:data {stats:{name:"x"}} if data storage ns:data {flag:1b} run say ok
        \\execute if data storage ns:data stats.bonus run say bonus
        \\execute unless data entity @s SelectedItem.components.enchantments run say plain
        \\
    , try Compiler.renderForTest(arena.allocator(), program, "main"));
}

test "string helpers use set string, and run in the compiler on constants" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    var compiler = try Compiler.compileForTest(arena.allocator(),
        \\var $id = "minecraft:diamond";
        \\var #n = 42;
        \\mcfun main() {
        \\    $id = slice(@s.$SelectedItem.id, 10, -2);
        \\    $id = str(#n);
        \\    /say {{slice("minecraft:stone", 10)}};
        \\    if (endsWith($id, "_sword")) { /say sword; }
        \\    #n = slice($id, 1);
        \\}
    );
    const program = try compiler.compile();
    try std.testing.expectEqual(1, compiler.errors.items.len);
    try std.testing.expectEqualStrings("'slice' gives a string, so it cannot be a score. Store it in data: '$x = slice(...);'", compiler.errors.items[0].message);

    try std.testing.expectEqualStrings(
        \\data modify storage ns:data id set string entity @s SelectedItem.id 10 -2
        \\execute store result storage ns:poplar string int 1 run scoreboard players get #global ns.n
        \\data modify storage ns:data id set string storage ns:poplar string
        \\say stone
        \\data modify storage ns:poplar string_test set value ""
        \\data modify storage ns:poplar string_test set string storage ns:data id -6
        \\execute if data storage ns:poplar {string_test:"_sword"} run say sword
        \\
    , try Compiler.renderForTest(arena.allocator(), program, "main"));
}
