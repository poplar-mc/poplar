# mcfun calls: arguments, the call graph, and saving values around a recursive call. Part of compiler.nim.

const builtinNames* = ["append", "prepend", "insert", "remove", "len", "text", "onEvent", "onTrigger", "onDeath",
                       "onFirstJoin", "onJoin", "onRespawn", "slice", "str", "startsWith", "endsWith"]

func isBuiltin(name: string): bool = name in builtinNames

func isBuiltinCall(call: Call, name: string): bool =
  let callee = identifierOf(call.callee)
  callee.isSome and callee.get.namespace.isNone and callee.get.name == name

func exampleCompound(keys: OrderedSet[string]): string =
  ## `{a: ..., b: ...}` for the keys an mcfun uses, for error messages.
  if keys.len == 0: return "{name: ...}"
  "{" & keys.toSeq.mapIt(it & ": ...").join(", ") & "}"

proc argumentSnbt(compiler: Compiler, arg: Expression, env: Environment): string =
  ## A compile-time value as SNBT. A macro key is `"$(name)"`, so the line becomes a macro line.
  let outerPosition = compiler.enterExpression(arg)
  defer: compiler.position = outerPosition
  case arg
  of MacroKey(key): return &"\"$({key})\""
  else: discard

  let value = compiler.evaluate(arg, env)
  case value
  of NullValue: compiler.fail("null cannot be passed to an mcfun")
  else: discard
  valueToSnbt(value)

func setsData(body: openArray[Statement], name: string): bool =
  ## True if a statement assigns `$name`, or a raw command names
  ## it. A raw command is not read, so any mention counts.
  for statement in body:
    case statement
    of AssignStatement(assign):
      if assign.target.kind == ikData and pathRoot(assign.target.name) == name: return true
    of IfStatement(ifStatement):
      if setsData(ifStatement.thenBody, name): return true
      if ifStatement.elseBody.isSome and setsData(ifStatement.elseBody.get, name): return true
    of WhileStatement(whileLoop):
      if setsData(whileLoop.body, name): return true
    of ForStatement(forLoop):
      if setsData(forLoop.body, name): return true
    of ExecuteStatement(execute):
      if setsData(execute.body, name): return true
    of CommandStatement(command):
      if name in command.text: return true
    else: discard
  false

proc nonCompoundGlobal(compiler: Compiler, identifier: Identifier, env: Environment): Option[string] =
  ## The initial value of a whole `$` global that is not a compound and that no code changes. A global that code
  ## sets can hold a compound by the time of the call, so it is not reported. None otherwise.
  if identifier.kind != ikData or pathRoot(identifier.name) != identifier.name: return none(string)
  if identifier.namespace.isNone and env.getLocal(lkData, identifier.name).isSome: return none(string)
  let namespace = compiler.resolveNamespace(identifier.namespace)
  let key = qualifiedKey(namespace, identifier.name)
  if key notin compiler.dataGlobals: return none(string)
  let global = compiler.dataGlobals[key]
  if global.initialSnbt[0] == '{': return none(string)
  for declaration in compiler.mcfuns.values:
    if setsData(declaration.mcfun.body, identifier.name): return none(string)
  some(global.initialSnbt)

proc dataArguments(compiler: Compiler, value: Expression, env: Environment): FunctionWithArguments =
  ## `f() with $player`: the `$` variable is read as it is.
  let identifier = identifierOf(value).get
  let path = compiler.dataPathOf(identifier, env)
  let initial = compiler.nonCompoundGlobal(identifier, env)
  if initial.isSome:
    let name = identifier.name
    compiler.failOn(value, &"'with' needs a compound, but '${name}' is {initial.get}. Declare it as a compound: " &
                           &"'var ${name} = {{name: {initial.get}}};'")
  DataPathArguments(dataPath: path)

proc inlineCompound(compiler: Compiler, entries: openArray[Entry], env: Environment): string =
  var parts: seq[string]
  for entry in entries: parts.add snbtKey(entry.key) & ":" & compiler.argumentSnbt(entry.value, env)
  "{" & parts.join(",") & "}"

proc scoreOfArgument(compiler: Compiler, value: Expression, env: Environment,
                     commands: var seq[Command]): Option[Score] =
  ## The score that holds a value that is a score or math. None for any other value.
  if not containsRuntimeValue(value): return none(Score)
  case value
  of MacroKey, ListExpression, CompoundExpression: return none(Score)
  of CallExpression(call):
    if isStringCall(call): return none(Score)
  of NameExpression(identifier):
    if identifier.kind != ikScore: return none(Score)
    return some(compiler.scoreSource(identifier, env))
  else: discard

  let temp = compiler.newTemp()
  compiler.compileInto(temp, value, env, commands)
  some(temp)

proc storeArguments(compiler: Compiler, entries: openArray[Entry], env: Environment, commands: var seq[Command]) =
  ## Writes each key of `<ns>:poplar args`. Math is computed before any key is written, so a call inside a value
  ## cannot overwrite them.
  var entryScores: seq[Option[Score]]
  for entry in entries: entryScores.add compiler.scoreOfArgument(entry.value, env, commands)

  for index, entry in entries:
    let outerPosition = compiler.enterExpression(entry.value)
    defer: compiler.position = outerPosition
    let target = inStorage(stArgs, snbtKey(entry.key))
    let value = entry.value
    let isRuntime = containsRuntimeValue(value)
    let call = callOf(value)
    let isLiteral = case value
      of ListExpression, CompoundExpression: true
      else: false
    if entryScores[index].isSome:
      commands.add ScoreToDataCommand(scoreToData: ScoreToData(target: target, score: entryScores[index].get))
    elif call.isSome and isStringCall(call.get) and isRuntime:
      compiler.compileStringInto(target, call.get, env, commands)
    elif isDataIdentifier(value):
      let source = compiler.dataPathOf(identifierOf(value).get, env)
      commands.add DataCopyCommand(dataCopy: DataCopy(target: target, source: source))
    elif isLiteral and isRuntime:
      compiler.compileLiteralAssign(target, value, env, commands)
    else:
      commands.add DataSetCommand(dataValue: DataValue(target: target, snbt: compiler.argumentSnbt(value, env)))

proc compoundArguments(compiler: Compiler, mcfunName: string, keys: OrderedSet[string], value: Expression,
                       env: Environment, commands: var seq[Command]): FunctionWithArguments =
  ## `f() with {name: ...}`: written in the call when every value is known, else stored in `<ns>:poplar args`
  ## first.
  var entries: seq[Entry]
  case value
  of CompoundExpression(compoundEntries): entries = compoundEntries
  else:
    compiler.failOn(value, "'with' needs a compound ('{name: ...}'), a '$' variable, 'entity <selector>' or " &
                           "'block <position>'")

  for key in keys:
    if not entries.anyIt(it.key == key):
      compiler.failOn(value, &"mcfun '{mcfunName}' uses '$({key})', but this compound has no key '{key}'")

  var isInline = true
  for entry in entries:
    case entry.value
    of MacroKey: discard
    else:
      if containsRuntimeValue(entry.value): isInline = false
  if isInline: return CompoundArguments(compound: compiler.inlineCompound(entries, env))

  compiler.storeArguments(entries, env, commands)
  ArgsStorageArguments()

proc compileMcfunCall(compiler: Compiler, call: Call, declaration: McfunDeclaration, env: Environment,
                      commands: var seq[Command]): Command =
  ## Returns the command that calls an mcfun. Commands that write a runtime `with` compound go into `commands`
  ## first.
  let mcfun = declaration.mcfun
  var keys: OrderedSet[string]
  collectMacroKeys(mcfun.body, keys)
  if call.args.len > 0:
    compiler.fail(&"mcfun '{mcfun.name}' takes no arguments. Pass them as a compound: " &
                  &"'{mcfun.name}() with {exampleCompound(keys)}'")
  if call.with.isNone:
    if keys.len > 0:
      compiler.fail(&"mcfun '{mcfun.name}' uses '$({keys.toSeq[0]})', so it needs a compound: " &
                    &"'{mcfun.name}() with {exampleCompound(keys)}'")
    return FunctionCommand(function: declaration.irName)

  let arguments = case call.with.get
    of WithRaw(raw): RawArguments(raw: raw)
    of WithValue(value):
      if isDataIdentifier(value): compiler.dataArguments(value, env)
      else: compiler.compoundArguments(mcfun.name, keys, value, env, commands)
  FunctionWithCommand(functionWith: FunctionWith(name: declaration.irName, arguments: arguments))

proc generatedCall(compiler: Compiler, name: string): Command =
  ## Calls a generated function. In an mcfun that uses macro
  ## arguments, they are passed on, because the body can use them.
  if compiler.mcfun.forwardedArgs.isNone: return FunctionCommand(function: name)
  let arguments = CompoundArguments(compound: compiler.mcfun.forwardedArgs.get)
  FunctionWithCommand(functionWith: FunctionWith(name: name, arguments: arguments))

func scoreFrameSlot(score: Score): DataPath =
  ## The key in the frame: `t0` for the temp `#poplar.<mcfun>.t0`, and `s_i_countdown` for the local `#i_countdown`.
  let key = case score.kind
    of TempScore(temp): &"t{temp.index}"
    of LocalScore: "s_" & score.holder[1 .. ^1]
    of GlobalScore, ConstantScore: raiseAssert "only temps and locals are saved"
  inStorage(stFrame, key)

func dataFrameSlot(key: string): DataPath =
  ## The key in the frame of the data local `names_countdown`: `d_names_countdown`.
  inStorage(stFrame, "d_" & key)

proc addWithSavedValues(compiler: Compiler, call: Command, target: Option[Score], liveTempCount: int,
                           commands: var seq[Command]) =
  ## A recursive call runs this mcfun again, which overwrites its temps and locals. The live temps and the visible
  ## locals are saved in a frame around the call. `target` gets the result of the call, so it is not restored.
  var savedScores: seq[Score]
  var savedData: seq[string]
  for index in 0 ..< liveTempCount: savedScores.add compiler.tempScore(index)
  for local in compiler.mcfun.liveLocals:
    case local.kind
    of lkScore: savedScores.add localScore(local.generatedName, local.owner, compiler.scope.outputNamespace)
    of lkData: savedData.add local.generatedName
  if target.isSome:
    for index, score in savedScores:
      if score == target.get:
        savedScores.delete(index)
        break
  if savedScores.len + savedData.len == 0:
    commands.add call
    return

  compiler.usesStack = true
  commands.add FramePushCommand()
  for score in savedScores:
    commands.add ScoreToDataCommand(scoreToData: ScoreToData(target: scoreFrameSlot(score), score: score))
  for key in savedData:
    commands.add DataCopyCommand(dataCopy: DataCopy(target: dataFrameSlot(key), source: compiler.dataLocal(key)))
  commands.add call
  for score in savedScores:
    commands.add DataToScoreCommand(dataToScore: DataToScore(source: scoreFrameSlot(score), score: score))
  for key in savedData:
    commands.add DataCopyCommand(dataCopy: DataCopy(target: compiler.dataLocal(key), source: dataFrameSlot(key)))
  commands.add FramePopCommand()

proc calledKey(compiler: Compiler, identifier: Identifier): Option[string] =
  ## The key of a called name, without errors: the compile step reports a missing import or name.
  let key = qualifiedKey(identifier.namespace.get(compiler.scope.namespace), identifier.name)
  if key in compiler.mcfuns: some(key) else: none(string)

proc collectStdIds(compiler: Compiler, text: string, calls: var OrderedSet[string]) =
  ## A std mcfun is only written when something uses it, so a `std:name` in Minecraft text counts as a use.
  const prefix = stdNamespace & ":"
  var index = 0
  while true:
    let start = text.find(prefix, index)
    if start < 0: return
    index = start + prefix.len
    if start > 0 and isResourceNameChar(text[start - 1]): continue
    var stop = index
    while stop < text.len and (text[stop].isAlphaNumeric or text[stop] == '_'): inc stop
    let key = qualifiedKey(stdNamespace, text[index ..< stop])
    if key in compiler.mcfuns: calls.incl key

proc collectInsertCalls(compiler: Compiler, parts: openArray[CommandPart], calls: var OrderedSet[string]) =
  ## `/say {{double(2)}};` calls `double` too, and `/function std:clamp {...};` is a use of `std:clamp`.
  for part in parts:
    case part
    of TextPart(text): compiler.collectStdIds(text, calls)
    of InsertPart(insert): compiler.collectExpressionCalls(insert, calls)

proc collectExpressionCalls(compiler: Compiler, expression: Expression, calls: var OrderedSet[string]) =
  case expression
  of PrefixExpression(prefix): compiler.collectExpressionCalls(prefix.operand, calls)
  of InfixExpression(infix):
    compiler.collectExpressionCalls(infix.left, calls)
    compiler.collectExpressionCalls(infix.right, calls)
  of MinecraftCheck(parts): compiler.collectInsertCalls(parts, calls)
  of ListExpression(elements):
    for element in elements: compiler.collectExpressionCalls(element, calls)
  of CompoundExpression(entries):
    for entry in entries: compiler.collectExpressionCalls(entry.value, calls)
  of CallExpression(call):
    for arg in call.args: compiler.collectExpressionCalls(arg, calls)
    if call.with.isSome:
      case call.with.get
      of WithValue(value): compiler.collectExpressionCalls(value, calls)
      else: discard
    let callee = identifierOf(call.callee)
    if callee.isNone: return

    # An event callback is called from `load`, as far as the call graph is concerned.
    let isEvent = callee.get.namespace.isNone and callee.get.name in eventBuiltins
    if isEvent and call.args.len > 0:
      let callback = identifierOf(call.args[^1])
      if callback.isSome:
        let callbackKey = compiler.calledKey(callback.get)
        if callbackKey.isSome: calls.incl callbackKey.get
    let called = compiler.calledKey(callee.get)
    if called.isSome: calls.incl called.get
  else: discard

proc collectCalls(compiler: Compiler, body: openArray[Statement], calls: var OrderedSet[string]) =
  ## Finds the mcfun calls in a body. This can find calls that
  ## a compile-time branch removes later. That only adds saves.
  for statement in body:
    case statement
    of VarDeclStatement(varDecl): compiler.collectExpressionCalls(varDecl.value, calls)
    of AssignStatement(assign): compiler.collectExpressionCalls(assign.value, calls)
    of ReturnStatement(returned):
      if returned != nil: compiler.collectExpressionCalls(returned, calls)
    of BreakStatement, ContinueStatement: discard
    of IfStatement(ifStatement):
      compiler.collectExpressionCalls(ifStatement.condition, calls)
      compiler.collectCalls(ifStatement.thenBody, calls)
      if ifStatement.elseBody.isSome: compiler.collectCalls(ifStatement.elseBody.get, calls)
    of ForStatement(forLoop): compiler.collectCalls(forLoop.body, calls)
    of WhileStatement(whileLoop):
      compiler.collectExpressionCalls(whileLoop.condition, calls)
      compiler.collectCalls(whileLoop.body, calls)
    of ExecuteStatement(execute):
      compiler.collectInsertCalls(execute.subcommands, calls)
      compiler.collectCalls(execute.body, calls)
    of ExpressionStatement(expression): compiler.collectExpressionCalls(expression, calls)
    of CommandStatement(command): compiler.collectInsertCalls(command.parts, calls)

proc buildCallGraph(compiler: Compiler) =
  for mcfunKey, declaration in compiler.mcfuns:
    compiler.scope = compiler.scopeOf(declaration.namespace, declaration.imports)
    var calls: OrderedSet[string]
    compiler.collectCalls(declaration.mcfun.body, calls)
    compiler.mcfunCalls[mcfunKey] = calls

proc canReach(compiler: Compiler, start, goal: string): bool =
  ## True if `start` can call `goal`, directly or through other mcfuns.
  var pending = @[start]
  var visited: HashSet[string]
  while pending.len > 0:
    let name = pending.pop()
    if name == goal: return true
    if visited.containsOrIncl(name): continue
    if name notin compiler.mcfunCalls: continue
    for called in compiler.mcfunCalls[name]: pending.add called
  false

proc compileCall(compiler: Compiler, call: Call, env: Environment, commands: var seq[Command]) =
  let callee = identifierOf(call.callee)
  if callee.isNone: compiler.fail("only named functions can be called")
  let name = callee.get.name

  if callee.get.namespace.isNone and name in eventBuiltins:
    compiler.compileEvent(call, name, env)
    return
  if isStringCall(call) or isStringTest(call):
    compiler.fail(&"'{name}' gives a value. Use it: '$x = {name}(...);' or 'if ({name}(...))'")
  if callee.get.namespace.isNone and isBuiltin(name):
    compiler.compileListBuiltin(name, call, env, commands)
    return
  let found = compiler.findMcfun(callee.get)

  compiler.mcfun.tempCount = 0
  let command = compiler.compileMcfunCall(call, found.declaration, env, commands)
  if compiler.mcfun.liveLocals.len > 0 and compiler.canReach(found.key, compiler.mcfun.key):
    compiler.addWithSavedValues(command, none(Score), 0, commands)
    return
  commands.add command
