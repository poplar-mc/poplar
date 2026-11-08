import std/[options, os, strutils, tempfiles, unittest]
import ../src/[config, datapack_writer, ir]

test "writes functions and tags":
  let folder = createTempDir("poplar", "")
  defer: removeDir(folder)
  let program = Program(
    functions: @[McFunction(name: "main", commands: @[RawCommand(raw: "say hi"),
                                                      FunctionCommand(function: "other")])],
    load: some(McFunction(name: "poplar/load", commands: @[
      ScoreSetIfUnsetCommand(scoreValue: ScoreValue(score: Score(holder: "$hp"), value: 20))])),
    tick: @["main"],
  )
  let packConfig = Config(zipName: "demo", namespace: "demo", description: "\"Demo\"",
                          minFormat: PackFormat(major: 121), maxFormat: PackFormat(major: 121))
  writeDatapack(folder, packConfig, program)

  check readFile(folder / "data/demo/function/main.mcfunction") == "say hi\nfunction demo:other\n"
  check readFile(folder / "data/demo/function/poplar/load.mcfunction") ==
    "execute unless score $hp poplar.demo matches -2147483648.. run scoreboard players set $hp poplar.demo 20\n"
  check readFile(folder / "data/minecraft/tags/function/load.json") ==
    "{\n    \"values\": [\"demo:poplar/load\"]\n}\n"
  check readFile(folder / "data/minecraft/tags/function/tick.json") ==
    "{\n    \"values\": [\"demo:main\"]\n}\n"

test "writes a zip with each file stored after its name":
  let pack = createTempDir("poplar", "")
  defer: removeDir(pack)
  writeFile(pack / "pack.mcmeta", "{}")
  createDir(pack / "data/demo/function")
  writeFile(pack / "data/demo/function/main.mcfunction", "say hi\n")

  let zipPath = pack.parentDir / pack.lastPathPart & ".zip"
  defer: removeFile(zipPath)
  writeZip(pack, zipPath)
  let zip = readFile(zipPath)
  check "data/demo/function/main.mcfunctionsay hi\n" in zip
  check "pack.mcmeta{}" in zip
  # The end record counts 2 files.
  let endRecord = zip.rfind("PK\x05\x06")
  check endRecord >= 0
  check zip[endRecord + 8] == '\x02'
