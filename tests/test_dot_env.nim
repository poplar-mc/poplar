import std/unittest
import ../src/dot_env

test "find":
  let text = "# my world\nOTHER=1\nexport POPLAR_WORLD = \"/home/me/saves/My World\"\n"
  check find(text, "POPLAR_WORLD").value == "/home/me/saves/My World"
  check find(text, "OTHER").value == "1"
  check find(text, "NONE").kind == lkMissing
  let invalid = find("A=1\nnot a pair\n", "A")
  check invalid.kind == lkInvalidLine
  check invalid.line == 2
