## Builds each project in `tests/e2e/` with poplar, runs `function <name>:test` on a Minecraft server, and compares
## the `say` output with `expect.txt`. Downloads use curl, and the SHA-1 check uses sha1sum or shasum.
##
## usage: e2e <poplar> <mcmeta version.json> <tests dir> <cache dir> [--accept-eula]

import std/[algorithm, json, os, osproc, streams, strformat, strutils]

const manifestUrl = "https://piston-meta.mojang.com/mc/game/version_manifest_v2.json"
const eulaUrl = "https://aka.ms/MinecraftEULA"
const endMarker = "poplar-e2e-end"
  ## The harness says this after each test, so it knows where the output of the test ends.

const serverProperties = """
level-type=minecraft\:flat
generator-settings={"layers":[{"block":"minecraft:bedrock","height":1},{"block":"minecraft:stone","height":3}],"biome":"minecraft:plains"}
online-mode=false
generate-structures=false
spawn-protection=0
view-distance=3
simulation-distance=3
max-players=1
"""
  ## A flat world needs its layers in `generator-settings`, or the server logs an error.

type TestProject = object
  name: string
  expected: seq[string]

proc stop(message: string) {.noreturn.} =
  stderr.write message & "\n"
  quit(1)

proc download(url, path: string) =
  let (output, code) = execCmdEx(&"curl -fsSL -o {quoteShell(path)} {quoteShell(url)}", options = {poUsePath})
  if code != 0: stop(&"download of {url} failed: {output.strip}")

proc sha1Hex(path: string): string =
  let command = if findExe("sha1sum").len > 0: "sha1sum " else: "shasum -a 1 "
  let (output, code) = execCmdEx(command & quoteShell(path), options = {poUsePath})
  if code != 0: stop(&"cannot compute the SHA-1 of {path}: {output.strip}")
  output.split(' ')[0]

proc loadVersionInfo(cachePath, versionId: string): JsonNode =
  ## The version JSON is kept in the cache, so a run with the jar already there needs no network.
  let cached = cachePath / versionId & ".json"
  if not fileExists(cached):
    let manifestPath = cachePath / "version_manifest.json"
    download(manifestUrl, manifestPath)
    var url = ""
    for version in parseJson(readFile(manifestPath))["versions"]:
      if version["id"].getStr == versionId: url = version["url"].getStr
    if url.len == 0: stop(&"Minecraft version '{versionId}' is not in the Mojang version manifest")
    download(url, cached)
  parseJson(readFile(cached))

proc ensureServerJar(jarPath, url, sha1: string) =
  if fileExists(jarPath) and sha1Hex(jarPath) == sha1: return
  stderr.write &"downloading {url}\n"
  download(url, jarPath)
  if sha1Hex(jarPath) != sha1: stop("the downloaded server jar has the wrong SHA-1")

proc checkJava(versionId: string, required: int) =
  const hint = "Install a JDK from your package manager, for example: nix-env -iA nixpkgs.jdk"
  if findExe("java").len == 0:
    stop(&"Minecraft {versionId} needs Java {required}, but 'java' was not found. {hint}{required}")
  # `java -version` writes `openjdk version "25.0.1" ...` to stderr.
  let (output, _) = execCmdEx("java -version", options = {poUsePath, poStdErrToStdOut})
  const marker = "version \""
  let start = output.find(marker) + marker.len
  var versionEnd = start
  while versionEnd < output.len and output[versionEnd] notin {'.', '"'}: inc versionEnd
  let major = try: parseInt(output[start ..< versionEnd]) except ValueError: 0
  if major < required:
    stop(&"Minecraft {versionId} needs Java {required}, but 'java' is version {major}. {hint}{required}")

func trimLine(line: string): string = line.strip(leading = false, chars = {'\r'})

proc nonEmptyLines(text: string): seq[string] =
  for line in text.splitLines:
    let trimmed = line.strip(chars = {' ', '\t', '\r'})
    if trimmed.len > 0: result.add trimmed

proc buildTestProjects(poplarPath, testsPath, serverPath: string, failed: var int): seq[TestProject] =
  ## Builds each folder in the tests folder with poplar, and copies its datapack into the world. A copy, not a
  ## symbolic link: Minecraft rejects datapacks that are links.
  var names: seq[string]
  for kind, path in walkDir(testsPath, relative = true):
    if kind == pcDir: names.add path
  names.sort()

  for name in names:
    let projectPath = testsPath / name
    let (output, code) = execCmdEx(quoteShell(poplarPath) & " build " & quoteShell(projectPath))
    if code != 0:
      stderr.write &"FAIL {name}: poplar build failed\n{output}"
      inc failed
      continue

    # `poplar-out/` holds one folder for the pack, named by poplar.json, and the zip.
    for kind, pack in walkDir(projectPath / "poplar-out"):
      if kind == pcDir: copyDir(pack, serverPath / "world" / "datapacks" / pack.lastPathPart)
    result.add TestProject(name: name, expected: nonEmptyLines(readFile(projectPath / "expect.txt")))

proc serverMessage(line: string): string =
  ## `[12:00:00] [Server thread/INFO]: [Not Secure] [Server] hello` → `hello`. `[Not Secure] ` is not always there.
  ## Empty for any other line.
  let start = line.find("]: ")
  if start < 0: return ""
  var message = line[start + 3 .. ^1]
  message.removePrefix("[Not Secure] ")
  if not message.startsWith("[Server] "): return ""
  trimLine(message["[Server] ".len .. ^1])

proc printLines(label: string, lines: seq[string]) =
  stderr.write &"  {label}:\n"
  for line in lines: stderr.write &"    {line}\n"

proc runServer(serverPath, jarPath: string, projects: seq[TestProject]): int =
  ## Starts the server, runs `function <name>:test` for each project, and compares the `[Server]` messages.
  stderr.write "starting the Minecraft server\n"
  # The server's stderr goes into the log too: a pipe that nothing reads could fill and stop the server.
  let server = startProcess("java", serverPath, ["-Xmx1G", "-jar", jarPath, "nogui"],
                            options = {poUsePath, poStdErrToStdOut})
  let log = server.outputStream
  let input = server.inputStream
  let logHint = &"see {serverPath}/logs/latest.log"

  var isReady = false
  var line: string
  while log.readLine(line):
    # An error while loading means that the compiler wrote a command that Minecraft does not accept.
    if "/ERROR]" in line:
      stderr.write &"server error: {trimLine(line)}\n"
      inc result
    if "Done (" in line:
      isReady = true
      break
  if not isReady:
    stderr.write &"FAIL: the server stopped before it was ready, {logHint}\n"
    discard server.waitForExit()
    return result + projects.len

  for project in projects:
    input.write &"function {project.name}:test\nsay {endMarker}\n"
    input.flush()

    var messages, otherOutput: seq[string]
    var hasEnd = false
    while log.readLine(line):
      let message = serverMessage(line)
      if message.len == 0:
        otherOutput.add trimLine(line)
        continue
      if message == endMarker:
        hasEnd = true
        break
      messages.add message

    if hasEnd and messages == project.expected:
      stderr.write &"PASS {project.name}\n"
      continue

    inc result
    stderr.write &"FAIL {project.name}\n"
    printLines("expected", project.expected)
    printLines("actual", messages)
    printLines("other output", otherOutput)
    if not hasEnd:
      stderr.write &"  the server stopped during this test, {logHint}\n"
      discard server.waitForExit()
      return

  input.write "stop\n"
  input.flush()
  while log.readLine(line): discard
  discard server.waitForExit()

proc run(poplarPath, versionPath, testsPath, cachePath: string, acceptEula: bool): int =
  ## Returns the number of failed tests.
  let versionId = parseJson(readFile(versionPath))["id"].getStr
  createDir(cachePath)

  let info = loadVersionInfo(cachePath, versionId)
  checkJava(versionId, info["javaVersion"]["majorVersion"].getInt)
  if not acceptEula:
    stop(&"The Minecraft server needs the Minecraft EULA to be accepted: {eulaUrl}\n" &
         "If you accept it, run: nimble e2e --accept-eula")

  let jarName = &"server-{versionId}.jar"
  let server = info["downloads"]["server"]
  ensureServerJar(cachePath / jarName, server["url"].getStr, server["sha1"].getStr)

  let serverPath = cachePath / "server"
  removeDir(serverPath)
  createDir(serverPath / "world" / "datapacks")
  writeFile(serverPath / "eula.txt", "eula=true\n")
  writeFile(serverPath / "server.properties", serverProperties)

  var failed = 0
  let projects = buildTestProjects(poplarPath, testsPath, serverPath, failed)
  failed += runServer(serverPath, ".." / jarName, projects)
  stderr.write &"\n{failed} failed\n"
  failed

when isMainModule:
  let arguments = commandLineParams()
  if arguments.len < 4:
    stderr.write "usage: e2e <poplar> <mcmeta version.json> <tests dir> <cache dir> [--accept-eula]\n"
    quit(2)
  let failed = run(arguments[0], arguments[1], arguments[2], arguments[3],
                   arguments.len > 4 and arguments[4] == "--accept-eula")
  quit(min(failed, 255))
