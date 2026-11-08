import std/[monotimes, options, strformat, times]
import ../project
import output, root

proc printBuilt*(output: Output, summary: Summary, milliseconds: int64) =
  ## `✓ Built hello in 18 ms → poplar-out/hello (7 functions, zip)`
  output.success(&"Built {output.bold}{summary.name}{output.reset} in {milliseconds} ms {output.dim}→ " &
                 &"{summary.packPath.get} ({summary.functionCount} {summary.functionsText}, zip){output.reset}")

proc runBuild*(shared: Shared, projectPath: string) =
  let output = shared.output
  let started = getMonoTime()
  let built = build(projectPath, Options(stdPath: shared.stdPath, mode: moWrite))
  output.diagnostics(built.diagnostics)
  if built.summary.isNone:
    output.errorCount(built.diagnostics.len, ", nothing was written")
    fail()
  output.printBuilt(built.summary.get, (getMonoTime() - started).inMilliseconds)
