import std/[os, strformat]
import ../[config, project]
import command_line, output, root

proc register*(shared: Shared): Command =
  proc run(invocation: Invocation) =
    let output = shared.output
    for path in [fileName, "src/main.poplar"]:
      if fileExists(path) or dirExists(path):
        output.failure(&"{output.bold}{path}{output.reset} already exists, so this folder has a project")
        fail()

    let folder = lastPathPart(getCurrentDir())
    try:
      writeNewProject(".", folder)
    except PathExistsError:
      output.failure("A project file already exists here")
      fail()
    output.success(&"Made a project in {output.bold}{folder}{output.reset}")
    stdout.write &"  {output.dim}Next: poplar build{output.reset}\n"
  newCommand("init", "Make a project in the current folder", run)
