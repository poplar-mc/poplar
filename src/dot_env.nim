## A `.env` file: `KEY=VALUE` lines, `#` comments, an optional `export ` and optional quotes around the value. There
## is no variable expansion and no multi-line value.

import std/[os, strutils]

const fileName* = ".env"

type
  LookupKind* = enum
    lkValue, lkMissing, lkInvalidLine

  Lookup* = object
    kind*: LookupKind
    value*: string
    ## The 1-based number of a line that is not `KEY=VALUE`.
    line*: int

func unquote(value: string): string =
  if value.len >= 2 and value[0] in {'"', '\''} and value[^1] == value[0]: value[1 ..< value.len - 1] else: value

func find*(text, key: string): Lookup =
  result = Lookup(kind: lkMissing)
  let lines = text.split('\n')
  for index, rawLine in lines:
    var line = rawLine.strip(chars = {' ', '\t', '\r'})
    if line.len == 0 or line[0] == '#': continue
    line.removePrefix("export ")

    let equals = line.find('=')
    if equals < 0: return Lookup(kind: lkInvalidLine, line: index + 1)
    let lineKey = line[0 ..< equals].strip(chars = {' ', '\t'})
    if lineKey.len == 0: return Lookup(kind: lkInvalidLine, line: index + 1)
    if lineKey == key: result = Lookup(kind: lkValue, value: unquote(line[equals + 1 .. ^1].strip(chars = {' ', '\t'})))

proc read*(projectPath, key: string): Lookup =
  ## The value of `key` in the `.env` file of the project folder. The last line with the key wins.
  let path = projectPath / fileName
  if not fileExists(path): return Lookup(kind: lkMissing)
  find(readFile(path), key)
