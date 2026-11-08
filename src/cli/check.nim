import std/[options, strformat]
import ../project
import output, root

proc runCheck*(shared: Shared, projectPath: string) =
  let output = shared.output
  let built = build(projectPath, Options(stdPath: shared.stdPath, mode: moCheck))
  output.diagnostics(built.diagnostics)
  if built.summary.isNone:
    output.errorCount(built.diagnostics.len, "")
    fail()
  let summary = built.summary.get
  output.success(&"No errors in {output.bold}{summary.name}{output.reset} {output.dim}({summary.functionCount} " &
                 &"{summary.functionsText}){output.reset}")
