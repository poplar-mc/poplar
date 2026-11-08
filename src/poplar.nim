## The `poplar` command.

import std/[os, terminal]
import project
import cli/[build, check, root]

when isMainModule:
  # Development builds and the e2e harness point to `std/` with `POPLAR_STD`.
  let shared = Shared(
    stdPath: getEnv("POPLAR_STD", installedStdPath()),
    color: not existsEnv("NO_COLOR") and stdout.isatty,
  )
  let arguments = commandLineParams()
  let projectPath = if arguments.len > 1: arguments[1] else: "."
  if arguments.len >= 1 and arguments[0] == "check": runCheck(shared, projectPath)
  if arguments.len >= 1 and arguments[0] == "build": runBuild(shared, projectPath)
