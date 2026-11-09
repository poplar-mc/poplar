## The tree that the parser builds from one file.

import std/options
import diagnostic

type
  NumberType* = enum
    ## The NBT number types of a number literal: `0.05f`, `1b`.
    ntByte = "byte", ntShort = "short", ntInt = "int", ntLong = "long", ntFloat = "float",
        ntDouble = "double"

  TypedNumber* = object
    ## `0.05f`, `1b` or `0.05`: an SNBT number as written, so `0.05` stays exact. None is a plain
    ## decimal, a double.
    text*: string
    numberType*: Option[NumberType]

  IdentifierKind* = enum
    ## `ikEntityData` is the NBT of an entity: `@s.$Health`. The name is the NBT path.
    ikCompileTime, ikScore, ikData, ikEntityData

  Identifier* = object
    name*: string
    kind*: IdentifierKind
    namespace*: Option[string]
      ## `magic` in `magic:heal()` or `#magic:mana`. None means the namespace of the file.
    selector*: Option[string]
      ## Only set for an entity score or entity data, for example `@s` in `@s.$mana`.

  PrefixOperator* = enum poNegate, poNot

  InfixOperator* = enum
    ioAdd, ioSubtract, ioMultiply, ioDivide, ioModulo,
    ioEqual, ioNotEqual, ioLess, ioLessEqual, ioGreater, ioGreaterEqual, ioAnd, ioOr

  Expression* = ref object
    ## An expression and where it starts. An infix or a call starts at its left side.
    position*: Position
    case
    of NameExpression: identifier*: Identifier
    of NumberExpression: number*: int64
    of TypedNumberExpression: typedNumber*: TypedNumber
    of StringExpression: text*: string
    of BooleanExpression: boolean*: bool
    of NullExpression: discard
    of PrefixExpression: prefix*: Prefix
    of InfixExpression: infix*: Infix
    of CallExpression: call*: Call
    of ListExpression: elements*: seq[Expression]
    of CompoundExpression: entries*: seq[Entry]
    of SelectorExpression: selector*: string ## `@a` on its own, as a value: `actionBar(@a, "hi")`.
    of MinecraftCheck:
      parts*: seq[CommandPart]
        ## `block ~ ~-1 ~ stone` in a condition: the text
        ## after `execute if`, with `{{...}}` inserts.
    of MacroKey:
      key*: string ## `$(name)`: a macro argument of the mcfun, known when the call starts.

  Entry* = object
    ## One `key: value` of a compound literal.
    key*: string
    value*: Expression

  Prefix* = object
    op*: PrefixOperator
    operand*: Expression

  Infix* = object
    op*: InfixOperator
    left*, right*: Expression

  With* = object
    ## `f() with {name: "Steve"}`, `f() with $player` or `f() with entity @s`.
    case
    of WithValue: value*: Expression
    of WithRaw: raw*: string ## `entity @s` or `block ~ ~ ~`, as it is written.

  Call* = object
    callee*: Expression
    args*: seq[Expression]
    with*: Option[With]

  CommandPart* = object
    offset*: int ## Where the part starts in the command text.
    case
    of TextPart: text*: string
    of InsertPart: insert*: Expression

  VarDecl* = object
    target*: Identifier
    value*: Expression

  Assign* = object
    target*: Identifier
    value*: Expression

  If* = object
    condition*: Expression
    thenBody*: seq[Statement]
    elseBody*: Option[seq[Statement]]

  While* = object
    condition*: Expression
    body*: seq[Statement]

  For* = object
    start*, stop*: Expression
    capture*: string
    body*: seq[Statement]

  Execute* = object
    subcommands*: seq[CommandPart]
    subcommandsColumn*: int
    body*: seq[Statement]

  Command* = object
    text*: string
    parts*: seq[CommandPart]

  Statement* = ref object
    position*: Position
    case
    of VarDeclStatement: varDecl*: VarDecl
    of AssignStatement: assign*: Assign
    of ReturnStatement: returned*: Expression ## Nil for a `return` with no value.
    of BreakStatement, ContinueStatement: discard
    of IfStatement: ifStatement*: If
    of ForStatement: forLoop*: For
    of WhileStatement: whileLoop*: While
    of CommandStatement: command*: Command
    of ExecuteStatement: execute*: Execute
    of ExpressionStatement: expression*: Expression

  NamespaceName* = object
    ## `import magic` or `namespace magic`: a namespace name and where it is written.
    name*: string
    position*: Position

  Global* = object
    decl*: VarDecl
    position*: Position

  Constant* = object
    ## `const maxMana = 100`: a build-time value for the mcfuns of its file.
    name*: string
    value*: Expression
    position*: Position

  DataFileName* = object
    ## `isSneaking` is the file `is_sneaking`, which Minecraft text names as `self:isSneaking`.
    ## `"minecraft:entities/zombie"` is the resource id as written.
    case
    of IdentifierName: identifier*: string
    of IdName: id*: string

  DataFile* = object
    ## `predicate isSneaking { json }`: a JSON file in the pack.
    typeWord*: string
    name*: DataFileName
    json*: string
    position*: Position
    jsonPosition*: Position

  Mcfun* = object
    name*: string
    body*: seq[Statement]
    position*: Position ## Where the name is written.

  Program* = object
    namespace*: Option[NamespaceName]
      ## `namespace combat`, the first statement of every file. None when it is missing.
    imports*: seq[NamespaceName]
    mcfuns*: seq[Mcfun]
    globals*: seq[Global]
    constants*: seq[Constant]
    dataFiles*: seq[DataFile]

func suffix*(numberType: NumberType): string =
  case numberType
  of ntByte: "b"
  of ntShort: "s"
  of ntInt: ""
  of ntLong: "L"
  of ntFloat: "f"
  of ntDouble: "d"

func hasFraction*(number: TypedNumber): bool = '.' in number.text
