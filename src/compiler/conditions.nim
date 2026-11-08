# `if` and `while` conditions: comparisons, data tests and Minecraft checks, in OR-of-ANDs form. Part of
# compiler.nim.

type Operand = object
  case
  of NumberOperand: number: int64
  of ScoreOperand: score: Score

func constantOf(condition: Condition): Option[bool] =
  case condition
  of ConstantCondition(isTrue): some(isTrue)
  else: none(bool)

func clausesOf(condition: Condition): seq[seq[Check]] =
  case condition
  of ClausesCondition(clauses): clauses
  else: @[]

func singleCheck(check: Check): Condition =
  ClausesCondition(clauses: @[@[check]])

func combineAnd(left, right: Condition): Condition =
  let (leftConstant, rightConstant) = (constantOf(left), constantOf(right))
  if leftConstant.isSome: return (if leftConstant.get: right else: left)
  if rightConstant.isSome: return (if rightConstant.get: left else: right)

  var clauses: seq[seq[Check]]
  for leftChecks in clausesOf(left):
    for rightChecks in clausesOf(right): clauses.add leftChecks & rightChecks
  ClausesCondition(clauses: clauses)

func combineOr(left, right: Condition): Condition =
  let (leftConstant, rightConstant) = (constantOf(left), constantOf(right))
  if leftConstant.isSome: return (if leftConstant.get: left else: right)
  if rightConstant.isSome: return (if rightConstant.get: right else: left)
  ClausesCondition(clauses: clausesOf(left) & clausesOf(right))

func compareOperator(op: InfixOperator): CompareOp =
  case op
  of ioLess: coLt
  of ioLessEqual: coLe
  of ioGreater: coGt
  of ioGreaterEqual: coGe
  of ioEqual, ioNotEqual: coEq
  else: raiseAssert "not a comparison"

func flipCompare(op: CompareOp): CompareOp =
  case op
  of coLt: coGt
  of coLe: coGe
  of coEq: coEq
  of coGe: coLe
  of coGt: coLt

func matchesCondition(score: Score, op: CompareOp, number: int64, negated: bool): Condition =
  var min, max = none(int64)
  case op
  of coLt: max = some(if number == low(int64): number else: number - 1)
  of coLe: max = some(number)
  of coEq: (min, max) = (some(number), some(number))
  of coGe: min = some(number)
  of coGt: min = some(if number == high(int64): number else: number + 1)

  let isNeverTrue = (max.isSome and max.get < low(int32)) or (min.isSome and min.get > high(int32))
  if isNeverTrue: return ConstantCondition(isTrue: negated)

  let rangeMin = if min.isSome and min.get > low(int32): some(int32(min.get)) else: none(int32)
  let rangeMax = if max.isSome and max.get < high(int32): some(int32(max.get)) else: none(int32)
  if rangeMin.isNone and rangeMax.isNone: return ConstantCondition(isTrue: not negated)

  singleCheck(Check(negated: negated, condition: MatchesTest(matches: Matches(score: score, min: rangeMin,
                                                                              max: rangeMax))))

proc minecraftCheck(compiler: Compiler, parts: seq[CommandPart], column: int, env: Environment,
                    negated: bool): Condition =
  ## `block ~ ~-1 ~ stone` → `if block ~ ~-1 ~ stone`, checked like the subcommands of `execute (...)`.
  let check = buildCommandText(compiler, parts, env)
  if check.isMacro:
    compiler.fail("a game value in a Minecraft check is not supported yet. Use 'execute (if ...) { }'")

  let text = checkMinecraftText(compiler, parts, check, column, "execute if ", " run say x")
  singleCheck(Check(negated: negated, condition: RawTest(raw: text)))

proc dataCondition(compiler: Compiler, identifier: Identifier, value: Value, negated: bool,
                   env: Environment): Condition =
  ## `$name == "Steve"` → `if data storage ns:data {name:"Steve"}`. The path becomes a nested filter.
  let path = dataPathOf(compiler, identifier, env)
  if path.path.find({'[', '"'}) >= 0:
    compiler.fail(&"a condition on '{identifier.name}' is not supported yet: the path must only have keys")

  let keys = path.path.split('.')
  var filter = ""
  for key in keys: filter.add "{" & key & ":"
  # Minecraft stores a bool as a byte, so the filter says `1b` or `0b`.
  case value
  of BooleanValue(boolean): filter.add(if boolean: "1b" else: "0b")
  else: filter.add valueToSnbt(value)
  filter.add '}'.repeat(keys.len)

  singleCheck(Check(negated: negated, condition: DataTest(dataPath: path.withPath(filter))))

proc dataComparison(compiler: Compiler, dataSide, other: Expression, env: Environment, negated: bool): Condition =
  ## `==` between data and a compile-time string, bool, list, compound or typed number is an NBT filter. A number
  ## comparison still goes through a score, which also works for other number types.
  let outerPosition = compiler.enterExpression(other)
  defer: compiler.position = outerPosition
  if containsRuntimeValue(other):
    compiler.fail("comparing two runtime values that are not numbers is not supported yet")
  let value = evaluate(compiler, other, env)
  compiler.dataCondition(identifierOf(dataSide).get, value, negated, env)

proc isNbtFilterComparison(left, right: Expression): bool =
  ## True when one side is data and the other is a compile-time value that is not a plain int.
  if not isDataIdentifier(left) and not isDataIdentifier(right): return false
  for side in [left, right]:
    if isDataIdentifier(side) or containsRuntimeValue(side): continue
    case side
    of StringExpression, BooleanExpression, ListExpression, CompoundExpression, TypedNumberExpression: return true
    of PrefixExpression(prefix):
      case prefix.operand
      of TypedNumberExpression: return true
      else: discard
    else: discard
  false

proc lowerOperand(compiler: Compiler, expression: Expression, env: Environment, setup: var seq[Command]): Operand =
  let outerPosition = compiler.enterExpression(expression)
  defer: compiler.position = outerPosition
  if not containsRuntimeValue(expression):
    let value = evaluate(compiler, expression, env)
    case value
    of TypedNumberValue(number):
      compiler.fail(&"a score holds whole numbers with no suffix, so it cannot be compared with '{number.text}'")
    of NumberValue(number): return NumberOperand(number: number)
    else: compiler.fail(&"only numbers can be compared with scores, found {tagName(value)}")

  let identifier = identifierOf(expression)
  if identifier.isSome and identifier.get.kind == ikScore:
    return ScoreOperand(score: compiler.scoreSource(identifier.get, env))

  let temp = compiler.newTemp()
  compiler.compileInto(temp, expression, env, setup)
  ScoreOperand(score: temp)

proc lowerComparison(compiler: Compiler, infix: Infix, env: Environment, negated: bool,
                     setup: var seq[Command]): Condition =
  let checkNegated = negated != (infix.op == ioNotEqual)
  let op = compareOperator(infix.op)

  if infix.op in {ioEqual, ioNotEqual} and isNbtFilterComparison(infix.left, infix.right):
    if isDataIdentifier(infix.left): return compiler.dataComparison(infix.left, infix.right, env, checkNegated)
    if isDataIdentifier(infix.right): return compiler.dataComparison(infix.right, infix.left, env, checkNegated)

  let left = compiler.lowerOperand(infix.left, env, setup)
  let right = compiler.lowerOperand(infix.right, env, setup)

  # At least one side has a score, so two numbers cannot happen here.
  case left
  of NumberOperand(number):
    case right
    of ScoreOperand(score): matchesCondition(score, flipCompare(op), number, checkNegated)
    of NumberOperand: raiseAssert "a comparison of two numbers is evaluated at compile time"
  of ScoreOperand(leftScore):
    case right
    of NumberOperand(number): matchesCondition(leftScore, op, number, checkNegated)
    of ScoreOperand(rightScore):
      singleCheck(Check(negated: checkNegated,
                        condition: CompareTest(compare: Compare(left: leftScore, op: op, right: rightScore))))

proc lowerCondition(compiler: Compiler, expression: Expression, env: Environment, negated: bool,
                    setup: var seq[Command]): Condition =
  let outerPosition = compiler.enterExpression(expression)
  defer: compiler.position = outerPosition
  if not containsRuntimeValue(expression):
    let value = evaluate(compiler, expression, env)
    case value
    of BooleanValue(boolean): return ConstantCondition(isTrue: boolean != negated)
    else: compiler.fail(&"a condition must be a comparison, a data path, true or false, found {tagName(value)}")

  case expression
  of PrefixExpression(prefix):
    if prefix.op == poNot: return compiler.lowerCondition(prefix.operand, env, not negated, setup)
  of InfixExpression(infix):
    case infix.op
    of ioAnd, ioOr:
      let left = compiler.lowerCondition(infix.left, env, negated, setup)
      let right = compiler.lowerCondition(infix.right, env, negated, setup)
      let isAnd = (infix.op == ioAnd) != negated
      return if isAnd: combineAnd(left, right) else: combineOr(left, right)
    of ioLess, ioLessEqual, ioGreater, ioGreaterEqual, ioEqual, ioNotEqual:
      return compiler.lowerComparison(infix, env, negated, setup)
    else: discard
  of CallExpression(call):
    if isStringTest(call): return stringTest(compiler, call, env, negated, setup)
  of MinecraftCheck(parts): return compiler.minecraftCheck(parts, expression.position.column, env, negated)
  of NameExpression(identifier):
    # `if ($x)` is Minecraft's `if data`: the path exists, whatever its value. A bool needs `== true`.
    if identifier.kind in {ikData, ikEntityData}:
      let path = dataPathOf(compiler, identifier, env)
      return singleCheck(Check(negated: negated, condition: DataTest(dataPath: path)))
    if identifier.kind == ikScore:
      compiler.fail(&"a score needs a comparison in a condition: 'if (#{identifier.name} != 0)'")
  else: discard

  compiler.fail("a condition must be a comparison, a data path, or 'and', 'or' and '!' of those")
