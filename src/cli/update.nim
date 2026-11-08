## `poplar update`: finds the latest release on GitHub and runs the install script.

import std/[json, options, os, osproc, strformat, strtabs, strutils, terminal]
import command_line, output, root

const latestReleaseUrl = "https://api.github.com/repos/poplar-mc/poplar/releases/latest"
const installScriptUrl = "https://raw.githubusercontent.com/poplar-mc/poplar/main/install"

type Version = object
  ## A semantic version: `0.6.0`, `1.0.0-beta.1`.
  numbers: array[3, int]
  prerelease: seq[string]

func parseVersion(text: string): Option[Version] =
  var core = text.split('+')[0]
  var version: Version
  let dash = core.find('-')
  if dash >= 0:
    version.prerelease = core[dash + 1 .. ^1].split('.')
    core = core[0..<dash]
  let parts = core.split('.')
  if parts.len != 3: return none(Version)
  for index, part in parts:
    if part.len == 0 or not part.allCharsInSet(Digits): return none(Version)
    version.numbers[index] = parseInt(part)
  some(version)

func `$`(version: Version): string =
  result = version.numbers.join(".")
  if version.prerelease.len > 0: result.add "-" & version.prerelease.join(".")

func isNewer(a, b: Version): bool =
  ## True if `a` comes after `b`. A version with a prerelease comes before the same version without
  ## one.
  for index in 0..<3:
    if a.numbers[index] != b.numbers[index]: return a.numbers[index] > b.numbers[index]
  if a.prerelease.len == 0 or b.prerelease.len == 0:
    return a.prerelease.len == 0 and b.prerelease.len > 0
  for index in 0..<min(a.prerelease.len, b.prerelease.len):
    let (left, right) = (a.prerelease[index], b.prerelease[index])
    if left == right: continue
    let (leftNumber, rightNumber) = (left.allCharsInSet(Digits), right.allCharsInSet(Digits))
    if leftNumber and rightNumber: return parseInt(left) > parseInt(right)
    if leftNumber != rightNumber: return rightNumber
    return left > right
  a.prerelease.len > b.prerelease.len

proc latestRelease(): (string, string) =
  ## The tag and the page of the latest release. GitHub's API answers only requests that name their
  ## client.
  let (body, code) = execCmdEx(&"curl -fsSL -H \"User-Agent: poplar/{version}\" {latestReleaseUrl}")
  if code != 0: raise newException(IOError, body.strip.splitLines[^1])
  let release = parseJson(body)
  (release["tag_name"].getStr, release["html_url"].getStr)

proc runInstallScript(shared: Shared) =
  ## The same command as the README. `POPLAR_PREFIX` is the folder above this binary's `bin/`, so
  ## the script replaces the copy that is running instead of installing a second one.
  let environment = newStringTable()
  for key, value in envPairs(): environment[key] = value
  environment["POPLAR_PREFIX"] = getAppDir().parentDir
  let process =
    when defined(windows):
      startProcess("powershell", args = ["-NoProfile", "-ExecutionPolicy", "Bypass", "-Command",
                                         &"irm {installScriptUrl}.ps1 | iex"], env = environment,
                   options = {poUsePath, poParentStreams})
    else:
      startProcess("sh", args = ["-c", &"curl -fsSL {installScriptUrl}.sh | sh"], env = environment,
                   options = {poUsePath, poParentStreams})
  if process.waitForExit() != 0:
    shared.output.failure("The update failed")
    fail()

proc register*(shared: Shared): Command =
  proc run(invocation: Invocation) =
    let output = shared.output
    var tag, page: string
    try:
      (tag, page) = latestRelease()
    except CatchableError as error:
      output.failure(&"Could not check for updates: {error.msg}")
      fail()
    var unprefixed = tag
    unprefixed.removePrefix('v')
    let latest = parseVersion(unprefixed)
    if latest.isNone:
      output.failure(&"Could not check for updates: the latest release has the tag '{tag}'")
      fail()
    if not latest.get.isNewer(parseVersion(version).get):
      output.success(&"poplar {version} is the latest version")
      return

    stdout.write &"You have poplar {version}. {latest.get} is available: {page}\n"
    if not invocation.isSet("yes"):
      if not stdin.isatty:
        stdout.write &"Run {output.bold}poplar update --yes{output.reset} to update\n"
        return
      stdout.write "Update now? [y/N] "
      stdout.flushFile()
      var answer = ""
      discard stdin.readLine(answer)
      if answer.strip(chars = {' ', '\t', '\r'}).toLowerAscii notin ["y", "yes"]: return
    stdout.flushFile()
    runInstallScript(shared)
  result = newCommand("update", "Update Poplar to the latest release", run)
  result.addFlag Flag(name: "yes", description: "Update without asking",
                      default: BoolFlag(isOn: false))
