## A JSON scanner that reads one token at a time and knows its line and column, so an error can point into the
## file. Its states are the ones of the JSON scanner in Poplar 0.5, so errors have the same positions.

import std/[strutils, unicode]

type
  JsonTokenKind* = enum
    jtObjectBegin, jtObjectEnd, jtArrayBegin, jtArrayEnd, jtString, jtNumber, jtTrue, jtFalse, jtNull, jtEndOfDocument

  JsonToken* = object
    kind*: JsonTokenKind
    ## The decoded text of a string, or a number as written.
    text*: string

  JsonSyntaxError* = object of CatchableError

  ScannerState = enum
    ssValue, ssPostValue, ssObjectStart, ssObjectPostComma, ssArrayStart

  JsonScanner* = object
    text: string
    cursor: int
    line: int
    lineStart: int
    ## `{` and `[` that are open.
    stack: seq[char]
    state: ScannerState
    stringIsObjectKey: bool

func initJsonScanner*(text: string): JsonScanner =
  JsonScanner(text: text, line: 1, lineStart: -1)

func line*(scanner: JsonScanner): int = scanner.line

func column*(scanner: JsonScanner): int =
  ## The column after the last byte that was read. It starts at 1.
  scanner.cursor - scanner.lineStart

proc fail(scanner: JsonScanner) {.noreturn.} =
  raise newException(JsonSyntaxError, "invalid JSON")

proc skipWhitespace(scanner: var JsonScanner) =
  while scanner.cursor < scanner.text.len and scanner.text[scanner.cursor] in {' ', '\t', '\r', '\n'}:
    if scanner.text[scanner.cursor] == '\n':
      inc scanner.line
      scanner.lineStart = scanner.cursor
    inc scanner.cursor

proc expectByte(scanner: JsonScanner): char =
  if scanner.cursor >= scanner.text.len: scanner.fail()
  scanner.text[scanner.cursor]

proc take(scanner: var JsonScanner, allowed: set[char]): char =
  ## The byte at the cursor, which must be in `allowed`.
  result = scanner.expectByte()
  if result notin allowed: scanner.fail()
  inc scanner.cursor

proc takeDigits(scanner: var JsonScanner) =
  while scanner.cursor < scanner.text.len and scanner.text[scanner.cursor].isDigit: inc scanner.cursor

proc readHexDigits(scanner: var JsonScanner, allowed: openArray[set[char]]): int =
  for digits in allowed: result = result * 16 + parseHexInt($scanner.take(digits))

proc readEscape(scanner: var JsonScanner, output: var string) =
  case scanner.take({'"', '\\', '/', 'b', 'f', 'n', 'r', 't', 'u'})
  of 'b': output.add '\b'
  of 'f': output.add '\f'
  of 'n': output.add '\n'
  of 'r': output.add '\r'
  of 't': output.add '\t'
  of 'u':
    let unit = scanner.readHexDigits([HexDigits, HexDigits, HexDigits, HexDigits])
    case unit
    of 0xD800 .. 0xDBFF:
      discard scanner.take({'\\'})
      discard scanner.take({'u'})
      let low = scanner.readHexDigits([{'D', 'd'}, {'C' .. 'F', 'c' .. 'f'}, HexDigits, HexDigits])
      output.add $Rune(0x10000 + (unit - 0xD800) shl 10 + (low - 0xDC00))
    of 0xDC00 .. 0xDFFF: scanner.fail()
    else: output.add $Rune(unit)
  else: output.add scanner.text[scanner.cursor - 1]

proc readUtf8(scanner: var JsonScanner, output: var string) =
  ## One UTF-8 character, checked byte by byte for overlong forms, surrogates and code points past U+10FFFF.
  const continuation = {'\x80' .. '\xBF'}
  let lead = scanner.text[scanner.cursor]
  let following = case lead
    of '\xC2' .. '\xDF': @[continuation]
    of '\xE0': @[{'\xA0' .. '\xBF'}, continuation]
    of '\xE1' .. '\xEC', '\xEE' .. '\xEF': @[continuation, continuation]
    of '\xED': @[{'\x80' .. '\x9F'}, continuation]
    of '\xF0': @[{'\x90' .. '\xBF'}, continuation, continuation]
    of '\xF1' .. '\xF3': @[continuation, continuation, continuation]
    of '\xF4': @[{'\x80' .. '\x8F'}, continuation, continuation]
    else: scanner.fail()
  output.add lead
  inc scanner.cursor
  for allowed in following: output.add scanner.take(allowed)

proc readStringToken(scanner: var JsonScanner): JsonToken =
  inc scanner.cursor
  result = JsonToken(kind: jtString)
  while true:
    let ch = scanner.expectByte()
    case ch
    of '\0' .. '\x1F': scanner.fail()
    of '"':
      inc scanner.cursor
      break
    of '\\':
      inc scanner.cursor
      scanner.readEscape(result.text)
    of '\x80' .. '\xFF': scanner.readUtf8(result.text)
    else:
      result.text.add ch
      inc scanner.cursor
  scanner.state = ssPostValue

proc readNumberToken(scanner: var JsonScanner): JsonToken =
  let start = scanner.cursor
  if scanner.text[scanner.cursor] == '-': inc scanner.cursor
  if scanner.take({'0' .. '9'}) != '0': scanner.takeDigits()
  if scanner.cursor < scanner.text.len and scanner.text[scanner.cursor] == '.':
    inc scanner.cursor
    discard scanner.take({'0' .. '9'})
    scanner.takeDigits()
  if scanner.cursor < scanner.text.len and scanner.text[scanner.cursor] in {'e', 'E'}:
    inc scanner.cursor
    if scanner.take({'0' .. '9', '+', '-'}) in {'+', '-'}: discard scanner.take({'0' .. '9'})
    scanner.takeDigits()
  scanner.state = ssPostValue
  JsonToken(kind: jtNumber, text: scanner.text[start ..< scanner.cursor])

proc readLiteral(scanner: var JsonScanner, word: string, kind: JsonTokenKind): JsonToken =
  for letter in word: discard scanner.take({letter})
  scanner.state = ssPostValue
  JsonToken(kind: kind)

proc next*(scanner: var JsonScanner): JsonToken =
  ## The next token, checked against the JSON grammar.
  while true:
    case scanner.state
    of ssValue:
      scanner.skipWhitespace()
      case scanner.expectByte()
      of '{':
        scanner.stack.add '{'
        inc scanner.cursor
        scanner.state = ssObjectStart
        return JsonToken(kind: jtObjectBegin)
      of '[':
        scanner.stack.add '['
        inc scanner.cursor
        scanner.state = ssArrayStart
        return JsonToken(kind: jtArrayBegin)
      of '"': return scanner.readStringToken()
      of '-', '0' .. '9': return scanner.readNumberToken()
      of 't': return scanner.readLiteral("true", jtTrue)
      of 'f': return scanner.readLiteral("false", jtFalse)
      of 'n': return scanner.readLiteral("null", jtNull)
      else: scanner.fail()
    of ssPostValue:
      scanner.skipWhitespace()
      if scanner.cursor >= scanner.text.len and scanner.stack.len == 0: return JsonToken(kind: jtEndOfDocument)
      let ch = scanner.expectByte()
      if scanner.stack.len == 0: scanner.fail()
      if scanner.stringIsObjectKey:
        scanner.stringIsObjectKey = false
        discard scanner.take({':'})
        scanner.state = ssValue
        continue
      case ch
      of '}', ']':
        if scanner.stack.pop() != (if ch == '}': '{' else: '['): scanner.fail()
        inc scanner.cursor
        return JsonToken(kind: if ch == '}': jtObjectEnd else: jtArrayEnd)
      of ',':
        scanner.state = if scanner.stack[^1] == '{': ssObjectPostComma else: ssValue
        inc scanner.cursor
      else: scanner.fail()
    of ssObjectStart, ssObjectPostComma:
      scanner.skipWhitespace()
      if scanner.expectByte() == '}' and scanner.state == ssObjectStart:
        inc scanner.cursor
        discard scanner.stack.pop()
        scanner.state = ssPostValue
        return JsonToken(kind: jtObjectEnd)
      if scanner.expectByte() != '"': scanner.fail()
      scanner.stringIsObjectKey = true
      return scanner.readStringToken()
    of ssArrayStart:
      scanner.skipWhitespace()
      if scanner.expectByte() == ']':
        inc scanner.cursor
        discard scanner.stack.pop()
        scanner.state = ssPostValue
        return JsonToken(kind: jtArrayEnd)
      scanner.state = ssValue
