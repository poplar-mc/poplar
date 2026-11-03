const std = @import("std");
const Ir = @import("Ir.zig");

const Allocator = std.mem.Allocator;

// The passes run in this order on each function. Each pass is a small rewrite, as in bolt-expressions.
pub fn optimizeFunction(gpa: Allocator, function_name: []const u8, commands: []const Ir.Command) Allocator.Error![]const Ir.Command {
    const without_identities = try removeIdentities(gpa, commands);
    const with_known_values = try propagateKnownValues(gpa, without_identities);
    const without_dead_writes = try removeDeadWrites(gpa, function_name, with_known_values);
    const with_scaled_gets = try scaleDataGets(gpa, without_dead_writes);
    const with_inlined_stores = try inlineStores(gpa, function_name, with_scaled_gets);
    return storeConstants(gpa, function_name, with_inlined_stores);
}

// `execute store result storage X float 1 run scoreboard players set T 20` → `data modify storage X set value 20f`,
// when nothing reads the temp after it. A store into a score becomes `scoreboard players set`.
fn storeConstants(gpa: Allocator, function_name: []const u8, commands: []const Ir.Command) Allocator.Error![]const Ir.Command {
    var result: std.ArrayList(Ir.Command) = .empty;

    for (commands, 0..) |command, index| {
        if (command == .store_result and command.store_result.run.* == .score_set) {
            const set = command.store_result.run.score_set;
            if (isScopedHere(set.score, function_name) and !isReadLater(commands[index + 1 ..], set.score)) {
                try result.append(gpa, switch (command.store_result.target) {
                    .score => |score| .{ .score_set = .{ .score = score, .value = set.value } },
                    .data => |data| .{ .data_set = .{ .target = data.path, .snbt = try numberSnbt(gpa, set.value, data.type) } },
                });
                continue;
            }
        }
        try result.append(gpa, command);
    }
    return result.toOwnedSlice(gpa);
}

fn numberSnbt(gpa: Allocator, value: i32, number_type: Ir.NumberType) Allocator.Error![]const u8 {
    const suffix = switch (number_type) {
        .byte => "b",
        .short => "s",
        .int => "",
        .long => "L",
        .float => "f",
        .double => "d",
    };
    return std.fmt.allocPrint(gpa, "{d}{s}", .{ value, suffix });
}

// `add 0`, `remove 0`, `*= 1` and `/= 1` do nothing.
fn removeIdentities(gpa: Allocator, commands: []const Ir.Command) Allocator.Error![]const Ir.Command {
    var result: std.ArrayList(Ir.Command) = .empty;

    for (commands) |command| {
        const does_nothing = switch (command) {
            .score_add, .score_remove => |change| change.value == 0,
            .score_operation => |operation| (operation.op == .mul or operation.op == .div) and isConstantOne(operation.source),
            else => false,
        };
        if (!does_nothing) try result.append(gpa, command);
    }
    return result.toOwnedSlice(gpa);
}

// A score value that the optimizer knows: a number, or the value of an mcfun parameter.
const KnownValue = union(enum) {
    number: i32,
    param: []const u8,

    fn eql(a: KnownValue, b: KnownValue) bool {
        return switch (a) {
            .number => |number| b == .number and b.number == number,
            .param => |param| b == .param and std.mem.eql(u8, b.param, param),
        };
    }
};

// The scores with a known value at one point in a function.
const KnownScores = struct {
    const Entry = struct { score: Ir.Score, value: KnownValue };

    entries: std.ArrayList(Entry) = .empty,

    fn get(known: KnownScores, score: Ir.Score) ?KnownValue {
        if (constantValue(score)) |number| return .{ .number = number };
        for (known.entries.items) |entry| {
            if (entry.score.eql(score)) return entry.value;
        }
        return null;
    }

    fn scoreWithValue(known: KnownScores, value: KnownValue) ?Ir.Score {
        for (known.entries.items) |entry| {
            if (entry.value.eql(value)) return entry.score;
        }
        return null;
    }

    fn remember(known: *KnownScores, gpa: Allocator, score: Ir.Score, value: KnownValue) Allocator.Error!void {
        known.forget(score);
        if (isTracked(score)) try known.entries.append(gpa, .{ .score = score, .value = value });
    }

    fn forget(known: *KnownScores, score: Ir.Score) void {
        for (known.entries.items, 0..) |entry, index| {
            if (entry.score.eql(score)) {
                _ = known.entries.swapRemove(index);
                return;
            }
        }
    }

    // A call can run this mcfun again (recursion), and a user command can change any score.
    fn forgetWrites(known: *KnownScores, command: Ir.Command) void {
        if (runsOtherCode(command)) return known.entries.clearRetainingCapacity();
        switch (command) {
            .score_set, .score_add, .score_remove, .score_set_if_unset => |set| known.forget(set.score),
            .score_set_param => |set| known.forget(set.score),
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

    fn learn(known: *KnownScores, gpa: Allocator, command: Ir.Command) Allocator.Error!void {
        const learned: ?struct { Ir.Score, KnownValue } = switch (command) {
            .score_set => |set| .{ set.score, .{ .number = set.value } },
            .score_set_param => |set| .{ set.score, .{ .param = set.param } },
            .score_operation => |operation| if (operation.op == .assign)
                if (known.get(operation.source)) |value| .{ operation.target, value } else null
            else
                null,
            else => null,
        };
        known.forgetWrites(command);
        if (learned) |score_and_value| try known.remember(gpa, score_and_value[0], score_and_value[1]);
    }
};

// Removes a set when the score already has the value, copies a parameter from a score that holds it
// (a macro line is parsed again for new arguments), and computes math on known numbers.
fn propagateKnownValues(gpa: Allocator, commands: []const Ir.Command) Allocator.Error![]const Ir.Command {
    var result: std.ArrayList(Ir.Command) = .empty;
    var known: KnownScores = .{};
    defer known.entries.deinit(gpa);

    for (commands) |command| {
        const optimized: ?Ir.Command = switch (command) {
            .score_set => |set| if (isKnown(known, set.score, .{ .number = set.value })) null else command,
            .score_set_param => |set| blk: {
                const value: KnownValue = .{ .param = set.param };
                if (isKnown(known, set.score, value)) break :blk null;
                const copy = known.scoreWithValue(value) orelse break :blk command;
                break :blk .{ .score_operation = .{ .target = set.score, .op = .assign, .source = copy } };
            },
            .score_add, .score_remove, .score_operation => if (foldMath(known, command)) |set| .{ .score_set = set } else command,
            else => command,
        };
        if (optimized) |kept| {
            try known.learn(gpa, kept);
            try result.append(gpa, kept);
        }
    }
    return result.toOwnedSlice(gpa);
}

fn isKnown(known: KnownScores, score: Ir.Score, value: KnownValue) bool {
    const current = known.get(score) orelse return false;
    return current.eql(value);
}

// The same math as Minecraft: ints wrap, and `/=` and `%=` round down. Division by 0 is not computed.
fn foldMath(known: KnownScores, command: Ir.Command) ?Ir.ScoreValue {
    const target, const op: Ir.Operator, const source: KnownValue = switch (command) {
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
fn removeDeadWrites(gpa: Allocator, function_name: []const u8, commands: []const Ir.Command) Allocator.Error![]const Ir.Command {
    var result: std.ArrayList(Ir.Command) = .empty;

    for (commands, 0..) |command, index| {
        const written = switch (command) {
            .score_set, .score_add, .score_remove => |set| set.score,
            .score_set_param => |set| set.score,
            .score_operation => |operation| operation.target,
            .data_to_score => |store| store.score,
            else => null,
        };
        if (written) |score| {
            const rest = commands[index + 1 ..];
            const is_dead = if (isScopedHere(score, function_name)) !isReadLater(rest, score) else isTracked(score) and isSetBeforeUse(rest, score);
            if (is_dead) continue;
        }
        try result.append(gpa, command);
    }
    return result.toOwnedSlice(gpa);
}

// `data get X` followed by `*= N` becomes `data get X N`. Only `*=`: a scale such as 0.01 can round wrongly.
fn scaleDataGets(gpa: Allocator, commands: []const Ir.Command) Allocator.Error![]const Ir.Command {
    var result: std.ArrayList(Ir.Command) = .empty;

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
        try result.append(gpa, command);
    }
    return result.toOwnedSlice(gpa);
}

// A command that computes a temp, followed by a copy of that temp, becomes one command:
// `scoreboard players remove T 1` + `execute store result storage X int 1 run scoreboard players get T`
// → `execute store result storage X int 1 run scoreboard players remove T 1`.
fn inlineStores(gpa: Allocator, function_name: []const u8, commands: []const Ir.Command) Allocator.Error![]const Ir.Command {
    var result: std.ArrayList(Ir.Command) = .empty;

    var index: usize = 0;
    while (index < commands.len) : (index += 1) {
        const command = commands[index];
        if (index + 1 < commands.len) {
            if (definedTemp(command, function_name)) |temp| {
                if (try mergeCopy(gpa, command, commands[index + 1], temp)) |merged| {
                    if (!isReadLater(commands[index + 2 ..], temp)) {
                        try result.append(gpa, merged);
                        index += 1;
                        continue;
                    }
                }
            }
        }
        try result.append(gpa, command);
    }
    return result.toOwnedSlice(gpa);
}

// The temp that a command writes, when the command's result is the temp's new value.
// `/=` and `%=` fail when the source is 0, and then the result is 0, so they need a constant source.
fn definedTemp(command: Ir.Command, function_name: []const u8) ?Ir.Score {
    const score = switch (command) {
        .score_set, .score_add, .score_remove => |set| set.score,
        .score_set_param => |set| set.score,
        .score_operation => |operation| blk: {
            const can_fail = operation.op == .div or operation.op == .mod;
            if (can_fail and !isConstant(operation.source)) return null;
            break :blk operation.target;
        },
        else => return null,
    };
    return if (isScopedHere(score, function_name)) score else null;
}

fn mergeCopy(gpa: Allocator, definition: Ir.Command, copy: Ir.Command, temp: Ir.Score) Allocator.Error!?Ir.Command {
    switch (copy) {
        .score_to_data => |store| {
            if (!store.score.eql(temp)) return null;
            const target: Ir.StoreResult.Target = .{ .data = .{ .path = store.target, .type = store.type } };
            return .{ .store_result = .{ .target = target, .run = try create(gpa, definition) } };
        },
        .return_run => |run| {
            if (run.* != .score_get or !run.score_get.eql(temp)) return null;
            return .{ .return_run = try create(gpa, definition) };
        },
        .score_operation => |operation| {
            if (operation.op != .assign or !operation.source.eql(temp) or operation.target.eql(temp)) return null;
            return .{ .store_result = .{ .target = .{ .score = operation.target }, .run = try create(gpa, definition) } };
        },
        else => return null,
    }
}

// True if a command reads the temp before a command sets it again.
fn isReadLater(commands: []const Ir.Command, temp: Ir.Score) bool {
    for (commands) |command| {
        if (readsScore(command, temp) or callsTempReader(command, temp)) return true;
        // Command text can name a local's fake player: a user command, or a `text(#x)` part in a call's arguments.
        if (temp.owner != null and mentionsInText(command, temp.holder)) return true;
        if (setsScore(command, temp)) return false;
    }
    return false;
}

fn mentionsInText(command: Ir.Command, name: []const u8) bool {
    return switch (command) {
        .raw, .macro => |text| std.mem.indexOf(u8, text, name) != null,
        .function_with => |call| call.arguments == .compound and std.mem.indexOf(u8, call.arguments.compound, name) != null,
        .execute => |execute| for (execute.checks) |check| {
            if (check.score_test == .raw and std.mem.indexOf(u8, check.score_test.raw, name) != null) break true;
        } else mentionsInText(execute.run.*, name),
        .execute_raw => |execute| std.mem.indexOf(u8, execute.subcommands, name) != null or mentionsInText(execute.run.*, name),
        .store_result => |store| mentionsInText(store.run.*, name),
        .return_run => |run| mentionsInText(run.*, name),
        else => false,
    };
}

pub fn readsScore(command: Ir.Command, score: Ir.Score) bool {
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
fn setsScore(command: Ir.Command, score: Ir.Score) bool {
    return switch (command) {
        .score_set => |set| set.score.eql(score),
        .score_set_param => |set| set.score.eql(score),
        .score_operation => |operation| operation.op == .assign and operation.target.eql(score),
        .data_to_score => |store| store.score.eql(score),
        .store_result => |store| store.target == .score and store.target.score.eql(score),
        else => false,
    };
}

// Other functions and user commands can read any global score, and so can the caller after a return.
fn isSetBeforeUse(commands: []const Ir.Command, score: Ir.Score) bool {
    for (commands) |command| {
        if (readsScore(command, score) or runsOtherCode(command) or canReturn(command)) return false;
        if (setsScore(command, score)) return true;
    }
    return false;
}

fn runsOtherCode(command: Ir.Command) bool {
    return switch (command) {
        .function, .function_with, .macro, .raw, .execute_raw => true,
        .execute => |execute| checkedFunction(execute) != null or runsCheckedCode(execute) or runsOtherCode(execute.run.*),
        .store_result => |store| runsOtherCode(store.run.*),
        .return_run => |run| runsOtherCode(run.*),
        else => false,
    };
}

fn canReturn(command: Ir.Command) bool {
    return switch (command) {
        .return_run, .return_value, .return_param => true,
        .execute => |execute| canReturn(execute.run.*),
        .execute_raw => |execute| canReturn(execute.run.*),
        else => false,
    };
}

// Fake players, and `@s`, which is the same entity for the whole function.
// Other selectors can match other entities in each command.
fn isTracked(score: Ir.Score) bool {
    return std.mem.startsWith(u8, score.holder, "#") or std.mem.eql(u8, score.holder, "@s");
}

// A generated function with one command is put where it is called, and the function is removed.
// A command that can return is not moved, because the `return` would then leave the caller.
pub fn inlineSmallFunctions(gpa: Allocator, functions: []const Ir.McFunction) Allocator.Error![]const Ir.McFunction {
    // One pass with the original bodies, so that functions that call each other cannot grow forever.
    const result = try gpa.dupe(Ir.McFunction, functions);
    for (result) |*function| {
        var commands: std.ArrayList(Ir.Command) = .empty;
        for (function.commands) |command| {
            try commands.append(gpa, try inlineCall(gpa, functions, function.name, command) orelse command);
        }
        function.commands = try commands.toOwnedSlice(gpa);
    }
    try inlineTailCalls(gpa, result);

    var used: std.ArrayList(Ir.McFunction) = .empty;
    for (result) |function| {
        if (!isGenerated(function.name) or isCalled(result, function.name)) try used.append(gpa, function);
    }
    for (used.items) |*function| function.commands = try optimizeFunction(gpa, function.name, function.commands);
    return used.toOwnedSlice(gpa);
}

fn inlineCall(gpa: Allocator, functions: []const Ir.McFunction, caller: []const u8, command: Ir.Command) Allocator.Error!?Ir.Command {
    switch (command) {
        .function => |name| return smallBody(functions, caller, name),
        // A generated function gets the arguments of its mcfun, so `$(arg)` means the same in the caller.
        .function_with => |call| return if (call.arguments == .compound) smallBody(functions, caller, call.name) else null,
        .execute => |execute| {
            const run = try inlineCall(gpa, functions, caller, execute.run.*) orelse return null;
            if (run == .execute) {
                const checks = try std.mem.concat(gpa, Ir.Check, &.{ execute.checks, run.execute.checks });
                return .{ .execute = .{ .checks = checks, .run = run.execute.run } };
            }
            return .{ .execute = .{ .checks = execute.checks, .run = try create(gpa, run) } };
        },
        .execute_raw => |execute| {
            const run = try inlineCall(gpa, functions, caller, execute.run.*) orelse return null;
            return .{ .execute_raw = .{ .subcommands = execute.subcommands, .run = try create(gpa, run) } };
        },
        else => return null,
    }
}

fn smallBody(functions: []const Ir.McFunction, caller: []const u8, name: []const u8) ?Ir.Command {
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
fn inlineTailCalls(gpa: Allocator, functions: []Ir.McFunction) Allocator.Error!void {
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
        function.commands = try std.mem.concat(gpa, Ir.Command, &.{ commands[0 .. commands.len - 1], callee.commands });
    }
}

fn callCount(functions: []const Ir.McFunction, name: []const u8) usize {
    var count: usize = 0;
    for (functions) |function| {
        for (function.commands) |command| {
            if (callsFunction(command, name)) count += 1;
        }
    }
    return count;
}

// True when a command uses the return value of `name`: `store result ... run function`, `if function`, or `return run function`.
fn isReturnValueRead(functions: []const Ir.McFunction, name: []const u8) bool {
    for (functions) |function| {
        for (function.commands) |command| {
            if (readsReturnValue(command, name)) return true;
        }
    }
    return false;
}

fn readsReturnValue(command: Ir.Command, name: []const u8) bool {
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
    return std.mem.startsWith(u8, name, "poplar/");
}

fn isCalled(functions: []const Ir.McFunction, name: []const u8) bool {
    for (functions) |function| {
        for (function.commands) |command| {
            if (callsFunction(command, name)) return true;
        }
    }
    return false;
}

fn callsFunction(command: Ir.Command, name: []const u8) bool {
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
fn callsTempReader(command: Ir.Command, temp: Ir.Score) bool {
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
fn runsCheckedCode(execute: Ir.Execute) bool {
    for (execute.checks) |check| {
        if (check.score_test == .raw and std.mem.startsWith(u8, check.score_test.raw, "function ")) return true;
    }
    return false;
}

// The function of an `execute if function ...` check.
fn checkedFunction(execute: Ir.Execute) ?[]const u8 {
    for (execute.checks) |check| {
        if (check.score_test == .function_returns) return check.score_test.function_returns;
    }
    return null;
}

fn readsTempsOf(name: []const u8, temp: Ir.Score) bool {
    // A `macro_<n>` helper holds one user command, so it never reads a temp.
    if (std.mem.startsWith(u8, std.fs.path.basenamePosix(name), "macro_")) return false;

    const function_namespace, const path = Ir.splitName(name);
    // A local knows its mcfun (`combat:heal`). A temp names it in its holder (`#poplar.heal.t0`), in its namespace.
    const owner_namespace, const owner = if (temp.owner) |owner| Ir.splitName(owner) else .{ temp.namespace, temp.holder["#poplar.".len..std.mem.lastIndexOfScalar(u8, temp.holder, '.').?] };
    if (!Ir.optionalEql(function_namespace, owner_namespace)) return false;

    const generated_prefix = "poplar/";
    if (!std.mem.startsWith(u8, path, generated_prefix)) return false;
    const folder_end = std.mem.indexOfScalarPos(u8, path, generated_prefix.len, '/') orelse return false;
    return Ir.isGeneratedFolder(path[generated_prefix.len..folder_end], owner);
}

fn checkReads(check: Ir.Check, score: Ir.Score) bool {
    return switch (check.score_test) {
        .data_test, .function_returns => false,
        // `score @s ...` in a check written by the user can name any score.
        .raw => |raw| std.mem.indexOf(u8, raw, score.holder) != null,
        .matches => |matches| matches.score.eql(score),
        .compare => |compare| compare.left.eql(score) or compare.right.eql(score),
    };
}

// A temp, or a local of this mcfun, is only read by this function and its generated functions. A local can be
// written in a generated body and read by its mcfun after the body returns, so it only counts in the mcfun itself.
fn isScopedHere(score: Ir.Score, function_name: []const u8) bool {
    if (score.owner) |owner| return std.mem.eql(u8, owner, function_name);
    return isTemp(score);
}

// Temps are `#poplar.<mcfun>.t<N>`. They are only read in the function that writes them.
fn isTemp(score: Ir.Score) bool {
    if (score.objective != null or !std.mem.startsWith(u8, score.holder, "#poplar.") or isConstant(score)) return false;
    const name = score.holder[std.mem.lastIndexOfScalar(u8, score.holder, '.').? + 1 ..];
    return name.len > 1 and name[0] == 't' and std.ascii.isDigit(name[1]);
}

// Constants are `#poplar.c<N>`.
fn constantValue(score: Ir.Score) ?i32 {
    const prefix = "#poplar.c";
    if (score.objective != null or !std.mem.startsWith(u8, score.holder, prefix)) return null;
    return std.fmt.parseInt(i32, score.holder[prefix.len..], 10) catch null;
}

fn isConstant(score: Ir.Score) bool {
    return constantValue(score) != null;
}

fn isConstantOne(score: Ir.Score) bool {
    return constantValue(score) == 1;
}

fn create(gpa: Allocator, command: Ir.Command) Allocator.Error!*const Ir.Command {
    const pointer = try gpa.create(Ir.Command);
    pointer.* = command;
    return pointer;
}

test "removes identities and inlines copies of temps" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    const temp: Ir.Score = .{ .holder = "#poplar.f.t0" };
    const other_temp: Ir.Score = .{ .holder = "#poplar.f.t1" };
    const division_temp: Ir.Score = .{ .holder = "#poplar.f.t2" };
    const entity: Ir.Score = .{ .holder = "@p", .objective = "x" };

    const commands = [_]Ir.Command{
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

    const result = try optimizeFunction(gpa, "f", &commands);
    try std.testing.expectEqual(6, result.len);
    try std.testing.expect(result[0] == .store_result);
    try std.testing.expectEqualStrings("n", result[0].store_result.target.data.path.path);
    try std.testing.expect(result[0].store_result.run.* == .score_remove);
    try std.testing.expect(result[1] == .score_set);
    try std.testing.expect(result[4] == .score_operation);
}

test "uses known values, removes dead writes and scales data gets" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    const temp: Ir.Score = .{ .holder = "#poplar.f.t0" };
    const copy_temp: Ir.Score = .{ .holder = "#poplar.f.t1" };
    const after_call_temp: Ir.Score = .{ .holder = "#poplar.f.t2" };
    const global: Ir.Score = .{ .holder = "#global", .objective = "x" };
    const at_most_one: Ir.Check = .{ .negated = false, .score_test = .{ .matches = .{ .score = temp, .min = null, .max = 1 } } };

    const commands = [_]Ir.Command{
        .{ .score_set_param = .{ .score = temp, .param = "n" } },
        .{ .execute = .{ .checks = &.{at_most_one}, .run = &Ir.Command{ .return_value = 1 } } },
        // Removed: the temp already holds `n`.
        .{ .score_set_param = .{ .score = temp, .param = "n" } },
        // Becomes a copy of the temp.
        .{ .score_set_param = .{ .score = copy_temp, .param = "n" } },
        .{ .score_to_data = .{ .target = .inStorage(.args, "n"), .score = copy_temp } },
        // Kept: the call can change every score.
        .{ .function = "other" },
        .{ .score_set_param = .{ .score = after_call_temp, .param = "n" } },
        .{ .score_to_data = .{ .target = .inStorage(.args, "m"), .score = after_call_temp } },
        // `set 7` is removed, and `*= 3` becomes `set 21`.
        .{ .score_set = .{ .score = global, .value = 7 } },
        .{ .score_operation = .{ .target = global, .op = .mul, .source = .{ .holder = "#poplar.c3" } } },
        .{ .function = "other" },
        .{ .data_to_score = .{ .source = .inStorage(.data, "count"), .score = global } },
        .{ .score_operation = .{ .target = global, .op = .mul, .source = .{ .holder = "#poplar.c100" } } },
    };

    const result = try optimizeFunction(gpa, "f", &commands);
    try std.testing.expectEqual(8, result.len);
    try std.testing.expect(result[2].store_result.run.* == .score_operation);
    try std.testing.expect(result[4].store_result.run.* == .score_set_param);
    try std.testing.expectEqual(21, result[5].score_set.value);
    try std.testing.expectEqual(100, result[7].data_to_score.scale);
}
