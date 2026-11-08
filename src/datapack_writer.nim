## Writes the IR as a datapack folder, and the folder as a zip.

import std/[options, os, strformat, strutils]
import config, ir

const zipVersion = 20'u16
  ## Version 2.0 of the zip format: stored files with no compression.

func functionPath*(name: string): string =
  ## Minecraft function names cannot have capitals, so a camelCase name is written in snake_case: `playerDied` →
  ## `player_died`, `poplar/usedCarrot/if_0` → `poplar/used_carrot/if_0`.
  for index, ch in name:
    if ch.isUpperAscii:
      if index > 0 and name[index - 1] != '/': result.add '_'
      result.add ch.toLowerAscii
    else:
      result.add ch

func splitFunctionName(packNamespace, name: string): (string, string) =
  let (namespace, path) = splitName(name)
  (namespace.get(packNamespace), path)

func functionId(packNamespace, name: string): string =
  ## `combat:healPlayer` → `combat:heal_player`. A name without a namespace is in the pack namespace.
  let (namespace, path) = splitFunctionName(packNamespace, name)
  namespace & ":" & functionPath(path)

func dataPathText(namespace: string, dataPath: DataPath): string =
  ## `storage ns:data hp` or `entity @s Health`, the target of `data` and `execute store`.
  let path = dataPath.path
  case dataPath.holder
  of StorageHolder(storage):
    case storage
    of stData: &"storage {dataPath.namespace.get(namespace)}:data {path}"
    of stStd: &"storage {namespace}:std {path}"
    of stArgs: &"storage {namespace}:poplar args.{path}"
    of stFrame: &"storage {namespace}:poplar stack[-1].{path}"
    of stPoplar: &"storage {namespace}:poplar {path}"
    of stMacro:
      if path.len == 0: &"storage {namespace}:poplar macro" else: &"storage {namespace}:poplar macro.{path}"
  of EntityHolder(selector): &"entity {selector} {path}"

func objectiveText*(namespace: string, objective: Option[string]): string =
  ## Poplar's own objective is `poplar.<ns>`, so a trigger can have the name of its namespace.
  if objective.isSome: &"{namespace}.{objective.get}" else: &"poplar.{namespace}"

func scoreText(namespace: string, score: Score): string =
  score.holder & " " & objectiveText(score.namespace.get(namespace), score.objective)

func compareText(op: CompareOp): string =
  case op
  of coLt: "<"
  of coLe: "<="
  of coEq: "="
  of coGe: ">="
  of coGt: ">"

func operatorText(op: Operator): string =
  case op
  of opAssign: "="
  of opAdd: "+="
  of opSub: "-="
  of opMul: "*="
  of opDiv: "/="
  of opMod: "%="

proc renderCheck(text: var string, namespace: string, check: Check) =
  text.add(if check.negated: " unless " else: " if ")
  case check.condition
  of DataTest(dataPath): text.add "data " & dataPathText(namespace, dataPath)
  of FunctionReturnsTest(function): text.add "function " & functionId(namespace, function)
  of RawTest(raw): text.add raw
  of MatchesTest(matches):
    text.add &"score {scoreText(namespace, matches.score)} matches "
    if matches.min.isSome and matches.min == matches.max:
      text.add $matches.min.get
    else:
      if matches.min.isSome: text.add $matches.min.get
      text.add ".."
      if matches.max.isSome: text.add $matches.max.get
  of CompareTest(compare):
    text.add &"score {scoreText(namespace, compare.left)} {compareText(compare.op)} " &
             scoreText(namespace, compare.right)

proc renderCommand*(text: var string, namespace: string, command: Command)

proc renderRun(text: var string, namespace: string, run: Command) =
  ## `execute A run execute B run C` is the same as `execute A B run C`, so nested executes become one.
  const nested = " run execute "
  let start = text.len
  text.add " run "
  text.renderCommand(namespace, run)
  if text.continuesWith(nested, start): text[start ..< start + nested.len] = " "

proc renderCommand*(text: var string, namespace: string, command: Command) =
  case command
  of RawCommand(raw): text.add raw
  of FunctionCommand(function): text.add "function " & functionId(namespace, function)
  of AddObjectiveCommand(objective):
    text.add &"scoreboard objectives add {objectiveText(objective.namespace.get(namespace), objective.name)} dummy"
  of ScoreSetCommand(scoreValue):
    text.add &"scoreboard players set {scoreText(namespace, scoreValue.score)} {scoreValue.value}"
  of ScoreSetIfUnsetCommand(scoreValue):
    let score = scoreText(namespace, scoreValue.score)
    text.add &"execute unless score {score} matches -2147483648.. run scoreboard players set {score} {scoreValue.value}"
  of ScoreAddCommand(scoreValue):
    text.add &"scoreboard players add {scoreText(namespace, scoreValue.score)} {scoreValue.value}"
  of ScoreRemoveCommand(scoreValue):
    text.add &"scoreboard players remove {scoreText(namespace, scoreValue.score)} {scoreValue.value}"
  of ScoreOperationCommand(operation):
    text.add &"scoreboard players operation {scoreText(namespace, operation.target)} {operatorText(operation.op)} " &
             scoreText(namespace, operation.source)
  of ScoreSetMacroArgumentCommand(argument):
    text.add &"scoreboard players set {scoreText(namespace, argument.score)} $({argument.macroArgument})"
  of DataSetCommand(data):
    text.add &"data modify {dataPathText(namespace, data.target)} set value {data.snbt}"
  of DataSetIfUnsetCommand(data):
    let target = dataPathText(namespace, data.target)
    text.add &"execute unless data {target} run data modify {target} set value {data.snbt}"
  of DataAddCommand(dataAdd):
    text.add &"data modify {dataPathText(namespace, dataAdd.list)} "
    case dataAdd.position
    of AppendPosition: text.add "append"
    of PrependPosition: text.add "prepend"
    of InsertPosition(index): text.add &"insert {index}"
    case dataAdd.source
    of SnbtSource(snbt): text.add " value " & snbt
    of FromSource(fromPath): text.add " from " & dataPathText(namespace, fromPath)
  of DataRemoveCommand(dataPath): text.add "data remove " & dataPathText(namespace, dataPath)
  of DataCopyCommand(copy):
    text.add &"data modify {dataPathText(namespace, copy.target)} set from {dataPathText(namespace, copy.source)}"
  of DataSetStringCommand(substring):
    text.add &"data modify {dataPathText(namespace, substring.target)} set string " &
             dataPathText(namespace, substring.source)
    if substring.start.isSome: text.add " " & $substring.start.get
    if substring.stop.isSome: text.add " " & $substring.stop.get
  of ScoreToDataCommand(copy):
    text.add &"execute store result {dataPathText(namespace, copy.target)} int 1 run scoreboard players get " &
             scoreText(namespace, copy.score)
  of DataToScoreCommand(copy):
    text.add &"execute store result score {scoreText(namespace, copy.score)} run data get " &
             dataPathText(namespace, copy.source)
    if copy.scale != 1: text.add " " & $copy.scale
  of FunctionWithCommand(call):
    text.add "function " & functionId(namespace, call.name)
    case call.arguments
    of CompoundArguments(compound): text.add " " & compound
    of DataStorageArguments(storage):
      text.add &" with storage {storage.namespace.get(namespace)}:{storage.kind.variablesName}"
    of ArgsStorageArguments: text.add &" with storage {namespace}:poplar args"
    of MacroStorageArguments: text.add &" with storage {namespace}:poplar macro"
    of DataPathArguments(dataPath): text.add " with " & dataPathText(namespace, dataPath)
    of RawArguments(raw): text.add " with " & raw
  of MacroCommand(macroLine): text.add macroLine
  of FramePushCommand: text.add &"data modify storage {namespace}:poplar stack append value {{}}"
  of FramePopCommand: text.add &"data remove storage {namespace}:poplar stack[-1]"
  of StackClearCommand: text.add &"data modify storage {namespace}:poplar stack set value []"
  of ExecuteCommand(execute):
    text.add "execute"
    for check in execute.checks: text.renderCheck(namespace, check)
    text.renderRun(namespace, execute.run[])
  of ExecuteRawCommand(execute):
    text.add "execute " & execute.subcommands
    text.renderRun(namespace, execute.run[])
  of ReturnRunCommand(run):
    text.add "return run "
    text.renderCommand(namespace, run[])
  of ReturnValueCommand(value): text.add "return " & $value
  of ReturnMacroArgumentCommand(macroArgument): text.add &"return $({macroArgument})"
  of StoreResultCommand(store):
    case store.target
    of ScoreTarget(score): text.add &"execute store result score {scoreText(namespace, score)} run "
    of DataTarget(dataPath): text.add &"execute store result {dataPathText(namespace, dataPath)} int 1 run "
    text.renderCommand(namespace, store.run[])
  of ScoreGetCommand(score): text.add "scoreboard players get " & scoreText(namespace, score)
  of DataGetCommand(dataPath): text.add "data get " & dataPathText(namespace, dataPath)

proc renderFunction*(namespace: string, function: McFunction): string =
  for command in function.commands:
    var line = ""
    line.renderCommand(namespace, command)
    # A line that uses a macro argument must start with `$`.
    if "$(" in line: result.add '$'
    result.add line
    result.add '\n'

proc writeFunction(outPath, namespace: string, function: McFunction) =
  let (functionNamespace, path) = splitFunctionName(namespace, function.name)
  let filePath = outPath / &"data/{functionNamespace}/function/{functionPath(path)}.mcfunction"
  createDir(filePath.parentDir)
  writeFile(filePath, renderFunction(namespace, function))

proc writeFunctionTag(outPath, tagName, namespace: string, functionNames: openArray[string]) =
  ## Writes a `minecraft:<tagName>` function tag with the functions in order.
  let tagFolder = outPath / "data/minecraft/tags/function"
  createDir(tagFolder)
  var values: seq[string]
  for name in functionNames: values.add "\"" & functionId(namespace, name) & "\""
  writeFile(tagFolder / tagName & ".json", "{\n    \"values\": [" & values.join(", ") & "]\n}\n")

proc writeDatapack*(outPath: string, packConfig: Config, program: Program) =
  let (min, max) = (packConfig.minFormat, packConfig.maxFormat)
  writeFile(outPath / "pack.mcmeta", "{\n    \"pack\": {\n" &
    &"        \"description\": {packConfig.description},\n" &
    &"        \"min_format\": [{min.major}, {min.minor}],\n" &
    &"        \"max_format\": [{max.major}, {max.minor}]\n" &
    "    }\n}\n")

  for function in program.functions: writeFunction(outPath, packConfig.namespace, function)

  if program.load.isSome:
    let load = program.load.get
    writeFunction(outPath, packConfig.namespace, load)
    writeFunctionTag(outPath, "load", packConfig.namespace, [load.name])

  if program.tick.len > 0: writeFunctionTag(outPath, "tick", packConfig.namespace, program.tick)

  for dataFile in program.dataFiles:
    let path = outPath / &"data/{dataFile.namespace}/{dataFile.folder}/{dataFile.path}.json"
    createDir(path.parentDir)
    writeFile(path, dataFile.json)

# ---- the zip

func crc32(data: string): uint32 =
  result = 0xFFFF_FFFF'u32
  for byte in data:
    result = result xor uint32(ord(byte))
    for _ in 0 ..< 8:
      result = if (result and 1) != 0: (result shr 1) xor 0xEDB8_8320'u32 else: result shr 1
  result = not result

proc addInt[T: uint16 | uint32](bytes: var string, value: T) =
  for index in 0 ..< sizeof(T): bytes.add char((value shr (8 * index)) and 0xFF)

proc addEntryHeader(bytes: var string, crc, size: uint32, nameLength: uint16) =
  ## The fields that the local header and the central directory header share, from "version needed" to "name
  ## length".
  bytes.addInt zipVersion
  bytes.addInt 0'u16 # flags
  bytes.addInt 0'u16 # method: stored
  bytes.addInt 0'u16 # time
  bytes.addInt uint16((1 shl 5) or 1) # date: 1980-01-01
  bytes.addInt crc
  bytes.addInt size # compressed size
  bytes.addInt size
  bytes.addInt nameLength

proc collectFiles(folder, relative: string, files: var seq[string]) =
  ## Depth first, in the order of the file system.
  for entry in walkDir(folder / relative, relative = true):
    let path = if relative.len == 0: entry.path else: relative / entry.path
    case entry.kind
    of pcFile: files.add path
    of pcDir: collectFiles(folder, path, files)
    else: discard

proc writeZip*(packPath, zipPath: string) =
  ## Writes a zip of the pack folder with no compression, so `pack.mcmeta` is at the root of the zip.
  var bytes, centralDirectory: string
  var fileCount = 0'u16

  var files: seq[string]
  collectFiles(packPath, "", files)
  for path in files:
    let name = path.replace('\\', '/')
    let data = readFile(packPath / path)
    let (crc, size) = (crc32(data), uint32(data.len))
    let localHeaderOffset = uint32(bytes.len)

    bytes.addInt 0x04034b50'u32
    bytes.addEntryHeader(crc, size, uint16(name.len))
    bytes.addInt 0'u16 # extra field length
    bytes.add name
    bytes.add data

    centralDirectory.addInt 0x02014b50'u32
    centralDirectory.addInt zipVersion
    centralDirectory.addEntryHeader(crc, size, uint16(name.len))
    centralDirectory.addInt 0'u16 # extra field length
    centralDirectory.addInt 0'u16 # comment length
    centralDirectory.addInt 0'u16 # disk number
    centralDirectory.addInt 0'u16 # internal attributes
    centralDirectory.addInt 0'u32 # external attributes
    centralDirectory.addInt localHeaderOffset
    centralDirectory.add name
    inc fileCount

  let centralDirectoryOffset = uint32(bytes.len)
  bytes.add centralDirectory

  bytes.addInt 0x06054b50'u32
  bytes.addInt 0'u16 # disk number
  bytes.addInt 0'u16 # disk of the central directory
  bytes.addInt fileCount
  bytes.addInt fileCount
  bytes.addInt uint32(centralDirectory.len)
  bytes.addInt centralDirectoryOffset
  bytes.addInt 0'u16 # comment length

  writeFile(zipPath, bytes)
