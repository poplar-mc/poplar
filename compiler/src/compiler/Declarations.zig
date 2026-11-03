// Names and namespaces: registering mcfuns, globals and data files, and finding what a name refers to.
const std = @import("std");
const Compiler = @import("../Compiler.zig");
const Ast = @import("../Ast.zig");
const Commands = @import("../Commands.zig");
const DataFile = @import("../DataFile.zig");
const Config = @import("../Config.zig");
const Environment = @import("../Environment.zig");
const Lexer = @import("../Lexer.zig");
const Parser = @import("../Parser.zig");
const Writer = @import("../Writer.zig");
const Data = @import("Data.zig");
const Scores = @import("Scores.zig");
const Values = @import("Values.zig");

// `combat:heal`: how declarations are keyed in the compiler.
pub fn qualifiedKey(self: *Compiler, namespace: []const u8, name: []const u8) Compiler.CompileError![]const u8 {
    return std.fmt.allocPrint(self.gpa, "{s}:{s}", .{ namespace, name });
}

// Where the files of a namespace go. Null is the pack namespace, which std is written into.
pub fn outputNamespace(self: *const Compiler, namespace: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, namespace, Compiler.std_namespace) or std.mem.eql(u8, namespace, self.namespace)) return null;
    return namespace;
}

// The path of an mcfun in its output namespace: `heal`, and `std/clamp` for std, which shares the pack namespace.
pub fn outputPath(self: *Compiler, namespace: []const u8, name: []const u8) Compiler.CompileError![]const u8 {
    if (!std.mem.eql(u8, namespace, Compiler.std_namespace)) return name;
    return std.fmt.allocPrint(self.gpa, "std/{s}", .{name});
}

// The IR name of an mcfun: `combat:heal`, `heal` in the pack namespace, `std/clamp` for std.
pub fn functionName(self: *Compiler, namespace: []const u8, name: []const u8) Compiler.CompileError![]const u8 {
    const path = try outputPath(self, namespace, name);
    const output = outputNamespace(self, namespace) orelse return path;
    return std.fmt.allocPrint(self.gpa, "{s}:{s}", .{ output, path });
}

// The namespace that a name refers to: its own `magic:`, which the file must import, or the current one.
pub fn resolveNamespace(self: *Compiler, namespace: ?[]const u8) Compiler.CompileError!?[]const u8 {
    const name = namespace orelse return self.scope.namespace;
    if (std.mem.eql(u8, name, self.scope.namespace) or isImported(self, name)) return name;
    try self.addError("namespace '{s}' is not imported. Add 'import {s};'", .{ name, name });
    return null;
}

pub fn isImported(self: *const Compiler, namespace: []const u8) bool {
    for (self.scope.imports) |import| {
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

pub fn addDataFile(self: *Compiler, data_file: Ast.DataFile) Compiler.CompileError!void {
    const folder = DataFile.folders.get(data_file.type_word) orelse
        try DataFile.tagFolder(self.gpa, data_file.type_word, &self.command_tree.registries.map) orelse
        return self.addError("unknown data file type '{s}'{f}", .{ data_file.type_word, Suggestion{ .closest = Commands.closestId(DataFile.folders.keys(), data_file.type_word) } });

    var namespace = self.scope.output_namespace orelse self.namespace;
    var file_path: []const u8 = undefined;
    switch (data_file.name) {
        .identifier => |name| {
            file_path = try std.fmt.allocPrint(self.gpa, "{f}", .{Writer.functionPath(name)});
            if (!Config.isValidResourceName(file_path)) {
                return self.addError("data file name '{s}' must only use letters, 0-9, '_', '.' and '-'", .{name});
            }
        },
        .id => |id| {
            if (std.mem.indexOfScalar(u8, id, ':')) |colon| {
                namespace = id[0..colon];
                file_path = id[colon + 1 ..];
            } else {
                file_path = id;
            }
            var segments = std.mem.splitScalar(u8, file_path, '/');
            const is_valid = while (segments.next()) |segment| {
                if (!Config.isValidResourceName(segment)) break false;
            } else Config.isValidResourceName(namespace);
            if (!is_valid) return self.addError("data file id '{s}' must only use a-z, 0-9, '_', '.', '-' and '/', with one ':' after the namespace", .{id});
        },
    }

    const is_hook_tag = std.mem.eql(u8, folder, "tags/function") and std.mem.eql(u8, namespace, "minecraft") and
        (std.mem.eql(u8, file_path, "load") or std.mem.eql(u8, file_path, "tick"));
    if (is_hook_tag) return self.addError("Poplar writes the minecraft:{s} function tag. Use 'mcfun {s}'", .{ file_path, file_path });

    const full_path = try std.fmt.allocPrint(self.gpa, "data/{s}/{s}/{s}.json", .{ namespace, folder, file_path });
    const location = try std.fmt.allocPrint(self.gpa, "{s}:{d}", .{ self.position.path, data_file.line });
    const path_entry = try self.data_file_paths.getOrPut(self.gpa, full_path);
    if (path_entry.found_existing) return self.addError("{s} '{s}:{s}' is already declared at {s}", .{ data_file.type_word, namespace, file_path, path_entry.value_ptr.* });
    path_entry.value_ptr.* = location;

    // A data file in the namespace of its file can be named in Minecraft text: `self:isSitting`.
    const is_own = std.mem.eql(u8, namespace, self.scope.output_namespace orelse self.namespace);
    if (is_own) {
        const name = switch (data_file.name) {
            .identifier => |identifier| identifier,
            .id => file_path,
        };
        try self.data_file_names.put(self.gpa, try qualifiedKey(self, self.scope.namespace, name), file_path);
    }

    if (data_file.name == .identifier) {
        const id = try std.fmt.allocPrint(self.gpa, "{s}:{s}", .{ namespace, file_path });
        const entry = try self.named_data_files.getOrPut(self.gpa, try qualifiedKey(self, self.scope.namespace, data_file.name.identifier));
        if (entry.found_existing) return self.addError("'{s}' is already the name of another data file", .{data_file.name.identifier});
        entry.value_ptr.* = .{ .type_word = data_file.type_word, .id = id, .path = self.position.path, .line = data_file.line };
    }

    if (try jsonError(self, data_file)) |position| {
        self.position.line = position.line;
        self.position.column = position.column;
        return self.addError("invalid JSON in {s} '{s}'", .{ data_file.type_word, file_path });
    }

    try self.data_files.append(self.gpa, .{
        .namespace = namespace,
        .folder = folder,
        .path = file_path,
        .json = try std.fmt.allocPrint(self.gpa, "{s}\n", .{data_file.json}),
    });
}

pub const JsonPosition = struct { line: usize, column: usize };

// Where the JSON body stops being valid, as a line and column in the source file.
pub fn jsonError(self: *Compiler, data_file: Ast.DataFile) Compiler.CompileError!?JsonPosition {
    var scanner: std.json.Scanner = .initCompleteInput(self.gpa, data_file.json);
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
        .line = data_file.json_line + json_line - 1,
        .column = if (json_line == 1) data_file.json_column + column - 1 else column,
    };
}

pub const Suggestion = struct {
    closest: ?[]const u8,

    pub fn format(self: Suggestion, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        if (self.closest) |closest| try writer.print(". Did you mean '{s}'?", .{closest});
    }
};

// A name that the project and std both define is reported in the project file, where it can be renamed.
// Otherwise the later definition is reported.
pub fn addDuplicateError(self: *Compiler, existing: Compiler.Located, later: Compiler.Located) Compiler.CompileError!void {
    const project_side, const other = if (existing.origin != .std and later.origin == .std) .{ existing, later } else .{ later, existing };
    self.position.path = project_side.path;
    self.position.line = project_side.function.line;
    self.position.column = null;
    if (other.origin == .std and project_side.origin != .std) {
        return self.addError("function '{s}' is already defined in {s}:{d}. Rename yours", .{ later.function.name, other.path, other.function.line });
    }
    try self.addError("function '{s}' is already defined at {s}:{d}", .{ later.function.name, other.path, other.function.line });
}

pub fn addGlobal(self: *Compiler, decl: Ast.VarDecl) Compiler.CompileError!void {
    if (decl.target.namespace) |namespace| return self.addError("'{s}:' cannot be declared here. Declare it in a file with 'namespace {s};'", .{ namespace, namespace });
    switch (decl.target.storage) {
        .score => {},
        .compile_time => return self.addError("only score (#) and data ($) variables can be declared at the top level", .{}),
        .data => return addDataGlobal(self, decl),
        .entity_data => return self.addError("entity data cannot be declared. Set it in an mcfun: '@s.$path = ...;'", .{}),
    }

    var env: Environment = .{};
    const value = try Values.evaluate(self, decl.value, &env) orelse return;
    const initial_value = try Scores.toScoreValue(self, value) orelse return;

    const entry = try self.globals.getOrPut(self.gpa, try qualifiedKey(self, self.scope.namespace, decl.target.name));
    if (entry.found_existing) {
        const existing = entry.value_ptr.*;
        return self.addError("score '#{s}' is already declared at {s}:{d}", .{ decl.target.name, existing.path, existing.line });
    }

    entry.value_ptr.* = .{
        .path = self.position.path,
        .line = self.position.line,
        .initial_value = initial_value,
        .name = decl.target.name,
        .output_namespace = self.scope.output_namespace,
    };
}

pub fn addDataGlobal(self: *Compiler, decl: Ast.VarDecl) Compiler.CompileError!void {
    if (Compiler.pathRoot(decl.target.name).len != decl.target.name.len) {
        return self.addError("'var' declares a whole variable. Set '${s}' in an mcfun", .{decl.target.name});
    }
    var env: Environment = .{};
    const expression, const cast_type = Data.splitCast(decl.value);
    const value = try Values.evaluate(self, expression, &env) orelse return;
    if (value == .null) return self.addError("a data variable cannot start as null", .{});
    const initial_snbt = try Data.castSnbt(self, value, cast_type) orelse return;

    const entry = try self.data_globals.getOrPut(self.gpa, try qualifiedKey(self, self.scope.namespace, decl.target.name));
    if (entry.found_existing) {
        const existing = entry.value_ptr.*;
        return self.addError("data '${s}' is already declared at {s}:{d}", .{ decl.target.name, existing.path, existing.line });
    }

    entry.value_ptr.* = .{
        .path = self.position.path,
        .line = self.position.line,
        .initial_snbt = initial_snbt,
        .name = decl.target.name,
        .output_namespace = self.scope.output_namespace,
        .storage = Data.storageOf(self.scope.namespace),
    };
}

// The mcfun whose return value is used, for example `double` in `#y = double();`.
pub fn findMcfn(self: *Compiler, call: Ast.Call) Compiler.CompileError!?FoundMcfun {
    if (call.callee.kind == .identifier) return findFunction(self, call.callee.kind.identifier);
    try self.addError("only an mcfun call can be used as a runtime value", .{});
    return null;
}

pub const FoundMcfun = struct {
    // `combat:heal`, the key in `functions` and `mcfun_calls`.
    key: []const u8,
    located: Compiler.Located,
};

// `heal` in this namespace or `magic:heal` in an imported one. Null after an error.
pub fn findFunction(self: *Compiler, identifier: Ast.Identifier) Compiler.CompileError!?FoundMcfun {
    const namespace = try resolveNamespace(self, identifier.namespace) orelse return null;
    const function_key = try qualifiedKey(self, namespace, identifier.name);
    const located = self.functions.get(function_key) orelse {
        try self.addError("unknown function '{s}'", .{identifier.name});
        return null;
    };
    return .{ .key = function_key, .located = located };
}

// The namespaces other than the pack namespace that have mcfuns: each one gets its own `poplar.<ns>` objective for temps and locals.
pub fn outputNamespaces(self: *Compiler) Compiler.CompileError![]const []const u8 {
    var namespaces: std.StringArrayHashMapUnmanaged(void) = .empty;
    for (self.functions.values()) |located| {
        if (outputNamespace(self, located.namespace)) |namespace| try namespaces.put(self.gpa, namespace, {});
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
    try std.testing.expectEqual(6, errors[1].line);
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
    const command_tree = try arena.allocator().create(Commands);
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

    const load = try Writer.renderFunction(arena.allocator(), "ns", program.load.?);
    try std.testing.expect(std.mem.endsWith(u8, load, "function magic:load\nfunction ns:load\n"));
}
