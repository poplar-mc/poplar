## `poplar build`: compiles the project into `poplar-out/`. `poplar watch` uses `printBuilt` too.

import std/[monotimes, options, strformat, times]
import ../project
import command_line, output, root

proc printBuilt*(output: Output, summary: Summary, milliseconds: int64) =
  ## `✓ Built hello in 18 ms → poplar-out/hello (7 functions, zip)`
  output.success(&"Built {output.bold}{summary.name}{output.reset} in {milliseconds} ms " &
                 &"{output.dim}→ {summary.packPath.get} " &
                 &"({summary.functionCount} {summary.functionsText}, zip){output.reset}")

proc register*(shared: Shared): Command =
  proc run(invocation: Invocation) =
    let output = shared.output
    let started = getMonoTime()
    let built = build(invocation.projectPath, Options(stdPath: shared.stdPath, mode: moWrite))
    output.diagnostics(built.diagnostics)
    if built.summary.isNone:
      output.errorCount(built.diagnostics.len, ", nothing was written")
      fail()
    output.printBuilt(built.summary.get, (getMonoTime() - started).inMilliseconds)
  result = newCommand("build", "Compile the project into poplar-out/", run)
  result.addPositionalArg dirArg
