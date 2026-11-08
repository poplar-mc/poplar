## The `poplar` command.

import std/[os, terminal]
import project
import cli/[check, root]

when isMainModule:
  # Development builds and the e2e harness point to `std/` with `POPLAR_STD`.
  let shared = Shared(
    stdPath: getEnv("POPLAR_STD", installedStdPath()),
    color: not existsEnv("NO_COLOR") and stdout.isatty,
  )
  let arguments = commandLineParams()
  if arguments.len >= 1 and arguments[0] == "check":
    runCheck(shared, if arguments.len > 1: arguments[1] else: ".")
