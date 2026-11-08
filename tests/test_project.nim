import std/[algorithm, options, os, strutils, tables, tempfiles, unittest]
import ../src/[compiler, config, ir, project]

test "builds every file in src/, and std when a file imports it":
  let folder = createTempDir("poplar", "")
  defer: removeDir(folder)
  createDir(folder / "src" / "lib")
  createDir(folder / "std")
  writeFile(folder / "poplar.json", "{\"namespace\": \"game\"}")
  writeFile(folder / "src" / "main.poplar", "namespace game;\nimport std;\nmcfun one() {}\n")
  writeFile(folder / "src" / "lib" / "two.poplar", "namespace game;\nmcfun two() {}\n")
  writeFile(folder / "std" / "std.poplar", "namespace std;\nmcfun three() {}\n")

  let options = Options(stdPath: folder / "std", mode: moCheck)
  let built = build(folder, options)
  check built.diagnostics.len == 0
  check built.compiler.mcfuns.len == 3

  writeFile(folder / "src" / "broken.poplar", "import magic;\nmcfun three() {}\n")
  check build(folder, options).summary.isNone

test "only the std mcfuns that the project calls are written, under std/":
  let folder = createTempDir("poplar", "")
  defer: removeDir(folder)
  createDir(folder / "src")
  createDir(folder / "std")
  writeFile(folder / "poplar.json", "{\"namespace\": \"ns\"}")
  writeFile(folder / "src" / "main.poplar", "namespace ns;\nimport std;\nmcfun main() { /say {{ std:double() with " &
            "{x: 2} }}; /function std:fromCommand; }\n")
  writeFile(folder / "std" / "std.poplar", "namespace std;\nmcfun double() { return twice() with {x: $(x)}; }\n" &
            "mcfun twice() { return $(x) * 2; }\nmcfun fromCommand() {}\nmcfun unused() {}\n")

  let built = build(folder, Options(stdPath: folder / "std", mode: moCheck))
  check built.diagnostics.len == 0
  var names: seq[string]
  for function in built.compiler.compile().functions:
    if not function.name.startsWith("poplar/"): names.add function.name
  check names.sorted == @["main", "std/double", "std/fromCommand", "std/twice"]

test "makes a namespace from a project name":
  let namespace = namespaceFromName("My Pack!")
  check namespace == "my_pack_"
  check isValidResourceName(namespace)
