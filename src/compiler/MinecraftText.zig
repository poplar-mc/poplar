// Minecraft text: `/commands`, `execute (...)`, `{{...}}` inserts and macro lines, and `self:` ids.
const std = @import("std");
const Compiler = @import("../Compiler.zig");
const Ast = @import("../Ast.zig");
const Commands = @import("../Commands.zig");
const Environment = @import("../Environment.zig");
const Ir = @import("../Ir.zig");
const Writer = @import("../Writer.zig");
const Data = @import("Data.zig");
const Declarations = @import("Declarations.zig");
const Scores = @import("Scores.zig");
const Values = @import("Values.zig");

// `text_column` is the column where the command text starts, after the `/`.
pub fn compileCommand(self: *Compiler, command: Ast.Command, text_column: usize, env: *Environment, commands: *std.ArrayList(Ir.Command)) Compiler.CompileError!void {
    var command_text = try buildCommandText(self, command.parts, env) orelse return;
    command_text.text = try checkMinecraftText(self, command.parts, command_text, text_column, "", "") orelse return;

    if (!command_text.is_macro) return commands.append(self.gpa, .{ .raw = command_text.text });

    const name = try self.newGeneratedName("macro");
    const macro_commands = try self.gpa.dupe(Ir.Command, &.{.{ .macro = command_text.text }});
    try self.generated.append(self.gpa, .{ .name = name, .commands = macro_commands });
    try callMacroHelper(self, name, command_text, command_text.uses_macro_keys, env, commands);
}

// The storage that holds every insert, when each one is a whole `$` variable of the same storage: the helper can
// then read them from it as they are.
fn sharedStorage(inserts: []const Compiler.Insert) ?Ir.DataStorage {
    var shared: ?Ir.DataStorage = null;
    for (inserts) |insert| {
        if (!insert.isWholeDataVar()) return null;
        const path = insert.source.data;
        if (path.holder.storage != .data and path.holder.storage != .std) return null;
        const storage: Ir.DataStorage = .{ .storage = path.holder.storage, .namespace = path.namespace };
        if (shared) |other| {
            if (other.storage != storage.storage or !Ir.optionalEql(other.namespace, storage.namespace)) return null;
        }
        shared = storage;
    }
    return shared;
}

// A macro call gets its arguments from one place. A helper that also needs the macro arguments of the mcfun,
// or a path such as `$stats.hp`, gets one compound in `<ns>:poplar macro`: the macro arguments, then each value it uses.
pub fn callMacroHelper(self: *Compiler, name: []const u8, command_text: Compiler.CommandText, needs_macro_keys: bool, env: *Environment, commands: *std.ArrayList(Ir.Command)) Compiler.CompileError!void {
    if (!needs_macro_keys) if (sharedStorage(command_text.inserts)) |storage| {
        return commands.append(self.gpa, .{ .function_with = .{ .name = name, .arguments = .{ .data_storage = storage } } });
    };

    // Old keys from an earlier helper do no harm, because a macro line reads only the names it uses.
    if (needs_macro_keys) try commands.append(self.gpa, .{ .data_set = .{ .target = .inStorage(.macro, ""), .snbt = self.forwarded_args.? } });
    self.temp_count = 0;
    for (command_text.inserts) |insert| {
        const target: Ir.DataPath = .inStorage(.macro, insert.macro_name);
        switch (insert.source) {
            .data => |source| try commands.append(self.gpa, .{ .data_copy = .{ .target = target, .source = source } }),
            .value => |expression| {
                const outer_position = self.enterExpression(expression);
                defer self.restorePosition(outer_position);
                if (expression.kind == .call and Data.isStringCall(expression.kind.call)) {
                    try Data.compileStringInto(self, target, expression.kind.call, env, commands);
                    continue;
                }
                const score = if (expression.kind == .identifier and expression.kind.identifier.storage == .score)
                    try Scores.scoreSource(self, expression.kind.identifier, env) orelse return
                else blk: {
                    const temp = try Scores.newTemp(self);
                    try Scores.compileInto(self, temp, expression, env, commands);
                    break :blk temp;
                };
                try commands.append(self.gpa, .{ .score_to_data = .{ .target = target, .score = score } });
            },
        }
    }
    try commands.append(self.gpa, .{ .function_with = .{ .name = name, .arguments = .macro_storage } });
}

pub fn compileExecute(self: *Compiler, execute: Ast.Execute, env: *Environment, commands: *std.ArrayList(Ir.Command)) Compiler.CompileError!void {
    var subcommands = try buildCommandText(self, execute.subcommands, env) orelse return;
    subcommands.text = try checkMinecraftText(self, execute.subcommands, subcommands, execute.subcommands_column, "execute ", " run say x") orelse return;

    const can_return = Compiler.containsReturn(execute.body);
    if (can_return) {
        if (self.forwarded_args != null) return self.addError("'return' inside 'execute (...)' in an mcfun that uses macro arguments is not supported yet", .{});
        if (subcommands.is_macro) return self.addError("'return' inside 'execute (...)' with a data insert is not supported yet", .{});
    }

    const run = try self.compileJumpBody(execute.body, env, null);
    const execute_command: Ir.Command = .{ .execute_raw = .{ .subcommands = subcommands.text, .run = try self.createCommand(run orelse return) } };
    if (!subcommands.is_macro) return commands.append(self.gpa, execute_command);

    const name = try self.newGeneratedName("macro");
    try self.generated.append(self.gpa, .{ .name = name, .commands = try self.gpa.dupe(Ir.Command, &.{execute_command}) });
    // The body can forward the macro arguments too, so in an mcfun that uses them they always go along.
    try callMacroHelper(self, name, subcommands, self.forwarded_args != null, env, commands);
}

// Joins text and `{{...}}` inserts. A `{{#x}}` insert becomes `$(x)` and makes the text a macro line. `$(key)` in the
// text uses the mcfun's macro arguments.
pub fn buildCommandText(self: *Compiler, parts: []const Ast.CommandPart, env: *Environment) Compiler.CompileError!?Compiler.CommandText {
    var text: std.ArrayList(u8) = .empty;
    const text_starts = try self.gpa.alloc(usize, parts.len);
    var is_macro = false;
    var uses_macro_keys = false;
    var inserts: std.ArrayList(Compiler.Insert) = .empty;

    for (parts, text_starts) |part, *text_start| {
        text_start.* = text.items.len;
        switch (part.content) {
            .text => |part_text| {
                try text.appendSlice(self.gpa, part_text);
                if (std.mem.indexOf(u8, part_text, "$(") != null) uses_macro_keys = true;
            },
            .insert => |expression| {
                const outer_position = self.enterExpression(expression);
                defer self.restorePosition(outer_position);
                if (expression.kind == .macro_key) {
                    try text.print(self.gpa, "$({s})", .{expression.kind.macro_key});
                    uses_macro_keys = true;
                    continue;
                }
                if (Values.containsRuntimeValue(self, expression, env)) {
                    const insert = try runtimeInsert(self, expression, env, inserts.items) orelse return null;
                    try text.print(self.gpa, "$({s})", .{insert.macro_name});
                    is_macro = true;
                    for (inserts.items) |used| {
                        if (std.mem.eql(u8, used.macro_name, insert.macro_name)) break;
                    } else try inserts.append(self.gpa, insert);
                    continue;
                }
                const value = try Values.evaluate(self, expression, env) orelse return null;
                try text.appendSlice(self.gpa, try Values.valueToText(self, value));
            },
        }
    }

    return .{
        .text = try text.toOwnedSlice(self.gpa),
        .text_starts = text_starts,
        .is_macro = is_macro,
        .uses_macro_keys = uses_macro_keys,
        .inserts = try inserts.toOwnedSlice(self.gpa),
    };
}

// Where the value of a runtime insert comes from, and its macro name. The same value again in the line
// gives the insert that is already there.
pub fn runtimeInsert(self: *Compiler, expression: *const Ast.Expr, env: *Environment, used: []const Compiler.Insert) Compiler.CompileError!?Compiler.Insert {
    const outer_position = self.enterExpression(expression);
    defer self.restorePosition(outer_position);

    var base: []const u8 = "value";
    var source: Compiler.Insert.Source = .{ .value = expression };
    if (expression.kind == .identifier) {
        const identifier = expression.kind.identifier;
        switch (identifier.storage) {
            .data, .entity_data => {
                const path = try Data.dataPathOf(self, identifier, env) orelse return null;
                source = .{ .data = path };
                base = try macroName(self.gpa, path.path);
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
    while (isUsedMacroName(self, name, used)) : (number += 1) name = try std.fmt.allocPrint(self.gpa, "{s}_{d}", .{ base, number });
    return .{ .macro_name = name, .source = source };
}

pub fn isSameInsert(a: Compiler.Insert.Source, b: Compiler.Insert.Source) bool {
    switch (a) {
        .data => |path| return b == .data and std.meta.eql(path.holder, b.data.holder) and std.mem.eql(u8, path.path, b.data.path),
        .value => |expression| {
            if (b != .value or expression.kind != .identifier or b.value.kind != .identifier) return false;
            const left = expression.kind.identifier;
            const right = b.value.kind.identifier;
            return left.storage == .score and right.storage == .score and std.mem.eql(u8, left.name, right.name) and
                std.mem.eql(u8, left.selector orelse "", right.selector orelse "");
        },
    }
}

pub fn isUsedMacroName(self: *const Compiler, name: []const u8, used: []const Compiler.Insert) bool {
    for (used) |insert| {
        if (std.mem.eql(u8, insert.macro_name, name)) return true;
    }
    return self.macro_keys.contains(name);
}

// Maps an offset in the finished command back to the source. An offset inside an insert maps to its `{{`.
pub fn sourceOffset(parts: []const Ast.CommandPart, text_starts: []const usize, at: usize) usize {
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

// `stats.inventory[0]` → `stats_inventory_0_`: a name that a macro line can use.
pub fn macroName(gpa: std.mem.Allocator, path: []const u8) Compiler.CompileError![]const u8 {
    const name = try gpa.dupe(u8, path);
    for (name) |*ch| {
        if (!std.ascii.isAlphanumeric(ch.*) and ch.* != '_') ch.* = '_';
    }
    return name;
}

// Checks Minecraft text against the command tree, between `prefix` and `suffix`, and changes each `self:name` and
// `ns:name` of a declaration into its id. `column` is where the text starts in the source. Null after an error.
pub fn checkMinecraftText(self: *Compiler, parts: []const Ast.CommandPart, built: Compiler.CommandText, column: usize, comptime prefix: []const u8, comptime suffix: []const u8) Compiler.CompileError!?[]const u8 {
    const full_text = try std.fmt.allocPrint(self.gpa, prefix ++ "{s}" ++ suffix, .{built.text});
    const checked = try self.command_tree.checkText(self.gpa, full_text, self.poplar_namespaces);
    if (checked.failure) |failure| {
        const at = @min(failure.at -| prefix.len, built.text.len);
        try self.addErrorAt(column + sourceOffset(parts, built.text_starts, at), "{s}", .{failure.message});
        return null;
    }
    if (checked.ids.len == 0) return built.text;

    const ids = try self.gpa.dupe(Commands.Id, checked.ids);
    std.mem.sort(Commands.Id, ids, {}, idBefore);
    var resolved: std.ArrayList(u8) = .empty;
    var copied: usize = 0;
    for (ids) |text_id| {
        const start = text_id.at - prefix.len;
        var colon = start;
        while (colon < built.text.len and isNamespaceChar(built.text[colon])) colon += 1;
        if (colon >= built.text.len or built.text[colon] != ':') {
            if (text_id.can_be_pack_name) try checkBareName(self, parts, built, column, start);
            continue;
        }
        const written = built.text[start..colon];

        // A storage or bossbar id is not a Poplar declaration: `self:` only gives it the namespace.
        if (!text_id.names_declaration) {
            if (!std.mem.eql(u8, written, "self")) continue;
            try resolved.print(self.gpa, "{s}{s}", .{ built.text[copied..start], self.scope.output_namespace orelse self.namespace });
            copied = colon;
            continue;
        }
        const namespace = try sourceNamespaceOf(self, written) orelse continue;

        var end = colon + 1;
        while (end < built.text.len and isIdChar(built.text[end])) end += 1;
        const name = built.text[colon + 1 .. end];
        const id = try idOf(self, namespace, name) orelse {
            // `magic:heal_player`, the real id, stays as it is. `self:` only takes the name from the source.
            const is_self = std.mem.eql(u8, written, "self");
            if (!is_self and try declarationWithFileName(self, namespace, name) != null) continue;
            try self.addErrorAt(column + sourceOffset(parts, built.text_starts, start), "{s}", .{try unknownIdMessage(self, written, namespace, name)});
            return null;
        };
        try resolved.print(self.gpa, "{s}{s}", .{ built.text[copied..start], id });
        copied = end;
    }
    try resolved.appendSlice(self.gpa, built.text[copied..]);
    return resolved.items;
}

// A name with no namespace means `minecraft:name`, so a name from this pack needs `self:`.
fn checkBareName(self: *Compiler, parts: []const Ast.CommandPart, built: Compiler.CommandText, column: usize, start: usize) Compiler.CompileError!void {
    var end = start;
    while (end < built.text.len and isIdChar(built.text[end])) end += 1;
    const name = built.text[start..end];
    const namespace = self.scope.namespace;
    const in_pack = try idOf(self, namespace, name) != null;
    const source_name = if (in_pack) name else try declarationWithFileName(self, namespace, name) orelse {
        // An id cannot have a capital letter, so this is a typo of a name from this pack, or a mistake.
        for (name) |ch| {
            if (std.ascii.isUpper(ch)) return self.addErrorAt(column + sourceOffset(parts, built.text_starts, start), "'{s}' cannot be an id, because an id has no capital letters. To name something in this pack, write 'self:{s}'", .{ name, name });
        }
        return;
    };
    try self.addErrorAt(column + sourceOffset(parts, built.text_starts, start), "'{s}' is in this pack, but with no namespace it means 'minecraft:{s}'. Write 'self:{s}'", .{ name, name, source_name });
}

pub fn idBefore(_: void, a: Commands.Id, b: Commands.Id) bool {
    return a.at < b.at;
}

pub fn isNamespaceChar(ch: u8) bool {
    return std.ascii.isLower(ch) or std.ascii.isDigit(ch) or ch == '_' or ch == '.' or ch == '-';
}

pub fn isIdChar(ch: u8) bool {
    return std.ascii.isAlphanumeric(ch) or std.mem.indexOfScalar(u8, "_-./", ch) != null;
}

// The namespace whose Poplar names an id in Minecraft text uses: `self:`, or a namespace of the pack that the file
// imports. Null for any other id, such as `minecraft:stone`, which is left as it is.
pub fn sourceNamespaceOf(self: *Compiler, written: []const u8) Compiler.CompileError!?[]const u8 {
    if (std.mem.eql(u8, written, "self")) return self.scope.namespace;
    if (!self.namespace_imports.contains(written)) return null;
    if (std.mem.eql(u8, written, self.scope.namespace) or Declarations.isImported(self, written)) return written;
    return null;
}

// `combat:healPlayer` → `combat:heal_player`, `std:clamp` → `<pack>:std/clamp`, `combat:isSitting` → `combat:is_sitting`.
pub fn idOf(self: *Compiler, namespace: []const u8, name: []const u8) Compiler.CompileError!?[]const u8 {
    const output = Declarations.outputNamespace(self, namespace) orelse self.namespace;
    const name_key = try Declarations.qualifiedKey(self, namespace, name);
    if (self.data_file_names.get(name_key)) |path| return try std.fmt.allocPrint(self.gpa, "{s}:{s}", .{ output, path });
    if (!self.functions.contains(name_key)) return null;
    return try std.fmt.allocPrint(self.gpa, "{s}:{f}", .{ output, Writer.functionPath(try Declarations.outputPath(self, namespace, name)) });
}

// The source names of the data files and mcfuns of a namespace.
pub fn declaredNames(self: *Compiler, namespace: []const u8) Compiler.CompileError![]const []const u8 {
    const key_prefix = try Declarations.qualifiedKey(self, namespace, "");
    var names: std.ArrayList([]const u8) = .empty;
    for ([_][]const []const u8{ self.data_file_names.keys(), self.functions.keys() }) |keys| {
        for (keys) |declared| {
            if (std.mem.startsWith(u8, declared, key_prefix)) try names.append(self.gpa, declared[key_prefix.len..]);
        }
    }
    return names.items;
}

// The source name whose file is `file_name`: `healPlayer` for `heal_player`.
pub fn declarationWithFileName(self: *Compiler, namespace: []const u8, file_name: []const u8) Compiler.CompileError!?[]const u8 {
    for (try declaredNames(self, namespace)) |declared| {
        const declared_file = self.data_file_names.get(try Declarations.qualifiedKey(self, namespace, declared)) orelse
            try std.fmt.allocPrint(self.gpa, "{f}", .{Writer.functionPath(declared)});
        if (std.mem.eql(u8, declared_file, file_name)) return declared;
    }
    return null;
}

pub fn unknownIdMessage(self: *Compiler, written: []const u8, namespace: []const u8, name: []const u8) Compiler.CompileError![]const u8 {
    // `self:heal_player` is the file name of `healPlayer`: point to the name in the source.
    if (try declarationWithFileName(self, namespace, name)) |declared| {
        return std.fmt.allocPrint(self.gpa, "'{s}:{s}' is a file name. Use the name from the source: '{s}:{s}'", .{ written, name, written, declared });
    }
    const names = try declaredNames(self, namespace);
    return std.fmt.allocPrint(self.gpa, "'{s}:{s}' is not a data file or mcfun of namespace '{s}'{f}", .{ written, name, namespace, Declarations.Suggestion{ .closest = Commands.closestId(names, name) } });
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
    try std.testing.expectEqual(27, errors[0].column);
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
    try std.testing.expectEqual(7, compiler.errors.items[0].line);
    try std.testing.expectEqual(38, compiler.errors.items[0].column);

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
