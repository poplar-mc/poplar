# What the game runs on its own: `poplar/load`, the `load` and `tick` of each namespace, and events. Part of
# compiler.nim.

proc visitNamespace(compiler: Compiler, namespace: string, visited: var HashSet[string], order: var seq[string]) =
  if visited.containsOrIncl(namespace): return
  if namespace in compiler.namespaceImports:
    for imported in sorted(toSeq(compiler.namespaceImports[namespace])):
      compiler.visitNamespace(imported, visited, order)
  order.add namespace

proc namespaceOrder(compiler: Compiler): seq[string] =
  var visited: HashSet[string]
  for namespace in sorted(toSeq(compiler.namespaceImports.keys)): compiler.visitNamespace(namespace, visited, result)

proc hookNames(compiler: Compiler, namespaces: OrderedSet[string], hook: string): seq[string] =
  ## The IR names of `load` or `tick` of each namespace that has one. A namespace comes after the namespaces it
  ## imports. Namespaces that import each other are in alphabetical order.
  for namespace in compiler.namespaceOrder():
    if namespace in namespaces: result.add compiler.functionName(namespace, hook)

proc reachableFromProject(compiler: Compiler): HashSet[string] =
  ## The mcfuns that a project mcfun can call, directly or
  ## through others. Event callbacks count as calls from `load`.
  var pending: seq[string]
  for mcfunKey, declaration in compiler.mcfuns:
    if declaration.origin != orStd: pending.add mcfunKey
  while pending.len > 0:
    let name = pending.pop()
    if result.containsOrIncl(name): continue
    if name notin compiler.mcfunCalls: continue
    for called in compiler.mcfunCalls[name]: pending.add called

proc eventObjective(compiler: Compiler, event: Event, index: int): string =
  case event.source
  of TriggerSource(trigger): trigger
  else: &"{event.namespace.get(compiler.packNamespace)}.event_{index}"

proc appendEventFunctions(compiler: Compiler, functions: var seq[McFunction], ticks: seq[string]) =
  ## For each event: `poplar/event_<n>` resets the player's score and runs the callback as `@s` at the player.
  ## `poplar/tick` runs it for every player with a count, then the user's `tick`.
  if compiler.events.len == 0: return

  var tick: seq[Command]
  for index, event in compiler.events:
    let objective = compiler.eventObjective(event, index)
    let name = &"poplar/event_{index}"
    let reset = RawCommand(raw: &"scoreboard players reset @s {objective}")
    # A player without the tag `<objective>` has not joined before.
    let mark = RawCommand(raw: &"tag @s add {objective}")
    let callback = FunctionCommand(function: event.callback)
    let body = case event.source
      of CriteriaSource, TriggerSource, RespawnSource: @[reset, callback]
      of FirstJoinSource: @[mark, callback]
      of JoinSource: @[reset, mark, callback]
    functions.add McFunction(name: name, commands: body)

    let players = case event.source
      of CriteriaSource, TriggerSource: @[&"@a[scores={{{objective}=1..}}]"]
      of FirstJoinSource: @[&"@a[tag=!{objective}]"]
      # A rejoin: the score of `leave_game` counted when the player left.
      of JoinSource: @[&"@a[tag=!{objective}]", &"@a[scores={{{objective}=1..}}]"]
      # Dead, and alive again: `time_since_death` only counts while the player is alive.
      of RespawnSource: @[&"@a[scores={{{objective}=1..,{objective}_alive=1..}}]"]
    for selector in players:
      tick.add ExecuteRawCommand(executeRaw: ExecuteRaw(subcommands: &"as {selector} at @s",
                                                        run: createCommand(FunctionCommand(function: name))))
  for event in compiler.events:
    case event.source
    of TriggerSource(trigger): tick.add RawCommand(raw: &"scoreboard players enable @a {trigger}")
    else: discard
  for name in ticks: tick.add FunctionCommand(function: name)
  functions.add McFunction(name: "poplar/tick", commands: tick)

proc isScoreRead(functions: seq[McFunction], score: Score): bool =
  for function in functions:
    for command in function.commands:
      if readsScore(command, score): return true
  false

proc removeUnusedConstants(compiler: Compiler, functions: seq[McFunction]) =
  ## The optimizer can remove the last use of a constant, for example `*= #poplar.c1`.
  var index = compiler.constants.len
  while index > 0:
    dec index
    if not isScoreRead(functions, constantScore(compiler.constants[index])): compiler.constants.delete(index)

proc mentionsGlobalHolder(command: Command, objective: string): bool =
  let text = case command
    of RawCommand(raw): raw
    of MacroCommand(macroLine): macroLine
    of FunctionWithCommand(call):
      case call.arguments
      of CompoundArguments(compound): compound
      else: return false
    else:
      let run = runOf(command)
      return run != nil and mentionsGlobalHolder(run[], objective)
  globalHolder in text and objective in text

proc isGlobalValueUsed(compiler: Compiler, functions: seq[McFunction], global: GlobalScore): bool =
  ## A score that is only used on entities (`@s.#mana`) needs no initial value on `#global`. A text part such as
  ## `text(#mana)` names `#global` in the command text, so that counts as a use too.
  let score = globalScore(global)
  let objective = &"\"{global.outputNamespace.get(compiler.packNamespace)}.{global.name}\""
  for function in functions:
    for command in function.commands:
      if readsScore(command, score) or mentionsGlobalHolder(command, objective): return true
  false

proc buildLoadFunction(compiler: Compiler, functions: seq[McFunction]): McFunction =
  ## Runs after all mcfuns, so that every constant they use is known.
  var commands: seq[Command]

  # A run that stopped in the middle of a recursive call can leave frames behind.
  if compiler.usesStack: commands.add StackClearCommand()
  commands.add AddObjectiveCommand(objective: Objective())
  for namespace in compiler.outputNamespaces():
    commands.add AddObjectiveCommand(objective: Objective(namespace: some(namespace)))
  for global in compiler.globals.values:
    commands.add AddObjectiveCommand(objective: Objective(namespace: global.outputNamespace, name: some(global.name)))
  for index, event in compiler.events:
    let objective = compiler.eventObjective(event, index)
    var criteria: string
    case event.source
    of CriteriaSource(eventCriteria): criteria = eventCriteria
    of TriggerSource: criteria = "trigger"
    of FirstJoinSource: continue
    of JoinSource: criteria = "minecraft.custom:minecraft.leave_game"
    of RespawnSource: criteria = "deathCount"
    commands.add RawCommand(raw: &"scoreboard objectives add {objective} {criteria}")
    case event.source
    of RespawnSource:
      commands.add RawCommand(raw: &"scoreboard objectives add {objective}_alive " &
                                   "minecraft.custom:minecraft.time_since_death")
    else: discard

  for constant in compiler.constants:
    commands.add ScoreSetCommand(scoreValue: ScoreValue(score: compiler.constantScore(constant), value: constant))

  for global in compiler.globals.values:
    if not compiler.isGlobalValueUsed(functions, global): continue
    commands.add ScoreSetIfUnsetCommand(scoreValue: ScoreValue(score: globalScore(global), value: global.initialValue))

  for global in compiler.dataGlobals.values:
    var target = inStorage(global.storage, global.name)
    target.namespace = global.outputNamespace
    commands.add DataSetIfUnsetCommand(dataValue: DataValue(target: target, snbt: global.initialSnbt))

  # A `load` with only `onEvent` lines has no commands, so `poplar/load` does not call it.
  for name in compiler.hookNames(compiler.loadNamespaces, "load"):
    var isEmpty = true
    for function in functions:
      if function.name == name:
        isEmpty = function.commands.len == 0
        break
    if not isEmpty: commands.add FunctionCommand(function: name)

  McFunction(name: "poplar/load", commands: commands)

proc isInRuntimeBranch(env: Environment): bool =
  var scope = env
  while scope != nil:
    if scope.runtimeBranch: return true
    scope = scope.outer
  false

proc poplarObjectiveClash(compiler: Compiler, name: string): Option[string] =
  ## Poplar's objectives are `poplar.<ns>` and `<ns>.<name>`. Gives the prefix that a trigger name clashes with.
  if name.startsWith("poplar."): return some("poplar.")
  for namespace in @[compiler.packNamespace] & compiler.outputNamespaces():
    let prefix = namespace & "."
    if name.startsWith(prefix): return some(prefix)
  none(string)

proc eventName(compiler: Compiler, argument: Expression, builtin: string, kind: EventKind, first: string,
               env: Environment): string =
  ## The first argument of `onEvent` or `onTrigger`, which must be a constant string.
  var name = ""
  case evaluate(compiler, argument, env)
  of StringValue(text): name = text
  else: discard
  if name.len == 0:
    let example = if kind == ekTrigger: "showoff" else: "deathCount"
    compiler.fail(&"the {first} of '{builtin}' must be a string, for example \"{example}\"")
  if kind != ekTrigger: return name

  if not name.allCharsInSet(Letters + Digits + {'_', '-', '.', '+'}):
    compiler.fail(&"the trigger name '{name}' can only have letters, 0-9, '_', '-', '.' and '+'")
  let clash = compiler.poplarObjectiveClash(name)
  if clash.isSome:
    compiler.fail(&"the trigger name '{name}' starts with '{clash.get}', which Poplar uses for its own objectives")
  name

proc callbackOf(compiler: Compiler, callback: Expression, builtin: string): string =
  ## The IR name of an event's callback: an mcfun that uses no macro arguments.
  let outerPosition = compiler.enterExpression(callback)
  defer: compiler.position = outerPosition
  let identifier = identifierOf(callback)
  if identifier.isNone or identifier.get.kind != ikCompileTime:
    compiler.fail(&"the callback of '{builtin}' must be the name of an mcfun")
  let found = compiler.findMcfun(identifier.get)
  var keys: OrderedSet[string]
  collectMacroKeys(found.declaration.mcfun.body, keys)
  if keys.len > 0:
    compiler.fail(&"the callback '{identifier.get.name}' is run by the game, so it gets no macro arguments and " &
                  &"cannot use '$({toSeq(keys)[0]})'")
  found.declaration.irName

proc compileEvent(compiler: Compiler, call: Call, builtin: string, env: Environment) =
  ## `onEvent(criteria, callback)` and the other event builtins in `load`. It registers the event at compile time and
  ## writes no command.
  let kind = eventBuiltins[builtin]
  if not compiler.mcfun.inLoad: compiler.fail(&"'{builtin}' must be in 'mcfun load'")
  if isInRuntimeBranch(env):
    compiler.fail(&"'{builtin}' registers the event when the pack is compiled, so it cannot be in a runtime 'if', " &
                  "'while' or 'execute'")

  # `onEvent(criteria, callback)` and `onTrigger(name, callback)` take a name first; the player events only a
  # callback.
  let takesName = kind == ekTrigger or builtin == "onEvent"
  let first = if kind == ekTrigger: "name" else: "criteria"
  if takesName and call.args.len != 2:
    compiler.fail(&"'{builtin}' expects 2 arguments ({first}, callback), found {call.args.len}")
  if not takesName and call.args.len != 1:
    compiler.fail(&"'{builtin}' expects 1 argument (callback), found {call.args.len}")

  let name = if takesName: compiler.eventName(call.args[0], builtin, kind, first, env) else: ""
  let callback = compiler.callbackOf(call.args[^1], builtin)
  let source = case kind
    of ekCriteria: CriteriaSource(criteria: if takesName: name else: "deathCount")
    of ekTrigger: TriggerSource(trigger: name)
    of ekFirstJoin: FirstJoinSource()
    of ekJoin: JoinSource()
    of ekRespawn: RespawnSource()
  compiler.events.add Event(source: source, callback: callback, namespace: compiler.scope.outputNamespace)
