## Changes tokens into an AST with a Pratt parser. A mistake records a diagnostic and raises `ReportedError`, and
## recovery skips to the next statement or declaration. A `{{...}}` insert is parsed by a second parser whose lexer
## starts at the insert's line and column, so errors in it point into the file.

import std/[options, strformat, strutils]
import ast, diagnostic, lexer, token

type
  Precedence = enum
    lowestPrecedence, orPrecedence, andPrecedence, equalsPrecedence, lessGreaterPrecedence,
    sumPrecedence, productPrecedence, prefixPrecedence, callPrecedence

  Parser* = object
    lexer: Lexer
    current, peek: Token
    errors*: seq[Diagnostic]
    endOfInput: string ## What the end of the input is called in a message. An insert has its own.

  Declarations = object
    imports: seq[NamespaceName]
    mcfuns: seq[Mcfun]
    globals: seq[Global]
    dataFiles: seq[DataFile]

func tokenPosition(token: Token): Position = Position(line: token.line, column: token.column)

func describe(parser: Parser, token: Token): string =
  if token.tag == tkEof: parser.endOfInput else: &"'{token.literal}'"

func expectedText(tag: TokenTag): string =
  ## How a message names a token that `expectPeek` wants.
  case tag
  of tkSemicolon: "';'"
  of tkEql: "'='"
  of tkLeftParen: "'('"
  of tkRightParen: "')'"
  of tkLeftBrace: "'{'"
  of tkRightBrace: "'}'"
  of tkRightBracket: "']'"
  of tkColon: "':'"
  of tkDot: "'.'"
  of tkDotDot: "'..'"
  of tkPipe: "'|'"
  of tkIdentifier: "a name"
  of tkScoreIdentifier: "a score name"
  of tkExecuteSubcommands: "'(...)' after 'execute'"
  else: $tag

func addDiagnostic(parser: var Parser, diagnostic: Diagnostic) =
  ## Only the first error on a line is kept. Later ones on that line are usually caused by it.
  if parser.errors.len > 0 and parser.errors[^1].position.get.line == diagnostic.position.get.line: return
  parser.errors.add diagnostic

func addError(parser: var Parser, message: string) =
  parser.addDiagnostic(Diagnostic(position: some(tokenPosition(parser.current)), message: message))

func fail(parser: var Parser, message: string) {.noreturn.} =
  ## Records an error and stops the statement or declaration that is being parsed.
  parser.addError(message)
  raise newException(ReportedError, message)

func nextToken(parser: var Parser) =
  ## Illegal and unclosed tokens are reported here and skipped, so they do not cause more errors later.
  parser.current = parser.peek
  parser.peek = parser.lexer.nextToken()
  while parser.peek.tag in {tkIllegal, tkUnclosed}:
    let literal = parser.peek.literal
    let message =
      if parser.peek.tag == tkIllegal: &"unexpected character '{literal}'"
      elif literal[0] == '"': "unterminated string"
      else: &"missing '{literal}'"
    parser.addDiagnostic(Diagnostic(position: some(tokenPosition(parser.peek)), message: message))
    parser.peek = parser.lexer.nextToken()

func initParser*(lexer: Lexer): Parser =
  result = Parser(lexer: lexer, endOfInput: "end of file")
  result.nextToken()
  result.nextToken()

func currentIs(parser: Parser, tag: TokenTag): bool = parser.current.tag == tag

func peekIs(parser: Parser, tag: TokenTag): bool = parser.peek.tag == tag

func expectPeek(parser: var Parser, tag: TokenTag) =
  if not parser.peekIs(tag): parser.fail(&"expected {expectedText(tag)}, found {parser.describe(parser.peek)}")
  parser.nextToken()

func precedenceOf(tag: TokenTag): Precedence =
  case tag
  of tkOr: orPrecedence
  of tkAnd: andPrecedence
  of tkEqlEql, tkBangEql: equalsPrecedence
  of tkLess, tkLessEql, tkGreater, tkGreaterEql: lessGreaterPrecedence
  of tkPlus, tkMinus: sumPrecedence
  of tkStar, tkSlash, tkPercent: productPrecedence
  of tkLeftParen: callPrecedence
  else: lowestPrecedence

func infixOperator(tag: TokenTag): InfixOperator =
  ## Only the tokens that `precedenceOf` gives a precedence reach this. A `(` is a call.
  case tag
  of tkPlus: ioAdd
  of tkMinus: ioSubtract
  of tkStar: ioMultiply
  of tkSlash: ioDivide
  of tkPercent: ioModulo
  of tkEqlEql: ioEqual
  of tkBangEql: ioNotEqual
  of tkLess: ioLess
  of tkLessEql: ioLessEqual
  of tkGreater: ioGreater
  of tkGreaterEql: ioGreaterEqual
  of tkAnd: ioAnd
  of tkOr: ioOr
  else: raiseAssert "not an infix operator: " & $tag

func splitNamespace(literal: string): (string, Option[string]) =
  ## The lexer keeps `magic:` on a `#` or `$` name: `magic:item.count` → `item.count` in `magic`.
  let colon = literal.find(':')
  if colon < 0: return (literal, none(string))
  var pathStart = literal.find({'[', '"'})
  if pathStart < 0: pathStart = literal.len
  if colon > pathStart: return (literal, none(string))
  (literal[colon + 1 .. ^1], some(literal[0 ..< colon]))

func currentIdentifier(parser: Parser): Option[Identifier] =
  let kind = case parser.current.tag
    of tkIdentifier: ikCompileTime
    of tkScoreIdentifier: ikScore
    of tkDataIdentifier: ikData
    else: return none(Identifier)
  let (name, namespace) = splitNamespace(parser.current.literal)
  some(Identifier(name: name, kind: kind, namespace: namespace))

# ---- expressions

func parseExpression(parser: var Parser, precedence: Precedence): Expression

func parseNamespaceName(parser: var Parser): string =
  ## `bs.math`: identifiers joined by `.`, starting at the current token.
  result = parser.current.literal
  while parser.peekIs(tkDot):
    parser.nextToken()
    parser.expectPeek(tkIdentifier)
    result.add "." & parser.current.literal

func parseQualifiedName(parser: var Parser): Identifier =
  ## `magic:heal` or `bs.math:clamp` as a value or a callee.
  let namespace = parser.parseNamespaceName()
  parser.expectPeek(tkColon)
  parser.expectPeek(tkIdentifier)
  Identifier(name: parser.current.literal, kind: ikCompileTime, namespace: some(namespace))

func parseIdentifier(parser: var Parser): Identifier =
  ## Reads `x`, `#x`, `$x`, an entity score such as `@s.#mana`, or entity data such as `@s.$Health`.
  if parser.currentIs(tkIdentifier) and (parser.peekIs(tkColon) or parser.peekIs(tkDot)):
    return parser.parseQualifiedName()
  if not parser.currentIs(tkSelector): return parser.currentIdentifier().get

  let selector = parser.current.literal
  if parser.peekIs(tkEntityData):
    parser.nextToken()
    return Identifier(name: parser.current.literal, kind: ikEntityData, selector: some(selector))
  parser.expectPeek(tkDot)
  parser.expectPeek(tkScoreIdentifier)

  let (name, namespace) = splitNamespace(parser.current.literal)
  Identifier(name: name, kind: ikScore, selector: some(selector), namespace: namespace)

func decodeString(parser: var Parser, literal: string): string =
  ## Only `\"` and `\\` are allowed, because a string ends up in a one-line command or in SNBT.
  if '\\' notin literal: return literal
  var index = 0
  while index < literal.len:
    if literal[index] != '\\':
      result.add literal[index]
    else:
      inc index
      let escaped = literal[index]
      if escaped notin {'"', '\\'}:
        parser.fail(&"unknown escape '\\{escaped}' in string. Only \\\" and \\\\ are allowed")
      result.add escaped
    inc index

func parseNumber(parser: var Parser, position: Position): Expression =
  let literal = parser.current.literal
  let numberType = case literal[^1].toLowerAscii
    of 'b': some(ntByte)
    of 's': some(ntShort)
    of 'l': some(ntLong)
    of 'f': some(ntFloat)
    of 'd': some(ntDouble)
    else: none(NumberType)
  let number = TypedNumber(text: if numberType.isNone: literal else: literal[0 ..< ^1], numberType: numberType)

  if numberType.isNone and not number.hasFraction:
    try:
      return NumberExpression(position: position, number: parseBiggestInt(literal))
    except ValueError:
      parser.fail(&"number '{literal}' is too large")
  if number.hasFraction and numberType.get(ntDouble) in {ntByte, ntShort, ntLong}:
    parser.fail(&"a {numberType.get} is a whole number, so '{literal}' cannot have a fraction")
  TypedNumberExpression(position: position, typedNumber: number)

func parseInsert(parser: var Parser, source: string, column: int): Expression =
  var insertLexer = initLexer(source)
  insertLexer.line = parser.current.line
  insertLexer.firstLineColumn = column - 1
  var insertParser = initParser(insertLexer)
  insertParser.endOfInput = "the end of '{{...}}'"
  try:
    result = insertParser.parseExpression(lowestPrecedence)
  except ReportedError:
    result = nil

  if result != nil and not insertParser.peekIs(tkEof):
    insertParser.addError(&"unexpected {insertParser.describe(insertParser.peek)} in '{{{{...}}}}'")
  for error in insertParser.errors: parser.addDiagnostic(error)

  if insertParser.errors.len > 0: raise newException(ReportedError, "error in an insert")

func parseCommandParts(parser: var Parser, text: string, textColumn: int): seq[CommandPart] =
  ## Splits command text into plain text and `{{expr}}` inserts. `textColumn` is the column where `text` starts in the
  ## file, so an expression in an insert has its real position.
  var pos = 0
  while true:
    let open = text.find("{{", pos)
    if open < 0: break
    let close = text.find("}}", open + 2)
    if close < 0: parser.fail("missing '}}' in command")

    if open > pos: result.add TextPart(offset: pos, text: text[pos ..< open])
    let expression = parser.parseInsert(text[open + 2 ..< close], textColumn + open + 2)
    result.add InsertPart(offset: open, insert: expression)
    pos = close + 2

  if pos < text.len: result.add TextPart(offset: pos, text: text[pos .. ^1])

func parseListLiteral(parser: var Parser): seq[Expression] =
  ## `[1, 2, 3]`
  while not parser.peekIs(tkRightBracket):
    parser.nextToken()
    result.add parser.parseExpression(lowestPrecedence)
    if not parser.peekIs(tkComma): break
    parser.nextToken()
  parser.expectPeek(tkRightBracket)

func parseCompoundLiteral(parser: var Parser): seq[Entry] =
  ## `{hp: 20, "custom name": "x"}`
  while not parser.peekIs(tkRightBrace):
    parser.nextToken()
    let key = case parser.current.tag
      of tkIdentifier: parser.current.literal
      of tkString: parser.decodeString(parser.current.literal)
      else: parser.fail(&"expected a key, found {parser.describe(parser.current)}")
    parser.expectPeek(tkColon)
    parser.nextToken()
    result.add Entry(key: key, value: parser.parseExpression(lowestPrecedence))
    if not parser.peekIs(tkComma): break
    parser.nextToken()
  parser.expectPeek(tkRightBrace)

func parsePrefix(parser: var Parser): Expression =
  let start = parser.current
  let position = tokenPosition(start)
  case start.tag
  of tkSelector:
    if parser.peekIs(tkDot) or parser.peekIs(tkEntityData):
      result = NameExpression(position: position, identifier: parser.parseIdentifier())
    else:
      result = SelectorExpression(position: position, selector: start.literal)
  of tkIdentifier, tkScoreIdentifier, tkDataIdentifier:
    result = NameExpression(position: position, identifier: parser.parseIdentifier())
  of tkString:
    result = StringExpression(position: position, text: parser.decodeString(start.literal))
  of tkNumber:
    result = parser.parseNumber(position)
  of tkLeftBracket:
    result = ListExpression(position: position, elements: parser.parseListLiteral())
  of tkLeftBrace:
    result = CompoundExpression(position: position, entries: parser.parseCompoundLiteral())
  of tkTrue, tkFalse:
    result = BooleanExpression(position: position, boolean: start.tag == tkTrue)
  of tkNull:
    result = NullExpression(position: position)
  of tkBang, tkMinus:
    let op = if start.tag == tkMinus: poNegate else: poNot
    parser.nextToken()
    let operand = parser.parseExpression(prefixPrecedence)
    result = PrefixExpression(position: position, prefix: Prefix(op: op, operand: operand))
  of tkSelf:
    parser.fail("'self:' is only for ids in commands and checks. In code, a plain name already means this namespace")
  of tkConditionText:
    result = MinecraftCheck(position: position, parts: parser.parseCommandParts(start.literal, start.column))
  of tkMacroKey:
    result = MacroKey(position: position, key: start.literal)
  of tkLeftParen:
    parser.nextToken()
    result = parser.parseExpression(lowestPrecedence)
    parser.expectPeek(tkRightParen)
  else:
    parser.fail(&"expected an expression, found {parser.describe(start)}")

func parseCall(parser: var Parser, callee: Expression): Expression =
  var args: seq[Expression]
  if parser.peekIs(tkRightParen):
    parser.nextToken()
  else:
    parser.nextToken()
    args.add parser.parseExpression(lowestPrecedence)
    while parser.peekIs(tkComma):
      parser.nextToken()
      parser.nextToken()
      args.add parser.parseExpression(lowestPrecedence)
    parser.expectPeek(tkRightParen)

  var with = none(With)
  if parser.peekIs(tkWith):
    parser.nextToken()
    parser.nextToken()
    with =
      if parser.currentIs(tkWithSource): some(WithRaw(raw: parser.current.literal))
      else: some(WithValue(value: parser.parseExpression(callPrecedence)))

  CallExpression(position: callee.position, call: Call(callee: callee, args: args, with: with))

func parseInfix(parser: var Parser, left: Expression): Expression =
  if parser.currentIs(tkLeftParen): return parser.parseCall(left)

  let op = infixOperator(parser.current.tag)
  let precedence = precedenceOf(parser.current.tag)
  parser.nextToken()
  let right = parser.parseExpression(precedence)
  InfixExpression(position: left.position, infix: Infix(op: op, left: left, right: right))

func parseExpression(parser: var Parser, precedence: Precedence): Expression =
  result = parser.parsePrefix()
  while not parser.peekIs(tkSemicolon) and precedence < precedenceOf(parser.peek.tag):
    parser.nextToken()
    result = parser.parseInfix(result)

# ---- statements

func parseStatement(parser: var Parser): Statement

func skipStatement(parser: var Parser) =
  ## Skips the rest of a broken statement, so one mistake gives one error.
  var depth = 0
  while not parser.currentIs(tkEof):
    case parser.current.tag
    of tkLeftBrace: inc depth
    of tkRightBrace: depth = max(depth - 1, 0)
    of tkSemicolon:
      if depth == 0: return
    else: discard
    if depth == 0 and parser.peekIs(tkRightBrace): return
    parser.nextToken()

func parseBlock(parser: var Parser): seq[Statement] =
  parser.nextToken()
  while not parser.currentIs(tkRightBrace):
    if parser.currentIs(tkEof): parser.fail(&"expected '}}', found {parser.endOfInput}")
    try:
      result.add parser.parseStatement()
    except ReportedError:
      parser.skipStatement()
    parser.nextToken()

func parseCondition(parser: var Parser): Expression =
  parser.expectPeek(tkLeftParen)
  parser.nextToken()
  result = parser.parseExpression(lowestPrecedence)
  parser.expectPeek(tkRightParen)

func parseVarDecl(parser: var Parser): VarDecl =
  parser.nextToken()
  let target = parser.currentIdentifier()
  if target.isNone: parser.fail(&"expected a variable name, found {parser.describe(parser.current)}")
  parser.expectPeek(tkEql)
  parser.nextToken()
  let value = parser.parseExpression(lowestPrecedence)
  parser.expectPeek(tkSemicolon)
  VarDecl(target: target.get, value: value)

func parseIf(parser: var Parser): If =
  let condition = parser.parseCondition()
  parser.expectPeek(tkLeftBrace)
  let thenBody = parser.parseBlock()

  var elseBody = none(seq[Statement])
  if parser.peekIs(tkElse):
    parser.nextToken()
    if parser.peekIs(tkIf):
      parser.nextToken()
      elseBody = some(@[parser.parseStatement()])
    else:
      parser.expectPeek(tkLeftBrace)
      elseBody = some(parser.parseBlock())
  If(condition: condition, thenBody: thenBody, elseBody: elseBody)

func parseFor(parser: var Parser): For =
  parser.expectPeek(tkLeftParen)
  parser.nextToken()
  let start = parser.parseExpression(lowestPrecedence)
  parser.expectPeek(tkDotDot)
  parser.nextToken()
  let stop = parser.parseExpression(lowestPrecedence)
  parser.expectPeek(tkRightParen)

  parser.expectPeek(tkPipe)
  parser.expectPeek(tkIdentifier)
  let capture = parser.current.literal
  parser.expectPeek(tkPipe)

  parser.expectPeek(tkLeftBrace)
  For(start: start, stop: stop, capture: capture, body: parser.parseBlock())

func parseStatement(parser: var Parser): Statement =
  let position = tokenPosition(parser.current)
  let isAssignment = (parser.currentIdentifier().isSome and parser.peekIs(tkEql)) or parser.currentIs(tkSelector)
  if isAssignment:
    let target = parser.parseIdentifier()
    parser.expectPeek(tkEql)
    parser.nextToken()
    let value = parser.parseExpression(lowestPrecedence)
    parser.expectPeek(tkSemicolon)
    return AssignStatement(position: position, assign: Assign(target: target, value: value))

  case parser.current.tag
  of tkVar:
    result = VarDeclStatement(position: position, varDecl: parser.parseVarDecl())
  of tkReturn:
    var value: Expression = nil
    if not parser.peekIs(tkSemicolon):
      parser.nextToken()
      value = parser.parseExpression(lowestPrecedence)
    parser.expectPeek(tkSemicolon)
    result = ReturnStatement(position: position, returned: value)
  of tkBreak, tkContinue:
    let isBreak = parser.currentIs(tkBreak)
    parser.expectPeek(tkSemicolon)
    result = if isBreak: BreakStatement(position: position) else: ContinueStatement(position: position)
  of tkIf:
    result = IfStatement(position: position, ifStatement: parser.parseIf())
  of tkFor:
    result = ForStatement(position: position, forLoop: parser.parseFor())
  of tkWhile:
    let condition = parser.parseCondition()
    parser.expectPeek(tkLeftBrace)
    result = WhileStatement(position: position, whileLoop: While(condition: condition, body: parser.parseBlock()))
  of tkCommand:
    let text = parser.current.literal
    let parts = parser.parseCommandParts(text, parser.current.column + 1)
    parser.expectPeek(tkSemicolon)
    result = CommandStatement(position: position, command: Command(text: text, parts: parts))
  of tkExecute:
    parser.expectPeek(tkExecuteSubcommands)
    let column = parser.current.column
    let subcommands = parser.parseCommandParts(parser.current.literal, column)
    parser.expectPeek(tkLeftBrace)
    let execute = Execute(subcommands: subcommands, subcommandsColumn: column, body: parser.parseBlock())
    result = ExecuteStatement(position: position, execute: execute)
  else:
    let expression = parser.parseExpression(lowestPrecedence)
    parser.expectPeek(tkSemicolon)
    result = ExpressionStatement(position: position, expression: expression)

# ---- declarations

func skipToDeclaration(parser: var Parser) =
  ## Skips the rest of a broken declaration, so a statement in its body is not read as a declaration. It stops after
  ## the `;`, `}` or JSON body that ends the declaration, or before a word that starts a new one.
  var depth = if parser.currentIs(tkLeftBrace): 1 else: 0
  while not parser.peekIs(tkEof):
    let startsDeclaration = parser.peek.tag in {tkImport, tkVar, tkMcfun}
    if depth == 0 and startsDeclaration: return

    var endsDeclaration = false
    case parser.peek.tag
    of tkLeftBrace:
      inc depth
    of tkRightBrace:
      depth = max(depth - 1, 0)
      endsDeclaration = depth == 0
    of tkSemicolon, tkJsonBody:
      endsDeclaration = depth == 0
    else: discard
    parser.nextToken()
    if endsDeclaration: return

func parseNamespaceStatement(parser: var Parser): NamespaceName =
  ## `namespace combat;`
  let position = tokenPosition(parser.current)
  parser.expectPeek(tkIdentifier)
  let name = parser.parseNamespaceName()
  parser.expectPeek(tkSemicolon)
  NamespaceName(name: name, position: position)

func parseImport(parser: var Parser): NamespaceName =
  ## `import magic;`
  if parser.peekIs(tkString):
    parser.fail("imports are by namespace: 'import magic;'. A file is part of the pack when it is in src/")
  parser.parseNamespaceStatement()

func parseDataFile(parser: var Parser): DataFile =
  ## `predicate isSneaking { ... }` or `lootTable "minecraft:entities/zombie"
  ## { ... }`. The Compiler checks the type word.
  let typeWord = parser.current.literal
  let position = tokenPosition(parser.current)

  parser.nextToken()
  let name = case parser.current.tag
    of tkIdentifier: IdentifierName(identifier: parser.current.literal)
    of tkString: IdName(id: parser.decodeString(parser.current.literal))
    else: parser.fail(&"expected a name after '{typeWord}', found {parser.describe(parser.current)}")
  if parser.peekIs(tkUnclosed): parser.fail(&"the JSON of {typeWord} '{parser.current.literal}' is not closed")
  if not parser.peekIs(tkJsonBody):
    let found = parser.describe(parser.peek)
    parser.fail(&"expected the JSON of {typeWord} '{parser.current.literal}' (an object or a list), found {found}")
  parser.nextToken()

  DataFile(typeWord: typeWord, name: name, json: parser.current.literal, position: position,
           jsonPosition: tokenPosition(parser.current))

func parseMcfun(parser: var Parser): Mcfun =
  if not parser.currentIs(tkMcfun):
    parser.fail(&"expected 'import', 'var', 'mcfun' or a data file, found {parser.describe(parser.current)}")
  parser.expectPeek(tkIdentifier)
  let name = parser.current.literal
  let position = tokenPosition(parser.current)

  parser.expectPeek(tkLeftParen)
  if not parser.peekIs(tkRightParen):
    parser.nextToken()
    parser.fail("an mcfun has no parameter list. Pass a compound with 'f() with {name: ...}' and read it with " &
                "'$(name)'")
  parser.nextToken()

  parser.expectPeek(tkLeftBrace)
  Mcfun(name: name, body: parser.parseBlock(), position: position)

func parseDeclaration(parser: var Parser, declarations: var Declarations) =
  case parser.current.tag
  of tkNamespace:
    parser.fail("'namespace' must be the first statement of the file")
  of tkImport:
    declarations.imports.add parser.parseImport()
  of tkVar:
    let position = tokenPosition(parser.current)
    declarations.globals.add Global(decl: parser.parseVarDecl(), position: position)
  of tkIdentifier:
    declarations.dataFiles.add parser.parseDataFile()
  else:
    declarations.mcfuns.add parser.parseMcfun()

func parseProgram*(parser: var Parser): Program =
  if parser.currentIs(tkNamespace):
    try:
      result.namespace = some(parser.parseNamespaceStatement())
    except ReportedError:
      discard
    parser.nextToken()

  var declarations: Declarations
  while not parser.currentIs(tkEof):
    try:
      parser.parseDeclaration(declarations)
    except ReportedError:
      parser.skipToDeclaration()
    parser.nextToken()

  result.imports = declarations.imports
  result.mcfuns = declarations.mcfuns
  result.globals = declarations.globals
  result.dataFiles = declarations.dataFiles
