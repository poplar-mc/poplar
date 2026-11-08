import std/[options, os, tempfiles, unittest]
import ../src/project

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
  var mcfunCount = 0
  for loaded in built.programs: mcfunCount += loaded.program.mcfuns.len
  check mcfunCount == 3

  writeFile(folder / "src" / "broken.poplar", "import magic;\nmcfun three() {}\n")
  check build(folder, options).summary.isNone
