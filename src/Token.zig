const std = @import("std");

const Self = @This();

pub const TokenType = enum {
    left_paren,
    right_paren,
    left_brace,
    right_brace,
    left_bracket,
    right_bracket,
    colon,
    comma,
    dot,
    dot_dot,
    pipe,
    minus,
    plus,
    semicolon,
    slash,
    star,
    percent,
    bang,
    bang_eql,
    eql,
    eql_eql,
    greater,
    greater_eql,
    less,
    less_eql,
    identifier,
    score_identifier,
    data_identifier,
    // The NBT path after `@s.$`, for example `Inventory[0].count`.
    entity_data,
    command,
    selector,
    execute_subcommands,
    // `block ~ ~-1 ~ stone` in an `if` or `while` condition: an `execute if` subcommand as raw text.
    condition_text,
    // The JSON body of a data file, from `{` or `[` to the matching bracket.
    json_body,
    // `$(name)`: a macro argument of the mcfun. The literal is the name.
    macro_key,
    // `entity @s` or `block ~ ~ ~` after `with`: raw text to the `;`.
    with_source,
    string,
    number,
    @"and",
    @"break",
    @"continue",
    @"else",
    execute,
    false,
    mcfun,
    namespace,
    self,
    @"for",
    @"if",
    import,
    null,
    @"or",
    @"return",
    true,
    @"var",
    @"while",
    with,
    eof,
    illegal,
    // A string, `(`, `[` or JSON body that is not closed. The literal is the missing character.
    unclosed,
};

pub const Keywords = std.StaticStringMap(TokenType).initComptime(.{
    .{ "and", .@"and" },
    .{ "break", .@"break" },
    .{ "continue", .@"continue" },
    .{ "else", .@"else" },
    .{ "execute", .execute },
    .{ "false", .false },
    .{ "for", .@"for" },
    .{ "mcfun", .mcfun },
    .{ "namespace", .namespace },
    .{ "self", .self },
    .{ "if", .@"if" },
    .{ "import", .import },
    .{ "null", .null },
    .{ "or", .@"or" },
    .{ "return", .@"return" },
    .{ "var", .@"var" },
    .{ "true", .true },
    .{ "while", .@"while" },
    .{ "with", .with },
});

type: TokenType,
literal: []const u8,
line: usize,
column: usize,

pub fn init(@"type": TokenType, literal: []const u8, line: usize, column: usize) Self {
    return .{
        .type = @"type",
        .literal = literal,
        .line = line,
        .column = column,
    };
}
