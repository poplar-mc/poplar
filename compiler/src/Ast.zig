const Token = @import("Token.zig");

pub const Program = struct {
    // `namespace combat;`, the first statement of every file. Null when it is missing.
    namespace: ?Import,
    imports: []const Import,
    functions: []const Function,
    globals: []const Global,
    data_files: []const DataFile,
};

// `import magic;` or `namespace magic;`: a namespace name and where it is written.
pub const Import = struct {
    name: []const u8,
    line: usize,
    column: usize,
};

pub const Global = struct {
    decl: VarDecl,
    line: usize,
    column: usize,
};

// `predicate isSneaking { json }`: a JSON file in the pack.
pub const DataFile = struct {
    pub const Name = union(enum) {
        // `isSneaking`: the file `is_sneaking`, and a constant with its id.
        identifier: []const u8,
        // `"minecraft:entities/zombie"`: the resource id as written.
        id: []const u8,
    };

    type_word: []const u8,
    name: Name,
    json: []const u8,
    line: usize,
    column: usize,
    json_line: usize,
    json_column: usize,
};

pub const Function = struct {
    name: []const u8,
    params: []const Param,
    body: []const Stmt,
    line: usize,
};

pub const Stmt = struct {
    pub const Kind = union(enum) {
        var_decl: VarDecl,
        assign: Assign,
        @"return": ?*Expr,
        @"break",
        @"continue",
        @"if": If,
        @"for": For,
        @"while": While,
        command: Command,
        execute: Execute,
        expression: *Expr,
    };

    line: usize,
    column: usize,
    kind: Kind,
};

// `entity_data` is the NBT of an entity: `@s.$Health`. The name is the NBT path.
pub const Storage = enum { compile_time, score, data, entity_data };

// The NBT number types of `x as float`.
pub const NumberType = enum { byte, short, int, long, float, double };

pub const Identifier = struct {
    name: []const u8,
    storage: Storage,
    // `magic` in `magic:heal()` or `#magic:mana`. Null means the namespace of the file.
    namespace: ?[]const u8 = null,
    // Only set for an entity score or entity data, for example `@s` in `@s.$mana`.
    selector: ?[]const u8 = null,
};

// A parameter is a macro value: `$(name)` in the lines that use it.
pub const Param = struct {
    name: []const u8,
};

pub const VarDecl = struct {
    target: Identifier,
    value: *Expr,
};

pub const Assign = struct {
    target: Identifier,
    value: *Expr,
};

pub const If = struct {
    condition: *Expr,
    then_body: []const Stmt,
    else_body: ?[]const Stmt,
};

pub const While = struct {
    condition: *Expr,
    body: []const Stmt,
};

pub const For = struct {
    start: *Expr,
    end: *Expr,
    capture: []const u8,
    body: []const Stmt,
};

pub const Execute = struct {
    subcommands: []const CommandPart,
    subcommands_column: usize,
    body: []const Stmt,
};

pub const Command = struct {
    text: []const u8,
    parts: []const CommandPart,
};

// `offset` is where the part starts in the command text.
pub const CommandPart = struct {
    pub const Content = union(enum) {
        text: []const u8,
        insert: *Expr,
    };

    offset: usize,
    content: Content,
};

// An expression and where it starts. An infix, a cast or a call starts at its left side.
pub const Expr = struct {
    line: usize,
    column: usize,
    kind: Kind,

    pub const Kind = union(enum) {
        identifier: Identifier,
        number: i64,
        string: []const u8,
        boolean: bool,
        null,
        prefix: Prefix,
        infix: Infix,
        call: Call,
        cast: Cast,
        list: []const *Expr,
        compound: []const Entry,
        // `@a` on its own, as a value: `actionBar(@a, "hi")`.
        selector: []const u8,
        // `block ~ ~-1 ~ stone` in a condition: the text after `execute if`, with `{{...}}` inserts.
        minecraft_check: []const CommandPart,
    };
};

// One `key: value` of a compound literal.
pub const Entry = struct {
    key: []const u8,
    value: *Expr,
};

// `value as float`
pub const Cast = struct {
    value: *Expr,
    type: NumberType,
};

pub const Prefix = struct {
    op: Token.TokenType,
    operand: *Expr,
};

pub const Infix = struct {
    op: Token.TokenType,
    left: *Expr,
    right: *Expr,
};

pub const Call = struct {
    callee: *Expr,
    args: []const *Expr,
};
