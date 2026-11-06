const std = @import("std");
const ast = @import("ast.zig");
const CommandTree = @import("CommandTree.zig");
const Diagnostic = @import("Diagnostic.zig");
const Config = @import("Config.zig");
const Environment = @import("Environment.zig");
const ir = @import("ir.zig");
const Lexer = @import("Lexer.zig");
const optimizer = @import("optimizer.zig");
const Parser = @import("Parser.zig");
const datapack_writer = @import("datapack_writer.zig");
const declarations = @import("compiler/declarations.zig");
const load = @import("compiler/load.zig");
const conditions = @import("compiler/conditions.zig");
const minecraft_text = @import("compiler/minecraft_text.zig");
const calls = @import("compiler/calls.zig");
const scores = @import("compiler/scores.zig");
const data = @import("compiler/data.zig");
const values = @import("compiler/values.zig");

pub const builtin_names = calls.builtin_names;

const Compiler = @This();
const Position = Diagnostic.Position;

pub const Error = Diagnostic.Error;

pub const McfunDeclaration = struct {
    path: []const u8,
    mcfun: *const ast.Mcfun,
    origin: Origin,
    /// The namespace of the file, and the namespaces it imports.
    namespace: []const u8,
    imports: []const ast.NamespaceName,
    /// The name in the IR: `combat:heal`, or `heal` in the pack namespace.
    ir_name: []const u8,
};

/// Where a source file comes from: the project's `src/` or the standard library.
pub const Origin = enum { project, std };

/// The namespace of the standard library. Its files are written into the pack namespace, under `std/`.
pub const std_namespace = "std";

/// `onEvent(criteria, callback)`: the game counts the criteria in `<ns>.event_<n>`, and `poplar/tick` runs the callback.
/// `onTrigger(name, callback)` is the same with a `trigger` objective called `name`, so players can run `/trigger <name>`.
pub const Event = struct {
    /// What starts the event. The player events are fixed patterns (see `load.appendEventFunctions`).
    pub const Source = union(enum) {
        /// `onEvent` and `onDeath` count a criteria.
        criteria: []const u8,
        /// The objective name of `onTrigger`. A trigger is disabled after each use, so `poplar/tick` enables it again.
        trigger: []const u8,
        first_join,
        join,
        respawn,
    };

    source: Source,
    /// The IR name of the callback mcfun.
    callback: []const u8,
    /// The output namespace of the `load` that registered it. The objective is `<namespace>.event_<n>`.
    namespace: ?[]const u8,
};

pub const Value = Environment.Value;

/// The holder of the global value of each `#var`. A `#` holder is hidden from the sidebar.
pub const global_holder = "#global";

pub const GlobalScore = struct {
    path: []const u8,
    position: Position,
    initial_value: i32,
    name: []const u8,
    /// Null for the pack namespace.
    output_namespace: ?[]const u8,
};

pub const CommandText = struct {
    text: []const u8,
    /// Where each part starts in `text`, for mapping errors back to the source.
    text_starts: []const usize,
    /// True if a `{{$x}}` insert makes the text a macro line for a helper function.
    is_macro: bool,
    uses_macro_keys: bool,
    /// The runtime values that the text uses, each one time.
    inserts: []const Insert,
};

/// A runtime value in `{{...}}`: `{{$stats.hp}}` is `$(stats_hp)` in the macro line. A macro argument is a
/// top-level key, so any value that is not a whole `$` var is copied into `<ns>:poplar macro` under its name first.
pub const Insert = struct {
    pub const Source = union(enum) {
        data: ir.DataPath,
        /// A score, math or a value call, computed just before the helper is called.
        value: *const ast.Expression,
    };

    macro_name: []const u8,
    source: Source,

    /// A whole `$` var is read from `<ns>:data` as it is.
    pub fn isWholeDataVar(insert: Insert) bool {
        if (insert.source != .data or insert.source.data.holder != .storage) return false;
        return std.mem.eql(u8, insert.macro_name, insert.source.data.path);
    }
};

pub const LocalOrigin = struct {
    name: []const u8,
    owner: []const u8,
};

pub const LocalVariable = struct {
    name: []const u8,
    local: Environment.Local,
    path: []const u8,
    position: Position,
};

pub const GlobalData = struct {
    path: []const u8,
    position: Position,
    /// The initial value as SNBT: `20`, `20f`, `{hp:20}`.
    initial_snbt: []const u8,
    name: []const u8,
    /// Null for the pack namespace.
    output_namespace: ?[]const u8,
    storage: ir.Storage,
};

/// Checks in OR-of-ANDs form: the condition is true if every check in one clause passes.
pub const Condition = union(enum) {
    constant: bool,
    clauses: []const []const ir.Check,
};

pub const NamedDataFile = struct {
    type_word: []const u8,
    id: []const u8,
    path: []const u8,
    position: Position,
};

/// The namespace of the file or mcfun being compiled, the namespaces it imports, and where its files go (null: the pack).
pub const Scope = struct {
    namespace: []const u8 = "ns",
    imports: []const ast.NamespaceName = &.{},
    output_namespace: ?[]const u8 = null,
};

/// What the compiler knows about the mcfun that it is compiling. Assigning a new one resets it all.
pub const CurrentMcfun = struct {
    /// As it appears in generated names (`ir.generatedFolder`): `heal`, or `std.clamp` for std.
    folder: []const u8 = "",
    /// The IR name (`combat:heal`), and the key with the source namespace (`combat:heal`, `std:clamp`).
    name: []const u8 = "",
    key: []const u8 = "",
    temp_count: usize = 0,
    generated_count: usize = 0,
    /// The `$(name)` keys that it uses.
    macro_keys: std.StringArrayHashMapUnmanaged(void) = .empty,
    /// `{a:"$(a)"}` for the macro arguments that it uses. Calls to its generated functions pass it on.
    forwarded_args: ?[]const u8 = null,
    /// The test function of the innermost `while`, for `break` and `continue`.
    loop: ?[]const u8 = null,
    /// True in a `while` or `execute (...)` body. There `return` stores the value and returns 1, so the caller can pass it on.
    return_through_body: bool = false,
    /// True in a namespace's `mcfun load`. Only there `onEvent` is allowed.
    in_load: bool = false,
    /// Removes each of its data locals. It runs at each exit, so no value is left for the next call.
    cleanup: []const ir.Command = &.{},
    /// The locals that are visible at the statement being compiled. A recursive call saves them.
    live_locals: std.ArrayList(Environment.Local) = .empty,
};

arena: std.mem.Allocator,
command_tree: *const CommandTree,
mcfuns: std.StringArrayHashMapUnmanaged(McfunDeclaration) = .empty,
globals: std.StringArrayHashMapUnmanaged(GlobalScore) = .empty,
data_globals: std.StringArrayHashMapUnmanaged(GlobalData) = .empty,
constants: std.AutoArrayHashMapUnmanaged(i32, void) = .empty,
errors: std.ArrayList(Diagnostic) = .empty,
generated: std.ArrayList(ir.McFunction) = .empty,
/// Where the compiler is: the source position for errors, the namespace, and the mcfun.
path: []const u8 = "",
position: Position = .{ .line = 0, .column = 0 },
scope: Scope = .{},
mcfun: CurrentMcfun = .{},
/// The imports of each namespace, from all its files. They decide the order of the `load` and `tick` functions.
namespace_imports: std.StringArrayHashMapUnmanaged(std.StringArrayHashMapUnmanaged(void)) = .empty,
/// The namespaces with an `mcfun load` or `mcfun tick`.
load_namespaces: std.StringArrayHashMapUnmanaged(void) = .empty,
tick_namespaces: std.StringArrayHashMapUnmanaged(void) = .empty,
/// For each mcfun, the mcfuns that its body calls.
mcfun_calls: std.StringHashMapUnmanaged(std.StringArrayHashMapUnmanaged(void)) = .empty,
/// Set when a recursive call saves temps, so that `poplar/load` clears the stack.
uses_stack: bool = false,
/// The namespace of the pack. `text(#hp)` writes it into a text component.
pack_namespace: []const u8 = "ns",
events: std.ArrayList(Event) = .empty,
/// `#i_countdown` → where it comes from, so two different locals cannot get the same generated name.
local_names: std.StringHashMapUnmanaged(LocalOrigin) = .empty,
/// Every local declaration, for the language server.
locals: std.ArrayList(LocalVariable) = .empty,
data_files: std.ArrayList(ir.DataFile) = .empty,
/// `data/<ns>/<folder>/<path>.json` → where it is declared, so two declarations cannot write one file.
data_file_paths: std.StringHashMapUnmanaged([]const u8) = .empty,
/// The file path of each data file of a namespace, by its source name: `combat:isSitting` → `is_sitting`,
/// `combat:checks/never` → itself. `self:name` and `ns:name` in Minecraft text look names up here and in `functions`.
data_file_names: std.StringArrayHashMapUnmanaged([]const u8) = .empty,
/// `self`, `std` and the namespaces of the project's files: the ones whose ids in commands can be Poplar names.
poplar_namespaces: []const []const u8 = &.{"self"},
/// The namespace of each source file (by its display path), for the language server.
file_namespaces: std.StringHashMapUnmanaged([]const u8) = .empty,
/// The data files with an identifier name, for the language server.
named_data_files: std.StringArrayHashMapUnmanaged(NamedDataFile) = .empty,

pub fn init(arena: std.mem.Allocator, command_tree: *const CommandTree) Compiler {
    return .{ .arena = arena, .command_tree = command_tree };
}

/// `mcfun load` and `mcfun tick` of each namespace are run by the game. A program without a `namespace` line
/// (in tests) is in the pack namespace.
pub fn addProgram(self: *Compiler, path: []const u8, program: ast.Program, origin: Origin) std.mem.Allocator.Error!void {
    self.path = path;
    self.scope = self.scopeOf(if (program.namespace) |namespace| namespace.name else self.pack_namespace, program.imports);
    try self.file_namespaces.put(self.arena, path, self.scope.namespace);
    if (program.namespace) |namespace| {
        self.position = namespace.position;
        if (!declarations.isValidNamespace(namespace.name)) return self.addError("namespace '{s}' must only use a-z, 0-9, '_' and '.'", .{namespace.name});
        if (origin == .project and std.mem.eql(u8, namespace.name, std_namespace)) return self.addError("the namespace 'std' belongs to the standard library", .{});
    }

    const imports = try self.namespace_imports.getOrPut(self.arena, self.scope.namespace);
    if (!imports.found_existing) imports.value_ptr.* = .empty;
    for (program.imports) |import| {
        self.position = import.position;
        if (std.mem.eql(u8, import.name, self.scope.namespace)) {
            try self.addError("a file does not import its own namespace '{s}'", .{import.name});
            continue;
        }
        try imports.value_ptr.put(self.arena, import.name, {});
    }

    for (program.mcfuns) |*mcfun| {
        if (origin == .project) {
            if (std.mem.eql(u8, mcfun.name, "load")) try self.load_namespaces.put(self.arena, self.scope.namespace, {});
            if (std.mem.eql(u8, mcfun.name, "tick")) try self.tick_namespaces.put(self.arena, self.scope.namespace, {});
        }

        if (calls.isBuiltin(mcfun.name)) {
            self.position = mcfun.position;
            try self.addError("'{s}' is a built-in function, so it cannot be defined", .{mcfun.name});
            continue;
        }

        const entry = try self.mcfuns.getOrPut(self.arena, try declarations.qualifiedKey(self, self.scope.namespace, mcfun.name));

        const declaration: McfunDeclaration = .{
            .path = path,
            .mcfun = mcfun,
            .origin = origin,
            .namespace = self.scope.namespace,
            .imports = program.imports,
            .ir_name = try declarations.functionName(self, self.scope.namespace, mcfun.name),
        };
        if (entry.found_existing) {
            try declarations.addDuplicateError(self, entry.value_ptr.*, declaration);
            continue;
        }
        entry.value_ptr.* = declaration;
    }

    for (program.globals) |global| {
        self.position = global.position;
        try Diagnostic.recover(declarations.addGlobal(self, global.decl));
    }

    for (program.data_files) |data_file| {
        self.position = data_file.position;
        try Diagnostic.recover(declarations.addDataFile(self, data_file));
    }
}

pub fn compile(self: *Compiler) std.mem.Allocator.Error!ir.Program {
    self.poplar_namespaces = try std.mem.concat(self.arena, []const u8, &.{ &.{"self"}, self.namespace_imports.keys() });
    var mc_functions: std.ArrayList(ir.McFunction) = .empty;
    try calls.buildCallGraph(self);
    const used = try load.reachableFromProject(self);
    var paths: std.StringHashMapUnmanaged([]const u8) = .empty;

    for (self.mcfuns.keys(), self.mcfuns.values()) |mcfun_key, declaration| {
        const mcfun = declaration.mcfun;
        // `import std;` costs nothing for the std mcfuns that the project never calls.
        if (declaration.origin == .std and !used.contains(mcfun_key)) continue;

        self.path = declaration.path;
        self.position = mcfun.position;
        self.scope = self.scopeOf(declaration.namespace, declaration.imports);

        // The file name is the snake_case of the name (`playerDied` → `player_died`), so both must be valid and unique.
        const path = try std.fmt.allocPrint(self.arena, "{f}", .{datapack_writer.functionPath(mcfun.name)});
        if (!Config.isValidResourceName(path)) {
            try self.addError("mcfun name '{s}' must only use letters, 0-9, '_', '.' and '-'", .{mcfun.name});
            continue;
        }
        const path_entry = try paths.getOrPut(self.arena, try declarations.functionName(self, declaration.namespace, path));
        if (path_entry.found_existing) {
            try self.addError("mcfun '{s}' and '{s}' have the same file name '{s}.mcfunction'", .{ path_entry.value_ptr.*, mcfun.name, path });
            continue;
        }
        path_entry.value_ptr.* = mcfun.name;

        var macro_keys: std.StringArrayHashMapUnmanaged(void) = .empty;
        try collectMacroKeys(self.arena, mcfun.body, &macro_keys);
        const is_hook = declaration.origin == .project and (std.mem.eql(u8, mcfun.name, "load") or std.mem.eql(u8, mcfun.name, "tick"));
        if (is_hook and macro_keys.count() > 0) {
            try self.addError("mcfun '{s}' is run by the game, so it gets no macro arguments and cannot use '$({s})'", .{ mcfun.name, macro_keys.keys()[0] });
            continue;
        }

        var forwarded: std.ArrayList(u8) = .empty;
        for (macro_keys.keys(), 0..) |key, index| {
            try forwarded.appendSlice(self.arena, if (index == 0) "{" else ",");
            try forwarded.print(self.arena, "{s}:\"$({s})\"", .{ key, key });
        }
        if (macro_keys.count() > 0) try forwarded.append(self.arena, '}');

        self.mcfun = .{
            .folder = try ir.generatedFolder(self.arena, try declarations.outputPath(self, declaration.namespace, mcfun.name)),
            .name = declaration.ir_name,
            .key = mcfun_key,
            .macro_keys = macro_keys,
            .forwarded_args = if (macro_keys.count() > 0) try forwarded.toOwnedSlice(self.arena) else null,
            .in_load = declaration.origin == .project and std.mem.eql(u8, mcfun.name, "load"),
        };
        self.mcfun.cleanup = try self.localCleanup(mcfun.body);

        var env: Environment = .{};
        var commands: std.ArrayList(ir.Command) = .empty;
        try self.compileBlock(mcfun.body, &env, &commands);
        if (mcfun.body.len == 0 or !isJump(mcfun.body[mcfun.body.len - 1].kind)) try commands.appendSlice(self.arena, self.mcfun.cleanup);

        try mc_functions.append(self.arena, .{
            .name = declaration.ir_name,
            .commands = try commands.toOwnedSlice(self.arena),
        });
    }

    try mc_functions.appendSlice(self.arena, self.generated.items);
    try optimizer.dropUnusedArguments(self.arena, mc_functions.items);

    for (mc_functions.items) |*function| function.commands = try optimizer.optimizeFunction(self.arena, function.name, function.commands);
    const optimized = try optimizer.inlineSmallFunctions(self.arena, mc_functions.items);
    try load.removeUnusedConstants(self, optimized);

    // Only the tick tag calls these, so they come after the inline pass, which removes functions that nothing calls.
    var functions: std.ArrayList(ir.McFunction) = .fromOwnedSlice(optimized);
    const ticks = try load.hookNames(self, self.tick_namespaces, "tick");
    try load.appendEventFunctions(self, &functions, ticks);

    const needs_load = self.globals.count() + self.data_globals.count() > 0 or self.load_namespaces.count() > 0 or self.uses_stack or self.events.items.len > 0;
    const program_functions = try functions.toOwnedSlice(self.arena);
    return .{
        .functions = program_functions,
        .load = if (needs_load) try load.buildLoadFunction(self, program_functions) else null,
        .tick = if (self.events.items.len > 0) try self.arena.dupe([]const u8, &.{"poplar/tick"}) else ticks,
        .data_files = self.data_files.items,
    };
}

pub fn scopeOf(self: *const Compiler, namespace: []const u8, imports: []const ast.NamespaceName) Scope {
    return .{ .namespace = namespace, .imports = imports, .output_namespace = declarations.outputNamespace(self, namespace) };
}

fn compileBlock(self: *Compiler, body: []const ast.Statement, env: *Environment, commands: *std.ArrayList(ir.Command)) std.mem.Allocator.Error!void {
    const outer_live_count = self.mcfun.live_locals.items.len;
    defer self.mcfun.live_locals.shrinkRetainingCapacity(outer_live_count);

    for (body, 0..) |statement, index| {
        try Diagnostic.recover(self.compileStatement(statement, env, commands));

        if (isJump(statement.kind) and index + 1 < body.len) {
            const next = body[index + 1];
            return self.errors.append(self.arena, .{
                .path = self.path,
                .position = next.position,
                .message = "code after 'return', 'break' or 'continue' is never run",
            });
        }
    }
}

fn compileStatement(self: *Compiler, statement: ast.Statement, env: *Environment, commands: *std.ArrayList(ir.Command)) Error!void {
    const outer_position = self.position;
    self.position = statement.position;
    defer self.position = outer_position;

    switch (statement.kind) {
        .expression => |expression| {
            self.position = expression.position;
            switch (expression.kind) {
                .call => |call| try calls.compileCall(self, call, env, commands),
                else => return self.fail("only calls can be used as statements", .{}),
            }
        },
        .var_decl => |var_decl| try self.compileVarDecl(var_decl, env, commands),
        .assign => |assign| try self.compileAssign(assign, env, commands),
        .@"for" => |loop| try self.compileFor(loop, env, commands),
        .@"return" => |value| try self.compileReturn(value, env, commands),
        .@"break" => {
            if (self.mcfun.loop == null) return self.fail("'break' must be inside a 'while' (not in 'execute (...)')", .{});
            try commands.append(self.arena, .{ .return_value = 0 });
        },
        .@"continue" => {
            const loop = self.mcfun.loop orelse return self.fail("'continue' must be inside a 'while' (not in 'execute (...)')", .{});
            try commands.append(self.arena, .{ .return_run = try self.createCommand(calls.generatedCall(self, loop)) });
        },
        .@"while" => |loop| try self.compileWhile(loop, env, commands),
        .@"if" => |if_statement| try self.compileIf(if_statement, env, commands),
        .command => |command| try minecraft_text.compileCommand(self, command, statement.position.column + 1, env, commands),
        .execute => |execute| try minecraft_text.compileExecute(self, execute, env, commands),
    }
}

/// Compiles an `execute (...)` body. A body that can `return` is always a function, called as
/// `if function ...`: it returns 1 for each entity that returns from the mcfun, and then the mcfun returns.
pub fn compileJumpBody(self: *Compiler, body: []const ast.Statement, env: *Environment, loop: ?[]const u8) std.mem.Allocator.Error!?ir.Command {
    const outer_loop = self.mcfun.loop;
    const outer_through_body = self.mcfun.return_through_body;
    self.mcfun.loop = loop;
    self.mcfun.return_through_body = true;
    defer {
        self.mcfun.loop = outer_loop;
        self.mcfun.return_through_body = outer_through_body;
    }

    if (!jumpsIn(body).has_return) return self.compileBodyAsCommand(body, env, "execute");

    var branch_env: Environment = .{ .outer = env, .runtime_branch = true };
    var body_commands: std.ArrayList(ir.Command) = .empty;
    try self.compileBlock(body, &branch_env, &body_commands);
    const name = try self.newGeneratedName("execute");
    try self.generated.append(self.arena, .{ .name = name, .commands = try body_commands.toOwnedSlice(self.arena) });

    self.mcfun.return_through_body = outer_through_body;
    return try self.onBodyReturn(name);
}

/// `execute if function <body> run ...`: when the body returned, return from this function too.
fn onBodyReturn(self: *Compiler, body_name: []const u8) std.mem.Allocator.Error!ir.Command {
    const pass_on: ir.Command = if (self.mcfun.return_through_body) .{ .return_value = 1 } else .{ .return_run = try self.createCommand(.{ .score_get = try self.resultScore() }) };
    const checks = try self.arena.dupe(ir.Check, &.{.{ .negated = false, .condition = .{ .function_returns = body_name } }});
    return .{ .execute = .{ .checks = checks, .run = try self.createCommand(pass_on) } };
}

/// The value of a `return` inside a `while` or `execute (...)` body, on its way out.
fn resultScore(self: *Compiler) std.mem.Allocator.Error!ir.Score {
    return ir.Score.result(self.arena, self.mcfun.folder, self.scope.output_namespace);
}

fn compileVarDecl(self: *Compiler, var_decl: ast.VarDecl, env: *Environment, commands: *std.ArrayList(ir.Command)) Error!void {
    switch (var_decl.target.kind) {
        .compile_time => {},
        .score => return self.declareLocal(.score, var_decl, env, commands),
        .data => return self.declareLocal(.data, var_decl, env, commands),
        .entity_data => return self.fail("entity data cannot be declared with 'var'. Set it: '@s.$path = ...;'", .{}),
    }
    if (values.containsRuntimeValue(var_decl.value)) {
        return self.fail("'{s}' is a build-time constant, but this value only exists in the game. Use 'var #{s}' for a score or 'var ${s}' for data", .{ var_decl.target.name, var_decl.target.name, var_decl.target.name });
    }

    const value = try values.evaluate(self, var_decl.value, env);
    if (!try env.declare(self.arena, var_decl.target.name, value)) {
        return self.fail("'{s}' is already declared", .{var_decl.target.name});
    }
}

/// `var #i = 10;` in `mcfun countdown` is the fake player `#i_countdown` in `<ns>`. `var $names = [];` is
/// `names_countdown` in `<ns>:data`. The value is set here, on every call.
fn declareLocal(self: *Compiler, kind: Environment.Local.Kind, var_decl: ast.VarDecl, env: *Environment, commands: *std.ArrayList(ir.Command)) Error!void {
    const name = var_decl.target.name;
    const sigil: u8 = if (kind == .score) '#' else '$';
    if (kind == .data and pathRoot(name).len != name.len) {
        return self.fail("'var' declares a whole variable. Set '${s}' after it", .{name});
    }
    const global_key = try declarations.qualifiedKey(self, self.scope.namespace, name);
    const is_global = if (kind == .score) self.globals.contains(global_key) else self.data_globals.contains(global_key);
    const key = try std.fmt.allocPrint(self.arena, "{c}{s}", .{ sigil, name });
    if (is_global or env.getLocal(kind, name) != null) return self.fail("'{s}' is already declared", .{key});

    const generated_base = try self.localKey(name);
    const generated_name = if (kind == .score) try std.fmt.allocPrint(self.arena, "#{s}", .{generated_base}) else generated_base;

    const origin: LocalOrigin = .{ .name = name, .owner = self.mcfun.folder };
    const name_entry = try self.local_names.getOrPut(self.arena, try std.fmt.allocPrint(self.arena, "{c}{s}", .{ sigil, generated_base }));
    if (name_entry.found_existing and !sameOrigin(name_entry.value_ptr.*, origin)) {
        const other = name_entry.value_ptr.*;
        return self.fail("'{c}{s}' in '{s}' and '{c}{s}' in '{s}' both become '{s}'. Rename one", .{ sigil, other.name, other.owner, sigil, name, self.mcfun.folder, generated_name });
    }
    name_entry.value_ptr.* = origin;

    const local: Environment.Local = .{ .kind = kind, .generated_name = generated_name, .owner = self.mcfun.name };
    switch (kind) {
        .score => {
            self.mcfun.temp_count = 0;
            try scores.compileInto(self, ir.Score.local(generated_name, self.mcfun.name, self.scope.output_namespace), var_decl.value, env, commands);
        },
        .data => try data.compileDataAssign(self, data.dataLocal(self, generated_name), var_decl.value, env, commands),
    }

    try env.declareLocal(self.arena, name, local);
    try self.mcfun.live_locals.append(self.arena, local);
    for (self.locals.items) |existing| {
        if (std.meta.eql(existing.position, self.position) and std.mem.eql(u8, existing.path, self.path)) break;
    } else try self.locals.append(self.arena, .{
        .name = name,
        .local = local,
        .path = self.path,
        .position = self.position,
    });
}

/// `#i` in `mcfun countdown` is `i_countdown`, with a `#` in front for a score.
fn localKey(self: *Compiler, name: []const u8) std.mem.Allocator.Error![]const u8 {
    return std.fmt.allocPrint(self.arena, "{s}_{s}", .{ name, self.mcfun.folder });
}

/// `data remove` for each data local declared anywhere in the body. A failed `set from` keeps the old value, so
/// without this a local could hold a value from an earlier call. `data remove` on a missing key fails without effect.
/// A score local needs nothing: every score write (`set`, `operation`, `store result`) overwrites it, and a failure writes 0.
fn localCleanup(self: *Compiler, body: []const ast.Statement) std.mem.Allocator.Error![]const ir.Command {
    var names: std.StringArrayHashMapUnmanaged(void) = .empty;
    try collectDataLocalNames(self.arena, body, &names);

    var cleanup: std.ArrayList(ir.Command) = .empty;
    for (names.keys()) |name| {
        try cleanup.append(self.arena, .{ .data_remove = data.dataLocal(self, try self.localKey(name)) });
    }
    return cleanup.toOwnedSlice(self.arena);
}

fn collectDataLocalNames(arena: std.mem.Allocator, body: []const ast.Statement, names: *std.StringArrayHashMapUnmanaged(void)) std.mem.Allocator.Error!void {
    for (body) |statement| switch (statement.kind) {
        .var_decl => |var_decl| if (var_decl.target.kind == .data) try names.put(arena, var_decl.target.name, {}),
        .@"if" => |if_statement| {
            try collectDataLocalNames(arena, if_statement.then_body, names);
            if (if_statement.else_body) |else_body| try collectDataLocalNames(arena, else_body, names);
        },
        .@"while" => |loop| try collectDataLocalNames(arena, loop.body, names),
        .@"for" => |loop| try collectDataLocalNames(arena, loop.body, names),
        .execute => |execute| try collectDataLocalNames(arena, execute.body, names),
        else => {},
    };
}

/// The `$(name)` keys that a body uses, in expressions and in Minecraft text.
pub fn collectMacroKeys(arena: std.mem.Allocator, body: []const ast.Statement, keys: *std.StringArrayHashMapUnmanaged(void)) std.mem.Allocator.Error!void {
    for (body) |statement| switch (statement.kind) {
        .var_decl => |var_decl| try collectExpressionMacroKeys(arena, var_decl.value, keys),
        .assign => |assign| try collectExpressionMacroKeys(arena, assign.value, keys),
        .@"return" => |value| if (value) |expression| try collectExpressionMacroKeys(arena, expression, keys),
        .@"break", .@"continue" => {},
        .@"if" => |if_statement| {
            try collectExpressionMacroKeys(arena, if_statement.condition, keys);
            try collectMacroKeys(arena, if_statement.then_body, keys);
            if (if_statement.else_body) |else_body| try collectMacroKeys(arena, else_body, keys);
        },
        .@"while" => |loop| {
            try collectExpressionMacroKeys(arena, loop.condition, keys);
            try collectMacroKeys(arena, loop.body, keys);
        },
        .@"for" => |loop| {
            try collectExpressionMacroKeys(arena, loop.start, keys);
            try collectExpressionMacroKeys(arena, loop.end, keys);
            try collectMacroKeys(arena, loop.body, keys);
        },
        .command => |command| try collectPartsMacroKeys(arena, command.parts, keys),
        .execute => |execute| {
            try collectPartsMacroKeys(arena, execute.subcommands, keys);
            try collectMacroKeys(arena, execute.body, keys);
        },
        .expression => |expression| try collectExpressionMacroKeys(arena, expression, keys),
    };
}

fn collectExpressionMacroKeys(arena: std.mem.Allocator, expression: *const ast.Expression, keys: *std.StringArrayHashMapUnmanaged(void)) std.mem.Allocator.Error!void {
    switch (expression.kind) {
        .macro_key => |name| try keys.put(arena, name, {}),
        .prefix => |prefix| try collectExpressionMacroKeys(arena, prefix.operand, keys),
        .infix => |infix| {
            try collectExpressionMacroKeys(arena, infix.left, keys);
            try collectExpressionMacroKeys(arena, infix.right, keys);
        },
        .call => |call| {
            for (call.args) |arg| try collectExpressionMacroKeys(arena, arg, keys);
            if (call.with) |with| switch (with) {
                .value => |value| try collectExpressionMacroKeys(arena, value, keys),
                .raw => |text| try collectTextMacroKeys(arena, text, keys),
            };
        },
        .list => |elements| for (elements) |element| try collectExpressionMacroKeys(arena, element, keys),
        .compound => |entries| for (entries) |entry| try collectExpressionMacroKeys(arena, entry.value, keys),
        .minecraft_check => |parts| try collectPartsMacroKeys(arena, parts, keys),
        .identifier, .number, .typed_number, .string, .boolean, .null, .selector => {},
    }
}

fn collectPartsMacroKeys(arena: std.mem.Allocator, parts: []const ast.CommandPart, keys: *std.StringArrayHashMapUnmanaged(void)) std.mem.Allocator.Error!void {
    for (parts) |part| switch (part.content) {
        .text => |text| try collectTextMacroKeys(arena, text, keys),
        .insert => |expression| try collectExpressionMacroKeys(arena, expression, keys),
    };
}

fn collectTextMacroKeys(arena: std.mem.Allocator, text: []const u8, keys: *std.StringArrayHashMapUnmanaged(void)) std.mem.Allocator.Error!void {
    var rest = text;
    while (std.mem.indexOf(u8, rest, "$(")) |start| {
        const end = std.mem.indexOfScalarPos(u8, rest, start, ')') orelse return;
        try keys.put(arena, rest[start + 2 .. end], {});
        rest = rest[end + 1 ..];
    }
}

fn sameOrigin(a: LocalOrigin, b: LocalOrigin) bool {
    return std.mem.eql(u8, a.name, b.name) and std.mem.eql(u8, a.owner, b.owner);
}

/// `stats` in `stats.inventory[0]`.
pub fn pathRoot(path: []const u8) []const u8 {
    const end = std.mem.indexOfAny(u8, path, ".[") orelse path.len;
    return path[0..end];
}

fn compileAssign(self: *Compiler, assign: ast.Assign, env: *Environment, commands: *std.ArrayList(ir.Command)) Error!void {
    switch (assign.target.kind) {
        .compile_time => {},
        .score => return scores.compileScoreAssign(self, assign.target, assign.value, env, commands),
        .data => {
            const target = try data.dataPath(self, assign.target, env);
            return data.compileDataAssign(self, target, assign.value, env, commands);
        },
        .entity_data => {
            const target = try data.entityDataPath(self, assign.target);
            return data.compileDataAssign(self, target, assign.value, env, commands);
        },
    }

    if (values.containsRuntimeValue(assign.value)) return self.fail("a runtime value cannot be stored in a compile-time variable", .{});

    const value = try values.evaluate(self, assign.value, env);
    switch (env.assign(assign.target.name, value)) {
        .assigned => {},
        .not_found => return self.fail("unknown name '{s}'", .{assign.target.name}),
        .crosses_runtime_branch => {
            return self.fail("cannot change compile-time '{s}' inside a runtime 'if' or 'execute'", .{assign.target.name});
        },
    }
}

/// What a body can jump with. A `break` or `continue` in an inner `while` belongs to that loop, and `execute (...)` cannot
/// have one. A `return` leaves every level.
pub const Jumps = struct {
    has_return: bool = false,
    has_break: bool = false,
    has_continue: bool = false,

    fn merge(jumps: *Jumps, other: Jumps) void {
        jumps.has_return = jumps.has_return or other.has_return;
        jumps.has_break = jumps.has_break or other.has_break;
        jumps.has_continue = jumps.has_continue or other.has_continue;
    }

    fn any(jumps: Jumps) bool {
        return jumps.has_return or jumps.has_break or jumps.has_continue;
    }
};

pub fn jumpsIn(body: []const ast.Statement) Jumps {
    var jumps: Jumps = .{};
    for (body) |statement| switch (statement.kind) {
        .@"return" => jumps.has_return = true,
        .@"break" => jumps.has_break = true,
        .@"continue" => jumps.has_continue = true,
        .@"if" => |if_statement| jumps.merge(jumpsInIf(if_statement)),
        .@"for" => |loop| jumps.merge(jumpsIn(loop.body)),
        .@"while" => |loop| jumps.has_return = jumps.has_return or jumpsIn(loop.body).has_return,
        .execute => |execute| jumps.has_return = jumps.has_return or jumpsIn(execute.body).has_return,
        else => {},
    };
    return jumps;
}

fn jumpsInIf(if_statement: ast.If) Jumps {
    var jumps = jumpsIn(if_statement.then_body);
    jumps.merge(jumpsIn(if_statement.else_body orelse &.{}));
    return jumps;
}

fn isJump(kind: ast.Statement.Kind) bool {
    return kind == .@"return" or kind == .@"break" or kind == .@"continue";
}

/// True if the then body and every `else if` and `else` body end with `return`, `break` or `continue`.
/// The final `else` is optional.
fn branchesEndWithJump(if_statement: ast.If) bool {
    if (!endsWithJump(if_statement.then_body)) return false;

    const else_body = if_statement.else_body orelse return true;
    if (else_body.len == 1 and else_body[0].kind == .@"if") return branchesEndWithJump(else_body[0].kind.@"if");
    return endsWithJump(else_body);
}

fn endsWithJump(body: []const ast.Statement) bool {
    if (body.len == 0) return false;

    return switch (body[body.len - 1].kind) {
        .@"return", .@"break", .@"continue" => true,
        .@"if" => |if_statement| if_statement.else_body != null and branchesEndWithJump(if_statement),
        else => false,
    };
}

fn compileIf(self: *Compiler, if_statement: ast.If, env: *Environment, commands: *std.ArrayList(ir.Command)) Error!void {
    self.mcfun.temp_count = 0;
    var setup: std.ArrayList(ir.Command) = .empty;
    const condition = try conditions.lowerCondition(self, if_statement.condition, env, false, &setup);

    switch (condition) {
        .constant => |is_true| {
            const body = if (is_true) if_statement.then_body else if_statement.else_body orelse return;
            var branch_env: Environment = .{ .outer = env };
            try self.compileBlock(body, &branch_env, commands);
        },
        .clauses => |clauses| {
            // Each returning branch returns from this function, so the branches go here directly, with no wrapper.
            if (jumpsInIf(if_statement).any()) {
                if (!branchesEndWithJump(if_statement)) {
                    return self.fail("if one branch of an 'if' contains 'return', 'break' or 'continue', every branch must end with one", .{});
                }
                return self.appendBranches(if_statement, env, commands, condition, setup.items, false);
            }

            if (if_statement.else_body == null and clauses.len == 1) {
                const run = try self.compileBodyAsCommand(if_statement.then_body, env, "if") orelse return;
                try commands.appendSlice(self.arena, setup.items);
                try commands.append(self.arena, .{ .execute = .{ .checks = clauses[0], .run = try self.createCommand(run) } });
                return;
            }

            const wrapper_name = try self.newGeneratedName("if");
            var wrapper: std.ArrayList(ir.Command) = .empty;
            try self.appendBranches(if_statement, env, &wrapper, condition, setup.items, false);

            try self.generated.append(self.arena, .{ .name = wrapper_name, .commands = try wrapper.toOwnedSlice(self.arena) });
            try commands.append(self.arena, calls.generatedCall(self, wrapper_name));
        },
    }
}

/// Each branch returns from the wrapper, so later branches and the else body run only if no earlier branch ran.
fn appendBranches(
    self: *Compiler,
    if_statement: ast.If,
    env: *Environment,
    wrapper: *std.ArrayList(ir.Command),
    condition: Condition,
    setup: []const ir.Command,
    after_runtime_branch: bool,
) Error!void {
    try wrapper.appendSlice(self.arena, setup);

    switch (condition) {
        .constant => |is_true| if (is_true) {
            var branch_env: Environment = .{ .outer = env, .runtime_branch = after_runtime_branch };
            return self.compileBlock(if_statement.then_body, &branch_env, wrapper);
        },
        .clauses => |clauses| {
            const body = try self.compileBodyAsCommand(if_statement.then_body, env, "if");
            const run: ir.Command = if (body) |command| try self.returnRun(command) else .{ .return_value = 0 };
            const run_pointer = try self.createCommand(run);

            for (clauses) |checks| {
                try wrapper.append(self.arena, .{ .execute = .{ .checks = checks, .run = run_pointer } });
            }
        },
    }

    const is_runtime = after_runtime_branch or condition == .clauses;
    const else_body = if_statement.else_body orelse return;

    if (else_body.len == 1 and else_body[0].kind == .@"if") {
        const else_if = else_body[0].kind.@"if";
        // The rest of the chain belongs to this `else if`. `compileStatement` restores the position after the chain.
        self.position = else_body[0].position;
        self.mcfun.temp_count = 0;
        var else_setup: std.ArrayList(ir.Command) = .empty;
        const else_condition = try conditions.lowerCondition(self, else_if.condition, env, false, &else_setup);
        return self.appendBranches(else_if, env, wrapper, else_condition, else_setup.items, is_runtime);
    }

    var else_env: Environment = .{ .outer = env, .runtime_branch = is_runtime };
    try self.compileBlock(else_body, &else_env, wrapper);
}

/// `kind` names a generated function for a body with more than one command: `if` or `execute`.
fn compileBodyAsCommand(self: *Compiler, body: []const ast.Statement, env: *Environment, kind: []const u8) std.mem.Allocator.Error!?ir.Command {
    var branch_env: Environment = .{ .outer = env, .runtime_branch = true };
    var body_commands: std.ArrayList(ir.Command) = .empty;
    try self.compileBlock(body, &branch_env, &body_commands);

    switch (body_commands.items.len) {
        0 => return null,
        1 => return body_commands.items[0],
        else => {
            const name = try self.newGeneratedName(kind);
            try self.generated.append(self.arena, .{ .name = name, .commands = try body_commands.toOwnedSlice(self.arena) });
            return calls.generatedCall(self, name);
        },
    }
}

pub fn newGeneratedName(self: *Compiler, kind: []const u8) std.mem.Allocator.Error![]const u8 {
    defer self.mcfun.generated_count += 1;
    const path = try std.fmt.allocPrint(self.arena, "poplar/{s}/{s}_{d}", .{ self.mcfun.folder, kind, self.mcfun.generated_count });
    const namespace = self.scope.output_namespace orelse return path;
    return std.fmt.allocPrint(self.arena, "{s}:{s}", .{ namespace, path });
}

pub fn createExpression(self: *Compiler, expression: ast.Expression) std.mem.Allocator.Error!*const ast.Expression {
    const pointer = try self.arena.create(ast.Expression);
    pointer.* = expression;
    return pointer;
}

pub fn createCommand(self: *Compiler, command: ir.Command) std.mem.Allocator.Error!*const ir.Command {
    return ir.createCommand(self.arena, command);
}

fn compileReturn(self: *Compiler, value: ?*const ast.Expression, env: *Environment, commands: *std.ArrayList(ir.Command)) Error!void {
    if (self.mcfun.return_through_body) {
        const result = try self.resultScore();
        self.mcfun.temp_count = 0;
        if (value) |expression| {
            try scores.compileInto(self, result, expression, env, commands);
        } else {
            try commands.append(self.arena, .{ .score_set = .{ .score = result, .value = 0 } });
        }
        try commands.appendSlice(self.arena, self.mcfun.cleanup);
        return commands.append(self.arena, .{ .return_value = 1 });
    }

    const expression = value orelse {
        try commands.appendSlice(self.arena, self.mcfun.cleanup);
        return commands.append(self.arena, .{ .return_value = 0 });
    };

    if (!values.containsRuntimeValue(expression)) {
        const result = try values.evaluate(self, expression, env);
        const number = try scores.toScoreValue(self, result);
        try commands.appendSlice(self.arena, self.mcfun.cleanup);
        return commands.append(self.arena, .{ .return_value = number });
    }

    self.mcfun.temp_count = 0;
    if (expression.kind == .macro_key) {
        try commands.appendSlice(self.arena, self.mcfun.cleanup);
        return commands.append(self.arena, .{ .return_macro_argument = expression.kind.macro_key });
    }
    // The value can read a local, so it is computed before the locals are removed.
    if (self.mcfun.cleanup.len > 0) {
        const temp = try scores.newTemp(self);
        try scores.compileInto(self, temp, expression, env, commands);
        try commands.appendSlice(self.arena, self.mcfun.cleanup);
        return commands.append(self.arena, .{ .return_run = try self.createCommand(.{ .score_get = temp }) });
    }
    const read: ir.Command = blk: {
        if (expression.kind == .identifier) {
            const identifier = expression.kind.identifier;
            switch (identifier.kind) {
                .data, .entity_data => break :blk .{ .data_get = try data.dataPathOf(self, identifier, env) },
                .score => break :blk .{ .score_get = try scores.scoreSource(self, identifier, env) },
                .compile_time => {},
            }
        }

        const temp = try scores.newTemp(self);
        try scores.compileInto(self, temp, expression, env, commands);
        break :blk .{ .score_get = temp };
    };
    try commands.append(self.arena, .{ .return_run = try self.createCommand(read) });
}

/// Wraps a command in `return run`, unless it already returns.
fn returnRun(self: *Compiler, command: ir.Command) std.mem.Allocator.Error!ir.Command {
    return switch (command) {
        .return_run, .return_value, .return_macro_argument => command,
        else => .{ .return_run = try self.createCommand(command) },
    };
}

/// A loop is two functions: `while_<n>` tests the condition and runs `while_<n>_body`, which runs `while_<n>` again.
fn compileWhile(self: *Compiler, loop: ast.While, env: *Environment, commands: *std.ArrayList(ir.Command)) Error!void {
    const jumps = jumpsIn(loop.body);
    const test_name = try self.newGeneratedName("while");
    const body_name = try std.fmt.allocPrint(self.arena, "{s}_body", .{test_name});

    self.mcfun.temp_count = 0;
    var test_commands: std.ArrayList(ir.Command) = .empty;
    const condition = try conditions.lowerCondition(self, loop.condition, env, false, &test_commands);
    // `while (true)` runs the body with no check. It must be able to stop.
    const always: []const []const ir.Check = &.{&.{}};
    const clauses = switch (condition) {
        .constant => |is_true| if (!is_true) return else if (!jumps.has_return and !jumps.has_break) {
            return self.fail("this 'while' never stops: add a 'break' or 'return', or use a score or data value in the condition", .{});
        } else always,
        .clauses => |clauses| clauses,
    };

    const can_return = jumps.has_return;
    // `continue` and a passed-on `return` use the result of the test, so then the test must always give one.
    const reads_test_result = can_return or jumps.has_continue;

    // `return run` stops the next clause from running the body again, and passes a return of the body on.
    const call_body = calls.generatedCall(self, body_name);
    const run_body = try self.createCommand(if (clauses.len > 1 or can_return) .{ .return_run = try self.createCommand(call_body) } else call_body);
    for (clauses) |checks| {
        try test_commands.append(self.arena, if (checks.len == 0) run_body.* else .{ .execute = .{ .checks = checks, .run = run_body } });
    }
    if (reads_test_result) try test_commands.append(self.arena, .{ .return_value = 0 });

    const outer_loop = self.mcfun.loop;
    const outer_through_body = self.mcfun.return_through_body;
    self.mcfun.loop = test_name;
    self.mcfun.return_through_body = true;

    var body_env: Environment = .{ .outer = env, .runtime_branch = true };
    var body_commands: std.ArrayList(ir.Command) = .empty;
    try self.compileBlock(loop.body, &body_env, &body_commands);
    const call_test = calls.generatedCall(self, test_name);
    try body_commands.append(self.arena, if (can_return) .{ .return_run = try self.createCommand(call_test) } else call_test);

    self.mcfun.loop = outer_loop;
    self.mcfun.return_through_body = outer_through_body;

    try self.generated.append(self.arena, .{ .name = test_name, .commands = try test_commands.toOwnedSlice(self.arena) });
    try self.generated.append(self.arena, .{ .name = body_name, .commands = try body_commands.toOwnedSlice(self.arena) });

    if (!can_return) return commands.append(self.arena, call_test);
    if (self.mcfun.forwarded_args == null) return commands.append(self.arena, try self.onBodyReturn(test_name));

    // `if function` cannot pass the macro arguments, so the result of the loop goes through a temp.
    const returned = try scores.newTemp(self);
    try commands.append(self.arena, .{ .store_result = .{ .target = .{ .score = returned }, .run = try self.createCommand(call_test) } });
    const pass_on = (try self.onBodyReturn(test_name)).execute.run;
    const checks = try self.arena.dupe(ir.Check, &.{.{ .negated = false, .condition = .{ .matches = .{ .score = returned, .min = 1, .max = 1 } } }});
    try commands.append(self.arena, .{ .execute = .{ .checks = checks, .run = pass_on } });
}

fn compileFor(self: *Compiler, loop: ast.For, env: *Environment, commands: *std.ArrayList(ir.Command)) Error!void {
    const start, const end = try self.evaluateRange(loop, env);

    var i = start;
    while (i < end) : (i += 1) {
        var loop_env: Environment = .{ .outer = env };
        if (!try loop_env.declare(self.arena, loop.capture, .{ .number = i })) {
            return self.fail("'{s}' is already declared", .{loop.capture});
        }

        const error_count = self.errors.items.len;
        try self.compileBlock(loop.body, &loop_env, commands);
        if (self.errors.items.len > error_count) return;
    }
}

fn evaluateRange(self: *Compiler, loop: ast.For, env: *Environment) Error!struct { i64, i64 } {
    const start = try values.evaluate(self, loop.start, env);
    const end = try values.evaluate(self, loop.end, env);

    if (start != .number or end != .number) {
        return self.fail("range bounds must be whole numbers", .{});
    }
    if (start.number > end.number) {
        return self.fail("range start {d} is greater than end {d}", .{ start.number, end.number });
    }
    return .{ start.number, end.number };
}

/// Errors inside an expression point to where it starts. Returns the outer position for `restorePosition`.
pub fn enterExpression(self: *Compiler, expression: *const ast.Expression) Position {
    const outer = self.position;
    self.position = expression.position;
    return outer;
}

pub fn restorePosition(self: *Compiler, position: Position) void {
    self.position = position;
}

pub fn addError(self: *Compiler, comptime format: []const u8, args: anytype) std.mem.Allocator.Error!void {
    const message = try std.fmt.allocPrint(self.arena, format, args);
    try self.errors.append(self.arena, .{ .path = self.path, .position = self.position, .message = message });
}

/// Records an error and stops the statement that is being compiled.
pub fn fail(self: *Compiler, comptime format: []const u8, args: anytype) Error {
    try self.addError(format, args);
    return error.Reported;
}

/// The same as `fail`, at a column of the current line.
pub fn failAt(self: *Compiler, column: usize, comptime format: []const u8, args: anytype) Error {
    const message = try std.fmt.allocPrint(self.arena, format, args);
    try self.errors.append(self.arena, .{ .path = self.path, .position = .{ .line = self.position.line, .column = column }, .message = message });
    return error.Reported;
}

pub fn compileForTest(arena: std.mem.Allocator, source: []const u8) !Compiler {
    var parser = try Parser.init(arena, Lexer.init(source));
    const program = try parser.parseProgram();
    try std.testing.expectEqual(0, parser.errors.items.len);

    const command_tree = try arena.create(CommandTree);
    command_tree.* = try .load(arena);

    var compiler = Compiler.init(arena, command_tree);
    try compiler.addProgram("main.poplar", program, .project);
    return compiler;
}

test "assigns outer var from for body" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    var compiler = try compileForTest(arena.allocator(),
        \\mcfun main() {
        \\    var total = 0;
        \\    for (1..4) |i| { total = total + i; }
        \\    /say {{total}};
        \\}
    );
    const commands = (try compiler.compile()).functions[0].commands;

    try std.testing.expectEqual(0, compiler.errors.items.len);
    try std.testing.expectEqualStrings("say 6", commands[0].raw);
}

pub fn renderForTest(arena: std.mem.Allocator, program: ir.Program, name: []const u8) ![]const u8 {
    for (program.functions) |function| {
        if (std.mem.eql(u8, function.name, name)) return datapack_writer.renderFunction(arena, "ns", function);
    }
    return error.TestUnexpectedResult;
}

test "if else chain uses one wrapper, inlined when it is the last command" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    var compiler = try compileForTest(arena.allocator(),
        \\var #hp = 0;
        \\mcfun main() {
        \\    if (#hp <= 0) { /say dead; } else if (#hp < 5) { /say low; } else { /say ok; }
        \\}
    );
    const program = try compiler.compile();
    try std.testing.expectEqual(0, compiler.errors.items.len);

    try std.testing.expectEqualStrings(
        \\execute if score #global ns.hp matches ..0 run return run say dead
        \\execute if score #global ns.hp matches ..4 run return run say low
        \\say ok
        \\
    , try renderForTest(arena.allocator(), program, "main"));
    for (program.functions) |function| try std.testing.expect(!std.mem.eql(u8, function.name, "poplar/main/if_0"));
}

test "rejects compile-time change in runtime if" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    var compiler = try compileForTest(arena.allocator(),
        \\var #a = 0;
        \\mcfun main() { var count = 0; if (#a > 0) { count = 1; } }
    );
    _ = try compiler.compile();

    try std.testing.expectEqual(1, compiler.errors.items.len);
    try std.testing.expectEqualStrings("cannot change compile-time 'count' inside a runtime 'if' or 'execute'", compiler.errors.items[0].message);
}

test "errors point to their expression" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    var compiler = try compileForTest(arena.allocator(),
        \\var #total = 0;
        \\mcfun helper() {
        \\    missing();
        \\}
        \\mcfun main() {
        \\    var x = y;
        \\    var copy = #total;
        \\}
    );
    _ = try compiler.compile();

    const errors = compiler.errors.items;
    try std.testing.expectEqual(3, errors.len);
    try std.testing.expectEqual(3, errors[0].position.?.line);
    try std.testing.expectEqual(5, errors[0].position.?.column);
    try std.testing.expectEqual(6, errors[1].position.?.line);
    try std.testing.expectEqual(13, errors[1].position.?.column);
    try std.testing.expectEqualStrings("'copy' is a build-time constant, but this value only exists in the game. Use 'var #copy' for a score or 'var $copy' for data", errors[2].message);
}

test "break, continue and return in loops and execute bodies" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    var compiler = try compileForTest(arena.allocator(),
        \\var #i = 0;
        \\mcfun count() {
        \\    while (true) {
        \\        #i = #i + 1;
        \\        if (#i > 9) { break; }
        \\        if (#i == 5) { continue; }
        \\    }
        \\}
        \\mcfun find() {
        \\    while (#i < 100) {
        \\        if (#i > 50) { return #i; }
        \\        #i = #i + 1;
        \\    }
        \\    return -1;
        \\}
        \\mcfun any() {
        \\    execute (as @e) { if (@s.#i > 5) { return 1; } }
        \\    return 0;
        \\}
    );
    const program = try compiler.compile();
    try std.testing.expectEqual(0, compiler.errors.items.len);

    try std.testing.expectEqualStrings(
        \\scoreboard players add #global ns.i 1
        \\execute if score #global ns.i matches 10.. run return 0
        \\execute if score #global ns.i matches 5 run return run function ns:poplar/count/while_0
        \\function ns:poplar/count/while_0
        \\
    , try renderForTest(arena.allocator(), program, "poplar/count/while_0_body"));
    try std.testing.expectEqualStrings(
        \\execute if function ns:poplar/find/while_0 run return run scoreboard players get #poplar.find.result poplar.ns
        \\return -1
        \\
    , try renderForTest(arena.allocator(), program, "find"));
    try std.testing.expectEqualStrings(
        \\scoreboard players operation #poplar.find.result poplar.ns = #global ns.i
        \\return 1
        \\
    , try renderForTest(arena.allocator(), program, "poplar/find/if_1"));
    try std.testing.expectEqualStrings(
        \\execute as @e if function ns:poplar/any/execute_1 run return run scoreboard players get #poplar.any.result poplar.ns
        \\return 0
        \\
    , try renderForTest(arena.allocator(), program, "any"));
}

test "return errors" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    var compiler = try compileForTest(arena.allocator(),
        \\var #a = 0;
        \\mcfun f() {
        \\    if (#a > 0) {
        \\        if (#a > 1) { return 1; }
        \\        #a = 2;
        \\    }
        \\    if (#a == 9) { break; }
        \\    while (true) { #a = 1; }
        \\    return 1;
        \\    #a = 4;
        \\}
    );
    _ = try compiler.compile();

    const errors = compiler.errors.items;
    try std.testing.expectEqual(4, errors.len);
    try std.testing.expectEqualStrings("if one branch of an 'if' contains 'return', 'break' or 'continue', every branch must end with one", errors[0].message);
    try std.testing.expectEqual(3, errors[0].position.?.line);
    try std.testing.expectEqualStrings("'break' must be inside a 'while' (not in 'execute (...)')", errors[1].message);
    try std.testing.expectEqualStrings("this 'while' never stops: add a 'break' or 'return', or use a score or data value in the condition", errors[2].message);
    try std.testing.expectEqualStrings("code after 'return', 'break' or 'continue' is never run", errors[3].message);
    try std.testing.expectEqual(10, errors[3].position.?.line);
}

test "locals are set on every call, saved around a recursive call, and data locals are removed at each exit" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    var compiler = try compileForTest(arena.allocator(),
        \\mcfun walk() {
        \\    var #mine = $(depth);
        \\    var $seen = true;
        \\    if ($(depth) > 0) { walk() with {depth: $(depth) - 1}; }
        \\    /say {{#mine}} {{$seen}};
        \\}
        \\mcfun twice() {
        \\    var $v = $(n);
        \\    return $v * 2;
        \\}
    );
    const program = try compiler.compile();
    try std.testing.expectEqual(0, compiler.errors.items.len);

    try std.testing.expectEqualStrings(
        \\$scoreboard players set #mine_walk poplar.ns $(depth)
        \\data modify storage ns:data seen_walk set value true
        \\scoreboard players operation #poplar.walk.t0 poplar.ns = #mine_walk poplar.ns
        \\$execute if score #poplar.walk.t0 poplar.ns matches 1.. run function ns:poplar/walk/if_0 {depth:"$(depth)"}
        \\execute store result storage ns:poplar macro.mine int 1 run scoreboard players get #mine_walk poplar.ns
        \\data modify storage ns:poplar macro.seen_walk set from storage ns:data seen_walk
        \\function ns:poplar/walk/macro_1 with storage ns:poplar macro
        \\data remove storage ns:data seen_walk
        \\
    , try renderForTest(arena.allocator(), program, "walk"));
    try std.testing.expectEqualStrings(
        \\$data modify storage ns:data v_twice set value $(n)
        \\execute store result score #poplar.twice.t0 poplar.ns run data get storage ns:data v_twice 2
        \\data remove storage ns:data v_twice
        \\return run scoreboard players get #poplar.twice.t0 poplar.ns
        \\
    , try renderForTest(arena.allocator(), program, "twice"));
    try std.testing.expectEqualStrings(
        \\$scoreboard players set #poplar.walk.t0 poplar.ns $(depth)
        \\execute store result storage ns:poplar args.depth int 1 run scoreboard players remove #poplar.walk.t0 poplar.ns 1
        \\data modify storage ns:poplar stack append value {}
        \\execute store result storage ns:poplar stack[-1].s_mine_walk int 1 run scoreboard players get #mine_walk poplar.ns
        \\data modify storage ns:poplar stack[-1].d_seen_walk set from storage ns:data seen_walk
        \\function ns:walk with storage ns:poplar args
        \\execute store result score #mine_walk poplar.ns run data get storage ns:poplar stack[-1].s_mine_walk
        \\data modify storage ns:data seen_walk set from storage ns:poplar stack[-1].d_seen_walk
        \\data remove storage ns:poplar stack[-1]
        \\
    , try renderForTest(arena.allocator(), program, "poplar/walk/if_0"));
}

test "local errors" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    var compiler = try compileForTest(arena.allocator(),
        \\var #hp = 0;
        \\mcfun c() { var #a_b = 1; }
        \\mcfun b_c() { var #a = 1; }
        \\mcfun main() {
        \\    var #hp = 1;
        \\    var #i = 0;
        \\    @s.#i = 1;
        \\    if (#i > 0) { var #inner = 1; }
        \\    #inner = 2;
        \\}
    );
    _ = try compiler.compile();

    const errors = compiler.errors.items;
    try std.testing.expectEqual(4, errors.len);
    try std.testing.expectEqualStrings("'#a_b' in 'c' and '#a' in 'b_c' both become '#a_b_c'. Rename one", errors[0].message);
    try std.testing.expectEqualStrings("'#hp' is already declared", errors[1].message);
    try std.testing.expectEqualStrings("'#i' is local, so it has no entity values. Declare it at the top level", errors[2].message);
    try std.testing.expectEqualStrings("unknown score '#inner'", errors[3].message);
}

test "a wrapper that can return is not inlined where the return value is read" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    var compiler = try compileForTest(arena.allocator(),
        \\var #a = 0;
        \\mcfun pick() {
        \\    if (#a > 0) { /say a; } else { /say b; }
        \\}
        \\mcfun main() { #a = pick(); }
    );
    const program = try compiler.compile();
    try std.testing.expectEqual(0, compiler.errors.items.len);
    try std.testing.expectEqualStrings("function ns:poplar/pick/if_0\n", try renderForTest(arena.allocator(), program, "pick"));
}
