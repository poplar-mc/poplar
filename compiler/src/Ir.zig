const std = @import("std");

pub const NumberType = @import("Ast.zig").NumberType;

pub const Program = struct {
    functions: []const McFunction,
    load: ?McFunction,
    // The mcfun for the `minecraft:tick` tag.
    tick: ?[]const u8,
};

pub const McFunction = struct {
    name: []const u8,
    commands: []const Command,
};

pub const Command = union(enum) {
    raw: []const u8,
    // The Writer adds the namespace to this mcfun name.
    function: []const u8,
    // Null is the main objective `<ns>`.
    add_objective: ?[]const u8,
    score_set: ScoreValue,
    score_set_param: ScoreParam,
    score_set_if_unset: ScoreValue,
    score_add: ScoreValue,
    score_remove: ScoreValue,
    score_operation: ScoreOperation,
    data_set: DataValue,
    data_set_if_unset: DataValue,
    data_copy: DataCopy,
    // `data modify ... append|prepend|insert <i> value|from ...`
    data_add: DataAdd,
    data_remove: DataPath,
    score_to_data: ScoreToData,
    data_to_score: DataToScore,
    function_with: FunctionWith,
    // The text of a macro line, with `$(key)` in it.
    macro: []const u8,
    // A frame on `<ns>:poplar stack` holds the temps that a recursive call would overwrite.
    frame_push,
    frame_pop,
    stack_clear,
    execute: Execute,
    execute_raw: ExecuteRaw,
    // `execute store result score <score> run <command>`
    store_result: StoreResult,
    score_get: Score,
    data_get: DataPath,
    return_run: *const Command,
    return_value: i32,
    // `return $(param)`, which returns the value of an mcfun parameter.
    return_param: []const u8,
};

pub const StoreResult = struct {
    pub const Target = union(enum) {
        score: Score,
        data: TypedDataPath,
    };

    target: Target,
    run: *const Command,
};

// `data` is the `<ns>:data` storage of `#` variables, where a key is a variable name.
// `args` is `<ns>:poplar args`, where a key is the name of a parameter of the mcfun that is called next.
// `frame` is the top frame of `<ns>:poplar stack`, where a key is the name of a saved temp.
// `macro` is `<ns>:poplar macro`: the parameters and `#` keys for one macro helper. An empty key is the whole compound.
pub const Storage = enum { data, args, frame, macro };

// A place for NBT: a key in one of Poplar's storages, or a path in the NBT of one entity.
pub const DataPath = struct {
    pub const Holder = union(enum) {
        storage: Storage,
        // A selector for one entity.
        entity: []const u8,
    };

    holder: Holder,
    path: []const u8,

    pub fn inStorage(storage: Storage, key: []const u8) DataPath {
        return .{ .holder = .{ .storage = storage }, .path = key };
    }

    pub fn ofEntity(selector: []const u8, path: []const u8) DataPath {
        return .{ .holder = .{ .entity = selector }, .path = path };
    }
};

pub const TypedDataPath = struct {
    path: DataPath,
    type: NumberType = .int,
};

pub const DataValue = struct {
    target: DataPath,
    snbt: []const u8,
};

pub const DataCopy = struct {
    target: DataPath,
    source: DataPath,
};

pub const DataAdd = struct {
    pub const Position = union(enum) { append, prepend, insert: i32 };
    pub const Source = union(enum) { snbt: []const u8, from: DataPath };

    list: DataPath,
    position: Position,
    source: Source,
};

pub const ScoreToData = struct {
    target: DataPath,
    score: Score,
    type: NumberType = .int,
};

// The value is multiplied by the scale before it is stored.
pub const DataToScore = struct {
    source: DataPath,
    score: Score,
    scale: i32 = 1,
};

pub const ScoreParam = struct {
    score: Score,
    param: []const u8,
};

// Calls an mcfun with macro arguments.
pub const FunctionWith = struct {
    pub const Arguments = union(enum) {
        compound: []const u8,
        data_storage,
        args_storage,
        macro_storage,
    };

    name: []const u8,
    arguments: Arguments,
};

// A holder is a fake player (`$hp`, `#poplar.t0`) or a selector (`@s`).
// A null objective is the main objective `<ns>`. Otherwise it is `<ns>.<objective>`.
pub const Score = struct {
    holder: []const u8,
    objective: ?[]const u8 = null,
    // The mcfun of a local variable. Only that mcfun and its generated functions read it. It is not part of `eql`.
    owner: ?[]const u8 = null,

    pub fn eql(a: Score, b: Score) bool {
        const same_objective = if (a.objective) |objective| b.objective != null and std.mem.eql(u8, objective, b.objective.?) else b.objective == null;
        return same_objective and std.mem.eql(u8, a.holder, b.holder);
    }
};

pub const ScoreValue = struct {
    score: Score,
    value: i32,
};

pub const ScoreOperation = struct {
    target: Score,
    op: Operator,
    source: Score,
};

pub const Operator = enum { assign, add, sub, mul, div, mod };

pub const Execute = struct {
    checks: []const Check,
    run: *const Command,
};

// Subcommands written by the user, for example `as @a at @s`.
pub const ExecuteRaw = struct {
    subcommands: []const u8,
    run: *const Command,
};

// A negated check is written as `unless`.
pub const Check = struct {
    negated: bool,
    score_test: ScoreTest,
};

pub const ScoreTest = union(enum) {
    matches: Matches,
    compare: Compare,
    // `if data storage ns:data stats.bonus` passes when the path exists. The path can also be an NBT filter: `{name:"Steve"}`.
    data_test: DataPath,
    // `if function ns:<name>` runs the function and passes when it returns a value that is not 0.
    function_returns: []const u8,
};

pub const Matches = struct {
    score: Score,
    min: ?i32,
    max: ?i32,
};

pub const Compare = struct {
    left: Score,
    op: CompareOp,
    right: Score,
};

pub const CompareOp = enum { lt, le, eq, ge, gt };
