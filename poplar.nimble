import std/[os, strutils]

version = "0.5.1"
author = "Jordan Baron"
description = "A programming language that compiles to Minecraft Java datapacks"
license = "MIT"
srcDir = "src"
binDir = "bin"
bin = @["poplar"]

requires "nim >= 2.4.0"

task test, "Run the unit tests":
  for file in listFiles("tests"):
    if file.extractFilename.startsWith("test_") and file.endsWith(".nim"):
      exec "nim c -r --hints:off --outdir:bin/tests " & file
