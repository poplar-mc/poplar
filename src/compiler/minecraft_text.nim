# Minecraft text: commands, `execute` subcommands, `{{...}}` inserts, macro lines and `self:` ids.
# Part of compiler.nim.

func isWholeDataVar(insert: Insert): bool =
  ## A whole `$` var is read from `<ns>:data` as it is.
  case insert.source
  of DataSource(path):
    case path.holder
    of StorageHolder: insert.macroName == path.path
    else: false
  else: false

func macroName(path: string): string =
  ## `stats.inventory[0]` → `stats_inventory_0_`: a name that a macro line can use.
  for ch in path: result.add(if ch.isAlphaNumeric or ch == '_': ch else: '_')

func isIdChar(ch: char): bool = ch.isAlphaNumeric or ch in "_-./"

func sharedStorage(inserts: openArray[Insert]): Option[DataStorage] =
  ## The storage that holds every insert, when each one is a whole `$` variable of the same storage:
  ## the helper can then read them from it as they are.
  var shared = none(DataStorage)
  for insert in inserts:
    if not insert.isWholeDataVar: return none(DataStorage)
    var storage: DataStorage
    case insert.source
    of DataSource(path):
      case path.holder
      of StorageHolder(kind):
        if kind notin {stData, stStd}: return none(DataStorage)
        storage = DataStorage(kind: kind, namespace: path.namespace)
      else: discard
    else: discard
    if shared.isSome and (shared.get.kind != storage.kind or
                          shared.get.namespace != storage.namespace):
      return none(DataStorage)
    shared = some(storage)
  shared

func isSameInsert(a, b: InsertSource): bool =
  case a
  of DataSource(path):
    case b
    of DataSource(other): sameHolder(path.holder, other.holder) and path.path == other.path
    else: false
  of ValueSource(expression):
    case b
    of ValueSource(other):
      let (left, right) = (identifierOf(expression), identifierOf(other))
      if left.isNone or right.isNone: return false
      left.get.kind == ikScore and right.get.kind == ikScore and left.get.name == right.get.name and
        left.get.selector.get("") == right.get.selector.get("")
    else: false

proc isUsedMacroName(compiler: Compiler, name: string, used: openArray[Insert]): bool =
  used.anyIt(it.macroName == name) or name in compiler.mcfun.macroKeys

proc runtimeInsert(compiler: Compiler, expression: Expression, env: Environment,
                   used: openArray[Insert]): Insert =
  ## Where the value of a runtime insert comes from, and its macro name. The same value again in the
  ## line gives the insert that is already there.
  let outerPosition = compiler.enterExpression(expression)
  defer: compiler.position = outerPosition

  var base = "value"
  var source = ValueSource(expression: expression)
  let identifier = identifierOf(expression)
  if identifier.isSome:
    case identifier.get.kind
    of ikData, ikEntityData:
      let path = compiler.dataPathOf(identifier.get, env)
      source = DataSource(path: path)
      base = macroName(path.path)
    of ikScore: base = identifier.get.name
    of ikCompileTime: discard

  for insert in used:
    if isSameInsert(insert.source, source): return insert

  # A helper may get the macro arguments and the values in one compound, so each name must be new.
  var name = base
  var number = 2
  while compiler.isUsedMacroName(name, used):
    name = &"{base}_{number}"
    inc number
  Insert(macroName: name, source: source)

func hasUnclosedMacroKey(text: string): bool =
  ## True when a `$(` has no `)` after it, so it names no macro argument.
  var start = text.find("$(")
  while start >= 0:
    let stop = text.find(')', start)
    if stop < 0: return true
    start = text.find("$(", stop)
  false

proc buildCommandText(compiler: Compiler, parts: openArray[CommandPart],
    env: Environment): CommandText =
  ## Joins text and `{{...}}` inserts. A `{{#x}}` insert becomes `$(x)` and makes the text a macro
  ## line. `$(key)` in the text uses the mcfun's macro arguments.
  for part in parts:
    result.textStarts.add result.text.len
    case part
    of TextPart(text):
      result.text.add text
      if hasUnclosedMacroKey(text):
        compiler.fail("'$(' needs the name of a macro argument and a ')', such as '$(count)'")
      if "$(" in text: result.usesMacroKeys = true
    of InsertPart(expression):
      let outerPosition = compiler.enterExpression(expression)
      defer: compiler.position = outerPosition
      case expression
      of MacroKey(key):
        result.text.add &"$({key})"
        result.usesMacroKeys = true
        continue
      else: discard
      if containsRuntimeValue(expression):
        let insert = compiler.runtimeInsert(expression, env, result.inserts)
        result.text.add &"$({insert.macroName})"
        result.isMacro = true
        if not result.inserts.anyIt(it.macroName == insert.macroName): result.inserts.add insert
        continue
      result.text.add valueToText(compiler.evaluate(expression, env))

func sourceOffset(parts: openArray[CommandPart], textStarts: openArray[int], at: int): int =
  ## Maps an offset in the finished command back to the source. An offset inside an insert maps to
  ## its `{{`.
  result = at
  for index, part in parts:
    let textStart = textStarts[index]
    if textStart > at: break
    case part
    of TextPart: result = part.offset + (at - textStart)
    of InsertPart: result = part.offset

proc idOf(compiler: Compiler, namespace, name: string): Option[string] =
  ## `combat:healPlayer` → `combat:heal_player`, `std:clamp` →
  ## `<pack>:std/clamp`, `combat:isSitting` → `combat:is_sitting`.
  let output = compiler.outputNamespace(namespace).get(compiler.packNamespace)
  let nameKey = qualifiedKey(namespace, name)
  if nameKey in compiler.dataFileNames: return some(output & ":" & compiler.dataFileNames[nameKey])
  if nameKey notin compiler.mcfuns: return none(string)
  some(output & ":" & functionPath(outputPath(namespace, name)))

proc declaredNames(compiler: Compiler, namespace: string): seq[string] =
  ## The source names of the data files and mcfuns of a namespace.
  let keyPrefix = qualifiedKey(namespace, "")
  for declared in compiler.dataFileNames.keys:
    if declared.startsWith(keyPrefix): result.add declared[keyPrefix.len..^1]
  for declared in compiler.mcfuns.keys:
    if declared.startsWith(keyPrefix): result.add declared[keyPrefix.len..^1]

proc declarationWithFileName(compiler: Compiler, namespace, fileName: string): Option[string] =
  ## The source name whose file is `fileName`: `healPlayer` for `heal_player`.
  for declared in compiler.declaredNames(namespace):
    let key = qualifiedKey(namespace, declared)
    let declaredFile =
      if key in compiler.dataFileNames: compiler.dataFileNames[key] else: functionPath(declared)
    if declaredFile == fileName: return some(declared)
  none(string)

proc unknownIdMessage(compiler: Compiler, written, namespace, name: string): string =
  # `self:heal_player` is the file name of `healPlayer`: point to the name in the source.
  let declared = compiler.declarationWithFileName(namespace, name)
  if declared.isSome:
    return &"'{written}:{name}' is a file name. Use the name from the source: " &
           &"'{written}:{declared.get}'"
  &"'{written}:{name}' is not a data file or mcfun of namespace '{namespace}'" &
    suggestion(closestId(compiler.declaredNames(namespace), name))

proc sourceNamespaceOf(compiler: Compiler, written: string): Option[string] =
  ## The namespace whose Poplar names an id in Minecraft text uses: `self:`, or a namespace of the
  ## pack that the file imports. None for any other id, such as `minecraft:stone`, which is left as
  ## it is.
  if written == "self": return some(compiler.scope.namespace)
  if written notin compiler.namespaceImports: return none(string)
  if written == compiler.scope.namespace or compiler.isImported(written): return some(written)
  none(string)

proc checkBareName(compiler: Compiler, parts: openArray[CommandPart], built: CommandText, column,
                   start: int) =
  ## A name with no namespace means `minecraft:name`, so a name from this pack needs `self:`.
  var stop = start
  while stop < built.text.len and isIdChar(built.text[stop]): inc stop
  let name = built.text[start..<stop]
  let namespace = compiler.scope.namespace
  let at = column + sourceOffset(parts, built.textStarts, start)
  var sourceName = name
  if compiler.idOf(namespace, name).isNone:
    let declared = compiler.declarationWithFileName(namespace, name)
    if declared.isNone:
      # An id cannot have a capital letter, so this is a typo of a name from this pack, or a
      # mistake.
      if name.anyIt(it.isUpperAscii):
        compiler.failAt(at, &"'{name}' cannot be an id, because an id has no capital letters. To " &
                            &"name something in this pack, write 'self:{name}'")
      return
    sourceName = declared.get
  compiler.failAt(at, &"'{name}' is in this pack, but with no namespace it means " &
                      &"'minecraft:{name}'. Write 'self:{sourceName}'")

proc checkMinecraftText(compiler: Compiler, parts: openArray[CommandPart], built: CommandText,
                        column: int,
                        prefix, suffix: string): string =
  ## Checks Minecraft text against the command tree, between `prefix` and `suffix`, and changes each
  ## `self:name` and `ns:name` of a declaration into its id. `column` is where the text starts in
  ## the source.
  let fullText = prefix & built.text & suffix
  let checked = compiler.commandTree.checkText(fullText, compiler.poplarNamespaces)
  if checked.failure.isSome:
    let failure = checked.failure.get
    let at = min(max(failure.at - prefix.len, 0), built.text.len)
    compiler.failAt(column + sourceOffset(parts, built.textStarts, at), failure.message)
  if checked.ids.len == 0: return built.text

  let ids = checked.ids.sortedByIt(it.at)
  var resolved = ""
  var copied = 0
  for textId in ids:
    let start = textId.at - prefix.len
    var colon = start
    while colon < built.text.len and isResourceNameChar(built.text[colon]): inc colon
    if colon >= built.text.len or built.text[colon] != ':':
      if textId.canBePackName: compiler.checkBareName(parts, built, column, start)
      continue
    let written = built.text[start..<colon]

    # A storage or bossbar id is not a Poplar declaration: `self:` only gives it the namespace.
    if not textId.namesDeclaration:
      if written != "self": continue
      resolved.add built.text[copied..<start]
      resolved.add compiler.scope.outputNamespace.get(compiler.packNamespace)
      copied = colon
      continue
    let namespace = compiler.sourceNamespaceOf(written)
    if namespace.isNone: continue

    var stop = colon + 1
    while stop < built.text.len and isIdChar(built.text[stop]): inc stop
    let name = built.text[colon + 1 ..< stop]
    let id = compiler.idOf(namespace.get, name)
    if id.isNone:
      # `magic:heal_player`, the real id, stays as it is. `self:` only takes the name from the
      # source.
      let isSelf = written == "self"
      if not isSelf and compiler.declarationWithFileName(namespace.get, name).isSome: continue
      compiler.failAt(column + sourceOffset(parts, built.textStarts, start),
                      compiler.unknownIdMessage(written, namespace.get, name))
    resolved.add built.text[copied..<start] & id.get
    copied = stop
  resolved.add built.text[copied..^1]
  resolved

proc callMacroHelper(compiler: Compiler, name: string, commandText: CommandText,
                     needsMacroKeys: bool,
                     env: Environment, commands: var seq[Command]) =
  ## A macro call gets its arguments from one place. A helper that also needs the macro arguments of
  ## the mcfun, or a path such as `$stats.hp`, gets one compound in `<ns>:poplar macro`: the macro
  ## arguments, then each value it uses.
  if not needsMacroKeys:
    let storage = sharedStorage(commandText.inserts)
    if storage.isSome:
      let arguments = DataStorageArguments(dataStorage: storage.get)
      commands.add FunctionWithCommand(functionWith: FunctionWith(name: name, arguments: arguments))
      return

  # Keys from an earlier helper do no harm, because a macro line reads only the names it uses.
  if needsMacroKeys:
    commands.add DataSetCommand(dataValue: DataValue(target: inStorage(stMacro, ""),
                                                     snbt: compiler.mcfun.forwardedArgs.get))
  compiler.mcfun.tempCount = 0
  for insert in commandText.inserts:
    let target = inStorage(stMacro, insert.macroName)
    case insert.source
    of DataSource(path):
      commands.add DataCopyCommand(dataCopy: DataCopy(target: target, source: path))
    of ValueSource(expression):
      let outerPosition = compiler.enterExpression(expression)
      defer: compiler.position = outerPosition
      let call = callOf(expression)
      if call.isSome and isStringCall(call.get):
        compiler.compileStringInto(target, call.get, env, commands)
        continue
      let identifier = identifierOf(expression)
      var score: Score
      if identifier.isSome and identifier.get.kind == ikScore:
        score = compiler.scoreSource(identifier.get, env)
      else:
        score = compiler.newTemp()
        compiler.compileInto(score, expression, env, commands)
      commands.add ScoreToDataCommand(scoreToData: ScoreToData(target: target, score: score))
  commands.add FunctionWithCommand(functionWith: FunctionWith(name: name,
      arguments: MacroStorageArguments()))

proc compileCommand(compiler: Compiler, command: ast.Command, textColumn: int, env: Environment,
                    commands: var seq[Command]) =
  ## `textColumn` is the column where the command text starts, after the `/`.
  var commandText = compiler.buildCommandText(command.parts, env)
  commandText.text = compiler.checkMinecraftText(command.parts, commandText, textColumn, "", "")

  if not commandText.isMacro:
    commands.add RawCommand(raw: commandText.text)
    return

  let name = compiler.newGeneratedName("macro")
  let macroLine = MacroCommand(macroLine: commandText.text)
  compiler.generated.add McFunction(name: name, commands: @[macroLine])
  compiler.callMacroHelper(name, commandText, commandText.usesMacroKeys, env, commands)

proc compileExecute(compiler: Compiler, execute: ast.Execute, env: Environment,
                    commands: var seq[Command]) =
  var subcommands = compiler.buildCommandText(execute.subcommands, env)
  subcommands.text = compiler.checkMinecraftText(execute.subcommands, subcommands,
                                                 execute.subcommandsColumn,
                                                 "execute ", " run say x")

  let canReturn = jumpsIn(execute.body).hasReturn
  if canReturn:
    if compiler.mcfun.forwardedArgs.isSome:
      compiler.fail("'return' inside an 'execute' body in an mcfun that uses macro arguments is " &
                    "not supported yet")
    if subcommands.isMacro:
      compiler.fail("'return' inside an 'execute' body with a data insert is not supported yet")

  let run = compiler.compileJumpBody(execute.body, env, none(string))
  if run.isNone: return
  let executeCommand = ExecuteRawCommand(executeRaw: ExecuteRaw(subcommands: subcommands.text,
                                                                run: createCommand(run.get)))
  if not subcommands.isMacro:
    commands.add executeCommand
    return

  let name = compiler.newGeneratedName("macro")
  compiler.generated.add McFunction(name: name, commands: @[executeCommand])
  # The body can forward the macro arguments too, so in an mcfun that uses them they always go
  # along.
  compiler.callMacroHelper(name, subcommands, compiler.mcfun.forwardedArgs.isSome, env, commands)
