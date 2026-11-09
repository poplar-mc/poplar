import std/[os, strutils]

version = "0.7.0"
author = "Jordan Baron"
description = "A programming language that compiles to Minecraft Java datapacks"
license = "MIT"
srcDir = "src"
binDir = "bin"
bin = @["poplar"]

requires "nim >= 2.4.0"

task e2e, "Run the test projects on a Minecraft server. --accept-eula accepts the Minecraft EULA":
  exec "nim c -d:release --hints:off -o:bin/poplar src/poplar.nim"
  exec "nim c -d:release --hints:off -o:bin/e2e tools/e2e.nim"
  putEnv("POPLAR_STD", thisDir() / "std")
  let acceptEula = if "--accept-eula" in commandLineParams: " --accept-eula" else: ""
  exec "bin/e2e bin/poplar mcmeta/version.json tests/e2e .e2e" & acceptEula

task test, "Run the unit tests":
  for file in listFiles("tests"):
    if file.extractFilename.startsWith("test_") and file.endsWith(".nim"):
      exec "nim c -r --hints:off --outdir:bin/tests " & file
