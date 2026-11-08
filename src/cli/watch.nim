import std/[hashes, monotimes, options, os, strformat, strutils, times]
import ../[config, dot_env, project]
import build, command_line, output, root

const pollInterval = 300

const markerName = ".poplar-watch"
  ## The copy has this file, so `watch` only replaces a folder that it made itself.

type
  WorldCopy = object
    ## `--world`: after each build, the pack is copied into `<world>/datapacks/`. Minecraft does not follow symbolic
    ## links unless they are allowed in `allowed_symlinks.txt`, so it is a copy.
    datapacksPath: string
    ## Where the world came from, such as ` (POPLAR_WORLD from .env)`, or empty for `--world`.
    source: string
    copiedBefore: bool
    ## Set after an error, so that it is printed one time.
    failed: bool

  World = object
    path, source: string

proc isReplaceable(path: string): bool =
  ## Nothing there yet, a link from an older `watch`, or a copy with the marker.
  if symlinkExists(path) or not (fileExists(path) or dirExists(path)): return true
  dirExists(path) and fileExists(path / markerName)

proc update(copy: var WorldCopy, output: Output, projectPath, packPath: string) =
  if copy.failed: return
  let name = lastPathPart(packPath)
  let target = copy.datapacksPath / name
  let worldName = lastPathPart(copy.datapacksPath.parentDir)
  if not isReplaceable(target):
    copy.failed = true
    output.failure(&"{output.bold}{worldName}/datapacks/{name}{output.reset} already exists and was not made by " &
                   "poplar watch. Remove it, then run watch again")
    return
  if symlinkExists(target) or fileExists(target): removeFile(target) else: removeDir(target)

  let source = projectPath / packPath
  createDir(target)
  for path in walkDirRec(source, yieldFilter = {pcFile, pcDir}, relative = true):
    if dirExists(source / path): createDir(target / path) else: copyFile(source / path, target / path)
  writeFile(target / markerName, "Copied by poplar watch, which replaces this folder after each build.\n")

  if not copy.copiedBefore:
    output.success(&"Copied to {output.bold}{worldName}/datapacks/{name}{output.reset}{copy.source}. Run " &
                   &"{output.bold}/reload{output.reset} in the game after each build")
  copy.copiedBefore = true

proc expandHome(path: string): string =
  ## The shell turns `~/` into the home folder for `--world`, but not for a variable.
  if not path.startsWith("~/"): return path
  let home = getEnv("HOME", getEnv("USERPROFILE"))
  if home.len == 0: path else: home / path[2 .. ^1]

proc chooseWorld(shared: Shared, invocation: Invocation, projectPath: string): Option[World] =
  ## `--world`, else `POPLAR_WORLD` from the environment, else from the project's `.env`. None when none is set.
  let flag = invocation.flag("world")
  if flag.len > 0: return some(World(path: flag))
  if existsEnv("POPLAR_WORLD"):
    return some(World(path: expandHome(getEnv("POPLAR_WORLD")), source: " (POPLAR_WORLD from the environment)"))
  let lookup = dot_env.read(projectPath, "POPLAR_WORLD")
  case lookup.kind
  of lkValue: some(World(path: expandHome(lookup.value), source: " (POPLAR_WORLD from .env)"))
  of lkMissing: none(World)
  of lkInvalidLine:
    let output = shared.output
    output.failure(&"{output.bold}{dot_env.fileName}:{lookup.line}{output.reset}  Expected KEY=VALUE")
    fail()

proc datapacksPath(output: Output, world: World): Option[string] =
  ## The `datapacks` folder of the world, made if the world has none yet. None after an error is printed.
  if not dirExists(world.path):
    output.failure(&"The world folder {output.bold}{world.path}{output.reset}{world.source} does not exist")
    return none(string)
  let worldPath = expandFilename(world.path)
  if not fileExists(worldPath / "level.dat"):
    output.failure(&"{output.bold}{world.path}{output.reset}{world.source} is not a Minecraft world: it has no " &
                   "level.dat")
    return none(string)
  createDir(worldPath / "datapacks")
  some(worldPath / "datapacks")

proc fingerprint(projectPath: string): Hash =
  ## A hash of the path, size and change time of poplar.json and of every file in src/.
  var files: seq[string]
  if fileExists(projectPath / config.fileName): files.add config.fileName
  if dirExists(projectPath / "src"):
    for path in walkDirRec(projectPath / "src", relative = true): files.add "src" / path
  for path in files:
    try:
      let info = getFileInfo(projectPath / path)
      result = result !& hash(path) !& hash(info.size) !& hash(info.lastWriteTime.toUnixFloat)
    except OSError:
      discard
  !$result

proc rebuild(shared: Shared, projectPath: string, worldCopy: var Option[WorldCopy]) =
  let output = shared.output
  let started = getMonoTime()
  let built = build(projectPath, Options(stdPath: shared.stdPath, mode: moWrite))
  output.diagnostics(built.diagnostics)

  # The time of day (UTC), so that each build is easy to tell apart.
  stdout.write output.dim & now().utc.format("HH:mm:ss") & " UTC" & output.reset & " "
  if built.summary.isSome:
    output.printBuilt(built.summary.get, (getMonoTime() - started).inMilliseconds)
    if worldCopy.isSome: worldCopy.get.update(output, projectPath, built.summary.get.packPath.get)
  else:
    output.errorCount(built.diagnostics.len, ", waiting for changes")
  stdout.flushFile()

proc register*(shared: Shared): Command =
  proc run(invocation: Invocation) =
    let output = shared.output
    let projectPath = invocation.projectPath
    var worldCopy = none(WorldCopy)
    let world = chooseWorld(shared, invocation, projectPath)
    if world.isSome:
      let datapacks = datapacksPath(output, world.get)
      if datapacks.isNone: fail()
      worldCopy = some(WorldCopy(datapacksPath: datapacks.get, source: world.get.source))
    else:
      output.warning(&"No world specified, so builds are not copied anywhere. Use {output.bold}--world" &
                     &"{output.reset}, or set {output.bold}POPLAR_WORLD{output.reset} in .env")

    var lastFingerprint = fingerprint(projectPath)
    rebuild(shared, projectPath, worldCopy)
    while true:
      sleep(pollInterval)
      let current = fingerprint(projectPath)
      if current == lastFingerprint: continue
      lastFingerprint = current
      rebuild(shared, projectPath, worldCopy)
  result = newCommand("watch", "Build again each time a file in src/ or poplar.json changes", run)
  result.addPositionalArg dirArg
  result.addFlag Flag(name: "world", kind: fkString, description: "A world folder. Each build is copied into its " &
                      "datapacks/ folder, so /reload loads it (default: POPLAR_WORLD from the environment or .env)")
