const std = @import("std");
const Ast = @import("Ast.zig");
const Commands = @import("Commands.zig");
const DataFile = @import("DataFile.zig");
const Config = @import("Config.zig");
const Environment = @import("Environment.zig");
const Ir = @import("Ir.zig");
const Lexer = @import("Lexer.zig");
const Optimizer = @import("Optimizer.zig");
const Parser = @import("Parser.zig");
const Token = @import("Token.zig");
const Writer = @import("Writer.zig");
const Declarations = @import("compiler/Declarations.zig");
const Load = @import("compiler/Load.zig");
const Conditions = @import("compiler/Conditions.zig");
const MinecraftText = @import("compiler/MinecraftText.zig");
const Calls = @import("compiler/Calls.zig");
const Scores = @import("compiler/Scores.zig");
const Data = @import("compiler/Data.zig");
const Values = @import("compiler/Values.zig");

pub const builtin_names = Calls.builtin_names;

const Self = @This();

pub const CompileError = std.mem.Allocator.Error;

pub const Error = struct {
    path: []const u8,
    line: usize,
    column: ?usize = null,
    message: []const u8,
};

pub const Located = struct {
    path: []const u8,
    function: *const Ast.Function,
    origin: Origin,
    // The namespace of the file, and the namespaces it imports.
    namespace: []const u8,
    imports: []const Ast.Import,
    // The name in the IR: `combat:heal`, or `heal` in the pack namespace.
    ir_name: []const u8,
};

// Where a source file comes from: the project's `src/` or the standard library.
pub const Origin = enum { project, std };

// The namespace of the standard library. Its files are written into the pack namespace, under `std/`.
pub const std_namespace = "std";

// `onEvent(criteria, callback)`: the game counts the criteria in `<ns>.event_<n>`, and `poplar/tick` runs the callback.
// `onTrigger(name, callback)` is the same with a `trigger` objective called `name`, so players can run `/trigger <name>`.
pub const Event = struct {
    // `onEvent` and `onDeath` count a criteria; the player events are fixed patterns (see `Load.appendEventFunctions`).
    pub const Kind = enum { criteria, trigger, first_join, join, respawn };

    kind: Kind,
    criteria: []const u8 = "",
    // The IR name of the callback mcfun.
    callback: []const u8,
    // The output namespace of the `load` that registered it. The objective is `<namespace>.event_<n>`.
    namespace: ?[]const u8,
    // The objective name of `onTrigger`. A trigger is disabled after each use, so `poplar/tick` enables it again.
    trigger: ?[]const u8 = null,
};

pub const Value = Environment.Value;

// The holder of the global value of each `#var`. A `#` holder is hidden from the sidebar.
pub const global_holder = "#global";

pub const GlobalScore = struct {
    path: []const u8,
    line: usize,
    initial_value: i32,
    name: []const u8,
    // Null for the pack namespace.
    output_namespace: ?[]const u8,
};

pub const CommandText = struct {
    text: []const u8,
    // Where each part starts in `text`, for mapping errors back to the source.
    text_starts: []const usize,
    // True if a `{{$x}}` insert makes the text a macro line for a helper function.
    is_macro: bool,
    uses_macro_keys: bool,
    // The runtime values that the text uses, each one time.
    inserts: []const Insert,
};

// A runtime value in `{{...}}`: `{{$stats.hp}}` is `$(stats_hp)` in the macro line. A macro argument is a
// top-level key, so any value that is not a whole `$` var is copied into `<ns>:poplar macro` under its name first.
pub const Insert = struct {
    pub const Source = union(enum) {
        data: Ir.DataPath,
        // A score, math or a value call, computed just before the helper is called.
        value: *const Ast.Expr,
    };

    macro_name: []const u8,
    source: Source,

    // A whole `$` var is read from `<ns>:data` as it is.
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
    line: usize,
    column: ?usize,
};

pub const GlobalData = struct {
    path: []const u8,
    line: usize,
    // The initial value as SNBT: `20`, `20f`, `{hp:20}`.
    initial_snbt: []const u8,
    name: []const u8,
    // Null for the pack namespace.
    output_namespace: ?[]const u8,
    storage: Ir.Storage,
};

// Checks in OR-of-ANDs form: the condition is true if every check in one clause passes.
pub const Condition = union(enum) {
    constant: bool,
    clauses: []const []const Ir.Check,
};

pub const Operand = union(enum) {
    number: i64,
    score: Ir.Score,
};

gpa: std.mem.Allocator,
command_tree: *const Commands,
functions: std.StringArrayHashMapUnmanaged(Located) = .empty,
globals: std.StringArrayHashMapUnmanaged(GlobalScore) = .empty,
data_globals: std.StringArrayHashMapUnmanaged(GlobalData) = .empty,
constants: std.AutoArrayHashMapUnmanaged(i32, void) = .empty,
errors: std.ArrayList(Error) = .empty,
generated: std.ArrayList(Ir.McFunction) = .empty,
temp_count: usize = 0,
generated_count: usize = 0,
// Where the compiler is: the source position for errors, the namespace, and the mcfun.
position: SourcePosition = .{},
scope: Scope = .{},
mcfun: CurrentMcfun = .{},
// The imports of each namespace, from all its files. They decide the order of the `load` and `tick` functions.
namespace_imports: std.StringArrayHashMapUnmanaged(std.StringArrayHashMapUnmanaged(void)) = .empty,
// The namespaces with an `mcfun load` or `mcfun tick`.
load_namespaces: std.StringArrayHashMapUnmanaged(void) = .empty,
tick_namespaces: std.StringArrayHashMapUnmanaged(void) = .empty,
// For each mcfun, the mcfuns that its body calls.
mcfun_calls: std.StringHashMapUnmanaged(std.StringArrayHashMapUnmanaged(void)) = .empty,
// Set when a recursive call saves temps, so that `poplar/load` clears the stack.
uses_stack: bool = false,
// `{a:"$(a)"}` for the macro arguments that the current mcfun uses. Calls to its generated functions pass it on.
forwarded_args: ?[]const u8 = null,
// The `$(name)` keys that the current mcfun uses.
macro_keys: std.StringArrayHashMapUnmanaged(void) = .empty,
// Names the construct that `return` cannot be used in, while its body is compiled.
// The test function of the innermost `while`, for `break` and `continue`.
current_loop: ?[]const u8 = null,
// True in a `while` or `execute (...)` body. There `return` stores the value and returns 1, so the caller can pass it on.
return_through_body: bool = false,
// The namespace of the pack. `text(#hp)` writes it into a text component.
namespace: []const u8 = "ns",
// True while a namespace's `mcfun load` is compiled. Only there `onEvent` is allowed.
in_load: bool = false,
events: std.ArrayList(Event) = .empty,
// Removes every data local of the current mcfun. It runs at each exit, so no value is left for the next call.
current_cleanup: []const Ir.Command = &.{},
// The locals that are visible at the statement being compiled. A recursive call saves them.
live_locals: std.ArrayList(Environment.Local) = .empty,
// `#i_countdown` → where it comes from, so two different locals cannot get the same generated name.
local_names: std.StringHashMapUnmanaged(LocalOrigin) = .empty,
// Every local declaration, for the language server.
locals: std.ArrayList(LocalVariable) = .empty,
data_files: std.ArrayList(Ir.DataFile) = .empty,
// `data/<ns>/<folder>/<path>.json` → where it is declared, so two declarations cannot write one file.
data_file_paths: std.StringHashMapUnmanaged([]const u8) = .empty,
// The file path of each data file of a namespace, by its source name: `combat:isSitting` → `is_sitting`,
// `combat:checks/never` → itself. `self:name` and `ns:name` in Minecraft text look names up here and in `functions`.
data_file_names: std.StringArrayHashMapUnmanaged([]const u8) = .empty,
// `self`, `std` and the namespaces of the project's files: the ones whose ids in commands can be Poplar names.
poplar_namespaces: []const []const u8 = &.{"self"},
// The namespace of each source file (by its display path), for the language server.
file_namespaces: std.StringHashMapUnmanaged([]const u8) = .empty,
// The data files with an identifier name, for the language server.
named_data_files: std.StringArrayHashMapUnmanaged(NamedDataFile) = .empty,

pub fn init(gpa: std.mem.Allocator, command_tree: *const Commands) Self {
    return .{ .gpa = gpa, .command_tree = command_tree };
}

// `mcfun load` and `mcfun tick` of each namespace are run by the game. A program without a `namespace` line
// (in tests) is in the pack namespace.
pub fn addProgram(self: *Self, path: []const u8, program: Ast.Program, origin: Origin) CompileError!void {
    self.position.path = path;
    self.scope = self.scopeOf(if (program.namespace) |namespace| namespace.name else self.namespace, program.imports);
    try self.file_namespaces.put(self.gpa, path, self.scope.namespace);
    if (program.namespace) |namespace| {
        self.position.line = namespace.line;
        self.position.column = namespace.column;
        if (!Declarations.isValidNamespace(namespace.name)) return self.addError("namespace '{s}' must only use a-z, 0-9, '_' and '.'", .{namespace.name});
        if (origin == .project and std.mem.eql(u8, namespace.name, std_namespace)) return self.addError("the namespace 'std' belongs to the standard library", .{});
    }

    const imports = try self.namespace_imports.getOrPut(self.gpa, self.scope.namespace);
    if (!imports.found_existing) imports.value_ptr.* = .empty;
    for (program.imports) |import| {
        self.position.line = import.line;
        self.position.column = import.column;
        if (std.mem.eql(u8, import.name, self.scope.namespace)) {
            try self.addError("a file does not import its own namespace '{s}'", .{import.name});
            continue;
        }
        try imports.value_ptr.put(self.gpa, import.name, {});
    }

    for (program.functions) |*function| {
        if (origin == .project) {
            if (std.mem.eql(u8, function.name, "load")) try self.load_namespaces.put(self.gpa, self.scope.namespace, {});
            if (std.mem.eql(u8, function.name, "tick")) try self.tick_namespaces.put(self.gpa, self.scope.namespace, {});
        }

        if (Calls.isBuiltin(function.name)) {
            self.position.line = function.line;
            try self.addError("'{s}' is a built-in function, so it cannot be defined", .{function.name});
            continue;
        }

        const entry = try self.functions.getOrPut(self.gpa, try Declarations.qualifiedKey(self, self.scope.namespace, function.name));

        const located: Located = .{
            .path = path,
            .function = function,
            .origin = origin,
            .namespace = self.scope.namespace,
            .imports = program.imports,
            .ir_name = try Declarations.functionName(self, self.scope.namespace, function.name),
        };
        if (entry.found_existing) {
            try Declarations.addDuplicateError(self, entry.value_ptr.*, located);
            continue;
        }
        entry.value_ptr.* = located;
    }

    for (program.globals) |global| {
        self.position.path = path;
        self.position.line = global.line;
        self.position.column = global.column;
        try Declarations.addGlobal(self, global.decl);
    }

    for (program.data_files) |data_file| {
        self.position.path = path;
        self.position.line = data_file.line;
        self.position.column = data_file.column;
        try Declarations.addDataFile(self, data_file);
    }
}

pub const NamedDataFile = struct {
    type_word: []const u8,
    id: []const u8,
    path: []const u8,
    line: usize,
};

pub fn compile(self: *Self) CompileError!Ir.Program {
    self.poplar_namespaces = try std.mem.concat(self.gpa, []const u8, &.{ &.{"self"}, self.namespace_imports.keys() });
    var mc_functions: std.ArrayList(Ir.McFunction) = .empty;
    try Calls.buildCallGraph(self);
    const used = try Load.reachableFromProject(self);
    var paths: std.StringHashMapUnmanaged([]const u8) = .empty;

    for (self.functions.keys(), self.functions.values()) |function_key, located| {
        const function = located.function;
        // `import std;` costs nothing for the std mcfuns that the project never calls.
        if (located.origin == .std and !used.contains(function_key)) continue;

        self.position.path = located.path;
        self.position.line = function.line;
        self.position.column = null;
        self.scope = self.scopeOf(located.namespace, located.imports);

        // The file name is the snake_case of the name (`playerDied` → `player_died`), so both must be valid and unique.
        const path = try std.fmt.allocPrint(self.gpa, "{f}", .{Writer.functionPath(function.name)});
        if (!Config.isValidResourceName(path)) {
            try self.addError("mcfun name '{s}' must only use letters, 0-9, '_', '.' and '-'", .{function.name});
            continue;
        }
        const path_entry = try paths.getOrPut(self.gpa, try Declarations.functionName(self, located.namespace, path));
        if (path_entry.found_existing) {
            try self.addError("mcfun '{s}' and '{s}' have the same file name '{s}.mcfunction'", .{ path_entry.value_ptr.*, function.name, path });
            continue;
        }
        path_entry.value_ptr.* = function.name;

        var macro_keys: std.StringArrayHashMapUnmanaged(void) = .empty;
        try collectMacroKeys(self.gpa, function.body, &macro_keys);
        self.macro_keys = macro_keys;
        const is_hook = located.origin == .project and (std.mem.eql(u8, function.name, "load") or std.mem.eql(u8, function.name, "tick"));
        if (is_hook and macro_keys.count() > 0) {
            try self.addError("mcfun '{s}' is run by the game, so it gets no macro arguments and cannot use '$({s})'", .{ function.name, macro_keys.keys()[0] });
            continue;
        }

        self.mcfun = .{
            .folder = try Ir.generatedFolder(self.gpa, try Declarations.outputPath(self, located.namespace, function.name)),
            .name = located.ir_name,
            .key = function_key,
        };
        self.generated_count = 0;
        self.live_locals.clearRetainingCapacity();
        self.current_cleanup = try self.localCleanup(function.body);
        self.in_load = located.origin == .project and std.mem.eql(u8, function.name, "load");

        var env: Environment = .{};
        var forwarded: std.ArrayList(u8) = .empty;
        for (macro_keys.keys(), 0..) |key, index| {
            try forwarded.appendSlice(self.gpa, if (index == 0) "{" else ",");
            try forwarded.print(self.gpa, "{s}:\"$({s})\"", .{ key, key });
        }
        if (macro_keys.count() > 0) try forwarded.append(self.gpa, '}');
        self.forwarded_args = if (macro_keys.count() > 0) try forwarded.toOwnedSlice(self.gpa) else null;

        var commands: std.ArrayList(Ir.Command) = .empty;
        try self.compileBlock(function.body, &env, &commands);
        if (function.body.len == 0 or !isJump(function.body[function.body.len - 1].kind)) try commands.appendSlice(self.gpa, self.current_cleanup);

        try mc_functions.append(self.gpa, .{
            .name = located.ir_name,
            .commands = try commands.toOwnedSlice(self.gpa),
        });
    }

    try mc_functions.appendSlice(self.gpa, self.generated.items);
    try Optimizer.dropUnusedArguments(self.gpa, mc_functions.items);

    for (mc_functions.items) |*function| function.commands = try Optimizer.optimizeFunction(self.gpa, function.name, function.commands);
    const optimized = try Optimizer.inlineSmallFunctions(self.gpa, mc_functions.items);
    try Load.removeUnusedConstants(self, optimized);

    // Only the tick tag calls these, so they come after the inline pass, which removes functions that nothing calls.
    var functions: std.ArrayList(Ir.McFunction) = .fromOwnedSlice(@constCast(optimized));
    const ticks = try Load.hookNames(self, self.tick_namespaces, "tick");
    try Load.appendEventFunctions(self, &functions, ticks);

    const needs_load = self.globals.count() + self.data_globals.count() > 0 or self.load_namespaces.count() > 0 or self.uses_stack or self.events.items.len > 0;
    const program_functions = try functions.toOwnedSlice(self.gpa);
    return .{
        .functions = program_functions,
        .load = if (needs_load) try Load.buildLoadFunction(self, program_functions) else null,
        .tick = if (self.events.items.len > 0) try self.gpa.dupe([]const u8, &.{"poplar/tick"}) else ticks,
        .data_files = self.data_files.items,
    };
}

pub fn scopeOf(self: *const Self, namespace: []const u8, imports: []const Ast.Import) Scope {
    return .{ .namespace = namespace, .imports = imports, .output_namespace = Declarations.outputNamespace(self, namespace) };
}

pub fn compileBlock(self: *Self, body: []const Ast.Stmt, env: *Environment, commands: *std.ArrayList(Ir.Command)) CompileError!void {
    const outer_live_count = self.live_locals.items.len;
    defer self.live_locals.shrinkRetainingCapacity(outer_live_count);

    for (body, 0..) |statement, index| {
        try self.compileStatement(statement, env, commands);

        if (isJump(statement.kind) and index + 1 < body.len) {
            const next = body[index + 1];
            return self.errors.append(self.gpa, .{
                .path = self.position.path,
                .line = next.line,
                .column = next.column,
                .message = "code after 'return', 'break' or 'continue' is never run",
            });
        }
    }
}

pub fn compileStatement(self: *Self, statement: Ast.Stmt, env: *Environment, commands: *std.ArrayList(Ir.Command)) CompileError!void {
    const outer_line = self.position.line;
    const outer_column = self.position.column;
    self.position.line = statement.line;
    self.position.column = statement.column;
    defer {
        self.position.line = outer_line;
        self.position.column = outer_column;
    }

    switch (statement.kind) {
        .expression => |expression| {
            const outer_position = self.enterExpression(expression);
            defer self.restorePosition(outer_position);
            switch (expression.kind) {
                .call => |call| try Calls.compileCall(self, call, env, commands),
                else => try self.addError("only calls can be used as statements", .{}),
            }
        },
        .var_decl => |var_decl| try self.compileVarDecl(var_decl, env, commands),
        .assign => |assign| try self.compileAssign(assign, env, commands),
        .@"for" => |loop| try self.compileFor(loop, env, commands),
        .@"return" => |value| try self.compileReturn(value, env, commands),
        .@"break" => {
            if (self.current_loop == null) return self.addError("'break' must be inside a 'while' (not in 'execute (...)')", .{});
            try commands.append(self.gpa, .{ .return_value = 0 });
        },
        .@"continue" => {
            const loop = self.current_loop orelse return self.addError("'continue' must be inside a 'while' (not in 'execute (...)')", .{});
            try commands.append(self.gpa, .{ .return_run = try self.createCommand(Calls.generatedCall(self, loop)) });
        },
        .@"while" => |loop| try self.compileWhile(loop, env, commands),
        .@"if" => |if_statement| try self.compileIf(if_statement, env, commands),
        .command => |command| try MinecraftText.compileCommand(self, command, statement.column + 1, env, commands),
        .execute => |execute| try MinecraftText.compileExecute(self, execute, env, commands),
    }
}

// Compiles an `execute (...)` body. A body that can `return` is always a function, called as
// `if function ...`: it returns 1 for each entity that returns from the mcfun, and then the mcfun returns.
pub fn compileJumpBody(self: *Self, body: []const Ast.Stmt, env: *Environment, loop: ?[]const u8) CompileError!?Ir.Command {
    const outer_loop = self.current_loop;
    const outer_through_body = self.return_through_body;
    self.current_loop = loop;
    self.return_through_body = true;
    defer {
        self.current_loop = outer_loop;
        self.return_through_body = outer_through_body;
    }

    if (!containsReturn(body)) return self.compileBodyAsCommand(body, env, "execute");

    var branch_env: Environment = .{ .outer = env, .runtime_branch = true };
    var body_commands: std.ArrayList(Ir.Command) = .empty;
    try self.compileBlock(body, &branch_env, &body_commands);
    const name = try self.newGeneratedName("execute");
    try self.generated.append(self.gpa, .{ .name = name, .commands = try body_commands.toOwnedSlice(self.gpa) });

    self.return_through_body = outer_through_body;
    return try self.onBodyReturn(name);
}

// `execute if function <body> run ...`: when the body returned, return from this function too.
pub fn onBodyReturn(self: *Self, body_name: []const u8) CompileError!Ir.Command {
    const pass_on: Ir.Command = if (self.return_through_body) .{ .return_value = 1 } else .{ .return_run = try self.createCommand(.{ .score_get = try self.resultScore() }) };
    const checks = try self.gpa.dupe(Ir.Check, &.{.{ .negated = false, .score_test = .{ .function_returns = body_name } }});
    return .{ .execute = .{ .checks = checks, .run = try self.createCommand(pass_on) } };
}

// The value of a `return` inside a `while` or `execute (...)` body, on its way out.
pub fn resultScore(self: *Self) CompileError!Ir.Score {
    return .{ .holder = try std.fmt.allocPrint(self.gpa, "#poplar.{s}.result", .{self.mcfun.folder}), .namespace = self.scope.output_namespace };
}

pub fn compileVarDecl(self: *Self, var_decl: Ast.VarDecl, env: *Environment, commands: *std.ArrayList(Ir.Command)) CompileError!void {
    switch (var_decl.target.storage) {
        .compile_time => {},
        .score => return self.declareLocal(.score, var_decl, env, commands),
        .data => return self.declareLocal(.data, var_decl, env, commands),
        .entity_data => return self.addError("entity data cannot be declared with 'var'. Set it: '@s.$path = ...;'", .{}),
    }
    if (Values.containsRuntimeValue(self, var_decl.value, env)) {
        return self.addError("'{s}' is a build-time constant, but this value only exists in the game. Use 'var #{s}' for a score or 'var ${s}' for data", .{ var_decl.target.name, var_decl.target.name, var_decl.target.name });
    }

    const value = try Values.evaluate(self, var_decl.value, env) orelse return;
    if (!try env.declare(self.gpa, var_decl.target.name, value)) {
        try self.addError("'{s}' is already declared", .{var_decl.target.name});
    }
}

// `var #i = 10;` in `mcfun countdown` is the fake player `#i_countdown` in `<ns>`. `var $names = [];` is
// `names_countdown` in `<ns>:data`. The value is set here, on every call.
pub fn declareLocal(self: *Self, kind: Environment.Local.Kind, var_decl: Ast.VarDecl, env: *Environment, commands: *std.ArrayList(Ir.Command)) CompileError!void {
    const name = var_decl.target.name;
    const sigil: u8 = if (kind == .score) '#' else '$';
    if (kind == .data and pathRoot(name).len != name.len) {
        return self.addError("'var' declares a whole variable. Set '${s}' after it", .{name});
    }
    const global_key = try Declarations.qualifiedKey(self, self.scope.namespace, name);
    const is_global = if (kind == .score) self.globals.contains(global_key) else self.data_globals.contains(global_key);
    const key = try std.fmt.allocPrint(self.gpa, "{c}{s}", .{ sigil, name });
    if (is_global or env.get(key) != null) return self.addError("'{s}' is already declared", .{key});

    const generated_base = try std.fmt.allocPrint(self.gpa, "{s}_{s}", .{ name, self.mcfun.folder });
    const generated_name = if (kind == .score) try std.fmt.allocPrint(self.gpa, "#{s}", .{generated_base}) else generated_base;

    const origin: LocalOrigin = .{ .name = name, .owner = self.mcfun.folder };
    const name_entry = try self.local_names.getOrPut(self.gpa, try std.fmt.allocPrint(self.gpa, "{c}{s}", .{ sigil, generated_base }));
    if (name_entry.found_existing and !sameOrigin(name_entry.value_ptr.*, origin)) {
        const other = name_entry.value_ptr.*;
        return self.addError("'{c}{s}' in '{s}' and '{c}{s}' in '{s}' both become '{s}'. Rename one", .{ sigil, other.name, other.owner, sigil, name, self.mcfun.folder, generated_name });
    }
    name_entry.value_ptr.* = origin;

    const local: Environment.Local = .{ .kind = kind, .generated_name = generated_name, .owner = self.mcfun.name };
    switch (kind) {
        .score => {
            self.temp_count = 0;
            try Scores.compileInto(self, .{ .holder = generated_name, .owner = self.mcfun.name, .namespace = self.scope.output_namespace }, var_decl.value, env, commands);
        },
        .data => try Data.compileDataAssign(self, Data.dataLocal(self, generated_name), var_decl.value, env, commands),
    }

    _ = try env.declare(self.gpa, key, .{ .local = local });
    try self.live_locals.append(self.gpa, local);
    for (self.locals.items) |existing| {
        if (existing.line == self.position.line and existing.column == self.position.column and std.mem.eql(u8, existing.path, self.position.path)) break;
    } else try self.locals.append(self.gpa, .{
        .name = name,
        .local = local,
        .path = self.position.path,
        .line = self.position.line,
        .column = self.position.column,
    });
}

// `data remove` for each data local declared anywhere in the body. A failed `set from` keeps the old value, so
// without this a local could hold a value from an earlier call. `data remove` on a missing key fails without effect.
// A score local needs nothing: every score write (`set`, `operation`, `store result`) overwrites it, and a failure writes 0.
pub fn localCleanup(self: *Self, body: []const Ast.Stmt) CompileError![]const Ir.Command {
    var names: std.StringArrayHashMapUnmanaged(void) = .empty;
    try collectDataLocalNames(self.gpa, body, &names);

    var cleanup: std.ArrayList(Ir.Command) = .empty;
    for (names.keys()) |name| {
        const generated_name = try std.fmt.allocPrint(self.gpa, "{s}_{s}", .{ name, self.mcfun.folder });
        try cleanup.append(self.gpa, .{ .data_remove = Data.dataLocal(self, generated_name) });
    }
    return cleanup.toOwnedSlice(self.gpa);
}

pub fn collectDataLocalNames(gpa: std.mem.Allocator, body: []const Ast.Stmt, names: *std.StringArrayHashMapUnmanaged(void)) CompileError!void {
    for (body) |statement| switch (statement.kind) {
        .var_decl => |var_decl| if (var_decl.target.storage == .data) try names.put(gpa, var_decl.target.name, {}),
        .@"if" => |if_statement| {
            try collectDataLocalNames(gpa, if_statement.then_body, names);
            if (if_statement.else_body) |else_body| try collectDataLocalNames(gpa, else_body, names);
        },
        .@"while" => |loop| try collectDataLocalNames(gpa, loop.body, names),
        .@"for" => |loop| try collectDataLocalNames(gpa, loop.body, names),
        .execute => |execute| try collectDataLocalNames(gpa, execute.body, names),
        else => {},
    };
}

// The `$(name)` keys that a body uses, in expressions and in Minecraft text.
pub fn collectMacroKeys(gpa: std.mem.Allocator, body: []const Ast.Stmt, keys: *std.StringArrayHashMapUnmanaged(void)) CompileError!void {
    for (body) |statement| switch (statement.kind) {
        .var_decl => |var_decl| try collectExprMacroKeys(gpa, var_decl.value, keys),
        .assign => |assign| try collectExprMacroKeys(gpa, assign.value, keys),
        .@"return" => |value| if (value) |expression| try collectExprMacroKeys(gpa, expression, keys),
        .@"break", .@"continue" => {},
        .@"if" => |if_statement| {
            try collectExprMacroKeys(gpa, if_statement.condition, keys);
            try collectMacroKeys(gpa, if_statement.then_body, keys);
            if (if_statement.else_body) |else_body| try collectMacroKeys(gpa, else_body, keys);
        },
        .@"while" => |loop| {
            try collectExprMacroKeys(gpa, loop.condition, keys);
            try collectMacroKeys(gpa, loop.body, keys);
        },
        .@"for" => |loop| {
            try collectExprMacroKeys(gpa, loop.start, keys);
            try collectExprMacroKeys(gpa, loop.end, keys);
            try collectMacroKeys(gpa, loop.body, keys);
        },
        .command => |command| try collectPartsMacroKeys(gpa, command.parts, keys),
        .execute => |execute| {
            try collectPartsMacroKeys(gpa, execute.subcommands, keys);
            try collectMacroKeys(gpa, execute.body, keys);
        },
        .expression => |expression| try collectExprMacroKeys(gpa, expression, keys),
    };
}

fn collectExprMacroKeys(gpa: std.mem.Allocator, expression: *const Ast.Expr, keys: *std.StringArrayHashMapUnmanaged(void)) CompileError!void {
    switch (expression.kind) {
        .macro_key => |name| try keys.put(gpa, name, {}),
        .prefix => |prefix| try collectExprMacroKeys(gpa, prefix.operand, keys),
        .infix => |infix| {
            try collectExprMacroKeys(gpa, infix.left, keys);
            try collectExprMacroKeys(gpa, infix.right, keys);
        },
        .call => |call| {
            for (call.args) |arg| try collectExprMacroKeys(gpa, arg, keys);
            if (call.with) |with| switch (with) {
                .value => |value| try collectExprMacroKeys(gpa, value, keys),
                .raw => |text| try collectTextMacroKeys(gpa, text, keys),
            };
        },
        .list => |elements| for (elements) |element| try collectExprMacroKeys(gpa, element, keys),
        .compound => |entries| for (entries) |entry| try collectExprMacroKeys(gpa, entry.value, keys),
        .minecraft_check => |parts| try collectPartsMacroKeys(gpa, parts, keys),
        .identifier, .number, .typed_number, .string, .boolean, .null, .selector => {},
    }
}

fn collectPartsMacroKeys(gpa: std.mem.Allocator, parts: []const Ast.CommandPart, keys: *std.StringArrayHashMapUnmanaged(void)) CompileError!void {
    for (parts) |part| switch (part.content) {
        .text => |text| try collectTextMacroKeys(gpa, text, keys),
        .insert => |expression| try collectExprMacroKeys(gpa, expression, keys),
    };
}

fn collectTextMacroKeys(gpa: std.mem.Allocator, text: []const u8, keys: *std.StringArrayHashMapUnmanaged(void)) CompileError!void {
    var rest = text;
    while (std.mem.indexOf(u8, rest, "$(")) |start| {
        const end = std.mem.indexOfScalarPos(u8, rest, start, ')') orelse return;
        try keys.put(gpa, rest[start + 2 .. end], {});
        rest = rest[end + 1 ..];
    }
}

pub fn sameOrigin(a: LocalOrigin, b: LocalOrigin) bool {
    return std.mem.eql(u8, a.name, b.name) and std.mem.eql(u8, a.owner, b.owner);
}

// `stats` in `stats.inventory[0]`.
pub fn pathRoot(path: []const u8) []const u8 {
    const end = std.mem.indexOfAny(u8, path, ".[") orelse path.len;
    return path[0..end];
}

pub fn compileAssign(self: *Self, assign: Ast.Assign, env: *Environment, commands: *std.ArrayList(Ir.Command)) CompileError!void {
    switch (assign.target.storage) {
        .compile_time => {},
        .score => return Scores.compileScoreAssign(self, assign.target, assign.value, env, commands),
        .data => {
            const target = try Data.dataPath(self, assign.target, env) orelse return;
            return Data.compileDataAssign(self, target, assign.value, env, commands);
        },
        .entity_data => {
            const target = try Data.entityDataPath(self, assign.target) orelse return;
            return Data.compileDataAssign(self, target, assign.value, env, commands);
        },
    }

    if (Values.containsRuntimeValue(self, assign.value, env)) return self.addError("a runtime value cannot be stored in a compile-time variable", .{});

    const value = try Values.evaluate(self, assign.value, env) orelse return;
    switch (env.assign(assign.target.name, value)) {
        .assigned => {},
        .not_found => try self.addError("unknown name '{s}'", .{assign.target.name}),
        .crosses_runtime_branch => {
            try self.addError("cannot change compile-time '{s}' inside a runtime 'if' or 'execute'", .{assign.target.name});
        },
    }
}

// The local `#name` or `$name` that is visible here.
pub fn localOf(env: *const Environment, sigil: u8, name: []const u8) ?Environment.Local {
    var buffer: [256]u8 = undefined;
    const key = std.fmt.bufPrint(&buffer, "{c}{s}", .{ sigil, name }) catch return null;
    const value = env.get(key) orelse return null;
    return if (value == .local) value.local else null;
}

pub fn ifContainsReturn(if_statement: Ast.If) bool {
    const else_body = if_statement.else_body orelse &.{};
    return containsReturn(if_statement.then_body) or containsReturn(else_body);
}

pub fn containsReturn(body: []const Ast.Stmt) bool {
    for (body) |statement| {
        const found = switch (statement.kind) {
            .@"return" => true,
            .@"if" => |if_statement| ifContainsReturn(if_statement),
            .@"for" => |loop| containsReturn(loop.body),
            .@"while" => |loop| containsReturn(loop.body),
            .execute => |execute| containsReturn(execute.body),
            else => false,
        };
        if (found) return true;
    }
    return false;
}

pub fn isJump(kind: Ast.Stmt.Kind) bool {
    return kind == .@"return" or kind == .@"break" or kind == .@"continue";
}

// `return`, `break` or `continue` of this loop level. A `break` in an inner `while` belongs to that loop.
pub fn ifContainsJump(if_statement: Ast.If) bool {
    const else_body = if_statement.else_body orelse &.{};
    return containsJump(if_statement.then_body) or containsJump(else_body);
}

pub fn containsJump(body: []const Ast.Stmt) bool {
    for (body) |statement| {
        const found = switch (statement.kind) {
            .@"return", .@"break", .@"continue" => true,
            .@"if" => |if_statement| ifContainsJump(if_statement),
            .@"for" => |loop| containsJump(loop.body),
            .@"while" => |loop| containsReturn(loop.body),
            .execute => |execute| containsReturn(execute.body),
            else => false,
        };
        if (found) return true;
    }
    return false;
}

// True if the body can leave this loop level with `break` or `return`.
pub fn containsExit(body: []const Ast.Stmt) bool {
    for (body) |statement| {
        const found = switch (statement.kind) {
            .@"return", .@"break" => true,
            .@"if" => |if_statement| containsExit(if_statement.then_body) or containsExit(if_statement.else_body orelse &.{}),
            .@"for" => |loop| containsExit(loop.body),
            .@"while" => |loop| containsReturn(loop.body),
            .execute => |execute| containsReturn(execute.body),
            else => false,
        };
        if (found) return true;
    }
    return false;
}

// True if the then body and every `else if` and `else` body end with `return`, `break` or `continue`.
// The final `else` is optional.
pub fn branchesEndWithJump(if_statement: Ast.If) bool {
    if (!endsWithJump(if_statement.then_body)) return false;

    const else_body = if_statement.else_body orelse return true;
    if (else_body.len == 1 and else_body[0].kind == .@"if") return branchesEndWithJump(else_body[0].kind.@"if");
    return endsWithJump(else_body);
}

pub fn endsWithJump(body: []const Ast.Stmt) bool {
    if (body.len == 0) return false;

    return switch (body[body.len - 1].kind) {
        .@"return", .@"break", .@"continue" => true,
        .@"if" => |if_statement| if_statement.else_body != null and branchesEndWithJump(if_statement),
        else => false,
    };
}

pub fn compileIf(self: *Self, if_statement: Ast.If, env: *Environment, commands: *std.ArrayList(Ir.Command)) CompileError!void {
    self.temp_count = 0;
    var setup: std.ArrayList(Ir.Command) = .empty;
    const condition = try Conditions.lowerCondition(self, if_statement.condition, env, false, &setup) orelse return;

    switch (condition) {
        .constant => |is_true| {
            const body = if (is_true) if_statement.then_body else if_statement.else_body orelse return;
            var branch_env: Environment = .{ .outer = env };
            try self.compileBlock(body, &branch_env, commands);
        },
        .clauses => |clauses| {
            // Each returning branch returns from this function, so the branches go here directly, with no wrapper.
            if (ifContainsJump(if_statement)) {
                if (!branchesEndWithJump(if_statement)) {
                    return self.addError("if one branch of an 'if' contains 'return', 'break' or 'continue', every branch must end with one", .{});
                }
                return self.appendBranches(if_statement, env, commands, condition, setup.items, false);
            }

            if (if_statement.else_body == null and clauses.len == 1) {
                const run = try self.compileBodyAsCommand(if_statement.then_body, env, "if") orelse return;
                try commands.appendSlice(self.gpa, setup.items);
                try commands.append(self.gpa, .{ .execute = .{ .checks = clauses[0], .run = try self.createCommand(run) } });
                return;
            }

            const wrapper_name = try self.newGeneratedName("if");
            var wrapper: std.ArrayList(Ir.Command) = .empty;
            try self.appendBranches(if_statement, env, &wrapper, condition, setup.items, false);

            try self.generated.append(self.gpa, .{ .name = wrapper_name, .commands = try wrapper.toOwnedSlice(self.gpa) });
            try commands.append(self.gpa, Calls.generatedCall(self, wrapper_name));
        },
    }
}

// Each branch returns from the wrapper, so later branches and the else body run only if no earlier branch ran.
pub fn appendBranches(
    self: *Self,
    if_statement: Ast.If,
    env: *Environment,
    wrapper: *std.ArrayList(Ir.Command),
    condition: Condition,
    setup: []const Ir.Command,
    after_runtime_branch: bool,
) CompileError!void {
    try wrapper.appendSlice(self.gpa, setup);

    switch (condition) {
        .constant => |is_true| if (is_true) {
            var branch_env: Environment = .{ .outer = env, .runtime_branch = after_runtime_branch };
            return self.compileBlock(if_statement.then_body, &branch_env, wrapper);
        },
        .clauses => |clauses| {
            const body = try self.compileBodyAsCommand(if_statement.then_body, env, "if");
            const run: Ir.Command = if (body) |command| try self.returnRun(command) else .{ .return_value = 0 };
            const run_pointer = try self.createCommand(run);

            for (clauses) |checks| {
                try wrapper.append(self.gpa, .{ .execute = .{ .checks = checks, .run = run_pointer } });
            }
        },
    }

    const is_runtime = after_runtime_branch or condition == .clauses;
    const else_body = if_statement.else_body orelse return;

    if (else_body.len == 1 and else_body[0].kind == .@"if") {
        const else_if = else_body[0].kind.@"if";
        // The rest of the chain belongs to this `else if`. `compileStatement` restores the position after the chain.
        self.position.line = else_body[0].line;
        self.position.column = else_body[0].column;
        self.temp_count = 0;
        var else_setup: std.ArrayList(Ir.Command) = .empty;
        const else_condition = try Conditions.lowerCondition(self, else_if.condition, env, false, &else_setup) orelse return;
        return self.appendBranches(else_if, env, wrapper, else_condition, else_setup.items, is_runtime);
    }

    var else_env: Environment = .{ .outer = env, .runtime_branch = is_runtime };
    try self.compileBlock(else_body, &else_env, wrapper);
}

// `kind` names a generated function for a body with more than one command: `if` or `execute`.
pub fn compileBodyAsCommand(self: *Self, body: []const Ast.Stmt, env: *Environment, kind: []const u8) CompileError!?Ir.Command {
    var branch_env: Environment = .{ .outer = env, .runtime_branch = true };
    var body_commands: std.ArrayList(Ir.Command) = .empty;
    try self.compileBlock(body, &branch_env, &body_commands);

    switch (body_commands.items.len) {
        0 => return null,
        1 => return body_commands.items[0],
        else => {
            const name = try self.newGeneratedName(kind);
            try self.generated.append(self.gpa, .{ .name = name, .commands = try body_commands.toOwnedSlice(self.gpa) });
            return Calls.generatedCall(self, name);
        },
    }
}

pub fn newGeneratedName(self: *Self, kind: []const u8) CompileError![]const u8 {
    defer self.generated_count += 1;
    const path = try std.fmt.allocPrint(self.gpa, "poplar/{s}/{s}_{d}", .{ self.mcfun.folder, kind, self.generated_count });
    const namespace = self.scope.output_namespace orelse return path;
    return std.fmt.allocPrint(self.gpa, "{s}:{s}", .{ namespace, path });
}

pub fn createExpr(self: *Self, expression: Ast.Expr) CompileError!*const Ast.Expr {
    const pointer = try self.gpa.create(Ast.Expr);
    pointer.* = expression;
    return pointer;
}

pub fn createCommand(self: *Self, command: Ir.Command) CompileError!*const Ir.Command {
    const pointer = try self.gpa.create(Ir.Command);
    pointer.* = command;
    return pointer;
}

pub fn compileReturn(self: *Self, value: ?*const Ast.Expr, env: *Environment, commands: *std.ArrayList(Ir.Command)) CompileError!void {
    if (self.return_through_body) {
        const result = try self.resultScore();
        self.temp_count = 0;
        if (value) |expression| {
            try Scores.compileInto(self, result, expression, env, commands);
        } else {
            try commands.append(self.gpa, .{ .score_set = .{ .score = result, .value = 0 } });
        }
        try commands.appendSlice(self.gpa, self.current_cleanup);
        return commands.append(self.gpa, .{ .return_value = 1 });
    }

    const expression = value orelse {
        try commands.appendSlice(self.gpa, self.current_cleanup);
        return commands.append(self.gpa, .{ .return_value = 0 });
    };

    if (!Values.containsRuntimeValue(self, expression, env)) {
        const result = try Values.evaluate(self, expression, env) orelse return;
        const number = try Scores.toScoreValue(self, result) orelse return;
        try commands.appendSlice(self.gpa, self.current_cleanup);
        return commands.append(self.gpa, .{ .return_value = number });
    }

    self.temp_count = 0;
    if (expression.kind == .macro_key) {
        try commands.appendSlice(self.gpa, self.current_cleanup);
        return commands.append(self.gpa, .{ .return_param = expression.kind.macro_key });
    }
    // The value can read a local, so it is computed before the locals are removed.
    if (self.current_cleanup.len > 0) {
        const temp = try Scores.newTemp(self);
        try Scores.compileInto(self, temp, expression, env, commands);
        try commands.appendSlice(self.gpa, self.current_cleanup);
        return commands.append(self.gpa, .{ .return_run = try self.createCommand(.{ .score_get = temp }) });
    }
    const read: Ir.Command = blk: {
        if (expression.kind == .identifier) {
            const identifier = expression.kind.identifier;
            switch (identifier.storage) {
                .data, .entity_data => break :blk .{ .data_get = try Data.dataPathOf(self, identifier, env) orelse return },
                .score => break :blk .{ .score_get = try Scores.scoreSource(self, identifier, env) orelse return },
                .compile_time => {},
            }
        }

        const temp = try Scores.newTemp(self);
        try Scores.compileInto(self, temp, expression, env, commands);
        break :blk .{ .score_get = temp };
    };
    try commands.append(self.gpa, .{ .return_run = try self.createCommand(read) });
}

// Wraps a command in `return run`, unless it already returns.
pub fn returnRun(self: *Self, command: Ir.Command) CompileError!Ir.Command {
    return switch (command) {
        .return_run, .return_value, .return_param => command,
        else => .{ .return_run = try self.createCommand(command) },
    };
}

// A loop is two functions: `while_<n>` tests the condition and runs `while_<n>_body`, which runs `while_<n>` again.
pub fn compileWhile(self: *Self, loop: Ast.While, env: *Environment, commands: *std.ArrayList(Ir.Command)) CompileError!void {
    const test_name = try self.newGeneratedName("while");
    const body_name = try std.fmt.allocPrint(self.gpa, "{s}_body", .{test_name});

    self.temp_count = 0;
    var test_commands: std.ArrayList(Ir.Command) = .empty;
    const condition = try Conditions.lowerCondition(self, loop.condition, env, false, &test_commands) orelse return;
    // `while (true)` runs the body with no check. It must be able to stop.
    const always: []const []const Ir.Check = &.{&.{}};
    const clauses = switch (condition) {
        .constant => |is_true| if (!is_true) return else if (!containsExit(loop.body)) {
            return self.addError("this 'while' never stops: add a 'break' or 'return', or use a score or data value in the condition", .{});
        } else always,
        .clauses => |clauses| clauses,
    };

    const can_return = containsReturn(loop.body);
    // `continue` and a passed-on `return` use the result of the test, so then the test must always give one.
    const reads_test_result = can_return or containsContinue(loop.body);

    // `return run` stops the next clause from running the body again, and passes a return of the body on.
    const call_body = Calls.generatedCall(self, body_name);
    const run_body = try self.createCommand(if (clauses.len > 1 or can_return) .{ .return_run = try self.createCommand(call_body) } else call_body);
    for (clauses) |checks| {
        try test_commands.append(self.gpa, if (checks.len == 0) run_body.* else .{ .execute = .{ .checks = checks, .run = run_body } });
    }
    if (reads_test_result) try test_commands.append(self.gpa, .{ .return_value = 0 });

    const outer_loop = self.current_loop;
    const outer_through_body = self.return_through_body;
    self.current_loop = test_name;
    self.return_through_body = true;

    var body_env: Environment = .{ .outer = env, .runtime_branch = true };
    var body_commands: std.ArrayList(Ir.Command) = .empty;
    try self.compileBlock(loop.body, &body_env, &body_commands);
    const call_test = Calls.generatedCall(self, test_name);
    try body_commands.append(self.gpa, if (can_return) .{ .return_run = try self.createCommand(call_test) } else call_test);

    self.current_loop = outer_loop;
    self.return_through_body = outer_through_body;

    try self.generated.append(self.gpa, .{ .name = test_name, .commands = try test_commands.toOwnedSlice(self.gpa) });
    try self.generated.append(self.gpa, .{ .name = body_name, .commands = try body_commands.toOwnedSlice(self.gpa) });

    if (!can_return) return commands.append(self.gpa, call_test);
    if (self.forwarded_args == null) return commands.append(self.gpa, try self.onBodyReturn(test_name));

    // `if function` cannot pass the macro arguments, so the result of the loop goes through a temp.
    const returned = try Scores.newTemp(self);
    try commands.append(self.gpa, .{ .store_result = .{ .target = .{ .score = returned }, .run = try self.createCommand(call_test) } });
    const pass_on = (try self.onBodyReturn(test_name)).execute.run;
    const checks = try self.gpa.dupe(Ir.Check, &.{.{ .negated = false, .score_test = .{ .matches = .{ .score = returned, .min = 1, .max = 1 } } }});
    try commands.append(self.gpa, .{ .execute = .{ .checks = checks, .run = pass_on } });
}

// `continue` of this loop level.
pub fn containsContinue(body: []const Ast.Stmt) bool {
    for (body) |statement| {
        const found = switch (statement.kind) {
            .@"continue" => true,
            .@"if" => |if_statement| containsContinue(if_statement.then_body) or containsContinue(if_statement.else_body orelse &.{}),
            .@"for" => |loop| containsContinue(loop.body),
            else => false,
        };
        if (found) return true;
    }
    return false;
}

pub fn compileFor(self: *Self, loop: Ast.For, env: *Environment, commands: *std.ArrayList(Ir.Command)) CompileError!void {
    const start, const end = try self.evaluateRange(loop, env) orelse return;

    var i = start;
    while (i < end) : (i += 1) {
        var loop_env: Environment = .{ .outer = env };
        if (!try loop_env.declare(self.gpa, loop.capture, .{ .number = i })) {
            return self.addError("'{s}' is already declared", .{loop.capture});
        }

        const error_count = self.errors.items.len;
        try self.compileBlock(loop.body, &loop_env, commands);
        if (self.errors.items.len > error_count) return;
    }
}

pub fn evaluateRange(self: *Self, loop: Ast.For, env: *Environment) CompileError!?struct { i64, i64 } {
    const start = try Values.evaluate(self, loop.start, env) orelse return null;
    const end = try Values.evaluate(self, loop.end, env) orelse return null;

    if (start != .number or end != .number) {
        try self.addError("range bounds must be whole numbers", .{});
        return null;
    }
    if (start.number > end.number) {
        try self.addError("range start {d} is greater than end {d}", .{ start.number, end.number });
        return null;
    }
    return .{ start.number, end.number };
}

pub const SourcePosition = struct {
    path: []const u8 = "",
    line: usize = 0,
    column: ?usize = null,
};

// The namespace of the file or mcfun being compiled, the namespaces it imports, and where its files go (null: the pack).
pub const Scope = struct {
    namespace: []const u8 = "ns",
    imports: []const Ast.Import = &.{},
    output_namespace: ?[]const u8 = null,
};

pub const CurrentMcfun = struct {
    // As it appears in generated names (`Ir.generatedFolder`): `heal`, or `std.clamp` for std.
    folder: []const u8 = "",
    // The IR name (`combat:heal`), and the key with the source namespace (`combat:heal`, `std:clamp`).
    name: []const u8 = "",
    key: []const u8 = "",
};

// Errors inside an expression point to where it starts. Returns the outer position for `restorePosition`.
pub fn enterExpression(self: *Self, expression: *const Ast.Expr) SourcePosition {
    const outer: SourcePosition = .{ .path = self.position.path, .line = self.position.line, .column = self.position.column };
    self.position.line = expression.line;
    self.position.column = expression.column;
    return outer;
}

pub fn restorePosition(self: *Self, position: SourcePosition) void {
    self.position.path = position.path;
    self.position.line = position.line;
    self.position.column = position.column;
}

pub fn addError(self: *Self, comptime format: []const u8, args: anytype) CompileError!void {
    const message = try std.fmt.allocPrint(self.gpa, format, args);
    try self.errors.append(self.gpa, .{
        .path = self.position.path,
        .line = self.position.line,
        .column = self.position.column,
        .message = message,
    });
}

pub fn addErrorAt(self: *Self, column: usize, comptime format: []const u8, args: anytype) CompileError!void {
    const message = try std.fmt.allocPrint(self.gpa, format, args);
    try self.errors.append(self.gpa, .{
        .path = self.position.path,
        .line = self.position.line,
        .column = column,
        .message = message,
    });
}

pub fn compileForTest(arena: std.mem.Allocator, source: []const u8) !Self {
    var parser = try Parser.init(arena, Lexer.init(source));
    const program = try parser.parseProgram();
    try std.testing.expectEqual(0, parser.errors.items.len);

    const command_tree = try arena.create(Commands);
    command_tree.* = try .load(arena);

    var compiler = Self.init(arena, command_tree);
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

pub fn renderForTest(arena: std.mem.Allocator, program: Ir.Program, name: []const u8) ![]const u8 {
    for (program.functions) |function| {
        if (std.mem.eql(u8, function.name, name)) return Writer.renderFunction(arena, "ns", function);
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
    try std.testing.expectEqual(3, errors[0].line);
    try std.testing.expectEqual(5, errors[0].column);
    try std.testing.expectEqual(6, errors[1].line);
    try std.testing.expectEqual(13, errors[1].column);
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
    try std.testing.expectEqual(3, errors[0].line);
    try std.testing.expectEqualStrings("'break' must be inside a 'while' (not in 'execute (...)')", errors[1].message);
    try std.testing.expectEqualStrings("this 'while' never stops: add a 'break' or 'return', or use a score or data value in the condition", errors[2].message);
    try std.testing.expectEqualStrings("code after 'return', 'break' or 'continue' is never run", errors[3].message);
    try std.testing.expectEqual(10, errors[3].line);
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
