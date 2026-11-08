## What every command shares, and the `poplar` command itself.

import std/strutils
import output

type Shared* = object
  ## What `main` passes to every command.
  stdPath*: string ## The folder of the standard library, which `import std;` loads.
  color*: bool

const version* = static:
  var found = ""
  for line in staticRead("../../poplar.nimble").splitLines:
    if line.startsWith("version"): found = line.split('"')[1]
  found

func output*(shared: Shared): Output = Output(color: shared.color)

proc fail*() {.noreturn.} =
  ## Exits with code 1 after a command printed its own error messages.
  stdout.flushFile()
  quit(1)
