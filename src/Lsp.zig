const std = @import("std");
const builtin = @import("builtin");
const lsp = @import("lsp");
const build_options = @import("build_options");
const ast = @import("ast.zig");
const CommandTree = @import("CommandTree.zig");
const Compiler = @import("Compiler.zig");
const Config = @import("Config.zig");
const data_folders = @import("data_folders.zig");
const Environment = @import("Environment.zig");
const project = @import("project.zig");
const Token = @import("Token.zig");

const Lsp = @This();

/// The last compile of one project. Hover, definition and completion read it.
const Analysis = struct {
    arena: std.heap.ArenaAllocator,
    project_root: []const u8,
    result: project.Result,

    fn contains(analysis: *const Analysis, path: []const u8) bool {
        for (analysis.result.files.values()) |file_path| {
            if (std.mem.eql(u8, file_path, path)) return true;
        }
        return false;
    }

    fn displayPath(analysis: *const Analysis, path: []const u8) ?[]const u8 {
        for (analysis.result.files.keys(), analysis.result.files.values()) |display_path, file_path| {
            if (std.mem.eql(u8, file_path, path)) return display_path;
        }
        return null;
    }

    fn absolutePath(analysis: *Analysis, display_path: []const u8) ![]const u8 {
        if (analysis.result.files.get(display_path)) |path| return path;
        return std.fs.path.join(analysis.arena.allocator(), &.{ analysis.project_root, display_path });
    }
};

const Builtin = struct {
    name: []const u8,
    signature: []const u8,
    doc: []const u8,
};

const builtins = [_]Builtin{
    .{ .name = "append", .signature = "append($list, value)", .doc = "Adds a value at the end of a list." },
    .{ .name = "prepend", .signature = "prepend($list, value)", .doc = "Adds a value at the start of a list." },
    .{ .name = "insert", .signature = "insert($list, index, value)", .doc = "Adds a value at an index. The index is a compile-time int." },
    .{ .name = "remove", .signature = "remove($list, index)", .doc = "Removes the value at an index. The index is a compile-time int." },
    .{ .name = "len", .signature = "len(value)", .doc = "The size of a list, compound or string." },
    .{ .name = "text", .signature = "text(value)", .doc = "A text part that names a score or data. The game reads the value when it shows the text." },
    .{ .name = "onEvent", .signature = "onEvent(criteria, callback)", .doc = "Runs the mcfun `callback` as a player each time the criteria counts for that player. Only in `mcfun load`." },
    .{ .name = "onTrigger", .signature = "onTrigger(name, callback)", .doc = "Makes `/trigger name` run the mcfun `callback` as the player who used it. Only in `mcfun load`." },
    .{ .name = "onDeath", .signature = "onDeath(callback)", .doc = "Runs the mcfun `callback` as a player when the player dies. Only in `mcfun load`." },
    .{ .name = "onFirstJoin", .signature = "onFirstJoin(callback)", .doc = "Runs the mcfun `callback` as a player the first time the player joins the world. Only in `mcfun load`." },
    .{ .name = "onJoin", .signature = "onJoin(callback)", .doc = "Runs the mcfun `callback` as a player each time the player joins, the first time too. Only in `mcfun load`." },
    .{ .name = "onRespawn", .signature = "onRespawn(callback)", .doc = "Runs the mcfun `callback` as a player when a dead player is alive again. Only in `mcfun load`." },
    .{ .name = "slice", .signature = "slice(text, start, end)", .doc = "A substring: from `start` (included) to `end` (not included, optional). Negative bounds count from the end. One `data modify ... set string` command." },
    .{ .name = "str", .signature = "str(value)", .doc = "A number, score or math as a string: `$label = str(#kills);`." },
    .{ .name = "startsWith", .signature = "startsWith(text, \"prefix\")", .doc = "A condition: the text starts with a constant prefix." },
    .{ .name = "endsWith", .signature = "endsWith(text, \"suffix\")", .doc = "A condition: the text ends with a constant suffix." },
};

comptime {
    std.debug.assert(builtins.len == Compiler.builtin_names.len);
}

gpa: std.mem.Allocator,
io: std.Io,
transport: *lsp.Transport,
std_path: []const u8,
offset_encoding: lsp.offsets.Encoding = .@"utf-16",
/// URI → the text in the editor, which can be unsaved.
documents: std.StringHashMapUnmanaged([]u8) = .empty,
/// URI → the project root, for each file that has diagnostics in the editor now.
published: std.StringHashMapUnmanaged([]const u8) = .empty,
command_tree_arena: std.heap.ArenaAllocator,
command_tree: ?CommandTree = null,
analysis: ?*Analysis = null,

pub fn init(gpa: std.mem.Allocator, io: std.Io, transport: *lsp.Transport, std_path: []const u8) Lsp {
    return .{
        .gpa = gpa,
        .io = io,
        .transport = transport,
        .std_path = std_path,
        .command_tree_arena = .init(gpa),
    };
}

pub fn deinit(self: *Lsp) void {
    var documents = self.documents.iterator();
    while (documents.next()) |entry| {
        self.gpa.free(entry.key_ptr.*);
        self.gpa.free(entry.value_ptr.*);
    }
    self.documents.deinit(self.gpa);
    var published = self.published.iterator();
    while (published.next()) |entry| {
        self.gpa.free(entry.key_ptr.*);
        self.gpa.free(entry.value_ptr.*);
    }
    self.published.deinit(self.gpa);
    self.freeAnalysis();
    self.command_tree_arena.deinit();
}

fn freeAnalysis(self: *Lsp) void {
    const analysis = self.analysis orelse return;
    analysis.arena.deinit();
    self.gpa.destroy(analysis);
    self.analysis = null;
}

pub fn initialize(self: *Lsp, _: std.mem.Allocator, params: lsp.types.InitializeParams) lsp.types.InitializeResult {
    if (params.capabilities.general) |general| {
        for (general.positionEncodings orelse &.{}) |encoding| {
            self.offset_encoding = switch (encoding) {
                .@"utf-8" => .@"utf-8",
                .@"utf-16" => .@"utf-16",
                .@"utf-32" => .@"utf-32",
                .custom_value => continue,
            };
            break;
        }
    }

    const capabilities: lsp.types.ServerCapabilities = .{
        .positionEncoding = switch (self.offset_encoding) {
            .@"utf-8" => .@"utf-8",
            .@"utf-16" => .@"utf-16",
            .@"utf-32" => .@"utf-32",
        },
        .textDocumentSync = .{ .text_document_sync_options = .{ .openClose = true, .change = .Full } },
        .hoverProvider = .{ .bool = true },
        .definitionProvider = .{ .bool = true },
        .completionProvider = .{ .triggerCharacters = &.{ "#", "$" } },
    };
    if (builtin.mode == .debug) lsp.basic_server.validateServerCapabilities(Lsp, capabilities);

    return .{
        .serverInfo = .{ .name = "poplar", .version = build_options.version },
        .capabilities = capabilities,
    };
}

pub fn shutdown(_: *Lsp, _: std.mem.Allocator, _: void) ?void {
    return null;
}

/// `lsp.basic_server.run` returns after this message, but only if the Handler has this function.
pub fn exit(_: *Lsp, _: std.mem.Allocator, _: void) void {}

pub fn @"textDocument/didOpen"(self: *Lsp, arena: std.mem.Allocator, params: lsp.types.TextDocument.DidOpenParams) !void {
    const text = try self.gpa.dupe(u8, params.textDocument.text);
    errdefer self.gpa.free(text);
    const entry = try self.documents.getOrPut(self.gpa, params.textDocument.uri);
    if (entry.found_existing) {
        self.gpa.free(entry.value_ptr.*);
    } else {
        entry.key_ptr.* = try self.gpa.dupe(u8, params.textDocument.uri);
    }
    entry.value_ptr.* = text;
    try self.check(arena, params.textDocument.uri);
}

pub fn @"textDocument/didChange"(self: *Lsp, arena: std.mem.Allocator, params: lsp.types.TextDocument.DidChangeParams) !void {
    const current_text = self.documents.getPtr(params.textDocument.uri) orelse return;
    var buffer: std.ArrayList(u8) = .fromOwnedSlice(current_text.*);
    errdefer current_text.* = buffer.items;
    for (params.contentChanges) |content_change| {
        switch (content_change) {
            .text_document_content_change_whole_document => |change| {
                buffer.clearRetainingCapacity();
                try buffer.appendSlice(self.gpa, change.text);
            },
            .text_document_content_change_partial => |change| {
                const loc = lsp.offsets.rangeToLoc(buffer.items, change.range, self.offset_encoding);
                try buffer.replaceRange(self.gpa, loc.start, loc.end - loc.start, change.text);
            },
        }
    }
    current_text.* = try buffer.toOwnedSlice(self.gpa);
    try self.check(arena, params.textDocument.uri);
}

pub fn @"textDocument/didClose"(self: *Lsp, arena: std.mem.Allocator, params: lsp.types.TextDocument.DidCloseParams) !void {
    const entry = self.documents.fetchRemove(params.textDocument.uri) orelse return;
    self.gpa.free(entry.key);
    self.gpa.free(entry.value);
    // The file on disk counts again.
    try self.check(arena, params.textDocument.uri);
}

pub fn @"textDocument/hover"(self: *Lsp, arena: std.mem.Allocator, params: lsp.types.Hover.Params) !?lsp.types.Hover {
    const analysis = try self.analysisFor(arena, params.textDocument.uri) orelse return null;
    const text = self.documents.get(params.textDocument.uri) orelse return null;
    const word = wordAt(text, lsp.offsets.positionToIndex(text, params.position, self.offset_encoding)) orelse return null;
    const place = try placeOf(arena, analysis, params.textDocument.uri, params.position);
    const markdown = try self.describe(arena, analysis, word, place) orelse return null;
    return .{ .contents = .{ .markup_content = .{ .kind = .markdown, .value = markdown } } };
}

pub fn @"textDocument/definition"(self: *Lsp, arena: std.mem.Allocator, params: lsp.types.Definition.Params) !lsp.ResultType("textDocument/definition") {
    const analysis = try self.analysisFor(arena, params.textDocument.uri) orelse return null;
    const text = self.documents.get(params.textDocument.uri) orelse return null;
    const word = wordAt(text, lsp.offsets.positionToIndex(text, params.position, self.offset_encoding)) orelse return null;
    const compiler = analysis.result.compiler orelse return null;

    const place = try placeOf(arena, analysis, params.textDocument.uri, params.position);
    const local_kind: ?Environment.Local.Kind = switch (word.kind) {
        .score => .score,
        .data => .data,
        else => null,
    };
    const local = if (local_kind != null and word.namespace == null) try findLocal(arena, compiler, place, local_kind.?, Compiler.pathRoot(word.text)) else null;
    const key = try wordKey(arena, compiler, place, word, Compiler.pathRoot(word.text));

    const display_path: []const u8, const line: usize = if (local) |found| .{ found.path, found.line } else switch (word.kind) {
        .score => if (compiler.globals.get(key)) |global| .{ global.path, global.line } else return null,
        .data => if (compiler.data_globals.get(key)) |global| .{ global.path, global.line } else return null,
        .entity_data => return null,
        .name => if (compiler.mcfuns.get(key)) |declaration|
            .{ declaration.path, declaration.mcfun.line }
        else if (compiler.named_data_files.get(key)) |data_file|
            .{ data_file.path, data_file.line }
        else
            return null,
    };
    const position: lsp.types.Position = .{ .line = @intCast(line -| 1), .character = 0 };
    return .{ .definition = .{ .location = .{
        .uri = try pathToUri(arena, try analysis.absolutePath(display_path)),
        .range = .{ .start = position, .end = position },
    } } };
}

pub fn @"textDocument/completion"(self: *Lsp, arena: std.mem.Allocator, params: lsp.types.completion.Params) !lsp.ResultType("textDocument/completion") {
    const text = self.documents.get(params.textDocument.uri) orelse return null;
    var start = lsp.offsets.positionToIndex(text, params.position, self.offset_encoding);
    while (start > 0 and isNameChar(text[start - 1])) start -= 1;
    const sigil: u8 = if (start > 0) text[start - 1] else 0;

    var items: std.ArrayList(lsp.types.completion.Item) = .empty;
    const analysis = try self.analysisFor(arena, params.textDocument.uri);
    const compiler = if (analysis) |found| found.result.compiler else null;
    const place: ?Place = if (analysis) |found| try placeOf(arena, found, params.textDocument.uri, params.position) else null;

    // A name in the file's own namespace without its `ns:`, any other with it.
    const own: []const u8 = if (compiler) |found| try std.fmt.allocPrint(arena, "{s}:", .{found.file_namespaces.get(place.?.path) orelse found.pack_namespace}) else "";
    switch (sigil) {
        '#' => if (compiler) |found| {
            for (found.globals.keys()) |name| try items.append(arena, .{ .label = completionLabel(name, own), .kind = .Variable, .detail = "score" });
            for (try visibleLocals(arena, found, place.?, .score)) |local| {
                try items.append(arena, .{ .label = local.name, .kind = .Variable, .detail = "local score" });
            }
        },
        '$' => if (compiler) |found| {
            var globals = found.data_globals.iterator();
            while (globals.next()) |entry| {
                try items.append(arena, .{ .label = completionLabel(entry.key_ptr.*, own), .kind = .Variable, .detail = "data" });
            }
            for (try visibleLocals(arena, found, place.?, .data)) |local| {
                try items.append(arena, .{ .label = local.name, .kind = .Variable, .detail = "local data" });
            }
        },
        else => {
            // A word at the start of a line, with no indent, is likely at the top level.
            if (start == 0 or text[start - 1] == '\n') {
                for (data_folders.folders.keys()) |word| try items.append(arena, .{ .label = word, .kind = .Keyword, .detail = "data file" });
            }
            for (Token.keywords.keys()) |keyword| try items.append(arena, .{ .label = keyword, .kind = .Keyword });
            for (builtins) |each| try items.append(arena, .{ .label = each.name, .kind = .Function, .detail = each.signature });
            if (compiler) |found| {
                var data_files = found.named_data_files.iterator();
                while (data_files.next()) |entry| {
                    try items.append(arena, .{ .label = completionLabel(entry.key_ptr.*, own), .kind = .Constant, .detail = entry.value_ptr.id });
                }
                var functions = found.mcfuns.iterator();
                while (functions.next()) |entry| {
                    try items.append(arena, .{ .label = completionLabel(entry.key_ptr.*, own), .kind = .Function, .detail = try signature(arena, entry.value_ptr.mcfun) });
                }
            }
        },
    }
    return .{ .completion_items = items.items };
}

/// A name of this namespace without its `ns:`, any other with it: `heal`, `magic:fireball`.
fn completionLabel(key: []const u8, own_prefix: []const u8) []const u8 {
    return if (std.mem.startsWith(u8, key, own_prefix)) key[own_prefix.len..] else key;
}

/// The server sends no requests, so no response is expected.
pub fn onResponse(_: *Lsp, _: std.mem.Allocator, response: lsp.JsonRPCMessage.Response) void {
    std.log.warn("unexpected response from the editor: {?}", .{response.id});
}

/// Compiles the project of `uri` with the open documents and shows its errors in the editor.
fn check(self: *Lsp, arena: std.mem.Allocator, uri: []const u8) !void {
    const analysis = try self.analyze(arena, uri) orelse return;

    var by_uri: std.StringArrayHashMapUnmanaged(std.ArrayList(lsp.types.Diagnostic)) = .empty;
    for (analysis.result.diagnostics) |diagnostic| {
        const path = if (diagnostic.path.len == 0)
            try uriToPath(arena, uri) orelse continue
        else
            try analysis.absolutePath(diagnostic.path);
        const text = try self.textOf(arena, path);
        const entry = try by_uri.getOrPutValue(arena, try pathToUri(arena, path), .empty);
        try entry.value_ptr.append(arena, .{
            .range = diagnosticRange(text, diagnostic.line, diagnostic.column, self.offset_encoding),
            .severity = .Error,
            .source = "poplar",
            .message = .{ .string = diagnostic.message },
        });
    }

    for (by_uri.keys(), by_uri.values()) |file_uri, diagnostics| {
        try self.publish(arena, file_uri, diagnostics.items);
        const entry = try self.published.getOrPut(self.gpa, file_uri);
        if (entry.found_existing) {
            self.gpa.free(entry.value_ptr.*);
        } else {
            entry.key_ptr.* = try self.gpa.dupe(u8, file_uri);
        }
        entry.value_ptr.* = try self.gpa.dupe(u8, analysis.project_root);
    }

    // Files of this project that had errors and have none now get an empty list, so their marks go away.
    var fixed: std.ArrayList([]const u8) = .empty;
    var published = self.published.iterator();
    while (published.next()) |entry| {
        if (std.mem.eql(u8, entry.value_ptr.*, analysis.project_root) and !by_uri.contains(entry.key_ptr.*)) {
            try fixed.append(arena, entry.key_ptr.*);
        }
    }
    for (fixed.items) |file_uri| {
        try self.publish(arena, file_uri, &.{});
        const entry = self.published.fetchRemove(file_uri).?;
        self.gpa.free(entry.key);
        self.gpa.free(entry.value);
    }
}

fn publish(self: *Lsp, arena: std.mem.Allocator, uri: []const u8, diagnostics: []const lsp.types.Diagnostic) !void {
    try self.transport.writeNotification(
        self.io,
        arena,
        "textDocument/publishDiagnostics",
        lsp.types.publish_diagnostics.Params,
        .{ .uri = uri, .diagnostics = diagnostics },
        .{ .emit_null_optional_fields = false },
    );
}

/// The last analysis if it has the file of `uri`, else a new one.
fn analysisFor(self: *Lsp, arena: std.mem.Allocator, uri: []const u8) !?*Analysis {
    const path = try uriToPath(arena, uri) orelse return null;
    if (self.analysis) |analysis| {
        if (analysis.contains(path)) return analysis;
    }
    return self.analyze(arena, uri);
}

/// Compiles the project that has the file of `uri`. Null if the file is in no project.
fn analyze(self: *Lsp, arena: std.mem.Allocator, uri: []const u8) !?*Analysis {
    const path = try uriToPath(arena, uri) orelse return null;
    const project_root = if (self.analysis != null and self.analysis.?.contains(path))
        self.analysis.?.project_root
    else
        try self.findProjectRoot(arena, path) orelse return null;

    const analysis = try self.gpa.create(Analysis);
    errdefer self.gpa.destroy(analysis);
    analysis.arena = .init(self.gpa);
    errdefer analysis.arena.deinit();
    const analysis_arena = analysis.arena.allocator();
    analysis.project_root = try analysis_arena.dupe(u8, project_root);

    // The texts are copied, because the compiler keeps slices of them after the editor changes the document.
    var overlay: std.StringHashMapUnmanaged([]const u8) = .empty;
    var documents = self.documents.iterator();
    while (documents.next()) |entry| {
        const document_path = try uriToPath(analysis_arena, entry.key_ptr.*) orelse continue;
        try overlay.put(analysis_arena, document_path, try analysis_arena.dupe(u8, entry.value_ptr.*));
    }

    if (self.command_tree == null) self.command_tree = try CommandTree.load(self.command_tree_arena.allocator());
    analysis.result = try project.build(analysis_arena, self.io, analysis.project_root, .{
        .std_path = self.std_path,
        .mode = .check,
        .overlay = &overlay,
        .command_tree = &self.command_tree.?,
    });

    self.freeAnalysis();
    self.analysis = analysis;
    return analysis;
}

/// The nearest folder with `poplar.json`, or else the folder that holds the `src/` that the file is in.
fn findProjectRoot(self: *Lsp, arena: std.mem.Allocator, file_path: []const u8) !?[]const u8 {
    var above_src: ?[]const u8 = null;
    var directory = std.fs.path.dirname(file_path);
    while (directory) |current| : (directory = std.fs.path.dirname(current)) {
        const config_path = try std.fs.path.join(arena, &.{ current, Config.file_name });
        if (std.Io.Dir.accessAbsolute(self.io, config_path, .{})) |_| return current else |_| {}
        if (above_src == null and std.mem.eql(u8, std.fs.path.basename(current), "src")) above_src = std.fs.path.dirname(current);
    }
    return above_src;
}

/// The text of a file: from the editor when it is open, else from the disk.
fn textOf(self: *Lsp, arena: std.mem.Allocator, path: []const u8) ![]const u8 {
    if (self.documents.get(try pathToUri(arena, path))) |text| return text;
    return std.Io.Dir.cwd().readFileAlloc(self.io, path, arena, .unlimited) catch "";
}

const Word = struct {
    kind: enum { name, score, data, entity_data },
    /// Without the sigil. A data path goes up to the end of the part under the cursor: `stats.maxHp`.
    text: []const u8,
    /// `magic` in `magic:heal` or `#magic:mana`.
    namespace: ?[]const u8 = null,
};

/// The name under the cursor, with its sigil: `#hp`, `$stats.maxHp`, `@s.$Health` or `clamp`.
fn wordAt(text: []const u8, index: usize) ?Word {
    var start = @min(index, text.len);
    var end = start;
    while (start > 0 and isNameChar(text[start - 1])) start -= 1;
    while (end < text.len and isNameChar(text[end])) end += 1;
    if (start == end) return null;

    var path_start = start;
    while (path_start > 0 and isPathChar(text[path_start - 1])) path_start -= 1;
    const path_namespace, const path_sigil = namespaceBefore(text, path_start);
    if (path_sigil > 0 and text[path_sigil - 1] == '$') {
        const is_entity = path_namespace == null and path_sigil > 1 and text[path_sigil - 2] == '.';
        return .{ .kind = if (is_entity) .entity_data else .data, .text = text[path_start..end], .namespace = path_namespace };
    }
    const namespace, const sigil = namespaceBefore(text, start);
    if (sigil > 0 and text[sigil - 1] == '#') return .{ .kind = .score, .text = text[start..end], .namespace = namespace };
    return .{ .kind = .name, .text = text[start..end], .namespace = namespace };
}

/// `magic:` right before `start`: the namespace, and where it starts. Otherwise null and `start`.
fn namespaceBefore(text: []const u8, start: usize) struct { ?[]const u8, usize } {
    if (start == 0 or text[start - 1] != ':') return .{ null, start };
    var namespace_start = start - 1;
    while (namespace_start > 0 and (std.ascii.isLower(text[namespace_start - 1]) or std.ascii.isDigit(text[namespace_start - 1]) or text[namespace_start - 1] == '_' or text[namespace_start - 1] == '.')) namespace_start -= 1;
    if (namespace_start == start - 1) return .{ null, start };
    return .{ text[namespace_start .. start - 1], namespace_start };
}

/// `combat:heal`: how the compiler keys the declaration that `word` names, from the namespace of its file.
fn wordKey(arena: std.mem.Allocator, compiler: *const Compiler, place: Place, word: Word, name: []const u8) ![]const u8 {
    const namespace = word.namespace orelse compiler.file_namespaces.get(place.path) orelse compiler.pack_namespace;
    return std.fmt.allocPrint(arena, "{s}:{s}", .{ namespace, name });
}

fn isNameChar(char: u8) bool {
    return std.ascii.isAlphanumeric(char) or char == '_';
}

fn isPathChar(char: u8) bool {
    return isNameChar(char) or char == '.' or char == '[' or char == ']' or char == '-';
}

/// The cursor in the compiler's terms: a display path such as `src/main.poplar`, and a line that starts at 1.
const Place = struct {
    path: []const u8,
    line: usize,
};

fn placeOf(arena: std.mem.Allocator, analysis: *const Analysis, uri: []const u8, position: lsp.types.Position) !Place {
    const path = try uriToPath(arena, uri) orelse "";
    return .{ .path = analysis.displayPath(path) orelse "", .line = position.line + 1 };
}

/// The function that contains `place`: the last one that starts above it in the same file.
fn enclosingMcfun(compiler: *const Compiler, place: Place) ?[]const u8 {
    var nearest: ?*const ast.Mcfun = null;
    for (compiler.mcfuns.values()) |declaration| {
        if (!std.mem.eql(u8, declaration.path, place.path) or declaration.mcfun.line > place.line) continue;
        if (nearest == null or declaration.mcfun.line > nearest.?.line) nearest = declaration.mcfun;
    }
    return if (nearest) |mcfun| mcfun.name else null;
}

/// The local `name` that is visible at `place`: the nearest one declared above it in the same function.
fn findLocal(arena: std.mem.Allocator, compiler: *const Compiler, place: Place, kind: Environment.Local.Kind, name: []const u8) !?Compiler.LocalVariable {
    var found: ?Compiler.LocalVariable = null;
    for (try visibleLocals(arena, compiler, place, kind)) |local| {
        if (!std.mem.eql(u8, local.name, name)) continue;
        if (found == null or local.line > found.?.line) found = local;
    }
    return found;
}

/// The locals of the function at `place` that are declared above it. Block scope is not checked.
fn visibleLocals(arena: std.mem.Allocator, compiler: *const Compiler, place: Place, kind: Environment.Local.Kind) ![]const Compiler.LocalVariable {
    const owner = enclosingMcfun(compiler, place) orelse return &.{};
    var visible: std.ArrayList(Compiler.LocalVariable) = .empty;
    for (compiler.locals.items) |local| {
        if (local.local.kind != kind or local.line > place.line) continue;
        if (!std.mem.eql(u8, local.local.owner, owner) or !std.mem.eql(u8, local.path, place.path)) continue;
        try visible.append(arena, local);
    }
    return visible.items;
}

/// The hover text for a word, in Markdown.
fn describe(self: *Lsp, arena: std.mem.Allocator, analysis: *Analysis, word: Word, place: Place) !?[]const u8 {
    if (word.kind == .entity_data) {
        return try std.fmt.allocPrint(arena, "Entity NBT `{s}`. The compiler does not check the path.", .{word.text});
    }
    if (word.kind == .name) {
        for (builtins) |each| {
            if (std.mem.eql(u8, each.name, word.text)) return try std.fmt.allocPrint(arena, "```poplar\n{s}\n```\n{s}", .{ each.signature, each.doc });
        }
    }
    const compiler = analysis.result.compiler orelse return null;
    const key = try wordKey(arena, compiler, place, word, Compiler.pathRoot(word.text));
    switch (word.kind) {
        .score => {
            if (word.namespace == null) if (try findLocal(arena, compiler, place, .score, word.text)) |local| {
                return try std.fmt.allocPrint(arena, "```poplar\nvar #{s}\n```\nA local in `{s}`: the fake player `{s}`.", .{ word.text, local.local.owner, local.local.generated_name });
            };
            const global = compiler.globals.get(key) orelse return null;
            return try std.fmt.allocPrint(arena, "```poplar\nvar #{s} = {d};\n```\nA score in the objective `{s}.{s}`.", .{ word.text, global.initial_value, global.output_namespace orelse compiler.pack_namespace, global.name });
        },
        .data => {
            const root = Compiler.pathRoot(word.text);
            if (word.namespace == null) if (try findLocal(arena, compiler, place, .data, root)) |local| {
                return try std.fmt.allocPrint(arena, "```poplar\nvar ${s}\n```\nA local in `{s}`: the key `{s}`.", .{ root, local.local.owner, local.local.generated_name });
            };
            const global = compiler.data_globals.get(key) orelse return null;
            return try std.fmt.allocPrint(arena, "```poplar\nvar ${s} = {s};\n```\nIn the storage `{s}:data`.", .{ root, global.initial_snbt, global.output_namespace orelse compiler.pack_namespace });
        },
        .name => {
            if (compiler.named_data_files.get(key)) |data_file| {
                return try std.fmt.allocPrint(arena, "```poplar\n{s} {s}\n```\nThe data file `{s}`.", .{ data_file.type_word, word.text, data_file.id });
            }
            const declaration = compiler.mcfuns.get(key) orelse return null;
            const source = try self.textOf(arena, try analysis.absolutePath(declaration.path));
            const doc = try docComment(arena, source, declaration.mcfun.line);
            return try std.fmt.allocPrint(arena, "```poplar\n{s}\n```\n{s}", .{ try signature(arena, declaration.mcfun), doc });
        },
        .entity_data => unreachable,
    }
}

/// `mcfun clamp() with {x, low, high}`: the macro keys that the body uses.
fn signature(arena: std.mem.Allocator, mcfun: *const ast.Mcfun) ![]const u8 {
    var keys: std.StringArrayHashMapUnmanaged(void) = .empty;
    try Compiler.collectMacroKeys(arena, mcfun.body, &keys);
    if (keys.count() == 0) return std.fmt.allocPrint(arena, "mcfun {s}()", .{mcfun.name});
    return std.fmt.allocPrint(arena, "mcfun {s}() with {{{s}}}", .{ mcfun.name, try std.mem.join(arena, ", ", keys.keys()) });
}

/// The `//` lines right above line `line` (1-based), without the slashes.
fn docComment(arena: std.mem.Allocator, source: []const u8, line: usize) ![]const u8 {
    var lines: std.ArrayList([]const u8) = .empty;
    var all_lines = std.mem.splitScalar(u8, source, '\n');
    var number: usize = 1;
    while (all_lines.next()) |each| : (number += 1) {
        if (number >= line) break;
        const trimmed = std.mem.trim(u8, each, " \t\r");
        if (std.mem.startsWith(u8, trimmed, "//")) {
            try lines.append(arena, std.mem.trim(u8, trimmed[2..], " "));
        } else {
            lines.clearRetainingCapacity();
        }
    }
    return std.mem.join(arena, "\n", lines.items);
}

/// Poplar lines and columns start at 1 and count bytes. The range ends at the end of the word at the start,
/// or covers the line when there is no column.
fn diagnosticRange(text: []const u8, line: usize, column: ?usize, encoding: lsp.offsets.Encoding) lsp.types.Range {
    if (line == 0) return .{ .start = .{ .line = 0, .character = 0 }, .end = .{ .line = 0, .character = 0 } };

    var line_start: usize = 0;
    var current_line: usize = 1;
    while (current_line < line) : (current_line += 1) {
        const newline = std.mem.indexOfScalarPos(u8, text, line_start, '\n') orelse break;
        line_start = newline + 1;
    }
    const line_end = std.mem.indexOfScalarPos(u8, text, line_start, '\n') orelse text.len;

    var start = line_start;
    var end = line_end;
    if (column) |byte_column| {
        start = @min(line_start + byte_column -| 1, line_end);
        end = start;
        if (end < line_end and !isNameChar(text[end])) end += 1;
        while (end < line_end and isNameChar(text[end])) end += 1;
    } else {
        while (start < line_end and std.ascii.isWhitespace(text[start])) start += 1;
    }
    return .{
        .start = lsp.offsets.indexToPosition(text, start, encoding),
        .end = lsp.offsets.indexToPosition(text, end, encoding),
    };
}

fn uriToPath(arena: std.mem.Allocator, uri: []const u8) !?[]const u8 {
    const prefix = "file://";
    if (!std.mem.startsWith(u8, uri, prefix)) return null;
    const encoded = uri[prefix.len..];
    var path: std.ArrayList(u8) = try .initCapacity(arena, encoded.len);
    var index: usize = 0;
    while (index < encoded.len) : (index += 1) {
        if (encoded[index] == '%' and index + 2 < encoded.len) {
            if (std.fmt.parseInt(u8, encoded[index + 1 .. index + 3], 16)) |byte| {
                path.appendAssumeCapacity(byte);
                index += 2;
                continue;
            } else |_| {}
        }
        path.appendAssumeCapacity(encoded[index]);
    }
    // `file:///c%3A/x` is `C:\x`. Editors differ in the case of the drive letter, and the compiler's paths have a capital.
    if (path.items.len >= 3 and path.items[0] == '/' and isDrivePrefix(path.items[1..3])) {
        const windows_path = path.items[1..];
        windows_path[0] = std.ascii.toUpper(windows_path[0]);
        std.mem.replaceScalar(u8, windows_path, '/', '\\');
        return windows_path;
    }
    return path.items;
}

fn isDrivePrefix(text: []const u8) bool {
    return std.ascii.isAlphabetic(text[0]) and text[1] == ':';
}

fn pathToUri(arena: std.mem.Allocator, path: []const u8) ![]const u8 {
    var uri: std.ArrayList(u8) = .empty;
    try uri.appendSlice(arena, "file://");
    var rest = path;
    const is_windows_path = path.len >= 2 and isDrivePrefix(path[0..2]);
    if (is_windows_path) {
        try uri.print(arena, "/{s}", .{path[0..2]});
        rest = path[2..];
    }
    for (rest) |byte| {
        if (std.ascii.isAlphanumeric(byte) or std.mem.indexOfScalar(u8, "-._~/", byte) != null) {
            try uri.append(arena, byte);
        } else if (byte == '\\' and is_windows_path) {
            try uri.append(arena, '/');
        } else {
            try uri.print(arena, "%{X:0>2}", .{byte});
        }
    }
    return uri.items;
}

test "converts a byte column to a UTF-16 range that ends at the end of the word" {
    const text = "var #é = 1;\n  /say ünknown #hp;\n";
    const range = diagnosticRange(text, 2, 17, .@"utf-16");
    try std.testing.expectEqual(lsp.types.Position{ .line = 1, .character = 15 }, range.start);
    try std.testing.expectEqual(lsp.types.Position{ .line = 1, .character = 18 }, range.end);
}

test "finds the word under the cursor with its sigil" {
    const text = "#a = @s.$Inventory[0].count + $stats.maxHp + clamp(#hp);";
    try std.testing.expectEqualDeep(Word{ .kind = .entity_data, .text = "Inventory[0].count" }, wordAt(text, 24).?);
    try std.testing.expectEqualDeep(Word{ .kind = .data, .text = "stats" }, wordAt(text, 32).?);
    try std.testing.expectEqualDeep(Word{ .kind = .data, .text = "stats.maxHp" }, wordAt(text, 38).?);
    try std.testing.expectEqualDeep(Word{ .kind = .name, .text = "clamp" }, wordAt(text, 46).?);
    try std.testing.expectEqualDeep(Word{ .kind = .score, .text = "hp" }, wordAt(text, 52).?);
}

test "converts Windows paths to URIs and back" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    const windows_path = "C:\\My Packs\\src\\main.poplar";
    try std.testing.expectEqualStrings("file:///C:/My%20Packs/src/main.poplar", try pathToUri(arena.allocator(), windows_path));
    try std.testing.expectEqualStrings(windows_path, (try uriToPath(arena.allocator(), "file:///C:/My%20Packs/src/main.poplar")).?);
    try std.testing.expectEqualStrings(windows_path, (try uriToPath(arena.allocator(), "file:///c%3A/My%20Packs/src/main.poplar")).?);
    try std.testing.expectEqualStrings("/home/me/a b.poplar", (try uriToPath(arena.allocator(), "file:///home/me/a%20b.poplar")).?);
}

/// Collects the messages that the server writes, instead of stdout.
const TestTransport = struct {
    transport: lsp.Transport = .{ .vtable = &.{ .readJsonMessage = readJsonMessage, .writeJsonMessage = writeJsonMessage } },
    written: std.Io.Writer.Allocating,

    fn readJsonMessage(_: *lsp.Transport, _: std.Io, _: std.mem.Allocator) lsp.Transport.ReadError![]u8 {
        return error.EndOfStream;
    }

    fn writeJsonMessage(transport: *lsp.Transport, _: std.Io, json_message: []const u8) lsp.Transport.WriteError!void {
        const self: *TestTransport = @fieldParentPtr("transport", transport);
        self.written.writer.writeAll(json_message) catch return error.NoSpaceLeft;
        self.written.writer.writeAll("\n") catch return error.NoSpaceLeft;
    }
};

test "an open document with an error gets a diagnostic, and loses it when it is fixed" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "src");
    try tmp.dir.writeFile(io, .{ .sub_path = "src/main.poplar", .data = "" });
    try tmp.dir.writeFile(io, .{ .sub_path = "poplar.json", .data = "{\"namespace\": \"test\"}" });
    const project_path = try tmp.dir.realPathFileAlloc(io, ".", arena.allocator());
    const uri = try pathToUri(arena.allocator(), try std.fs.path.join(arena.allocator(), &.{ project_path, "src", "main.poplar" }));

    var transport: TestTransport = .{ .written = .init(std.testing.allocator) };
    defer transport.written.deinit();
    var server: Lsp = .init(std.testing.allocator, io, &transport.transport, "no-std");
    defer server.deinit();

    try server.@"textDocument/didOpen"(arena.allocator(), .{ .textDocument = .{ .uri = uri, .languageId = .{ .custom_value = "poplar" }, .version = 1, .text = "namespace test;\nmcfun f() {\n  #nope = 1;\n}\n" } });
    try std.testing.expect(std.mem.indexOf(u8, transport.written.written(), "\"range\":{\"start\":{\"line\":2,\"character\":2},\"end\":{\"line\":2,\"character\":7}}") != null);

    transport.written.clearRetainingCapacity();
    try server.@"textDocument/didChange"(arena.allocator(), .{
        .textDocument = .{ .uri = uri, .version = 2 },
        .contentChanges = &.{.{ .text_document_content_change_whole_document = .{ .text = "namespace test;\nmcfun f() {}\n" } }},
    });
    try std.testing.expect(std.mem.indexOf(u8, transport.written.written(), "\"diagnostics\":[]") != null);
}
