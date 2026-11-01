/**
 * @file Tree-sitter grammar for Poplar, for syntax highlighting in Gram and Zed.
 */

/// <reference types="tree-sitter-cli/dsl" />
// @ts-check

const PREC = {
  cast: 0,
  or: 1,
  and: 2,
  equality: 3,
  compare: 4,
  sum: 5,
  product: 6,
  unary: 7,
  call: 8,
};

const BINARY_OPERATORS = [
  ['or', PREC.or],
  ['and', PREC.and],
  ['==', PREC.equality],
  ['!=', PREC.equality],
  ['<', PREC.compare],
  ['<=', PREC.compare],
  ['>', PREC.compare],
  ['>=', PREC.compare],
  ['+', PREC.sum],
  ['-', PREC.sum],
  ['*', PREC.product],
  ['/', PREC.product],
  ['%', PREC.product],
];

module.exports = grammar({
  name: 'poplar',

  extras: $ => [/\s/, $.comment],

  word: $ => $.identifier,

  rules: {
    source_file: $ => repeat(choice(
      $.import_declaration,
      $.variable_declaration,
      $.function_definition,
    )),

    import_declaration: $ => seq('import', field('path', $.string), ';'),

    function_definition: $ => seq(
      'mcfun',
      field('name', $.identifier),
      field('parameters', $.parameter_list),
      field('body', $.block),
    ),

    parameter_list: $ => seq('(', commaSep($.parameter), ')'),

    parameter: $ => field('name', $.identifier),

    block: $ => seq('{', repeat($._statement), '}'),

    _statement: $ => choice(
      $.variable_declaration,
      $.assignment,
      $.return_statement,
      $.break_statement,
      $.continue_statement,
      $.if_statement,
      $.while_statement,
      $.for_statement,
      $.execute_statement,
      $.command,
      $.expression_statement,
    ),

    variable_declaration: $ => seq(
      'var', field('name', $._variable),
      '=', field('value', $._expression), ';',
    ),

    assignment: $ => seq(field('target', $._variable), '=', field('value', $._expression), ';'),

    return_statement: $ => seq('return', optional($._expression), ';'),
    break_statement: _ => seq('break', ';'),
    continue_statement: _ => seq('continue', ';'),

    if_statement: $ => seq(
      'if',
      field('condition', $.condition),
      field('consequence', $.block),
      optional(seq('else', field('alternative', choice($.block, $.if_statement)))),
    ),

    while_statement: $ => seq('while', field('condition', $.condition), field('body', $.block)),

    for_statement: $ => seq(
      'for', '(', field('start', $._expression), '..', field('end', $._expression), ')',
      '|', field('capture', $.identifier), '|',
      field('body', $.block),
    ),

    condition: $ => seq('(', $._expression, ')'),

    // `execute (as @a at @s) { ... }`. The subcommands are raw Minecraft text.
    execute_statement: $ => seq(
      'execute', '(',
      field('subcommands', repeat(choice($.insert, $.selector, alias($._subcommand_text, $.command_text)))),
      ')',
      field('body', $.block),
    ),

    // `/give @p diamond {{count}};`. Everything after the name is raw Minecraft text.
    command: $ => seq(
      '/',
      field('name', $.command_name),
      repeat(choice($.insert, $.selector, $.command_text)),
      ';',
    ),

    command_name: _ => /[a-z_]+/,

    command_text: _ => /[^\s;@{]+|\{[^{;\s]*/,

    _subcommand_text: _ => /[^\s;@{()]+/,

    insert: $ => seq('{{', $._expression, '}}'),

    expression_statement: $ => seq($._expression, ';'),

    _variable: $ => choice($.identifier, $.score_variable, $.data_variable, $.entity_score, $.entity_data),

    _expression: $ => choice(
      $._variable,
      $.number,
      $.string,
      $.boolean,
      $.null,
      $.unary_expression,
      $.binary_expression,
      $.call_expression,
      $.parenthesized_expression,
      $.cast_expression,
      $.list_literal,
      $.compound_literal,
      $.selector,
    ),

    list_literal: $ => seq('[', commaSep($._expression), ']'),
    compound_literal: $ => seq('{', commaSep($.compound_entry), '}'),
    compound_entry: $ => seq(field('key', choice($.identifier, $.string)), ':', field('value', $._expression)),

    unary_expression: $ => prec(PREC.unary, seq(
      field('operator', choice('!', '-')),
      field('operand', $._expression),
    )),

    binary_expression: $ => choice(...BINARY_OPERATORS.map(([operator, precedence]) =>
      prec.left(precedence, seq(
        field('left', $._expression),
        // @ts-ignore
        field('operator', operator),
        field('right', $._expression),
      )),
    )),

    call_expression: $ => prec(PREC.call, seq(
      field('function', $.identifier),
      field('arguments', $.argument_list),
    )),

    argument_list: $ => seq('(', commaSep($._expression), ')'),

    parenthesized_expression: $ => seq('(', $._expression, ')'),

    // `#hp + 1 as float`: the NBT type of a value that is stored in data.
    cast_expression: $ => prec.left(PREC.cast, seq(
      field('value', $._expression),
      'as',
      field('type', $.number_type),
    )),

    number_type: _ => choice('byte', 'short', 'int', 'long', 'float', 'double'),

    // `@s.#mana`
    entity_score: $ => seq(field('selector', $.selector), '.', field('score', $.score_variable)),

    // `@s.$Inventory[0].count`: a path in the NBT of an entity.
    entity_data: $ => seq(
      field('selector', $.selector),
      field('path', alias(token.immediate(/\.\$([A-Za-z0-9_.]|\[[^\]\n]*\]|"[^"\n]*")+/), $.data_path)),
    ),

    selector: _ => token(seq('@', /[aeprsn]/, optional(seq('[', /[^\]]*/, ']')))),

    score_variable: _ => /#[A-Za-z_][A-Za-z0-9_]*/,

    // `$stats`, or a path in it: `$stats.inventory[0].count`
    data_variable: _ => /\$[A-Za-z_][A-Za-z0-9_]*(\.[A-Za-z_][A-Za-z0-9_]*|\."[^"\n]*"|\[[^\]\n]*\])*/,

    identifier: _ => /[A-Za-z_][A-Za-z0-9_]*/,

    number: _ => /\d+/,

    string: _ => /"([^"\\\n]|\\.)*"/,

    boolean: _ => choice('true', 'false'),

    null: _ => 'null',

    comment: _ => token(seq('//', /.*/)),
  },
});

/**
 * @param {RuleOrLiteral} rule
 */
function commaSep(rule) {
  return optional(seq(rule, repeat(seq(',', rule))));
}
