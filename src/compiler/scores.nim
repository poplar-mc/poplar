# Score math: computing into a score, operands, temps and constants. Part of compiler.nim.

func referencesScore(expression: Expression, target: Identifier): bool =
  case expression
  of NameExpression(identifier):
    identifier.kind == ikScore and identifier.name == target.name and
      identifier.selector.get("") == target.selector.get("")
  of PrefixExpression(prefix): referencesScore(prefix.operand, target)
  of InfixExpression(infix):
    referencesScore(infix.left, target) or referencesScore(infix.right, target)
  else: false

func isSafeInPlace(expression: Expression, target: Identifier): bool =
  ## The target can only be computed in place if it is read before it is first written, which is
  ## true when it appears only as the leftmost operand.
  case expression
  of InfixExpression(infix):
    isSafeInPlace(infix.left, target) and not referencesScore(infix.right, target)
  of PrefixExpression(prefix): isSafeInPlace(prefix.operand, target)
  else: true

func swappedInPlace(expression: Expression, target: Identifier): Option[Expression] =
  ## `#n = 3 + #n` is the same as `#n = #n + 3`, which is computed in `#n` with no temp.
  case expression
  of InfixExpression(infix):
    if infix.op notin {ioAdd, ioMultiply}: return none(Expression)
    if identifierOf(infix.right).isNone or not referencesScore(infix.right, target) or
       referencesScore(infix.left, target): return none(Expression)
    some(InfixExpression(position: expression.position,
                         infix: Infix(op: infix.op, left: infix.right, right: infix.left)))
  else: none(Expression)

func scoreOperator(op: InfixOperator): Option[Operator] =
  case op
  of ioAdd: some(opAdd)
  of ioSubtract: some(opSub)
  of ioMultiply: some(opMul)
  of ioDivide: some(opDiv)
  of ioModulo: some(opMod)
  else: none(Operator)

func isSingleEntitySelector(selector: string): bool =
  if selector[1] in "sprn": return true
  let limitStart = selector.find("limit=1")
  if limitStart < 0: return false
  let after = limitStart + "limit=1".len
  after < selector.len and selector[after] in {',', ']'}

proc checkSingleEntity(compiler: Compiler, identifier: Identifier) =
  if identifier.selector.isNone: return
  let selector = identifier.selector.get
  let failure = compiler.commandTree.checkSelector(selector)
  if failure.isSome: compiler.fail(failure.get.message)
  if isSingleEntitySelector(selector): return
  let sigil = if identifier.kind == ikEntityData: "$" else: "#"
  compiler.fail(&"'{selector}.{sigil}{identifier.name}' needs a selector for one entity (@s, @p, " &
                "@r, @n or limit=1)")

proc resolveScore(compiler: Compiler, identifier: Identifier, env: Environment): Score =
  ## `#x` is the global value of objective `<ns>.x`. `@s.#x` is the value of an entity in the same
  ## objective. A local `#x` is the fake player `#x_<mcfun>` in `<ns>`.
  let local = env.getLocal(lkScore, identifier.name)
  if local.isSome:
    if identifier.selector.isSome:
      compiler.fail(&"'#{identifier.name}' is local, so it has no entity values. Declare it at " &
                    "the top level")
    return localScore(local.get.generatedName, local.get.owner, compiler.scope.outputNamespace)
  let namespace = compiler.resolveNamespace(identifier.namespace)
  let key = qualifiedKey(namespace, identifier.name)
  if key notin compiler.globals: compiler.fail(&"unknown score '#{identifier.name}'")
  let global = compiler.globals[key]
  Score(holder: identifier.selector.get(globalHolder), objective: some(global.name),
        namespace: global.outputNamespace)

proc scoreSource(compiler: Compiler, identifier: Identifier, env: Environment): Score =
  ## Resolves a score that is read. An entity score must name one entity.
  result = compiler.resolveScore(identifier, env)
  compiler.checkSingleEntity(identifier)

proc toScoreValue(compiler: Compiler, value: Value): int32 =
  case value
  of TypedNumberValue(number):
    if number.hasFraction:
      compiler.fail(&"a score holds whole numbers, so it cannot hold '{number.text}'")
    compiler.fail(&"a score has no number types: write '{number.text}' with no suffix")
  of NumberValue(number):
    if number < low(int32) or number > high(int32):
      compiler.fail(&"value {number} does not fit in a score (32-bit)")
    int32(number)
  else: compiler.fail(&"a score must hold a number, found {tagName(value)}")

func globalScore(global: GlobalScore): Score =
  Score(holder: globalHolder, objective: some(global.name), namespace: global.outputNamespace)

proc constantScore(compiler: Compiler, value: int32): Score =
  if value notin compiler.constants: compiler.constants.add value
  constantScore(value)

proc tempScore(compiler: Compiler, index: int): Score =
  ## Each mcfun has its own temps, so a call to another mcfun cannot overwrite them.
  tempScore(compiler.mcfun.folder, index, compiler.scope.outputNamespace)

proc newTemp(compiler: Compiler): Score =
  result = compiler.tempScore(compiler.mcfun.tempCount)
  inc compiler.mcfun.tempCount

func addOperation(commands: var seq[Command], target: Score, op: Operator, source: Score) =
  commands.add ScoreOperationCommand(scoreOperation: ScoreOperation(target: target, op: op,
      source: source))

proc applyOperand(compiler: Compiler, target: Score, op: Operator, operand: Expression,
                  env: Environment, commands: var seq[Command]) =
  let outerPosition = compiler.enterExpression(operand)
  defer: compiler.position = outerPosition
  if not containsRuntimeValue(operand):
    let number = compiler.toScoreValue(compiler.evaluate(operand, env))

    if op in {opAdd, opSub} and number != low(int32):
      let scoreValue = ScoreValue(score: target, value: abs(number))
      let isAdd = (op == opAdd) == (number >= 0)
      if isAdd: commands.add ScoreAddCommand(scoreValue: scoreValue)
      else: commands.add ScoreRemoveCommand(scoreValue: scoreValue)
      return

    if op in {opDiv, opMod} and number == 0: compiler.fail("division by zero")
    addOperation(commands, target, op, compiler.constantScore(number))
    return

  let identifier = identifierOf(operand)
  if identifier.isSome and identifier.get.kind == ikScore:
    addOperation(commands, target, op, compiler.scoreSource(identifier.get, env))
    return

  let temp = compiler.newTemp()
  compiler.compileInto(temp, operand, env, commands)
  addOperation(commands, target, op, temp)

proc compileInto(compiler: Compiler, target: Score, expression: Expression, env: Environment,
                 commands: var seq[Command]) =
  let outerPosition = compiler.enterExpression(expression)
  defer: compiler.position = outerPosition
  if not containsRuntimeValue(expression):
    let number = compiler.toScoreValue(compiler.evaluate(expression, env))
    commands.add ScoreSetCommand(scoreValue: ScoreValue(score: target, value: number))
    return

  case expression
  of MacroKey(key):
    commands.add ScoreSetMacroArgumentCommand(scoreMacroArgument: ScoreMacroArgument(score: target,
        macroArgument: key))
  of NameExpression(identifier):
    if identifier.kind in {ikData, ikEntityData}:
      let source = compiler.dataPathOf(identifier, env)
      commands.add DataToScoreCommand(dataToScore: DataToScore(source: source, score: target))
      return

    let source = compiler.resolveScore(identifier, env)
    if source == target: return
    compiler.checkSingleEntity(identifier)
    addOperation(commands, target, opAssign, source)
  of PrefixExpression(prefix):
    if prefix.op != poNegate:
      compiler.fail(&"operator '{prefixOperatorText(prefix.op)}' cannot be used with scores")
    compiler.compileInto(target, prefix.operand, env, commands)
    addOperation(commands, target, opMul, compiler.constantScore(-1))
  of InfixExpression(infix):
    let op = scoreOperator(infix.op)
    if op.isNone:
      compiler.fail(&"operator '{infixOperatorText(infix.op)}' on scores needs 'if' (not " &
                    "supported yet)")
    compiler.compileInto(target, infix.left, env, commands)
    compiler.applyOperand(target, op.get, infix.right, env, commands)
  of CallExpression(call):
    if isBuiltinCall(call, "len"):
      compiler.compileLength(target, call, env, commands)
      return
    if isStringCall(call):
      let name = calleeName(call)
      compiler.fail(&"'{name}' gives a string, so it cannot be a score. Store it in data: " &
                    &"'$x = {name}(...);'")
    if isStringTest(call):
      compiler.fail(&"'{calleeName(call)}' is a condition. Use it in 'if' or 'while'")
    let callee = identifierOf(call.callee)
    if callee.isNone: compiler.fail("only an mcfun call can be used as a runtime value")
    let found = compiler.findMcfun(callee.get)
    # Temps made after this point hold arguments. They are not needed after the call.
    let liveCount = compiler.mcfun.tempCount
    let run = compiler.compileMcfunCall(call, found.declaration, env, commands)
    compiler.mcfun.tempCount = liveCount
    let store = StoreResultCommand(storeResult: StoreResult(target: ScoreTarget(score: target),
                                                            run: createCommand(run)))

    if not compiler.canReach(found.key, compiler.mcfun.key):
      commands.add store
      return
    compiler.addWithSavedValues(store, some(target), liveCount, commands)
  else: compiler.fail("this expression cannot be used with scores")

proc compileScoreAssign(compiler: Compiler, identifier: Identifier, expression: Expression,
                        env: Environment, commands: var seq[Command]) =
  let target = compiler.resolveScore(identifier, env)
  compiler.mcfun.tempCount = 0

  if isSafeInPlace(expression, identifier):
    compiler.compileInto(target, expression, env, commands)
    return
  let swapped = swappedInPlace(expression, identifier)
  if swapped.isSome:
    compiler.compileInto(target, swapped.get, env, commands)
    return

  let temp = compiler.newTemp()
  compiler.compileInto(temp, expression, env, commands)
  addOperation(commands, target, opAssign, temp)
