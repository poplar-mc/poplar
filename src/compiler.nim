## Changes the AST into IR, and builds `poplar/load`. A mistake records a diagnostic and raises `ReportedError`;
## `compileBlock` recovers per statement, and `addProgram` per declaration.
##
## The compiler is one module in several files: this one, and the files in `compiler/` that it includes. They call
## each other, so the procs that they share are declared before the includes.

import std/[algorithm, math, options, sequtils, sets, strformat, strutils, tables]
from std/unicode import Rune, toUTF8
import ast except Command, Execute, Program, DataFile
import command_tree, config, data_folders, datapack_writer, diagnostic, environment, ir, json_scanner, optimizer

type
  Origin* = enum
    ## Where a source file comes from: the project's `src/` folder or the standard library.
    orProject, orStd

  McfunDeclaration* = object
    path*: string
    mcfun*: Mcfun
    origin*: Origin
    namespace*: string ## The namespace of the file, and the namespaces it imports.
    imports*: seq[NamespaceName]
    irName*: string ## The name in the IR: `combat:heal`, or `heal` in the pack namespace.

  EventKind = enum
    ekCriteria, ekTrigger, ekFirstJoin, ekJoin, ekRespawn

  EventSource* = object
    ## What starts an event. `onEvent` and `onDeath` count a criteria. A trigger is the objective name of
    ## `onTrigger`: it is disabled after each use, so `poplar/tick` enables it again. The player events are fixed
    ## patterns (see `appendEventFunctions`).
    case
    of CriteriaSource: criteria*: string
    of TriggerSource: trigger*: string
    of FirstJoinSource, JoinSource, RespawnSource: discard

  FoundMcfun = object
    key: string ## `combat:heal`, the key in `mcfuns` and `mcfunCalls`.
    declaration: McfunDeclaration

  Event* = object
    ## `onEvent(criteria, callback)`: the game counts the criteria in `<ns>.event_<n>`,
    ## and `poplar/tick` runs the callback. `onTrigger(name, callback)` is the same
    ## with a `trigger` objective called `name`, so players can run `/trigger <name>`.
    source*: EventSource
    callback*: string ## The IR name of the callback mcfun.
    namespace*: Option[string]
      ## The output namespace of the `load` that registered
      ## it. The objective is `<namespace>.event_<n>`.

  GlobalScore* = object
    path*: string
    position*: Position
    initialValue*: int32
    name*: string
    outputNamespace*: Option[string] ## None for the pack namespace.

  InsertSource* = object
    case
    of DataSource: path*: DataPath
    of ValueSource:
      expression*: Expression
        ## A score, math or a value call, computed just before the helper is called.

  Insert* = object
    ## A runtime value in `{{...}}`: `{{$stats.hp}}` is `$(stats_hp)` in the
    ## macro line. A macro argument is a top-level key, so any value that is not
    ## a whole `$` var is copied into `<ns>:poplar macro` under its name first.
    macroName*: string
    source*: InsertSource

  CommandText* = object
    text*: string
    textStarts*: seq[int]
      ## Where each part starts in `text`, for mapping errors back to the source.
    isMacro*: bool ## True if a `{{$x}}` insert makes the text a macro line for a helper function.
    usesMacroKeys*: bool
    inserts*: seq[Insert] ## The runtime values that the text uses, each one time.

  LocalOrigin = object
    name, owner: string

  LocalVariable* = object
    name*: string
    local*: Local
    path*: string
    position*: Position

  GlobalData* = object
    path*: string
    position*: Position
    initialSnbt*: string ## The initial value as SNBT: `20`, `20f`, `{hp:20}`.
    name*: string
    outputNamespace*: Option[string] ## None for the pack namespace.
    storage*: Storage

  Condition* = object
    ## Checks in OR-of-ANDs form: the condition is true if every check in one clause passes.
    case
    of ConstantCondition: isTrue*: bool
    of ClausesCondition: clauses*: seq[seq[Check]]

  NamedDataFile* = object
    typeWord*: string
    id*: string
    path*: string
    position*: Position

  Scope* = object
    ## The namespace of the file or mcfun being compiled, the
    ## namespaces it imports, and where its files go (none: the pack).
    namespace*: string = "ns"
    imports*: seq[NamespaceName]
    outputNamespace*: Option[string]

  CurrentMcfun* = object
    ## What the compiler knows about the mcfun that it is compiling. Assigning a new one resets it all.
    folder*: string
      ## The mcfun as it appears in generated names (`generatedFolder`): `heal`, or `std.clamp` for std.
    name*, key*: string
      ## The IR name (`combat:heal`), and the key with the
      ## source namespace (`combat:heal`, `std:clamp`).
    tempCount*, generatedCount*: int
    macroKeys*: OrderedSet[string] ## The `$(name)` keys that it uses.
    forwardedArgs*: Option[string]
      ## `{a:"$(a)"}` for the macro arguments that it uses.
      ## Calls to its generated functions pass it on.
    loop*: Option[string] ## The test function of the innermost `while`, for `break` and `continue`.
    returnThroughBody*: bool
      ## True in a `while` or `execute (...)` body. There `return` stores the value and returns 1,
      ## so the caller can pass it on.
    inLoad*: bool ## True in a namespace's `mcfun load`. Only there `onEvent` is allowed.
    cleanup*: seq[Command]
      ## Removes each of its data locals. It runs at each
      ## exit, so no value is left for the next call.
    liveLocals*: seq[Local]
      ## The locals that are visible at the statement being compiled. A recursive call saves them.

  Compiler* = ref object
    commandTree*: CommandTree
    mcfuns*: OrderedTable[string, McfunDeclaration]
    globals*: OrderedTable[string, GlobalScore]
    dataGlobals*: OrderedTable[string, GlobalData]
    constants: seq[int32]
    errors*: seq[Diagnostic]
    generated: seq[McFunction]
    path: string
      ## Where the compiler is: this file, `position` for errors, `scope` and `mcfun`.
    position: Position
    scope: Scope
    mcfun: CurrentMcfun
    namespaceImports*: OrderedTable[string, OrderedSet[string]]
      ## The imports of each namespace, from all its files. They
      ## decide the order of the `load` and `tick` functions.
    loadNamespaces, tickNamespaces: OrderedSet[string]
      ## The namespaces with an `mcfun load` or `mcfun tick`.
    mcfunCalls: Table[string, OrderedSet[string]] ## For each mcfun, the mcfuns that its body calls.
    usesStack: bool
      ## Set when a recursive call saves temps, so that `poplar/load` clears the stack.
    packNamespace*: string = "ns"
      ## The namespace of the pack. `text(#hp)` writes it into a text component.
    events: seq[Event]
    localNames: Table[string, LocalOrigin]
      ## `#i_countdown` → where it comes from, so two
      ## different locals cannot get the same generated name.
    locals*: seq[LocalVariable] ## Every local declaration, for the language server.
    dataFiles: seq[DataFile]
    dataFilePaths: Table[string, string]
      ## `data/<ns>/<folder>/<path>.json` → where it is
      ## declared, so two declarations cannot write one file.
    dataFileNames*: OrderedTable[string, string]
      ## The file path of each data file of a namespace, by its source name: `combat:isSitting` →
      ## `is_sitting`, `combat:checks/never` → itself. `self:name` and `ns:name` in Minecraft text
      ## look names up here and in `mcfuns`.
    poplarNamespaces: seq[string] = @["self"]
      ## `self`, `std` and the namespaces of the project's files: the ones whose ids in commands can
      ## be Poplar names.
    fileNamespaces*: Table[string, string]
      ## The namespace of each source file (by its display path), for the language server.
    namedDataFiles*: OrderedTable[string, NamedDataFile]
      ## The data files with an identifier name, for the language server.

const globalHolder* = "#global"
  ## The holder of the global value of each `#var`. A `#` holder is hidden from the sidebar.

const stdNamespace* = "std"
  ## The namespace of the standard library. Its files are written into the pack namespace, under `std/`.

const eventBuiltins = {"onEvent": ekCriteria, "onTrigger": ekTrigger, "onDeath": ekCriteria,
                       "onFirstJoin": ekFirstJoin, "onJoin": ekJoin, "onRespawn": ekRespawn}.toTable
  ## The event builtins, and the kind of event each one registers.

proc initCompiler*(commandTree: CommandTree): Compiler =
  Compiler(commandTree: commandTree)

# ---- errors and positions

proc addError(compiler: Compiler, message: string) =
  compiler.errors.add Diagnostic(path: compiler.path, position: some(compiler.position), message: message)

proc fail(compiler: Compiler, message: string) {.noreturn.} =
  ## Records an error and stops the statement that is being compiled.
  compiler.addError(message)
  raise newException(ReportedError, message)

proc failOn(compiler: Compiler, expression: Expression, message: string) {.noreturn.} =
  ## The same as `fail`, at an expression. The statement stops, so its position is not restored here.
  compiler.position = expression.position
  compiler.fail(message)

proc failAt(compiler: Compiler, column: int, message: string) {.noreturn.} =
  ## The same as `fail`, at a column of the current line.
  compiler.errors.add Diagnostic(path: compiler.path, position: some(Position(line: compiler.position.line,
                                                                                column: column)), message: message)
  raise newException(ReportedError, message)

proc enterExpression(compiler: Compiler, expression: Expression): Position =
  ## Errors inside an expression point to where it starts. Returns the outer position to restore.
  result = compiler.position
  compiler.position = expression.position

# ---- small helpers on the AST

func identifierOf(expression: Expression): Option[Identifier] =
  case expression
  of NameExpression(identifier): some(identifier)
  else: none(Identifier)

func callOf(expression: Expression): Option[Call] =
  case expression
  of CallExpression(call): some(call)
  else: none(Call)

func calleeName(call: Call): string =
  ## The name of a call whose callee is known to be a name.
  identifierOf(call.callee).get.name

func pathRoot*(path: string): string =
  ## `stats` in `stats.inventory[0]`.
  let stop = path.find({'.', '['})
  if stop < 0: path else: path[0 ..< stop]

func isJump(statement: Statement): bool =
  case statement
  of ReturnStatement, BreakStatement, ContinueStatement: true
  else: false

proc newGeneratedName(compiler: Compiler, kind: string): string =
  let path = &"poplar/{compiler.mcfun.folder}/{kind}_{compiler.mcfun.generatedCount}"
  inc compiler.mcfun.generatedCount
  if compiler.scope.outputNamespace.isSome: compiler.scope.outputNamespace.get & ":" & path else: path

# ---- macro keys

proc collectTextMacroKeys(text: string, keys: var OrderedSet[string]) =
  var rest = text
  while true:
    let start = rest.find("$(")
    if start < 0: return
    let stop = rest.find(')', start)
    if stop < 0: return
    keys.incl rest[start + 2 ..< stop]
    rest = rest[stop + 1 .. ^1]

proc collectExpressionMacroKeys(expression: Expression, keys: var OrderedSet[string])

proc collectPartsMacroKeys(parts: seq[CommandPart], keys: var OrderedSet[string]) =
  for part in parts:
    case part
    of TextPart(text): collectTextMacroKeys(text, keys)
    of InsertPart(insert): collectExpressionMacroKeys(insert, keys)

proc collectExpressionMacroKeys(expression: Expression, keys: var OrderedSet[string]) =
  case expression
  of MacroKey(key): keys.incl key
  of PrefixExpression(prefix): collectExpressionMacroKeys(prefix.operand, keys)
  of InfixExpression(infix):
    collectExpressionMacroKeys(infix.left, keys)
    collectExpressionMacroKeys(infix.right, keys)
  of CallExpression(call):
    for arg in call.args: collectExpressionMacroKeys(arg, keys)
    if call.with.isSome:
      case call.with.get
      of WithValue(value): collectExpressionMacroKeys(value, keys)
      of WithRaw(raw): collectTextMacroKeys(raw, keys)
  of ListExpression(elements):
    for element in elements: collectExpressionMacroKeys(element, keys)
  of CompoundExpression(entries):
    for entry in entries: collectExpressionMacroKeys(entry.value, keys)
  of MinecraftCheck(parts): collectPartsMacroKeys(parts, keys)
  else: discard

proc collectMacroKeys*(body: seq[Statement], keys: var OrderedSet[string]) =
  ## The `$(name)` keys that a body uses, in expressions and in Minecraft text.
  for statement in body:
    case statement
    of VarDeclStatement(varDecl): collectExpressionMacroKeys(varDecl.value, keys)
    of AssignStatement(assign): collectExpressionMacroKeys(assign.value, keys)
    of ReturnStatement(returned):
      if returned != nil: collectExpressionMacroKeys(returned, keys)
    of BreakStatement, ContinueStatement: discard
    of IfStatement(ifStatement):
      collectExpressionMacroKeys(ifStatement.condition, keys)
      collectMacroKeys(ifStatement.thenBody, keys)
      if ifStatement.elseBody.isSome: collectMacroKeys(ifStatement.elseBody.get, keys)
    of WhileStatement(whileLoop):
      collectExpressionMacroKeys(whileLoop.condition, keys)
      collectMacroKeys(whileLoop.body, keys)
    of ForStatement(forLoop):
      collectExpressionMacroKeys(forLoop.start, keys)
      collectExpressionMacroKeys(forLoop.stop, keys)
      collectMacroKeys(forLoop.body, keys)
    of CommandStatement(command): collectPartsMacroKeys(command.parts, keys)
    of ExecuteStatement(execute):
      collectPartsMacroKeys(execute.subcommands, keys)
      collectMacroKeys(execute.body, keys)
    of ExpressionStatement(expression): collectExpressionMacroKeys(expression, keys)

# ---- jumps

type Jumps* = object
  ## What a body can jump with. A `break` or `continue` in an inner `while` belongs to that loop, and `execute (...)`
  ## cannot have one. A `return` leaves every level.
  hasReturn*, hasBreak*, hasContinue*: bool

proc merge(jumps: var Jumps, other: Jumps) =
  jumps.hasReturn = jumps.hasReturn or other.hasReturn
  jumps.hasBreak = jumps.hasBreak or other.hasBreak
  jumps.hasContinue = jumps.hasContinue or other.hasContinue

func any(jumps: Jumps): bool = jumps.hasReturn or jumps.hasBreak or jumps.hasContinue

func jumpsIn*(body: seq[Statement]): Jumps

func jumpsInIf(ifStatement: If): Jumps =
  result = jumpsIn(ifStatement.thenBody)
  result.merge(jumpsIn(ifStatement.elseBody.get(@[])))

func jumpsIn*(body: seq[Statement]): Jumps =
  for statement in body:
    case statement
    of ReturnStatement: result.hasReturn = true
    of BreakStatement: result.hasBreak = true
    of ContinueStatement: result.hasContinue = true
    of IfStatement(ifStatement): result.merge(jumpsInIf(ifStatement))
    of ForStatement(forLoop): result.merge(jumpsIn(forLoop.body))
    of WhileStatement(whileLoop): result.hasReturn = result.hasReturn or jumpsIn(whileLoop.body).hasReturn
    of ExecuteStatement(execute): result.hasReturn = result.hasReturn or jumpsIn(execute.body).hasReturn
    else: discard

func branchesEndWithJump(ifStatement: If): bool

func endsWithJump(body: seq[Statement]): bool =
  if body.len == 0: return false
  case body[^1]
  of ReturnStatement, BreakStatement, ContinueStatement: true
  of IfStatement(ifStatement): ifStatement.elseBody.isSome and branchesEndWithJump(ifStatement)
  else: false

func branchesEndWithJump(ifStatement: If): bool =
  ## True if the then body and every `else if` and `else` body end with `return`, `break` or `continue`. The final
  ## `else` is optional.
  if not endsWithJump(ifStatement.thenBody): return false
  if ifStatement.elseBody.isNone: return true
  let elseBody = ifStatement.elseBody.get
  if elseBody.len == 1:
    case elseBody[0]
    of IfStatement(elseIf): return branchesEndWithJump(elseIf)
    else: discard
  endsWithJump(elseBody)

# ---- forward declarations of the procs that the included files share

func valueToSnbt(value: Value): string
proc evaluate(compiler: Compiler, expression: Expression, env: Environment): Value
proc compileInto(compiler: Compiler, target: Score, expression: Expression, env: Environment,
                 commands: var seq[Command])
func utf16Length(text: string): Option[int]
proc isDataIdentifier(expression: Expression): bool
proc dataPathOf(compiler: Compiler, identifier: Identifier, env: Environment): DataPath
func isStringCall(call: Call): bool
func isStringTest(call: Call): bool
proc compileStringInto(compiler: Compiler, target: DataPath, call: Call, env: Environment,
                       commands: var seq[Command])
proc compileDataAssign(compiler: Compiler, target: DataPath, expression: Expression, env: Environment,
                       commands: var seq[Command])
proc textComponent(compiler: Compiler, argument: Expression, env: Environment): Value
proc stringTest(compiler: Compiler, call: Call, env: Environment, negated: bool,
                setup: var seq[Command]): Condition
proc evaluateStringCall(compiler: Compiler, call: Call, env: Environment): Value
proc compileLength(compiler: Compiler, target: Score, call: Call, env: Environment, commands: var seq[Command])
func isBuiltin(name: string): bool
func isBuiltinCall(call: Call, name: string): bool
proc compileMcfunCall(compiler: Compiler, call: Call, declaration: McfunDeclaration, env: Environment,
                      commands: var seq[Command]): Command
proc appendWithSavedValues(compiler: Compiler, call: Command, target: Option[Score], liveTempCount: int,
                           commands: var seq[Command])
proc calledKey(compiler: Compiler, identifier: Identifier): Option[string]
proc collectExpressionCalls(compiler: Compiler, expression: Expression, calls: var OrderedSet[string])
proc canReach(compiler: Compiler, start, goal: string): bool
func qualifiedKey(namespace, name: string): string
proc resolveNamespace(compiler: Compiler, namespace: Option[string]): string
proc findMcfun(compiler: Compiler, identifier: Identifier): FoundMcfun
proc compileEvent(compiler: Compiler, call: Call, builtin: string, env: Environment)
proc buildCommandText(compiler: Compiler, parts: seq[CommandPart], env: Environment): CommandText
proc checkMinecraftText(compiler: Compiler, parts: seq[CommandPart], built: CommandText, column: int,
                        prefix, suffix: string): string
proc scopeOf(compiler: Compiler, namespace: string, imports: seq[NamespaceName]): Scope
proc compileJumpBody(compiler: Compiler, body: seq[Statement], env: Environment,
                     loop: Option[string]): Option[Command]
proc compileStatement(compiler: Compiler, statement: Statement, env: Environment, commands: var seq[Command])

include compiler/[values, scores, conditions, data, calls, declarations, load, minecraft_text]

# ---- statements

proc scopeOf(compiler: Compiler, namespace: string, imports: seq[NamespaceName]): Scope =
  Scope(namespace: namespace, imports: imports, outputNamespace: outputNamespace(compiler, namespace))

proc resultScore(compiler: Compiler): Score =
  ## The value of a `return` inside a `while` or `execute (...)` body, on its way out.
  resultScore(compiler.mcfun.folder, compiler.scope.outputNamespace)

proc onBodyReturn(compiler: Compiler, bodyName: string): Command =
  ## `execute if function <body> run ...`: when the body returned, return from this function too.
  let passOn = if compiler.mcfun.returnThroughBody: ReturnValueCommand(returnValue: 1)
               else: ReturnRunCommand(returnRun: createCommand(ScoreGetCommand(score: compiler.resultScore())))
  let checks = @[Check(negated: false, condition: FunctionReturnsTest(function: bodyName))]
  ExecuteCommand(execute: Execute(checks: checks, run: createCommand(passOn)))

proc compileBlock(compiler: Compiler, body: seq[Statement], env: Environment, commands: var seq[Command]) =
  let outerLiveCount = compiler.mcfun.liveLocals.len
  defer: compiler.mcfun.liveLocals.setLen(outerLiveCount)

  for index, statement in body:
    recover: compiler.compileStatement(statement, env, commands)

    if statement.isJump and index + 1 < body.len:
      compiler.errors.add Diagnostic(path: compiler.path, position: some(body[index + 1].position),
                                     message: "code after 'return', 'break' or 'continue' is never run")
      return

proc compileBodyAsCommand(compiler: Compiler, body: seq[Statement], env: Environment,
                          kind: string): Option[Command] =
  ## `kind` names a generated function for a body with more than one command: `if` or `execute`.
  let branchEnv = Environment(outer: env, runtimeBranch: true)
  var bodyCommands: seq[Command]
  compiler.compileBlock(body, branchEnv, bodyCommands)

  case bodyCommands.len
  of 0: none(Command)
  of 1: some(bodyCommands[0])
  else:
    let name = compiler.newGeneratedName(kind)
    compiler.generated.add McFunction(name: name, commands: bodyCommands)
    some(generatedCall(compiler, name))

proc compileJumpBody(compiler: Compiler, body: seq[Statement], env: Environment,
                     loop: Option[string]): Option[Command] =
  ## Compiles an `execute (...)` body. A body that can `return` is always a function, called as
  ## `if function ...`: it returns 1 for each entity that returns from the mcfun, and then the mcfun returns.
  let outerLoop = compiler.mcfun.loop
  let outerThroughBody = compiler.mcfun.returnThroughBody
  compiler.mcfun.loop = loop
  compiler.mcfun.returnThroughBody = true
  defer:
    compiler.mcfun.loop = outerLoop
    compiler.mcfun.returnThroughBody = outerThroughBody

  if not jumpsIn(body).hasReturn: return compiler.compileBodyAsCommand(body, env, "execute")

  let branchEnv = Environment(outer: env, runtimeBranch: true)
  var bodyCommands: seq[Command]
  compiler.compileBlock(body, branchEnv, bodyCommands)
  let name = compiler.newGeneratedName("execute")
  compiler.generated.add McFunction(name: name, commands: bodyCommands)

  compiler.mcfun.returnThroughBody = outerThroughBody
  some(compiler.onBodyReturn(name))

proc localKey(compiler: Compiler, name: string): string =
  ## `#i` in `mcfun countdown` is `i_countdown`, with a `#` in front for a score.
  name & "_" & compiler.mcfun.folder

proc declareLocal(compiler: Compiler, kind: LocalKind, varDecl: VarDecl, env: Environment,
                  commands: var seq[Command]) =
  ## `var #i = 10;` in `mcfun countdown` is the fake player `#i_countdown` in `<ns>`. `var $names = [];` is
  ## `names_countdown` in `<ns>:data`. The value is set here, on every call.
  let name = varDecl.target.name
  let sigil = if kind == lkScore: '#' else: '$'
  if kind == lkData and pathRoot(name).len != name.len:
    compiler.fail(&"'var' declares a whole variable. Set '${name}' after it")
  let globalKey = qualifiedKey(compiler.scope.namespace, name)
  let isGlobal = if kind == lkScore: globalKey in compiler.globals else: globalKey in compiler.dataGlobals
  let key = sigil & name
  if isGlobal or env.getLocal(kind, name).isSome: compiler.fail(&"'{key}' is already declared")

  let generatedBase = compiler.localKey(name)
  let generatedName = if kind == lkScore: "#" & generatedBase else: generatedBase

  let origin = LocalOrigin(name: name, owner: compiler.mcfun.folder)
  let nameKey = sigil & generatedBase
  if nameKey in compiler.localNames and compiler.localNames[nameKey] != origin:
    let other = compiler.localNames[nameKey]
    compiler.fail(&"'{sigil}{other.name}' in '{other.owner}' and '{sigil}{name}' in '{compiler.mcfun.folder}' both " &
                  &"become '{generatedName}'. Rename one")
  compiler.localNames[nameKey] = origin

  let local = Local(kind: kind, generatedName: generatedName, owner: compiler.mcfun.name)
  case kind
  of lkScore:
    compiler.mcfun.tempCount = 0
    let target = localScore(generatedName, compiler.mcfun.name, compiler.scope.outputNamespace)
    compileInto(compiler, target, varDecl.value, env, commands)
  of lkData:
    compileDataAssign(compiler, dataLocal(compiler, generatedName), varDecl.value, env, commands)

  env.declareLocal(name, local)
  compiler.mcfun.liveLocals.add local
  for existing in compiler.locals:
    if existing.position == compiler.position and existing.path == compiler.path: return
  compiler.locals.add LocalVariable(name: name, local: local, path: compiler.path, position: compiler.position)

proc compileVarDecl(compiler: Compiler, varDecl: VarDecl, env: Environment, commands: var seq[Command]) =
  case varDecl.target.kind
  of ikCompileTime: discard
  of ikScore:
    compiler.declareLocal(lkScore, varDecl, env, commands)
    return
  of ikData:
    compiler.declareLocal(lkData, varDecl, env, commands)
    return
  of ikEntityData: compiler.fail("entity data cannot be declared with 'var'. Set it: '@s.$path = ...;'")
  let name = varDecl.target.name
  if containsRuntimeValue(varDecl.value):
    compiler.fail(&"'{name}' is a build-time constant, but this value only exists in the game. Use 'var #{name}' " &
                  &"for a score or 'var ${name}' for data")

  let value = evaluate(compiler, varDecl.value, env)
  if not env.declare(name, value): compiler.fail(&"'{name}' is already declared")

proc collectDataLocalNames(body: seq[Statement], names: var OrderedSet[string]) =
  for statement in body:
    case statement
    of VarDeclStatement(varDecl):
      if varDecl.target.kind == ikData: names.incl varDecl.target.name
    of IfStatement(ifStatement):
      collectDataLocalNames(ifStatement.thenBody, names)
      if ifStatement.elseBody.isSome: collectDataLocalNames(ifStatement.elseBody.get, names)
    of WhileStatement(whileLoop): collectDataLocalNames(whileLoop.body, names)
    of ForStatement(forLoop): collectDataLocalNames(forLoop.body, names)
    of ExecuteStatement(execute): collectDataLocalNames(execute.body, names)
    else: discard

proc localCleanup(compiler: Compiler, body: seq[Statement]): seq[Command] =
  ## `data remove` for each data local declared anywhere in the body. A failed `set from` keeps the old value, so
  ## without this a local could hold a value from an earlier call. `data remove` on a missing key fails without
  ## effect. A score local needs nothing: every score write (`set`, `operation`, `store result`) overwrites it, and a
  ## failure writes 0.
  var names: OrderedSet[string]
  collectDataLocalNames(body, names)
  for name in names: result.add DataRemoveCommand(dataPath: dataLocal(compiler, compiler.localKey(name)))

proc compileAssign(compiler: Compiler, assign: Assign, env: Environment, commands: var seq[Command]) =
  case assign.target.kind
  of ikCompileTime: discard
  of ikScore:
    compileScoreAssign(compiler, assign.target, assign.value, env, commands)
    return
  of ikData:
    compileDataAssign(compiler, dataPath(compiler, assign.target, env), assign.value, env, commands)
    return
  of ikEntityData:
    compileDataAssign(compiler, entityDataPath(compiler, assign.target), assign.value, env, commands)
    return

  if containsRuntimeValue(assign.value): compiler.fail("a runtime value cannot be stored in a compile-time variable")

  let value = evaluate(compiler, assign.value, env)
  case env.assign(assign.target.name, value)
  of arAssigned: discard
  of arNotFound: compiler.fail(&"unknown name '{assign.target.name}'")
  of arCrossesRuntimeBranch:
    compiler.fail(&"cannot change compile-time '{assign.target.name}' inside a runtime 'if' or 'execute'")

proc returnRun(command: Command): Command =
  ## Wraps a command in `return run`, unless it already returns.
  case command
  of ReturnRunCommand, ReturnValueCommand, ReturnMacroArgumentCommand: command
  else: ReturnRunCommand(returnRun: createCommand(command))

proc appendBranches(compiler: Compiler, ifStatement: If, env: Environment, wrapper: var seq[Command],
                    condition: Condition, setup: seq[Command], afterRuntimeBranch: bool) =
  ## Each branch returns from the wrapper, so later branches and the else body run only if no earlier branch ran.
  wrapper.add setup

  case condition
  of ConstantCondition(isTrue):
    if isTrue:
      let branchEnv = Environment(outer: env, runtimeBranch: afterRuntimeBranch)
      compiler.compileBlock(ifStatement.thenBody, branchEnv, wrapper)
      return
  of ClausesCondition(clauses):
    let body = compiler.compileBodyAsCommand(ifStatement.thenBody, env, "if")
    let run = if body.isSome: returnRun(body.get) else: ReturnValueCommand(returnValue: 0)
    let runPointer = createCommand(run)
    for checks in clauses: wrapper.add ExecuteCommand(execute: Execute(checks: checks, run: runPointer))

  let isRuntime = afterRuntimeBranch or constantOf(condition).isNone
  if ifStatement.elseBody.isNone: return
  let elseBody = ifStatement.elseBody.get

  if elseBody.len == 1:
    case elseBody[0]
    of IfStatement(elseIf):
      # The rest of the chain belongs to this `else if`. `compileStatement` restores the position after the chain.
      compiler.position = elseBody[0].position
      compiler.mcfun.tempCount = 0
      var elseSetup: seq[Command]
      let elseCondition = lowerCondition(compiler, elseIf.condition, env, false, elseSetup)
      compiler.appendBranches(elseIf, env, wrapper, elseCondition, elseSetup, isRuntime)
      return
    else: discard

  let elseEnv = Environment(outer: env, runtimeBranch: isRuntime)
  compiler.compileBlock(elseBody, elseEnv, wrapper)

proc compileIf(compiler: Compiler, ifStatement: If, env: Environment, commands: var seq[Command]) =
  compiler.mcfun.tempCount = 0
  var setup: seq[Command]
  let condition = lowerCondition(compiler, ifStatement.condition, env, false, setup)

  case condition
  of ConstantCondition(isTrue):
    let body = if isTrue: some(ifStatement.thenBody) else: ifStatement.elseBody
    if body.isNone: return
    compiler.compileBlock(body.get, Environment(outer: env), commands)
  of ClausesCondition(clauses):
    # Each returning branch returns from this function, so the branches go here directly, with no wrapper.
    if jumpsInIf(ifStatement).any:
      if not branchesEndWithJump(ifStatement):
        compiler.fail("if one branch of an 'if' contains 'return', 'break' or 'continue', every branch must end " &
                      "with one")
      compiler.appendBranches(ifStatement, env, commands, condition, setup, false)
      return

    if ifStatement.elseBody.isNone and clauses.len == 1:
      let run = compiler.compileBodyAsCommand(ifStatement.thenBody, env, "if")
      if run.isNone: return
      commands.add setup
      commands.add ExecuteCommand(execute: Execute(checks: clauses[0], run: createCommand(run.get)))
      return

    let wrapperName = compiler.newGeneratedName("if")
    var wrapper: seq[Command]
    compiler.appendBranches(ifStatement, env, wrapper, condition, setup, false)
    compiler.generated.add McFunction(name: wrapperName, commands: wrapper)
    commands.add generatedCall(compiler, wrapperName)

proc compileReturn(compiler: Compiler, value: Expression, env: Environment, commands: var seq[Command]) =
  ## `value` is nil for a `return;` with no value.
  if compiler.mcfun.returnThroughBody:
    let target = compiler.resultScore()
    compiler.mcfun.tempCount = 0
    if value != nil: compileInto(compiler, target, value, env, commands)
    else: commands.add ScoreSetCommand(scoreValue: ScoreValue(score: target, value: 0))
    commands.add compiler.mcfun.cleanup
    commands.add ReturnValueCommand(returnValue: 1)
    return

  if value == nil:
    commands.add compiler.mcfun.cleanup
    commands.add ReturnValueCommand(returnValue: 0)
    return

  if not containsRuntimeValue(value):
    let number = compiler.toScoreValue(evaluate(compiler, value, env))
    commands.add compiler.mcfun.cleanup
    commands.add ReturnValueCommand(returnValue: number)
    return

  compiler.mcfun.tempCount = 0
  case value
  of MacroKey(key):
    commands.add compiler.mcfun.cleanup
    commands.add ReturnMacroArgumentCommand(returnMacroArgument: key)
    return
  else: discard
  # The value can read a local, so it is computed before the locals are removed.
  if compiler.mcfun.cleanup.len > 0:
    let temp = compiler.newTemp()
    compileInto(compiler, temp, value, env, commands)
    commands.add compiler.mcfun.cleanup
    commands.add ReturnRunCommand(returnRun: createCommand(ScoreGetCommand(score: temp)))
    return

  var read: Option[Command]
  let identifier = identifierOf(value)
  if identifier.isSome:
    case identifier.get.kind
    of ikData, ikEntityData: read = some(DataGetCommand(dataPath: dataPathOf(compiler, identifier.get, env)))
    of ikScore: read = some(ScoreGetCommand(score: scoreSource(compiler, identifier.get, env)))
    of ikCompileTime: discard
  if read.isNone:
    let temp = compiler.newTemp()
    compileInto(compiler, temp, value, env, commands)
    read = some(ScoreGetCommand(score: temp))
  commands.add ReturnRunCommand(returnRun: createCommand(read.get))

proc compileWhile(compiler: Compiler, whileLoop: While, env: Environment, commands: var seq[Command]) =
  ## A loop is two functions: `while_<n>` tests the condition
  ## and runs `while_<n>_body`, which runs `while_<n>` again.
  let jumps = jumpsIn(whileLoop.body)
  let testName = compiler.newGeneratedName("while")
  let bodyName = testName & "_body"

  compiler.mcfun.tempCount = 0
  var testCommands: seq[Command]
  let condition = lowerCondition(compiler, whileLoop.condition, env, false, testCommands)
  var clauses: seq[seq[Check]]
  case condition
  of ConstantCondition(isTrue):
    if not isTrue: return
    if not jumps.hasReturn and not jumps.hasBreak:
      compiler.fail("this 'while' never stops: add a 'break' or 'return', or use a score or data value in the " &
                    "condition")
    # `while (true)` runs the body with no check. It must be able to stop.
    clauses = @[newSeq[Check]()]
  of ClausesCondition(conditionClauses): clauses = conditionClauses

  let canReturn = jumps.hasReturn
  # `continue` and a passed-on `return` use the result of the test, so then the test must always give one.
  let readsTestResult = canReturn or jumps.hasContinue

  # `return run` stops the next clause from running the body again, and passes a return of the body on.
  let callBody = generatedCall(compiler, bodyName)
  let runBody = createCommand(if clauses.len > 1 or canReturn: ReturnRunCommand(returnRun: createCommand(callBody))
                              else: callBody)
  for checks in clauses:
    testCommands.add(if checks.len == 0: runBody[] else: ExecuteCommand(execute: Execute(checks: checks, run: runBody)))
  if readsTestResult: testCommands.add ReturnValueCommand(returnValue: 0)

  let outerLoop = compiler.mcfun.loop
  let outerThroughBody = compiler.mcfun.returnThroughBody
  compiler.mcfun.loop = some(testName)
  compiler.mcfun.returnThroughBody = true

  var bodyCommands: seq[Command]
  compiler.compileBlock(whileLoop.body, Environment(outer: env, runtimeBranch: true), bodyCommands)
  let callTest = generatedCall(compiler, testName)
  bodyCommands.add(if canReturn: ReturnRunCommand(returnRun: createCommand(callTest)) else: callTest)

  compiler.mcfun.loop = outerLoop
  compiler.mcfun.returnThroughBody = outerThroughBody

  compiler.generated.add McFunction(name: testName, commands: testCommands)
  compiler.generated.add McFunction(name: bodyName, commands: bodyCommands)

  if not canReturn:
    commands.add callTest
    return
  if compiler.mcfun.forwardedArgs.isNone:
    commands.add compiler.onBodyReturn(testName)
    return

  # `if function` cannot pass the macro arguments, so the result of the loop goes through a temp.
  let returned = compiler.newTemp()
  commands.add StoreResultCommand(storeResult: StoreResult(target: ScoreTarget(score: returned),
                                                           run: createCommand(callTest)))
  var passOn: ref Command
  case compiler.onBodyReturn(testName)
  of ExecuteCommand(execute): passOn = execute.run
  else: discard
  let checks = @[Check(negated: false, condition: MatchesTest(matches: Matches(score: returned, min: some(1'i32),
                                                                              max: some(1'i32))))]
  commands.add ExecuteCommand(execute: Execute(checks: checks, run: passOn))

proc evaluateRange(compiler: Compiler, forLoop: For, env: Environment): (int64, int64) =
  let start = evaluate(compiler, forLoop.start, env)
  let stop = evaluate(compiler, forLoop.stop, env)
  let (startNumber, stopNumber) = (numberOf(start), numberOf(stop))
  if startNumber.isNone or stopNumber.isNone: compiler.fail("range bounds must be whole numbers")
  if startNumber.get > stopNumber.get:
    compiler.fail(&"range start {startNumber.get} is greater than end {stopNumber.get}")
  (startNumber.get, stopNumber.get)

proc compileFor(compiler: Compiler, forLoop: For, env: Environment, commands: var seq[Command]) =
  let (start, stop) = compiler.evaluateRange(forLoop, env)
  var index = start
  while index < stop:
    let loopEnv = Environment(outer: env)
    if not loopEnv.declare(forLoop.capture, NumberValue(number: index)):
      compiler.fail(&"'{forLoop.capture}' is already declared")

    let errorCount = compiler.errors.len
    compiler.compileBlock(forLoop.body, loopEnv, commands)
    if compiler.errors.len > errorCount: return
    inc index

proc compileStatement(compiler: Compiler, statement: Statement, env: Environment, commands: var seq[Command]) =
  let outerPosition = compiler.position
  compiler.position = statement.position
  defer: compiler.position = outerPosition

  case statement
  of ExpressionStatement(expression):
    compiler.position = expression.position
    let call = callOf(expression)
    if call.isNone: compiler.fail("only calls can be used as statements")
    compileCall(compiler, call.get, env, commands)
  of VarDeclStatement(varDecl): compiler.compileVarDecl(varDecl, env, commands)
  of AssignStatement(assign): compiler.compileAssign(assign, env, commands)
  of ForStatement(forLoop): compiler.compileFor(forLoop, env, commands)
  of ReturnStatement(returned): compiler.compileReturn(returned, env, commands)
  of BreakStatement:
    if compiler.mcfun.loop.isNone: compiler.fail("'break' must be inside a 'while' (not in 'execute (...)')")
    commands.add ReturnValueCommand(returnValue: 0)
  of ContinueStatement:
    if compiler.mcfun.loop.isNone: compiler.fail("'continue' must be inside a 'while' (not in 'execute (...)')")
    commands.add ReturnRunCommand(returnRun: createCommand(generatedCall(compiler, compiler.mcfun.loop.get)))
  of WhileStatement(whileLoop): compiler.compileWhile(whileLoop, env, commands)
  of IfStatement(ifStatement): compiler.compileIf(ifStatement, env, commands)
  of CommandStatement(command): compileCommand(compiler, command, statement.position.column + 1, env, commands)
  of ExecuteStatement(execute): compileExecute(compiler, execute, env, commands)

# ---- mcfuns and programs

proc forwardedArguments(keys: OrderedSet[string]): Option[string] =
  ## `{a:"$(a)",b:"$(b)"}`, or none when the mcfun uses no macro arguments.
  if keys.len == 0: return none(string)
  var forwarded: seq[string]
  for key in keys: forwarded.add &"{key}:\"$({key})\""
  some("{" & forwarded.join(",") & "}")

proc compileMcfun(compiler: Compiler, mcfunKey: string, declaration: McfunDeclaration,
                  paths: var Table[string, string]): McFunction =
  ## `paths` holds the file name of each mcfun so far, so that two names cannot write one file.
  let mcfun = declaration.mcfun
  compiler.path = declaration.path
  compiler.position = mcfun.position
  compiler.scope = compiler.scopeOf(declaration.namespace, declaration.imports)

  # The file name is the snake_case of the name (`playerDied` → `player_died`), so both must be valid and unique.
  let path = functionPath(mcfun.name)
  if not isValidResourceName(path):
    compiler.fail(&"mcfun name '{mcfun.name}' must only use letters, 0-9, '_', '.' and '-'")
  let pathKey = functionName(compiler, declaration.namespace, path)
  if pathKey in paths:
    compiler.fail(&"mcfun '{paths[pathKey]}' and '{mcfun.name}' have the same file name '{path}.mcfunction'")
  paths[pathKey] = mcfun.name

  var macroKeys: OrderedSet[string]
  collectMacroKeys(mcfun.body, macroKeys)
  let isProject = declaration.origin == orProject
  let isLoad = isProject and mcfun.name == "load"
  let isHook = isLoad or (isProject and mcfun.name == "tick")
  if isHook and macroKeys.len > 0:
    compiler.fail(&"mcfun '{mcfun.name}' is run by the game, so it gets no macro arguments and cannot use " &
                  &"'$({macroKeys.toSeq[0]})'")

  compiler.mcfun = CurrentMcfun(
    folder: generatedFolder(outputPath(declaration.namespace, mcfun.name)),
    name: declaration.irName,
    key: mcfunKey,
    macroKeys: macroKeys,
    forwardedArgs: forwardedArguments(macroKeys),
    inLoad: isLoad,
  )
  compiler.mcfun.cleanup = compiler.localCleanup(mcfun.body)

  var commands: seq[Command]
  compiler.compileBlock(mcfun.body, Environment(), commands)
  if mcfun.body.len == 0 or not mcfun.body[^1].isJump: commands.add compiler.mcfun.cleanup

  McFunction(name: declaration.irName, commands: commands)

proc addProgram*(compiler: Compiler, path: string, program: ast.Program, origin: Origin) =
  ## `mcfun load` and `mcfun tick` of each namespace are run by the game. A program without a `namespace` line (in
  ## tests) is in the pack namespace.
  compiler.path = path
  let namespace = if program.namespace.isSome: program.namespace.get.name else: compiler.packNamespace
  compiler.scope = compiler.scopeOf(namespace, program.imports)
  compiler.fileNamespaces[path] = compiler.scope.namespace
  if program.namespace.isSome:
    let namespaceName = program.namespace.get
    compiler.position = namespaceName.position
    if not isValidNamespace(namespaceName.name):
      compiler.addError(&"namespace '{namespaceName.name}' must only use a-z, 0-9, '_' and '.'")
      return
    if origin == orProject and namespaceName.name == stdNamespace:
      compiler.addError("the namespace 'std' belongs to the standard library")
      return

  discard compiler.namespaceImports.hasKeyOrPut(compiler.scope.namespace, initOrderedSet[string]())
  for imported in program.imports:
    compiler.position = imported.position
    if imported.name == compiler.scope.namespace:
      compiler.addError(&"a file does not import its own namespace '{imported.name}'")
      continue
    compiler.namespaceImports[compiler.scope.namespace].incl imported.name

  for mcfun in program.mcfuns:
    if origin == orProject:
      if mcfun.name == "load": compiler.loadNamespaces.incl compiler.scope.namespace
      if mcfun.name == "tick": compiler.tickNamespaces.incl compiler.scope.namespace

    if isBuiltin(mcfun.name):
      compiler.position = mcfun.position
      compiler.addError(&"'{mcfun.name}' is a built-in function, so it cannot be defined")
      continue

    let key = qualifiedKey(compiler.scope.namespace, mcfun.name)
    let declaration = McfunDeclaration(path: path, mcfun: mcfun, origin: origin, namespace: compiler.scope.namespace,
                                       imports: program.imports,
                                       irName: functionName(compiler, compiler.scope.namespace, mcfun.name))
    if key in compiler.mcfuns:
      addDuplicateError(compiler, compiler.mcfuns[key], declaration)
      continue
    compiler.mcfuns[key] = declaration

  for global in program.globals:
    compiler.position = global.position
    recover: addGlobal(compiler, global.decl)

  for dataFile in program.dataFiles:
    compiler.position = dataFile.position
    recover: addDataFile(compiler, dataFile)

proc compile*(compiler: Compiler): Program =
  compiler.poplarNamespaces = @["self"] & compiler.namespaceImports.keys.toSeq
  var functions: seq[McFunction]
  buildCallGraph(compiler)
  let used = reachableFromProject(compiler)
  var paths: Table[string, string]

  for mcfunKey, declaration in compiler.mcfuns:
    # `import std;` costs nothing for the std mcfuns that the project never calls.
    if declaration.origin == orStd and mcfunKey notin used: continue
    try:
      functions.add compiler.compileMcfun(mcfunKey, declaration, paths)
    except ReportedError:
      continue

  functions.add compiler.generated
  dropUnusedArguments(functions)

  for function in functions.mitems: function.commands = optimizeFunction(function.name, function.commands)
  functions = inlineSmallFunctions(functions)
  removeUnusedConstants(compiler, functions)

  # Only the tick tag calls these, so they come after the inline pass, which removes functions that nothing calls.
  let ticks = hookNames(compiler, compiler.tickNamespaces, "tick")
  appendEventFunctions(compiler, functions, ticks)

  let needsLoad = compiler.globals.len + compiler.dataGlobals.len > 0 or compiler.loadNamespaces.len > 0 or
                  compiler.usesStack or compiler.events.len > 0
  Program(
    functions: functions,
    load: if needsLoad: some(buildLoadFunction(compiler, functions)) else: none(McFunction),
    tick: if compiler.events.len > 0: @["poplar/tick"] else: ticks,
    dataFiles: compiler.dataFiles,
  )
