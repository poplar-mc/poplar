## Minecraft functions and commands, before they are written as text.
##
## A function name is `ns:path`, or only `path` in the pack namespace (Poplar's own files and the namespace of
## `poplar.json`). A score or data path with no namespace is in the pack namespace too.

import std/[options, strutils]

type
  Program* = object
    functions*: seq[McFunction]
    load*: Option[McFunction]
    tick*: seq[string] ## The functions of the `minecraft:tick` tag, in order.
    dataFiles*: seq[DataFile]

  DataFile* = object
    ## `data/<namespace>/<folder>/<path>.json`, with the JSON as the user wrote it.
    namespace*: string
    folder*: string
    path*: string
    json*: string

  McFunction* = object
    name*: string
    commands*: seq[Command]

  Command* = object
    ## `FramePushCommand` adds a frame to `<ns>:poplar stack`, to hold the temps that a recursive call would
    ## overwrite. `FramePopCommand` removes it, and `StackClearCommand` empties the stack.
    case
    of RawCommand: raw*: string
    of FunctionCommand: function*: string ## The writer adds the namespace to this mcfun name.
    of AddObjectiveCommand: objective*: Objective
    of ScoreSetCommand, ScoreSetIfUnsetCommand, ScoreAddCommand, ScoreRemoveCommand: scoreValue*: ScoreValue
    of ScoreSetMacroArgumentCommand: scoreMacroArgument*: ScoreMacroArgument
    of ScoreOperationCommand: scoreOperation*: ScoreOperation
    of DataSetCommand, DataSetIfUnsetCommand: dataValue*: DataValue
    of DataCopyCommand: dataCopy*: DataCopy
    of DataSetStringCommand: dataSetString*: DataSetString
    of DataAddCommand:
      dataAdd*: DataAdd ## `data modify ... append|prepend|insert <i> value|from ...`
    of DataRemoveCommand, DataGetCommand: dataPath*: DataPath
    of ScoreToDataCommand: scoreToData*: ScoreToData
    of DataToScoreCommand: dataToScore*: DataToScore
    of FunctionWithCommand: functionWith*: FunctionWith
    of MacroCommand: macroLine*: string ## The text of a macro line, with `$(key)` in it.
    of FramePushCommand, FramePopCommand, StackClearCommand: discard
    of ExecuteCommand: execute*: Execute
    of ExecuteRawCommand: executeRaw*: ExecuteRaw
    of StoreResultCommand:
      storeResult*: StoreResult ## `execute store result score <score> run <command>`
    of ScoreGetCommand: score*: Score
    of ReturnRunCommand: returnRun*: ref Command
    of ReturnValueCommand: returnValue*: int32
    of ReturnMacroArgumentCommand:
      returnMacroArgument*: string ## `return $(key)`, which returns the value of a macro argument.

  StoreResultTarget* = object
    case
    of ScoreTarget: score*: Score
    of DataTarget: dataPath*: DataPath

  StoreResult* = object
    target*: StoreResultTarget
    run*: ref Command

  Storage* = enum
    ## `stData` is the `<ns>:data` storage of `$` variables, where a key is a variable name.
    ## `stArgs` is `<ns>:poplar args`, the `with` compound of the mcfun that is called next.
    ## `stFrame` is the top frame of `<ns>:poplar stack`, where a key is the name of a saved temp.
    ## `stMacro` is `<ns>:poplar macro`: the macro arguments and the inserted values for one macro helper. An empty
    ## key is the whole compound.
    ## `stPoplar` is the root of `<ns>:poplar`, where the string helpers keep their scratch value.
    ## `stStd` is `<pack>:std`, the `$` variables of the standard library, apart from the pack's own `<pack>:data`.
    stData, stArgs, stFrame, stMacro, stPoplar, stStd

  DataPathHolder* = object
    case
    of StorageHolder: storage*: Storage
    of EntityHolder: entity*: string ## A selector for one entity.

  DataPath* = object
    ## A place for NBT: a key in one of Poplar's storages, or a path in the NBT of one entity.
    holder*: DataPathHolder
    path*: string
    namespace*: Option[string] ## The namespace of the `<ns>:data` storage.

  DataValue* = object
    target*: DataPath
    snbt*: string

  DataCopy* = object
    target*: DataPath
    source*: DataPath

  DataSetString* = object
    ## `data modify <target> set string <source> [start] [end]`: a substring, or a number as a string.
    target*: DataPath
    source*: DataPath
    start*, stop*: Option[int32]

  DataAddPosition* = object
    case
    of AppendPosition, PrependPosition: discard
    of InsertPosition: index*: int32

  DataAddSource* = object
    case
    of SnbtSource: snbt*: string
    of FromSource: fromPath*: DataPath

  DataAdd* = object
    list*: DataPath
    position*: DataAddPosition
    source*: DataAddSource

  ScoreToData* = object
    target*: DataPath
    score*: Score

  DataToScore* = object
    ## The value is multiplied by the scale before it is stored.
    source*: DataPath
    score*: Score
    scale*: int32 = 1

  ScoreMacroArgument* = object
    score*: Score
    macroArgument*: string

  DataStorage* = object
    kind*: Storage
    namespace*: Option[string]

  FunctionWithArguments* = object
    case
    of CompoundArguments: compound*: string
    of DataStorageArguments:
      dataStorage*: DataStorage
        ## `with storage <ns>:data` or `<pack>:std`, where whole `$` variables are read as they are.
    of DataPathArguments:
      dataPath*: DataPath ## `with storage ns:data player` or `with entity @s SelectedItem`.
    of RawArguments: raw*: string ## `with entity @s` or `with block ~ ~ ~`, as written.
    of ArgsStorageArguments, MacroStorageArguments: discard

  FunctionWith* = object
    ## Calls an mcfun with macro arguments.
    name*: string
    arguments*: FunctionWithArguments

  Objective* = object
    ## A none name is Poplar's objective `poplar.<ns>`. Otherwise it is `<ns>.<name>`.
    namespace*: Option[string]
    name*: Option[string]

  ScoreTemp* = object
    folder*: string ## The mcfun as it appears in generated names (`generatedFolder`).
    index*: int

  ScoreKind* = object
    ## `GlobalScore` is a score that any function can read:
    ## a global, or the result of a body on its way out.
    case
    of GlobalScore: discard
    of TempScore:
      temp*: ScoreTemp
        ## A value during one statement. Only the mcfun and its generated functions read it.
    of ConstantScore: constant*: int32 ## A number that `poplar/load` sets, for math with a fixed value.
    of LocalScore:
      owner*: string
        ## A local variable. The owner is its mcfun (`combat:heal`), and only that mcfun and its
        ## generated functions read it.

  Score* = object
    ## A holder is a fake player (`#hp`, `#poplar.c1`) or a selector (`@s`).
    holder*: string
    objective*: Option[string]
    namespace*: Option[string] ## The objective is `<namespace>` or `<namespace>.<objective>`.
    kind*: ScoreKind ## Not compared by `==`.

  ScoreValue* = object
    score*: Score
    value*: int32

  Operator* = enum
    opAssign, opAdd, opSub, opMul, opDiv, opMod

  ScoreOperation* = object
    target*: Score
    op*: Operator
    source*: Score

  Execute* = object
    checks*: seq[Check]
    run*: ref Command

  ExecuteRaw* = object
    ## Subcommands written by the user, for example `as @a at @s`.
    subcommands*: string
    run*: ref Command

  CheckTest* = object
    case
    of MatchesTest: matches*: Matches
    of CompareTest: compare*: Compare
    of DataTest:
      dataPath*: DataPath
        ## `if data storage ns:data stats.bonus` passes when the path exists. The path can also be
        ## an NBT filter: `{name:"Steve"}`.
    of FunctionReturnsTest:
      function*: string
        ## `if function ns:<name>` runs the function and passes when its return value is not 0.
    of RawTest:
      raw*: string ## A Minecraft check as the user wrote it, such as `block ~ ~-1 ~ stone`.

  Check* = object
    ## A negated check is written as `unless`.
    negated*: bool
    condition*: CheckTest

  Matches* = object
    score*: Score
    min*, max*: Option[int32]

  CompareOp* = enum
    coLt, coLe, coEq, coGe, coGt

  Compare* = object
    left*: Score
    op*: CompareOp
    right*: Score

proc createCommand*(command: Command): ref Command =
  result = new Command
  result[] = command

func variablesName*(storage: Storage): string =
  ## The path of the storage that holds `$` variables: `<ns>:data` or `<pack>:std`.
  if storage == stStd: "std" else: "data"

func inStorage*(storage: Storage, key: string): DataPath =
  DataPath(holder: StorageHolder(storage: storage), path: key)

func ofEntity*(selector, path: string): DataPath =
  DataPath(holder: EntityHolder(entity: selector), path: path)

func withPath*(dataPath: DataPath, path: string): DataPath =
  ## The same holder and namespace, with another path.
  result = dataPath
  result.path = path

func tempScore*(folder: string, index: int, namespace: Option[string]): Score =
  Score(holder: "#poplar." & folder & ".t" & $index, namespace: namespace,
        kind: TempScore(temp: ScoreTemp(folder: folder, index: index)))

func constantScore*(value: int32): Score =
  Score(holder: "#poplar.c" & $value, kind: ConstantScore(constant: value))

func resultScore*(folder: string, namespace: Option[string]): Score =
  ## The value of a `return` inside a `while` or `execute (...)` body.
  Score(holder: "#poplar." & folder & ".result", namespace: namespace)

func localScore*(generatedName, owner: string, namespace: Option[string]): Score =
  Score(holder: generatedName, namespace: namespace, kind: LocalScore(owner: owner))

func `==`*(a, b: Score): bool =
  a.objective == b.objective and a.namespace == b.namespace and a.holder == b.holder

func splitName*(name: string): (Option[string], string) =
  ## `combat:poplar/heal/if_0` → `combat` and `poplar/heal/if_0`. A name without `:` is in the pack namespace.
  let colon = name.find(':')
  if colon < 0: (none(string), name) else: (some(name[0 ..< colon]), name[colon + 1 .. ^1])

func generatedFolder*(mcfunPath: string): string =
  ## The generated functions of an mcfun go in `poplar/<folder>/`, and its temps are `#poplar.<folder>.t<n>`. The
  ## folder is the mcfun's path with `.` for `/` (`std/clamp` → `std.clamp`), because it is also in data keys, which
  ## cannot have `/`.
  mcfunPath.replace('/', '.')

func isGeneratedFolder*(folder, mcfunPath: string): bool =
  if folder.len != mcfunPath.len: return false
  for index, ch in folder:
    if ch != mcfunPath[index] and not (ch == '.' and mcfunPath[index] == '/'): return false
  true
