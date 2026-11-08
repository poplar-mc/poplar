import std/[options, strutils, unittest]
import ../src/[datapack_writer, ir, optimizer]

proc rendered(command: Command): string =
  result.renderCommand("ns", command)

let temp = tempScore("f", 0, none(string))

test "removes identities and inlines copies of temps":
  let otherTemp = tempScore("f", 1, none(string))
  let divisionTemp = tempScore("f", 2, none(string))
  let entity = Score(holder: "@p", objective: some("x"))
  let commands = @[
    ScoreAddCommand(scoreValue: ScoreValue(score: temp, value: 0)),
    ScoreOperationCommand(scoreOperation: ScoreOperation(target: temp, op: opMul,
        source: constantScore(1))),
    ScoreRemoveCommand(scoreValue: ScoreValue(score: temp, value: 1)),
    ScoreToDataCommand(scoreToData: ScoreToData(target: inStorage(stArgs, "n"), score: temp)),
    # Not inlined: the temp is read again below.
    ScoreSetCommand(scoreValue: ScoreValue(score: otherTemp, value: 5)),
    ScoreOperationCommand(scoreOperation: ScoreOperation(target: entity, op: opAssign,
        source: otherTemp)),
    ScoreGetCommand(score: otherTemp),
    # Not inlined: `/=` with a temp source can fail.
    ScoreOperationCommand(scoreOperation: ScoreOperation(target: divisionTemp, op: opDiv,
        source: otherTemp)),
    ScoreOperationCommand(scoreOperation: ScoreOperation(target: entity, op: opAssign,
        source: divisionTemp)),
  ]

  let result = optimizeFunction("f", commands)
  check result.len == 6
  check result[0].rendered == "execute store result storage ns:poplar args.n int 1 run " &
                              "scoreboard players remove #poplar.f.t0 poplar.ns 1"
  check result[1].rendered.startsWith("scoreboard players set ")
  check result[4].rendered.startsWith("scoreboard players operation ")

test "uses known values, removes dead writes and scales data gets":
  let copyTemp = tempScore("f", 1, none(string))
  let afterCallTemp = tempScore("f", 2, none(string))
  let global = Score(holder: "#global", objective: some("x"))
  let atMostOne = Check(condition: MatchesTest(matches: Matches(score: temp, max: some(1'i32))))
  let commands = @[
    ScoreSetMacroArgumentCommand(scoreMacroArgument: ScoreMacroArgument(score: temp,
        macroArgument: "n")),
    ExecuteCommand(execute: Execute(checks: @[atMostOne],
                                    run: createCommand(ReturnValueCommand(returnValue: 1)))),
    # Removed: the temp already holds `n`.
    ScoreSetMacroArgumentCommand(scoreMacroArgument: ScoreMacroArgument(score: temp,
        macroArgument: "n")),
    # Becomes a copy of the temp.
    ScoreSetMacroArgumentCommand(scoreMacroArgument: ScoreMacroArgument(score: copyTemp,
        macroArgument: "n")),
    ScoreToDataCommand(scoreToData: ScoreToData(target: inStorage(stArgs, "n"), score: copyTemp)),
    # Kept: the call can change every score.
    FunctionCommand(function: "other"),
    ScoreSetMacroArgumentCommand(scoreMacroArgument: ScoreMacroArgument(score: afterCallTemp,
        macroArgument: "n")),
    ScoreToDataCommand(scoreToData: ScoreToData(target: inStorage(stArgs, "m"),
        score: afterCallTemp)),
    # `set 7` is removed, and `*= 3` becomes `set 21`.
    ScoreSetCommand(scoreValue: ScoreValue(score: global, value: 7)),
    ScoreOperationCommand(scoreOperation: ScoreOperation(target: global, op: opMul,
        source: constantScore(3))),
    FunctionCommand(function: "other"),
    DataToScoreCommand(dataToScore: DataToScore(source: inStorage(stData, "count"), score: global)),
    ScoreOperationCommand(scoreOperation: ScoreOperation(target: global, op: opMul,
        source: constantScore(100))),
  ]

  let result = optimizeFunction("f", commands)
  check result.len == 8
  check result[2].rendered.endsWith(
    " run scoreboard players operation #poplar.f.t1 poplar.ns = #poplar.f.t0 poplar.ns")
  check result[4].rendered.endsWith(" run scoreboard players set #poplar.f.t2 poplar.ns $(n)")
  check result[5].rendered == "scoreboard players set #global ns.x 21"
  check result[7].rendered ==
    "execute store result score #global ns.x run data get storage ns:data count 100"
