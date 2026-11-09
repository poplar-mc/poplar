## What every command shares, and the `poplar` command itself.

import std/strformat
import ../config
import command_line, output

type Shared* = object
  ## What `main` passes to every command.
  stdPath*: string ## The folder of the standard library, which `import std` loads.
  color*: bool

const version* = poplarVersion

const dirArg* = PositionalArg(name: "dir",
                              description: "The project folder (default: the current folder)")

func output*(shared: Shared): Output = Output(color: shared.color)

proc fail*() {.noreturn.} =
  ## Exits with code 1 after a command printed its own error messages.
  stdout.flushFile()
  quit(1)

func projectPath*(invocation: Invocation): string =
  ## The project folder: the optional `dir` argument, or the current folder.
  let dir = invocation.arg("dir")
  if dir.len > 0: dir else: "."

proc newRootCommand*(): Command =
  proc showHelpOrVersion(invocation: Invocation) =
    if invocation.isSet("version"):
      stdout.write &"poplar {version} (Minecraft {minecraftVersion})\n"
    else: stdout.write invocation.command.helpText
  result = newCommand("poplar", "Compile Poplar code into Minecraft datapacks", showHelpOrVersion,
      version = version)
  result.addFlag Flag(name: "version", shortcut: "v", default: BoolFlag(isOn: false),
                      description: "Show the Poplar version and the Minecraft version it targets")
