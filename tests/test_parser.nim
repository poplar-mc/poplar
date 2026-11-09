import std/[options, unittest]
import ../src/[ast, diagnostic, lexer, parser]

# A test knows which branch each node is, so it reads the fields with `uncheckedAccess` instead of
# matching.

proc parseWithErrors(source: string): (Program, seq[Diagnostic]) =
  var sourceParser = initParser(initLexer(source))
  let program = sourceParser.parseProgram()
  (program, sourceParser.errors)

proc parseValid(source: string): Program =
  let (program, errors) = parseWithErrors(source)
  for error in errors: echo "line ", error.position.get.line, ": ", error.message
  check errors.len == 0
  program

test "parse hello.poplar":
  let program = parseValid("""
// creates hello.mcfunction
mcfun hello:
    say("hello")""")
  check program.mcfuns.len == 1
  let mcfun = program.mcfuns[0]
  check mcfun.name == "hello"
  check mcfun.position.line == 2
  {.cast(uncheckedAccess).}:
    let call = mcfun.body[0].expression.call
    check call.callee.identifier.name == "say"
    check call.args[0].text == "hello"

test "parse calls with a macro compound, a path or raw text, and macro keys":
  let program = parseValid("""
mcfun f:
    g() with {name: $(name)}
    g() with $players[0]
    g() with entity @s""")
  let body = program.mcfuns[0].body
  {.cast(uncheckedAccess).}:
    check body[0].expression.call.with.get.value.entries[0].value.key == "name"
    check body[1].expression.call.with.get.value.identifier.name == "players[0]"
    check body[2].expression.call.with.get.raw == "entity @s"

test "an expression in an insert has its position in the file":
  let program = parseValid("""
mcfun f:
    /say x{{ #a }}
    execute as {{ #b }}: /say y
    if entity {{ #c }}: /say z""")
  let body = program.mcfuns[0].body
  {.cast(uncheckedAccess).}:
    let commandInsert = body[0].command.parts[1].insert
    let executeInsert = body[1].execute.subcommands[1].insert
    let checkInsert = body[2].ifStatement.condition.parts[1].insert
    check commandInsert.position == Position(line: 2, column: 14)
    check executeInsert.position == Position(line: 3, column: 19)
    check checkInsert.position == Position(line: 4, column: 18)

test "SNBT numbers keep their text and type, and a range still works":
  let program = parseValid("""
mcfun f:
    g(0.05f, 0.05, 1b, 5L, 20D, 5)
    for i in 1..5: /say x""")
  {.cast(uncheckedAccess).}:
    let args = program.mcfuns[0].body[0].expression.call.args
    check args[0].typedNumber == TypedNumber(text: "0.05", numberType: some(ntFloat))
    check args[1].typedNumber == TypedNumber(text: "0.05", numberType: none(NumberType))
    check args[2].typedNumber.numberType == some(ntByte)
    check args[3].typedNumber.numberType == some(ntLong)
    check args[4].typedNumber.numberType == some(ntDouble)
    check args[5].number == 5
    check program.mcfuns[0].body[1].forLoop.stop.number == 5

test "parse operator precedence":
  let program = parseValid("mcfun f: 1 + 2 * 3")
  {.cast(uncheckedAccess).}:
    let sum = program.mcfuns[0].body[0].expression.infix
    check sum.op == ioAdd
    check sum.left.number == 1
    let product = sum.right.infix
    check product.op == ioMultiply
    check product.left.number == 2
    check product.right.number == 3

test "parse grouped and prefix expressions":
  let program = parseValid("mcfun f: -(1 + 2) * 3")
  {.cast(uncheckedAccess).}:
    let product = program.mcfuns[0].body[0].expression.infix
    check product.op == ioMultiply
    let negation = product.left.prefix
    check negation.op == poNegate
    check negation.operand.infix.op == ioAdd

test "parse call with args":
  let program = parseValid("""
mcfun f: add(1, x + 2, "three")""")
  {.cast(uncheckedAccess).}:
    let call = program.mcfuns[0].body[0].expression.call
    check call.callee.identifier.name == "add"
    check call.args.len == 3
    check call.args[0].number == 1
    check call.args[1].infix.op == ioAdd
    check call.args[2].text == "three"

test "parse if else":
  let program = parseValid(
    """
mcfun f:
    if x < 1: a()
    elif x == 2: b()
    else: c()""")
  {.cast(uncheckedAccess).}:
    let ifStatement = program.mcfuns[0].body[0].ifStatement
    check ifStatement.condition.infix.op == ioLess
    check ifStatement.thenBody.len == 1
    let elseIf = ifStatement.elseBody.get[0].ifStatement
    check elseIf.condition.infix.op == ioEqual
    check elseIf.elseBody.get.len == 1

test "parse storage sigils":
  let program = parseValid("""
mcfun f:
    var #hp = 1
    var $name = 2""")
  {.cast(uncheckedAccess).}:
    let body = program.mcfuns[0].body
    check body[0].varDecl.target.kind == ikScore
    check body[0].varDecl.target.name == "hp"
    check body[1].varDecl.target.kind == ikData

proc firstError(source: string): Diagnostic =
  let (_, errors) = parseWithErrors(source)
  errors[0]

test "errors say what to change in code with braces and semicolons":
  const semicolon = "remove the ';': a statement ends at the end of its line"
  check firstError("mcfun f:\n    #x = 1;").message == semicolon
  let command = firstError("mcfun f:\n    /say hi;")
  check command.message == semicolon
  check command.position.get == Position(line: 2, column: 12)
  check firstError("mcfun f:\n    if #x > 1 {\n        /say a\n    }").message ==
    "blocks start with ':' and an indented line, not '{'"
  check firstError("mcfun f:\n    if #x: /say a\n    else if #y: /say b").message ==
    "write 'elif' in place of 'else if'"
  check firstError("mcfun f() {}").message == "remove the '()': write 'mcfun f:'"
  check firstError("var count = 0").message == "a variable needs '#' (a score) or '$' (data). " &
    "A build-time constant is 'const count = ...' at the top level of the file"
  check firstError("mcfun f:\n    const x = 1").message ==
    "'const' is only allowed at the top level of a file"

test "a block body is indented, or one simple statement after the colon":
  check firstError("mcfun f:\n    if #x > 1:\n    /say a").message ==
    "expected an indented block after ':'"
  check firstError("mcfun f:\n    if #x: if #y: /say a").message ==
    "'if' cannot follow ':' on the same line. Put it on the next line, indented"

test "errors have a column, also in an insert, and name the end of the insert":
  let (_, errors) = parseWithErrors("""
mcfun f:
    /say {{ 1 + }}
    var #x 5""")
  check errors[0].message == "expected an expression, found the end of '{{...}}'"
  check errors[0].position.get == Position(line: 2, column: 17)
  check errors[1].message == "expected '=', found '5'"
  check errors[1].position.get.column == 9

test "after a broken declaration, its body is skipped and the next declaration is read":
  let (program, errors) = parseWithErrors("""
mcfun broken x:
    var #x = 1
recipe a {}
mcfun f:""")
  check errors.len == 1
  check program.globals.len == 0
  check program.dataFiles.len == 1
  check program.mcfuns.len == 1

test "decodes string escapes":
  let program = parseValid("""
mcfun f: g("a \"b\" \\ c")""")
  {.cast(uncheckedAccess).}:
    check program.mcfuns[0].body[0].expression.call.args[0].text == "a \"b\" \\ c"
  let (_, errors) = parseWithErrors("""
mcfun f: g("bad \q")""")
  check errors[0].message == "unknown escape '\\q' in string. Only \\\" and \\\\ are allowed"

test "reads namespace, imports and names of other namespaces":
  let program = parseValid("""
namespace combat
import bs.math
mcfun f: bs.math:clamp(#magic:mana, $magic:item.count)""")
  check program.namespace.get.name == "combat"
  check program.imports[0].name == "bs.math"
  {.cast(uncheckedAccess).}:
    let call = program.mcfuns[0].body[0].expression.call
    check call.callee.identifier.namespace == some("bs.math")
    check call.callee.identifier.name == "clamp"
    check call.args[0].identifier.namespace == some("magic")
    check call.args[1].identifier.name == "item.count"

  let (_, lateErrors) = parseWithErrors("""
mcfun f:
namespace late
""")
  check lateErrors[0].message == "'namespace' must be the first statement of the file"

