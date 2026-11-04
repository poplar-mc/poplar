// NBT data: assigning, paths and literals, list builtins, and the string helpers.
const std = @import("std");
const Compiler = @import("../Compiler.zig");
const Ast = @import("../Ast.zig");
const Environment = @import("../Environment.zig");
const Ir = @import("../Ir.zig");
const Writer = @import("../Writer.zig");
const Calls = @import("Calls.zig");
const Conditions = @import("Conditions.zig");
const Declarations = @import("Declarations.zig");
const Scores = @import("Scores.zig");
const Values = @import("Values.zig");

// Sets data in storage or an entity path. A score or math is stored as an int.
pub fn compileDataAssign(self: *Compiler, target: Ir.DataPath, expression: *const Ast.Expr, env: *Environment, commands: *std.ArrayList(Ir.Command)) Compiler.CompileError!void {
    const outer_position = self.enterExpression(expression);
    defer self.restorePosition(outer_position);

    if (!Values.containsRuntimeValue(self, expression, env)) {
        const value = try Values.evaluate(self, expression, env) orelse return;
        if (value == .null) return self.addError("data cannot be set to null", .{});
        return commands.append(self.gpa, .{ .data_set = .{ .target = target, .snbt = try Values.valueToSnbt(self, value) } });
    }

    if (expression.kind == .call and isStringCall(expression.kind.call)) return compileStringInto(self, target, expression.kind.call, env, commands);
    if (expression.kind == .list or expression.kind == .compound) return compileLiteralAssign(self, target, expression, env, commands);

    // A macro argument is text in the command, so Minecraft reads its type, as in a hand-written datapack.
    if (expression.kind == .macro_key) {
        return commands.append(self.gpa, .{ .data_set = .{ .target = target, .snbt = try std.fmt.allocPrint(self.gpa, "$({s})", .{expression.kind.macro_key}) } });
    }

    if (expression.kind == .identifier) {
        const identifier = expression.kind.identifier;
        switch (identifier.storage) {
            .score => {
                const score = try Scores.scoreSource(self, identifier, env) orelse return;
                return commands.append(self.gpa, .{ .score_to_data = .{ .target = target, .score = score } });
            },
            .data, .entity_data => {
                const source = try dataPathOf(self, identifier, env) orelse return;
                if (std.meta.eql(source.holder, target.holder) and std.mem.eql(u8, source.path, target.path)) return;
                return commands.append(self.gpa, .{ .data_copy = .{ .target = target, .source = source } });
            },
            .compile_time => {},
        }
    }

    self.temp_count = 0;
    const temp = try Scores.newTemp(self);
    try Scores.compileInto(self, temp, expression, env, commands);
    try commands.append(self.gpa, .{ .score_to_data = .{ .target = target, .score = temp } });
}

// A runtime value inside a literal, and where it goes: `[1]` in `pos[1]`, `.hp` in `stats.hp`.
pub const LiteralPart = struct {
    path: []const u8,
    value: *const Ast.Expr,
};

// `$pos = [#x, #y, 0];` sets the literal with a `0` for each runtime part, then stores each part at its path.
pub fn compileLiteralAssign(self: *Compiler, target: Ir.DataPath, expression: *const Ast.Expr, env: *Environment, commands: *std.ArrayList(Ir.Command)) Compiler.CompileError!void {
    var parts: std.ArrayList(LiteralPart) = .empty;
    const template = try literalTemplate(self, expression, "", env, &parts) orelse return;

    try commands.append(self.gpa, .{ .data_set = .{ .target = target, .snbt = try Values.valueToSnbt(self, template) } });
    for (parts.items) |part| {
        const part_target = target.withPath(try std.mem.concat(self.gpa, u8, &.{ target.path, part.path }));
        try compileDataAssign(self, part_target, part.value, env, commands);
    }
}

// The literal as a value, with `0` in the place of each runtime part.
pub fn literalTemplate(self: *Compiler, expression: *const Ast.Expr, path: []const u8, env: *Environment, parts: *std.ArrayList(LiteralPart)) Compiler.CompileError!?Compiler.Value {
    if (!Values.containsRuntimeValue(self, expression, env)) return try Values.evaluate(self, expression, env);

    switch (expression.kind) {
        .list => |elements| {
            const values = try self.gpa.alloc(Compiler.Value, elements.len);
            for (elements, values, 0..) |element, *value, index| {
                const element_path = try std.fmt.allocPrint(self.gpa, "{s}[{d}]", .{ path, index });
                value.* = try literalTemplate(self, element, element_path, env, parts) orelse return null;
            }
            return .{ .list = values };
        },
        .compound => |entries| {
            const values = try self.gpa.alloc(Compiler.Value.Entry, entries.len);
            for (entries, values) |entry, *value| {
                const entry_path = try std.fmt.allocPrint(self.gpa, "{s}.{s}", .{ path, try Values.snbtKey(self, entry.key) });
                const entry_value = try literalTemplate(self, entry.value, entry_path, env, parts) orelse return null;
                value.* = .{ .key = entry.key, .value = entry_value };
            }
            return .{ .compound = values };
        },
        else => {
            try parts.append(self.gpa, .{ .path = path, .value = expression });
            return .{ .number = 0 };
        },
    }
}

pub fn isDataIdentifier(expression: *const Ast.Expr) bool {
    return expression.kind == .identifier and (expression.kind.identifier.storage == .data or expression.kind.identifier.storage == .entity_data);
}

// A `#` variable in `<ns>:data`, or the NBT path of one entity.
pub fn dataPathOf(self: *Compiler, identifier: Ast.Identifier, env: *const Environment) Compiler.CompileError!?Ir.DataPath {
    if (identifier.storage == .entity_data) return entityDataPath(self, identifier);
    return dataPath(self, identifier, env);
}

pub fn entityDataPath(self: *Compiler, identifier: Ast.Identifier) Compiler.CompileError!?Ir.DataPath {
    if (!try Scores.checkSingleEntity(self, identifier)) return null;
    return .ofEntity(identifier.selector.?, identifier.name);
}

// Checks that the root of a `$` path is declared, and gives the path in `<ns>:data`.
pub fn dataPath(self: *Compiler, identifier: Ast.Identifier, env: *const Environment) Compiler.CompileError!?Ir.DataPath {
    const name = identifier.name;
    const root = Compiler.pathRoot(name);
    if (identifier.namespace == null) {
        if (Compiler.localOf(env, '$', root)) |local| return dataLocal(self, try std.mem.concat(self.gpa, u8, &.{ local.generated_name, name[root.len..] }));
    }
    const namespace = try Declarations.resolveNamespace(self, identifier.namespace) orelse return null;
    const global = self.data_globals.get(try Declarations.qualifiedKey(self, namespace, root)) orelse {
        try self.addError("unknown data '${s}'", .{root});
        return null;
    };
    var path: Ir.DataPath = .inStorage(global.storage, name);
    path.namespace = global.output_namespace;
    return path;
}

// A data local in `<ns>:data` of the mcfun's namespace, or in `<pack>:std` for std.
pub fn dataLocal(self: *const Compiler, key_name: []const u8) Ir.DataPath {
    var path: Ir.DataPath = .inStorage(storageOf(self.scope.namespace), key_name);
    path.namespace = self.scope.output_namespace;
    return path;
}

// std shares the pack namespace, so its `$` variables have their own storage, apart from the pack's.
pub fn storageOf(namespace: []const u8) Ir.Storage {
    return if (std.mem.eql(u8, namespace, Compiler.std_namespace)) .std else .data;
}

// `text(#hp)` → `{score:{name:"#global",objective:"<ns>.hp"}}`, `text($x)` → `{storage:"<ns>:data",nbt:"x"}`,
// `text(@s.$Name)` → `{entity:"@s",nbt:"Name"}`. A compile-time value becomes a string.
pub fn textComponent(self: *Compiler, argument: *const Ast.Expr, env: *Environment) Compiler.CompileError!?Compiler.Value {
    if (argument.kind == .identifier) {
        const identifier = argument.kind.identifier;
        switch (identifier.storage) {
            .score => {
                const score = try Scores.resolveScore(self, identifier, env) orelse return null;
                // A local score is in Poplar's objective `poplar.<ns>`, a global one in `<ns>.<name>`.
                const score_namespace = score.namespace orelse self.namespace;
                const objective = if (score.objective) |name| try std.fmt.allocPrint(self.gpa, "{s}.{s}", .{ score_namespace, name }) else try std.fmt.allocPrint(self.gpa, "poplar.{s}", .{score_namespace});
                const holder: Compiler.Value = .{ .compound = try self.gpa.dupe(Compiler.Value.Entry, &.{ .{ .key = "name", .value = .{ .string = score.holder } }, .{ .key = "objective", .value = .{ .string = objective } } }) };
                return .{ .compound = try self.gpa.dupe(Compiler.Value.Entry, &.{.{ .key = "score", .value = holder }}) };
            },
            .data => {
                const path = try dataPath(self, identifier, env) orelse return null;
                const storage = try std.fmt.allocPrint(self.gpa, "{s}:{s}", .{ path.namespace orelse self.namespace, if (path.holder.storage == .std) "std" else "data" });
                return .{ .compound = try self.gpa.dupe(Compiler.Value.Entry, &.{ .{ .key = "storage", .value = .{ .string = storage } }, .{ .key = "nbt", .value = .{ .string = path.path } } }) };
            },
            .entity_data => return .{ .compound = try self.gpa.dupe(Compiler.Value.Entry, &.{ .{ .key = "entity", .value = .{ .string = identifier.selector.? } }, .{ .key = "nbt", .value = .{ .string = identifier.name } } }) },
            .compile_time => {},
        }
    }
    const value = try Values.evaluate(self, argument, env) orelse return null;
    return .{ .string = try Values.valueToText(self, value) };
}

// `append($list, v)`, `prepend($list, v)`, `insert($list, i, v)` and `remove($list, i)`.
pub fn compileListBuiltin(self: *Compiler, name: []const u8, call: Ast.Call, env: *Environment, commands: *std.ArrayList(Ir.Command)) Compiler.CompileError!void {
    if (std.mem.eql(u8, name, "len")) return self.addError("'len' gives a value. Use it as one: '#n = len($list);'", .{});
    const arity: usize = if (std.mem.eql(u8, name, "insert")) 3 else 2;
    if (call.args.len != arity) return self.addError("'{s}' expects {d} arguments, found {d}", .{ name, arity, call.args.len });

    const list = try listArgument(self, name, call.args[0], env) orelse return;

    const has_index = std.mem.eql(u8, name, "insert") or std.mem.eql(u8, name, "remove");
    const index: i32 = if (has_index) blk: {
        const value = try Values.evaluate(self, call.args[1], env) orelse return;
        break :blk try Scores.toScoreValue(self, value) orelse return;
    } else 0;

    if (std.mem.eql(u8, name, "remove")) {
        return commands.append(self.gpa, .{ .data_remove = list.withPath(try std.fmt.allocPrint(self.gpa, "{s}[{d}]", .{ list.path, index })) });
    }

    const position: Ir.DataAdd.Position = if (std.mem.eql(u8, name, "append")) .append else if (std.mem.eql(u8, name, "prepend")) .prepend else .{ .insert = index };
    const element_path = switch (position) {
        .append => "[-1]",
        .prepend => "[0]",
        .insert => try std.fmt.allocPrint(self.gpa, "[{d}]", .{index}),
    };
    const value = call.args[arity - 1];

    if (!Values.containsRuntimeValue(self, value, env)) {
        const constant = try Values.evaluate(self, value, env) orelse return;
        const snbt = try Values.valueToSnbt(self, constant);
        return commands.append(self.gpa, .{ .data_add = .{ .list = list, .position = position, .source = .{ .snbt = snbt } } });
    }
    if (isDataIdentifier(value)) {
        const source = try dataPathOf(self, value.kind.identifier, env) orelse return;
        return commands.append(self.gpa, .{ .data_add = .{ .list = list, .position = position, .source = .{ .from = source } } });
    }

    // Add a `0`, then store the runtime value into it.
    try commands.append(self.gpa, .{ .data_add = .{ .list = list, .position = position, .source = .{ .snbt = "0" } } });
    const element = list.withPath(try std.mem.concat(self.gpa, u8, &.{ list.path, element_path }));
    try compileDataAssign(self, element, value, env, commands);
}

// The first argument of a list helper: a `$` variable or entity data.
pub fn listArgument(self: *Compiler, name: []const u8, argument: *const Ast.Expr, env: *const Environment) Compiler.CompileError!?Ir.DataPath {
    const outer_position = self.enterExpression(argument);
    defer self.restorePosition(outer_position);
    if (!isDataIdentifier(argument)) {
        try self.addError("the first argument of '{s}' must be a list: '$list' or '@s.$path'", .{name});
        return null;
    }
    return dataPathOf(self, argument.kind.identifier, env);
}

// `slice(text, start, end)` and `str(value)` give a string. `startsWith` and `endsWith` are conditions.
pub fn isStringCall(call: Ast.Call) bool {
    return Calls.isBuiltinCall(call, "slice") or Calls.isBuiltinCall(call, "str");
}

pub fn isStringTest(call: Ast.Call) bool {
    return Calls.isBuiltinCall(call, "startsWith") or Calls.isBuiltinCall(call, "endsWith");
}

// The result of a nested string helper, and the substring that `startsWith` and `endsWith` compare.
pub const string_scratch: Ir.DataPath = .inStorage(.poplar, "string");

pub const string_test_key = "string_test";

// `data modify <target> set string <source> [start] [end]`. A score or math goes into the scratch value first,
// because `set string` reads data: a number there becomes its text.
pub fn compileStringInto(self: *Compiler, target: Ir.DataPath, call: Ast.Call, env: *Environment, commands: *std.ArrayList(Ir.Command)) Compiler.CompileError!void {
    const outer_position = self.enterExpression(call.callee);
    defer self.restorePosition(outer_position);
    if (Calls.isBuiltinCall(call, "slice")) {
        if (call.args.len != 2 and call.args.len != 3) return self.addError("'slice' expects 2 or 3 arguments (text, start, end), found {d}", .{call.args.len});
        const start = try constantIndex(self, call.args[1], env) orelse return;
        const end: ?i32 = if (call.args.len == 3) try constantIndex(self, call.args[2], env) orelse return else null;
        const source = try stringSource(self, call.args[0], env, commands) orelse return;
        return commands.append(self.gpa, .{ .data_set_string = .{ .target = target, .source = source, .start = start, .end = end } });
    }

    if (call.args.len != 1) return self.addError("'str' expects 1 argument, found {d}", .{call.args.len});
    const argument = call.args[0];
    if (argument.kind == .call and isStringCall(argument.kind.call)) return compileStringInto(self, target, argument.kind.call, env, commands);
    if (isDataIdentifier(argument)) {
        const source = try dataPathOf(self, argument.kind.identifier, env) orelse return;
        return commands.append(self.gpa, .{ .data_set_string = .{ .target = target, .source = source } });
    }
    const score = if (argument.kind == .identifier and argument.kind.identifier.storage == .score)
        try Scores.scoreSource(self, argument.kind.identifier, env) orelse return
    else blk: {
        const temp = try Scores.newTemp(self);
        try Scores.compileInto(self, temp, argument, env, commands);
        break :blk temp;
    };
    try commands.append(self.gpa, .{ .score_to_data = .{ .target = string_scratch, .score = score } });
    try commands.append(self.gpa, .{ .data_set_string = .{ .target = target, .source = string_scratch } });
}

// The data that a string helper reads: a `$` path, entity data, or another string helper (through the scratch value).
pub fn stringSource(self: *Compiler, argument: *const Ast.Expr, env: *Environment, commands: *std.ArrayList(Ir.Command)) Compiler.CompileError!?Ir.DataPath {
    if (isDataIdentifier(argument)) return try dataPathOf(self, argument.kind.identifier, env);
    if (argument.kind == .call and isStringCall(argument.kind.call)) {
        try compileStringInto(self, string_scratch, argument.kind.call, env, commands);
        return string_scratch;
    }
    const outer_position = self.enterExpression(argument);
    defer self.restorePosition(outer_position);
    try self.addError("the text must be data ('$x' or '@s.$path') or another string helper. For a score, use 'str(#x)'", .{});
    return null;
}

pub fn constantIndex(self: *Compiler, expression: *const Ast.Expr, env: *Environment) Compiler.CompileError!?i32 {
    if (Values.containsRuntimeValue(self, expression, env)) {
        const outer_position = self.enterExpression(expression);
        defer self.restorePosition(outer_position);
        try self.addError("the bounds of 'slice' must be constant integers", .{});
        return null;
    }
    const value = try Values.evaluate(self, expression, env) orelse return null;
    return Scores.toScoreValue(self, value);
}

// `startsWith(text, "minecraft:")`: the first characters go into the test value, which starts as "" so that a
// text that is too short (the `set string` fails) does not match. Then one NBT filter compares them.
pub fn stringTest(self: *Compiler, call: Ast.Call, env: *Environment, negated: bool, setup: *std.ArrayList(Ir.Command)) Compiler.CompileError!?Compiler.Condition {
    const name = call.callee.kind.identifier.name;
    if (call.args.len != 2) {
        try self.addError("'{s}' expects 2 arguments (text, {s}), found {d}", .{ name, if (Calls.isBuiltinCall(call, "startsWith")) "prefix" else "suffix", call.args.len });
        return null;
    }
    const affix = try constantString(self, call.args[1], env, name) orelse return null;
    const length: i32 = @intCast(std.unicode.calcUtf16LeLen(affix) catch affix.len);
    if (length == 0) return .{ .constant = !negated };

    const source = try stringSource(self, call.args[0], env, setup) orelse return null;
    const test_value: Ir.DataPath = .inStorage(.poplar, string_test_key);
    try setup.append(self.gpa, .{ .data_set = .{ .target = test_value, .snbt = "\"\"" } });
    const is_start = Calls.isBuiltinCall(call, "startsWith");
    try setup.append(self.gpa, .{ .data_set_string = .{ .target = test_value, .source = source, .start = if (is_start) 0 else -length, .end = if (is_start) length else null } });
    const filter = try std.fmt.allocPrint(self.gpa, "{{{s}:{s}}}", .{ string_test_key, try Values.valueToSnbt(self, .{ .string = affix }) });
    return try Conditions.singleCheck(self, .{ .negated = negated, .score_test = .{ .data_test = .{ .holder = .{ .storage = .poplar }, .path = filter } } });
}

pub fn constantString(self: *Compiler, expression: *const Ast.Expr, env: *Environment, builtin: []const u8) Compiler.CompileError!?[]const u8 {
    const outer_position = self.enterExpression(expression);
    defer self.restorePosition(outer_position);
    if (!Values.containsRuntimeValue(self, expression, env)) {
        const value = try Values.evaluate(self, expression, env) orelse return null;
        if (value == .string) return value.string;
    }
    try self.addError("the second argument of '{s}' must be a constant string", .{builtin});
    return null;
}

// The string helpers on constants run when the pack is built. Indices count UTF-16 units, the same as the game.
pub fn evaluateStringCall(self: *Compiler, call: Ast.Call, env: *Environment) Compiler.CompileError!?Compiler.Value {
    const name = call.callee.kind.identifier.name;
    const arity_ok = if (Calls.isBuiltinCall(call, "slice")) call.args.len == 2 or call.args.len == 3 else if (Calls.isBuiltinCall(call, "str")) call.args.len == 1 else call.args.len == 2;
    if (!arity_ok) {
        try self.addError("'{s}' has the wrong number of arguments", .{name});
        return null;
    }
    const first = try Values.evaluate(self, call.args[0], env) orelse return null;
    const text = switch (first) {
        .string => |text| text,
        .number => |number| try std.fmt.allocPrint(self.gpa, "{d}", .{number}),
        .typed_number => |number| number.text,
        else => {
            try self.addError("'{s}' needs a string or a number, found {s}", .{ name, @tagName(first) });
            return null;
        },
    };
    if (Calls.isBuiltinCall(call, "str")) return .{ .string = text };
    if (isStringTest(call)) {
        const affix = try constantString(self, call.args[1], env, name) orelse return null;
        const matches = if (Calls.isBuiltinCall(call, "startsWith")) std.mem.startsWith(u8, text, affix) else std.mem.endsWith(u8, text, affix);
        return .{ .boolean = matches };
    }

    const units = std.unicode.utf8ToUtf16LeAlloc(self.gpa, text) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidUtf8 => {
            try self.addError("'slice' needs valid UTF-8 text", .{});
            return null;
        },
    };
    const length: i64 = @intCast(units.len);
    const start = try constantIndex(self, call.args[1], env) orelse return null;
    const end: i64 = if (call.args.len == 3) try constantIndex(self, call.args[2], env) orelse return null else length;
    const from: i64 = if (start < 0) length + start else start;
    const to: i64 = if (end < 0) length + end else end;
    if (from < 0 or to > length or from > to) {
        try self.addError("'slice' bounds {d}..{d} are out of range for a text of length {d}", .{ start, end, length });
        return null;
    }
    const sliced = std.unicode.utf16LeToUtf8Alloc(self.gpa, units[@intCast(from)..@intCast(to)]) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            try self.addError("'slice' cuts a character in two", .{});
            return null;
        },
    };
    return .{ .string = sliced };
}

// `len($list)`: `data get` on a list, compound or string gives its size.
pub fn compileLength(self: *Compiler, target: Ir.Score, call: Ast.Call, env: *const Environment, commands: *std.ArrayList(Ir.Command)) Compiler.CompileError!void {
    if (call.args.len != 1) return self.addError("'len' expects 1 argument, found {d}", .{call.args.len});
    const argument = call.args[0];
    if (!isDataIdentifier(argument)) return self.addError("'len' needs a list, a compound or a string in data", .{});
    const source = try dataPathOf(self, argument.kind.identifier, env) orelse return;
    try commands.append(self.gpa, .{ .data_to_score = .{ .source = source, .score = target } });
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
    , try Writer.renderFunction(arena.allocator(), "ns", program.load.?));
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

    const load = try Writer.renderFunction(arena.allocator(), "ns", program.load.?);
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
    const load = try Writer.renderFunction(arena.allocator(), "ns", program.load.?);
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
