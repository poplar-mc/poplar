## Reads `poplar.json` and gives the defaults. The default pack format comes from mcmeta `version.json`.

import std/[json, math, options, os, sets, strformat, strutils, unicode]
import diagnostic

type
  PackFormat* = object
    major*: int
    minor*: int

  Config* = object
    ## The name of the built pack: `poplar-out/<name>/` and `poplar-out/<name>.zip`.
    zipName*: string
    namespace*: string
    ## A JSON text component, already written as JSON.
    description*: string
    minFormat*, maxFormat*: PackFormat

  ConfigError* = object of CatchableError
    ## Where and why `poplar.json` is invalid. None when the problem has no position in the file.
    position*: Option[Position]

  JsonTokenKind = enum
    jtObjectBegin, jtObjectEnd, jtArrayBegin, jtArrayEnd, jtString, jtNumber, jtTrue, jtFalse, jtNull

  JsonToken = object
    kind: JsonTokenKind
    ## The decoded text of a string, or a number as written.
    text: string

  ScannerState = enum
    ssValue, ssPostValue, ssObjectStart, ssObjectPostComma, ssArrayStart

  FieldReader = object
    ## Reads the fields one token at a time, so that each problem has the line and column of its field: the column
    ## after the last byte that was read.
    text: string
    cursor: int
    line: int
    lineStart: int
    ## `{` and `[` that are open.
    stack: seq[char]
    state: ScannerState
    stringIsObjectKey: bool

const fileName* = "poplar.json"

const oldestFormat* = PackFormat(major: 88)
  ## 1.21.9. Older versions also need the old `pack_format` and `supported_formats` fields in pack.mcmeta.

const versionJson = staticRead("../mcmeta/version.json")

const latestFormat* = static:
  let version = parseJson(versionJson)
  PackFormat(major: version["data_pack_version"].getInt, minor: version["data_pack_version_minor"].getInt)

const minecraftVersion* = static(parseJson(versionJson)["name"].getStr)
  ## The Minecraft version that the command data comes from.

func `<`(a, b: PackFormat): bool = a.major < b.major or (a.major == b.major and a.minor < b.minor)

func isResourceNameChar*(ch: char): bool = ch.isLowerAscii or ch.isDigit or ch in {'_', '.', '-'}

func isValidResourceName*(name: string): bool =
  name.len > 0 and name.allCharsInSet({'a' .. 'z', '0' .. '9', '_', '.', '-'})

proc failWithoutPosition(message: string) {.noreturn.} =
  raise (ref ConfigError)(msg: message, position: none(Position))

# ---- JSON for pack.mcmeta

func jsonString*(text: string): string =
  ## Escapes only `"`, `\` and control characters, and keeps other UTF-8 as it is.
  result = "\""
  for ch in text:
    case ch
    of '"': result.add "\\\""
    of '\\': result.add "\\\\"
    of '\b': result.add "\\b"
    of '\f': result.add "\\f"
    of '\n': result.add "\\n"
    of '\r': result.add "\\r"
    of '\t': result.add "\\t"
    of '\0' .. '\x07', '\v', '\x0E' .. '\x1F': result.add "\\u" & toHex(ord(ch), 4).toLowerAscii
    else: result.add ch
  result.add '"'

func decimalText(number: float): string =
  ## The shortest digits that read back as `number`, without an exponent: `1e-7` is `0.0000001`, `2.0` is `2`.
  var shortest = $number
  if shortest.startsWith('-'):
    result.add '-'
    shortest.removePrefix('-')
  let parts = shortest.split('e')
  var exponent = if parts.len == 2: parseInt(parts[1]) else: 0
  var digits = parts[0]
  let point = digits.find('.')
  if point >= 0:
    digits.delete(point .. point)
    exponent += point
  else:
    exponent += digits.len
  while digits.len > 0 and digits[0] == '0':
    digits.delete(0 .. 0)
    dec exponent
  digits.removeSuffix('0')
  if digits.len == 0:
    result.add '0'
  elif exponent <= 0:
    result.add "0." & '0'.repeat(-exponent) & digits
  elif exponent >= digits.len:
    result.add digits & '0'.repeat(exponent - digits.len)
  else:
    result.add digits[0 ..< exponent] & "." & digits[exponent .. ^1]

func jsonNumber(text: string): string =
  ## A whole number that fits in 64 bits is written as a whole number, and any other finite number as a decimal.
  ## Other numbers stay as written.
  if text != "-0" and not text.contains({'.', 'e', 'E'}):
    try:
      return $parseBiggestInt(text)
    except ValueError:
      return text
  let number = parseFloat(text)
  if number.classify in {fcInf, fcNegInf}: text else: decimalText(number)

# ---- the token reader

proc fail(reader: FieldReader, message: string) {.noreturn.} =
  let position = Position(line: reader.line, column: reader.cursor - reader.lineStart)
  raise (ref ConfigError)(msg: message, position: some(position))

proc skipWhitespace(reader: var FieldReader) =
  while reader.cursor < reader.text.len and reader.text[reader.cursor] in {' ', '\t', '\r', '\n'}:
    if reader.text[reader.cursor] == '\n':
      inc reader.line
      reader.lineStart = reader.cursor
    inc reader.cursor

proc expectByte(reader: FieldReader): char =
  if reader.cursor >= reader.text.len: reader.fail("invalid JSON")
  reader.text[reader.cursor]

proc take(reader: var FieldReader, allowed: set[char]): char =
  ## The byte at the cursor, which must be in `allowed`.
  result = reader.expectByte()
  if result notin allowed: reader.fail("invalid JSON")
  inc reader.cursor

proc takeDigits(reader: var FieldReader) =
  while reader.cursor < reader.text.len and reader.text[reader.cursor].isDigit: inc reader.cursor

proc readHexDigits(reader: var FieldReader, allowed: openArray[set[char]]): int =
  for digits in allowed: result = result * 16 + parseHexInt($reader.take(digits))

proc readEscape(reader: var FieldReader, output: var string) =
  case reader.take({'"', '\\', '/', 'b', 'f', 'n', 'r', 't', 'u'})
  of 'b': output.add '\b'
  of 'f': output.add '\f'
  of 'n': output.add '\n'
  of 'r': output.add '\r'
  of 't': output.add '\t'
  of 'u':
    let unit = reader.readHexDigits([HexDigits, HexDigits, HexDigits, HexDigits])
    case unit
    of 0xD800 .. 0xDBFF:
      discard reader.take({'\\'})
      discard reader.take({'u'})
      let low = reader.readHexDigits([{'D', 'd'}, {'C' .. 'F', 'c' .. 'f'}, HexDigits, HexDigits])
      output.add $Rune(0x10000 + (unit - 0xD800) shl 10 + (low - 0xDC00))
    of 0xDC00 .. 0xDFFF: reader.fail("invalid JSON")
    else: output.add $Rune(unit)
  else: output.add reader.text[reader.cursor - 1]

proc readUtf8(reader: var FieldReader, output: var string) =
  ## One UTF-8 character, checked byte by byte for overlong forms, surrogates and code points past U+10FFFF.
  const continuation = {'\x80' .. '\xBF'}
  let lead = reader.text[reader.cursor]
  let following = case lead
    of '\xC2' .. '\xDF': @[continuation]
    of '\xE0': @[{'\xA0' .. '\xBF'}, continuation]
    of '\xE1' .. '\xEC', '\xEE' .. '\xEF': @[continuation, continuation]
    of '\xED': @[{'\x80' .. '\x9F'}, continuation]
    of '\xF0': @[{'\x90' .. '\xBF'}, continuation, continuation]
    of '\xF1' .. '\xF3': @[continuation, continuation, continuation]
    of '\xF4': @[{'\x80' .. '\x8F'}, continuation, continuation]
    else: reader.fail("invalid JSON")
  output.add lead
  inc reader.cursor
  for allowed in following: output.add reader.take(allowed)

proc readStringToken(reader: var FieldReader): JsonToken =
  inc reader.cursor
  result = JsonToken(kind: jtString)
  while true:
    let ch = reader.expectByte()
    case ch
    of '\0' .. '\x1F': reader.fail("invalid JSON")
    of '"':
      inc reader.cursor
      break
    of '\\':
      inc reader.cursor
      reader.readEscape(result.text)
    of '\x80' .. '\xFF': reader.readUtf8(result.text)
    else:
      result.text.add ch
      inc reader.cursor
  reader.state = ssPostValue

proc readNumberToken(reader: var FieldReader): JsonToken =
  let start = reader.cursor
  if reader.text[reader.cursor] == '-': inc reader.cursor
  if reader.take({'0' .. '9'}) != '0': reader.takeDigits()
  if reader.cursor < reader.text.len and reader.text[reader.cursor] == '.':
    inc reader.cursor
    discard reader.take({'0' .. '9'})
    reader.takeDigits()
  if reader.cursor < reader.text.len and reader.text[reader.cursor] in {'e', 'E'}:
    inc reader.cursor
    if reader.take({'0' .. '9', '+', '-'}) in {'+', '-'}: discard reader.take({'0' .. '9'})
    reader.takeDigits()
  reader.state = ssPostValue
  JsonToken(kind: jtNumber, text: reader.text[start ..< reader.cursor])

proc readLiteral(reader: var FieldReader, word: string, kind: JsonTokenKind): JsonToken =
  for letter in word: discard reader.take({letter})
  reader.state = ssPostValue
  JsonToken(kind: kind)

proc next(reader: var FieldReader): JsonToken =
  ## The next token, checked against the JSON grammar.
  while true:
    case reader.state
    of ssValue:
      reader.skipWhitespace()
      case reader.expectByte()
      of '{':
        reader.stack.add '{'
        inc reader.cursor
        reader.state = ssObjectStart
        return JsonToken(kind: jtObjectBegin)
      of '[':
        reader.stack.add '['
        inc reader.cursor
        reader.state = ssArrayStart
        return JsonToken(kind: jtArrayBegin)
      of '"': return reader.readStringToken()
      of '-', '0' .. '9': return reader.readNumberToken()
      of 't': return reader.readLiteral("true", jtTrue)
      of 'f': return reader.readLiteral("false", jtFalse)
      of 'n': return reader.readLiteral("null", jtNull)
      else: reader.fail("invalid JSON")
    of ssPostValue:
      reader.skipWhitespace()
      let ch = reader.expectByte()
      if reader.stack.len == 0: reader.fail("invalid JSON")
      if reader.stringIsObjectKey:
        reader.stringIsObjectKey = false
        discard reader.take({':'})
        reader.state = ssValue
        continue
      case ch
      of '}', ']':
        if reader.stack.pop() != (if ch == '}': '{' else: '['): reader.fail("invalid JSON")
        inc reader.cursor
        return JsonToken(kind: if ch == '}': jtObjectEnd else: jtArrayEnd)
      of ',':
        reader.state = if reader.stack[^1] == '{': ssObjectPostComma else: ssValue
        inc reader.cursor
      else: reader.fail("invalid JSON")
    of ssObjectStart, ssObjectPostComma:
      reader.skipWhitespace()
      if reader.expectByte() == '}' and reader.state == ssObjectStart:
        inc reader.cursor
        discard reader.stack.pop()
        reader.state = ssPostValue
        return JsonToken(kind: jtObjectEnd)
      if reader.expectByte() != '"': reader.fail("invalid JSON")
      reader.stringIsObjectKey = true
      return reader.readStringToken()
    of ssArrayStart:
      reader.skipWhitespace()
      if reader.expectByte() == ']':
        inc reader.cursor
        discard reader.stack.pop()
        reader.state = ssPostValue
        return JsonToken(kind: jtArrayEnd)
      reader.state = ssValue

proc readString(reader: var FieldReader, field: string): string =
  let token = reader.next()
  if token.kind != jtString: reader.fail(&"\"{field}\" must be a string")
  token.text

proc parseFormatNumber(reader: FieldReader, number, field: string): int =
  try:
    result = parseInt(number)
  except ValueError:
    reader.fail(&"\"{field}\" must contain whole numbers")
  if result notin 0 .. int(high(uint32)): reader.fail(&"\"{field}\" must contain whole numbers")

proc readFormat(reader: var FieldReader, field: string): PackFormat =
  ## `121` or `[121, 0]`, the same as in pack.mcmeta.
  let first = reader.next()
  case first.kind
  of jtNumber: return PackFormat(major: reader.parseFormatNumber(first.text, field))
  of jtArrayBegin: discard
  else: reader.fail(&"\"{field}\" must be a number or [major, minor]")

  var count = 0
  while true:
    let token = reader.next()
    if token.kind == jtArrayEnd: break
    if token.kind != jtNumber: reader.fail(&"\"{field}\" must be [major, minor]")
    let number = reader.parseFormatNumber(token.text, field)
    case count
    of 0: result.major = number
    of 1: result.minor = number
    else: reader.fail(&"\"{field}\" must be [major, minor]")
    inc count
  if count == 0: reader.fail(&"\"{field}\" must be [major, minor]")

proc writeValue(reader: var FieldReader, token: JsonToken, output: var string) =
  case token.kind
  of jtString: output.add jsonString(token.text)
  of jtNumber: output.add jsonNumber(token.text)
  of jtTrue: output.add "true"
  of jtFalse: output.add "false"
  of jtNull: output.add "null"
  of jtObjectBegin:
    output.add '{'
    var keys: HashSet[string]
    var key = reader.next()
    while key.kind != jtObjectEnd:
      if keys.len > 0: output.add ','
      var value = ""
      reader.writeValue(reader.next(), value)
      if keys.containsOrIncl(key.text): reader.fail("invalid JSON")
      output.add jsonString(key.text) & ":" & value
      key = reader.next()
    output.add '}'
  of jtArrayBegin:
    output.add '['
    var element = reader.next()
    var count = 0
    while element.kind != jtArrayEnd:
      if count > 0: output.add ','
      reader.writeValue(element, output)
      element = reader.next()
      inc count
    output.add ']'
  of jtObjectEnd, jtArrayEnd: raiseAssert "the scanner does not give an end token in place of a value"

proc readJson(reader: var FieldReader): string =
  ## Any JSON value, for example a text component. It is written to pack.mcmeta in compact form.
  reader.writeValue(reader.next(), result)

# ---- poplar.json

proc validate(config: Config, hasNamespace: bool): Config =
  if config.zipName.len == 0 or config.zipName.contains({'/', '\\'}):
    failWithoutPosition(&"\"zipName\" '{config.zipName}' must not be empty or contain '/' or '\\'")
  if not isValidResourceName(config.namespace):
    if hasNamespace:
      failWithoutPosition(&"\"namespace\" '{config.namespace}' must only use a-z, 0-9, '_', '.' and '-'")
    failWithoutPosition(&"the project folder name '{config.namespace}' is not a valid namespace. Set \"namespace\" in " &
                        "poplar.json (a-z, 0-9, '_', '.' and '-')")
  if config.minFormat < oldestFormat:
    failWithoutPosition(&"\"minFormat\" must be at least {oldestFormat.major} (Minecraft 1.21.9)")
  if config.maxFormat < config.minFormat:
    failWithoutPosition("\"maxFormat\" must not be less than \"minFormat\"")
  config

proc parseConfig*(json, folderName: string, latest = latestFormat): Config =
  ## Raises `ConfigError` with the message and position of the first problem.
  var reader = FieldReader(text: json, line: 1, lineStart: -1)
  var zipName, namespace, description = none(string)
  var minFormat, maxFormat = none(PackFormat)

  if reader.next().kind != jtObjectBegin: reader.fail("poplar.json must be a JSON object")
  while true:
    let token = reader.next()
    if token.kind == jtObjectEnd: break
    let field = token.text
    case field
    of "$schema": discard reader.readString(field)
    of "zipName": zipName = some(reader.readString(field))
    of "namespace": namespace = some(reader.readString(field))
    of "description": description = some(reader.readJson())
    of "minFormat": minFormat = some(reader.readFormat(field))
    of "maxFormat": maxFormat = some(reader.readFormat(field))
    else: reader.fail(&"unknown field '{field}'. Fields: zipName, namespace, description, minFormat, maxFormat")

  let name = zipName.get(folderName)
  let config = Config(
    zipName: name,
    namespace: namespace.get(folderName),
    description: description.get(jsonString(name)),
    minFormat: minFormat.get(latest),
    maxFormat: maxFormat.get(minFormat.get(latest)),
  )
  config.validate(namespace.isSome)

proc loadConfig*(projectPath, folderName: string): Config =
  ## Reads `poplar.json` from the project folder. A missing file gives the defaults.
  let path = projectPath / fileName
  parseConfig(if fileExists(path): readFile(path) else: "{}", folderName)
