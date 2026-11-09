# NBT data: assigning, paths and literals, list builtins, and the string helpers. Part of
# compiler.nim.

type LiteralPart = object
  ## A runtime value inside a literal, and where it goes: `[1]` in `pos[1]`, `.hp` in `stats.hp`.
  path: string
  value: Expression

const stringScratch = inStorage(stPoplar, "string")
  ## The result of a nested string helper, and the substring that `startsWith` and `endsWith`
  ## compare.

const stringTestKey = "string_test"

# ---- text as the game counts it, in UTF-16 units

func decodeUtf8(text: string): Option[seq[int32]] =
  ## The code points of valid UTF-8: no overlong forms, no surrogates and nothing past U+10FFFF.
  var codePoints: seq[int32]
  var index = 0
  while index < text.len:
    let lead = ord(text[index])
    let (length, lowest) =
      if lead < 0x80: (1, 0)
      elif lead in 0xC2..0xDF: (2, 0x80)
      elif lead in 0xE0..0xEF: (3, 0x800)
      elif lead in 0xF0..0xF4: (4, 0x10000)
      else: return none(seq[int32])
    if index + length > text.len: return none(seq[int32])
    var codePoint = if length == 1: lead else: lead and (0xFF shr (length + 1))
    for offset in 1..<length:
      let continuation = ord(text[index + offset])
      if (continuation and 0xC0) != 0x80: return none(seq[int32])
      codePoint = (codePoint shl 6) or (continuation and 0x3F)
    if codePoint < lowest or codePoint > 0x10FFFF or codePoint in 0xD800..0xDFFF:
      return none(seq[int32])
    codePoints.add int32(codePoint)
    index += length
  some(codePoints)

func utf16Units(text: string): Option[seq[uint16]] =
  let codePoints = decodeUtf8(text)
  if codePoints.isNone: return none(seq[uint16])
  var units: seq[uint16]
  for codePoint in codePoints.get:
    if codePoint < 0x10000:
      units.add uint16(codePoint)
    else:
      let offset = codePoint - 0x10000
      units.add uint16(0xD800 + (offset shr 10))
      units.add uint16(0xDC00 + (offset and 0x3FF))
  some(units)

func utf16Length(text: string): Option[int] =
  let units = utf16Units(text)
  if units.isSome: some(units.get.len) else: none(int)

func utf16ToUtf8(units: openArray[uint16]): Option[string] =
  ## None when a surrogate has no partner.
  var text = ""
  var index = 0
  while index < units.len:
    let unit = int32(units[index])
    if unit in 0xDC00..0xDFFF: return none(string)
    if unit in 0xD800..0xDBFF:
      if index + 1 >= units.len or int32(units[index + 1]) notin 0xDC00 .. 0xDFFF:
        return none(string)
      text.add toUTF8(Rune(0x10000 + ((unit - 0xD800) shl 10) + (int32(units[index + 1]) - 0xDC00)))
      index += 2
    else:
      text.add toUTF8(Rune(unit))
      inc index
  some(text)

# ---- paths

func isDataIdentifier(expression: Expression): bool =
  let identifier = identifierOf(expression)
  identifier.isSome and identifier.get.kind in {ikData, ikEntityData}

func sameHolder(a, b: DataPathHolder): bool =
  case a
  of StorageHolder(storage):
    case b
    of StorageHolder(other): storage == other
    else: false
  of EntityHolder(entity):
    case b
    of EntityHolder(other): entity == other
    else: false

func storageOf(namespace: string): Storage =
  ## std shares the pack namespace, so its `$` variables have their own storage, apart from the
  ## pack's.
  if namespace == stdNamespace: stStd else: stData

proc dataLocal(compiler: Compiler, keyName: string): DataPath =
  ## A data local in `<ns>:data` of the mcfun's namespace, or in `<pack>:std` for std.
  result = inStorage(storageOf(compiler.scope.namespace), keyName)
  result.namespace = compiler.scope.outputNamespace

proc entityDataPath(compiler: Compiler, identifier: Identifier): DataPath =
  compiler.checkSingleEntity(identifier)
  ofEntity(identifier.selector.get, identifier.name)

proc dataPath(compiler: Compiler, identifier: Identifier, env: Environment): DataPath =
  ## Checks that the root of a `$` path is declared, and gives the path in `<ns>:data`.
  let name = identifier.name
  let root = pathRoot(name)
  if identifier.namespace.isNone:
    let local = env.getLocal(lkData, root)
    if local.isSome: return compiler.dataLocal(local.get.generatedName & name[root.len..^1])
  let namespace = compiler.resolveNamespace(identifier.namespace)
  let key = qualifiedKey(namespace, root)
  if key notin compiler.dataGlobals: compiler.fail(&"unknown data '${root}'")
  let global = compiler.dataGlobals[key]
  result = inStorage(global.storage, name)
  result.namespace = global.outputNamespace

proc dataPathOf(compiler: Compiler, identifier: Identifier, env: Environment): DataPath =
  ## A `$` variable in `<ns>:data`, or the NBT path of one entity.
  if identifier.kind == ikEntityData: compiler.entityDataPath(identifier)
  else: compiler.dataPath(identifier, env)

# ---- assigning

proc literalTemplate(compiler: Compiler, expression: Expression, path: string, env: Environment,
                     parts: var seq[LiteralPart]): Value =
  ## The literal as a value, with `0` in the place of each runtime part.
  if not containsRuntimeValue(expression): return compiler.evaluate(expression, env)

  case expression
  of ListExpression(elements):
    var values: seq[Value]
    for index, element in elements:
      values.add compiler.literalTemplate(element, &"{path}[{index}]", env, parts)
    ListValue(elements: values)
  of CompoundExpression(entries):
    var values: seq[ValueEntry]
    for entry in entries:
      let entryPath = path & "." & snbtKey(entry.key)
      let entryValue = compiler.literalTemplate(entry.value, entryPath, env, parts)
      values.add ValueEntry(key: entry.key, value: entryValue)
    CompoundValue(entries: values)
  else:
    parts.add LiteralPart(path: path, value: expression)
    NumberValue(number: 0)

proc compileLiteralAssign(compiler: Compiler, target: DataPath, expression: Expression,
                          env: Environment, commands: var seq[Command]) =
  ## `$pos = [#x, #y, 0]` sets the literal with a `0` for each runtime part, then stores each part
  ## at its path.
  var parts: seq[LiteralPart]
  let literal = compiler.literalTemplate(expression, "", env, parts)

  commands.add DataSetCommand(dataValue: DataValue(target: target, snbt: valueToSnbt(literal)))
  for part in parts:
    compiler.compileDataAssign(target.withPath(target.path & part.path), part.value, env, commands)

func isStringCall(call: Call): bool =
  ## `slice(text, start, end)` and `str(value)` give a string. `startsWith` and `endsWith` are
  ## conditions.
  isBuiltinCall(call, "slice") or isBuiltinCall(call, "str")

func isStringTest(call: Call): bool =
  isBuiltinCall(call, "startsWith") or isBuiltinCall(call, "endsWith")

proc constantIndex(compiler: Compiler, expression: Expression, env: Environment): int32 =
  if containsRuntimeValue(expression):
    compiler.failOn(expression, "the bounds of 'slice' must be constant integers")
  compiler.toScoreValue(compiler.evaluate(expression, env))

proc stringSource(compiler: Compiler, argument: Expression, env: Environment,
                  commands: var seq[Command]): DataPath =
  ## The data that a string helper reads: a `$` path, entity
  ## data, or another string helper (through the scratch value).
  if isDataIdentifier(argument): return compiler.dataPathOf(identifierOf(argument).get, env)
  let call = callOf(argument)
  if call.isSome and isStringCall(call.get):
    compiler.compileStringInto(stringScratch, call.get, env, commands)
    return stringScratch
  compiler.failOn(argument, "the text must be data ('$x' or '@s.$path') or another string " &
                            "helper. For a score, use 'str(#x)'")

proc compileStringInto(compiler: Compiler, target: DataPath, call: Call, env: Environment,
                       commands: var seq[Command]) =
  ## `data modify <target> set string <source> [start] [end]`. A score or math goes into the scratch
  ## value first, because `set string` reads data: a number there becomes its text.
  let outerPosition = compiler.enterExpression(call.callee)
  defer: compiler.position = outerPosition
  if isBuiltinCall(call, "slice"):
    if call.args.len notin [2, 3]:
      compiler.fail(&"'slice' expects 2 or 3 arguments (text, start, end), found {call.args.len}")
    let start = compiler.constantIndex(call.args[1], env)
    let stop = if call.args.len == 3: some(compiler.constantIndex(call.args[2],
                                                                  env)) else: none(int32)
    let source = compiler.stringSource(call.args[0], env, commands)
    let substring = DataSetString(target: target, source: source, start: some(start), stop: stop)
    commands.add DataSetStringCommand(dataSetString: substring)
    return

  if call.args.len != 1: compiler.fail(&"'str' expects 1 argument, found {call.args.len}")
  let argument = call.args[0]
  let argumentCall = callOf(argument)
  if argumentCall.isSome and isStringCall(argumentCall.get):
    compiler.compileStringInto(target, argumentCall.get, env, commands)
    return
  if isDataIdentifier(argument):
    let source = compiler.dataPathOf(identifierOf(argument).get, env)
    commands.add DataSetStringCommand(dataSetString: DataSetString(target: target, source: source))
    return
  let identifier = identifierOf(argument)
  var score: Score
  if identifier.isSome and identifier.get.kind == ikScore:
    score = compiler.scoreSource(identifier.get, env)
  else:
    score = compiler.newTemp()
    compiler.compileInto(score, argument, env, commands)
  commands.add ScoreToDataCommand(scoreToData: ScoreToData(target: stringScratch, score: score))
  commands.add DataSetStringCommand(dataSetString: DataSetString(target: target,
      source: stringScratch))

proc compileDataAssign(compiler: Compiler, target: DataPath, expression: Expression,
                       env: Environment, commands: var seq[Command]) =
  ## Sets data in storage or an entity path. A score or math is stored as an int.
  let outerPosition = compiler.enterExpression(expression)
  defer: compiler.position = outerPosition

  if not containsRuntimeValue(expression):
    let value = compiler.evaluate(expression, env)
    case value
    of NullValue: compiler.fail("data cannot be set to null")
    else: discard
    commands.add DataSetCommand(dataValue: DataValue(target: target, snbt: valueToSnbt(value)))
    return

  case expression
  of CallExpression(call):
    if isStringCall(call):
      compiler.compileStringInto(target, call, env, commands)
      return
  of ListExpression, CompoundExpression:
    compiler.compileLiteralAssign(target, expression, env, commands)
    return
  of MacroKey(key):
    # A macro argument is text in the command, so Minecraft reads its type, as in a hand-written
    # datapack.
    commands.add DataSetCommand(dataValue: DataValue(target: target, snbt: &"$({key})"))
    return
  of NameExpression(identifier):
    case identifier.kind
    of ikScore:
      let score = compiler.scoreSource(identifier, env)
      commands.add ScoreToDataCommand(scoreToData: ScoreToData(target: target, score: score))
      return
    of ikData, ikEntityData:
      let source = compiler.dataPathOf(identifier, env)
      if sameHolder(source.holder, target.holder) and source.path == target.path: return
      commands.add DataCopyCommand(dataCopy: DataCopy(target: target, source: source))
      return
    of ikCompileTime: discard
  else: discard

  compiler.mcfun.tempCount = 0
  let temp = compiler.newTemp()
  compiler.compileInto(temp, expression, env, commands)
  commands.add ScoreToDataCommand(scoreToData: ScoreToData(target: target, score: temp))

# ---- builtins

proc textComponent(compiler: Compiler, argument: Expression, env: Environment): Value =
  ## `text(#hp)` → `{score:{name:"#global",objective:"<ns>.hp"}}`, `text($x)` →
  ## `{storage:"<ns>:data",nbt:"x"}`, `text(@s.$Name)` → `{entity:"@s",nbt:"Name"}`. A compile-time
  ## value becomes a string.
  let identifier = identifierOf(argument)
  if identifier.isSome:
    case identifier.get.kind
    of ikScore:
      let score = compiler.resolveScore(identifier.get, env)
      let objective = objectiveText(score.namespace.get(compiler.packNamespace), score.objective)
      let holder = CompoundValue(entries: @[
        ValueEntry(key: "name", value: StringValue(text: score.holder)),
        ValueEntry(key: "objective", value: StringValue(text: objective))])
      return CompoundValue(entries: @[ValueEntry(key: "score", value: holder)])
    of ikData:
      let path = compiler.dataPath(identifier.get, env)
      var variables = ""
      case path.holder
      of StorageHolder(storage): variables = storage.variablesName
      of EntityHolder: discard
      let storage = path.namespace.get(compiler.packNamespace) & ":" & variables
      return CompoundValue(entries: @[
        ValueEntry(key: "storage", value: StringValue(text: storage)),
        ValueEntry(key: "nbt", value: StringValue(text: path.path))])
    of ikEntityData:
      let selector = identifier.get.selector.get
      return CompoundValue(entries: @[
        ValueEntry(key: "entity", value: StringValue(text: selector)),
        ValueEntry(key: "nbt", value: StringValue(text: identifier.get.name))])
    of ikCompileTime: discard
  StringValue(text: valueToText(compiler.evaluate(argument, env)))

proc listArgument(compiler: Compiler, name: string, argument: Expression,
    env: Environment): DataPath =
  ## The first argument of a list helper: a `$` variable or entity data.
  let outerPosition = compiler.enterExpression(argument)
  defer: compiler.position = outerPosition
  if not isDataIdentifier(argument):
    compiler.fail(&"the first argument of '{name}' must be a list: '$list' or '@s.$path'")
  compiler.dataPathOf(identifierOf(argument).get, env)

proc compileListBuiltin(compiler: Compiler, name: string, call: Call, env: Environment,
                        commands: var seq[Command]) =
  ## `append($list, v)`, `prepend($list, v)`, `insert($list, i, v)` and `remove($list, i)`.
  if name == "len": compiler.fail("'len' gives a value. Use it as one: '#n = len($list)'")
  let arity = if name == "insert": 3 else: 2
  if call.args.len != arity:
    compiler.fail(&"'{name}' expects {arity} arguments, found {call.args.len}")

  let list = compiler.listArgument(name, call.args[0], env)

  let hasIndex = name in ["insert", "remove"]
  let index = if hasIndex: compiler.toScoreValue(compiler.evaluate(call.args[1], env)) else: 0'i32

  if name == "remove":
    commands.add DataRemoveCommand(dataPath: list.withPath(&"{list.path}[{index}]"))
    return

  let position = case name
    of "append": AppendPosition()
    of "prepend": PrependPosition()
    else: InsertPosition(index: index)
  let elementPath = case name
    of "append": "[-1]"
    of "prepend": "[0]"
    else: &"[{index}]"
  let value = call.args[arity - 1]

  if not containsRuntimeValue(value):
    let snbt = valueToSnbt(compiler.evaluate(value, env))
    commands.add DataAddCommand(dataAdd: DataAdd(list: list, position: position,
                                                 source: SnbtSource(snbt: snbt)))
    return
  if isDataIdentifier(value):
    let source = compiler.dataPathOf(identifierOf(value).get, env)
    let add = DataAdd(list: list, position: position, source: FromSource(fromPath: source))
    commands.add DataAddCommand(dataAdd: add)
    return

  # Add a `0`, then store the runtime value into it.
  commands.add DataAddCommand(dataAdd: DataAdd(list: list, position: position,
                                               source: SnbtSource(snbt: "0")))
  compiler.compileDataAssign(list.withPath(list.path & elementPath), value, env, commands)

proc constantString(compiler: Compiler, expression: Expression, env: Environment,
    builtin: string): string =
  let outerPosition = compiler.enterExpression(expression)
  defer: compiler.position = outerPosition
  if not containsRuntimeValue(expression):
    case compiler.evaluate(expression, env)
    of StringValue(text): return text
    else: discard
  compiler.fail(&"the second argument of '{builtin}' must be a constant string")

proc stringTest(compiler: Compiler, call: Call, env: Environment, negated: bool,
                setup: var seq[Command]): Condition =
  ## `startsWith(text, "minecraft:")`: the first characters go into the test value, which starts as
  ## "" so that a text that is too short (the `set string` fails) does not match. Then one NBT
  ## filter compares them.
  let name = calleeName(call)
  let isStart = isBuiltinCall(call, "startsWith")
  let affixName = if isStart: "prefix" else: "suffix"
  if call.args.len != 2:
    compiler.fail(&"'{name}' expects 2 arguments (text, {affixName}), found {call.args.len}")
  let affix = compiler.constantString(call.args[1], env, name)
  let length = int32(utf16Length(affix).get(affix.len))
  if length == 0: return ConstantCondition(isTrue: not negated)

  let source = compiler.stringSource(call.args[0], env, setup)
  let testValue = inStorage(stPoplar, stringTestKey)
  setup.add DataSetCommand(dataValue: DataValue(target: testValue, snbt: "\"\""))
  setup.add DataSetStringCommand(dataSetString: DataSetString(
    target: testValue, source: source,
    start: some(if isStart: 0'i32 else: -length),
    stop: if isStart: some(length) else: none(int32),
  ))
  let filter = "{" & stringTestKey & ":" & valueToSnbt(StringValue(text: affix)) & "}"
  let testPath = DataPath(holder: StorageHolder(storage: stPoplar), path: filter)
  singleCheck(Check(negated: negated, condition: DataTest(dataPath: testPath)))

proc evaluateStringCall(compiler: Compiler, call: Call, env: Environment): Value =
  ## The string helpers on constants run when the pack is built. Indices count UTF-16 units, the
  ## same as the game.
  let name = calleeName(call)
  let arityOk = if isBuiltinCall(call, "slice"): call.args.len in [2, 3]
                elif isBuiltinCall(call, "str"): call.args.len == 1
                else: call.args.len == 2
  if not arityOk: compiler.fail(&"'{name}' has the wrong number of arguments")
  let firstValue = compiler.evaluate(call.args[0], env)
  let text = case firstValue
    of StringValue(text): text
    of NumberValue(number): $number
    of TypedNumberValue(number): number.text
    else: compiler.fail(&"'{name}' needs a string or a number, found {tagName(firstValue)}")
  if isBuiltinCall(call, "str"): return StringValue(text: text)
  if isStringTest(call):
    let affix = compiler.constantString(call.args[1], env, name)
    let matches = if isBuiltinCall(call,
                                   "startsWith"): text.startsWith(affix) else: text.endsWith(affix)
    return BooleanValue(boolean: matches)

  let units = utf16Units(text)
  if units.isNone: compiler.fail("'slice' needs valid UTF-8 text")
  let length = int64(units.get.len)
  let start = int64(compiler.constantIndex(call.args[1], env))
  let stop = if call.args.len == 3: int64(compiler.constantIndex(call.args[2], env)) else: length
  let fromIndex = if start < 0: length + start else: start
  let toIndex = if stop < 0: length + stop else: stop
  if fromIndex < 0 or toIndex > length or fromIndex > toIndex:
    compiler.fail(&"'slice' bounds {start}..{stop} are out of range for a text of length {length}")
  let sliced = utf16ToUtf8(units.get.toOpenArray(int(fromIndex), int(toIndex) - 1))
  if sliced.isNone: compiler.fail("'slice' cuts a character in two")
  StringValue(text: sliced.get)

proc compileLength(compiler: Compiler, target: Score, call: Call, env: Environment,
    commands: var seq[Command]) =
  ## `len($list)`: `data get` on a list, compound or string gives its size.
  if call.args.len != 1: compiler.fail(&"'len' expects 1 argument, found {call.args.len}")
  let argument = call.args[0]
  if not isDataIdentifier(argument):
    compiler.fail("'len' needs a list, a compound or a string in data")
  let source = compiler.dataPathOf(identifierOf(argument).get, env)
  commands.add DataToScoreCommand(dataToScore: DataToScore(source: source, score: target))
