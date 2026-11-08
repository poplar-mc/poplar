## Lines for people: a green ✓ or a red ✗ at the start, and dim details. There are colors only in a
## terminal, and not when NO_COLOR is set (https://no-color.org).

import std/[options, strformat, strutils]
import ../diagnostic

type Output* = object
  color*: bool

func bold*(output: Output): string = (if output.color: "\e[1m" else: "")
func dim*(output: Output): string = (if output.color: "\e[2m" else: "")
func reset*(output: Output): string = (if output.color: "\e[0m" else: "")
func green(output: Output): string = (if output.color: "\e[32m" else: "")
func red(output: Output): string = (if output.color: "\e[31m" else: "")
func yellow(output: Output): string = (if output.color: "\e[33m" else: "")

proc success*(output: Output, text: string) =
  stdout.write &"{output.green}✓{output.reset} {text}\n"

proc failure*(output: Output, text: string) =
  ## Failures go to stderr, so they still show when the normal output is piped somewhere.
  stdout.flushFile()
  stderr.write &"{output.red}✗{output.reset} {text}\n"

proc warning*(output: Output, text: string) =
  ## Something that works, but likely not as the user wants. It goes to stderr, like a failure.
  stdout.flushFile()
  stderr.write &"{output.yellow}!{output.reset} {text}\n"

proc diagnostics*(output: Output, list: openArray[Diagnostic]) =
  ## `✗ src/main.poplar:3:5  Message`, or the message alone when it has no position. The compiler's
  ## messages start in lowercase, which the language server shows as it is. On the command line each
  ## line starts with a capital.
  for diagnostic in list:
    let message = diagnostic.message.capitalizeAscii
    if diagnostic.position.isSome:
      let position = diagnostic.position.get
      let place = &"{diagnostic.path}:{position.line}:{position.column}"
      output.failure(&"{output.bold}{place}{output.reset}  {message}")
    elif diagnostic.path.len > 0:
      output.failure(&"{output.bold}{diagnostic.path}{output.reset}  {message}")
    else:
      output.failure(message)

proc errorCount*(output: Output, count: int, rest: string) =
  ## `✗ 2 errors, nothing was written`
  output.failure(&"""{count} error{(if count == 1: "" else: "s")}{rest}""")
