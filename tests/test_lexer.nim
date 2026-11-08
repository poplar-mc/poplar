import std/unittest
import ../src/[lexer, token]

proc skip(lexer: var Lexer, count: int) =
  for _ in 1 .. count: discard lexer.nextToken()

test "reads a Minecraft check in a condition up to 'and'":
  var lexer = initLexer("if (block ~ ~-1 ~ stone[a=b] and #a > 1) {} if (block == 1)")
  check lexer.nextToken().tag == tkIf
  check lexer.nextToken().tag == tkLeftParen
  let condition = lexer.nextToken()
  check condition.tag == tkConditionText
  check condition.literal == "block ~ ~-1 ~ stone[a=b]"
  check lexer.nextToken().tag == tkAnd
  lexer.skip(8)
  check lexer.nextToken().tag == tkIdentifier

test "reads a data file body over many lines":
  var lexer = initLexer("predicate p {\n  \"a\": \"}\\\"{\",\n  \"b\": [1, {}]\n}\nmcfun")
  check lexer.nextToken().tag == tkIdentifier
  check lexer.nextToken().tag == tkIdentifier
  let body = lexer.nextToken()
  check body.tag == tkJsonBody
  check body.literal == "{\n  \"a\": \"}\\\"{\",\n  \"b\": [1, {}]\n}"
  let after = lexer.nextToken()
  check after.tag == tkMcfun
  check after.line == 5

  var unclosed = initLexer("recipe r { \"a\": 1")
  unclosed.skip(2)
  check unclosed.nextToken().tag == tkUnclosed

test "skips comments":
  var lexer = initLexer("// first\nvar // second\n")
  check lexer.nextToken().tag == tkVar
  check lexer.nextToken().tag == tkEof

test "reads commands and keeps division":
  var lexer = initLexer("x = a / b; /give @s stone{a:[I;1]} 1;")
  lexer.skip(3)
  check lexer.nextToken().tag == tkSlash
  lexer.skip(1)
  check lexer.nextToken().tag == tkSemicolon
  let command = lexer.nextToken()
  check command.tag == tkCommand
  check command.literal == "give @s stone{a:[I;1]} 1"
  check lexer.nextToken().tag == tkSemicolon

test "reads illegal characters as tokens":
  var lexer = initLexer("a \\ \"open")
  lexer.skip(1)
  check lexer.nextToken().literal == "\\"
  check lexer.nextToken().tag == tkUnclosed
  check lexer.nextToken().tag == tkEof

test "a string ends at the end of its line":
  var lexer = initLexer("\"a\nb")
  check lexer.nextToken().tag == tkUnclosed
  let next = lexer.nextToken()
  check next.literal == "b"
  check next.line == 2

test "reads entity data paths after a selector":
  var lexer = initLexer("@s.$Inventory[{Slot:0b}].count * 2; @p.$\"a.b\"")
  check lexer.nextToken().tag == tkSelector
  let path = lexer.nextToken()
  check path.tag == tkEntityData
  check path.literal == "Inventory[{Slot:0b}].count"
  check lexer.nextToken().tag == tkStar
  lexer.skip(3)
  check lexer.nextToken().literal == "\"a.b\""

  var data = initLexer("$stats.inventory[0].count + $a..")
  check data.nextToken().literal == "stats.inventory[0].count"
  data.skip(1)
  check data.nextToken().literal == "a"
  check data.nextToken().tag == tkDotDot
