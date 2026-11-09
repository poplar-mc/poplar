import std/[tempfiles, unittest]
include ../src/lsp

test "converts a byte column to a UTF-16 range that ends at the end of the word":
  let text = "var #é = 1;\n  /say ünknown #hp;\n"
  let range = diagnosticRange(text, some(Position(line: 2, column: 17)), enUtf16)
  check range["start"] == %*{"line": 1, "character": 15}
  check range["end"] == %*{"line": 1, "character": 18}

test "finds the word under the cursor with its sigil":
  let text = "#a = @s.$Inventory[0].count + $stats.maxHp + clamp(#hp);"
  check wordAt(text, 24) == some(Word(kind: wkEntityData, text: "Inventory[0].count"))
  check wordAt(text, 32) == some(Word(kind: wkData, text: "stats"))
  check wordAt(text, 38) == some(Word(kind: wkData, text: "stats.maxHp"))
  check wordAt(text, 46) == some(Word(kind: wkName, text: "clamp"))
  check wordAt(text, 52) == some(Word(kind: wkScore, text: "hp"))

test "converts Windows paths to URIs and back":
  let windowsPath = "C:\\My Packs\\src\\main.poplar"
  check pathToUri(windowsPath) == "file:///C:/My%20Packs/src/main.poplar"
  check uriToPath("file:///C:/My%20Packs/src/main.poplar") == some(windowsPath)
  check uriToPath("file:///c%3A/My%20Packs/src/main.poplar") == some(windowsPath)
  check uriToPath("file:///home/me/a%20b.poplar") == some("/home/me/a b.poplar")

test "an open document with an error gets a diagnostic, and loses it when it is fixed":
  let folder = createTempDir("poplar", "")
  defer: removeDir(folder)
  createDir(folder / "src")
  writeFile(folder / "src" / "main.poplar", "")
  writeFile(folder / "poplar.json", "{\"namespace\": \"test\"}")
  let uri = pathToUri(expandFilename(folder) / "src" / "main.poplar")

  var written: seq[JsonNode]
  let server = newLanguageServer("no-std", proc (meth: string, params: JsonNode) =
    written.add params)
  let source = "namespace test\nmcfun f:\n  #nope = 1\n"
  discard server.handle("textDocument/didOpen", %*{
    "textDocument": {"uri": uri, "languageId": "poplar", "version": 1, "text": source}})
  check written[^1]["diagnostics"][0]["range"] ==
    %*{"start": {"line": 2, "character": 2}, "end": {"line": 2, "character": 7}}

  written.setLen(0)
  discard server.handle("textDocument/didChange", %*{
    "textDocument": {"uri": uri, "version": 2},
    "contentChanges": [{"text": "namespace test\nmcfun f:\n"}]})
  check written[^1]["diagnostics"].len == 0
