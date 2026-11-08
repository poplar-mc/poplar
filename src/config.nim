## Reads `poplar.json` and gives the defaults. The default pack format comes from mcmeta `version.json`.

import std/[json, math, options, os, sets, strformat, strutils]
import diagnostic, json_scanner

type
  PackFormat* = object
    major*: int
    minor*: int

  Config* = object
    zipName*: string
      ## The name of the built pack: `poplar-out/<name>/` and `poplar-out/<name>.zip`.
    namespace*: string
    description*: string ## A JSON text component, already written as JSON.
    minFormat*, maxFormat*: PackFormat

  ConfigError* = object of CatchableError
    position*: Option[Position]
      ## Where and why `poplar.json` is invalid. None when the problem has no position in the file.

  FieldReader = object
    ## Reads the fields one token at a time, so that each problem has the line and column of its field.
    scanner: JsonScanner

const fileName* = "poplar.json"

const oldestFormat* = PackFormat(major: 88)
  ## 1.21.9. Older versions also need the old `pack_format` and `supported_formats` fields in pack.mcmeta.

const versionJson = staticRead("../mcmeta/version.json")

const latestFormat* = static:
  let version = parseJson(versionJson)
  PackFormat(major: version["data_pack_version"].getInt, minor: version["data_pack_version_minor"].getInt)

const minecraftVersion* = static(parseJson(versionJson)["name"].getStr)
  ## The Minecraft version that the command data comes from.

const poplarVersion* = static:
  var found = ""
  for line in staticRead("../poplar.nimble").splitLines:
    if line.startsWith("version"): found = line.split('"')[1]
  found

func `<`(a, b: PackFormat): bool = a.major < b.major or (a.major == b.major and a.minor < b.minor)

func isResourceNameChar*(ch: char): bool = ch.isLowerAscii or ch.isDigit or ch in {'_', '.', '-'}

func isValidResourceName*(name: string): bool =
  name.len > 0 and name.allCharsInSet({'a' .. 'z', '0' .. '9', '_', '.', '-'})

func failWithoutPosition(message: string) {.noreturn.} =
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

# ---- the field reader

func fail(reader: FieldReader, message: string) {.noreturn.} =
  let position = Position(line: reader.scanner.line, column: reader.scanner.column)
  raise (ref ConfigError)(msg: message, position: some(position))

func next(reader: var FieldReader): JsonToken =
  try:
    reader.scanner.next()
  except JsonSyntaxError:
    reader.fail("invalid JSON")


func readString(reader: var FieldReader, field: string): string =
  let token = reader.next()
  if token.kind != jtString: reader.fail(&"\"{field}\" must be a string")
  token.text

func parseFormatNumber(reader: FieldReader, number, field: string): int =
  try:
    result = parseInt(number)
  except ValueError:
    reader.fail(&"\"{field}\" must contain whole numbers")
  if result notin 0 .. int(high(uint32)): reader.fail(&"\"{field}\" must contain whole numbers")

func readFormat(reader: var FieldReader, field: string): PackFormat =
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

func writeValue(reader: var FieldReader, token: JsonToken, output: var string) =
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
  of jtObjectEnd, jtArrayEnd, jtEndOfDocument: raiseAssert "the scanner does not give an end token in place of a value"

func readJson(reader: var FieldReader): string =
  ## Any JSON value, for example a text component. It is written to pack.mcmeta in compact form.
  reader.writeValue(reader.next(), result)

# ---- poplar.json

func validate(config: Config, hasNamespace: bool): Config =
  if config.zipName.len == 0 or config.zipName.contains({'/', '\\'}):
    failWithoutPosition(&"\"zipName\" '{config.zipName}' must not be empty or contain '/' or '\\'")
  if not isValidResourceName(config.namespace):
    if hasNamespace:
      failWithoutPosition(&"\"namespace\" '{config.namespace}' must only use a-z, 0-9, '_', '.' and '-'")
    failWithoutPosition(&"the project folder name '{config.namespace}' is not a valid namespace. Set " &
                        "\"namespace\" in poplar.json (a-z, 0-9, '_', '.' and '-')")
  if config.minFormat < oldestFormat:
    failWithoutPosition(&"\"minFormat\" must be at least {oldestFormat.major} (Minecraft 1.21.9)")
  if config.maxFormat < config.minFormat:
    failWithoutPosition("\"maxFormat\" must not be less than \"minFormat\"")
  config

func parseConfig*(json, folderName: string, latest = latestFormat): Config =
  ## Raises `ConfigError` with the message and position of the first problem.
  var reader = FieldReader(scanner: initJsonScanner(json))
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
