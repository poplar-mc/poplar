//! Names and namespaces: registering mcfuns, globals and data files, and finding what a name refers to.

const std = @import("std");
const Compiler = @import("../Compiler.zig");
const ast = @import("../ast.zig");
const CommandTree = @import("../CommandTree.zig");
const data_folders = @import("../data_folders.zig");
const Config = @import("../Config.zig");
const Diagnostic = @import("../Diagnostic.zig");
const Environment = @import("../Environment.zig");
const Lexer = @import("../Lexer.zig");
const Parser = @import("../Parser.zig");
const datapack_writer = @import("../datapack_writer.zig");
const data = @import("data.zig");
const scores = @import("scores.zig");
const values = @import("values.zig");

/// `combat:heal`: how declarations are keyed in the compiler.
pub fn qualifiedKey(compiler: *Compiler, namespace: []const u8, name: []const u8) Compiler.CompileError![]const u8 {
    return std.fmt.allocPrint(compiler.arena, "{s}:{s}", .{ namespace, name });
}

/// Where the files of a namespace go. Null is the pack namespace, which std is written into.
pub fn outputNamespace(compiler: *const Compiler, namespace: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, namespace, Compiler.std_namespace) or std.mem.eql(u8, namespace, compiler.pack_namespace)) return null;
    return namespace;
}

/// The path of an mcfun in its output namespace: `heal`, and `std/clamp` for std, which shares the pack namespace.
pub fn outputPath(compiler: *Compiler, namespace: []const u8, name: []const u8) Compiler.CompileError![]const u8 {
    if (!std.mem.eql(u8, namespace, Compiler.std_namespace)) return name;
    return std.fmt.allocPrint(compiler.arena, "std/{s}", .{name});
}

/// The IR name of an mcfun: `combat:heal`, `heal` in the pack namespace, `std/clamp` for std.
pub fn functionName(compiler: *Compiler, namespace: []const u8, name: []const u8) Compiler.CompileError![]const u8 {
    const path = try outputPath(compiler, namespace, name);
    const output = outputNamespace(compiler, namespace) orelse return path;
    return std.fmt.allocPrint(compiler.arena, "{s}:{s}", .{ output, path });
}

/// The namespace that a name refers to: its own `magic:`, which the file must import, or the current one.
pub fn resolveNamespace(compiler: *Compiler, namespace: ?[]const u8) Compiler.CompileError!?[]const u8 {
    const name = namespace orelse return compiler.scope.namespace;
    if (std.mem.eql(u8, name, compiler.scope.namespace) or isImported(compiler, name)) return name;
    try compiler.addError("namespace '{s}' is not imported. Add 'import {s};'", .{ name, name });
    return null;
}

pub fn isImported(compiler: *const Compiler, namespace: []const u8) bool {
    for (compiler.scope.imports) |import| {
        if (std.mem.eql(u8, import.name, namespace)) return true;
    }
    return false;
}

pub fn isValidNamespace(name: []const u8) bool {
    if (name.len == 0) return false;
    for (name) |ch| {
        if (!std.ascii.isLower(ch) and !std.ascii.isDigit(ch) and ch != '_' and ch != '.') return false;
    }
    return true;
}

pub fn addDataFile(compiler: *Compiler, data_file: ast.DataFile) Compiler.CompileError!void {
    const folder = data_folders.folders.get(data_file.type_word) orelse
        try data_folders.tagFolder(compiler.arena, data_file.type_word, &compiler.command_tree.registries.map) orelse
        return compiler.addError("unknown data file type '{s}'{f}", .{ data_file.type_word, Suggestion{ .closest = CommandTree.closestId(data_folders.folders.keys(), data_file.type_word) } });

    const own_namespace = compiler.scope.output_namespace orelse compiler.pack_namespace;
    const namespace: []const u8, const file_path: []const u8 = switch (data_file.name) {
        .identifier => |name| blk: {
            const path = try std.fmt.allocPrint(compiler.arena, "{f}", .{datapack_writer.functionPath(name)});
            if (!Config.isValidResourceName(path)) {
                return compiler.addError("data file name '{s}' must only use letters, 0-9, '_', '.' and '-'", .{name});
            }
            break :blk .{ own_namespace, path };
        },
        .id => |id| blk: {
            const colon = std.mem.indexOfScalar(u8, id, ':');
            const id_namespace = if (colon) |index| id[0..index] else own_namespace;
            const path = if (colon) |index| id[index + 1 ..] else id;
            var segments = std.mem.splitScalar(u8, path, '/');
            const is_valid = while (segments.next()) |segment| {
                if (!Config.isValidResourceName(segment)) break false;
            } else Config.isValidResourceName(id_namespace);
            if (!is_valid) return compiler.addError("data file id '{s}' must only use a-z, 0-9, '_', '.', '-' and '/', with one ':' after the namespace", .{id});
            break :blk .{ id_namespace, path };
        },
    };

    const is_hook_tag = std.mem.eql(u8, folder, "tags/function") and std.mem.eql(u8, namespace, "minecraft") and
        (std.mem.eql(u8, file_path, "load") or std.mem.eql(u8, file_path, "tick"));
    if (is_hook_tag) return compiler.addError("Poplar writes the minecraft:{s} function tag. Use 'mcfun {s}'", .{ file_path, file_path });

    const full_path = try std.fmt.allocPrint(compiler.arena, "data/{s}/{s}/{s}.json", .{ namespace, folder, file_path });
    const location = try std.fmt.allocPrint(compiler.arena, "{s}:{d}", .{ compiler.path, data_file.position.line });
    const path_entry = try compiler.data_file_paths.getOrPut(compiler.arena, full_path);
    if (path_entry.found_existing) return compiler.addError("{s} '{s}:{s}' is already declared at {s}", .{ data_file.type_word, namespace, file_path, path_entry.value_ptr.* });
    path_entry.value_ptr.* = location;

    // A data file in the namespace of its file can be named in Minecraft text: `self:isSitting`.
    if (std.mem.eql(u8, namespace, own_namespace)) {
        const name = switch (data_file.name) {
            .identifier => |identifier| identifier,
            .id => file_path,
        };
        try compiler.data_file_names.put(compiler.arena, try qualifiedKey(compiler, compiler.scope.namespace, name), file_path);
    }

    if (data_file.name == .identifier) {
        const id = try std.fmt.allocPrint(compiler.arena, "{s}:{s}", .{ namespace, file_path });
        const entry = try compiler.named_data_files.getOrPut(compiler.arena, try qualifiedKey(compiler, compiler.scope.namespace, data_file.name.identifier));
        if (entry.found_existing) return compiler.addError("'{s}' is already the name of another data file", .{data_file.name.identifier});
        entry.value_ptr.* = .{ .type_word = data_file.type_word, .id = id, .path = compiler.path, .position = data_file.position };
    }

    if (try jsonErrorPosition(compiler, data_file)) |position| {
        compiler.position = position;
        return compiler.addError("invalid JSON in {s} '{s}'", .{ data_file.type_word, file_path });
    }

    try compiler.data_files.append(compiler.arena, .{
        .namespace = namespace,
        .folder = folder,
        .path = file_path,
        .json = try std.fmt.allocPrint(compiler.arena, "{s}\n", .{data_file.json}),
    });
}

/// Where the JSON body stops being valid, as a line and column in the source file.
fn jsonErrorPosition(compiler: *Compiler, data_file: ast.DataFile) Compiler.CompileError!?Diagnostic.Position {
    var scanner: std.json.Scanner = .initCompleteInput(compiler.arena, data_file.json);
    defer scanner.deinit();
    var diagnostics: std.json.Diagnostics = .{};
    scanner.enableDiagnostics(&diagnostics);
    while (true) {
        const token = scanner.next() catch |err| switch (err) {
            error.SyntaxError, error.UnexpectedEndOfInput => break,
            error.OutOfMemory => |e| return e,
            error.BufferUnderrun => unreachable,
        };
        if (token == .end_of_document) return null;
    }
    const json_line: usize = @intCast(diagnostics.getLine());
    const column: usize = @intCast(diagnostics.getColumn());
    return .{
        .line = data_file.json_position.line + json_line - 1,
        .column = if (json_line == 1) data_file.json_position.column + column - 1 else column,
    };
}

pub const Suggestion = struct {
    closest: ?[]const u8,

    pub fn format(self: Suggestion, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        if (self.closest) |closest| try writer.print(". Did you mean '{s}'?", .{closest});
    }
};

/// A name that the project and std both define is reported in the project file, where it can be renamed.
/// Otherwise the later definition is reported.
pub fn addDuplicateError(compiler: *Compiler, existing: Compiler.McfunDeclaration, later: Compiler.McfunDeclaration) Compiler.CompileError!void {
    const project_side, const other = if (existing.origin != .std and later.origin == .std) .{ existing, later } else .{ later, existing };
    compiler.path = project_side.path;
    compiler.position = project_side.mcfun.position;
    if (other.origin == .std and project_side.origin != .std) {
        return compiler.addError("function '{s}' is already defined in {s}:{d}. Rename yours", .{ later.mcfun.name, other.path, other.mcfun.position.line });
    }
    try compiler.addError("function '{s}' is already defined at {s}:{d}", .{ later.mcfun.name, other.path, other.mcfun.position.line });
}

pub fn addGlobal(compiler: *Compiler, decl: ast.VarDecl) Compiler.CompileError!void {
    if (decl.target.namespace) |namespace| return compiler.addError("'{s}:' cannot be declared here. Declare it in a file with 'namespace {s};'", .{ namespace, namespace });
    switch (decl.target.kind) {
        .score => {},
        .compile_time => return compiler.addError("only score (#) and data ($) variables can be declared at the top level", .{}),
        .data => return addDataGlobal(compiler, decl),
        .entity_data => return compiler.addError("entity data cannot be declared. Set it in an mcfun: '@s.$path = ...;'", .{}),
    }

    var env: Environment = .{};
    const value = try values.evaluate(compiler, decl.value, &env) orelse return;
    const initial_value = try scores.toScoreValue(compiler, value) orelse return;

    const entry = try compiler.globals.getOrPut(compiler.arena, try qualifiedKey(compiler, compiler.scope.namespace, decl.target.name));
    if (entry.found_existing) {
        const existing = entry.value_ptr.*;
        return compiler.addError("score '#{s}' is already declared at {s}:{d}", .{ decl.target.name, existing.path, existing.position.line });
    }

    entry.value_ptr.* = .{
        .path = compiler.path,
        .position = compiler.position,
        .initial_value = initial_value,
        .name = decl.target.name,
        .output_namespace = compiler.scope.output_namespace,
    };
}

fn addDataGlobal(compiler: *Compiler, decl: ast.VarDecl) Compiler.CompileError!void {
    if (Compiler.pathRoot(decl.target.name).len != decl.target.name.len) {
        return compiler.addError("'var' declares a whole variable. Set '${s}' in an mcfun", .{decl.target.name});
    }
    var env: Environment = .{};
    const value = try values.evaluate(compiler, decl.value, &env) orelse return;
    if (value == .null) return compiler.addError("a data variable cannot start as null", .{});
    const initial_snbt = try values.valueToSnbt(compiler, value);

    const entry = try compiler.data_globals.getOrPut(compiler.arena, try qualifiedKey(compiler, compiler.scope.namespace, decl.target.name));
    if (entry.found_existing) {
        const existing = entry.value_ptr.*;
        return compiler.addError("data '${s}' is already declared at {s}:{d}", .{ decl.target.name, existing.path, existing.position.line });
    }

    entry.value_ptr.* = .{
        .path = compiler.path,
        .position = compiler.position,
        .initial_snbt = initial_snbt,
        .name = decl.target.name,
        .output_namespace = compiler.scope.output_namespace,
        .storage = data.storageOf(compiler.scope.namespace),
    };
}

pub const FoundMcfun = struct {
    /// `combat:heal`, the key in `mcfuns` and `mcfun_calls`.
    key: []const u8,
    declaration: Compiler.McfunDeclaration,
};

/// `heal` in this namespace or `magic:heal` in an imported one. Null after an error.
pub fn findMcfun(compiler: *Compiler, identifier: ast.Identifier) Compiler.CompileError!?FoundMcfun {
    const namespace = try resolveNamespace(compiler, identifier.namespace) orelse return null;
    const mcfun_key = try qualifiedKey(compiler, namespace, identifier.name);
    const declaration = compiler.mcfuns.get(mcfun_key) orelse {
        try compiler.addError("unknown function '{s}'", .{identifier.name});
        return null;
    };
    return .{ .key = mcfun_key, .declaration = declaration };
}

/// The namespaces other than the pack namespace that have mcfuns: each one gets its own `poplar.<ns>` objective for temps and locals.
pub fn outputNamespaces(compiler: *Compiler) Compiler.CompileError![]const []const u8 {
    var namespaces: std.StringArrayHashMapUnmanaged(void) = .empty;
    for (compiler.mcfuns.values()) |declaration| {
        if (outputNamespace(compiler, declaration.namespace)) |namespace| try namespaces.put(compiler.arena, namespace, {});
    }
    return namespaces.keys();
}

test "data files go to their folder, and self: names them in commands" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    var compiler = try Compiler.compileForTest(arena.allocator(),
        \\predicate isSneaking { "condition": "minecraft:entity_properties" }
        \\lootTable "minecraft:entities/zombie" { "pools": [{ "rolls": 0.5 }] }
        \\biomeTag hot { "values": [] }
        \\recpie a {}
        \\recipe b {
        \\  "a": [1,]
        \\}
        \\recipe "b" {}
        \\mcfun main() { /execute if predicate self:isSneaking run say hi; }
    );
    const program = try compiler.compile();
    const errors = compiler.errors.items;
    try std.testing.expectEqual(3, errors.len);
    try std.testing.expectEqualStrings("unknown data file type 'recpie'. Did you mean 'recipe'?", errors[0].message);
    try std.testing.expectEqualStrings("invalid JSON in recipe 'b'", errors[1].message);
    try std.testing.expectEqual(6, errors[1].position.?.line);
    try std.testing.expectEqualStrings("recipe 'ns:b' is already declared at main.poplar:5", errors[2].message);

    try std.testing.expectEqualStrings("execute if predicate ns:is_sneaking run say hi", program.functions[0].commands[0].raw);
    const files = program.data_files;
    try std.testing.expectEqualStrings("predicate", files[0].folder);
    try std.testing.expectEqualStrings("is_sneaking", files[0].path);
    try std.testing.expectEqualStrings("minecraft", files[1].namespace);
    try std.testing.expectEqualStrings("entities/zombie", files[1].path);
    try std.testing.expectEqualStrings("tags/worldgen/biome", files[2].folder);
}

test "two namespaces keep their own names, files and scores" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const command_tree = try arena.allocator().create(CommandTree);
    command_tree.* = try .load(arena.allocator());
    var compiler = Compiler.init(arena.allocator(), command_tree);

    const sources = [_][]const u8{
        \\namespace ns;
        \\import magic;
        \\var #mana = 0;
        \\mcfun load() { #mana = 1; }
        \\mcfun heal() { magic:heal(); /function magic:castSpell; /function self:heal; /give @s minecraft:stone; }
        ,
        \\namespace magic;
        \\var #mana = 0;
        \\mcfun load() { #mana = 2; }
        \\mcfun heal() { #mana = #mana + 1; }
        \\mcfun castSpell() { ns:heal(); }
        \\mcfun build() { var $player = {mana: #mana}; }
    };
    for (sources) |source| {
        var parser = try Parser.init(arena.allocator(), Lexer.init(source));
        try compiler.addProgram("main.poplar", try parser.parseProgram(), .project);
    }
    const program = try compiler.compile();
    try std.testing.expectEqual(1, compiler.errors.items.len);
    try std.testing.expectEqualStrings("namespace 'ns' is not imported. Add 'import ns;'", compiler.errors.items[0].message);

    try std.testing.expectEqualStrings(
        \\function magic:heal
        \\function magic:cast_spell
        \\function ns:heal
        \\give @s minecraft:stone
        \\
    , try Compiler.renderForTest(arena.allocator(), program, "heal"));
    try std.testing.expectEqualStrings("scoreboard players add #global magic.mana 1\n", try Compiler.renderForTest(arena.allocator(), program, "magic:heal"));
    try std.testing.expectEqualStrings(
        \\data modify storage magic:data player_build set value {mana:0}
        \\execute store result storage magic:data player_build.mana int 1 run scoreboard players get #global magic.mana
        \\data remove storage magic:data player_build
        \\
    , try Compiler.renderForTest(arena.allocator(), program, "magic:build"));

    const load = try datapack_writer.renderFunction(arena.allocator(), "ns", program.load.?);
    try std.testing.expect(std.mem.endsWith(u8, load, "function magic:load\nfunction ns:load\n"));
}
