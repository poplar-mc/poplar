## Changes source text into tokens, one at a time, as the parser asks for them. Raw text is one token: a command after
## `/`, `execute (...)` subcommands, and a data file JSON body (a top-level `{` after a name).

import std/[options, strutils]
import token

type
  Lexer* = object
    input: string
    pos, readPos: int
    ch: char
    line*: int
    lineStart, tokenStart: int
    previousTag: Option[TokenTag]
    ## The number of `{` that are open, so that a `{` or `[` at the top level after a name starts a data file body.
    braceDepth: int
    ## The open `(` of an `if` or `while` condition, counted from its first `(`. Zero outside a condition.
    conditionParenDepth: int
    ## Added to the column of each token on the first line: the column where a `{{...}}` insert starts in its file.
    firstLineColumn*: int

const conditionWords = ["biome", "block", "blocks", "data", "dimension", "entity", "function", "items", "loaded",
                        "predicate", "score", "slots", "stopwatch"]
  ## The `execute if` subcommands of Minecraft 26.3. In a condition, `block ~ ~-1 ~ stone` is raw text.

func isLetter(ch: char): bool = ch.isAlphaAscii or ch == '_'

proc readChar(lexer: var Lexer) =
  lexer.ch = if lexer.readPos >= lexer.input.len: '\0' else: lexer.input[lexer.readPos]
  lexer.pos = lexer.readPos
  inc lexer.readPos

proc initLexer*(input: string): Lexer =
  result = Lexer(input: input, line: 1)
  result.readChar()

func peekCharAt(lexer: Lexer, distance: int): char =
  let index = lexer.pos + distance
  if index >= lexer.input.len: '\0' else: lexer.input[index]

func peekChar(lexer: Lexer): char = lexer.peekCharAt(1)

func newToken(lexer: Lexer, tag: TokenTag, literal: string): Token =
  let offset = if lexer.lineStart == 0: lexer.firstLineColumn else: 0
  Token(tag: tag, literal: literal, line: lexer.line, column: lexer.tokenStart - lexer.lineStart + 1 + offset)

func startsStatement(lexer: Lexer): bool =
  ## Division cannot follow these tokens, so a `/` here starts a command.
  lexer.previousTag.isNone or lexer.previousTag.get in {tkSemicolon, tkLeftBrace, tkRightBrace}

proc readInQuote(lexer: var Lexer, quote: var char) =
  ## One character inside a quote: an escape skips the next character, and the quote's own character closes it.
  if lexer.ch == '\\':
    lexer.readChar()
  elif lexer.ch == quote:
    quote = '\0'

proc readBalanced(lexer: var Lexer, stop: char): Option[string] =
  ## Reads up to `stop` outside quotes and brackets, or up to the end of the line. None if a quote is still open.
  let start = lexer.pos
  var depth = 0
  var quote = '\0'
  while lexer.ch notin {'\n', '\0'}:
    if quote != '\0':
      lexer.readInQuote(quote)
    elif lexer.ch == stop and depth == 0:
      break
    else:
      case lexer.ch
      of '"', '\'': quote = lexer.ch
      of '[', '{', '(': inc depth
      of ']', '}', ')': depth = max(depth - 1, 0)
      else: discard
    lexer.readChar()

  if quote != '\0': return none(string)
  some(lexer.input[start ..< lexer.pos])

proc readCommand(lexer: var Lexer): Option[string] =
  ## Reads to the `;` that ends the command. A `;` inside quotes or brackets (NBT, JSON) is part of the text.
  lexer.readChar()
  let text = lexer.readBalanced(';')
  if text.isNone: return text
  some(text.get.strip(leading = false, chars = {' ', '\t', '\r'}))

proc readExecuteSubcommands(lexer: var Lexer): Token =
  ## Reads `as @a at @s` from `execute (as @a at @s)`, to the matching `)`.
  ## The token starts at the text, so its column is the column of the first subcommand.
  lexer.readChar()
  while lexer.ch in {' ', '\t'}: lexer.readChar()
  lexer.tokenStart = lexer.pos

  let text = lexer.readBalanced(')')
  if text.isNone: return lexer.newToken(tkUnclosed, "\"")
  if lexer.ch != ')':
    # Lex the rest of the line again as normal tokens, so a `{` on it still opens the body.
    lexer.readPos = lexer.tokenStart
    lexer.readChar()
    return lexer.newToken(tkUnclosed, ")")

  lexer.readChar()
  lexer.newToken(tkExecuteSubcommands, text.get.strip(leading = false, chars = {' ', '\t', '\r'}))

proc readIdentifier(lexer: var Lexer): string =
  let start = lexer.pos
  while isLetter(lexer.ch) or lexer.ch.isDigit: lexer.readChar()
  lexer.input[start ..< lexer.pos]

proc readMacroKey(lexer: var Lexer): Token =
  ## Reads `$(name)`. The literal is the name.
  lexer.readChar()
  lexer.readChar()
  let name = lexer.readIdentifier()
  if name.len == 0 or lexer.ch != ')': return lexer.newToken(tkIllegal, "$(")
  lexer.readChar()
  lexer.newToken(tkMacroKey, name)

func startsWithSource(lexer: Lexer): bool =
  ## `entity` or `block` right after `with`.
  if lexer.previousTag != some(tkWith): return false
  var stop = lexer.pos
  while stop < lexer.input.len and isLetter(lexer.input[stop]): inc stop
  lexer.input[lexer.pos ..< stop] in ["entity", "block"]

proc readSelector(lexer: var Lexer): Token =
  ## Reads `@s` or `@a[tag=x,limit=1]`.
  let isSelector = lexer.peekChar() in {'a', 'e', 'p', 'r', 's', 'n'} and not isLetter(lexer.peekCharAt(2))
  if not isSelector:
    result = lexer.newToken(tkIllegal, "@")
    lexer.readChar()
    return

  lexer.readChar()
  lexer.readChar()
  if lexer.ch == '[':
    lexer.readChar()
    if lexer.readBalanced(']').isNone: return lexer.newToken(tkUnclosed, "\"")
    if lexer.ch != ']': return lexer.newToken(tkUnclosed, "]")
    lexer.readChar()

  lexer.newToken(tkSelector, lexer.input[lexer.tokenStart ..< lexer.pos])

proc readDataPath(lexer: var Lexer, tag: TokenTag, start: int): Token =
  ## Reads an NBT path: keys, `.`, `[0]`, `[{Slot:0b}]` and `"quoted keys"`. A `.` that is not followed by a key ends
  ## the path, so `$a..` is still a range. `start` is where the token text starts, which can be before the current
  ## character (a `ns:` prefix).
  var depth = 0
  var quote = '\0'
  while lexer.ch notin {'\n', '\0'}:
    if quote != '\0':
      lexer.readInQuote(quote)
      lexer.readChar()
      continue

    if depth == 0 and lexer.ch == '.' and not isLetter(lexer.peekChar()) and lexer.peekChar() != '"': break
    case lexer.ch
    of '"', '\'':
      quote = lexer.ch
    of '[', '{':
      inc depth
    of ']', '}':
      if depth == 0: break
      dec depth
    else:
      if depth == 0 and not isLetter(lexer.ch) and not lexer.ch.isDigit and lexer.ch != '.': break
    lexer.readChar()

  if quote != '\0': return lexer.newToken(tkUnclosed, "\"")
  if depth > 0: return lexer.newToken(tkUnclosed, "]")
  if lexer.pos == start: return lexer.newToken(tkIllegal, ".$")
  lexer.newToken(tag, lexer.input[start ..< lexer.pos])

proc readVariable(lexer: var Lexer): Token =
  ## Reads `#mana` or `$item.count`. `#magic:mana` and `$magic:item.count` name a variable of another namespace.
  let tag = if lexer.ch == '#': tkScoreIdentifier else: tkDataIdentifier
  lexer.readChar()
  let start = lexer.pos
  while isLetter(lexer.ch) or lexer.ch.isDigit or lexer.ch == '.': lexer.readChar()
  if lexer.ch == ':' and isLetter(lexer.peekChar()):
    lexer.readChar()
  else:
    lexer.readPos = start
    lexer.readChar()
  if tag == tkDataIdentifier: return lexer.readDataPath(tkDataIdentifier, start)
  discard lexer.readIdentifier()
  lexer.newToken(tag, lexer.input[start ..< lexer.pos])

proc readEntityDataPath(lexer: var Lexer): Token =
  ## Reads `.$Inventory[0].count` after a selector. The literal is the NBT path without `.$`.
  lexer.readChar()
  lexer.readChar()
  lexer.readDataPath(tkEntityData, lexer.pos)

func startsConditionCheck(lexer: Lexer): bool =
  ## A check starts a condition part (after `(`, `and`, `or` or `!`) with one of the words, then a space and something
  ## that is not an operator. So `block == 1` and `(block)` still read `block` as a name.
  if lexer.conditionParenDepth == 0 or lexer.previousTag.isNone: return false
  if lexer.previousTag.get notin {tkLeftParen, tkAnd, tkOr, tkBang}: return false

  var stop = lexer.pos
  while stop < lexer.input.len and isLetter(lexer.input[stop]): inc stop
  if lexer.input[lexer.pos ..< stop] notin conditionWords: return false
  if stop >= lexer.input.len or lexer.input[stop] != ' ': return false
  while stop < lexer.input.len and lexer.input[stop] == ' ': inc stop
  if stop >= lexer.input.len: return false
  lexer.input[stop] notin "=<>!)+-*/%,;"

func isWordAhead(lexer: Lexer, word: string): bool =
  let start = lexer.pos + 1
  let stop = start + word.len
  if stop > lexer.input.len or lexer.input[start ..< stop] != word: return false
  stop == lexer.input.len or not isLetter(lexer.input[stop]) and not lexer.input[stop].isDigit

proc readConditionText(lexer: var Lexer): string =
  ## Reads to the `)` that closes the condition part, or to an `and` or `or` word, outside brackets and quotes.
  let start = lexer.pos
  var depth = 0
  var quote = '\0'
  while lexer.ch notin {'\n', '\0'}:
    if quote != '\0':
      lexer.readInQuote(quote)
    else:
      case lexer.ch
      of '"', '\'': quote = lexer.ch
      of '[', '{', '(': inc depth
      of ']', '}': depth = max(depth - 1, 0)
      of ')':
        if depth == 0: break
        dec depth
      of ' ':
        if depth == 0 and (lexer.isWordAhead("and") or lexer.isWordAhead("or")): break
      else: discard
    lexer.readChar()
  lexer.input[start ..< lexer.pos].strip(leading = false, chars = {' '})

proc readJsonBody(lexer: var Lexer): Token =
  ## Reads `{ ... }` or `[ ... ]` over many lines, to the bracket that closes the first one. Braces in JSON strings do
  ## not count.
  let start = lexer.pos
  let startLine = lexer.line
  let startColumn = lexer.tokenStart - lexer.lineStart + 1
  var depth = 0
  var quote = '\0'
  while lexer.ch != '\0':
    if lexer.ch == '\n':
      inc lexer.line
      lexer.lineStart = lexer.pos + 1
    if quote != '\0':
      lexer.readInQuote(quote)
    else:
      case lexer.ch
      of '"':
        quote = '"'
      of '{', '[':
        inc depth
      of '}', ']':
        depth = max(depth - 1, 0)
        if depth == 0:
          lexer.readChar()
          return Token(tag: tkJsonBody, literal: lexer.input[start ..< lexer.pos], line: startLine, column: startColumn)
      else: discard
    lexer.readChar()
  Token(tag: tkUnclosed, literal: "}", line: startLine, column: startColumn)

proc readString(lexer: var Lexer): Option[string] =
  let start = lexer.pos
  lexer.readChar()
  while lexer.ch != '"':
    # A string is one line, because it ends up in a one-line command or in SNBT.
    if lexer.ch == '\n' or lexer.pos >= lexer.input.len: return none(string)
    # The escaped character cannot end the string. The parser decodes the escape.
    if lexer.ch == '\\' and lexer.peekChar() != '\n': lexer.readChar()
    lexer.readChar()
  some(lexer.input[start + 1 ..< lexer.pos])

proc readNumber(lexer: var Lexer): string =
  ## Reads an SNBT number: `5`, `0.05`, `0.05f` or `1b`. A `.` needs a digit after it, so `1..5` is still a range.
  let start = lexer.pos
  while lexer.ch.isDigit: lexer.readChar()
  if lexer.ch == '.' and lexer.peekChar().isDigit:
    lexer.readChar()
    while lexer.ch.isDigit: lexer.readChar()

  let next = lexer.peekChar()
  let endsAfter = not isLetter(next) and not next.isDigit
  if lexer.ch in "bBsSlLfFdD" and endsAfter: lexer.readChar()
  lexer.input[start ..< lexer.pos]

proc skipWhitespaceAndComments(lexer: var Lexer) =
  while true:
    case lexer.ch
    of ' ', '\t', '\r':
      lexer.readChar()
    of '\n':
      inc lexer.line
      lexer.readChar()
      lexer.lineStart = lexer.pos
    of '/':
      if lexer.peekChar() != '/': return
      while lexer.ch notin {'\n', '\0'}: lexer.readChar()
    else:
      return

proc readToken(lexer: var Lexer): Token =
  lexer.skipWhitespaceAndComments()
  lexer.tokenStart = lexer.pos

  case lexer.ch
  of '(':
    if lexer.previousTag == some(tkExecute): return lexer.readExecuteSubcommands()
    let opensCondition = lexer.previousTag in [some(tkIf), some(tkWhile)]
    if opensCondition or lexer.conditionParenDepth > 0: inc lexer.conditionParenDepth
    result = lexer.newToken(tkLeftParen, "(")
  of '@':
    return lexer.readSelector()
  of ')':
    lexer.conditionParenDepth = max(lexer.conditionParenDepth - 1, 0)
    result = lexer.newToken(tkRightParen, ")")
  of '{':
    let afterName = lexer.previousTag in [some(tkIdentifier), some(tkString)]
    if lexer.braceDepth == 0 and afterName: return lexer.readJsonBody()
    inc lexer.braceDepth
    result = lexer.newToken(tkLeftBrace, "{")
  of '}':
    lexer.braceDepth = max(lexer.braceDepth - 1, 0)
    result = lexer.newToken(tkRightBrace, "}")
  of ',':
    result = lexer.newToken(tkComma, ",")
  of '.':
    if lexer.previousTag == some(tkSelector) and lexer.peekChar() == '$': return lexer.readEntityDataPath()
    if lexer.peekChar() == '.':
      lexer.readChar()
      result = lexer.newToken(tkDotDot, "..")
    else:
      result = lexer.newToken(tkDot, ".")
  of '|':
    result = lexer.newToken(tkPipe, "|")
  of '[':
    let afterName = lexer.previousTag in [some(tkIdentifier), some(tkString)]
    if lexer.braceDepth == 0 and afterName: return lexer.readJsonBody()
    result = lexer.newToken(tkLeftBracket, "[")
  of ']':
    result = lexer.newToken(tkRightBracket, "]")
  of ':':
    result = lexer.newToken(tkColon, ":")
  of '$', '#':
    if lexer.ch == '$' and lexer.peekChar() == '(': return lexer.readMacroKey()
    if isLetter(lexer.peekChar()): return lexer.readVariable()
    result = lexer.newToken(tkIllegal, $lexer.ch)
  of '-':
    result = lexer.newToken(tkMinus, "-")
  of '+':
    result = lexer.newToken(tkPlus, "+")
  of ';':
    result = lexer.newToken(tkSemicolon, ";")
  of '*':
    result = lexer.newToken(tkStar, "*")
  of '/':
    if lexer.startsStatement():
      let text = lexer.readCommand()
      if text.isNone: return lexer.newToken(tkUnclosed, "\"")
      return lexer.newToken(tkCommand, text.get)
    result = lexer.newToken(tkSlash, "/")
  of '%':
    result = lexer.newToken(tkPercent, "%")
  of '!', '=', '<', '>':
    let isDouble = lexer.peekChar() == '='
    let tag = case lexer.ch
      of '!': (if isDouble: tkBangEql else: tkBang)
      of '=': (if isDouble: tkEqlEql else: tkEql)
      of '<': (if isDouble: tkLessEql else: tkLess)
      else: (if isDouble: tkGreaterEql else: tkGreater)
    if isDouble: lexer.readChar()
    result = lexer.newToken(tag, lexer.input[lexer.tokenStart .. lexer.pos])
  of '"':
    let text = lexer.readString()
    if text.isNone: return lexer.newToken(tkUnclosed, "\"")
    result = lexer.newToken(tkString, text.get)
  else:
    if isLetter(lexer.ch):
      if lexer.startsWithSource():
        let text = lexer.readBalanced(';')
        if text.isNone: return lexer.newToken(tkUnclosed, "\"")
        return lexer.newToken(tkWithSource, text.get.strip(leading = false, chars = {' ', '\t', '\r'}))
      if lexer.startsConditionCheck(): return lexer.newToken(tkConditionText, lexer.readConditionText())
      let literal = lexer.readIdentifier()
      return lexer.newToken(keywordTag(literal), literal)
    if lexer.ch.isDigit: return lexer.newToken(tkNumber, lexer.readNumber())
    if lexer.pos >= lexer.input.len: return lexer.newToken(tkEof, "\0")
    result = lexer.newToken(tkIllegal, $lexer.ch)
  lexer.readChar()

proc nextToken*(lexer: var Lexer): Token =
  result = lexer.readToken()
  lexer.previousTag = some(result.tag)
