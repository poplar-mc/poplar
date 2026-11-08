## Commands, flags and positional arguments: parsing the command line and printing help. It gives the same help
## pages and messages as the zli library that Poplar 0.5 used. Help and parse errors go to stdout.

import std/[algorithm, sequtils, strformat, strutils, tables]

type
  FlagKind* = enum
    fkBool = "Bool", fkString = "String"

  Flag* = object
    name*: string
    ## One letter, or empty.
    shortcut*: string
    description*: string
    kind*: FlagKind
    ## `true` or `false` for a bool flag.
    default*: string
    persistent: bool

  PositionalArg* = object
    name*, description*: string
    required*: bool

  Invocation* = object
    ## The command that runs, with its flag values and positional arguments.
    command*: Command
    flagValues: Table[string, string]
    args: seq[string]

  Command* = ref object
    name*, description*: string
    ## Shown under the description of the help page, as `v0.6.0`.
    version*: string
    flags: seq[Flag]
    positionalArgs: seq[PositionalArg]
    commands: seq[Command]
    parent: Command
    run: proc (invocation: Invocation)

  CommandLineError* = object of CatchableError
    ## The message is printed already.

const
  bold = "\e[1m"
  dim = "\e[2m"
  reset = "\e[0m"
  padding = 5

const helpFlag = Flag(name: "help", shortcut: "h", description: "Shows the help for a command", kind: fkBool,
                      default: "false", persistent: true)

proc newCommand*(name, description: string, run: proc (invocation: Invocation), version = ""): Command =
  Command(name: name, description: description, version: version, flags: @[helpFlag], run: run)

proc addFlag*(command: Command, flag: Flag) = command.flags.add flag

proc addPositionalArg*(command: Command, arg: PositionalArg) = command.positionalArgs.add arg

proc addCommand*(command, subcommand: Command) =
  subcommand.parent = command
  for flag in command.flags:
    if flag.persistent and not subcommand.flags.anyIt(it.name == flag.name): subcommand.flags.add flag
  command.commands.add subcommand

func flag*(invocation: Invocation, name: string): string = invocation.flagValues[name]

func isSet*(invocation: Invocation, name: string): bool = invocation.flagValues[name] == "true"

func arg*(invocation: Invocation, name: string): string =
  ## The positional argument called `name`, or empty when it is not given.
  for index, positional in invocation.command.positionalArgs:
    if positional.name == name and index < invocation.args.len: return invocation.args[index]
  ""

# ---- help

func path(command: Command): string =
  ## `poplar build`: the command's path from the root.
  if command.parent == nil: command.name else: command.parent.path & " " & command.name

func flagWidth(flag: Flag): int = flag.name.len + 2 + (if flag.shortcut.len > 0: flag.shortcut.len + 3 else: 0)

func descriptionColumn(command: Command): int =
  ## Where descriptions start, after the row indent, so commands, flags and args line up.
  var widest = 0
  for subcommand in command.commands: widest = max(widest, subcommand.name.len)
  for flag in command.flags: widest = max(widest, flagWidth(flag))
  for arg in command.positionalArgs: widest = max(widest, arg.name.len)
  widest + padding

func describe(column, nameWidth: int, description: string): string =
  result = ' '.repeat(column - nameWidth)
  let lines = description.split('\n')
  for index, line in lines:
    if index > 0:
      result.add '\n'
      if line.len > 0: result.add ' '.repeat(3 + column)
    result.add line

proc helpText*(command: Command): string =
  let column = command.descriptionColumn
  result = &"{bold}{command.description}{reset}\n"
  if command.version.len > 0: result.add &"{dim}v{command.version}{reset}\n"
  result.add "\nUsage: " & command.path & " [options]"
  for arg in command.positionalArgs:
    result.add(if arg.required: &" <{arg.name}>" else: &" [{arg.name}]")
  result.add '\n'

  if command.commands.len > 0:
    result.add "\nAvailable commands:\n"
    for subcommand in command.commands.sortedByIt(it.name):
      result.add &"   {bold}{subcommand.name}{reset}" & describe(column, subcommand.name.len, subcommand.description) &
                 "\n"
  result.add '\n'

  if command.flags.len > 0:
    result.add "Flags:\n"
    for flag in command.flags.sortedByIt(it.name):
      result.add "   " & bold
      if flag.shortcut.len > 0: result.add &"-{flag.shortcut}, "
      result.add &"--{flag.name}{reset}" & describe(column, flagWidth(flag), flag.description) & &" [{flag.kind}]"
      if flag.kind == fkBool: result.add &" (default: {flag.default})"
      elif flag.default.len > 0: result.add &" (default: \"{flag.default}\")"
      result.add '\n'
    result.add '\n'

  if command.positionalArgs.len > 0:
    result.add "Arguments:\n"
    for arg in command.positionalArgs:
      result.add &"   {bold}{arg.name}{reset}" & describe(column, arg.name.len, arg.description)
      if arg.required: result.add " (required)"
      result.add '\n'
    result.add '\n'

# ---- parsing

proc failWith(command: Command, message: string, showHelpHint = true) {.noreturn.} =
  stdout.write message & "\n"
  if showHelpHint: stdout.write &"\nRun: '{command.path} --help'\n"
  raise newException(CommandLineError, message)

func findFlag(command: Command, nameOrShortcut: string): int =
  for index, flag in command.flags:
    if flag.name == nameOrShortcut: return index
  for index, flag in command.flags:
    if flag.shortcut == nameOrShortcut: return index
  -1

proc setFlag(command: Command, values: var Table[string, string], flag: Flag, value: string) =
  if flag.kind == fkBool and value notin ["true", "false"]:
    command.failWith(&"Invalid value for flag --{flag.name}: '{value}'\nExpected a value of type: {flag.kind}")
  values[flag.name] = value

proc checkPositionalArgs(command: Command, args: seq[string]) =
  let required = command.positionalArgs.filterIt(it.required)
  if args.len < required.len:
    command.failWith(&"Missing {required.len - args.len} positional argument(s).\n\nExpected: " &
                     required.mapIt(it.name).join(", "))
  if args.len > command.positionalArgs.len:
    command.failWith(&"Too many positional arguments. Expected at most {command.positionalArgs.len}, got {args.len}.")

proc defaultValues(command: Command): Table[string, string] =
  for flag in command.flags: result[flag.name] = flag.default

proc parse*(root: Command, arguments: seq[string]): Invocation =
  ## Raises `CommandLineError` after it printed the problem. A help request prints the help and gives no command.
  var command = root
  var values = root.defaultValues
  var positionals: seq[string]
  var inPositionals = false
  var index = 0
  while index < arguments.len:
    let argument = arguments[index]
    inc index

    if argument == "--":
      positionals.add arguments[index .. ^1]
      break

    # Words, "", "-" and negative numbers like -5 or -1.5 are subcommands or positional args.
    if argument.len < 2 or argument[0] != '-' or argument[1].isDigit:
      if not inPositionals:
        let found = command.commands.filterIt(it.name == argument)
        if found.len > 0:
          # Persistent flags given before the subcommand carry down to it.
          let carried = values
          command = found[0]
          values = command.defaultValues
          for flag in command.flags:
            if flag.persistent and flag.name in carried: values[flag.name] = carried[flag.name]
          continue
        if command.positionalArgs.len == 0: command.failWith(&"Unknown command: '{argument}'")
        inPositionals = true
      positionals.add argument
    elif argument[1] == '-':
      # --name, --name=value or --no-name
      let body = argument[2 .. ^1]
      let equals = body.find('=')
      let name = if equals >= 0: body[0 ..< equals] else: body
      let flagIndex = command.findFlag(name)
      if flagIndex >= 0:
        let flag = command.flags[flagIndex]
        if equals >= 0:
          command.setFlag(values, flag, body[equals + 1 .. ^1])
        elif flag.kind == fkBool:
          values[flag.name] = "true"
        else:
          if index >= arguments.len:
            command.failWith(&"Missing value for flag --{flag.name} of type: {flag.kind}")
          command.setFlag(values, flag, arguments[index])
          inc index
        continue

      # Tried after the full name, so a flag named like "no-cache" still works.
      let negated = if equals < 0 and name.startsWith("no-"): command.findFlag(name[3 .. ^1]) else: -1
      if negated < 0: command.failWith(&"Unknown flag: --{body}")
      let flag = command.flags[negated]
      if flag.kind != fkBool:
        command.failWith(&"Flag --{flag.name} does not accept negation as it expects type: {flag.kind}",
                         showHelpHint = false)
      values[flag.name] = "false"
    else:
      # -v, or a group like -vt 2 where only the last shortcut may take a value
      let shortcuts = argument[1 .. ^1]
      for position, letter in shortcuts:
        let flagIndex = command.findFlag($letter)
        if flagIndex < 0: command.failWith(&"Unknown flag shortcut: -{letter}")
        let flag = command.flags[flagIndex]
        if flag.kind == fkBool:
          values[flag.name] = "true"
        elif position < shortcuts.len - 1:
          command.failWith(&"Flag -{letter} ({flag.name}) must be last in group since it expects a value of type: " &
                           $flag.kind, showHelpHint = false)
        else:
          if index >= arguments.len:
            command.failWith(&"Missing value for flag -{letter} ({flag.name}) of type: {flag.kind}")
          command.setFlag(values, flag, arguments[index])
          inc index

  result = Invocation(command: command, flagValues: values, args: positionals)
  if values.getOrDefault("help") == "true":
    stdout.write command.helpText
    result.command = nil
    return
  command.checkPositionalArgs(positionals)

proc execute*(root: Command, arguments: seq[string]): int =
  ## Runs the command that the arguments name. Gives the exit code: 1 when the command line has a problem.
  try:
    let invocation = root.parse(arguments)
    if invocation.command != nil: invocation.command.run(invocation)
    0
  except CommandLineError:
    1
