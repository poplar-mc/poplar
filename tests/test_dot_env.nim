import std/unittest
import ../src/dot_env

func describe(lookup: Lookup): string =
  case lookup
  of ValueLookup(value): "value " & value
  of MissingLookup: "missing"
  of InvalidLineLookup(line): "invalid line " & $line

test "find":
  let text = "# my world\nOTHER=1\nexport POPLAR_WORLD = \"/home/me/saves/My World\"\n"
  check find(text, "POPLAR_WORLD").describe == "value /home/me/saves/My World"
  check find(text, "OTHER").describe == "value 1"
  check find(text, "NONE").describe == "missing"
  check find("A=1\nnot a pair\n", "A").describe == "invalid line 2"
