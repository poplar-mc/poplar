import std/unittest
import ../src/[lexer, token]

proc skip(lexer: var Lexer, count: int) =
  for _ in 1..count: discard lexer.nextToken()

proc tags(source: string): seq[TokenTag] =
  var lexer = initLexer(source)
  while true:
    result.add lexer.nextToken().tag
    if result[^1] == tkEof: break

test "lines and indentation give newline, indent and dedent tokens":
  const source = "mcfun f:\n    if #a > 1:\n        /say a\n\n    // note\n    /say b\n" &
                 "mcfun g: /say c"
  check tags(source) ==
    @[tkMcfun, tkIdentifier, tkBlockColon, tkNewline,
      tkIndent, tkIf, tkScoreIdentifier, tkGreater, tkNumber, tkBlockColon, tkNewline,
      tkIndent, tkCommand, tkNewline,
      tkDedent, tkCommand, tkNewline,
      tkDedent, tkMcfun, tkIdentifier, tkBlockColon, tkCommand, tkNewline, tkEof]

test "a line break inside brackets is only whitespace":
  check tags("#x = {a: 1,\n      b: [2,\n  3]}\n/say z") ==
    @[tkScoreIdentifier, tkEql, tkLeftBrace, tkIdentifier, tkColon, tkNumber, tkComma,
      tkIdentifier, tkColon, tkLeftBracket, tkNumber, tkComma, tkNumber, tkRightBracket,
      tkRightBrace, tkNewline, tkCommand, tkNewline, tkEof]

test "a colon starts a block only before a space or the end of the line":
  check tags("if magic:ready() == {a: 1}: /say y") ==
    @[tkIf, tkIdentifier, tkColon, tkIdentifier, tkLeftParen, tkRightParen, tkEqlEql,
      tkLeftBrace, tkIdentifier, tkColon, tkNumber, tkRightBrace, tkBlockColon, tkCommand,
      tkNewline, tkEof]

  var nether = initLexer("execute in minecraft:the_nether: /say x")
  nether.skip(1)
  check nether.nextToken().literal == "in minecraft:the_nether"
  check nether.nextToken().tag == tkBlockColon

  var wrapped = initLexer("execute (as @a[tag=x] at @s):")
  wrapped.skip(1)
  let subcommands = wrapped.nextToken()
  check subcommands.literal == "as @a[tag=x] at @s"
  check subcommands.column == 10

test "a tab or a dedent to no outer level is an error":
  check tkLayoutError in tags("mcfun f:\n\t/say a\n")
  check tags("mcfun f:\n    /say a\n  /say b\n")[7..9] == @[tkLayoutError, tkDedent, tkCommand]

test "reads a Minecraft check in a condition up to 'and', ')' or the block colon":
  var lexer = initLexer("if block ~ ~-1 ~ stone[a=b] and (block ~ ~ ~ minecraft:stone): /say x")
  lexer.skip(1)
  check lexer.nextToken().literal == "block ~ ~-1 ~ stone[a=b]"
  lexer.skip(2)
  check lexer.nextToken().literal == "block ~ ~ ~ minecraft:stone"

  check tags("if block == 1: /say y")[1] == tkIdentifier

test "reads a data file body over many lines":
  var lexer = initLexer("predicate p {\n  \"a\": \"}\\\"{\",\n  \"b\": [1, {}]\n}\nmcfun")
  lexer.skip(2)
  let body = lexer.nextToken()
  check body.tag == tkJsonBody
  check body.literal == "{\n  \"a\": \"}\\\"{\",\n  \"b\": [1, {}]\n}"
  check lexer.nextToken().tag == tkNewline
  let after = lexer.nextToken()
  check after.tag == tkMcfun
  check after.line == 5

  var unclosed = initLexer("recipe r { \"a\": 1")
  unclosed.skip(2)
  check unclosed.nextToken().tag == tkUnclosed

test "reads commands to the end of the line and keeps division":
  var lexer = initLexer("#x = a / b\n/give @s stone{a:[I;1]} 1 // all of it\n")
  lexer.skip(3)
  check lexer.nextToken().tag == tkSlash
  lexer.skip(2)
  let command = lexer.nextToken()
  check command.tag == tkCommand
  check command.literal == "give @s stone{a:[I;1]} 1 // all of it"

test "reads illegal characters as tokens":
  check tags("a \\ \"open") == @[tkIdentifier, tkIllegal, tkUnclosed, tkNewline, tkEof]

test "a string ends at the end of its line":
  var lexer = initLexer("\"a\nb")
  check lexer.nextToken().tag == tkUnclosed
  check lexer.nextToken().tag == tkNewline
  let next = lexer.nextToken()
  check next.literal == "b"
  check next.line == 2

test "reads entity data paths after a selector":
  var lexer = initLexer("@s.$Inventory[{Slot:0b}].count * 2\n@p.$\"a.b\"")
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
