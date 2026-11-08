## Builds a project: reads `poplar.json`, then parses every file in `src/`, and the standard library when a file
## imports `std`.

import std/[algorithm, options, os, sets, strformat, strutils, tables]
import ast, config, diagnostic, lexer, parser

const outDirName* = "poplar-out"

type
  Mode* = enum
    moWrite, moCheck

  Origin* = enum
    ## Where a file comes from: the project's `src/` folder or the standard library.
    orProject, orStd

  Summary* = object
    ## `zipName`, the name of the pack.
    name*: string
    functionCount*: int
    ## `poplar-out/<zipName>`, or none for `moCheck`.
    packPath*, zipPath*: Option[string]

  Options* = object
    ## The folder of the standard library, which `import std;` loads.
    stdPath*: string
    mode*: Mode
    ## Absolute path → the text of a file that is open in an editor. It is read instead of the file on disk.
    overlay*: Table[string, string]

  LoadedProgram* = object
    origin*: Origin
    displayPath*: string
    program*: Program

  Result* = object
    ## None when there were errors.
    summary*: Option[Summary]
    diagnostics*: seq[Diagnostic]
    programs*: seq[LoadedProgram]
    ## Display path (`src/main.poplar`, `std/math.poplar`) → absolute path, for every file that was read.
    files*: OrderedTable[string, string]

  SourceFile = object
    ## A file to load. The path is relative to the folder of its origin.
    origin: Origin
    path: string

  Loader = object
    ## Parses every `.poplar` file in `src/`, and the standard library when a file imports `std`.
    srcPath: string
    stdPath: string
    overlay: Table[string, string]
    ## Set when a file imports `std`, so projects without it do not need the folder.
    stdRealPath: Option[string]
    diagnostics: seq[Diagnostic]
    programs: seq[LoadedProgram]
    files: OrderedTable[string, string]

func functionsText*(summary: Summary): string =
  if summary.functionCount == 1: "function" else: "functions"

func originFolder(origin: Origin): string =
  ## The folder name that a source's display path starts with.
  case origin
  of orProject: "src"
  of orStd: "std"

proc installedStdPath*(): string =
  ## Where the release archives put the standard library: `lib/poplar/std` next to the `bin` folder of the binary.
  getAppDir() & DirSep & ".." & DirSep & "lib" & DirSep & "poplar" & DirSep & "std"

proc sourceFiles(folder: string, origin: Origin): seq[SourceFile] =
  ## Every `.poplar` file under `folder`, sorted, so the build does not depend on the order of the file system.
  for path in walkDirRec(folder, yieldFilter = {pcFile}, relative = true):
    if path.endsWith(".poplar"): result.add SourceFile(origin: origin, path: path.replace(DirSep, '/'))
  result.sort(proc (a, b: SourceFile): int = cmp(a.path, b.path))

proc addError(loader: var Loader, path: string, position: Option[Position], message: string) =
  loader.diagnostics.add Diagnostic(path: path, position: position, message: message)

proc read(loader: var Loader, file: SourceFile, displayPath: string): Option[string] =
  ## The text of a file: from the overlay when an editor has it open, else from the disk. None if it does not exist.
  let rootPath = case file.origin
    of orProject: loader.srcPath
    of orStd: loader.stdRealPath.get
  let absolutePath = rootPath / file.path
  loader.files[displayPath] = absolutePath

  if absolutePath in loader.overlay: return some(loader.overlay[absolutePath])
  if not fileExists(absolutePath): return none(string)
  some(readFile(absolutePath))

proc parse(loader: var Loader, file: SourceFile, hasErrors: var bool): Option[LoadedProgram] =
  ## Parses one file. None if it has no `namespace` line. After another parse error the rest still loads, so the
  ## editor knows its names.
  let displayPath = originFolder(file.origin) / file.path
  let input = loader.read(file, displayPath)
  if input.isNone: return none(LoadedProgram)

  var fileParser = initParser(initLexer(input.get))
  let program = fileParser.parseProgram()
  for error in fileParser.errors:
    loader.addError(displayPath, error.position, error.message)
  if fileParser.errors.len > 0: hasErrors = true

  if program.namespace.isNone:
    # A broken `namespace` line already has its own error.
    if fileParser.errors.len == 0:
      loader.addError(displayPath, some(Position(line: 1, column: 1)), "a file must start with 'namespace <name>;'")
    hasErrors = true
    return none(LoadedProgram)
  some(LoadedProgram(origin: file.origin, displayPath: displayPath, program: program))

proc openStd(loader: var Loader): bool =
  if loader.stdRealPath.isSome: return true
  if not dirExists(loader.stdPath): return false
  loader.stdRealPath = some(expandFilename(loader.stdPath))
  true

proc load(loader: var Loader): bool =
  ## Returns false if there were errors.
  var hasErrors = false
  var programs: seq[LoadedProgram]

  let projectFiles = sourceFiles(loader.srcPath, orProject)
  if projectFiles.len == 0:
    loader.addError("", none(Position), "the src/ folder has no .poplar files")
    return false
  for file in projectFiles:
    let loaded = loader.parse(file, hasErrors)
    if loaded.isSome: programs.add loaded.get

  var namespaces: HashSet[string]
  var importsStd = false
  for loaded in programs:
    namespaces.incl loaded.program.namespace.get.name
    for imported in loaded.program.imports:
      if imported.name == "std": importsStd = true

  if importsStd:
    if loader.openStd():
      namespaces.incl "std"
      for file in sourceFiles(loader.stdRealPath.get, orStd):
        let loaded = loader.parse(file, hasErrors)
        if loaded.isSome: programs.add loaded.get
    else:
      loader.addError("", none(Position), &"cannot find the standard library at '{loader.stdPath}'")
      hasErrors = true

  for loaded in programs:
    for imported in loaded.program.imports:
      if imported.name in namespaces: continue
      loader.addError(loaded.displayPath, some(imported.position), &"no file has 'namespace {imported.name};'")
      hasErrors = true
  loader.programs = programs

  not hasErrors

proc onlyDiagnostic(path: string, position: Option[Position], message: string): Result =
  Result(diagnostics: @[Diagnostic(path: path, position: position, message: message)])

proc build*(projectPath: string, options: Options): Result =
  ## Compiles the project in `projectPath`, and writes the pack in `moWrite` mode. Errors in the user's files are in
  ## the result, not printed.
  if not dirExists(projectPath):
    return onlyDiagnostic("", none(Position), &"the project folder {projectPath} does not exist")
  let projectRealPath = expandFilename(projectPath)

  let packConfig =
    try:
      loadConfig(projectPath, lastPathPart(projectRealPath))
    except ConfigError as error:
      return onlyDiagnostic(fileName, error.position, error.msg)

  if not dirExists(projectPath / "src"):
    return onlyDiagnostic("", none(Position), &"the folder {projectPath} is not a Poplar project: it has no src/ folder")

  var loader = Loader(srcPath: projectRealPath / "src", stdPath: options.stdPath, overlay: options.overlay)
  let sourcesLoaded = loader.load()
  result.files = loader.files
  result.diagnostics = loader.diagnostics
  result.programs = loader.programs
  if not sourcesLoaded: return

  var functionCount = 0
  for loaded in loader.programs: functionCount += loaded.program.mcfuns.len
  result.summary = some(Summary(name: packConfig.zipName, functionCount: functionCount))
