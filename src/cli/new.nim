import std/[os, strformat]
import ../project
import command_line, output, root

proc register*(shared: Shared): Command =
  proc run(invocation: Invocation) =
    let output = shared.output
    let path = invocation.arg("name")
    createDir(path)
    for _ in walkDir(path):
      output.failure(&"{output.bold}{path}{output.reset} is not empty")
      fail()

    writeNewProject(path, lastPathPart(path))
    output.success(&"Made {output.bold}{path}{output.reset}")
    stdout.write &"  {output.dim}Next: cd \"{path}\" && poplar build{output.reset}\n"
  result = newCommand("new", "Make a new project folder", run)
  result.addPositionalArg PositionalArg(name: "name", description: "The folder to make. Its name is the pack name",
                                        required: true)
