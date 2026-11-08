## The `poplar` command.

import std/[os, terminal]
import project
import cli/[build, check, command_line, init, lsp, new, root, update, watch]

when defined(posix):
  import std/posix

when isMainModule:
  when defined(posix):
    # Ctrl-C stops `poplar watch` at once, with no message, as it stops other command-line tools.
    discard posix.signal(SIGINT, SIG_DFL)
  # Development builds and the e2e harness point to `std/` with `POPLAR_STD`.
  let shared = Shared(
    stdPath: getEnv("POPLAR_STD", installedStdPath()),
    color: not existsEnv("NO_COLOR") and stdout.isatty,
  )
  let poplar = newRootCommand()
  for command in [new.register(shared), init.register(shared), build.register(shared), check.register(shared),
                  watch.register(shared), update.register(shared), lsp.register(shared)]:
    poplar.addCommand command
  let code = poplar.execute(commandLineParams())
  stdout.flushFile()
  quit(code)
