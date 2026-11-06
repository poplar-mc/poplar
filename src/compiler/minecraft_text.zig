//! Minecraft text: `/commands`, `execute (...)`, `{{...}}` inserts and macro lines, and `self:` ids.

const std = @import("std");
const Compiler = @import("../Compiler.zig");
const ast = @import("../ast.zig");
const CommandTree = @import("../CommandTree.zig");
const Environment = @import("../Environment.zig");
const ir = @import("../ir.zig");
const datapack_writer = @import("../datapack_writer.zig");
const data = @import("data.zig");
const declarations = @import("declarations.zig");
const scores = @import("scores.zig");
const values = @import("values.zig");

/// `text_column` is the column where the command text starts, after the `/`.
pub fn compileCommand(compiler: *Compiler, command: ast.Command, text_column: usize, env: *Environment, commands: *std.ArrayList(ir.Command)) Compiler.CompileError!void {
    var command_text = try buildCommandText(compiler, command.parts, env) orelse return;
    command_text.text = try checkMinecraftText(compiler, command.parts, command_text, text_column, "", "") orelse return;

    if (!command_text.is_macro) return commands.append(compiler.arena, .{ .raw = command_text.text });

    const name = try compiler.newGeneratedName("macro");
    const macro_commands = try compiler.arena.dupe(ir.Command, &.{.{ .macro = command_text.text }});
    try compiler.generated.append(compiler.arena, .{ .name = name, .commands = macro_commands });
    try callMacroHelper(compiler, name, command_text, command_text.uses_macro_keys, env, commands);
}

/// The storage that holds every insert, when each one is a whole `$` variable of the same storage: the helper can
/// then read them from it as they are.
fn sharedStorage(inserts: []const Compiler.Insert) ?ir.DataStorage {
    var shared: ?ir.DataStorage = null;
    for (inserts) |insert| {
        if (!insert.isWholeDataVar()) return null;
        const path = insert.source.data;
        if (path.holder.storage != .data and path.holder.storage != .std) return null;
        const storage: ir.DataStorage = .{ .kind = path.holder.storage, .namespace = path.namespace };
        if (shared) |other| {
            if (other.kind != storage.kind or !ir.optionalEql(other.namespace, storage.namespace)) return null;
        }
        shared = storage;
    }
    return shared;
}

/// A macro call gets its arguments from one place. A helper that also needs the macro arguments of the mcfun,
/// or a path such as `$stats.hp`, gets one compound in `<ns>:poplar macro`: the macro arguments, then each value it uses.
fn callMacroHelper(compiler: *Compiler, name: []const u8, command_text: Compiler.CommandText, needs_macro_keys: bool, env: *Environment, commands: *std.ArrayList(ir.Command)) Compiler.CompileError!void {
    if (!needs_macro_keys) if (sharedStorage(command_text.inserts)) |storage| {
        return commands.append(compiler.arena, .{ .function_with = .{ .name = name, .arguments = .{ .data_storage = storage } } });
    };

    // Old keys from an earlier helper do no harm, because a macro line reads only the names it uses.
    if (needs_macro_keys) try commands.append(compiler.arena, .{ .data_set = .{ .target = .inStorage(.macro, ""), .snbt = compiler.mcfun.forwarded_args.? } });
    compiler.mcfun.temp_count = 0;
    for (command_text.inserts) |insert| {
        const target: ir.DataPath = .inStorage(.macro, insert.macro_name);
        switch (insert.source) {
            .data => |source| try commands.append(compiler.arena, .{ .data_copy = .{ .target = target, .source = source } }),
            .value => |expression| {
                const outer_position = compiler.enterExpression(expression);
                defer compiler.restorePosition(outer_position);
                if (expression.kind == .call and data.isStringCall(expression.kind.call)) {
                    try data.compileStringInto(compiler, target, expression.kind.call, env, commands);
                    continue;
                }
                const score = if (expression.kind == .identifier and expression.kind.identifier.kind == .score)
                    try scores.scoreSource(compiler, expression.kind.identifier, env) orelse return
                else blk: {
                    const temp = try scores.newTemp(compiler);
                    try scores.compileInto(compiler, temp, expression, env, commands);
                    break :blk temp;
                };
                try commands.append(compiler.arena, .{ .score_to_data = .{ .target = target, .score = score } });
            },
        }
    }
    try commands.append(compiler.arena, .{ .function_with = .{ .name = name, .arguments = .macro_storage } });
}

pub fn compileExecute(compiler: *Compiler, execute: ast.Execute, env: *Environment, commands: *std.ArrayList(ir.Command)) Compiler.CompileError!void {
    var subcommands = try buildCommandText(compiler, execute.subcommands, env) orelse return;
    subcommands.text = try checkMinecraftText(compiler, execute.subcommands, subcommands, execute.subcommands_column, "execute ", " run say x") orelse return;

    const can_return = Compiler.containsReturn(execute.body);
    if (can_return) {
        if (compiler.mcfun.forwarded_args != null) return compiler.addError("'return' inside 'execute (...)' in an mcfun that uses macro arguments is not supported yet", .{});
        if (subcommands.is_macro) return compiler.addError("'return' inside 'execute (...)' with a data insert is not supported yet", .{});
    }

    const run = try compiler.compileJumpBody(execute.body, env, null);
    const execute_command: ir.Command = .{ .execute_raw = .{ .subcommands = subcommands.text, .run = try compiler.createCommand(run orelse return) } };
    if (!subcommands.is_macro) return commands.append(compiler.arena, execute_command);

    const name = try compiler.newGeneratedName("macro");
    try compiler.generated.append(compiler.arena, .{ .name = name, .commands = try compiler.arena.dupe(ir.Command, &.{execute_command}) });
    // The body can forward the macro arguments too, so in an mcfun that uses them they always go along.
    try callMacroHelper(compiler, name, subcommands, compiler.mcfun.forwarded_args != null, env, commands);
}

/// Joins text and `{{...}}` inserts. A `{{#x}}` insert becomes `$(x)` and makes the text a macro line. `$(key)` in the
/// text uses the mcfun's macro arguments.
pub fn buildCommandText(compiler: *Compiler, parts: []const ast.CommandPart, env: *Environment) Compiler.CompileError!?Compiler.CommandText {
    var text: std.ArrayList(u8) = .empty;
    const text_starts = try compiler.arena.alloc(usize, parts.len);
    var is_macro = false;
    var uses_macro_keys = false;
    var inserts: std.ArrayList(Compiler.Insert) = .empty;

    for (parts, text_starts) |part, *text_start| {
        text_start.* = text.items.len;
        switch (part.content) {
            .text => |part_text| {
                try text.appendSlice(compiler.arena, part_text);
                if (std.mem.indexOf(u8, part_text, "$(") != null) uses_macro_keys = true;
            },
            .insert => |expression| {
                const outer_position = compiler.enterExpression(expression);
                defer compiler.restorePosition(outer_position);
                if (expression.kind == .macro_key) {
                    try text.print(compiler.arena, "$({s})", .{expression.kind.macro_key});
                    uses_macro_keys = true;
                    continue;
                }
                if (values.containsRuntimeValue(compiler, expression, env)) {
                    const insert = try runtimeInsert(compiler, expression, env, inserts.items) orelse return null;
                    try text.print(compiler.arena, "$({s})", .{insert.macro_name});
                    is_macro = true;
                    for (inserts.items) |used| {
                        if (std.mem.eql(u8, used.macro_name, insert.macro_name)) break;
                    } else try inserts.append(compiler.arena, insert);
                    continue;
                }
                const value = try values.evaluate(compiler, expression, env) orelse return null;
                try text.appendSlice(compiler.arena, try values.valueToText(compiler, value));
            },
        }
    }

    return .{
        .text = try text.toOwnedSlice(compiler.arena),
        .text_starts = text_starts,
        .is_macro = is_macro,
        .uses_macro_keys = uses_macro_keys,
        .inserts = try inserts.toOwnedSlice(compiler.arena),
    };
}

/// Where the value of a runtime insert comes from, and its macro name. The same value again in the line
/// gives the insert that is already there.
fn runtimeInsert(compiler: *Compiler, expression: *const ast.Expression, env: *Environment, used: []const Compiler.Insert) Compiler.CompileError!?Compiler.Insert {
    const outer_position = compiler.enterExpression(expression);
    defer compiler.restorePosition(outer_position);

    var base: []const u8 = "value";
    var source: Compiler.Insert.Source = .{ .value = expression };
    if (expression.kind == .identifier) {
        const identifier = expression.kind.identifier;
        switch (identifier.kind) {
            .data, .entity_data => {
                const path = try data.dataPathOf(compiler, identifier, env) orelse return null;
                source = .{ .data = path };
                base = try macroName(compiler.arena, path.path);
            },
            .score => base = identifier.name,
            .compile_time => {},
        }
    }

    for (used) |insert| {
        if (isSameInsert(insert.source, source)) return insert;
    }

    // A helper may get the macro arguments and the values in one compound, so each name must be new.
    var name = base;
    var number: usize = 2;
    while (isUsedMacroName(compiler, name, used)) : (number += 1) name = try std.fmt.allocPrint(compiler.arena, "{s}_{d}", .{ base, number });
    return .{ .macro_name = name, .source = source };
}

fn isSameInsert(a: Compiler.Insert.Source, b: Compiler.Insert.Source) bool {
    switch (a) {
        .data => |path| return b == .data and std.meta.eql(path.holder, b.data.holder) and std.mem.eql(u8, path.path, b.data.path),
        .value => |expression| {
            if (b != .value or expression.kind != .identifier or b.value.kind != .identifier) return false;
            const left = expression.kind.identifier;
            const right = b.value.kind.identifier;
            return left.kind == .score and right.kind == .score and std.mem.eql(u8, left.name, right.name) and
                std.mem.eql(u8, left.selector orelse "", right.selector orelse "");
        },
    }
}

fn isUsedMacroName(compiler: *const Compiler, name: []const u8, used: []const Compiler.Insert) bool {
    for (used) |insert| {
        if (std.mem.eql(u8, insert.macro_name, name)) return true;
    }
    return compiler.mcfun.macro_keys.contains(name);
}

/// Maps an offset in the finished command back to the source. An offset inside an insert maps to its `{{`.
fn sourceOffset(parts: []const ast.CommandPart, text_starts: []const usize, at: usize) usize {
    var source_offset = at;
    for (parts, text_starts) |part, text_start| {
        if (text_start > at) break;
        source_offset = switch (part.content) {
            .text => part.offset + (at - text_start),
            .insert => part.offset,
        };
    }
    return source_offset;
}

/// `stats.inventory[0]` → `stats_inventory_0_`: a name that a macro line can use.
fn macroName(arena: std.mem.Allocator, path: []const u8) Compiler.CompileError![]const u8 {
    const name = try arena.dupe(u8, path);
    for (name) |*ch| {
        if (!std.ascii.isAlphanumeric(ch.*) and ch.* != '_') ch.* = '_';
    }
    return name;
}

/// Checks Minecraft text against the command tree, between `prefix` and `suffix`, and changes each `self:name` and
/// `ns:name` of a declaration into its id. `column` is where the text starts in the source. Null after an error.
pub fn checkMinecraftText(compiler: *Compiler, parts: []const ast.CommandPart, built: Compiler.CommandText, column: usize, comptime prefix: []const u8, comptime suffix: []const u8) Compiler.CompileError!?[]const u8 {
    const full_text = try std.fmt.allocPrint(compiler.arena, prefix ++ "{s}" ++ suffix, .{built.text});
    const checked = try compiler.command_tree.checkText(compiler.arena, full_text, compiler.poplar_namespaces);
    if (checked.failure) |failure| {
        const at = @min(failure.at -| prefix.len, built.text.len);
        try compiler.addErrorAt(column + sourceOffset(parts, built.text_starts, at), "{s}", .{failure.message});
        return null;
    }
    if (checked.ids.len == 0) return built.text;

    const ids = try compiler.arena.dupe(CommandTree.Id, checked.ids);
    std.mem.sort(CommandTree.Id, ids, {}, idBefore);
    var resolved: std.ArrayList(u8) = .empty;
    var copied: usize = 0;
    for (ids) |text_id| {
        const start = text_id.at - prefix.len;
        var colon = start;
        while (colon < built.text.len and isNamespaceChar(built.text[colon])) colon += 1;
        if (colon >= built.text.len or built.text[colon] != ':') {
            if (text_id.can_be_pack_name) try checkBareName(compiler, parts, built, column, start);
            continue;
        }
        const written = built.text[start..colon];

        // A storage or bossbar id is not a Poplar declaration: `self:` only gives it the namespace.
        if (!text_id.names_declaration) {
            if (!std.mem.eql(u8, written, "self")) continue;
            try resolved.print(compiler.arena, "{s}{s}", .{ built.text[copied..start], compiler.scope.output_namespace orelse compiler.pack_namespace });
            copied = colon;
            continue;
        }
        const namespace = try sourceNamespaceOf(compiler, written) orelse continue;

        var end = colon + 1;
        while (end < built.text.len and isIdChar(built.text[end])) end += 1;
        const name = built.text[colon + 1 .. end];
        const id = try idOf(compiler, namespace, name) orelse {
            // `magic:heal_player`, the real id, stays as it is. `self:` only takes the name from the source.
            const is_self = std.mem.eql(u8, written, "self");
            if (!is_self and try declarationWithFileName(compiler, namespace, name) != null) continue;
            try compiler.addErrorAt(column + sourceOffset(parts, built.text_starts, start), "{s}", .{try unknownIdMessage(compiler, written, namespace, name)});
            return null;
        };
        try resolved.print(compiler.arena, "{s}{s}", .{ built.text[copied..start], id });
        copied = end;
    }
    try resolved.appendSlice(compiler.arena, built.text[copied..]);
    return resolved.items;
}

/// A name with no namespace means `minecraft:name`, so a name from this pack needs `self:`.
fn checkBareName(compiler: *Compiler, parts: []const ast.CommandPart, built: Compiler.CommandText, column: usize, start: usize) Compiler.CompileError!void {
    var end = start;
    while (end < built.text.len and isIdChar(built.text[end])) end += 1;
    const name = built.text[start..end];
    const namespace = compiler.scope.namespace;
    const in_pack = try idOf(compiler, namespace, name) != null;
    const source_name = if (in_pack) name else try declarationWithFileName(compiler, namespace, name) orelse {
        // An id cannot have a capital letter, so this is a typo of a name from this pack, or a mistake.
        for (name) |ch| {
            if (std.ascii.isUpper(ch)) return compiler.addErrorAt(column + sourceOffset(parts, built.text_starts, start), "'{s}' cannot be an id, because an id has no capital letters. To name something in this pack, write 'self:{s}'", .{ name, name });
        }
        return;
    };
    try compiler.addErrorAt(column + sourceOffset(parts, built.text_starts, start), "'{s}' is in this pack, but with no namespace it means 'minecraft:{s}'. Write 'self:{s}'", .{ name, name, source_name });
}

fn idBefore(_: void, a: CommandTree.Id, b: CommandTree.Id) bool {
    return a.at < b.at;
}

pub fn isNamespaceChar(ch: u8) bool {
    return std.ascii.isLower(ch) or std.ascii.isDigit(ch) or ch == '_' or ch == '.' or ch == '-';
}

fn isIdChar(ch: u8) bool {
    return std.ascii.isAlphanumeric(ch) or std.mem.indexOfScalar(u8, "_-./", ch) != null;
}

/// The namespace whose Poplar names an id in Minecraft text uses: `self:`, or a namespace of the pack that the file
/// imports. Null for any other id, such as `minecraft:stone`, which is left as it is.
fn sourceNamespaceOf(compiler: *Compiler, written: []const u8) Compiler.CompileError!?[]const u8 {
    if (std.mem.eql(u8, written, "self")) return compiler.scope.namespace;
    if (!compiler.namespace_imports.contains(written)) return null;
    if (std.mem.eql(u8, written, compiler.scope.namespace) or declarations.isImported(compiler, written)) return written;
    return null;
}

/// `combat:healPlayer` → `combat:heal_player`, `std:clamp` → `<pack>:std/clamp`, `combat:isSitting` → `combat:is_sitting`.
fn idOf(compiler: *Compiler, namespace: []const u8, name: []const u8) Compiler.CompileError!?[]const u8 {
    const output = declarations.outputNamespace(compiler, namespace) orelse compiler.pack_namespace;
    const name_key = try declarations.qualifiedKey(compiler, namespace, name);
    if (compiler.data_file_names.get(name_key)) |path| return try std.fmt.allocPrint(compiler.arena, "{s}:{s}", .{ output, path });
    if (!compiler.mcfuns.contains(name_key)) return null;
    return try std.fmt.allocPrint(compiler.arena, "{s}:{f}", .{ output, datapack_writer.functionPath(try declarations.outputPath(compiler, namespace, name)) });
}

/// The source names of the data files and mcfuns of a namespace.
fn declaredNames(compiler: *Compiler, namespace: []const u8) Compiler.CompileError![]const []const u8 {
    const key_prefix = try declarations.qualifiedKey(compiler, namespace, "");
    var names: std.ArrayList([]const u8) = .empty;
    for ([_][]const []const u8{ compiler.data_file_names.keys(), compiler.mcfuns.keys() }) |keys| {
        for (keys) |declared| {
            if (std.mem.startsWith(u8, declared, key_prefix)) try names.append(compiler.arena, declared[key_prefix.len..]);
        }
    }
    return names.items;
}

/// The source name whose file is `file_name`: `healPlayer` for `heal_player`.
fn declarationWithFileName(compiler: *Compiler, namespace: []const u8, file_name: []const u8) Compiler.CompileError!?[]const u8 {
    for (try declaredNames(compiler, namespace)) |declared| {
        const declared_file = compiler.data_file_names.get(try declarations.qualifiedKey(compiler, namespace, declared)) orelse
            try std.fmt.allocPrint(compiler.arena, "{f}", .{datapack_writer.functionPath(declared)});
        if (std.mem.eql(u8, declared_file, file_name)) return declared;
    }
    return null;
}

fn unknownIdMessage(compiler: *Compiler, written: []const u8, namespace: []const u8, name: []const u8) Compiler.CompileError![]const u8 {
    // `self:heal_player` is the file name of `healPlayer`: point to the name in the source.
    if (try declarationWithFileName(compiler, namespace, name)) |declared| {
        return std.fmt.allocPrint(compiler.arena, "'{s}:{s}' is a file name. Use the name from the source: '{s}:{s}'", .{ written, name, written, declared });
    }
    const names = try declaredNames(compiler, namespace);
    return std.fmt.allocPrint(compiler.arena, "'{s}:{s}' is not a data file or mcfun of namespace '{s}'{f}", .{ written, name, namespace, declarations.Suggestion{ .closest = CommandTree.closestId(names, name) } });
}

test "a bare name from this pack is an error where it can only be a function or a data file" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    var compiler = try Compiler.compileForTest(arena.allocator(),
        \\predicate isVehicle { "type": "minecraft:random_chance", "chance": 1.0 }
        \\functionTag greeters { "values": [] }
        \\lootTable "minecraft:entities/zombie" { "pools": [] }
        \\mcfun speed() { /effect give @s speed; }
        \\mcfun zombie() { /summon zombie; /kill @e[type=zombie,tag=speed,team=speed]; /say speed; }
        \\mcfun main() {
        \\    /execute if predicate isVehicle run say x;
        \\    /execute if predicate is_vehicle run say x;
        \\    if (predicate isVehicle) { /say x; }
        \\    /function speed;
        \\    /function #greeters;
        \\    /kill @e[predicate=isVehicle];
        \\    /loot give @s loot entities/zombie;
        \\    /execute if predicate other run say x;
        \\    /execute if predicate isMissing run say x;
        \\    /data get storage speed x;
        \\}
    );
    _ = try compiler.compile();
    const errors = compiler.errors.items;
    try std.testing.expectEqual(7, errors.len);
    try std.testing.expectEqualStrings("'isMissing' cannot be an id, because an id has no capital letters. To name something in this pack, write 'self:isMissing'", errors[6].message);
    try std.testing.expectEqualStrings("'isVehicle' is in this pack, but with no namespace it means 'minecraft:isVehicle'. Write 'self:isVehicle'", errors[0].message);
    try std.testing.expectEqual(27, errors[0].position.?.column);
    try std.testing.expectEqualStrings("'is_vehicle' is in this pack, but with no namespace it means 'minecraft:is_vehicle'. Write 'self:isVehicle'", errors[1].message);
    try std.testing.expectEqualStrings("'speed' is in this pack, but with no namespace it means 'minecraft:speed'. Write 'self:speed'", errors[3].message);
    try std.testing.expectEqualStrings("'greeters' is in this pack, but with no namespace it means 'minecraft:greeters'. Write 'self:greeters'", errors[4].message);
}

test "inserts compile-time and runtime values into commands" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    var compiler = try Compiler.compileForTest(arena.allocator(),
        \\var #hp = 0;
        \\mcfun main() {
        \\    var n = 2;
        \\    /effect give @p poison {{n * 5}};
        \\    /say {{#hp}} {{#hp * 2}} {{@s.$CustomName}} $(hp) {{#hp}};
        \\}
        \\mcfun bad() { /effect give @p poison {{"x"}}; }
    );
    const program = try compiler.compile();

    try std.testing.expectEqual(1, compiler.errors.items.len);
    try std.testing.expectEqual(7, compiler.errors.items[0].position.?.line);
    try std.testing.expectEqual(38, compiler.errors.items[0].position.?.column);

    // The macro key `hp` has the name `hp`, so the score gets `hp_2`. The same score again uses it again.
    try std.testing.expectEqualStrings(
        \\effect give @p poison 10
        \\$data modify storage ns:poplar macro set value {hp:"$(hp)"}
        \\execute store result storage ns:poplar macro.hp_2 int 1 run scoreboard players get #global ns.hp
        \\scoreboard players operation #poplar.main.t0 poplar.ns = #global ns.hp
        \\execute store result storage ns:poplar macro.value int 1 run scoreboard players operation #poplar.main.t0 poplar.ns *= #poplar.c2 poplar.ns
        \\data modify storage ns:poplar macro.CustomName set from entity @s CustomName
        \\function ns:poplar/main/macro_0 with storage ns:poplar macro
        \\
    , try Compiler.renderForTest(arena.allocator(), program, "main"));
    try std.testing.expectEqualStrings("$say $(hp_2) $(value) $(CustomName) $(hp) $(hp_2)\n", try Compiler.renderForTest(arena.allocator(), program, "poplar/main/macro_0"));
}

test "a command uses a data variable and a macro key together" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    var compiler = try Compiler.compileForTest(arena.allocator(),
        \\var $item = "diamond";
        \\mcfun give() { /give @s {{$item}} $(count); }
    );
    const program = try compiler.compile();
    try std.testing.expectEqual(0, compiler.errors.items.len);

    try std.testing.expectEqualStrings(
        \\$data modify storage ns:poplar macro set value {count:"$(count)"}
        \\data modify storage ns:poplar macro.item set from storage ns:data item
        \\function ns:poplar/give/macro_0 with storage ns:poplar macro
        \\
    , try Compiler.renderForTest(arena.allocator(), program, "give"));
    try std.testing.expectEqualStrings("$give @s $(item) $(count)\n", try Compiler.renderForTest(arena.allocator(), program, "poplar/give/macro_0"));
}
