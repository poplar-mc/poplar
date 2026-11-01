const std = @import("std");
const Ast = @import("Ast.zig");
const Commands = @import("Commands.zig");
const Config = @import("Config.zig");
const Environment = @import("Environment.zig");
const Ir = @import("Ir.zig");
const Lexer = @import("Lexer.zig");
const Optimizer = @import("Optimizer.zig");
const Parser = @import("Parser.zig");
const Token = @import("Token.zig");
const Writer = @import("Writer.zig");

const Self = @This();

const CompileError = std.mem.Allocator.Error;

pub const Error = struct {
    path: []const u8,
    line: usize,
    column: ?usize = null,
    message: []const u8,
};

const Located = struct {
    path: []const u8,
    function: *const Ast.Function,
    origin: Origin,
};

// Where a source file comes from. `load` and `tick` are special only in the entry file.
pub const Origin = enum { entry, project, std };

// `onEvent(criteria, callback)`: the game counts the criteria in `<ns>.event_<n>`, and `poplar/tick` runs the callback.
const Event = struct {
    criteria: []const u8,
    callback: []const u8,
};

const Value = Environment.Value;

// The holder of the global value of each `#var`. A `#` holder is hidden from the sidebar.
const global_holder = "#global";

const GlobalScore = struct {
    path: []const u8,
    line: usize,
    initial_value: i32,
};

const CommandText = struct {
    text: []const u8,
    // Where each part starts in `text`, for mapping errors back to the source.
    text_starts: []const usize,
    // True if a `{{$x}}` insert makes the text a macro line for a helper function.
    is_macro: bool,
    uses_param: bool,
    // The runtime values that the text uses, each one time.
    inserts: []const Insert,
};

// A runtime value in `{{...}}`: `{{$stats.hp}}` is `$(stats_hp)` in the macro line. A macro argument is a
// top-level key, so any value that is not a whole `$` var is copied into `<ns>:poplar macro` under its name first.
const Insert = struct {
    const Source = union(enum) {
        data: Ir.DataPath,
        // A score, math or a value call, computed just before the helper is called.
        value: *const Ast.Expr,
    };

    macro_name: []const u8,
    source: Source,

    // A whole `$` var is read from `<ns>:data` as it is.
    fn isWholeDataVar(insert: Insert) bool {
        if (insert.source != .data or insert.source.data.holder != .storage) return false;
        return std.mem.eql(u8, insert.macro_name, insert.source.data.path);
    }
};

const LocalOrigin = struct {
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

const GlobalData = struct {
    path: []const u8,
    line: usize,
    // The initial value as SNBT: `20`, `20f` for `20 as float`, `{hp:20}`.
    initial_snbt: []const u8,
};

// Checks in OR-of-ANDs form: the condition is true if every check in one clause passes.
const Condition = union(enum) {
    constant: bool,
    clauses: []const []const Ir.Check,
};

const Operand = union(enum) {
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
current_mcfun: []const u8 = "",
current_path: []const u8 = "",
current_line: usize = 0,
current_column: ?usize = null,
// Set when the entry file defines `mcfun load` or `mcfun tick`.
has_load: bool = false,
has_tick: bool = false,
// For each mcfun, the mcfuns that its body calls.
mcfun_calls: std.StringHashMapUnmanaged(std.StringArrayHashMapUnmanaged(void)) = .empty,
// Set when a recursive call saves temps, so that `poplar/load` clears the stack.
uses_stack: bool = false,
// `{a:"$(a)"}` for the parameters of the current mcfun. Calls to its generated functions pass it on.
forwarded_args: ?[]const u8 = null,
// Names the construct that `return` cannot be used in, while its body is compiled.
// The test function of the innermost `while`, for `break` and `continue`.
current_loop: ?[]const u8 = null,
// True in a `while` or `execute (...)` body. There `return` stores the value and returns 1, so the caller can pass it on.
return_through_body: bool = false,
// The namespace of the pack. `text(#hp)` writes it into a text component.
namespace: []const u8 = "ns",
// True while the entry file's `mcfun load` is compiled. Only there `onEvent` is allowed.
in_entry_load: bool = false,
events: std.ArrayList(Event) = .empty,
// A `load` with only `onEvent` lines has no commands, so `poplar/load` does not call it.
load_is_empty: bool = false,
// Removes every data local of the current mcfun. It runs at each exit, so no value is left for the next call.
current_cleanup: []const Ir.Command = &.{},
// The locals that are visible at the statement being compiled. A recursive call saves them.
live_locals: std.ArrayList(Environment.Local) = .empty,
// `#i_countdown` → where it comes from, so two different locals cannot get the same generated name.
local_names: std.StringHashMapUnmanaged(LocalOrigin) = .empty,
// Every local declaration, for the language server.
locals: std.ArrayList(LocalVariable) = .empty,

pub fn init(gpa: std.mem.Allocator, command_tree: *const Commands) Self {
    return .{ .gpa = gpa, .command_tree = command_tree };
}

// Only in the entry file are `mcfun load` and `mcfun tick` run by the game.
pub fn addProgram(self: *Self, path: []const u8, program: Ast.Program, origin: Origin) CompileError!void {
    for (program.functions) |*function| {
        if (origin == .entry) {
            if (std.mem.eql(u8, function.name, "load")) self.has_load = true;
            if (std.mem.eql(u8, function.name, "tick")) self.has_tick = true;
        }

        if (isBuiltin(function.name)) {
            try self.addError("'{s}' is a built-in function, so it cannot be defined", .{function.name});
            continue;
        }

        const entry = try self.functions.getOrPut(self.gpa, function.name);

        const located: Located = .{ .path = path, .function = function, .origin = origin };
        if (entry.found_existing) {
            try self.addDuplicateError(entry.value_ptr.*, located);
            continue;
        }
        entry.value_ptr.* = located;
    }

    for (program.globals) |global| {
        self.current_path = path;
        self.current_line = global.line;
        self.current_column = global.column;
        try self.addGlobal(global.decl);
    }
}

// A name that the project and std both define is reported in the project file, where it can be renamed.
// Otherwise the later definition is reported.
fn addDuplicateError(self: *Self, existing: Located, later: Located) CompileError!void {
    const project_side, const other = if (existing.origin != .std and later.origin == .std) .{ existing, later } else .{ later, existing };
    self.current_path = project_side.path;
    self.current_line = project_side.function.line;
    self.current_column = null;
    if (other.origin == .std and project_side.origin != .std) {
        return self.addError("function '{s}' is already defined in {s}:{d}. Rename yours", .{ later.function.name, other.path, other.function.line });
    }
    try self.addError("function '{s}' is already defined at {s}:{d}", .{ later.function.name, other.path, other.function.line });
}

fn addGlobal(self: *Self, decl: Ast.VarDecl) CompileError!void {
    switch (decl.target.storage) {
        .score => {},
        .compile_time => return self.addError("only score (#) and data ($) variables can be declared at the top level", .{}),
        .data => return self.addDataGlobal(decl),
        .entity_data => return self.addError("entity data cannot be declared. Set it in an mcfun: '@s.$path = ...;'", .{}),
    }

    var env: Environment = .{};
    const value = try self.evaluate(decl.value, &env) orelse return;
    const initial_value = try self.toScoreValue(value) orelse return;

    const entry = try self.globals.getOrPut(self.gpa, decl.target.name);
    if (entry.found_existing) {
        const existing = entry.value_ptr.*;
        return self.addError("score '#{s}' is already declared at {s}:{d}", .{ decl.target.name, existing.path, existing.line });
    }

    entry.value_ptr.* = .{
        .path = self.current_path,
        .line = self.current_line,
        .initial_value = initial_value,
    };
}

fn addDataGlobal(self: *Self, decl: Ast.VarDecl) CompileError!void {
    if (pathRoot(decl.target.name).len != decl.target.name.len) {
        return self.addError("'var' declares a whole variable. Set '${s}' in an mcfun", .{decl.target.name});
    }
    var env: Environment = .{};
    const expression, const cast_type = splitCast(decl.value);
    const value = try self.evaluate(expression, &env) orelse return;
    if (value == .null) return self.addError("a data variable cannot start as null", .{});
    const initial_snbt = try self.castSnbt(value, cast_type) orelse return;

    const entry = try self.data_globals.getOrPut(self.gpa, decl.target.name);
    if (entry.found_existing) {
        const existing = entry.value_ptr.*;
        return self.addError("data '${s}' is already declared at {s}:{d}", .{ decl.target.name, existing.path, existing.line });
    }

    entry.value_ptr.* = .{
        .path = self.current_path,
        .line = self.current_line,
        .initial_snbt = initial_snbt,
    };
}

pub fn compile(self: *Self) CompileError!Ir.Program {
    var mc_functions: std.ArrayList(Ir.McFunction) = .empty;
    try self.buildCallGraph();
    const used = try self.reachableFromProject();
    var paths: std.StringHashMapUnmanaged([]const u8) = .empty;

    for (self.functions.values()) |located| {
        const function = located.function;
        // `import "std";` costs nothing for the std mcfuns that the project never calls.
        if (located.origin == .std and !used.contains(function.name)) continue;

        self.current_path = located.path;
        self.current_line = function.line;
        self.current_column = null;

        // The file name is the snake_case of the name (`playerDied` → `player_died`), so both must be valid and unique.
        const path = try std.fmt.allocPrint(self.gpa, "{f}", .{Writer.functionPath(function.name)});
        if (!Config.isValidResourceName(path)) {
            try self.addError("mcfun name '{s}' must only use letters, 0-9, '_', '.' and '-'", .{function.name});
            continue;
        }
        const path_entry = try paths.getOrPut(self.gpa, path);
        if (path_entry.found_existing) {
            try self.addError("mcfun '{s}' and '{s}' have the same file name '{s}.mcfunction'", .{ path_entry.value_ptr.*, function.name, path });
            continue;
        }
        path_entry.value_ptr.* = function.name;

        const is_hook = (self.has_load and std.mem.eql(u8, function.name, "load")) or
            (self.has_tick and std.mem.eql(u8, function.name, "tick"));
        if (is_hook and function.params.len > 0) {
            try self.addError("mcfun '{s}' is run by the game and cannot have parameters", .{function.name});
            continue;
        }

        self.current_mcfun = function.name;
        self.generated_count = 0;
        self.live_locals.clearRetainingCapacity();
        self.current_cleanup = try self.localCleanup(function.body);
        self.in_entry_load = located.origin == .entry and std.mem.eql(u8, function.name, "load");

        var env: Environment = .{};
        var forwarded: std.ArrayList(u8) = .empty;
        for (function.params, 0..) |param, index| {
            if (!try env.declare(self.gpa, param.name, .param)) try self.addError("param '{s}' is declared more than once", .{param.name});
            try forwarded.appendSlice(self.gpa, if (index == 0) "{" else ",");
            try forwarded.print(self.gpa, "{s}:\"$({s})\"", .{ param.name, param.name });
        }
        if (function.params.len > 0) try forwarded.append(self.gpa, '}');
        self.forwarded_args = if (function.params.len > 0) try forwarded.toOwnedSlice(self.gpa) else null;

        var commands: std.ArrayList(Ir.Command) = .empty;
        try self.compileBlock(function.body, &env, &commands);
        if (function.body.len == 0 or !isJump(function.body[function.body.len - 1].kind)) try commands.appendSlice(self.gpa, self.current_cleanup);

        try mc_functions.append(self.gpa, .{
            .name = function.name,
            .commands = try commands.toOwnedSlice(self.gpa),
        });
    }

    try mc_functions.appendSlice(self.gpa, self.generated.items);

    for (mc_functions.items) |*function| function.commands = try Optimizer.optimizeFunction(self.gpa, function.name, function.commands);
    const optimized = try Optimizer.inlineSmallFunctions(self.gpa, mc_functions.items);
    try self.removeUnusedConstants(optimized);

    // Only the tick tag calls these, so they come after the inline pass, which removes functions that nothing calls.
    var functions: std.ArrayList(Ir.McFunction) = .fromOwnedSlice(@constCast(optimized));
    try self.appendEventFunctions(&functions);
    self.load_is_empty = for (functions.items) |function| {
        if (std.mem.eql(u8, function.name, "load")) break function.commands.len == 0;
    } else true;

    const needs_load = self.globals.count() + self.data_globals.count() > 0 or self.has_load or self.uses_stack or self.events.items.len > 0;
    const program_functions = try functions.toOwnedSlice(self.gpa);
    return .{
        .functions = program_functions,
        .load = if (needs_load) try self.buildLoadFunction(program_functions) else null,
        .tick = if (self.events.items.len > 0) "poplar/tick" else if (self.has_tick) "tick" else null,
    };
}

// The mcfuns that a project mcfun can call, directly or through others. Event callbacks count as calls from `load`.
fn reachableFromProject(self: *Self) CompileError!std.StringHashMapUnmanaged(void) {
    var reached: std.StringHashMapUnmanaged(void) = .empty;
    var pending: std.ArrayList([]const u8) = .empty;
    for (self.functions.values()) |located| {
        if (located.origin != .std) try pending.append(self.gpa, located.function.name);
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
fn appendEventFunctions(self: *Self, functions: *std.ArrayList(Ir.McFunction)) CompileError!void {
    if (self.events.items.len == 0) return;

    var tick: std.ArrayList(Ir.Command) = .empty;
    for (self.events.items, 0..) |event, index| {
        const objective = try self.eventObjective(index);
        const name = try std.fmt.allocPrint(self.gpa, "poplar/event_{d}", .{index});
        const reset = try std.fmt.allocPrint(self.gpa, "scoreboard players reset @s {s}", .{objective});
        try functions.append(self.gpa, .{ .name = name, .commands = try self.gpa.dupe(Ir.Command, &.{ .{ .raw = reset }, .{ .function = event.callback } }) });

        const subcommands = try std.fmt.allocPrint(self.gpa, "as @a[scores={{{s}=1..}}] at @s", .{objective});
        try tick.append(self.gpa, .{ .execute_raw = .{ .subcommands = subcommands, .run = try self.createCommand(.{ .function = name }) } });
    }
    if (self.has_tick) try tick.append(self.gpa, .{ .function = "tick" });
    try functions.append(self.gpa, .{ .name = "poplar/tick", .commands = try tick.toOwnedSlice(self.gpa) });
}

fn eventObjective(self: *Self, index: usize) CompileError![]const u8 {
    return std.fmt.allocPrint(self.gpa, "{s}.event_{d}", .{ self.namespace, index });
}

// The optimizer can remove the last use of a constant, for example `*= #poplar.c1`.
fn removeUnusedConstants(self: *Self, functions: []const Ir.McFunction) CompileError!void {
    var index = self.constants.count();
    while (index > 0) {
        index -= 1;
        const holder = try std.fmt.allocPrint(self.gpa, "#poplar.c{d}", .{self.constants.keys()[index]});
        if (!isScoreRead(functions, .{ .holder = holder })) self.constants.orderedRemoveAt(index);
    }
}

fn isScoreRead(functions: []const Ir.McFunction, score: Ir.Score) bool {
    for (functions) |function| {
        for (function.commands) |command| {
            if (Optimizer.readsScore(command, score)) return true;
        }
    }
    return false;
}

// A score that is only used on entities (`@s.#mana`) needs no initial value on `#global`. A text part such as
// `text(#mana)` names `#global` in the command text, so that counts as a use too.
fn isGlobalValueUsed(self: *Self, functions: []const Ir.McFunction, name: []const u8) CompileError!bool {
    const score = globalScore(name);
    const objective = try std.fmt.allocPrint(self.gpa, "\"{s}.{s}\"", .{ self.namespace, name });
    for (functions) |function| {
        for (function.commands) |command| {
            if (Optimizer.readsScore(command, score) or mentionsGlobalHolder(command, objective)) return true;
        }
    }
    return false;
}

fn mentionsGlobalHolder(command: Ir.Command, objective: []const u8) bool {
    const text = switch (command) {
        .raw, .macro => |text| text,
        .function_with => |call| if (call.arguments == .compound) call.arguments.compound else return false,
        .execute => |execute| return mentionsGlobalHolder(execute.run.*, objective),
        .execute_raw => |execute| return mentionsGlobalHolder(execute.run.*, objective),
        .store_result => |store| return mentionsGlobalHolder(store.run.*, objective),
        .return_run => |run| return mentionsGlobalHolder(run.*, objective),
        else => return false,
    };
    return std.mem.indexOf(u8, text, global_holder) != null and std.mem.indexOf(u8, text, objective) != null;
}

// Runs after all mcfuns, so that every constant they use is known.
fn buildLoadFunction(self: *Self, functions: []const Ir.McFunction) CompileError!Ir.McFunction {
    var commands: std.ArrayList(Ir.Command) = .empty;

    // A run that stopped in the middle of a recursive call can leave frames behind.
    if (self.uses_stack) try commands.append(self.gpa, .stack_clear);
    try commands.append(self.gpa, .{ .add_objective = null });
    for (self.globals.keys()) |name| try commands.append(self.gpa, .{ .add_objective = name });
    for (self.events.items, 0..) |event, index| {
        const add = try std.fmt.allocPrint(self.gpa, "scoreboard objectives add {s} {s}", .{ try self.eventObjective(index), event.criteria });
        try commands.append(self.gpa, .{ .raw = add });
    }

    for (self.constants.keys()) |constant| {
        try commands.append(self.gpa, .{ .score_set = .{
            .score = try self.constantScore(constant),
            .value = constant,
        } });
    }

    for (self.globals.keys(), self.globals.values()) |name, global| {
        if (!try self.isGlobalValueUsed(functions, name)) continue;
        try commands.append(self.gpa, .{ .score_set_if_unset = .{
            .score = globalScore(name),
            .value = global.initial_value,
        } });
    }

    for (self.data_globals.keys(), self.data_globals.values()) |name, global| {
        try commands.append(self.gpa, .{ .data_set_if_unset = .{
            .target = .inStorage(.data, name),
            .snbt = global.initial_snbt,
        } });
    }

    if (self.has_load and !self.load_is_empty) try commands.append(self.gpa, .{ .function = "load" });

    return .{ .name = "poplar/load", .commands = try commands.toOwnedSlice(self.gpa) };
}

fn compileBlock(self: *Self, body: []const Ast.Stmt, env: *Environment, commands: *std.ArrayList(Ir.Command)) CompileError!void {
    const outer_live_count = self.live_locals.items.len;
    defer self.live_locals.shrinkRetainingCapacity(outer_live_count);

    for (body, 0..) |statement, index| {
        try self.compileStatement(statement, env, commands);

        if (isJump(statement.kind) and index + 1 < body.len) {
            const next = body[index + 1];
            return self.errors.append(self.gpa, .{
                .path = self.current_path,
                .line = next.line,
                .column = next.column,
                .message = "code after 'return', 'break' or 'continue' is never run",
            });
        }
    }
}

fn compileStatement(self: *Self, statement: Ast.Stmt, env: *Environment, commands: *std.ArrayList(Ir.Command)) CompileError!void {
    const outer_line = self.current_line;
    const outer_column = self.current_column;
    self.current_line = statement.line;
    self.current_column = statement.column;
    defer {
        self.current_line = outer_line;
        self.current_column = outer_column;
    }

    switch (statement.kind) {
        .expression => |expression| {
            const outer_position = self.enterExpression(expression);
            defer self.restorePosition(outer_position);
            switch (expression.kind) {
                .call => |call| try self.compileCall(call, env, commands),
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
            try commands.append(self.gpa, .{ .return_run = try self.createCommand(self.generatedCall(loop)) });
        },
        .@"while" => |loop| try self.compileWhile(loop, env, commands),
        .@"if" => |if_statement| try self.compileIf(if_statement, env, commands),
        .command => |command| try self.compileCommand(command, statement.column + 1, env, commands),
        .execute => |execute| try self.compileExecute(execute, env, commands),
    }
}

// `text_column` is the column where the command text starts, after the `/`.
fn compileCommand(self: *Self, command: Ast.Command, text_column: usize, env: *Environment, commands: *std.ArrayList(Ir.Command)) CompileError!void {
    const command_text = try self.buildCommandText(command.parts, env) orelse return;

    if (try self.command_tree.check(self.gpa, command_text.text)) |failure| {
        const column = text_column + sourceOffset(command.parts, command_text.text_starts, failure.at);
        return self.addErrorAt(column, "{s}", .{failure.message});
    }

    if (!command_text.is_macro) return commands.append(self.gpa, .{ .raw = command_text.text });

    const name = try self.newGeneratedName("macro");
    const macro_commands = try self.gpa.dupe(Ir.Command, &.{.{ .macro = command_text.text }});
    try self.generated.append(self.gpa, .{ .name = name, .commands = macro_commands });
    try self.callMacroHelper(name, command_text, command_text.uses_param, env, commands);
}

// A macro call gets its arguments from one place. A helper that also needs the parameters of the mcfun,
// or a path such as `$stats.hp`, gets one compound in `<ns>:poplar macro`: the parameters, then each value it uses.
fn callMacroHelper(self: *Self, name: []const u8, command_text: CommandText, needs_params: bool, env: *Environment, commands: *std.ArrayList(Ir.Command)) CompileError!void {
    const only_whole_vars = for (command_text.inserts) |insert| {
        if (!insert.isWholeDataVar()) break false;
    } else true;
    if (!needs_params and only_whole_vars) return commands.append(self.gpa, .{ .function_with = .{ .name = name, .arguments = .data_storage } });

    // Old keys from an earlier helper do no harm, because a macro line reads only the names it uses.
    if (needs_params) try commands.append(self.gpa, .{ .data_set = .{ .target = .inStorage(.macro, ""), .snbt = self.forwarded_args.? } });
    self.temp_count = 0;
    for (command_text.inserts) |insert| {
        const target: Ir.DataPath = .inStorage(.macro, insert.macro_name);
        switch (insert.source) {
            .data => |source| try commands.append(self.gpa, .{ .data_copy = .{ .target = target, .source = source } }),
            .value => |expression| {
                const score = if (expression.kind == .identifier and expression.kind.identifier.storage == .score)
                    try self.scoreSource(expression.kind.identifier, env) orelse return
                else blk: {
                    const temp = try self.newTemp();
                    try self.compileInto(temp, expression, env, commands);
                    break :blk temp;
                };
                try commands.append(self.gpa, .{ .score_to_data = .{ .target = target, .score = score } });
            },
        }
    }
    try commands.append(self.gpa, .{ .function_with = .{ .name = name, .arguments = .macro_storage } });
}

// Compiles an `execute (...)` body. A body that can `return` is always a function, called as
// `if function ...`: it returns 1 for each entity that returns from the mcfun, and then the mcfun returns.
fn compileJumpBody(self: *Self, body: []const Ast.Stmt, env: *Environment, loop: ?[]const u8) CompileError!?Ir.Command {
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
fn onBodyReturn(self: *Self, body_name: []const u8) CompileError!Ir.Command {
    const pass_on: Ir.Command = if (self.return_through_body) .{ .return_value = 1 } else .{ .return_run = try self.createCommand(.{ .score_get = try self.resultScore() }) };
    const checks = try self.gpa.dupe(Ir.Check, &.{.{ .negated = false, .score_test = .{ .function_returns = body_name } }});
    return .{ .execute = .{ .checks = checks, .run = try self.createCommand(pass_on) } };
}

// The value of a `return` inside a `while` or `execute (...)` body, on its way out.
fn resultScore(self: *Self) CompileError!Ir.Score {
    return .{ .holder = try std.fmt.allocPrint(self.gpa, "#poplar.{s}.result", .{self.current_mcfun}) };
}

fn compileExecute(self: *Self, execute: Ast.Execute, env: *Environment, commands: *std.ArrayList(Ir.Command)) CompileError!void {
    const subcommands = try self.buildCommandText(execute.subcommands, env) orelse return;

    const prefix = "execute ";
    const check_text = try std.fmt.allocPrint(self.gpa, prefix ++ "{s} run say x", .{subcommands.text});
    if (try self.command_tree.check(self.gpa, check_text)) |failure| {
        const at = @min(failure.at -| prefix.len, subcommands.text.len);
        const column = execute.subcommands_column + sourceOffset(execute.subcommands, subcommands.text_starts, at);
        return self.addErrorAt(column, "{s}", .{failure.message});
    }

    const can_return = containsReturn(execute.body);
    if (can_return) {
        if (self.forwarded_args != null) return self.addError("'return' inside 'execute (...)' in an mcfun with parameters is not supported yet", .{});
        if (subcommands.is_macro) return self.addError("'return' inside 'execute (...)' with a data insert is not supported yet", .{});
    }

    const run = try self.compileJumpBody(execute.body, env, null);
    const execute_command: Ir.Command = .{ .execute_raw = .{ .subcommands = subcommands.text, .run = try self.createCommand(run orelse return) } };
    if (!subcommands.is_macro) return commands.append(self.gpa, execute_command);

    const name = try self.newGeneratedName("macro");
    try self.generated.append(self.gpa, .{ .name = name, .commands = try self.gpa.dupe(Ir.Command, &.{execute_command}) });
    // The body can forward the parameters too, so in an mcfun with parameters they always go along.
    try self.callMacroHelper(name, subcommands, self.forwarded_args != null, env, commands);
}

// Joins text and `{{...}}` inserts. A `{{#x}}` insert becomes `$(x)` and makes the text a macro line.
fn buildCommandText(self: *Self, parts: []const Ast.CommandPart, env: *Environment) CompileError!?CommandText {
    var text: std.ArrayList(u8) = .empty;
    const text_starts = try self.gpa.alloc(usize, parts.len);
    var is_macro = false;
    var uses_param = false;
    var inserts: std.ArrayList(Insert) = .empty;

    for (parts, text_starts) |part, *text_start| {
        text_start.* = text.items.len;
        switch (part.content) {
            .text => |part_text| try text.appendSlice(self.gpa, part_text),
            .insert => |expression| {
                if (isParam(expression, env)) {
                    try text.print(self.gpa, "$({s})", .{expression.kind.identifier.name});
                    uses_param = true;
                    continue;
                }
                if (self.containsRuntimeValue(expression, env)) {
                    const insert = try self.runtimeInsert(expression, env, inserts.items) orelse return null;
                    try text.print(self.gpa, "$({s})", .{insert.macro_name});
                    is_macro = true;
                    for (inserts.items) |used| {
                        if (std.mem.eql(u8, used.macro_name, insert.macro_name)) break;
                    } else try inserts.append(self.gpa, insert);
                    continue;
                }
                const value = try self.evaluate(expression, env) orelse return null;
                try text.appendSlice(self.gpa, try self.valueToText(value));
            },
        }
    }

    return .{
        .text = try text.toOwnedSlice(self.gpa),
        .text_starts = text_starts,
        .is_macro = is_macro,
        .uses_param = uses_param,
        .inserts = try inserts.toOwnedSlice(self.gpa),
    };
}

// Where the value of a runtime insert comes from, and its macro name. The same value again in the line
// gives the insert that is already there.
fn runtimeInsert(self: *Self, expression: *const Ast.Expr, env: *Environment, used: []const Insert) CompileError!?Insert {
    const outer_position = self.enterExpression(expression);
    defer self.restorePosition(outer_position);

    var base: []const u8 = "value";
    var source: Insert.Source = .{ .value = expression };
    if (expression.kind == .identifier) {
        const identifier = expression.kind.identifier;
        switch (identifier.storage) {
            .data, .entity_data => {
                const path = try self.dataPathOf(identifier, env) orelse return null;
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

    // A helper may get the parameters and the values in one compound, so each name must be new.
    var name = base;
    var number: usize = 2;
    while (isUsedMacroName(name, used, env)) : (number += 1) name = try std.fmt.allocPrint(self.gpa, "{s}_{d}", .{ base, number });
    return .{ .macro_name = name, .source = source };
}

fn isSameInsert(a: Insert.Source, b: Insert.Source) bool {
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

fn isUsedMacroName(name: []const u8, used: []const Insert, env: *Environment) bool {
    for (used) |insert| {
        if (std.mem.eql(u8, insert.macro_name, name)) return true;
    }
    const value = env.get(name) orelse return false;
    return value == .param;
}

// Maps an offset in the finished command back to the source. An offset inside an insert maps to its `{{`.
fn sourceOffset(parts: []const Ast.CommandPart, text_starts: []const usize, at: usize) usize {
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

fn compileVarDecl(self: *Self, var_decl: Ast.VarDecl, env: *Environment, commands: *std.ArrayList(Ir.Command)) CompileError!void {
    switch (var_decl.target.storage) {
        .compile_time => {},
        .score => return self.declareLocal(.score, var_decl, env, commands),
        .data => return self.declareLocal(.data, var_decl, env, commands),
        .entity_data => return self.addError("entity data cannot be declared with 'var'. Set it: '@s.$path = ...;'", .{}),
    }
    if (self.containsRuntimeValue(var_decl.value, env)) {
        return self.addError("'{s}' is a build-time constant, but this value only exists in the game. Use 'var #{s}' for a score or 'var ${s}' for data", .{ var_decl.target.name, var_decl.target.name, var_decl.target.name });
    }

    const value = try self.evaluate(var_decl.value, env) orelse return;
    if (!try env.declare(self.gpa, var_decl.target.name, value)) {
        try self.addError("'{s}' is already declared", .{var_decl.target.name});
    }
}

// `var #i = 10;` in `mcfun countdown` is the fake player `#i_countdown` in `<ns>`. `var $names = [];` is
// `names_countdown` in `<ns>:data`. The value is set here, on every call.
fn declareLocal(self: *Self, kind: Environment.Local.Kind, var_decl: Ast.VarDecl, env: *Environment, commands: *std.ArrayList(Ir.Command)) CompileError!void {
    const name = var_decl.target.name;
    const sigil: u8 = if (kind == .score) '#' else '$';
    if (kind == .data and pathRoot(name).len != name.len) {
        return self.addError("'var' declares a whole variable. Set '${s}' after it", .{name});
    }
    const is_global = if (kind == .score) self.globals.contains(name) else self.data_globals.contains(name);
    const key = try std.fmt.allocPrint(self.gpa, "{c}{s}", .{ sigil, name });
    if (is_global or env.get(key) != null) return self.addError("'{s}' is already declared", .{key});

    const generated_base = try std.fmt.allocPrint(self.gpa, "{s}_{s}", .{ name, self.current_mcfun });
    const generated_name = if (kind == .score) try std.fmt.allocPrint(self.gpa, "#{s}", .{generated_base}) else generated_base;

    const origin: LocalOrigin = .{ .name = name, .owner = self.current_mcfun };
    const name_entry = try self.local_names.getOrPut(self.gpa, try std.fmt.allocPrint(self.gpa, "{c}{s}", .{ sigil, generated_base }));
    if (name_entry.found_existing and !sameOrigin(name_entry.value_ptr.*, origin)) {
        const other = name_entry.value_ptr.*;
        return self.addError("'{c}{s}' in '{s}' and '{c}{s}' in '{s}' both become '{s}'. Rename one", .{ sigil, other.name, other.owner, sigil, name, self.current_mcfun, generated_name });
    }
    name_entry.value_ptr.* = origin;

    const local: Environment.Local = .{ .kind = kind, .generated_name = generated_name, .owner = self.current_mcfun };
    switch (kind) {
        .score => {
            self.temp_count = 0;
            try self.compileInto(.{ .holder = generated_name, .owner = self.current_mcfun }, var_decl.value, env, commands);
        },
        .data => try self.compileDataAssign(.inStorage(.data, generated_name), var_decl.value, env, commands),
    }

    _ = try env.declare(self.gpa, key, .{ .local = local });
    try self.live_locals.append(self.gpa, local);
    for (self.locals.items) |existing| {
        if (existing.line == self.current_line and existing.column == self.current_column and std.mem.eql(u8, existing.path, self.current_path)) break;
    } else try self.locals.append(self.gpa, .{
        .name = name,
        .local = local,
        .path = self.current_path,
        .line = self.current_line,
        .column = self.current_column,
    });
}

// `data remove` for each data local declared anywhere in the body. A failed `set from` keeps the old value, so
// without this a local could hold a value from an earlier call. `data remove` on a missing key fails without effect.
// A score local needs nothing: every score write (`set`, `operation`, `store result`) overwrites it, and a failure writes 0.
fn localCleanup(self: *Self, body: []const Ast.Stmt) CompileError![]const Ir.Command {
    var names: std.StringArrayHashMapUnmanaged(void) = .empty;
    try collectDataLocalNames(self.gpa, body, &names);

    var cleanup: std.ArrayList(Ir.Command) = .empty;
    for (names.keys()) |name| {
        const generated_name = try std.fmt.allocPrint(self.gpa, "{s}_{s}", .{ name, self.current_mcfun });
        try cleanup.append(self.gpa, .{ .data_remove = .inStorage(.data, generated_name) });
    }
    return cleanup.toOwnedSlice(self.gpa);
}

fn collectDataLocalNames(gpa: std.mem.Allocator, body: []const Ast.Stmt, names: *std.StringArrayHashMapUnmanaged(void)) CompileError!void {
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

fn sameOrigin(a: LocalOrigin, b: LocalOrigin) bool {
    return std.mem.eql(u8, a.name, b.name) and std.mem.eql(u8, a.owner, b.owner);
}

// `stats` in `stats.inventory[0]`.
pub fn pathRoot(path: []const u8) []const u8 {
    const end = std.mem.indexOfAny(u8, path, ".[") orelse path.len;
    return path[0..end];
}

fn compileAssign(self: *Self, assign: Ast.Assign, env: *Environment, commands: *std.ArrayList(Ir.Command)) CompileError!void {
    switch (assign.target.storage) {
        .compile_time => {},
        .score => return self.compileScoreAssign(assign.target, assign.value, env, commands),
        .data => {
            const key = try self.dataKey(assign.target.name, env) orelse return;
            return self.compileDataAssign(.inStorage(.data, key), assign.value, env, commands);
        },
        .entity_data => {
            const target = try self.entityDataPath(assign.target) orelse return;
            return self.compileDataAssign(target, assign.value, env, commands);
        },
    }

    if (self.containsRuntimeValue(assign.value, env)) return self.addError("a runtime value cannot be stored in a compile-time variable", .{});

    const value = try self.evaluate(assign.value, env) orelse return;
    switch (env.assign(assign.target.name, value)) {
        .assigned => {},
        .not_found => try self.addError("unknown name '{s}'", .{assign.target.name}),
        .crosses_runtime_branch => {
            try self.addError("cannot change compile-time '{s}' inside a runtime 'if' or 'execute'", .{assign.target.name});
        },
    }
}

fn compileScoreAssign(self: *Self, identifier: Ast.Identifier, expression: *const Ast.Expr, env: *Environment, commands: *std.ArrayList(Ir.Command)) CompileError!void {
    const target = try self.resolveScore(identifier, env) orelse return;
    self.temp_count = 0;

    if (isSafeInPlace(expression, identifier)) return self.compileInto(target, expression, env, commands);
    if (try self.swappedInPlace(expression, identifier)) |swapped| return self.compileInto(target, swapped, env, commands);

    const temp = try self.newTemp();
    try self.compileInto(temp, expression, env, commands);
    try self.appendOperation(commands, target, .assign, temp);
}

// `#n = 3 + #n` is the same as `#n = #n + 3`, which is computed in `#n` with no temp.
fn swappedInPlace(self: *Self, expression: *const Ast.Expr, target: Ast.Identifier) CompileError!?*const Ast.Expr {
    if (expression.kind != .infix) return null;
    const infix = expression.kind.infix;
    if (infix.op != .plus and infix.op != .star) return null;
    if (infix.right.kind != .identifier or !referencesScore(infix.right, target) or referencesScore(infix.left, target)) return null;
    return try self.createExpr(.{ .line = expression.line, .column = expression.column, .kind = .{ .infix = .{ .op = infix.op, .left = infix.right, .right = infix.left } } });
}

// Sets data in storage or an entity path. `value as float` picks the NBT type of a score or math; without it, the value is an `int`.
fn compileDataAssign(self: *Self, target: Ir.DataPath, value_expression: *const Ast.Expr, env: *Environment, commands: *std.ArrayList(Ir.Command)) CompileError!void {
    const outer_position = self.enterExpression(value_expression);
    defer self.restorePosition(outer_position);
    const expression, const cast_type = splitCast(value_expression);

    if (!self.containsRuntimeValue(expression, env)) {
        const value = try self.evaluate(expression, env) orelse return;
        if (value == .null) return self.addError("data cannot be set to null", .{});
        const snbt = try self.castSnbt(value, cast_type) orelse return;
        return commands.append(self.gpa, .{ .data_set = .{ .target = target, .snbt = snbt } });
    }

    if (expression.kind == .list or expression.kind == .compound) {
        if (cast_type != null) return self.addError("'as' sets the type of one number, not of a list or compound", .{});
        return self.compileLiteralAssign(target, expression, env, commands);
    }

    const is_copy = isDataIdentifier(expression);
    if (target.holder == .entity and cast_type == null and !is_copy) {
        return self.addError("a score or math in entity data needs its NBT type: '{s}.${s} = ... as float;' (byte, short, int, long, float, double)", .{ target.holder.entity, target.path });
    }

    if (expression.kind == .identifier and !isParam(expression, env)) {
        const identifier = expression.kind.identifier;
        switch (identifier.storage) {
            .score => {
                const score = try self.scoreSource(identifier, env) orelse return;
                return commands.append(self.gpa, .{ .score_to_data = .{ .target = target, .score = score, .type = cast_type orelse .int } });
            },
            // A copy keeps the NBT type, so it is used when no type is given.
            .data, .entity_data => if (cast_type == null) {
                const source = try self.dataPathOf(identifier, env) orelse return;
                if (std.meta.eql(source.holder, target.holder) and std.mem.eql(u8, source.path, target.path)) return;
                return commands.append(self.gpa, .{ .data_copy = .{ .target = target, .source = source } });
            },
            .compile_time => {},
        }
    }

    self.temp_count = 0;
    const temp = try self.newTemp();
    try self.compileInto(temp, expression, env, commands);
    try commands.append(self.gpa, .{ .score_to_data = .{ .target = target, .score = temp, .type = cast_type orelse .int } });
}

// A runtime value inside a literal, and where it goes: `[1]` in `pos[1]`, `.hp` in `stats.hp`.
const LiteralPart = struct {
    path: []const u8,
    value: *const Ast.Expr,
};

// `$pos = [#x, #y, 0];` sets the literal with a `0` for each runtime part, then stores each part at its path.
fn compileLiteralAssign(self: *Self, target: Ir.DataPath, expression: *const Ast.Expr, env: *Environment, commands: *std.ArrayList(Ir.Command)) CompileError!void {
    var parts: std.ArrayList(LiteralPart) = .empty;
    const template = try self.literalTemplate(expression, "", env, &parts) orelse return;

    try commands.append(self.gpa, .{ .data_set = .{ .target = target, .snbt = try self.valueToSnbt(template) } });
    for (parts.items) |part| {
        const part_target: Ir.DataPath = .{ .holder = target.holder, .path = try std.mem.concat(self.gpa, u8, &.{ target.path, part.path }) };
        try self.compileDataAssign(part_target, part.value, env, commands);
    }
}

// The literal as a value, with `0` in the place of each runtime part.
fn literalTemplate(self: *Self, expression: *const Ast.Expr, path: []const u8, env: *Environment, parts: *std.ArrayList(LiteralPart)) CompileError!?Value {
    if (!self.containsRuntimeValue(expression, env)) return try self.evaluate(expression, env);

    switch (expression.kind) {
        .list => |elements| {
            const values = try self.gpa.alloc(Value, elements.len);
            for (elements, values, 0..) |element, *value, index| {
                const element_path = try std.fmt.allocPrint(self.gpa, "{s}[{d}]", .{ path, index });
                value.* = try self.literalTemplate(element, element_path, env, parts) orelse return null;
            }
            return .{ .list = values };
        },
        .compound => |entries| {
            const values = try self.gpa.alloc(Value.Entry, entries.len);
            for (entries, values) |entry, *value| {
                const entry_path = try std.fmt.allocPrint(self.gpa, "{s}.{s}", .{ path, try self.snbtKey(entry.key) });
                const entry_value = try self.literalTemplate(entry.value, entry_path, env, parts) orelse return null;
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

fn isDataIdentifier(expression: *const Ast.Expr) bool {
    return expression.kind == .identifier and (expression.kind.identifier.storage == .data or expression.kind.identifier.storage == .entity_data);
}

// The local `#name` or `$name` that is visible here.
fn localOf(env: *const Environment, sigil: u8, name: []const u8) ?Environment.Local {
    var buffer: [256]u8 = undefined;
    const key = std.fmt.bufPrint(&buffer, "{c}{s}", .{ sigil, name }) catch return null;
    const value = env.get(key) orelse return null;
    return if (value == .local) value.local else null;
}

// `value as float` → `value` and `.float`.
fn splitCast(expression: *const Ast.Expr) struct { *const Ast.Expr, ?Ast.NumberType } {
    return switch (expression.kind) {
        .cast => |cast| .{ cast.value, cast.type },
        else => .{ expression, null },
    };
}

// `20 as float` → `20f`, `true as byte` → `1b`. Without `as`, the value is written as it is.
fn castSnbt(self: *Self, value: Value, cast_type: ?Ast.NumberType) CompileError!?[]const u8 {
    const number_type = cast_type orelse return try self.valueToSnbt(value);
    return self.numberSnbt(value, number_type);
}

fn numberSnbt(self: *Self, value: Value, target_type: Ast.NumberType) CompileError!?[]const u8 {
    const number: i64 = switch (value) {
        .number => |number| number,
        .boolean => |boolean| @intFromBool(boolean),
        else => {
            try self.addError("a {t} needs a number, found {s}", .{ target_type, @tagName(value) });
            return null;
        },
    };
    const suffix = switch (target_type) {
        .byte => "b",
        .short => "s",
        .int => "",
        .long => "L",
        .float => "f",
        .double => "d",
    };
    return try std.fmt.allocPrint(self.gpa, "{d}{s}", .{ number, suffix });
}

// A `#` variable in `<ns>:data`, or the NBT path of one entity.
fn dataPathOf(self: *Self, identifier: Ast.Identifier, env: *const Environment) CompileError!?Ir.DataPath {
    if (identifier.storage == .entity_data) return self.entityDataPath(identifier);
    const key = try self.dataKey(identifier.name, env) orelse return null;
    return .inStorage(.data, key);
}

fn entityDataPath(self: *Self, identifier: Ast.Identifier) CompileError!?Ir.DataPath {
    if (!try self.checkSingleEntity(identifier)) return null;
    return .ofEntity(identifier.selector.?, identifier.name);
}

fn compileInto(self: *Self, target: Ir.Score, expression: *const Ast.Expr, env: *Environment, commands: *std.ArrayList(Ir.Command)) CompileError!void {
    const outer_position = self.enterExpression(expression);
    defer self.restorePosition(outer_position);
    if (!self.containsRuntimeValue(expression, env)) {
        const value = try self.evaluate(expression, env) orelse return;
        const number = try self.toScoreValue(value) orelse return;
        return commands.append(self.gpa, .{ .score_set = .{ .score = target, .value = number } });
    }

    switch (expression.kind) {
        .identifier => |identifier| {
            if (identifier.storage == .compile_time) {
                return commands.append(self.gpa, .{ .score_set_param = .{ .score = target, .param = identifier.name } });
            }
            if (identifier.storage == .data or identifier.storage == .entity_data) {
                const source = try self.dataPathOf(identifier, env) orelse return;
                return commands.append(self.gpa, .{ .data_to_score = .{ .source = source, .score = target } });
            }

            const source = try self.resolveScore(identifier, env) orelse return;
            if (source.eql(target)) return;
            if (!try self.checkSingleEntity(identifier)) return;
            try self.appendOperation(commands, target, .assign, source);
        },
        .prefix => |prefix| {
            if (prefix.op != .minus) {
                return self.addError("operator '{s}' cannot be used with scores", .{operatorText(prefix.op)});
            }
            try self.compileInto(target, prefix.operand, env, commands);
            try self.appendOperation(commands, target, .mul, try self.constantScore(-1));
        },
        .infix => |infix| {
            const op = scoreOperator(infix.op) orelse {
                return self.addError("operator '{s}' on scores needs 'if' (not supported yet)", .{operatorText(infix.op)});
            };
            try self.compileInto(target, infix.left, env, commands);
            try self.applyOperand(target, op, infix.right, env, commands);
        },
        .call => |call| {
            if (isBuiltinCall(call, "len")) return self.compileLength(target, call, env, commands);
            const function = try self.findMcfn(call) orelse return;
            // Temps made after this point hold arguments. They are not needed after the call.
            const live_count = self.temp_count;
            const run = try self.compileMcfnCall(call, function, env, commands) orelse return;
            self.temp_count = live_count;
            const store: Ir.Command = .{ .store_result = .{ .target = .{ .score = target }, .run = try self.createCommand(run) } };

            if (!try self.canReach(function.name, self.current_mcfun)) return commands.append(self.gpa, store);
            try self.appendWithSavedValues(store, target, live_count, commands);
        },
        .cast => try self.addError(cast_error, .{}),
        else => try self.addError("this expression cannot be used with scores", .{}),
    }
}

// The mcfun whose return value is used, for example `double` in `#y = double();`.
fn findMcfn(self: *Self, call: Ast.Call) CompileError!?*const Ast.Function {
    if (call.callee.kind == .identifier) {
        if (self.functions.get(call.callee.kind.identifier.name)) |located| return located.function;
        try self.addError("unknown function '{s}'", .{call.callee.kind.identifier.name});
        return null;
    }
    try self.addError("only an mcfun call can be used as a runtime value", .{});
    return null;
}

// Returns the command that calls an mcfun. Commands that prepare runtime arguments go into `commands` first.
fn compileMcfnCall(self: *Self, call: Ast.Call, function: *const Ast.Function, env: *Environment, commands: *std.ArrayList(Ir.Command)) CompileError!?Ir.Command {
    if (call.args.len != function.params.len) {
        try self.addError("mcfun '{s}' expects {d} arguments, found {d}", .{ function.name, function.params.len, call.args.len });
        return null;
    }
    if (function.params.len == 0) return .{ .function = function.name };

    var has_runtime_argument = false;
    for (call.args) |arg| {
        if (self.containsRuntimeValue(arg, env) and !isParam(arg, env)) has_runtime_argument = true;
    }

    if (!has_runtime_argument) {
        var compound: std.ArrayList(u8) = .empty;
        for (function.params, call.args, 0..) |param, arg, index| {
            try compound.appendSlice(self.gpa, if (index == 0) "{" else ",");
            try compound.print(self.gpa, "{s}:{s}", .{ param.name, try self.argumentSnbt(arg, env) orelse return null });
        }
        try compound.append(self.gpa, '}');
        return .{ .function_with = .{ .name = function.name, .arguments = .{ .compound = try compound.toOwnedSlice(self.gpa) } } };
    }

    // Math is computed before any argument is written, so a call inside an argument cannot overwrite them.
    const scores = try self.gpa.alloc(?Ir.Score, call.args.len);
    for (call.args, scores) |arg, *score| {
        score.* = null;
        if (!self.containsRuntimeValue(arg, env) or isParam(arg, env)) continue;
        const value, _ = splitCast(arg);

        if (value.kind == .identifier) {
            if (value.kind.identifier.storage == .score) score.* = try self.scoreSource(value.kind.identifier, env) orelse return null;
            continue;
        }

        score.* = try self.newTemp();
        try self.compileInto(score.*.?, value, env, commands);
    }

    for (function.params, call.args, scores) |param, arg, argument_score| {
        const outer_position = self.enterExpression(arg);
        defer self.restorePosition(outer_position);
        const target: Ir.DataPath = .inStorage(.args, param.name);
        if (argument_score) |score| {
            _, const cast_type = splitCast(arg);
            try commands.append(self.gpa, .{ .score_to_data = .{ .target = target, .score = score, .type = cast_type orelse .int } });
        } else if (isDataIdentifier(arg)) {
            const source = try self.dataPathOf(arg.kind.identifier, env) orelse return null;
            try commands.append(self.gpa, .{ .data_copy = .{ .target = target, .source = source } });
        } else {
            const snbt = try self.argumentSnbt(arg, env) orelse return null;
            try commands.append(self.gpa, .{ .data_set = .{ .target = target, .snbt = snbt } });
        }
    }
    return .{ .function_with = .{ .name = function.name, .arguments = .args_storage } };
}

// A compile-time argument as SNBT. A forwarded parameter is `"$(name)"`.
fn argumentSnbt(self: *Self, arg: *const Ast.Expr, env: *Environment) CompileError!?[]const u8 {
    const outer_position = self.enterExpression(arg);
    defer self.restorePosition(outer_position);
    if (isParam(arg, env)) return try std.fmt.allocPrint(self.gpa, "\"$({s})\"", .{arg.kind.identifier.name});

    const expression, const cast_type = splitCast(arg);
    const value = try self.evaluate(expression, env) orelse return null;
    if (value == .null) {
        try self.addError("null cannot be passed to an mcfun", .{});
        return null;
    }
    return try self.castSnbt(value, cast_type);
}

// Calls a generated function. In an mcfun with parameters, the arguments are passed on, because the body can use them.
fn generatedCall(self: *Self, name: []const u8) Ir.Command {
    const forwarded = self.forwarded_args orelse return .{ .function = name };
    return .{ .function_with = .{ .name = name, .arguments = .{ .compound = forwarded } } };
}

fn applyOperand(self: *Self, target: Ir.Score, op: Ir.Operator, operand: *const Ast.Expr, env: *Environment, commands: *std.ArrayList(Ir.Command)) CompileError!void {
    const outer_position = self.enterExpression(operand);
    defer self.restorePosition(outer_position);
    if (!self.containsRuntimeValue(operand, env)) {
        const value = try self.evaluate(operand, env) orelse return;
        const number = try self.toScoreValue(value) orelse return;

        if ((op == .add or op == .sub) and number != std.math.minInt(i32)) {
            const score_value: Ir.ScoreValue = .{ .score = target, .value = if (number < 0) -number else number };
            const is_add = (op == .add) == (number >= 0);
            return commands.append(self.gpa, if (is_add) .{ .score_add = score_value } else .{ .score_remove = score_value });
        }

        if ((op == .div or op == .mod) and number == 0) return self.addError("division by zero", .{});

        return self.appendOperation(commands, target, op, try self.constantScore(number));
    }

    if (operand.kind == .identifier and operand.kind.identifier.storage == .score) {
        const source = try self.scoreSource(operand.kind.identifier, env) orelse return;
        return self.appendOperation(commands, target, op, source);
    }

    const temp = try self.newTemp();
    try self.compileInto(temp, operand, env, commands);
    try self.appendOperation(commands, target, op, temp);
}

fn appendOperation(self: *Self, commands: *std.ArrayList(Ir.Command), target: Ir.Score, op: Ir.Operator, source: Ir.Score) CompileError!void {
    try commands.append(self.gpa, .{ .score_operation = .{ .target = target, .op = op, .source = source } });
}

// Resolves a score that is read. An entity score must name one entity.
fn scoreSource(self: *Self, identifier: Ast.Identifier, env: *const Environment) CompileError!?Ir.Score {
    const score = try self.resolveScore(identifier, env) orelse return null;
    if (!try self.checkSingleEntity(identifier)) return null;
    return score;
}

// `#x` is the global value of objective `<ns>.x`. `@s.#x` is the value of an entity in the same objective.
// A local `#x` is the fake player `#x_<mcfun>` in `<ns>`.
fn resolveScore(self: *Self, identifier: Ast.Identifier, env: *const Environment) CompileError!?Ir.Score {
    if (localOf(env, '#', identifier.name)) |local| {
        if (identifier.selector != null) {
            try self.addError("'#{s}' is local, so it has no entity values. Declare it at the top level", .{identifier.name});
            return null;
        }
        return .{ .holder = local.generated_name, .owner = local.owner };
    }
    if (!self.globals.contains(identifier.name)) {
        try self.addError("unknown score '#{s}'", .{identifier.name});
        return null;
    }
    return .{ .holder = identifier.selector orelse global_holder, .objective = identifier.name };
}

fn checkSingleEntity(self: *Self, identifier: Ast.Identifier) CompileError!bool {
    const selector = identifier.selector orelse return true;
    if (isSingleEntitySelector(selector)) return true;

    const sigil = if (identifier.storage == .entity_data) "$" else "#";
    try self.addError("'{s}.{s}{s}' needs a selector for one entity (@s, @p, @r, @n or limit=1)", .{ selector, sigil, identifier.name });
    return false;
}

fn isSingleEntitySelector(selector: []const u8) bool {
    if (std.mem.indexOfScalar(u8, "sprn", selector[1]) != null) return true;

    const limit_start = std.mem.indexOf(u8, selector, "limit=1") orelse return false;
    const after = limit_start + "limit=1".len;
    return after < selector.len and (selector[after] == ',' or selector[after] == ']');
}

// Checks that the root of a `$` path is declared, and gives the path in `<ns>:data`.
fn dataKey(self: *Self, name: []const u8, env: *const Environment) CompileError!?[]const u8 {
    const root = pathRoot(name);
    if (localOf(env, '$', root)) |local| return try std.mem.concat(self.gpa, u8, &.{ local.generated_name, name[root.len..] });
    if (!self.data_globals.contains(root)) {
        try self.addError("unknown data '${s}'", .{root});
        return null;
    }
    return name;
}

// `stats.inventory[0]` → `stats_inventory_0_`: a name that a macro line can use.
fn macroName(gpa: std.mem.Allocator, path: []const u8) CompileError![]const u8 {
    const name = try gpa.dupe(u8, path);
    for (name) |*ch| {
        if (!std.ascii.isAlphanumeric(ch.*) and ch.* != '_') ch.* = '_';
    }
    return name;
}

fn toScoreValue(self: *Self, value: Value) CompileError!?i32 {
    if (value != .number) {
        try self.addError("a score must hold a number, found {s}", .{@tagName(value)});
        return null;
    }

    return std.math.cast(i32, value.number) orelse {
        try self.addError("value {d} does not fit in a score (32-bit)", .{value.number});
        return null;
    };
}

fn globalScore(name: []const u8) Ir.Score {
    return .{ .holder = global_holder, .objective = name };
}

fn constantScore(self: *Self, value: i32) CompileError!Ir.Score {
    try self.constants.put(self.gpa, value, {});
    return .{ .holder = try std.fmt.allocPrint(self.gpa, "#poplar.c{d}", .{value}) };
}

fn newTemp(self: *Self) CompileError!Ir.Score {
    defer self.temp_count += 1;
    return self.tempScore(self.temp_count);
}

// Each mcfun has its own temps, so a call to another mcfun cannot overwrite them.
fn tempScore(self: *Self, index: usize) CompileError!Ir.Score {
    return .{ .holder = try std.fmt.allocPrint(self.gpa, "#poplar.{s}.t{d}", .{ self.current_mcfun, index }) };
}

// A recursive call runs this mcfun again, which overwrites its temps and locals. The live temps and the visible
// locals are saved in a frame around the call. `target` gets the result of the call, so it is not restored.
fn appendWithSavedValues(self: *Self, call: Ir.Command, target: ?Ir.Score, live_temp_count: usize, commands: *std.ArrayList(Ir.Command)) CompileError!void {
    var saved_scores: std.ArrayList(Ir.Score) = .empty;
    var saved_data: std.ArrayList([]const u8) = .empty;
    for (0..live_temp_count) |index| try saved_scores.append(self.gpa, try self.tempScore(index));
    for (self.live_locals.items) |local| switch (local.kind) {
        .score => try saved_scores.append(self.gpa, .{ .holder = local.generated_name, .owner = local.owner }),
        .data => try saved_data.append(self.gpa, local.generated_name),
    };
    if (target) |result| for (saved_scores.items, 0..) |score, index| {
        if (score.eql(result)) {
            _ = saved_scores.orderedRemove(index);
            break;
        }
    };
    if (saved_scores.items.len + saved_data.items.len == 0) return commands.append(self.gpa, call);

    self.uses_stack = true;
    try commands.append(self.gpa, .frame_push);
    for (saved_scores.items) |score| try commands.append(self.gpa, .{ .score_to_data = .{ .target = try self.frameSlot(score.holder), .score = score } });
    for (saved_data.items) |key| try commands.append(self.gpa, .{ .data_copy = .{ .target = try self.frameSlot(key), .source = .inStorage(.data, key) } });
    try commands.append(self.gpa, call);
    for (saved_scores.items) |score| try commands.append(self.gpa, .{ .data_to_score = .{ .source = try self.frameSlot(score.holder), .score = score } });
    for (saved_data.items) |key| try commands.append(self.gpa, .{ .data_copy = .{ .target = .inStorage(.data, key), .source = try self.frameSlot(key) } });
    try commands.append(self.gpa, .frame_pop);
}

// The key in the frame: `t0` for the temp `#poplar.<mcfun>.t0`, `s_i_countdown` for the local `#i_countdown`,
// and `d_names_countdown` for the data local `names_countdown`.
fn frameSlot(self: *Self, name: []const u8) CompileError!Ir.DataPath {
    if (std.mem.startsWith(u8, name, "#poplar.")) return .inStorage(.frame, name[std.mem.lastIndexOfScalar(u8, name, '.').? + 1 ..]);
    if (name[0] == '#') return .inStorage(.frame, try std.fmt.allocPrint(self.gpa, "s_{s}", .{name[1..]}));
    return .inStorage(.frame, try std.fmt.allocPrint(self.gpa, "d_{s}", .{name}));
}

fn buildCallGraph(self: *Self) CompileError!void {
    for (self.functions.values()) |located| {
        var calls: std.StringArrayHashMapUnmanaged(void) = .empty;
        try self.collectCalls(located.function.body, &calls);
        try self.mcfun_calls.put(self.gpa, located.function.name, calls);
    }
}

// Finds the mcfun calls in a body. This can find calls that a compile-time branch removes later. That only adds saves.
fn collectCalls(
    self: *Self,
    body: []const Ast.Stmt,
    calls: *std.StringArrayHashMapUnmanaged(void),
) CompileError!void {
    for (body) |statement| switch (statement.kind) {
        .var_decl => |var_decl| try self.collectExpressionCalls(var_decl.value, calls),
        .assign => |assign| try self.collectExpressionCalls(assign.value, calls),
        .@"return" => |value| if (value) |expression| try self.collectExpressionCalls(expression, calls),
        .@"break", .@"continue" => {},
        .@"if" => |if_statement| {
            try self.collectExpressionCalls(if_statement.condition, calls);
            try self.collectCalls(if_statement.then_body, calls);
            if (if_statement.else_body) |else_body| try self.collectCalls(else_body, calls);
        },
        .@"for" => |loop| try self.collectCalls(loop.body, calls),
        .@"while" => |loop| {
            try self.collectExpressionCalls(loop.condition, calls);
            try self.collectCalls(loop.body, calls);
        },
        .execute => |execute| {
            try self.collectInsertCalls(execute.subcommands, calls);
            try self.collectCalls(execute.body, calls);
        },
        .expression => |expression| try self.collectExpressionCalls(expression, calls),
        .command => |command| try self.collectInsertCalls(command.parts, calls),
    };
}

// `/say {{double(2)}};` calls `double` too.
fn collectInsertCalls(
    self: *Self,
    parts: []const Ast.CommandPart,
    calls: *std.StringArrayHashMapUnmanaged(void),
) CompileError!void {
    for (parts) |part| switch (part.content) {
        .text => {},
        .insert => |expression| try self.collectExpressionCalls(expression, calls),
    };
}

fn collectExpressionCalls(
    self: *Self,
    expression: *const Ast.Expr,
    calls: *std.StringArrayHashMapUnmanaged(void),
) CompileError!void {
    switch (expression.kind) {
        .prefix => |prefix| try self.collectExpressionCalls(prefix.operand, calls),
        .infix => |infix| {
            try self.collectExpressionCalls(infix.left, calls);
            try self.collectExpressionCalls(infix.right, calls);
        },
        .cast => |cast| try self.collectExpressionCalls(cast.value, calls),
        .call => |call| {
            for (call.args) |arg| try self.collectExpressionCalls(arg, calls);
            if (call.callee.kind != .identifier) return;

            // An event callback is called from `load`, as far as the call graph is concerned.
            if (isBuiltinCall(call, "onEvent") and call.args.len == 2 and call.args[1].kind == .identifier) {
                try calls.put(self.gpa, call.args[1].kind.identifier.name, {});
            }
            const located = self.functions.get(call.callee.kind.identifier.name) orelse return;
            try calls.put(self.gpa, located.function.name, {});
        },
        else => {},
    }
}

// True if `from` can call `to`, directly or through other mcfuns.
fn canReach(self: *Self, from: []const u8, to: []const u8) CompileError!bool {
    var pending: std.ArrayList([]const u8) = .empty;
    var visited: std.StringHashMapUnmanaged(void) = .empty;
    try pending.append(self.gpa, from);

    while (pending.pop()) |name| {
        if (std.mem.eql(u8, name, to)) return true;
        if ((try visited.getOrPut(self.gpa, name)).found_existing) continue;

        const calls = self.mcfun_calls.get(name) orelse continue;
        try pending.appendSlice(self.gpa, calls.keys());
    }
    return false;
}

fn scoreOperator(op: Token.TokenType) ?Ir.Operator {
    return switch (op) {
        .plus => .add,
        .minus => .sub,
        .star => .mul,
        .slash => .div,
        .percent => .mod,
        else => null,
    };
}

fn containsRuntimeValue(self: *const Self, expression: *const Ast.Expr, env: *const Environment) bool {
    return switch (expression.kind) {
        .identifier => |identifier| identifier.storage != .compile_time or isParam(expression, env),
        .prefix => |prefix| self.containsRuntimeValue(prefix.operand, env),
        .infix => |infix| self.containsRuntimeValue(infix.left, env) or self.containsRuntimeValue(infix.right, env),
        .cast => |cast| self.containsRuntimeValue(cast.value, env),
        .list => |elements| for (elements) |element| {
            if (self.containsRuntimeValue(element, env)) break true;
        } else false,
        .compound => |entries| for (entries) |entry| {
            if (self.containsRuntimeValue(entry.value, env)) break true;
        } else false,
        // An mcfun runs in the game. `text(#hp)` only names the score, so it is known when the pack is built.
        .call => |call| {
            if (isBuiltinCall(call, "text")) return false;
            if (!isBuiltinCall(call, "len")) return true;
            for (call.args) |arg| {
                if (self.containsRuntimeValue(arg, env)) return true;
            }
            return false;
        },
        else => false,
    };
}

fn isParam(expression: *const Ast.Expr, env: *const Environment) bool {
    if (expression.kind != .identifier or expression.kind.identifier.storage != .compile_time) return false;
    const value = env.get(expression.kind.identifier.name) orelse return false;
    return value == .param;
}

fn ifContainsReturn(if_statement: Ast.If) bool {
    const else_body = if_statement.else_body orelse &.{};
    return containsReturn(if_statement.then_body) or containsReturn(else_body);
}

fn containsReturn(body: []const Ast.Stmt) bool {
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

fn isJump(kind: Ast.Stmt.Kind) bool {
    return kind == .@"return" or kind == .@"break" or kind == .@"continue";
}

// `return`, `break` or `continue` of this loop level. A `break` in an inner `while` belongs to that loop.
fn ifContainsJump(if_statement: Ast.If) bool {
    const else_body = if_statement.else_body orelse &.{};
    return containsJump(if_statement.then_body) or containsJump(else_body);
}

fn containsJump(body: []const Ast.Stmt) bool {
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
fn containsExit(body: []const Ast.Stmt) bool {
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
fn branchesEndWithJump(if_statement: Ast.If) bool {
    if (!endsWithJump(if_statement.then_body)) return false;

    const else_body = if_statement.else_body orelse return true;
    if (else_body.len == 1 and else_body[0].kind == .@"if") return branchesEndWithJump(else_body[0].kind.@"if");
    return endsWithJump(else_body);
}

fn endsWithJump(body: []const Ast.Stmt) bool {
    if (body.len == 0) return false;

    return switch (body[body.len - 1].kind) {
        .@"return", .@"break", .@"continue" => true,
        .@"if" => |if_statement| if_statement.else_body != null and branchesEndWithJump(if_statement),
        else => false,
    };
}

fn referencesScore(expression: *const Ast.Expr, target: Ast.Identifier) bool {
    return switch (expression.kind) {
        .identifier => |identifier| identifier.storage == .score and
            std.mem.eql(u8, identifier.name, target.name) and
            std.mem.eql(u8, identifier.selector orelse "", target.selector orelse ""),
        .prefix => |prefix| referencesScore(prefix.operand, target),
        .infix => |infix| referencesScore(infix.left, target) or referencesScore(infix.right, target),
        else => false,
    };
}

// The target can only be computed in place if it is read before it is first written,
// which is true when it appears only as the leftmost operand.
fn isSafeInPlace(expression: *const Ast.Expr, target: Ast.Identifier) bool {
    return switch (expression.kind) {
        .infix => |infix| isSafeInPlace(infix.left, target) and !referencesScore(infix.right, target),
        .prefix => |prefix| isSafeInPlace(prefix.operand, target),
        else => true,
    };
}

fn compileIf(self: *Self, if_statement: Ast.If, env: *Environment, commands: *std.ArrayList(Ir.Command)) CompileError!void {
    self.temp_count = 0;
    var setup: std.ArrayList(Ir.Command) = .empty;
    const condition = try self.lowerCondition(if_statement.condition, env, false, &setup) orelse return;

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
            try commands.append(self.gpa, self.generatedCall(wrapper_name));
        },
    }
}

// Each branch returns from the wrapper, so later branches and the else body run only if no earlier branch ran.
fn appendBranches(
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
        self.current_line = else_body[0].line;
        self.current_column = else_body[0].column;
        self.temp_count = 0;
        var else_setup: std.ArrayList(Ir.Command) = .empty;
        const else_condition = try self.lowerCondition(else_if.condition, env, false, &else_setup) orelse return;
        return self.appendBranches(else_if, env, wrapper, else_condition, else_setup.items, is_runtime);
    }

    var else_env: Environment = .{ .outer = env, .runtime_branch = is_runtime };
    try self.compileBlock(else_body, &else_env, wrapper);
}

// `kind` names a generated function for a body with more than one command: `if` or `execute`.
fn compileBodyAsCommand(self: *Self, body: []const Ast.Stmt, env: *Environment, kind: []const u8) CompileError!?Ir.Command {
    var branch_env: Environment = .{ .outer = env, .runtime_branch = true };
    var body_commands: std.ArrayList(Ir.Command) = .empty;
    try self.compileBlock(body, &branch_env, &body_commands);

    switch (body_commands.items.len) {
        0 => return null,
        1 => return body_commands.items[0],
        else => {
            const name = try self.newGeneratedName(kind);
            try self.generated.append(self.gpa, .{ .name = name, .commands = try body_commands.toOwnedSlice(self.gpa) });
            return self.generatedCall(name);
        },
    }
}

fn lowerCondition(self: *Self, expression: *const Ast.Expr, env: *Environment, negated: bool, setup: *std.ArrayList(Ir.Command)) CompileError!?Condition {
    const outer_position = self.enterExpression(expression);
    defer self.restorePosition(outer_position);
    if (!self.containsRuntimeValue(expression, env)) {
        const value = try self.evaluate(expression, env) orelse return null;
        if (value != .boolean) {
            try self.addError("a condition must be a comparison, a data path, true or false, found {s}", .{@tagName(value)});
            return null;
        }
        return .{ .constant = value.boolean != negated };
    }

    switch (expression.kind) {
        .prefix => |prefix| if (prefix.op == .bang) return self.lowerCondition(prefix.operand, env, !negated, setup),
        .infix => |infix| switch (infix.op) {
            .@"and", .@"or" => {
                const left = try self.lowerCondition(infix.left, env, negated, setup) orelse return null;
                const right = try self.lowerCondition(infix.right, env, negated, setup) orelse return null;

                const is_and = (infix.op == .@"and") != negated;
                return if (is_and) try self.combineAnd(left, right) else try self.combineOr(left, right);
            },
            .less, .less_eql, .greater, .greater_eql, .eql_eql, .bang_eql => {
                return self.lowerComparison(infix, env, negated, setup);
            },
            else => {},
        },
        // `if ($x)` is Minecraft's `if data`: the path exists, whatever its value. A bool needs `== true`.
        .identifier => |identifier| if (identifier.storage == .data or identifier.storage == .entity_data) {
            const path = try self.dataPathOf(identifier, env) orelse return null;
            return try self.singleCheck(.{ .negated = negated, .score_test = .{ .data_test = path } });
        },
        else => {},
    }

    if (expression.kind == .identifier and expression.kind.identifier.storage == .score) {
        try self.addError("a score needs a comparison in a condition: 'if (#{s} != 0)'", .{expression.kind.identifier.name});
        return null;
    }
    try self.addError("a condition must be a comparison, a data path, or 'and', 'or' and '!' of those", .{});
    return null;
}

// `$name == "Steve"` → `if data storage ns:data {name:"Steve"}`. The path becomes a nested filter.
fn dataCondition(self: *Self, identifier: Ast.Identifier, value: Value, cast_type: ?Ast.NumberType, negated: bool, env: *const Environment) CompileError!?Condition {
    const path = try self.dataPathOf(identifier, env) orelse return null;
    if (std.mem.indexOfAny(u8, path.path, "[\"") != null) {
        try self.addError("a condition on '{s}' is not supported yet: the path must only have keys", .{identifier.name});
        return null;
    }

    var filter: std.ArrayList(u8) = .empty;
    var keys = std.mem.splitScalar(u8, path.path, '.');
    var depth: usize = 0;
    while (keys.next()) |key| : (depth += 1) try filter.print(self.gpa, "{{{s}:", .{key});
    // Minecraft stores a bool as a byte, so the filter says `1b` or `0b`.
    const snbt = if (value == .boolean) (if (value.boolean) "1b" else "0b") else try self.castSnbt(value, cast_type) orelse return null;
    try filter.appendSlice(self.gpa, snbt);
    try filter.appendNTimes(self.gpa, '}', depth);

    return try self.singleCheck(.{ .negated = negated, .score_test = .{ .data_test = .{ .holder = path.holder, .path = try filter.toOwnedSlice(self.gpa) } } });
}

fn lowerComparison(self: *Self, infix: Ast.Infix, env: *Environment, negated: bool, setup: *std.ArrayList(Ir.Command)) CompileError!?Condition {
    const check_negated = negated != (infix.op == .bang_eql);
    const op = compareOperator(infix.op);

    if ((infix.op == .eql_eql or infix.op == .bang_eql) and self.isTextComparison(infix.left, infix.right, env)) {
        if (isDataIdentifier(infix.left)) return self.dataComparison(infix.left, infix.right, env, check_negated);
        if (isDataIdentifier(infix.right)) return self.dataComparison(infix.right, infix.left, env, check_negated);
    }

    const left = try self.lowerOperand(infix.left, env, setup) orelse return null;
    const right = try self.lowerOperand(infix.right, env, setup) orelse return null;

    // At least one side has a score, so two numbers cannot happen here.
    return switch (left) {
        .number => |number| try self.matchesCondition(right.score, flipCompare(op), number, check_negated),
        .score => |left_score| switch (right) {
            .number => |number| try self.matchesCondition(left_score, op, number, check_negated),
            .score => |right_score| try self.singleCheck(.{
                .negated = check_negated,
                .score_test = .{ .compare = .{ .left = left_score, .op = op, .right = right_score } },
            }),
        },
    };
}

// `==` between data and a compile-time string, bool, list, compound or `as` number is an NBT filter.
// A number comparison still goes through a score, which also works for other number types.
fn dataComparison(self: *Self, data_side: *const Ast.Expr, other: *const Ast.Expr, env: *Environment, negated: bool) CompileError!?Condition {
    const outer_position = self.enterExpression(other);
    defer self.restorePosition(outer_position);
    if (self.containsRuntimeValue(other, env)) {
        try self.addError("comparing two runtime values that are not numbers is not supported yet", .{});
        return null;
    }
    const expression, const cast_type = splitCast(other);
    const value = try self.evaluate(expression, env) orelse return null;
    return self.dataCondition(data_side.kind.identifier, value, cast_type, negated, env);
}

// True when one side is data and the other is a compile-time value that is not a plain number.
fn isTextComparison(self: *Self, left: *const Ast.Expr, right: *const Ast.Expr, env: *Environment) bool {
    if (!isDataIdentifier(left) and !isDataIdentifier(right)) return false;
    for ([_]*const Ast.Expr{ left, right }) |side| {
        if (isDataIdentifier(side) or self.containsRuntimeValue(side, env)) continue;
        switch (side.kind) {
            .string, .boolean, .list, .compound, .cast => return true,
            else => {},
        }
    }
    return false;
}

fn lowerOperand(self: *Self, expression: *const Ast.Expr, env: *Environment, setup: *std.ArrayList(Ir.Command)) CompileError!?Operand {
    const outer_position = self.enterExpression(expression);
    defer self.restorePosition(outer_position);
    if (!self.containsRuntimeValue(expression, env)) {
        const value = try self.evaluate(expression, env) orelse return null;
        if (value != .number) {
            try self.addError("only numbers can be compared with scores, found {s}", .{@tagName(value)});
            return null;
        }
        return .{ .number = value.number };
    }

    if (expression.kind == .identifier and expression.kind.identifier.storage == .score) {
        return .{ .score = try self.scoreSource(expression.kind.identifier, env) orelse return null };
    }

    const temp = try self.newTemp();
    try self.compileInto(temp, expression, env, setup);
    return .{ .score = temp };
}

fn matchesCondition(self: *Self, score: Ir.Score, op: Ir.CompareOp, number: i64, negated: bool) CompileError!Condition {
    var min: ?i64 = null;
    var max: ?i64 = null;

    switch (op) {
        .lt => max = number -| 1,
        .le => max = number,
        .eq => {
            min = number;
            max = number;
        },
        .ge => min = number,
        .gt => min = number +| 1,
    }

    const score_min = std.math.minInt(i32);
    const score_max = std.math.maxInt(i32);

    const is_never_true = (max != null and max.? < score_min) or (min != null and min.? > score_max);
    if (is_never_true) return .{ .constant = negated };

    const range_min: ?i32 = if (min != null and min.? > score_min) @intCast(min.?) else null;
    const range_max: ?i32 = if (max != null and max.? < score_max) @intCast(max.?) else null;
    if (range_min == null and range_max == null) return .{ .constant = !negated };

    return self.singleCheck(.{
        .negated = negated,
        .score_test = .{ .matches = .{ .score = score, .min = range_min, .max = range_max } },
    });
}

fn singleCheck(self: *Self, check: Ir.Check) CompileError!Condition {
    const checks = try self.gpa.dupe(Ir.Check, &.{check});
    return .{ .clauses = try self.gpa.dupe([]const Ir.Check, &.{checks}) };
}

fn combineAnd(self: *Self, left: Condition, right: Condition) CompileError!Condition {
    if (left == .constant) return if (left.constant) right else left;
    if (right == .constant) return if (right.constant) left else right;

    var clauses: std.ArrayList([]const Ir.Check) = .empty;
    for (left.clauses) |left_checks| {
        for (right.clauses) |right_checks| {
            try clauses.append(self.gpa, try std.mem.concat(self.gpa, Ir.Check, &.{ left_checks, right_checks }));
        }
    }

    return .{ .clauses = try clauses.toOwnedSlice(self.gpa) };
}

fn combineOr(self: *Self, left: Condition, right: Condition) CompileError!Condition {
    if (left == .constant) return if (left.constant) left else right;
    if (right == .constant) return if (right.constant) right else left;

    return .{ .clauses = try std.mem.concat(self.gpa, []const Ir.Check, &.{ left.clauses, right.clauses }) };
}

fn compareOperator(op: Token.TokenType) Ir.CompareOp {
    return switch (op) {
        .less => .lt,
        .less_eql => .le,
        .greater => .gt,
        .greater_eql => .ge,
        .eql_eql, .bang_eql => .eq,
        else => unreachable,
    };
}

fn flipCompare(op: Ir.CompareOp) Ir.CompareOp {
    return switch (op) {
        .lt => .gt,
        .le => .ge,
        .eq => .eq,
        .ge => .le,
        .gt => .lt,
    };
}

fn newGeneratedName(self: *Self, kind: []const u8) CompileError![]const u8 {
    defer self.generated_count += 1;
    return std.fmt.allocPrint(self.gpa, "poplar/{s}/{s}_{d}", .{ self.current_mcfun, kind, self.generated_count });
}

fn createExpr(self: *Self, expression: Ast.Expr) CompileError!*const Ast.Expr {
    const pointer = try self.gpa.create(Ast.Expr);
    pointer.* = expression;
    return pointer;
}

fn createCommand(self: *Self, command: Ir.Command) CompileError!*const Ir.Command {
    const pointer = try self.gpa.create(Ir.Command);
    pointer.* = command;
    return pointer;
}

fn compileReturn(self: *Self, value: ?*const Ast.Expr, env: *Environment, commands: *std.ArrayList(Ir.Command)) CompileError!void {
    if (self.return_through_body) {
        const result = try self.resultScore();
        self.temp_count = 0;
        if (value) |expression| {
            try self.compileInto(result, expression, env, commands);
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

    if (!self.containsRuntimeValue(expression, env)) {
        const result = try self.evaluate(expression, env) orelse return;
        const number = try self.toScoreValue(result) orelse return;
        try commands.appendSlice(self.gpa, self.current_cleanup);
        return commands.append(self.gpa, .{ .return_value = number });
    }

    self.temp_count = 0;
    if (isParam(expression, env)) {
        try commands.appendSlice(self.gpa, self.current_cleanup);
        return commands.append(self.gpa, .{ .return_param = expression.kind.identifier.name });
    }
    // The value can read a local, so it is computed before the locals are removed.
    if (self.current_cleanup.len > 0) {
        const temp = try self.newTemp();
        try self.compileInto(temp, expression, env, commands);
        try commands.appendSlice(self.gpa, self.current_cleanup);
        return commands.append(self.gpa, .{ .return_run = try self.createCommand(.{ .score_get = temp }) });
    }
    const read: Ir.Command = blk: {
        if (expression.kind == .identifier) {
            const identifier = expression.kind.identifier;
            switch (identifier.storage) {
                .data, .entity_data => break :blk .{ .data_get = try self.dataPathOf(identifier, env) orelse return },
                .score => break :blk .{ .score_get = try self.scoreSource(identifier, env) orelse return },
                .compile_time => {},
            }
        }

        const temp = try self.newTemp();
        try self.compileInto(temp, expression, env, commands);
        break :blk .{ .score_get = temp };
    };
    try commands.append(self.gpa, .{ .return_run = try self.createCommand(read) });
}

// Wraps a command in `return run`, unless it already returns.
fn returnRun(self: *Self, command: Ir.Command) CompileError!Ir.Command {
    return switch (command) {
        .return_run, .return_value, .return_param => command,
        else => .{ .return_run = try self.createCommand(command) },
    };
}

// A loop is two functions: `while_<n>` tests the condition and runs `while_<n>_body`, which runs `while_<n>` again.
fn compileWhile(self: *Self, loop: Ast.While, env: *Environment, commands: *std.ArrayList(Ir.Command)) CompileError!void {
    const test_name = try self.newGeneratedName("while");
    const body_name = try std.fmt.allocPrint(self.gpa, "{s}_body", .{test_name});

    self.temp_count = 0;
    var test_commands: std.ArrayList(Ir.Command) = .empty;
    const condition = try self.lowerCondition(loop.condition, env, false, &test_commands) orelse return;
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
    const call_body = self.generatedCall(body_name);
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
    const call_test = self.generatedCall(test_name);
    try body_commands.append(self.gpa, if (can_return) .{ .return_run = try self.createCommand(call_test) } else call_test);

    self.current_loop = outer_loop;
    self.return_through_body = outer_through_body;

    try self.generated.append(self.gpa, .{ .name = test_name, .commands = try test_commands.toOwnedSlice(self.gpa) });
    try self.generated.append(self.gpa, .{ .name = body_name, .commands = try body_commands.toOwnedSlice(self.gpa) });

    if (!can_return) return commands.append(self.gpa, call_test);
    if (self.forwarded_args == null) return commands.append(self.gpa, try self.onBodyReturn(test_name));

    // `if function` cannot pass the macro arguments, so the result of the loop goes through a temp.
    const returned = try self.newTemp();
    try commands.append(self.gpa, .{ .store_result = .{ .target = .{ .score = returned }, .run = try self.createCommand(call_test) } });
    const pass_on = (try self.onBodyReturn(test_name)).execute.run;
    const checks = try self.gpa.dupe(Ir.Check, &.{.{ .negated = false, .score_test = .{ .matches = .{ .score = returned, .min = 1, .max = 1 } } }});
    try commands.append(self.gpa, .{ .execute = .{ .checks = checks, .run = pass_on } });
}

// `continue` of this loop level.
fn containsContinue(body: []const Ast.Stmt) bool {
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

fn compileFor(self: *Self, loop: Ast.For, env: *Environment, commands: *std.ArrayList(Ir.Command)) CompileError!void {
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

fn evaluateRange(self: *Self, loop: Ast.For, env: *Environment) CompileError!?struct { i64, i64 } {
    const start = try self.evaluate(loop.start, env) orelse return null;
    const end = try self.evaluate(loop.end, env) orelse return null;

    if (start != .number or end != .number) {
        try self.addError("range bounds must be numbers", .{});
        return null;
    }
    if (start.number > end.number) {
        try self.addError("range start {d} is greater than end {d}", .{ start.number, end.number });
        return null;
    }
    return .{ start.number, end.number };
}

fn compileCall(self: *Self, call: Ast.Call, env: *Environment, commands: *std.ArrayList(Ir.Command)) CompileError!void {
    if (call.callee.kind != .identifier) return self.addError("only named functions can be called", .{});
    const name = call.callee.kind.identifier.name;

    if (isBuiltinCall(call, "onEvent")) return self.compileOnEvent(call, env);
    if (isBuiltin(name)) return self.compileListBuiltin(name, call, env, commands);
    const callee = self.functions.get(name) orelse return self.addError("unknown function '{s}'", .{name});

    self.temp_count = 0;
    const command = try self.compileMcfnCall(call, callee.function, env, commands) orelse return;
    if (self.live_locals.items.len > 0 and try self.canReach(name, self.current_mcfun)) return self.appendWithSavedValues(command, null, 0, commands);
    try commands.append(self.gpa, command);
}

pub const builtin_names = [_][]const u8{ "append", "prepend", "insert", "remove", "len", "text", "onEvent" };

// `onEvent(criteria, callback)` in the entry file's `load`. It registers the event at compile time and writes no command.
fn compileOnEvent(self: *Self, call: Ast.Call, env: *Environment) CompileError!void {
    if (!self.in_entry_load) return self.addError("'onEvent' must be in 'mcfun load' of the entry file", .{});
    if (isInRuntimeBranch(env)) return self.addError("'onEvent' registers the event when the pack is compiled, so it cannot be in a runtime 'if', 'while' or 'execute'", .{});
    if (call.args.len != 2) return self.addError("'onEvent' expects 2 arguments (criteria, callback), found {d}", .{call.args.len});

    const criteria = try self.evaluate(call.args[0], env) orelse return;
    if (criteria != .string or criteria.string.len == 0) return self.addError("the criteria of 'onEvent' must be a string, for example \"deathCount\"", .{});

    const callback = call.args[1];
    const outer_position = self.enterExpression(callback);
    defer self.restorePosition(outer_position);
    if (callback.kind != .identifier or callback.kind.identifier.storage != .compile_time) return self.addError("the callback of 'onEvent' must be the name of an mcfun", .{});
    const name = callback.kind.identifier.name;
    const located = self.functions.get(name) orelse return self.addError("unknown mcfun '{s}'", .{name});
    if (located.function.params.len > 0) return self.addError("the callback '{s}' is run by the game, so it cannot have parameters", .{name});

    try self.events.append(self.gpa, .{ .criteria = criteria.string, .callback = name });
}

fn isInRuntimeBranch(env: *const Environment) bool {
    var scope: ?*const Environment = env;
    while (scope) |current| : (scope = current.outer) {
        if (current.runtime_branch) return true;
    }
    return false;
}

// `text(#hp)` → `{score:{name:"#global",objective:"<ns>.hp"}}`, `text($x)` → `{storage:"<ns>:data",nbt:"x"}`,
// `text(@s.$Name)` → `{entity:"@s",nbt:"Name"}`. A compile-time value becomes a string.
fn textComponent(self: *Self, argument: *const Ast.Expr, env: *Environment) CompileError!?Value {
    if (argument.kind == .identifier) {
        const identifier = argument.kind.identifier;
        switch (identifier.storage) {
            .score => {
                const score = try self.resolveScore(identifier, env) orelse return null;
                const objective = try std.fmt.allocPrint(self.gpa, "{s}.{s}", .{ self.namespace, score.objective.? });
                const holder: Value = .{ .compound = try self.gpa.dupe(Value.Entry, &.{ .{ .key = "name", .value = .{ .string = score.holder } }, .{ .key = "objective", .value = .{ .string = objective } } }) };
                return .{ .compound = try self.gpa.dupe(Value.Entry, &.{.{ .key = "score", .value = holder }}) };
            },
            .data => {
                const path = try self.dataKey(identifier.name, env) orelse return null;
                const storage = try std.fmt.allocPrint(self.gpa, "{s}:data", .{self.namespace});
                return .{ .compound = try self.gpa.dupe(Value.Entry, &.{ .{ .key = "storage", .value = .{ .string = storage } }, .{ .key = "nbt", .value = .{ .string = path } } }) };
            },
            .entity_data => return .{ .compound = try self.gpa.dupe(Value.Entry, &.{ .{ .key = "entity", .value = .{ .string = identifier.selector.? } }, .{ .key = "nbt", .value = .{ .string = identifier.name } } }) },
            .compile_time => {},
        }
    }
    const value = try self.evaluate(argument, env) orelse return null;
    return .{ .string = try self.valueToText(value) };
}

fn isBuiltin(name: []const u8) bool {
    for (builtin_names) |builtin| {
        if (std.mem.eql(u8, builtin, name)) return true;
    }
    return false;
}

fn isBuiltinCall(call: Ast.Call, name: []const u8) bool {
    return call.callee.kind == .identifier and std.mem.eql(u8, call.callee.kind.identifier.name, name);
}

// `append($list, v)`, `prepend($list, v)`, `insert($list, i, v)` and `remove($list, i)`.
fn compileListBuiltin(self: *Self, name: []const u8, call: Ast.Call, env: *Environment, commands: *std.ArrayList(Ir.Command)) CompileError!void {
    if (std.mem.eql(u8, name, "len")) return self.addError("'len' gives a value. Use it as one: '#n = len($list);'", .{});
    const arity: usize = if (std.mem.eql(u8, name, "insert")) 3 else 2;
    if (call.args.len != arity) return self.addError("'{s}' expects {d} arguments, found {d}", .{ name, arity, call.args.len });

    const list = try self.listArgument(name, call.args[0], env) orelse return;

    const has_index = std.mem.eql(u8, name, "insert") or std.mem.eql(u8, name, "remove");
    const index: i32 = if (has_index) blk: {
        const value = try self.evaluate(call.args[1], env) orelse return;
        break :blk try self.toScoreValue(value) orelse return;
    } else 0;

    if (std.mem.eql(u8, name, "remove")) {
        return commands.append(self.gpa, .{ .data_remove = .{ .holder = list.holder, .path = try std.fmt.allocPrint(self.gpa, "{s}[{d}]", .{ list.path, index }) } });
    }

    const position: Ir.DataAdd.Position = if (std.mem.eql(u8, name, "append")) .append else if (std.mem.eql(u8, name, "prepend")) .prepend else .{ .insert = index };
    const element_path = switch (position) {
        .append => "[-1]",
        .prepend => "[0]",
        .insert => try std.fmt.allocPrint(self.gpa, "[{d}]", .{index}),
    };
    const value = call.args[arity - 1];

    if (!self.containsRuntimeValue(value, env)) {
        const expression, const cast_type = splitCast(value);
        const constant = try self.evaluate(expression, env) orelse return;
        const snbt = try self.castSnbt(constant, cast_type) orelse return;
        return commands.append(self.gpa, .{ .data_add = .{ .list = list, .position = position, .source = .{ .snbt = snbt } } });
    }
    if (isDataIdentifier(value)) {
        const source = try self.dataPathOf(value.kind.identifier, env) orelse return;
        return commands.append(self.gpa, .{ .data_add = .{ .list = list, .position = position, .source = .{ .from = source } } });
    }

    // Add a `0`, then store the runtime value into it.
    try commands.append(self.gpa, .{ .data_add = .{ .list = list, .position = position, .source = .{ .snbt = "0" } } });
    const element: Ir.DataPath = .{ .holder = list.holder, .path = try std.mem.concat(self.gpa, u8, &.{ list.path, element_path }) };
    try self.compileDataAssign(element, value, env, commands);
}

// The first argument of a list helper: a `$` variable or entity data.
fn listArgument(self: *Self, name: []const u8, argument: *const Ast.Expr, env: *const Environment) CompileError!?Ir.DataPath {
    const outer_position = self.enterExpression(argument);
    defer self.restorePosition(outer_position);
    if (!isDataIdentifier(argument)) {
        try self.addError("the first argument of '{s}' must be a list: '$list' or '@s.$path'", .{name});
        return null;
    }
    return self.dataPathOf(argument.kind.identifier, env);
}

// `len($list)`: `data get` on a list, compound or string gives its size.
fn compileLength(self: *Self, target: Ir.Score, call: Ast.Call, env: *const Environment, commands: *std.ArrayList(Ir.Command)) CompileError!void {
    if (call.args.len != 1) return self.addError("'len' expects 1 argument, found {d}", .{call.args.len});
    const argument = call.args[0];
    if (!isDataIdentifier(argument)) return self.addError("'len' needs a list, a compound or a string in data", .{});
    const source = try self.dataPathOf(argument.kind.identifier, env) orelse return;
    try commands.append(self.gpa, .{ .data_to_score = .{ .source = source, .score = target } });
}

const SourcePosition = struct { path: []const u8, line: usize, column: ?usize };

// Errors inside an expression point to where it starts. Returns the outer position for `restorePosition`.
fn enterExpression(self: *Self, expression: *const Ast.Expr) SourcePosition {
    const outer: SourcePosition = .{ .path = self.current_path, .line = self.current_line, .column = self.current_column };
    self.current_line = expression.line;
    self.current_column = expression.column;
    return outer;
}

fn restorePosition(self: *Self, position: SourcePosition) void {
    self.current_path = position.path;
    self.current_line = position.line;
    self.current_column = position.column;
}

// `text(x)` and `len(x)` on a compile-time value are known when the pack is built.
fn evaluateCall(self: *Self, call: Ast.Call, env: *Environment) CompileError!?Value {
    if (call.callee.kind != .identifier) {
        try self.addError("only named functions can be called", .{});
        return null;
    }
    const name = call.callee.kind.identifier.name;
    if (isBuiltinCall(call, "text")) {
        if (call.args.len != 1) {
            try self.addError("'text' expects 1 argument, found {d}", .{call.args.len});
            return null;
        }
        return self.textComponent(call.args[0], env);
    }
    if (isBuiltinCall(call, "len") and call.args.len == 1) {
        const value = try self.evaluate(call.args[0], env) orelse return null;
        switch (value) {
            .list => |elements| return .{ .number = @intCast(elements.len) },
            .compound => |entries| return .{ .number = @intCast(entries.len) },
            .string => |text| return .{ .number = @intCast(std.unicode.utf8CountCodepoints(text) catch text.len) },
            else => {},
        }
    }
    if (self.functions.contains(name)) {
        try self.addError("mcfun '{s}' runs in the game, so its result is not known when the pack is built", .{name});
    } else if (isBuiltin(name)) {
        try self.addError("'{s}' changes data in the game, so it has no build-time value", .{name});
    } else {
        try self.addError("unknown function '{s}'", .{name});
    }
    return null;
}

const cast_error = "'as' sets the NBT type of a value that is stored in data: '$x = ... as float;' or '@s.$path = ... as float;'";

fn evaluate(self: *Self, expression: *const Ast.Expr, env: *Environment) CompileError!?Value {
    const outer_position = self.enterExpression(expression);
    defer self.restorePosition(outer_position);
    return switch (expression.kind) {
        .cast => {
            try self.addError(cast_error, .{});
            return null;
        },
        .string => |text| .{ .string = text },
        .number => |number| .{ .number = number },
        .boolean => |boolean| .{ .boolean = boolean },
        .null => .null,
        .identifier => |identifier| {
            switch (identifier.storage) {
                .compile_time => {},
                .score => {
                    try self.addError("score '#{s}' cannot be used here", .{identifier.name});
                    return null;
                },
                .data => {
                    try self.addError("data '${s}' cannot be used here", .{identifier.name});
                    return null;
                },
                .entity_data => {
                    try self.addError("entity data '{s}.${s}' cannot be used here", .{ identifier.selector.?, identifier.name });
                    return null;
                },
            }

            const value = env.get(identifier.name) orelse {
                try self.addError("unknown name '{s}'", .{identifier.name});
                return null;
            };
            if (value == .param) {
                try self.addError("parameter '{s}' is a runtime value and cannot be used at compile time", .{identifier.name});
                return null;
            }
            return value;
        },
        .prefix => |prefix| self.evaluatePrefix(prefix, env),
        .infix => |infix| self.evaluateInfix(infix, env),
        .call => |call| self.evaluateCall(call, env),
        .selector => |text| .{ .string = text },
        .list => |elements| {
            const values = try self.gpa.alloc(Value, elements.len);
            for (elements, values) |element, *value| value.* = try self.evaluate(element, env) orelse return null;
            return .{ .list = values };
        },
        .compound => |entries| {
            const values = try self.gpa.alloc(Value.Entry, entries.len);
            for (entries, values, 0..) |entry, *value, index| {
                for (entries[0..index]) |earlier| {
                    if (std.mem.eql(u8, earlier.key, entry.key)) {
                        try self.addError("key '{s}' is used more than once", .{entry.key});
                        return null;
                    }
                }
                value.* = .{ .key = entry.key, .value = try self.evaluate(entry.value, env) orelse return null };
            }
            return .{ .compound = values };
        },
    };
}

fn evaluatePrefix(self: *Self, prefix: Ast.Prefix, env: *Environment) CompileError!?Value {
    const operand = try self.evaluate(prefix.operand, env) orelse return null;

    if (prefix.op == .minus and operand == .number) return self.checkedNumber(std.math.sub(i64, 0, operand.number));
    if (prefix.op == .bang and operand == .boolean) return .{ .boolean = !operand.boolean };

    try self.addError("operator '{s}' cannot be used with {s}", .{ operatorText(prefix.op), @tagName(operand) });
    return null;
}

fn evaluateInfix(self: *Self, infix: Ast.Infix, env: *Environment) CompileError!?Value {
    const left = try self.evaluate(infix.left, env) orelse return null;
    const right = try self.evaluate(infix.right, env) orelse return null;

    if (infix.op == .plus and (left == .string or right == .string)) {
        const text = try std.fmt.allocPrint(self.gpa, "{s}{s}", .{ try self.valueToText(left), try self.valueToText(right) });
        return .{ .string = text };
    }

    if (left == .number and right == .number) {
        const a = left.number;
        const b = right.number;

        switch (infix.op) {
            .plus => return self.checkedNumber(std.math.add(i64, a, b)),
            .minus => return self.checkedNumber(std.math.sub(i64, a, b)),
            .star => return self.checkedNumber(std.math.mul(i64, a, b)),
            .slash => return self.checkedNumber(std.math.divFloor(i64, a, b)),
            .percent => return self.checkedNumber(floorMod(a, b)),
            .less => return .{ .boolean = a < b },
            .less_eql => return .{ .boolean = a <= b },
            .greater => return .{ .boolean = a > b },
            .greater_eql => return .{ .boolean = a >= b },
            else => {},
        }
    }

    if (left == .boolean and right == .boolean) {
        switch (infix.op) {
            .@"and" => return .{ .boolean = left.boolean and right.boolean },
            .@"or" => return .{ .boolean = left.boolean or right.boolean },
            else => {},
        }
    }

    if ((infix.op == .eql_eql or infix.op == .bang_eql) and std.meta.activeTag(left) == std.meta.activeTag(right)) {
        const is_equal = valuesEqual(left, right);
        return .{ .boolean = if (infix.op == .eql_eql) is_equal else !is_equal };
    }

    try self.addError("operator '{s}' cannot be used with {s} and {s}", .{
        operatorText(infix.op),
        @tagName(left),
        @tagName(right),
    });
    return null;
}

fn checkedNumber(self: *Self, result: error{ Overflow, DivisionByZero }!i64) CompileError!?Value {
    const number = result catch |err| switch (err) {
        error.Overflow => {
            try self.addError("integer overflow", .{});
            return null;
        },
        error.DivisionByZero => {
            try self.addError("division by zero", .{});
            return null;
        },
    };
    return .{ .number = number };
}

// Same result as Java's Math.floorMod, which Minecraft uses for `%=`.
fn floorMod(a: i64, b: i64) error{DivisionByZero}!i64 {
    if (b == 0) return error.DivisionByZero;
    if (b == -1) return 0;

    const remainder = @rem(a, b);
    return if (remainder != 0 and (remainder < 0) != (b < 0)) remainder + b else remainder;
}

fn valuesEqual(left: Value, right: Value) bool {
    return switch (left) {
        .string => |text| std.mem.eql(u8, text, right.string),
        .number => |number| number == right.number,
        .boolean => |boolean| boolean == right.boolean,
        .null => true,
        .list => |elements| elements.len == right.list.len and for (elements, right.list) |element, other| {
            if (std.meta.activeTag(element) != std.meta.activeTag(other) or !valuesEqual(element, other)) break false;
        } else true,
        .compound => |entries| entries.len == right.compound.len and for (entries, right.compound) |entry, other| {
            if (!std.mem.eql(u8, entry.key, other.key) or std.meta.activeTag(entry.value) != std.meta.activeTag(other.value) or !valuesEqual(entry.value, other.value)) break false;
        } else true,
        .param, .local => unreachable, // `evaluate` never returns a parameter or a local.
    };
}

fn operatorText(op: Token.TokenType) []const u8 {
    return switch (op) {
        .plus => "+",
        .minus => "-",
        .star => "*",
        .slash => "/",
        .percent => "%",
        .bang => "!",
        .less => "<",
        .less_eql => "<=",
        .greater => ">",
        .greater_eql => ">=",
        .eql_eql => "==",
        .bang_eql => "!=",
        .@"and" => "and",
        .@"or" => "or",
        else => @tagName(op),
    };
}

fn valueToText(self: *Self, value: Value) CompileError![]const u8 {
    return switch (value) {
        .string => |text| text,
        .number => |number| try std.fmt.allocPrint(self.gpa, "{d}", .{number}),
        .boolean => |boolean| if (boolean) "true" else "false",
        .null => "null",
        .list, .compound => self.valueToSnbt(value),
        .param, .local => unreachable, // `evaluate` never returns a parameter or a local.
    };
}

// A key is written as it is when it is a plain name, else in quotes.
fn snbtKey(self: *Self, key: []const u8) CompileError![]const u8 {
    for (key) |ch| {
        if (!std.ascii.isAlphanumeric(ch) and ch != '_' and ch != '-' and ch != '.' and ch != '+') return self.valueToSnbt(.{ .string = key });
    }
    return if (key.len == 0) "\"\"" else key;
}

fn valueToSnbt(self: *Self, value: Value) CompileError![]const u8 {
    switch (value) {
        .list => |elements| {
            var snbt: std.ArrayList(u8) = .empty;
            try snbt.append(self.gpa, '[');
            for (elements, 0..) |element, index| {
                if (index > 0) try snbt.append(self.gpa, ',');
                try snbt.appendSlice(self.gpa, try self.valueToSnbt(element));
            }
            try snbt.append(self.gpa, ']');
            return snbt.toOwnedSlice(self.gpa);
        },
        .compound => |entries| {
            var snbt: std.ArrayList(u8) = .empty;
            try snbt.append(self.gpa, '{');
            for (entries, 0..) |entry, index| {
                if (index > 0) try snbt.append(self.gpa, ',');
                try snbt.print(self.gpa, "{s}:{s}", .{ try self.snbtKey(entry.key), try self.valueToSnbt(entry.value) });
            }
            try snbt.append(self.gpa, '}');
            return snbt.toOwnedSlice(self.gpa);
        },
        .string => |text| {
            var snbt: std.ArrayList(u8) = .empty;
            try snbt.append(self.gpa, '"');
            for (text) |ch| {
                if (ch == '"' or ch == '\\') try snbt.append(self.gpa, '\\');
                try snbt.append(self.gpa, ch);
            }
            try snbt.append(self.gpa, '"');
            return snbt.toOwnedSlice(self.gpa);
        },
        else => return self.valueToText(value),
    }
}

fn addError(self: *Self, comptime format: []const u8, args: anytype) CompileError!void {
    const message = try std.fmt.allocPrint(self.gpa, format, args);
    try self.errors.append(self.gpa, .{
        .path = self.current_path,
        .line = self.current_line,
        .column = self.current_column,
        .message = message,
    });
}

fn addErrorAt(self: *Self, column: usize, comptime format: []const u8, args: anytype) CompileError!void {
    const message = try std.fmt.allocPrint(self.gpa, format, args);
    try self.errors.append(self.gpa, .{
        .path = self.current_path,
        .line = self.current_line,
        .column = column,
        .message = message,
    });
}

fn compileForTest(arena: std.mem.Allocator, source: []const u8) !Self {
    var parser = try Parser.init(arena, Lexer.init(source));
    const program = try parser.parseProgram();
    try std.testing.expectEqual(0, parser.errors.items.len);

    const command_tree = try arena.create(Commands);
    command_tree.* = try .load(arena);

    var compiler = Self.init(arena, command_tree);
    try compiler.addProgram("main.poplar", program, .entry);
    return compiler;
}

test "unrolls for with string concatenation" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    var compiler = try compileForTest(arena.allocator(),
        \\mcfun main() { for (0..3) |i| { /say {{"step " + i}}; } }
    );
    const commands = (try compiler.compile()).functions[0].commands;

    try std.testing.expectEqual(0, compiler.errors.items.len);
    try std.testing.expectEqual(3, commands.len);
    try std.testing.expectEqualStrings("say step 0", commands[0].raw);
    try std.testing.expectEqualStrings("say step 2", commands[2].raw);
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

test "lowers score expression in place" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    var compiler = try compileForTest(arena.allocator(),
        \\var #a = 0;
        \\var #b = 1;
        \\var #c = 2;
        \\mcfun f() { #a = (#b + 3) * #c; }
    );
    const program = try compiler.compile();
    try std.testing.expectEqual(0, compiler.errors.items.len);

    try std.testing.expectEqualStrings(
        \\scoreboard players operation #global ns.a = #global ns.b
        \\scoreboard players add #global ns.a 3
        \\scoreboard players operation #global ns.a *= #global ns.c
        \\
    , try renderForTest(arena.allocator(), program, "f"));
}

test "uses temp when target is read after write" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    var compiler = try compileForTest(arena.allocator(),
        \\var #a = 0;
        \\var #b = 1;
        \\mcfun f() { #a = #b - #a; }
    );
    const program = try compiler.compile();
    try std.testing.expectEqual(0, compiler.errors.items.len);

    try std.testing.expectEqualStrings(
        \\scoreboard players operation #poplar.f.t0 ns = #global ns.b
        \\execute store result score #global ns.a run scoreboard players operation #poplar.f.t0 ns -= #global ns.a
        \\
    , try renderForTest(arena.allocator(), program, "f"));
}

fn renderForTest(arena: std.mem.Allocator, program: Ir.Program, name: []const u8) ![]const u8 {
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

test "negated and becomes or" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    var compiler = try compileForTest(arena.allocator(),
        \\var #a = 0;
        \\var #b = 0;
        \\mcfun main() { if (!(#a > 1 and #b == 2)) { /say x; } }
    );
    const program = try compiler.compile();
    try std.testing.expectEqual(0, compiler.errors.items.len);

    try std.testing.expectEqualStrings(
        \\execute unless score #global ns.a matches 2.. run return run say x
        \\execute unless score #global ns.b matches 2 run return run say x
        \\
    , try renderForTest(arena.allocator(), program, "main"));
}

test "folds compile-time if" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    var compiler = try compileForTest(arena.allocator(),
        \\mcfun main() { for (0..4) |i| { if (i % 2 == 0) { /say {{i}}; } } }
    );
    const program = try compiler.compile();
    try std.testing.expectEqual(0, compiler.errors.items.len);

    try std.testing.expectEqualStrings("say 0\nsay 2\n", try renderForTest(arena.allocator(), program, "main"));
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

test "inserts compile-time and runtime values into commands" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    var compiler = try compileForTest(arena.allocator(),
        \\var #hp = 0;
        \\mcfun main(hp) {
        \\    var n = 2;
        \\    /effect give @p poison {{n * 5}};
        \\    /say {{#hp}} {{#hp * 2}} {{@s.$CustomName}} {{hp}} {{#hp}};
        \\}
        \\mcfun bad() { /effect give @p poison {{"x"}}; }
    );
    const program = try compiler.compile();

    try std.testing.expectEqual(1, compiler.errors.items.len);
    try std.testing.expectEqual(7, compiler.errors.items[0].line);
    try std.testing.expectEqual(38, compiler.errors.items[0].column);

    // The parameter `hp` has the name `hp`, so the score gets `hp_2`. The same score again uses it again.
    try std.testing.expectEqualStrings(
        \\effect give @p poison 10
        \\$data modify storage ns:poplar macro set value {hp:"$(hp)"}
        \\execute store result storage ns:poplar macro.hp_2 int 1 run scoreboard players get #global ns.hp
        \\scoreboard players operation #poplar.main.t0 ns = #global ns.hp
        \\execute store result storage ns:poplar macro.value int 1 run scoreboard players operation #poplar.main.t0 ns *= #poplar.c2 ns
        \\data modify storage ns:poplar macro.CustomName set from entity @s CustomName
        \\function ns:poplar/main/macro_0 with storage ns:poplar macro
        \\
    , try renderForTest(arena.allocator(), program, "main"));
    try std.testing.expectEqualStrings("$say $(hp_2) $(value) $(CustomName) $(hp) $(hp_2)\n", try renderForTest(arena.allocator(), program, "poplar/main/macro_0"));
}

test "data variables use storage and macros" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    var compiler = try compileForTest(arena.allocator(),
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
    , try renderForTest(arena.allocator(), program, "main"));
    try std.testing.expectEqualStrings("$give @p $(item) $(count)\n", try renderForTest(arena.allocator(), program, "poplar/main/macro_0"));
    try std.testing.expectEqualStrings(
        \\scoreboard objectives add ns dummy
        \\scoreboard objectives add ns.kills dummy
        \\execute unless score #global ns.kills matches -2147483648.. run scoreboard players set #global ns.kills 0
        \\execute unless data storage ns:data item run data modify storage ns:data item set value "diamond"
        \\execute unless data storage ns:data count run data modify storage ns:data count set value 3
        \\
    , try Writer.renderFunction(arena.allocator(), "ns", program.load.?));
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

test "entity scores and execute blocks" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    var compiler = try compileForTest(arena.allocator(),
        \\var #mana = 0;
        \\var #max = 100;
        \\mcfun tick() {
        \\    @a.#mana = 0;
        \\    execute (as @a at @s) {
        \\        @s.#mana = @s.#mana + 1;
        \\        if (@s.#mana > #max) { @s.#mana = #max; }
        \\        /particle heart ~ ~2 ~;
        \\    }
        \\}
    );
    const program = try compiler.compile();
    try std.testing.expectEqual(0, compiler.errors.items.len);

    try std.testing.expectEqualStrings(
        \\scoreboard players set @a ns.mana 0
        \\execute as @a at @s run function ns:poplar/tick/execute_0
        \\
    , try renderForTest(arena.allocator(), program, "tick"));
    try std.testing.expectEqualStrings(
        \\scoreboard players add @s ns.mana 1
        \\execute if score @s ns.mana > #global ns.max run scoreboard players operation @s ns.mana = #global ns.max
        \\particle heart ~ ~2 ~
        \\
    , try renderForTest(arena.allocator(), program, "poplar/tick/execute_0"));
    try std.testing.expectEqualStrings(
        \\scoreboard objectives add ns dummy
        \\scoreboard objectives add ns.mana dummy
        \\scoreboard objectives add ns.max dummy
        \\execute unless score #global ns.max matches -2147483648.. run scoreboard players set #global ns.max 100
        \\
    , try Writer.renderFunction(arena.allocator(), "ns", program.load.?));
}

test "entity score errors" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    var compiler = try compileForTest(arena.allocator(),
        \\var #mana = 0;
        \\mcfun main() {
        \\    #mana = @a.#mana;
        \\    execute (az @a) { /say hi; }
        \\    @s.$Health = #mana;
        \\}
    );
    _ = try compiler.compile();

    const errors = compiler.errors.items;
    try std.testing.expectEqual(3, errors.len);
    try std.testing.expectEqualStrings("'@a.#mana' needs a selector for one entity (@s, @p, @r, @n or limit=1)", errors[0].message);
    try std.testing.expectEqualStrings("expected a subcommand, found 'az'", errors[1].message);
    try std.testing.expectEqual(14, errors[1].column);
    try std.testing.expectEqualStrings("a score or math in entity data needs its NBT type: '@s.$Health = ... as float;' (byte, short, int, long, float, double)", errors[2].message);
}

test "reads and writes entity data with types" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    var compiler = try compileForTest(arena.allocator(),
        \\var #hp = 0;
        \\var $pos = 0;
        \\mcfun main() {
        \\    #hp = @s.$Health * 10;
        \\    @s.$Health = #hp as float;
        \\    @s.$data.x = #hp + 1 as double;
        \\    $pos = @s.$Pos;
        \\    @s.$Glowing = true as byte;
        \\}
    );
    const program = try compiler.compile();
    try std.testing.expectEqual(0, compiler.errors.items.len);

    try std.testing.expectEqualStrings(
        \\execute store result score #global ns.hp run data get entity @s Health 10
        \\execute store result entity @s Health float 1 run scoreboard players get #global ns.hp
        \\scoreboard players operation #poplar.main.t0 ns = #global ns.hp
        \\execute store result entity @s data.x double 1 run scoreboard players add #poplar.main.t0 ns 1
        \\data modify storage ns:data pos set from entity @s Pos
        \\data modify entity @s Glowing set value 1b
        \\
    , try renderForTest(arena.allocator(), program, "main"));
}

test "a command uses a data variable and a parameter together" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    var compiler = try compileForTest(arena.allocator(),
        \\var $item = "diamond";
        \\mcfun give(count) { /give @s {{$item}} {{count}}; }
    );
    const program = try compiler.compile();
    try std.testing.expectEqual(0, compiler.errors.items.len);

    try std.testing.expectEqualStrings(
        \\$data modify storage ns:poplar macro set value {count:"$(count)"}
        \\data modify storage ns:poplar macro.item set from storage ns:data item
        \\function ns:poplar/give/macro_0 with storage ns:poplar macro
        \\
    , try renderForTest(arena.allocator(), program, "give"));
    try std.testing.expectEqualStrings("$give @s $(item) $(count)\n", try renderForTest(arena.allocator(), program, "poplar/give/macro_0"));
}

test "a score or math is stored as an int unless 'as' gives the type" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    var compiler = try compileForTest(arena.allocator(),
        \\var #a = 3;
        \\var $ratio = 0 as float;
        \\var $speeds = [1, 2];
        \\mcfun heal(amount, label) { /say {{label}} {{amount}}; }
        \\mcfun main() {
        \\    $ratio = #a * 2 as float;
        \\    $speeds = #a;
        \\    heal(#a as double, "hi");
        \\}
    );
    const program = try compiler.compile();
    try std.testing.expectEqual(0, compiler.errors.items.len);

    try std.testing.expectEqualStrings(
        \\scoreboard players operation #poplar.main.t0 ns = #global ns.a
        \\execute store result storage ns:data ratio float 1 run scoreboard players operation #poplar.main.t0 ns *= #poplar.c2 ns
        \\execute store result storage ns:data speeds int 1 run scoreboard players get #global ns.a
        \\execute store result storage ns:poplar args.amount double 1 run scoreboard players get #global ns.a
        \\data modify storage ns:poplar args.label set value "hi"
        \\function ns:heal with storage ns:poplar args
        \\
    , try renderForTest(arena.allocator(), program, "main"));
    const load = try Writer.renderFunction(arena.allocator(), "ns", program.load.?);
    try std.testing.expect(std.mem.indexOf(u8, load, "ratio set value 0f") != null);
    try std.testing.expect(std.mem.indexOf(u8, load, "speeds set value [1,2]") != null);
}

test "paths, literals with runtime parts, list helpers and data conditions" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    var compiler = try compileForTest(arena.allocator(),
        \\var #x = 3;
        \\var $stats = {hp: 20, name: "x"};
        \\var $pos = [0, 0];
        \\var $names = [];
        \\var $flag = true;
        \\mcfun main() {
        \\    $stats.hp = #x;
        \\    $pos = [#x as double, 1];
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
        \\execute store result storage ns:data pos[0] double 1 run scoreboard players get #global ns.x
        \\data modify storage ns:data names append value "Steve"
        \\data modify storage ns:data names append value 0
        \\execute store result storage ns:data names[-1] int 1 run scoreboard players get #global ns.x
        \\execute store result score #global ns.x run data get storage ns:data names
        \\execute if data storage ns:data {stats:{name:"x"}} if data storage ns:data {flag:1b} run say ok
        \\execute if data storage ns:data stats.bonus run say bonus
        \\execute unless data entity @s SelectedItem.components.enchantments run say plain
        \\
    , try renderForTest(arena.allocator(), program, "main"));
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
        \\execute if function ns:poplar/find/while_0 run return run scoreboard players get #poplar.find.result ns
        \\return -1
        \\
    , try renderForTest(arena.allocator(), program, "find"));
    try std.testing.expectEqualStrings(
        \\scoreboard players operation #poplar.find.result ns = #global ns.i
        \\return 1
        \\
    , try renderForTest(arena.allocator(), program, "poplar/find/if_1"));
    try std.testing.expectEqualStrings(
        \\execute as @e if function ns:poplar/any/execute_1 run return run scoreboard players get #poplar.any.result ns
        \\return 0
        \\
    , try renderForTest(arena.allocator(), program, "any"));
}

test "selectors as values, text parts and events" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    var compiler = try compileForTest(arena.allocator(),
        \\var #hp = 7;
        \\var $stats = {maxHp: 20};
        \\mcfun tellraw(target, message) { /tellraw {{target}} {{message}}; }
        \\mcfun load() { onEvent("deathCount", playerDied); }
        \\mcfun playerDied() { tellraw(@a, ["HP ", text(#hp), text($stats.maxHp), text(@s.$CustomName)]); }
        \\mcfun greet(target) { /say {{target}}; }
        \\mcfun main() { greet(@p); }
    );
    const program = try compiler.compile();
    try std.testing.expectEqual(0, compiler.errors.items.len);

    try std.testing.expectEqualStrings(
        \\function ns:tellraw {target:"@a",message:["HP ",{score:{name:"#global",objective:"ns.hp"}},{storage:"ns:data",nbt:"stats.maxHp"},{entity:"@s",nbt:"CustomName"}]}
        \\
    , try renderForTest(arena.allocator(), program, "playerDied"));
    try std.testing.expectEqualStrings("function ns:greet {target:\"@p\"}\n", try renderForTest(arena.allocator(), program, "main"));
    try std.testing.expectEqualStrings(
        \\scoreboard players reset @s ns.event_0
        \\function ns:player_died
        \\
    , try renderForTest(arena.allocator(), program, "poplar/event_0"));
    try std.testing.expectEqualStrings(
        \\execute as @a[scores={ns.event_0=1..}] at @s run function ns:poplar/event_0
        \\
    , try renderForTest(arena.allocator(), program, "poplar/tick"));
    try std.testing.expectEqualStrings("poplar/tick", program.tick.?);

    const load = try Writer.renderFunction(arena.allocator(), "ns", program.load.?);
    try std.testing.expect(std.mem.indexOf(u8, load, "scoreboard objectives add ns.event_0 deathCount\n") != null);
    // `load` has only the event, so `poplar/load` does not call it.
    try std.testing.expect(std.mem.indexOf(u8, load, "function ns:load") == null);
}

test "onEvent errors" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    var compiler = try compileForTest(arena.allocator(),
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
    try std.testing.expectEqualStrings("unknown mcfun 'missing'", errors[1].message);
    try std.testing.expectEqualStrings("'onEvent' must be in 'mcfun load' of the entry file", errors[2].message);
}

test "load and tick run only from the entry file" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    var compiler = try compileForTest(arena.allocator(),
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
    try std.testing.expectEqualStrings("tick", program.tick.?);

    var parser = try Parser.init(arena.allocator(), Lexer.init("mcfun load() {} mcfun tick() {}"));
    var library = Self.init(arena.allocator(), compiler.command_tree);
    try library.addProgram("lib.poplar", try parser.parseProgram(), .project);
    const library_program = try library.compile();
    try std.testing.expectEqual(null, library_program.load);
    try std.testing.expectEqual(null, library_program.tick);
}

test "return values, mcfun calls as values and while" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    var compiler = try compileForTest(arena.allocator(),
        \\var #x = 0;
        \\mcfun sign() {
        \\    if (#x > 0) { return 1; } else if (#x < 0) { return -1; }
        \\    return 0;
        \\}
        \\mcfun main() {
        \\    #x = sign() + 1;
        \\    while (#x < 5) { #x = #x + 1; }
        \\}
    );
    const program = try compiler.compile();
    try std.testing.expectEqual(0, compiler.errors.items.len);

    try std.testing.expectEqualStrings(
        \\execute if score #global ns.x matches 1.. run return 1
        \\execute if score #global ns.x matches ..-1 run return -1
        \\return 0
        \\
    , try renderForTest(arena.allocator(), program, "sign"));
    try std.testing.expectEqualStrings(
        \\execute store result score #global ns.x run function ns:sign
        \\scoreboard players add #global ns.x 1
        \\execute if score #global ns.x matches ..4 run function ns:poplar/main/while_0_body
        \\
    , try renderForTest(arena.allocator(), program, "main"));
    try std.testing.expectError(error.TestUnexpectedResult, renderForTest(arena.allocator(), program, "poplar/main/while_0"));
    try std.testing.expectEqualStrings(
        \\scoreboard players add #global ns.x 1
        \\execute if score #global ns.x matches ..4 run function ns:poplar/main/while_0_body
        \\
    , try renderForTest(arena.allocator(), program, "poplar/main/while_0_body"));
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

test "mcfun parameters become macro arguments" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    var compiler = try compileForTest(arena.allocator(),
        \\var #hp = 0;
        \\mcfun heal(amount) {
        \\    #hp = #hp + amount;
        \\    if (#hp > 10) { /say {{amount}}; #hp = 10; }
        \\}
        \\mcfun main() {
        \\    heal(5);
        \\    heal(#hp * 2);
        \\}
    );
    const program = try compiler.compile();
    try std.testing.expectEqual(0, compiler.errors.items.len);

    try std.testing.expectEqualStrings(
        \\$scoreboard players set #poplar.heal.t0 ns $(amount)
        \\scoreboard players operation #global ns.hp += #poplar.heal.t0 ns
        \\$execute if score #global ns.hp matches 11.. run function ns:poplar/heal/if_0 {amount:"$(amount)"}
        \\
    , try renderForTest(arena.allocator(), program, "heal"));
    try std.testing.expectEqualStrings(
        \\$say $(amount)
        \\scoreboard players set #global ns.hp 10
        \\
    , try renderForTest(arena.allocator(), program, "poplar/heal/if_0"));
    try std.testing.expectEqualStrings(
        \\function ns:heal {amount:5}
        \\scoreboard players operation #poplar.main.t0 ns = #global ns.hp
        \\execute store result storage ns:poplar args.amount int 1 run scoreboard players operation #poplar.main.t0 ns *= #poplar.c2 ns
        \\function ns:heal with storage ns:poplar args
        \\
    , try renderForTest(arena.allocator(), program, "main"));
}

test "mcfun parameter errors" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    var compiler = try compileForTest(arena.allocator(),
        \\mcfun heal(amount) {
        \\    var copy = amount;
        \\}
        \\mcfun main() { heal(); }
    );
    _ = try compiler.compile();

    const errors = compiler.errors.items;
    try std.testing.expectEqual(2, errors.len);
    try std.testing.expectEqualStrings("'copy' is a build-time constant, but this value only exists in the game. Use 'var #copy' for a score or 'var $copy' for data", errors[0].message);
    try std.testing.expectEqualStrings("mcfun 'heal' expects 1 arguments, found 0", errors[1].message);
}

test "recursive calls save live temps in a frame" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    var compiler = try compileForTest(arena.allocator(),
        \\var #x = 0;
        \\mcfun fact(n) {
        \\    if (n <= 1) { return 1; }
        \\    return n * fact(n - 1);
        \\}
        \\mcfun double(v) { return v * 2; }
        \\mcfun main() { #x = 2 * double(3); }
    );
    const program = try compiler.compile();
    try std.testing.expectEqual(0, compiler.errors.items.len);

    try std.testing.expectEqualStrings(
        \\$scoreboard players set #poplar.fact.t0 ns $(n)
        \\execute if score #poplar.fact.t0 ns matches ..1 run return 1
        \\scoreboard players operation #poplar.fact.t2 ns = #poplar.fact.t0 ns
        \\execute store result storage ns:poplar args.n int 1 run scoreboard players remove #poplar.fact.t2 ns 1
        \\data modify storage ns:poplar stack append value {}
        \\execute store result storage ns:poplar stack[-1].t0 int 1 run scoreboard players get #poplar.fact.t0 ns
        \\execute store result score #poplar.fact.t1 ns run function ns:fact with storage ns:poplar args
        \\execute store result score #poplar.fact.t0 ns run data get storage ns:poplar stack[-1].t0
        \\data remove storage ns:poplar stack[-1]
        \\return run scoreboard players operation #poplar.fact.t0 ns *= #poplar.fact.t1 ns
        \\
    , try renderForTest(arena.allocator(), program, "fact"));
    try std.testing.expectEqualStrings(
        \\scoreboard players set #global ns.x 2
        \\execute store result score #poplar.main.t0 ns run function ns:double {v:3}
        \\scoreboard players operation #global ns.x *= #poplar.main.t0 ns
        \\
    , try renderForTest(arena.allocator(), program, "main"));
    try std.testing.expectEqual(Ir.Command.stack_clear, program.load.?.commands[0]);
}

test "locals are set on every call, saved around a recursive call, and data locals are removed at each exit" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    var compiler = try compileForTest(arena.allocator(),
        \\mcfun walk(depth) {
        \\    var #mine = depth;
        \\    var $seen = true;
        \\    if (depth > 0) { walk(depth - 1); }
        \\    /say {{#mine}} {{$seen}};
        \\}
        \\mcfun twice(n) {
        \\    var $v = n;
        \\    return $v * 2;
        \\}
    );
    const program = try compiler.compile();
    try std.testing.expectEqual(0, compiler.errors.items.len);

    try std.testing.expectEqualStrings(
        \\$scoreboard players set #mine_walk ns $(depth)
        \\data modify storage ns:data seen_walk set value true
        \\scoreboard players operation #poplar.walk.t0 ns = #mine_walk ns
        \\$execute if score #poplar.walk.t0 ns matches 1.. run function ns:poplar/walk/if_0 {depth:"$(depth)"}
        \\execute store result storage ns:poplar macro.mine int 1 run scoreboard players get #mine_walk ns
        \\data modify storage ns:poplar macro.seen_walk set from storage ns:data seen_walk
        \\function ns:poplar/walk/macro_1 with storage ns:poplar macro
        \\data remove storage ns:data seen_walk
        \\
    , try renderForTest(arena.allocator(), program, "walk"));
    try std.testing.expectEqualStrings(
        \\$execute store result storage ns:data v_twice int 1 run scoreboard players set #poplar.twice.t0 ns $(n)
        \\execute store result score #poplar.twice.t0 ns run data get storage ns:data v_twice 2
        \\data remove storage ns:data v_twice
        \\return run scoreboard players get #poplar.twice.t0 ns
        \\
    , try renderForTest(arena.allocator(), program, "twice"));
    try std.testing.expectEqualStrings(
        \\$scoreboard players set #poplar.walk.t0 ns $(depth)
        \\execute store result storage ns:poplar args.depth int 1 run scoreboard players remove #poplar.walk.t0 ns 1
        \\data modify storage ns:poplar stack append value {}
        \\execute store result storage ns:poplar stack[-1].s_mine_walk int 1 run scoreboard players get #mine_walk ns
        \\data modify storage ns:poplar stack[-1].d_seen_walk set from storage ns:data seen_walk
        \\function ns:walk with storage ns:poplar args
        \\execute store result score #mine_walk ns run data get storage ns:poplar stack[-1].s_mine_walk
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
