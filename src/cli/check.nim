import std/[options, strformat]
import ../project
import command_line, output, root

proc register*(shared: Shared): Command =
  proc run(invocation: Invocation) =
    let output = shared.output
    let built = build(invocation.projectPath, Options(stdPath: shared.stdPath, mode: moCheck))
    output.diagnostics(built.diagnostics)
    if built.summary.isNone:
      output.errorCount(built.diagnostics.len, "")
      fail()
    let summary = built.summary.get
    output.success(&"No errors in {output.bold}{summary.name}{output.reset} {output.dim}({summary.functionCount} " &
                   &"{summary.functionsText}){output.reset}")
  result = newCommand("check", "Find errors without writing any files", run)
  result.addPositionalArg dirArg
