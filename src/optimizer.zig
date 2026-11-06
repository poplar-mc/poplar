const std = @import("std");
const ir = @import("ir.zig");
const datapack_writer = @import("datapack_writer.zig");

// The passes run in this order on each function. Each pass is a small rewrite, as in bolt-expressions.
pub fn optimizeFunction(arena: std.mem.Allocator, function_name: []const u8, commands: []const ir.Command) std.mem.Allocator.Error![]const ir.Command {
    const without_identities = try removeIdentities(arena, commands);
    const with_known_values = try propagateKnownValues(arena, without_identities);
    const without_dead_writes = try removeDeadWrites(arena, function_name, with_known_values);
    const with_scaled_gets = try scaleDataGets(arena, without_dead_writes);
    const with_inlined_stores = try inlineStores(arena, function_name, with_scaled_gets);
    return storeConstants(arena, function_name, with_inlined_stores);
}

// `execute store result storage X float 1 run scoreboard players set T 20` → `data modify storage X set value 20f`,
// when nothing reads the temp after it. A store into a score becomes `scoreboard players set`.
fn storeConstants(arena: std.mem.Allocator, function_name: []const u8, commands: []const ir.Command) std.mem.Allocator.Error![]const ir.Command {
    var result: std.ArrayList(ir.Command) = .empty;

    for (commands, 0..) |command, index| {
        if (command == .store_result and command.store_result.run.* == .score_set) {
            const set = command.store_result.run.score_set;
            if (isScopedHere(set.score, function_name) and !isReadLater(commands[index + 1 ..], set.score)) {
                try result.append(arena, switch (command.store_result.target) {
                    .score => |score| .{ .score_set = .{ .score = score, .value = set.value } },
                    .data => |path| .{ .data_set = .{ .target = path, .snbt = try std.fmt.allocPrint(arena, "{d}", .{set.value}) } },
                });
                continue;
            }
        }
        try result.append(arena, command);
    }
    return result.toOwnedSlice(arena);
}

// `add 0`, `remove 0`, `*= 1` and `/= 1` do nothing.
fn removeIdentities(arena: std.mem.Allocator, commands: []const ir.Command) std.mem.Allocator.Error![]const ir.Command {
    var result: std.ArrayList(ir.Command) = .empty;

    for (commands) |command| {
        const does_nothing = switch (command) {
            .score_add, .score_remove => |change| change.value == 0,
            .score_operation => |operation| (operation.op == .mul or operation.op == .div) and isConstantOne(operation.source),
            else => false,
        };
        if (!does_nothing) try result.append(arena, command);
    }
    return result.toOwnedSlice(arena);
}

// A score value that the optimizer knows: a number, or the value of a macro argument.
const KnownValue = union(enum) {
    number: i32,
    macro_argument: []const u8,

    fn eql(a: KnownValue, b: KnownValue) bool {
        return switch (a) {
            .number => |number| b == .number and b.number == number,
            .macro_argument => |macro_argument| b == .macro_argument and std.mem.eql(u8, b.macro_argument, macro_argument),
        };
    }
};

// The scores with a known value at one point in a function.
const KnownScores = struct {
    const Entry = struct { score: ir.Score, value: KnownValue };

    entries: std.ArrayList(Entry) = .empty,

    fn get(known: KnownScores, score: ir.Score) ?KnownValue {
        if (constantValue(score)) |number| return .{ .number = number };
        for (known.entries.items) |entry| {
            if (entry.score.eql(score)) return entry.value;
        }
        return null;
    }

    fn scoreWithValue(known: KnownScores, value: KnownValue) ?ir.Score {
        for (known.entries.items) |entry| {
            if (entry.value.eql(value)) return entry.score;
        }
        return null;
    }

    fn remember(known: *KnownScores, arena: std.mem.Allocator, score: ir.Score, value: KnownValue) std.mem.Allocator.Error!void {
        known.forget(score);
        if (isTracked(score)) try known.entries.append(arena, .{ .score = score, .value = value });
    }

    fn forget(known: *KnownScores, score: ir.Score) void {
        for (known.entries.items, 0..) |entry, index| {
            if (entry.score.eql(score)) {
                _ = known.entries.swapRemove(index);
                return;
            }
        }
    }

    // A call can run this mcfun again (recursion), and a user command can change any score.
    fn forgetWrites(known: *KnownScores, command: ir.Command) void {
        if (runsOtherCode(command)) return known.entries.clearRetainingCapacity();
        switch (command) {
            .score_set, .score_add, .score_remove, .score_set_if_unset => |set| known.forget(set.score),
            .score_set_macro_argument => |set| known.forget(set.score),
            .score_operation => |operation| known.forget(operation.target),
            .data_to_score => |store| known.forget(store.score),
            .store_result => |store| {
                if (store.target == .score) known.forget(store.target.score);
                known.forgetWrites(store.run.*);
            },
            .execute => |execute| known.forgetWrites(execute.run.*),
            .return_run => |run| known.forgetWrites(run.*),
            else => {},
        }
    }

    fn learn(known: *KnownScores, arena: std.mem.Allocator, command: ir.Command) std.mem.Allocator.Error!void {
        const learned: ?struct { ir.Score, KnownValue } = switch (command) {
            .score_set => |set| .{ set.score, .{ .number = set.value } },
            .score_set_macro_argument => |set| .{ set.score, .{ .macro_argument = set.macro_argument } },
            .score_operation => |operation| if (operation.op == .assign)
                if (known.get(operation.source)) |value| .{ operation.target, value } else null
            else
                null,
            else => null,
        };
        known.forgetWrites(command);
        if (learned) |score_and_value| try known.remember(arena, score_and_value[0], score_and_value[1]);
    }
};

// Removes a set when the score already has the value, copies a macro argument from a score that holds it
// (a macro line is parsed again for new arguments), and computes math on known numbers.
fn propagateKnownValues(arena: std.mem.Allocator, commands: []const ir.Command) std.mem.Allocator.Error![]const ir.Command {
    var result: std.ArrayList(ir.Command) = .empty;
    var known: KnownScores = .{};
    defer known.entries.deinit(arena);

    for (commands) |command| {
        const optimized: ?ir.Command = switch (command) {
            .score_set => |set| if (isKnown(known, set.score, .{ .number = set.value })) null else command,
            .score_set_macro_argument => |set| blk: {
                const value: KnownValue = .{ .macro_argument = set.macro_argument };
                if (isKnown(known, set.score, value)) break :blk null;
                const copy = known.scoreWithValue(value) orelse break :blk command;
                break :blk .{ .score_operation = .{ .target = set.score, .op = .assign, .source = copy } };
            },
            .score_add, .score_remove, .score_operation => if (foldMath(known, command)) |set| .{ .score_set = set } else command,
            else => command,
        };
        if (optimized) |kept| {
            try known.learn(arena, kept);
            try result.append(arena, kept);
        }
    }
    return result.toOwnedSlice(arena);
}

fn isKnown(known: KnownScores, score: ir.Score, value: KnownValue) bool {
    const current = known.get(score) orelse return false;
    return current.eql(value);
}

// The same math as Minecraft: ints wrap, and `/=` and `%=` round down. Division by 0 is not computed.
fn foldMath(known: KnownScores, command: ir.Command) ?ir.ScoreValue {
    const target, const op: ir.Operator, const source: KnownValue = switch (command) {
        .score_add => |change| .{ change.score, .add, .{ .number = change.value } },
        .score_remove => |change| .{ change.score, .sub, .{ .number = change.value } },
        .score_operation => |operation| .{ operation.target, operation.op, known.get(operation.source) orelse return null },
        else => return null,
    };
    if (source != .number) return null;
    const right = source.number;
    if (op == .assign) return .{ .score = target, .value = right };

    const current = known.get(target) orelse return null;
    if (current != .number) return null;
    const left = current.number;

    const value = switch (op) {
        .assign => unreachable,
        .add => left +% right,
        .sub => left -% right,
        .mul => left *% right,
        .div => if (right == 0 or (left == std.math.minInt(i32) and right == -1)) return null else @divFloor(left, right),
        .mod => if (right <= 0) return null else @mod(left, right),
    };
    return .{ .score = target, .value = value };
}

// A write to a temp or a local is removed when nothing reads it before it is set again or the function ends.
// A write to a global is removed only when it is set again before anything else can read it.
fn removeDeadWrites(arena: std.mem.Allocator, function_name: []const u8, commands: []const ir.Command) std.mem.Allocator.Error![]const ir.Command {
    var result: std.ArrayList(ir.Command) = .empty;

    for (commands, 0..) |command, index| {
        const written = switch (command) {
            .score_set, .score_add, .score_remove => |set| set.score,
            .score_set_macro_argument => |set| set.score,
            .score_operation => |operation| operation.target,
            .data_to_score => |store| store.score,
            else => null,
        };
        if (written) |score| {
            const rest = commands[index + 1 ..];
            const is_dead = if (isScopedHere(score, function_name)) !isReadLater(rest, score) else isTracked(score) and isSetBeforeUse(rest, score);
            if (is_dead) continue;
        }
        try result.append(arena, command);
    }
    return result.toOwnedSlice(arena);
}

// `data get X` followed by `*= N` becomes `data get X N`. Only `*=`: a scale such as 0.01 can round wrongly.
fn scaleDataGets(arena: std.mem.Allocator, commands: []const ir.Command) std.mem.Allocator.Error![]const ir.Command {
    var result: std.ArrayList(ir.Command) = .empty;

    var index: usize = 0;
    while (index < commands.len) : (index += 1) {
        var command = commands[index];
        if (command == .data_to_score and index + 1 < commands.len and commands[index + 1] == .score_operation) {
            const operation = commands[index + 1].score_operation;
            const is_scaling = operation.op == .mul and operation.target.eql(command.data_to_score.score);
            if (is_scaling) {
                if (constantValue(operation.source)) |factor| {
                    if (std.math.mul(i32, command.data_to_score.scale, factor)) |scale| {
                        command.data_to_score.scale = scale;
                        index += 1;
                    } else |_| {}
                }
            }
        }
        try result.append(arena, command);
    }
    return result.toOwnedSlice(arena);
}

// A command that computes a temp, followed by a copy of that temp, becomes one command:
// `scoreboard players remove T 1` + `execute store result storage X int 1 run scoreboard players get T`
// → `execute store result storage X int 1 run scoreboard players remove T 1`.
fn inlineStores(arena: std.mem.Allocator, function_name: []const u8, commands: []const ir.Command) std.mem.Allocator.Error![]const ir.Command {
    var result: std.ArrayList(ir.Command) = .empty;

    var index: usize = 0;
    while (index < commands.len) : (index += 1) {
        const command = commands[index];
        if (index + 1 < commands.len) {
            if (definedTemp(command, function_name)) |temp| {
                if (try mergeCopy(arena, command, commands[index + 1], temp)) |merged| {
                    if (!isReadLater(commands[index + 2 ..], temp)) {
                        try result.append(arena, merged);
                        index += 1;
                        continue;
                    }
                }
            }
        }
        try result.append(arena, command);
    }
    return result.toOwnedSlice(arena);
}

// The temp that a command writes, when the command's result is the temp's new value.
// `/=` and `%=` fail when the source is 0, and then the result is 0, so they need a constant source.
fn definedTemp(command: ir.Command, function_name: []const u8) ?ir.Score {
    const score = switch (command) {
        .score_set, .score_add, .score_remove => |set| set.score,
        .score_set_macro_argument => |set| set.score,
        .score_operation => |operation| blk: {
            const can_fail = operation.op == .div or operation.op == .mod;
            if (can_fail and !isConstant(operation.source)) return null;
            break :blk operation.target;
        },
        else => return null,
    };
    return if (isScopedHere(score, function_name)) score else null;
}

fn mergeCopy(arena: std.mem.Allocator, definition: ir.Command, copy: ir.Command, temp: ir.Score) std.mem.Allocator.Error!?ir.Command {
    switch (copy) {
        .score_to_data => |store| {
            if (!store.score.eql(temp)) return null;
            const target: ir.StoreResult.Target = .{ .data = store.target };
            return .{ .store_result = .{ .target = target, .run = try create(arena, definition) } };
        },
        .return_run => |run| {
            if (run.* != .score_get or !run.score_get.eql(temp)) return null;
            return .{ .return_run = try create(arena, definition) };
        },
        .score_operation => |operation| {
            if (operation.op != .assign or !operation.source.eql(temp) or operation.target.eql(temp)) return null;
            return .{ .store_result = .{ .target = .{ .score = operation.target }, .run = try create(arena, definition) } };
        },
        else => return null,
    }
}

// True if a command reads the temp before a command sets it again.
fn isReadLater(commands: []const ir.Command, temp: ir.Score) bool {
    for (commands) |command| {
        if (readsScore(command, temp) or callsTempReader(command, temp)) return true;
        // Command text can name a local's fake player: a user command, or a `text(#x)` part in a call's arguments.
        if (temp.owner != null and mentionsInText(command, temp.holder)) return true;
        if (setsScore(command, temp)) return false;
    }
    return false;
}

fn mentionsInText(command: ir.Command, name: []const u8) bool {
    return switch (command) {
        .raw, .macro => |text| std.mem.indexOf(u8, text, name) != null,
        .function_with => |call| call.arguments == .compound and std.mem.indexOf(u8, call.arguments.compound, name) != null,
        .execute => |execute| for (execute.checks) |check| {
            if (check.condition == .raw and std.mem.indexOf(u8, check.condition.raw, name) != null) break true;
        } else mentionsInText(execute.run.*, name),
        .execute_raw => |execute| std.mem.indexOf(u8, execute.subcommands, name) != null or mentionsInText(execute.run.*, name),
        .store_result => |store| mentionsInText(store.run.*, name),
        .return_run => |run| mentionsInText(run.*, name),
        else => false,
    };
}

pub fn readsScore(command: ir.Command, score: ir.Score) bool {
    return switch (command) {
        .score_add, .score_remove => |change| change.score.eql(score),
        .score_operation => |operation| operation.source.eql(score) or (operation.op != .assign and operation.target.eql(score)),
        .score_to_data => |store| store.score.eql(score),
        .score_get => |read| read.eql(score),
        .execute => |execute| for (execute.checks) |check| {
            if (checkReads(check, score)) break true;
        } else readsScore(execute.run.*, score),
        .execute_raw => |execute| readsScore(execute.run.*, score),
        .store_result => |store| readsScore(store.run.*, score),
        .return_run => |run| readsScore(run.*, score),
        else => false,
    };
}

// Only a command that always runs counts. A write inside `execute if` may not happen.
fn setsScore(command: ir.Command, score: ir.Score) bool {
    return switch (command) {
        .score_set => |set| set.score.eql(score),
        .score_set_macro_argument => |set| set.score.eql(score),
        .score_operation => |operation| operation.op == .assign and operation.target.eql(score),
        .data_to_score => |store| store.score.eql(score),
        .store_result => |store| store.target == .score and store.target.score.eql(score),
        else => false,
    };
}

// Other functions and user commands can read any global score, and so can the caller after a return.
fn isSetBeforeUse(commands: []const ir.Command, score: ir.Score) bool {
    for (commands) |command| {
        if (readsScore(command, score) or runsOtherCode(command) or canReturn(command)) return false;
        if (setsScore(command, score)) return true;
    }
    return false;
}

fn runsOtherCode(command: ir.Command) bool {
    return switch (command) {
        .function, .function_with, .macro, .raw, .execute_raw => true,
        .execute => |execute| checkedFunction(execute) != null or runsCheckedCode(execute) or runsOtherCode(execute.run.*),
        .store_result => |store| runsOtherCode(store.run.*),
        .return_run => |run| runsOtherCode(run.*),
        else => false,
    };
}

fn canReturn(command: ir.Command) bool {
    return switch (command) {
        .return_run, .return_value, .return_macro_argument => true,
        .execute => |execute| canReturn(execute.run.*),
        .execute_raw => |execute| canReturn(execute.run.*),
        else => false,
    };
}

// Fake players, and `@s`, which is the same entity for the whole function.
// Other selectors can match other entities in each command.
fn isTracked(score: ir.Score) bool {
    return std.mem.startsWith(u8, score.holder, "#") or std.mem.eql(u8, score.holder, "@s");
}

// A generated function with one command is put where it is called, and the function is removed.
// A command that can return is not moved, because the `return` would then leave the caller.
pub fn inlineSmallFunctions(arena: std.mem.Allocator, functions: []const ir.McFunction) std.mem.Allocator.Error![]ir.McFunction {
    // One pass with the original bodies, so that functions that call each other cannot grow forever.
    const result = try arena.dupe(ir.McFunction, functions);
    for (result) |*function| {
        var commands: std.ArrayList(ir.Command) = .empty;
        for (function.commands) |command| {
            try commands.append(arena, try inlineCall(arena, functions, function.name, command) orelse command);
        }
        function.commands = try commands.toOwnedSlice(arena);
    }
    try inlineTailCalls(arena, result);

    var used: std.ArrayList(ir.McFunction) = .empty;
    for (result) |function| {
        if (!isGenerated(function.name) or isCalled(result, function.name)) try used.append(arena, function);
    }
    for (used.items) |*function| function.commands = try optimizeFunction(arena, function.name, function.commands);
    return used.toOwnedSlice(arena);
}

fn inlineCall(arena: std.mem.Allocator, functions: []const ir.McFunction, caller: []const u8, command: ir.Command) std.mem.Allocator.Error!?ir.Command {
    switch (command) {
        .function => |name| return smallBody(functions, caller, name),
        // A generated function gets the arguments of its mcfun, so `$(arg)` means the same in the caller.
        .function_with => |call| return if (call.arguments == .compound) smallBody(functions, caller, call.name) else null,
        .execute => |execute| {
            const run = try inlineCall(arena, functions, caller, execute.run.*) orelse return null;
            if (run == .execute) {
                const checks = try std.mem.concat(arena, ir.Check, &.{ execute.checks, run.execute.checks });
                return .{ .execute = .{ .checks = checks, .run = run.execute.run } };
            }
            return .{ .execute = .{ .checks = execute.checks, .run = try create(arena, run) } };
        },
        .execute_raw => |execute| {
            const run = try inlineCall(arena, functions, caller, execute.run.*) orelse return null;
            return .{ .execute_raw = .{ .subcommands = execute.subcommands, .run = try create(arena, run) } };
        },
        else => return null,
    }
}

fn smallBody(functions: []const ir.McFunction, caller: []const u8, name: []const u8) ?ir.Command {
    if (!isGenerated(name) or std.mem.eql(u8, caller, name)) return null;
    for (functions) |function| {
        if (!std.mem.eql(u8, function.name, name)) continue;
        if (function.commands.len != 1 or canReturn(function.commands[0])) return null;
        return function.commands[0];
    }
    return null;
}

// A generated function that is called once, as the last command of its caller, is put in its place, even when
// it can return: leaving the caller there is what happens anyway. Not when something reads the caller's return value.
fn inlineTailCalls(arena: std.mem.Allocator, functions: []ir.McFunction) std.mem.Allocator.Error!void {
    for (functions) |*function| {
        const commands = function.commands;
        if (commands.len == 0) continue;
        const callee_name = switch (commands[commands.len - 1]) {
            .function => |name| name,
            // A generated function gets the arguments of its mcfun, so `$(arg)` means the same in the caller.
            .function_with => |call| if (call.arguments == .compound) call.name else continue,
            else => continue,
        };
        if (!isGenerated(callee_name) or std.mem.eql(u8, callee_name, function.name)) continue;
        if (callCount(functions, callee_name) != 1 or isReturnValueRead(functions, function.name)) continue;
        const callee = for (functions) |candidate| {
            if (std.mem.eql(u8, candidate.name, callee_name)) break candidate;
        } else continue;
        function.commands = try std.mem.concat(arena, ir.Command, &.{ commands[0 .. commands.len - 1], callee.commands });
    }
}

fn callCount(functions: []const ir.McFunction, name: []const u8) usize {
    var count: usize = 0;
    for (functions) |function| {
        for (function.commands) |command| {
            if (callsFunction(command, name)) count += 1;
        }
    }
    return count;
}

// True when a command uses the return value of `name`: `store result ... run function`, `if function`, or `return run function`.
fn isReturnValueRead(functions: []const ir.McFunction, name: []const u8) bool {
    for (functions) |function| {
        for (function.commands) |command| {
            if (readsReturnValue(command, name)) return true;
        }
    }
    return false;
}

fn readsReturnValue(command: ir.Command, name: []const u8) bool {
    return switch (command) {
        .store_result => |store| callsFunction(store.run.*, name),
        .return_run => |run| callsFunction(run.*, name),
        .execute => |execute| blk: {
            if (checkedFunction(execute)) |checked| if (std.mem.eql(u8, checked, name)) break :blk true;
            break :blk readsReturnValue(execute.run.*, name);
        },
        .execute_raw => |execute| readsReturnValue(execute.run.*, name),
        else => false,
    };
}

fn isGenerated(name: []const u8) bool {
    _, const path = ir.splitName(name);
    return std.mem.startsWith(u8, path, "poplar/");
}

// A generated body gets the macro arguments of its mcfun (`{amount:"$(amount)"}`) only if it, or a body that it calls, has a
// macro line. The others are called without them, so a value with a `"` in it cannot break the call.
pub fn dropUnusedArguments(arena: std.mem.Allocator, functions: []ir.McFunction) std.mem.Allocator.Error!void {
    var needs: std.StringHashMapUnmanaged(void) = .empty;
    var is_changed = true;
    while (is_changed) {
        is_changed = false;
        for (functions) |function| {
            if (!isGenerated(function.name) or needs.contains(function.name)) continue;
            for (function.commands) |command| {
                if (!try usesArguments(arena, command, &needs)) continue;
                try needs.put(arena, function.name, {});
                is_changed = true;
                break;
            }
        }
    }
    for (functions) |*function| {
        const commands = try arena.alloc(ir.Command, function.commands.len);
        for (function.commands, commands) |command, *result| result.* = try withoutArguments(arena, command, &needs);
        function.commands = commands;
    }
}

fn usesArguments(arena: std.mem.Allocator, command: ir.Command, needs: *const std.StringHashMapUnmanaged(void)) std.mem.Allocator.Error!bool {
    switch (command) {
        .function_with => |call| if (call.arguments == .compound and isGenerated(call.name)) return needs.contains(call.name),
        // The wrapper and its run are checked apart, so a call inside counts only as itself.
        .execute, .execute_raw, .store_result, .return_run => {
            const run = runOf(command).?;
            return try hasMacroText(arena, try withRun(arena, command, .{ .raw = "" })) or try usesArguments(arena, run.*, needs);
        },
        else => {},
    }
    return hasMacroText(arena, command);
}

fn hasMacroText(arena: std.mem.Allocator, command: ir.Command) std.mem.Allocator.Error!bool {
    var text: std.ArrayList(u8) = .empty;
    try datapack_writer.renderCommand(&text, arena, "", command);
    return std.mem.indexOf(u8, text.items, "$(") != null;
}

fn withoutArguments(arena: std.mem.Allocator, command: ir.Command, needs: *const std.StringHashMapUnmanaged(void)) std.mem.Allocator.Error!ir.Command {
    switch (command) {
        .function_with => |call| if (call.arguments == .compound and isGenerated(call.name) and !needs.contains(call.name)) return .{ .function = call.name },
        .execute, .execute_raw, .store_result, .return_run => return withRun(arena, command, try withoutArguments(arena, runOf(command).?.*, needs)),
        else => {},
    }
    return command;
}

fn runOf(command: ir.Command) ?*const ir.Command {
    return switch (command) {
        .execute => |execute| execute.run,
        .execute_raw => |execute| execute.run,
        .store_result => |store| store.run,
        .return_run => |run| run,
        else => null,
    };
}

fn withRun(arena: std.mem.Allocator, command: ir.Command, run: ir.Command) std.mem.Allocator.Error!ir.Command {
    const new_run = try arena.create(ir.Command);
    new_run.* = run;
    return switch (command) {
        .execute => |execute| .{ .execute = .{ .checks = execute.checks, .run = new_run } },
        .execute_raw => |execute| .{ .execute_raw = .{ .subcommands = execute.subcommands, .run = new_run } },
        .store_result => |store| .{ .store_result = .{ .target = store.target, .run = new_run } },
        .return_run => .{ .return_run = new_run },
        else => unreachable,
    };
}

fn isCalled(functions: []const ir.McFunction, name: []const u8) bool {
    for (functions) |function| {
        for (function.commands) |command| {
            if (callsFunction(command, name)) return true;
        }
    }
    return false;
}

fn callsFunction(command: ir.Command, name: []const u8) bool {
    return switch (command) {
        .function => |called| std.mem.eql(u8, called, name),
        .function_with => |call| std.mem.eql(u8, call.name, name),
        .execute => |execute| if (checkedFunction(execute)) |checked| std.mem.eql(u8, checked, name) or callsFunction(execute.run.*, name) else callsFunction(execute.run.*, name),
        .execute_raw => |execute| callsFunction(execute.run.*, name),
        .store_result => |store| callsFunction(store.run.*, name),
        .return_run => |run| callsFunction(run.*, name),
        else => false,
    };
}

// Only the mcfun and its generated functions (`poplar/<mcfun>/...`) read the temps of the mcfun.
// The mcfun itself sets each temp before it reads it, so a recursive call does not read them.
fn callsTempReader(command: ir.Command, temp: ir.Score) bool {
    const name = switch (command) {
        .function => |name| name,
        .function_with => |call| call.name,
        .execute => |execute| {
            if (checkedFunction(execute)) |checked| if (readsTempsOf(checked, temp)) return true;
            return callsTempReader(execute.run.*, temp);
        },
        .execute_raw => |execute| return callsTempReader(execute.run.*, temp),
        .store_result => |store| return callsTempReader(store.run.*, temp),
        .return_run => |run| return callsTempReader(run.*, temp),
        else => return false,
    };
    return readsTempsOf(name, temp);
}

// `if function ...` written by the user runs code as part of the check.
fn runsCheckedCode(execute: ir.Execute) bool {
    for (execute.checks) |check| {
        if (check.condition == .raw and std.mem.startsWith(u8, check.condition.raw, "function ")) return true;
    }
    return false;
}

// The function of an `execute if function ...` check.
fn checkedFunction(execute: ir.Execute) ?[]const u8 {
    for (execute.checks) |check| {
        if (check.condition == .function_returns) return check.condition.function_returns;
    }
    return null;
}

fn readsTempsOf(name: []const u8, temp: ir.Score) bool {
    // A `macro_<n>` helper holds one user command, so it never reads a temp.
    if (std.mem.startsWith(u8, std.fs.path.basenamePosix(name), "macro_")) return false;

    const function_namespace, const path = ir.splitName(name);
    // A local knows its mcfun (`combat:heal`). A temp names it in its holder (`#poplar.heal.t0`), in its namespace.
    const owner_namespace, const owner = if (temp.owner) |owner| ir.splitName(owner) else .{ temp.namespace, temp.holder["#poplar.".len..std.mem.lastIndexOfScalar(u8, temp.holder, '.').?] };
    if (!ir.optionalEql(function_namespace, owner_namespace)) return false;

    const generated_prefix = "poplar/";
    if (!std.mem.startsWith(u8, path, generated_prefix)) return false;
    const folder_end = std.mem.indexOfScalarPos(u8, path, generated_prefix.len, '/') orelse return false;
    return ir.isGeneratedFolder(path[generated_prefix.len..folder_end], owner);
}

fn checkReads(check: ir.Check, score: ir.Score) bool {
    return switch (check.condition) {
        .data_test, .function_returns => false,
        // `score @s ...` in a check written by the user can name any score.
        .raw => |raw| std.mem.indexOf(u8, raw, score.holder) != null,
        .matches => |matches| matches.score.eql(score),
        .compare => |compare| compare.left.eql(score) or compare.right.eql(score),
    };
}

// A temp, or a local of this mcfun, is only read by this function and its generated functions. A local can be
// written in a generated body and read by its mcfun after the body returns, so it only counts in the mcfun itself.
fn isScopedHere(score: ir.Score, function_name: []const u8) bool {
    if (score.owner) |owner| return std.mem.eql(u8, owner, function_name);
    return isTemp(score);
}

// Temps are `#poplar.<mcfun>.t<N>`. They are only read in the function that writes them.
fn isTemp(score: ir.Score) bool {
    if (score.objective != null or !std.mem.startsWith(u8, score.holder, "#poplar.") or isConstant(score)) return false;
    const name = score.holder[std.mem.lastIndexOfScalar(u8, score.holder, '.').? + 1 ..];
    return name.len > 1 and name[0] == 't' and std.ascii.isDigit(name[1]);
}

// Constants are `#poplar.c<N>`.
fn constantValue(score: ir.Score) ?i32 {
    const prefix = "#poplar.c";
    if (score.objective != null or !std.mem.startsWith(u8, score.holder, prefix)) return null;
    return std.fmt.parseInt(i32, score.holder[prefix.len..], 10) catch null;
}

fn isConstant(score: ir.Score) bool {
    return constantValue(score) != null;
}

fn isConstantOne(score: ir.Score) bool {
    return constantValue(score) == 1;
}

fn create(arena: std.mem.Allocator, command: ir.Command) std.mem.Allocator.Error!*const ir.Command {
    const pointer = try arena.create(ir.Command);
    pointer.* = command;
    return pointer;
}

test "removes identities and inlines copies of temps" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const temp: ir.Score = .{ .holder = "#poplar.f.t0" };
    const other_temp: ir.Score = .{ .holder = "#poplar.f.t1" };
    const division_temp: ir.Score = .{ .holder = "#poplar.f.t2" };
    const entity: ir.Score = .{ .holder = "@p", .objective = "x" };

    const commands = [_]ir.Command{
        .{ .score_add = .{ .score = temp, .value = 0 } },
        .{ .score_operation = .{ .target = temp, .op = .mul, .source = .{ .holder = "#poplar.c1" } } },
        .{ .score_remove = .{ .score = temp, .value = 1 } },
        .{ .score_to_data = .{ .target = .inStorage(.args, "n"), .score = temp } },
        // Not inlined: the temp is read again below.
        .{ .score_set = .{ .score = other_temp, .value = 5 } },
        .{ .score_operation = .{ .target = entity, .op = .assign, .source = other_temp } },
        .{ .score_get = other_temp },
        // Not inlined: `/=` with a temp source can fail.
        .{ .score_operation = .{ .target = division_temp, .op = .div, .source = other_temp } },
        .{ .score_operation = .{ .target = entity, .op = .assign, .source = division_temp } },
    };

    const result = try optimizeFunction(arena, "f", &commands);
    try std.testing.expectEqual(6, result.len);
    try std.testing.expect(result[0] == .store_result);
    try std.testing.expectEqualStrings("n", result[0].store_result.target.data.path);
    try std.testing.expect(result[0].store_result.run.* == .score_remove);
    try std.testing.expect(result[1] == .score_set);
    try std.testing.expect(result[4] == .score_operation);
}

test "uses known values, removes dead writes and scales data gets" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const temp: ir.Score = .{ .holder = "#poplar.f.t0" };
    const copy_temp: ir.Score = .{ .holder = "#poplar.f.t1" };
    const after_call_temp: ir.Score = .{ .holder = "#poplar.f.t2" };
    const global: ir.Score = .{ .holder = "#global", .objective = "x" };
    const at_most_one: ir.Check = .{ .negated = false, .condition = .{ .matches = .{ .score = temp, .min = null, .max = 1 } } };

    const commands = [_]ir.Command{
        .{ .score_set_macro_argument = .{ .score = temp, .macro_argument = "n" } },
        .{ .execute = .{ .checks = &.{at_most_one}, .run = &ir.Command{ .return_value = 1 } } },
        // Removed: the temp already holds `n`.
        .{ .score_set_macro_argument = .{ .score = temp, .macro_argument = "n" } },
        // Becomes a copy of the temp.
        .{ .score_set_macro_argument = .{ .score = copy_temp, .macro_argument = "n" } },
        .{ .score_to_data = .{ .target = .inStorage(.args, "n"), .score = copy_temp } },
        // Kept: the call can change every score.
        .{ .function = "other" },
        .{ .score_set_macro_argument = .{ .score = after_call_temp, .macro_argument = "n" } },
        .{ .score_to_data = .{ .target = .inStorage(.args, "m"), .score = after_call_temp } },
        // `set 7` is removed, and `*= 3` becomes `set 21`.
        .{ .score_set = .{ .score = global, .value = 7 } },
        .{ .score_operation = .{ .target = global, .op = .mul, .source = .{ .holder = "#poplar.c3" } } },
        .{ .function = "other" },
        .{ .data_to_score = .{ .source = .inStorage(.data, "count"), .score = global } },
        .{ .score_operation = .{ .target = global, .op = .mul, .source = .{ .holder = "#poplar.c100" } } },
    };

    const result = try optimizeFunction(arena, "f", &commands);
    try std.testing.expectEqual(8, result.len);
    try std.testing.expect(result[2].store_result.run.* == .score_operation);
    try std.testing.expect(result[4].store_result.run.* == .score_set_macro_argument);
    try std.testing.expectEqual(21, result[5].score_set.value);
    try std.testing.expectEqual(100, result[7].data_to_score.scale);
}
