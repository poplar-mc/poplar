## Small rewrites of the IR, as in bolt-expressions. `optimizeFunction` runs the passes in order on
## each function.

import std/[math, options, sets, strutils, tables]
import datapack_writer, ir

type
  KnownValue = object
    ## A score value that the optimizer knows: a number, or the value of a macro argument.
    case
    of NumberKnown: number: int32
    of MacroArgumentKnown: macroArgument: string

  KnownScore = object
    score: Score
    value: KnownValue

  KnownScores = object
    ## The scores with a known value at one point in a function.
    entries: seq[KnownScore]

  ScoreReads* = object
    scores: HashSet[Score]
    rawCheckText: string ## The checks written by the user, which can name any score.

  CallCounts = object
    calls: CountTable[string] ## The number of commands that call each function.
    returnValueReads: CountTable[string]
      ## The number of commands that use the return value of each function.

func runOf*(command: Command): ref Command =
  ## The command that an `execute`, `store result` or `return run` runs. Nil for other commands.
  case command
  of ExecuteCommand(execute): execute.run
  of ExecuteRawCommand(execute): execute.run
  of StoreResultCommand(store): store.run
  of ReturnRunCommand(run): run
  else: nil

func withRun(command: Command, run: Command): Command =
  let newRun = createCommand(run)
  case command
  of ExecuteCommand(execute): ExecuteCommand(execute: Execute(checks: execute.checks, run: newRun))
  of ExecuteRawCommand(execute):
    ExecuteRawCommand(executeRaw: ExecuteRaw(subcommands: execute.subcommands, run: newRun))
  of StoreResultCommand(store):
    StoreResultCommand(storeResult: StoreResult(target: store.target, run: newRun))
  of ReturnRunCommand: ReturnRunCommand(returnRun: newRun)
  else: raiseAssert "the command runs no other command"

func constantValue(score: Score): Option[int32] =
  case score.kind
  of ConstantScore(constant): some(constant)
  else: none(int32)

func isConstant(score: Score): bool = constantValue(score).isSome

func isConstantOne(score: Score): bool = constantValue(score) == some(1'i32)

func isScopedHere(score: Score, functionName: string): bool =
  ## A temp, or a local of this mcfun, is only read by this function and its generated functions. A
  ## local can be written in a generated body and read by its mcfun after the body returns, so it
  ## only counts in the mcfun itself.
  case score.kind
  of LocalScore(owner): owner == functionName
  of TempScore: true
  of GlobalScore, ConstantScore: false

func isTracked(score: Score): bool =
  ## Fake players, and `@s`, which is the same entity for the whole function. Other selectors can
  ## match other entities in each command.
  score.holder.startsWith('#') or score.holder == "@s"

func isGenerated(name: string): bool =
  splitName(name)[1].startsWith("poplar/")

func checkedFunction(execute: Execute): Option[string] =
  ## The function of an `execute if function ...` check.
  for check in execute.checks:
    case check.condition
    of FunctionReturnsTest(function): return some(function)
    else: discard
  none(string)

func runsCheckedCode(execute: Execute): bool =
  ## `if function ...` written by the user runs code as part of the check.
  for check in execute.checks:
    case check.condition
    of RawTest(raw):
      if raw.startsWith("function "): return true
    else: discard
  false

func addScoresRead(command: Command, scores: var seq[Score], rawChecks: var seq[string]) =
  ## Adds the scores that the command reads. A check written by the user (`score @s ...`) can name
  ## any score, so its text goes in `rawChecks`.
  case command
  of {ScoreAddCommand, ScoreRemoveCommand}(change): scores.add change.score
  of ScoreOperationCommand(operation):
    scores.add operation.source
    if operation.op != opAssign: scores.add operation.target
  of ScoreToDataCommand(store): scores.add store.score
  of ScoreGetCommand(read): scores.add read
  of ExecuteCommand(execute):
    for check in execute.checks:
      case check.condition
      of DataTest, FunctionReturnsTest: discard
      of RawTest(raw): rawChecks.add raw
      of MatchesTest(matches): scores.add matches.score
      of CompareTest(compare):
        scores.add compare.left
        scores.add compare.right
    addScoresRead(execute.run[], scores, rawChecks)
  else:
    let run = runOf(command)
    if run != nil: addScoresRead(run[], scores, rawChecks)

func readsScore(command: Command, score: Score): bool =
  var scores: seq[Score]
  var rawChecks: seq[string]
  addScoresRead(command, scores, rawChecks)
  if score in scores: return true
  for raw in rawChecks:
    if score.holder in raw: return true
  false

func scoreReads*(functions: openArray[McFunction]): ScoreReads =
  ## The scores that any command reads, so that a check of many scores scans the program one time.
  var scores: seq[Score]
  var rawChecks: seq[string]
  for function in functions:
    for command in function.commands: addScoresRead(command, scores, rawChecks)
  result.scores = scores.toHashSet
  # A holder never has a line break, so it is in the joined text only if it is in one check.
  result.rawCheckText = rawChecks.join("\n")

func isRead*(reads: ScoreReads, score: Score): bool =
  score in reads.scores or score.holder in reads.rawCheckText

func setsScore(command: Command, score: Score): bool =
  ## Only a command that always runs counts. A write inside `execute if` may not happen.
  case command
  of ScoreSetCommand(scoreValue): scoreValue.score == score
  of ScoreSetMacroArgumentCommand(argument): argument.score == score
  of ScoreOperationCommand(operation): operation.op == opAssign and operation.target == score
  of DataToScoreCommand(store): store.score == score
  of StoreResultCommand(store):
    case store.target
    of ScoreTarget(target): target == score
    else: false
  else: false

func runsOtherCode(command: Command): bool =
  case command
  of FunctionCommand, FunctionWithCommand, MacroCommand, RawCommand, ExecuteRawCommand: true
  of ExecuteCommand(execute):
    checkedFunction(execute).isSome or runsCheckedCode(execute) or runsOtherCode(execute.run[])
  else:
    let run = runOf(command)
    run != nil and runsOtherCode(run[])

func canReturn(command: Command): bool =
  case command
  of ReturnRunCommand, ReturnValueCommand, ReturnMacroArgumentCommand: true
  of ExecuteCommand(execute): canReturn(execute.run[])
  of ExecuteRawCommand(execute): canReturn(execute.run[])
  else: false

func calledFunctions(command: Command): seq[string] =
  ## The functions that the command calls, each one time.
  case command
  of FunctionCommand(called): result = @[called]
  of FunctionWithCommand(call): result = @[call.name]
  of ExecuteCommand(execute):
    result = calledFunctions(execute.run[])
    let checked = checkedFunction(execute)
    if checked.isSome and checked.get notin result: result.add checked.get
  else:
    let run = runOf(command)
    if run != nil: result = calledFunctions(run[])

func readsTempsOf(name: string, temp: Score): bool =
  # A `macro_<n>` helper holds one user command, so it never reads a temp.
  if name.split('/')[^1].startsWith("macro_"): return false

  let (functionNamespace, path) = splitName(name)
  # A local knows its mcfun (`combat:heal`). A temp knows the folder of its mcfun, in its namespace.
  var ownerNamespace: Option[string]
  var owner: string
  case temp.kind
  of LocalScore(localOwner): (ownerNamespace, owner) = splitName(localOwner)
  of TempScore(details): (ownerNamespace, owner) = (temp.namespace, details.folder)
  of GlobalScore, ConstantScore: raiseAssert "only temps and locals belong to an mcfun"
  if functionNamespace != ownerNamespace: return false

  const generatedPrefix = "poplar/"
  if not path.startsWith(generatedPrefix): return false
  let folderEnd = path.find('/', generatedPrefix.len)
  if folderEnd < 0: return false
  isGeneratedFolder(path[generatedPrefix.len..<folderEnd], owner)

func callsTempReader(command: Command, temp: Score): bool =
  ## Only the mcfun and its generated functions (`poplar/<mcfun>/...`) read the temps of the mcfun.
  ## The mcfun itself sets each temp before it reads it, so a recursive call does not read them.
  case command
  of FunctionCommand(name): readsTempsOf(name, temp)
  of FunctionWithCommand(call): readsTempsOf(call.name, temp)
  of ExecuteCommand(execute):
    let checked = checkedFunction(execute)
    if checked.isSome and readsTempsOf(checked.get, temp): return true
    callsTempReader(execute.run[], temp)
  else:
    let run = runOf(command)
    run != nil and callsTempReader(run[], temp)

func mentionsInText(command: Command, name: string): bool =
  case command
  of RawCommand(raw): name in raw
  of MacroCommand(macroLine): name in macroLine
  of FunctionWithCommand(call):
    case call.arguments
    of CompoundArguments(compound): name in compound
    else: false
  of ExecuteCommand(execute):
    for check in execute.checks:
      case check.condition
      of RawTest(raw):
        if name in raw: return true
      else: discard
    mentionsInText(execute.run[], name)
  of ExecuteRawCommand(execute): name in execute.subcommands or mentionsInText(execute.run[], name)
  else:
    let run = runOf(command)
    run != nil and mentionsInText(run[], name)

func isReadLater(commands: openArray[Command], temp: Score): bool =
  ## True if a command reads the temp before a command sets it again.
  for command in commands:
    if readsScore(command, temp) or callsTempReader(command, temp): return true
    # Command text can name a local's fake player: a user command, or a `text(#x)` part in a call's
    # arguments.
    case temp.kind
    of LocalScore:
      if mentionsInText(command, temp.holder): return true
    else: discard
    if setsScore(command, temp): return false
  false

func isSetBeforeUse(commands: openArray[Command], score: Score): bool =
  ## Other functions and user commands can read any global score, and so can the caller after a
  ## return.
  for command in commands:
    if readsScore(command, score) or runsOtherCode(command) or canReturn(command): return false
    if setsScore(command, score): return true
  false

# ---- known values

func `==`(a, b: KnownValue): bool =
  case a
  of NumberKnown(number):
    case b
    of NumberKnown(other): number == other
    else: false
  of MacroArgumentKnown(macroArgument):
    case b
    of MacroArgumentKnown(other): macroArgument == other
    else: false

func numberOf(value: KnownValue): Option[int32] =
  case value
  of NumberKnown(number): some(number)
  else: none(int32)

func get(known: KnownScores, score: Score): Option[KnownValue] =
  let constant = constantValue(score)
  if constant.isSome: return some(NumberKnown(number: constant.get))
  for entry in known.entries:
    if entry.score == score: return some(entry.value)
  none(KnownValue)

func scoreWithValue(known: KnownScores, value: KnownValue): Option[Score] =
  for entry in known.entries:
    if entry.value == value: return some(entry.score)
  none(Score)

func forget(known: var KnownScores, score: Score) =
  for index, entry in known.entries:
    if entry.score == score:
      known.entries.del(index)
      return

func remember(known: var KnownScores, score: Score, value: KnownValue) =
  known.forget(score)
  if isTracked(score): known.entries.add KnownScore(score: score, value: value)

func forgetWrites(known: var KnownScores, command: Command) =
  ## A call can run this mcfun again (recursion), and a user command can change any score.
  if runsOtherCode(command):
    known.entries.setLen(0)
    return
  case command
  of {ScoreSetCommand, ScoreSetIfUnsetCommand, ScoreAddCommand, ScoreRemoveCommand}(scoreValue):
    known.forget(scoreValue.score)
  of ScoreSetMacroArgumentCommand(argument): known.forget(argument.score)
  of ScoreOperationCommand(operation): known.forget(operation.target)
  of DataToScoreCommand(store): known.forget(store.score)
  of StoreResultCommand(store):
    case store.target
    of ScoreTarget(target): known.forget(target)
    else: discard
    known.forgetWrites(store.run[])
  of ExecuteCommand(execute): known.forgetWrites(execute.run[])
  of ReturnRunCommand(run): known.forgetWrites(run[])
  else: discard

func learn(known: var KnownScores, command: Command) =
  var learned: Option[KnownScore]
  case command
  of ScoreSetCommand(scoreValue):
    let known = NumberKnown(number: scoreValue.value)
    learned = some(KnownScore(score: scoreValue.score, value: known))
  of ScoreSetMacroArgumentCommand(argument):
    learned = some(KnownScore(score: argument.score,
                              value: MacroArgumentKnown(macroArgument: argument.macroArgument)))
  of ScoreOperationCommand(operation):
    if operation.op == opAssign:
      let value = known.get(operation.source)
      if value.isSome: learned = some(KnownScore(score: operation.target, value: value.get))
  else: discard
  known.forgetWrites(command)
  if learned.isSome: known.remember(learned.get.score, learned.get.value)

func isKnown(known: KnownScores, score: Score, value: KnownValue): bool =
  known.get(score) == some(value)

func foldMath(known: KnownScores, command: Command): Option[ScoreValue] =
  ## The same math as Minecraft: ints wrap, and `/=` and `%=` round down. Division by 0 is not
  ## computed.
  var target: Score
  var op: Operator
  var source: KnownValue
  case command
  of ScoreAddCommand(change):
    (target, op, source) = (change.score, opAdd, NumberKnown(number: change.value))
  of ScoreRemoveCommand(change):
    (target, op, source) = (change.score, opSub, NumberKnown(number: change.value))
  of ScoreOperationCommand(operation):
    let value = known.get(operation.source)
    if value.isNone: return none(ScoreValue)
    (target, op, source) = (operation.target, operation.op, value.get)
  else: return none(ScoreValue)
  let sourceNumber = numberOf(source)
  if sourceNumber.isNone: return none(ScoreValue)
  let right = sourceNumber.get
  if op == opAssign: return some(ScoreValue(score: target, value: right))

  let current = known.get(target)
  let targetNumber = if current.isSome: numberOf(current.get) else: none(int32)
  if targetNumber.isNone: return none(ScoreValue)
  let left = targetNumber.get

  let value = case op
    of opAssign: right
    of opAdd: left +% right
    of opSub: left -% right
    of opMul: left *% right
    of opDiv:
      if right == 0 or (left == low(int32) and right == -1): return none(ScoreValue)
      floorDiv(left, right)
    of opMod:
      if right <= 0: return none(ScoreValue)
      floorMod(left, right)
  some(ScoreValue(score: target, value: value))

# ---- passes

func removeIdentities(commands: openArray[Command]): seq[Command] =
  ## `add 0`, `remove 0`, `*= 1` and `/= 1` do nothing.
  for command in commands:
    let doesNothing = case command
      of {ScoreAddCommand, ScoreRemoveCommand}(change): change.value == 0
      of ScoreOperationCommand(operation):
        operation.op in {opMul, opDiv} and isConstantOne(operation.source)
      else: false
    if not doesNothing: result.add command

func propagateKnownValues(commands: openArray[Command]): seq[Command] =
  ## Removes a set when the score already has the value, copies a macro argument from a score that
  ## holds it (a macro line is parsed again for new arguments), and computes math on known numbers.
  var known: KnownScores
  for command in commands:
    var optimized = some(command)
    case command
    of ScoreSetCommand(scoreValue):
      if known.isKnown(scoreValue.score,
                       NumberKnown(number: scoreValue.value)): optimized = none(Command)
    of ScoreSetMacroArgumentCommand(argument):
      let value = MacroArgumentKnown(macroArgument: argument.macroArgument)
      if known.isKnown(argument.score, value):
        optimized = none(Command)
      else:
        let copy = known.scoreWithValue(value)
        if copy.isSome:
          let operation = ScoreOperation(target: argument.score, op: opAssign, source: copy.get)
          optimized = some(ScoreOperationCommand(scoreOperation: operation))
    of ScoreAddCommand, ScoreRemoveCommand, ScoreOperationCommand:
      let folded = known.foldMath(command)
      if folded.isSome: optimized = some(ScoreSetCommand(scoreValue: folded.get))
    else: discard
    if optimized.isSome:
      known.learn(optimized.get)
      result.add optimized.get

func removeDeadWrites(functionName: string, commands: openArray[Command]): seq[Command] =
  ## A write to a temp or a local is removed when nothing reads it before it is set again or the
  ## function ends. A write to a global is removed only when it is set again before anything else
  ## can read it.
  for index, command in commands:
    var written = none(Score)
    case command
    of {ScoreSetCommand, ScoreAddCommand, ScoreRemoveCommand}(scoreValue):
      written = some(scoreValue.score)
    of ScoreSetMacroArgumentCommand(argument): written = some(argument.score)
    of ScoreOperationCommand(operation): written = some(operation.target)
    of DataToScoreCommand(store): written = some(store.score)
    else: discard
    if written.isSome:
      let score = written.get
      let isDead =
        if isScopedHere(score, functionName):
          not isReadLater(commands.toOpenArray(index + 1, commands.high), score)
        else:
          isTracked(score) and isSetBeforeUse(commands.toOpenArray(index + 1, commands.high), score)
      if isDead: continue
    result.add command

func scaleDataGets(commands: openArray[Command]): seq[Command] =
  ## `data get X` followed by `*= N` becomes `data get X N`. Only `*=`: a scale such as 0.01 can
  ## round wrongly.
  var index = 0
  while index < commands.len:
    var command = commands[index]
    if index + 1 < commands.len:
      case command
      of DataToScoreCommand(store):
        case commands[index + 1]
        of ScoreOperationCommand(operation):
          let factor = constantValue(operation.source)
          if operation.op == opMul and operation.target == store.score and factor.isSome:
            let scale = int64(store.scale) * int64(factor.get)
            if scale in int64(low(int32))..int64(high(int32)):
              store.scale = int32(scale)
              inc index
        else: discard
      else: discard
    result.add command
    inc index

func definedTemp(command: Command, functionName: string): Option[Score] =
  ## The temp that a command writes, when the command's result is the temp's new value. `/=` and
  ## `%=` fail when the source is 0, and then the result is 0, so they need a constant source.
  var score: Score
  case command
  of {ScoreSetCommand, ScoreAddCommand, ScoreRemoveCommand}(scoreValue): score = scoreValue.score
  of ScoreSetMacroArgumentCommand(argument): score = argument.score
  of ScoreOperationCommand(operation):
    let canFail = operation.op in {opDiv, opMod}
    if canFail and not isConstant(operation.source): return none(Score)
    score = operation.target
  else: return none(Score)
  if isScopedHere(score, functionName): some(score) else: none(Score)

func mergeCopy(definition, copy: Command, temp: Score): Option[Command] =
  case copy
  of ScoreToDataCommand(store):
    if store.score != temp: return none(Command)
    some(StoreResultCommand(storeResult: StoreResult(target: DataTarget(dataPath: store.target),
                                                     run: createCommand(definition))))
  of ReturnRunCommand(run):
    case run[]
    of ScoreGetCommand(read):
      if read != temp: return none(Command)
      some(ReturnRunCommand(returnRun: createCommand(definition)))
    else: none(Command)
  of ScoreOperationCommand(operation):
    if operation.op != opAssign or operation.source != temp or operation.target == temp:
      return none(Command)
    some(StoreResultCommand(storeResult: StoreResult(target: ScoreTarget(score: operation.target),
                                                     run: createCommand(definition))))
  else: none(Command)

func inlineStores(functionName: string, commands: openArray[Command]): seq[Command] =
  ## A command that computes a temp, followed by a copy of that temp, becomes one command:
  ## `scoreboard players remove T 1` +
  ## `execute store result storage X int 1 run scoreboard players get T` →
  ## `execute store result storage X int 1 run scoreboard players remove T 1`.
  var index = 0
  while index < commands.len:
    let command = commands[index]
    if index + 1 < commands.len:
      let temp = definedTemp(command, functionName)
      if temp.isSome:
        let merged = mergeCopy(command, commands[index + 1], temp.get)
        if merged.isSome and not isReadLater(commands.toOpenArray(index + 2, commands.high),
                                             temp.get):
          result.add merged.get
          index += 2
          continue
    result.add command
    inc index

func storeConstants(functionName: string, commands: openArray[Command]): seq[Command] =
  ## `execute store result storage X float 1 run scoreboard players set T 20` →
  ## `data modify storage X set value 20f`, when nothing reads the temp after it. A store into a
  ## score becomes `scoreboard players set`.
  for index, command in commands:
    case command
    of StoreResultCommand(store):
      case store.run[]
      of ScoreSetCommand(scoreValue):
        if isScopedHere(scoreValue.score, functionName) and
           not isReadLater(commands.toOpenArray(index + 1, commands.high), scoreValue.score):
          case store.target
          of ScoreTarget(score):
            result.add ScoreSetCommand(scoreValue: ScoreValue(score: score,
                value: scoreValue.value))
          of DataTarget(path):
            result.add DataSetCommand(dataValue: DataValue(target: path, snbt: $scoreValue.value))
          continue
      else: discard
    else: discard
    result.add command

func optimizeFunction*(functionName: string, commands: openArray[Command]): seq[Command] =
  ## The passes run in this order on each function. Each pass is a small rewrite, as in
  ## bolt-expressions.
  let withoutIdentities = removeIdentities(commands)
  let withKnownValues = propagateKnownValues(withoutIdentities)
  let withoutDeadWrites = removeDeadWrites(functionName, withKnownValues)
  let withScaledGets = scaleDataGets(withoutDeadWrites)
  let withInlinedStores = inlineStores(functionName, withScaledGets)
  storeConstants(functionName, withInlinedStores)

# ---- across functions

func smallBodies(functions: openArray[McFunction]): Table[string, Command] =
  ## The command of each generated function that has one command, which cannot return.
  for function in functions:
    if isGenerated(function.name) and function.commands.len == 1 and
       not canReturn(function.commands[0]):
      result[function.name] = function.commands[0]

func smallBody(bodies: Table[string, Command], caller, name: string): Option[Command] =
  if caller != name and name in bodies: some(bodies[name]) else: none(Command)

func inlineCall(bodies: Table[string, Command], caller: string,
                command: Command): Option[Command] =
  case command
  of FunctionCommand(name): smallBody(bodies, caller, name)
  # A generated function gets the arguments of its mcfun, so `$(arg)` means the same in the caller.
  of FunctionWithCommand(call):
    case call.arguments
    of CompoundArguments: smallBody(bodies, caller, call.name)
    else: none(Command)
  of ExecuteCommand(execute):
    let run = inlineCall(bodies, caller, execute.run[])
    if run.isNone: return none(Command)
    case run.get
    of ExecuteCommand(inner):
      some(ExecuteCommand(execute: Execute(checks: execute.checks & inner.checks, run: inner.run)))
    else:
      some(ExecuteCommand(execute: Execute(checks: execute.checks, run: createCommand(run.get))))
  of ExecuteRawCommand(execute):
    let run = inlineCall(bodies, caller, execute.run[])
    if run.isNone: return none(Command)
    some(ExecuteRawCommand(executeRaw: ExecuteRaw(subcommands: execute.subcommands,
        run: createCommand(run.get))))
  else: none(Command)

func returnValuesRead(command: Command): seq[string] =
  ## The functions whose return value the command uses: `store result ... run function`,
  ## `if function`, or `return run function`.
  case command
  of StoreResultCommand(store): result = calledFunctions(store.run[])
  of ReturnRunCommand(run): result = calledFunctions(run[])
  of ExecuteCommand(execute):
    result = returnValuesRead(execute.run[])
    let checked = checkedFunction(execute)
    if checked.isSome and checked.get notin result: result.add checked.get
  of ExecuteRawCommand(execute): result = returnValuesRead(execute.run[])
  else: discard

func add(counts: var CallCounts, command: Command, change = 1) =
  for name in calledFunctions(command): counts.calls.inc(name, change)
  for name in returnValuesRead(command): counts.returnValueReads.inc(name, change)

func callCounts(functions: openArray[McFunction]): CallCounts =
  for function in functions:
    for command in function.commands: result.add command

func inlineTailCalls(functions: var seq[McFunction], counts: var CallCounts) =
  ## A generated function that is called once, as the last command of its caller, is put in its
  ## place, even when it can return: leaving the caller there is what happens anyway. Not when
  ## something reads the caller's return value.
  var indexes: Table[string, int]
  for index, function in functions: indexes[function.name] = index
  for function in functions.mitems:
    let commands = function.commands
    if commands.len == 0: continue
    var calleeName: string
    case commands[^1]
    of FunctionCommand(name): calleeName = name
    # A generated function gets the arguments of its mcfun, so `$(arg)` means the same in the
    # caller.
    of FunctionWithCommand(call):
      case call.arguments
      of CompoundArguments: calleeName = call.name
      else: continue
    else: continue
    if not isGenerated(calleeName) or calleeName == function.name or calleeName notin indexes:
      continue
    if counts.calls[calleeName] != 1 or counts.returnValueReads[function.name] > 0: continue
    let calleeCommands = functions[indexes[calleeName]].commands
    counts.add(commands[^1], -1)
    for command in calleeCommands: counts.add command
    function.commands = commands[0 ..< commands.len - 1] & calleeCommands

func inlineSmallFunctions*(functions: openArray[McFunction]): seq[McFunction] =
  ## A generated function with one command is put where it is called, and the function is removed. A
  ## command that can return is not moved, because the `return` would then leave the caller.
  # One pass with the original bodies, so that functions that call each other cannot grow forever.
  let bodies = smallBodies(functions)
  var inlined = @functions
  for function in inlined.mitems:
    var commands: seq[Command]
    for command in function.commands:
      commands.add inlineCall(bodies, function.name, command).get(command)
    function.commands = commands
  var counts = callCounts(inlined)
  inlineTailCalls(inlined, counts)

  for function in inlined:
    if not isGenerated(function.name) or counts.calls[function.name] > 0: result.add function
  for function in result.mitems:
    function.commands = optimizeFunction(function.name, function.commands)

# ---- macro arguments of generated functions

func hasMacroText(command: Command): bool =
  var text = ""
  text.renderCommand("", command)
  "$(" in text

func usesArguments(command: Command, needs: HashSet[string]): bool =
  case command
  of FunctionWithCommand(call):
    case call.arguments
    of CompoundArguments:
      if isGenerated(call.name): return call.name in needs
    else: discard
  # The wrapper and its run are checked apart, so a call inside counts only as itself.
  of ExecuteCommand, ExecuteRawCommand, StoreResultCommand, ReturnRunCommand:
    let wrapper = withRun(command, RawCommand(raw: ""))
    return hasMacroText(wrapper) or usesArguments(runOf(command)[], needs)
  else: discard
  hasMacroText(command)

func withoutArguments(command: Command, needs: HashSet[string]): Command =
  case command
  of FunctionWithCommand(call):
    case call.arguments
    of CompoundArguments:
      if isGenerated(call.name) and call.name notin needs:
        return FunctionCommand(function: call.name)
    else: discard
  of ExecuteCommand, ExecuteRawCommand, StoreResultCommand, ReturnRunCommand:
    return withRun(command, withoutArguments(runOf(command)[], needs))
  else: discard
  command

func dropUnusedArguments*(functions: var seq[McFunction]) =
  ## A generated body gets the macro arguments of its mcfun (`{amount:"$(amount)"}`) only if it, or
  ## a body that it calls, has a macro line. The others are called without them, so a value with a
  ## `"` in it cannot break the call.
  var needs: HashSet[string]
  var isChanged = true
  while isChanged:
    isChanged = false
    for function in functions:
      if not isGenerated(function.name) or function.name in needs: continue
      for command in function.commands:
        if not usesArguments(command, needs): continue
        needs.incl function.name
        isChanged = true
        break
  for function in functions.mitems:
    var commands: seq[Command]
    for command in function.commands: commands.add withoutArguments(command, needs)
    function.commands = commands
