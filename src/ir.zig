const std = @import("std");

/// A function name is `ns:path`, or only `path` in the pack namespace (Poplar's own files and the namespace
/// of `poplar.json`). A score or data path with no namespace is in the pack namespace too.
pub const Program = struct {
    functions: []const McFunction,
    load: ?McFunction,
    /// The functions of the `minecraft:tick` tag, in order.
    tick: []const []const u8 = &.{},
    data_files: []const DataFile = &.{},
};

/// `data/<namespace>/<folder>/<path>.json`, with the JSON as the user wrote it.
pub const DataFile = struct {
    namespace: []const u8,
    folder: []const u8,
    path: []const u8,
    json: []const u8,
};

pub const McFunction = struct {
    name: []const u8,
    commands: []const Command,
};

pub const Command = union(enum) {
    raw: []const u8,
    /// The Writer adds the namespace to this mcfun name.
    function: []const u8,
    add_objective: Objective,
    score_set: ScoreValue,
    score_set_macro_argument: ScoreMacroArgument,
    score_set_if_unset: ScoreValue,
    score_add: ScoreValue,
    score_remove: ScoreValue,
    score_operation: ScoreOperation,
    data_set: DataValue,
    data_set_if_unset: DataValue,
    data_copy: DataCopy,
    data_set_string: DataSetString,
    /// `data modify ... append|prepend|insert <i> value|from ...`
    data_add: DataAdd,
    data_remove: DataPath,
    score_to_data: ScoreToData,
    data_to_score: DataToScore,
    function_with: FunctionWith,
    /// The text of a macro line, with `$(key)` in it.
    macro: []const u8,
    /// A frame on `<ns>:poplar stack` holds the temps that a recursive call would overwrite.
    frame_push,
    frame_pop,
    stack_clear,
    execute: Execute,
    execute_raw: ExecuteRaw,
    /// `execute store result score <score> run <command>`
    store_result: StoreResult,
    score_get: Score,
    data_get: DataPath,
    return_run: *const Command,
    return_value: i32,
    /// `return $(key)`, which returns the value of a macro argument.
    return_macro_argument: []const u8,
};

pub const StoreResult = struct {
    pub const Target = union(enum) {
        score: Score,
        data: DataPath,
    };

    target: Target,
    run: *const Command,
};

/// `data` is the `<ns>:data` storage of `$` variables, where a key is a variable name.
/// `args` is `<ns>:poplar args`, the `with` compound of the mcfun that is called next.
/// `frame` is the top frame of `<ns>:poplar stack`, where a key is the name of a saved temp.
/// `macro` is `<ns>:poplar macro`: the macro arguments and the inserted values for one macro helper. An empty key is the whole compound.
/// `poplar` is the root of `<ns>:poplar`, where the string helpers keep their scratch value.
/// `std` is `<pack>:std`, the `$` variables of the standard library, apart from the pack's own `<pack>:data`.
pub const Storage = enum { data, args, frame, macro, poplar, std };

/// A place for NBT: a key in one of Poplar's storages, or a path in the NBT of one entity.
pub const DataPath = struct {
    pub const Holder = union(enum) {
        storage: Storage,
        /// A selector for one entity.
        entity: []const u8,
    };

    holder: Holder,
    path: []const u8,
    /// The namespace of the `<ns>:data` storage.
    namespace: ?[]const u8 = null,

    pub fn inStorage(storage: Storage, key: []const u8) DataPath {
        return .{ .holder = .{ .storage = storage }, .path = key };
    }

    pub fn ofEntity(selector: []const u8, path: []const u8) DataPath {
        return .{ .holder = .{ .entity = selector }, .path = path };
    }

    /// The same holder and namespace, with another path.
    pub fn withPath(self: DataPath, path: []const u8) DataPath {
        var copy = self;
        copy.path = path;
        return copy;
    }
};

pub const DataValue = struct {
    target: DataPath,
    snbt: []const u8,
};

pub const DataCopy = struct {
    target: DataPath,
    source: DataPath,
};

/// `data modify <target> set string <source> [start] [end]`: a substring, or a number as a string.
pub const DataSetString = struct {
    target: DataPath,
    source: DataPath,
    start: ?i32 = null,
    end: ?i32 = null,
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
};

/// The value is multiplied by the scale before it is stored.
pub const DataToScore = struct {
    source: DataPath,
    score: Score,
    scale: i32 = 1,
};

pub const ScoreMacroArgument = struct {
    score: Score,
    macro_argument: []const u8,
};

pub const DataStorage = struct {
    kind: Storage = .data,
    namespace: ?[]const u8 = null,
};

/// Calls an mcfun with macro arguments.
pub const FunctionWith = struct {
    pub const Arguments = union(enum) {
        compound: []const u8,
        /// `with storage <ns>:data` or `<pack>:std`, where whole `$` variables are read as they are.
        data_storage: DataStorage,
        args_storage,
        macro_storage,
        /// `with storage ns:data player` or `with entity @s SelectedItem`.
        data_path: DataPath,
        /// `with entity @s` or `with block ~ ~ ~`, as written.
        raw: []const u8,
    };

    name: []const u8,
    arguments: Arguments,
};

/// A null name is Poplar's objective `poplar.<ns>`. Otherwise it is `<ns>.<name>`.
pub const Objective = struct {
    namespace: ?[]const u8 = null,
    name: ?[]const u8 = null,
};

/// A holder is a fake player (`#hp`, `#poplar.t0`) or a selector (`@s`).
pub const Score = struct {
    holder: []const u8,
    objective: ?[]const u8 = null,
    /// The objective is `<namespace>` or `<namespace>.<objective>`.
    namespace: ?[]const u8 = null,
    /// The mcfun of a local variable. Only that mcfun and its generated functions read it. It is not part of `eql`.
    owner: ?[]const u8 = null,

    pub fn eql(a: Score, b: Score) bool {
        return optionalEql(a.objective, b.objective) and optionalEql(a.namespace, b.namespace) and std.mem.eql(u8, a.holder, b.holder);
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

/// Subcommands written by the user, for example `as @a at @s`.
pub const ExecuteRaw = struct {
    subcommands: []const u8,
    run: *const Command,
};

/// A negated check is written as `unless`.
pub const Check = struct {
    pub const Test = union(enum) {
        matches: Matches,
        compare: Compare,
        /// `if data storage ns:data stats.bonus` passes when the path exists. The path can also be an NBT filter: `{name:"Steve"}`.
        data_test: DataPath,
        /// `if function ns:<name>` runs the function and passes when it returns a value that is not 0.
        function_returns: []const u8,
        /// A Minecraft check as the user wrote it, such as `block ~ ~-1 ~ stone`.
        raw: []const u8,
    };

    negated: bool,
    condition: Test,
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

/// `combat:poplar/heal/if_0` → `combat` and `poplar/heal/if_0`. A name without `:` is in the pack namespace.
pub fn splitName(name: []const u8) struct { ?[]const u8, []const u8 } {
    const colon = std.mem.indexOfScalar(u8, name, ':') orelse return .{ null, name };
    return .{ name[0..colon], name[colon + 1 ..] };
}

pub fn optionalEql(a: ?[]const u8, b: ?[]const u8) bool {
    if (a == null or b == null) return a == null and b == null;
    return std.mem.eql(u8, a.?, b.?);
}

/// The generated functions of an mcfun go in `poplar/<folder>/`, and its temps are `#poplar.<folder>.t<n>`. The folder
/// is the mcfun's path with `.` for `/` (`std/clamp` → `std.clamp`), because it is also in data keys, which cannot have `/`.
pub fn generatedFolder(arena: std.mem.Allocator, mcfun_path: []const u8) std.mem.Allocator.Error![]const u8 {
    const folder = try arena.dupe(u8, mcfun_path);
    std.mem.replaceScalar(u8, folder, '/', '.');
    return folder;
}

pub fn isGeneratedFolder(folder: []const u8, mcfun_path: []const u8) bool {
    if (folder.len != mcfun_path.len) return false;
    for (folder, mcfun_path) |a, b| {
        if (a != b and !(a == '.' and b == '/')) return false;
    }
    return true;
}
