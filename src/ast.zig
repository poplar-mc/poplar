const std = @import("std");
const Position = @import("Diagnostic.zig").Position;

pub const Program = struct {
    /// `namespace combat;`, the first statement of every file. Null when it is missing.
    namespace: ?NamespaceName,
    imports: []const NamespaceName,
    mcfuns: []const Mcfun,
    globals: []const Global,
    data_files: []const DataFile,
};

/// `import magic;` or `namespace magic;`: a namespace name and where it is written.
pub const NamespaceName = struct {
    name: []const u8,
    position: Position,
};

pub const Global = struct {
    decl: VarDecl,
    position: Position,
};

/// `predicate isSneaking { json }`: a JSON file in the pack.
pub const DataFile = struct {
    pub const Name = union(enum) {
        /// `isSneaking`: the file `is_sneaking`, and a constant with its id.
        identifier: []const u8,
        /// `"minecraft:entities/zombie"`: the resource id as written.
        id: []const u8,
    };

    type_word: []const u8,
    name: Name,
    json: []const u8,
    position: Position,
    json_position: Position,
};

pub const Mcfun = struct {
    name: []const u8,
    body: []const Statement,
    /// Where the name is written.
    position: Position,
};

pub const Statement = struct {
    pub const Kind = union(enum) {
        var_decl: VarDecl,
        assign: Assign,
        @"return": ?*Expression,
        @"break",
        @"continue",
        @"if": If,
        @"for": For,
        @"while": While,
        command: Command,
        execute: Execute,
        expression: *Expression,
    };

    position: Position,
    kind: Kind,
};

/// The NBT number types of a number literal: `0.05f`, `1b`.
pub const NumberType = enum {
    byte,
    short,
    int,
    long,
    float,
    double,

    pub fn suffix(self: NumberType) []const u8 {
        return switch (self) {
            .byte => "b",
            .short => "s",
            .int => "",
            .long => "L",
            .float => "f",
            .double => "d",
        };
    }
};

/// `0.05f`, `1b` or `0.05`: an SNBT number as written, so `0.05` stays exact. A null type is a plain decimal, a double.
pub const TypedNumber = struct {
    text: []const u8,
    type: ?NumberType,

    pub fn hasFraction(self: TypedNumber) bool {
        return std.mem.indexOfScalar(u8, self.text, '.') != null;
    }
};

pub const Identifier = struct {
    /// `entity_data` is the NBT of an entity: `@s.$Health`. The name is the NBT path.
    pub const Kind = enum { compile_time, score, data, entity_data };

    name: []const u8,
    kind: Kind,
    /// `magic` in `magic:heal()` or `#magic:mana`. Null means the namespace of the file.
    namespace: ?[]const u8 = null,
    /// Only set for an entity score or entity data, for example `@s` in `@s.$mana`.
    selector: ?[]const u8 = null,
};

pub const VarDecl = struct {
    target: Identifier,
    value: *Expression,
};

pub const Assign = struct {
    target: Identifier,
    value: *Expression,
};

pub const If = struct {
    condition: *Expression,
    then_body: []const Statement,
    else_body: ?[]const Statement,
};

pub const While = struct {
    condition: *Expression,
    body: []const Statement,
};

pub const For = struct {
    start: *Expression,
    end: *Expression,
    capture: []const u8,
    body: []const Statement,
};

pub const Execute = struct {
    subcommands: []const CommandPart,
    subcommands_column: usize,
    body: []const Statement,
};

pub const Command = struct {
    text: []const u8,
    parts: []const CommandPart,
};

/// `offset` is where the part starts in the command text.
pub const CommandPart = struct {
    pub const Content = union(enum) {
        text: []const u8,
        insert: *Expression,
    };

    offset: usize,
    content: Content,
};

/// An expression and where it starts. An infix or a call starts at its left side.
pub const Expression = struct {
    position: Position,
    kind: Kind,

    pub const Kind = union(enum) {
        identifier: Identifier,
        number: i64,
        typed_number: TypedNumber,
        string: []const u8,
        boolean: bool,
        null,
        prefix: Prefix,
        infix: Infix,
        call: Call,
        list: []const *Expression,
        compound: []const Entry,
        /// `@a` on its own, as a value: `actionBar(@a, "hi")`.
        selector: []const u8,
        /// `block ~ ~-1 ~ stone` in a condition: the text after `execute if`, with `{{...}}` inserts.
        minecraft_check: []const CommandPart,
        /// `$(name)`: a macro argument of the mcfun, known when the call starts.
        macro_key: []const u8,
    };
};

/// One `key: value` of a compound literal.
pub const Entry = struct {
    key: []const u8,
    value: *Expression,
};

pub const Prefix = struct {
    pub const Operator = enum { negate, not };

    op: Operator,
    operand: *Expression,
};

pub const Infix = struct {
    pub const Operator = enum {
        add,
        subtract,
        multiply,
        divide,
        modulo,
        equal,
        not_equal,
        less,
        less_equal,
        greater,
        greater_equal,
        @"and",
        @"or",
    };

    op: Operator,
    left: *Expression,
    right: *Expression,
};

pub const Call = struct {
    /// `f() with {name: "Steve"}`, `f() with $player` or `f() with entity @s`.
    pub const With = union(enum) {
        value: *Expression,
        /// `entity @s` or `block ~ ~ ~`, as it is written.
        raw: []const u8,
    };

    callee: *Expression,
    args: []const *Expression,
    with: ?With = null,
};
