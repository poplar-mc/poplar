## The language server: errors as the editor types, hover, go to definition and completion. `cli/lsp.nim` reads the
## messages and gives them to `handle`.

import std/[json, options, os, sequtils, sets, strformat, strutils, tables]
import ast except Command, Execute, Program, DataFile
import command_tree, compiler, config, data_folders, diagnostic, environment, project, token

type
  Encoding = enum
    ## How the editor counts characters in a line.
    enUtf8 = "utf-8", enUtf16 = "utf-16", enUtf32 = "utf-32"

  Analysis = ref object
    ## The last compile of one project. Hover, definition and completion read it.
    projectRoot: string
    result: Result

  WordKind = enum
    wkName, wkScore, wkData, wkEntityData

  Word = object
    kind: WordKind
    text: string
      ## Without the sigil. A data path goes up to the
      ## end of the part under the cursor: `stats.maxHp`.
    namespace: Option[string] ## `magic` in `magic:heal` or `#magic:mana`.

  Place = object
    ## The cursor in the compiler's terms: a display path such as `src/main.poplar`, and a line that starts at 1.
    path: string
    line: int

  Builtin = object
    name, signature, doc: string

  LanguageServer* = ref object
    stdPath: string
    encoding: Encoding
    documents: Table[string, string] ## URI → the text in the editor, which can be unsaved.
    published: OrderedTable[string, string]
      ## URI → the project root, for each file that has diagnostics in the editor now.
    commandTree: CommandTree
    analysis: Analysis
    notify: proc (meth: string, params: JsonNode) ## Sends a notification to the editor.

const builtins = [
  Builtin(name: "append", signature: "append($list, value)", doc: "Adds a value at the end of a list."),
  Builtin(name: "prepend", signature: "prepend($list, value)", doc: "Adds a value at the start of a list."),
  Builtin(name: "insert", signature: "insert($list, index, value)",
          doc: "Adds a value at an index. The index is a compile-time int."),
  Builtin(name: "remove", signature: "remove($list, index)",
          doc: "Removes the value at an index. The index is a compile-time int."),
  Builtin(name: "len", signature: "len(value)", doc: "The size of a list, compound or string."),
  Builtin(name: "text", signature: "text(value)",
          doc: "A text part that names a score or data. The game reads the value when it shows the text."),
  Builtin(name: "onEvent", signature: "onEvent(criteria, callback)",
          doc: "Runs the mcfun `callback` as a player each time the criteria counts for that player. Only in " &
               "`mcfun load`."),
  Builtin(name: "onTrigger", signature: "onTrigger(name, callback)",
          doc: "Makes `/trigger name` run the mcfun `callback` as the player who used it. Only in `mcfun load`."),
  Builtin(name: "onDeath", signature: "onDeath(callback)",
          doc: "Runs the mcfun `callback` as a player when the player dies. Only in `mcfun load`."),
  Builtin(name: "onFirstJoin", signature: "onFirstJoin(callback)",
          doc: "Runs the mcfun `callback` as a player the first time the player joins the world. Only in " &
               "`mcfun load`."),
  Builtin(name: "onJoin", signature: "onJoin(callback)",
          doc: "Runs the mcfun `callback` as a player each time the player joins, the first time too. Only in " &
               "`mcfun load`."),
  Builtin(name: "onRespawn", signature: "onRespawn(callback)",
          doc: "Runs the mcfun `callback` as a player when a dead player is alive again. Only in `mcfun load`."),
  Builtin(name: "slice", signature: "slice(text, start, end)",
          doc: "A substring: from `start` (included) to `end` (not included, optional). Negative bounds count from " &
               "the end. One `data modify ... set string` command."),
  Builtin(name: "str", signature: "str(value)", doc: "A number, score or math as a string: `$label = str(#kills);`."),
  Builtin(name: "startsWith", signature: "startsWith(text, \"prefix\")",
          doc: "A condition: the text starts with a constant prefix."),
  Builtin(name: "endsWith", signature: "endsWith(text, \"suffix\")",
          doc: "A condition: the text ends with a constant suffix."),
]

static: doAssert builtins.len == builtinNames.len

const completionVariable = 6
const completionFunction = 3
const completionKeyword = 14
const completionConstant = 21

proc newLanguageServer*(stdPath: string, notify: proc (meth: string, params: JsonNode)): LanguageServer =
  LanguageServer(stdPath: stdPath, encoding: enUtf16, notify: notify)

# ---- positions in the editor's encoding

func sequenceLength(lead: char): int =
  if ord(lead) < 0x80: 1 elif ord(lead) < 0xE0: 2 elif ord(lead) < 0xF0: 3 else: 4

func countCodeUnits(text: string, encoding: Encoding): int =
  if encoding == enUtf8: return text.len
  var index = 0
  while index < text.len:
    let length = sequenceLength(text[index])
    result += (if encoding == enUtf16 and length == 4: 2 else: 1)
    index += length

func codeUnitByteCount(text: string, count: int, encoding: Encoding): int =
  ## The bytes of the first `count` code units of `text`.
  if encoding == enUtf8: return min(text.len, count)
  var units = 0
  while result < text.len and units < count:
    let length = sequenceLength(text[result])
    units += (if encoding == enUtf16 and length == 4: 2 else: 1)
    result += length
  min(result, text.len)

func positionToIndex(text: string, line, character: int, encoding: Encoding): int =
  var currentLine = 0
  var lineStart = 0
  var isLineFound = false
  for index, ch in text:
    if currentLine == line:
      isLineFound = true
      break
    if ch == '\n':
      inc currentLine
      lineStart = index + 1
  if not isLineFound: return text.len
  var lineEnd = text.find('\n', lineStart)
  if lineEnd < 0: lineEnd = text.len
  lineStart + codeUnitByteCount(text[lineStart ..< lineEnd], character, encoding)

func indexToPosition(text: string, index: int, encoding: Encoding): JsonNode =
  let lastLineStart = if index == 0: 0 else: text.rfind('\n', 0, index - 1) + 1
  %*{"line": text[0 ..< lastLineStart].count('\n'),
     "character": countCodeUnits(text[lastLineStart ..< index], encoding)}

func isNameChar(ch: char): bool = ch.isAlphaNumeric or ch == '_'

func isPathChar(ch: char): bool = isNameChar(ch) or ch in {'.', '[', ']', '-'}

func diagnosticRange(text: string, position: Option[Position], encoding: Encoding): JsonNode =
  ## Poplar lines and columns start at 1 and count bytes. The range ends at the end of the word at the start.
  if position.isNone: return %*{"start": {"line": 0, "character": 0}, "end": {"line": 0, "character": 0}}
  let at = position.get
  var lineStart = 0
  var currentLine = 1
  while currentLine < at.line:
    let newline = text.find('\n', lineStart)
    if newline < 0: break
    lineStart = newline + 1
    inc currentLine
  var lineEnd = text.find('\n', lineStart)
  if lineEnd < 0: lineEnd = text.len

  let start = min(lineStart + max(at.column - 1, 0), lineEnd)
  var stop = start
  if stop < lineEnd and not isNameChar(text[stop]): inc stop
  while stop < lineEnd and isNameChar(text[stop]): inc stop
  %*{"start": indexToPosition(text, start, encoding), "end": indexToPosition(text, stop, encoding)}

# ---- URIs

func isDrivePrefix(text: string): bool = text.len >= 2 and text[0].isAlphaAscii and text[1] == ':'

func uriToPath(uri: string): Option[string] =
  const prefix = "file://"
  if not uri.startsWith(prefix): return none(string)
  let encoded = uri[prefix.len .. ^1]
  var path = ""
  var index = 0
  while index < encoded.len:
    if encoded[index] == '%' and index + 2 < encoded.len and encoded[index + 1 .. index + 2].allCharsInSet(HexDigits):
      path.add char(parseHexInt(encoded[index + 1 .. index + 2]))
      index += 3
      continue
    path.add encoded[index]
    inc index
  # `file:///c%3A/x` is `C:\x`. Editors differ in the case of the drive letter, and the compiler's paths have a
  # capital.
  if path.len >= 3 and path[0] == '/' and isDrivePrefix(path[1 .. 2]):
    var windowsPath = path[1 .. ^1]
    windowsPath[0] = windowsPath[0].toUpperAscii
    return some(windowsPath.replace('/', '\\'))
  some(path)

func pathToUri(path: string): string =
  result = "file://"
  var rest = path
  let isWindowsPath = isDrivePrefix(path)
  if isWindowsPath:
    result.add "/" & path[0 .. 1]
    rest = path[2 .. ^1]
  for ch in rest:
    if ch.isAlphaNumeric or ch in "-._~/": result.add ch
    elif ch == '\\' and isWindowsPath: result.add '/'
    else: result.add "%" & toHex(ord(ch), 2)

# ---- analysis

func contains(analysis: Analysis, path: string): bool = path in analysis.result.files.values.toSeq

func displayPath(analysis: Analysis, path: string): Option[string] =
  for displayPath, filePath in analysis.result.files:
    if filePath == path: return some(displayPath)
  none(string)

func absolutePath(analysis: Analysis, displayPath: string): string =
  if displayPath in analysis.result.files: analysis.result.files[displayPath] else: analysis.projectRoot / displayPath

proc findProjectRoot(filePath: string): Option[string] =
  ## The nearest folder with `poplar.json`, or else the folder that holds the `src/` that the file is in.
  var aboveSrc = none(string)
  var directory = filePath.parentDir
  while directory.len > 0:
    if fileExists(directory / fileName) or dirExists(directory / fileName): return some(directory)
    if aboveSrc.isNone and directory.lastPathPart == "src": aboveSrc = some(directory.parentDir)
    let parent = directory.parentDir
    if parent == directory: break
    directory = parent
  aboveSrc

proc textOf(server: LanguageServer, path: string): string =
  ## The text of a file: from the editor when it is open, else from the disk.
  let uri = pathToUri(path)
  if uri in server.documents: return server.documents[uri]
  try: readFile(path) except IOError, OSError: ""

proc analyze(server: LanguageServer, uri: string): Analysis =
  ## Compiles the project that has the file of `uri`. Nil if the file is in no project.
  let path = uriToPath(uri)
  if path.isNone: return nil
  var projectRoot: string
  if server.analysis != nil and server.analysis.contains(path.get):
    projectRoot = server.analysis.projectRoot
  else:
    let found = findProjectRoot(path.get)
    if found.isNone: return nil
    projectRoot = found.get

  var overlay: Table[string, string]
  for documentUri, text in server.documents:
    let documentPath = uriToPath(documentUri)
    if documentPath.isSome: overlay[documentPath.get] = text

  if server.commandTree == nil: server.commandTree = loadCommandTree()
  let built = build(projectRoot, Options(stdPath: server.stdPath, mode: moCheck, overlay: overlay,
                                         commandTree: server.commandTree))
  server.analysis = Analysis(projectRoot: projectRoot, result: built)
  server.analysis

proc analysisFor(server: LanguageServer, uri: string): Analysis =
  ## The last analysis if it has the file of `uri`, else a new one.
  let path = uriToPath(uri)
  if path.isNone: return nil
  if server.analysis != nil and server.analysis.contains(path.get): return server.analysis
  server.analyze(uri)

proc publish(server: LanguageServer, uri: string, diagnostics: seq[JsonNode]) =
  server.notify("textDocument/publishDiagnostics", %*{"uri": uri, "diagnostics": diagnostics})

proc check(server: LanguageServer, uri: string) =
  ## Compiles the project of `uri` with the open documents and shows its errors in the editor.
  let analysis = server.analyze(uri)
  if analysis == nil: return

  var byUri: OrderedTable[string, seq[JsonNode]]
  for diagnostic in analysis.result.diagnostics:
    var path: string
    if diagnostic.path.len == 0:
      let documentPath = uriToPath(uri)
      if documentPath.isNone: continue
      path = documentPath.get
    else:
      path = analysis.absolutePath(diagnostic.path)
    let range = diagnosticRange(server.textOf(path), diagnostic.position, server.encoding)
    byUri.mgetOrPut(pathToUri(path), @[]).add %*{"range": range, "severity": 1, "source": "poplar",
                                                 "message": diagnostic.message}

  for fileUri, diagnostics in byUri:
    server.publish(fileUri, diagnostics)
    server.published[fileUri] = analysis.projectRoot

  # Files of this project that had errors and have none now get an empty list, so their marks go away.
  var fixed: seq[string]
  for fileUri, projectRoot in server.published:
    if projectRoot == analysis.projectRoot and fileUri notin byUri: fixed.add fileUri
  for fileUri in fixed:
    server.publish(fileUri, @[])
    server.published.del(fileUri)

# ---- words and places

func namespaceBefore(text: string, start: int): (Option[string], int) =
  ## `magic:` right before `start`: the namespace, and where it starts. Otherwise none and `start`.
  if start == 0 or text[start - 1] != ':': return (none(string), start)
  var namespaceStart = start - 1
  while namespaceStart > 0 and text[namespaceStart - 1] in {'a' .. 'z', '0' .. '9', '_', '.'}: dec namespaceStart
  if namespaceStart == start - 1: return (none(string), start)
  (some(text[namespaceStart ..< start - 1]), namespaceStart)

func wordAt(text: string, index: int): Option[Word] =
  ## The name under the cursor, with its sigil: `#hp`, `$stats.maxHp`, `@s.$Health` or `clamp`.
  var start = min(index, text.len)
  var stop = start
  while start > 0 and isNameChar(text[start - 1]): dec start
  while stop < text.len and isNameChar(text[stop]): inc stop
  if start == stop: return none(Word)

  var pathStart = start
  while pathStart > 0 and isPathChar(text[pathStart - 1]): dec pathStart
  let (pathNamespace, pathSigil) = namespaceBefore(text, pathStart)
  if pathSigil > 0 and text[pathSigil - 1] == '$':
    let isEntity = pathNamespace.isNone and pathSigil > 1 and text[pathSigil - 2] == '.'
    return some(Word(kind: if isEntity: wkEntityData else: wkData, text: text[pathStart ..< stop],
                     namespace: pathNamespace))
  let (namespace, sigil) = namespaceBefore(text, start)
  if sigil > 0 and text[sigil - 1] == '#':
    return some(Word(kind: wkScore, text: text[start ..< stop], namespace: namespace))
  some(Word(kind: wkName, text: text[start ..< stop], namespace: namespace))

func wordKey(compiler: Compiler, place: Place, word: Word, name: string): string =
  ## `combat:heal`: how the compiler keys the declaration that `word` names, from the namespace of its file.
  let namespace = word.namespace.get(compiler.fileNamespaces.getOrDefault(place.path, compiler.packNamespace))
  namespace & ":" & name

func placeOf(analysis: Analysis, uri: string, line: int): Place =
  Place(path: analysis.displayPath(uriToPath(uri).get("")).get(""), line: line + 1)

func enclosingMcfun(compiler: Compiler, place: Place): Option[string] =
  ## The function that contains `place`: the last one that starts above it in the same file.
  var nearest = none(Mcfun)
  for declaration in compiler.mcfuns.values:
    if declaration.path != place.path or declaration.mcfun.position.line > place.line: continue
    if nearest.isNone or declaration.mcfun.position.line > nearest.get.position.line: nearest = some(declaration.mcfun)
  if nearest.isSome: some(nearest.get.name) else: none(string)

func visibleLocals(compiler: Compiler, place: Place, kind: LocalKind): seq[LocalVariable] =
  ## The locals of the function at `place` that are declared above it. Block scope is not checked.
  let owner = enclosingMcfun(compiler, place)
  if owner.isNone: return
  for local in compiler.locals:
    if local.local.kind != kind or local.position.line > place.line: continue
    if local.local.owner != owner.get or local.path != place.path: continue
    result.add local

func findLocal(compiler: Compiler, place: Place, kind: LocalKind, name: string): Option[LocalVariable] =
  ## The local `name` that is visible at `place`: the nearest one declared above it in the same function.
  for local in visibleLocals(compiler, place, kind):
    if local.name != name: continue
    if result.isNone or local.position.line > result.get.position.line: result = some(local)

proc signature(mcfun: Mcfun): string =
  ## `mcfun clamp() with {x, low, high}`: the macro keys that the body uses.
  var keys: OrderedSet[string]
  collectMacroKeys(mcfun.body, keys)
  if keys.len == 0: &"mcfun {mcfun.name}()" else: &"mcfun {mcfun.name}() with {{{toSeq(keys).join(\", \")}}}"

func docComment(source: string, line: int): string =
  ## The `//` lines right above line `line` (1-based), without the slashes.
  var lines: seq[string]
  let sourceLines = source.split('\n')
  for index, each in sourceLines:
    if index + 1 >= line: break
    let trimmed = each.strip(chars = {' ', '\t', '\r'})
    if trimmed.startsWith("//"): lines.add trimmed[2 .. ^1].strip(chars = {' '})
    else: lines.setLen(0)
  lines.join("\n")

proc describe(server: LanguageServer, analysis: Analysis, word: Word, place: Place): Option[string] =
  ## The hover text for a word, in Markdown.
  if word.kind == wkEntityData: return some(&"Entity NBT `{word.text}`. The compiler does not check the path.")
  if word.kind == wkName:
    for each in builtins:
      if each.name == word.text: return some(&"```poplar\n{each.signature}\n```\n{each.doc}")
  let compiler = analysis.result.compiler
  if compiler == nil: return none(string)
  let key = wordKey(compiler, place, word, pathRoot(word.text))
  case word.kind
  of wkScore:
    if word.namespace.isNone:
      let local = findLocal(compiler, place, lkScore, word.text)
      if local.isSome:
        return some(&"```poplar\nvar #{word.text}\n```\nA local in `{local.get.local.owner}`: the fake player " &
                    &"`{local.get.local.generatedName}`.")
    if key notin compiler.globals: return none(string)
    let global = compiler.globals[key]
    some(&"```poplar\nvar #{word.text} = {global.initialValue};\n```\nA score in the objective " &
         &"`{global.outputNamespace.get(compiler.packNamespace)}.{global.name}`.")
  of wkData:
    let root = pathRoot(word.text)
    if word.namespace.isNone:
      let local = findLocal(compiler, place, lkData, root)
      if local.isSome:
        return some(&"```poplar\nvar ${root}\n```\nA local in `{local.get.local.owner}`: the key " &
                    &"`{local.get.local.generatedName}`.")
    if key notin compiler.dataGlobals: return none(string)
    let global = compiler.dataGlobals[key]
    some(&"```poplar\nvar ${root} = {global.initialSnbt};\n```\nIn the storage " &
         &"`{global.outputNamespace.get(compiler.packNamespace)}:data`.")
  of wkName:
    if key in compiler.namedDataFiles:
      let dataFile = compiler.namedDataFiles[key]
      return some(&"```poplar\n{dataFile.typeWord} {word.text}\n```\nThe data file `{dataFile.id}`.")
    if key notin compiler.mcfuns: return none(string)
    let declaration = compiler.mcfuns[key]
    let source = server.textOf(analysis.absolutePath(declaration.path))
    some(&"```poplar\n{signature(declaration.mcfun)}\n```\n{docComment(source, declaration.mcfun.position.line)}")
  of wkEntityData: none(string)

# ---- requests and notifications

proc initialize(server: LanguageServer, params: JsonNode): JsonNode =
  for encoding in params{"capabilities", "general", "positionEncodings"}.getElems:
    let name = encoding.getStr
    if name in ["utf-8", "utf-16", "utf-32"]:
      server.encoding = parseEnum[Encoding](name)
      break
  %*{"capabilities": {"positionEncoding": $server.encoding, "textDocumentSync": {"openClose": true, "change": 1},
                      "completionProvider": {"triggerCharacters": ["#", "$"]}, "hoverProvider": true,
                      "definitionProvider": true},
     "serverInfo": {"name": "poplar", "version": poplarVersion}}

proc didChange(server: LanguageServer, params: JsonNode) =
  let uri = params["textDocument"]["uri"].getStr
  if uri notin server.documents: return
  var text = server.documents[uri]
  for change in params["contentChanges"]:
    if change.hasKey("range"):
      let range = change["range"]
      let start = positionToIndex(text, range["start"]["line"].getInt, range["start"]["character"].getInt,
                                  server.encoding)
      let (startLine, endLine) = (range["start"]["line"].getInt, range["end"]["line"].getInt)
      let endCharacter = if startLine == endLine: range["end"]["character"].getInt - range["start"]["character"].getInt
                         else: range["end"]["character"].getInt
      let stop = start + positionToIndex(text[start .. ^1], endLine - startLine, endCharacter, server.encoding)
      text = text[0 ..< start] & change["text"].getStr & text[stop .. ^1]
    else:
      text = change["text"].getStr
  server.documents[uri] = text
  server.check(uri)

proc hover(server: LanguageServer, params: JsonNode): JsonNode =
  let uri = params["textDocument"]["uri"].getStr
  let analysis = server.analysisFor(uri)
  if analysis == nil or uri notin server.documents: return newJNull()
  let text = server.documents[uri]
  let (line, character) = (params["position"]["line"].getInt, params["position"]["character"].getInt)
  let word = wordAt(text, positionToIndex(text, line, character, server.encoding))
  if word.isNone: return newJNull()
  let markdown = server.describe(analysis, word.get, placeOf(analysis, uri, line))
  if markdown.isNone: return newJNull()
  %*{"contents": {"kind": "markdown", "value": markdown.get}}

proc definition(server: LanguageServer, params: JsonNode): JsonNode =
  let uri = params["textDocument"]["uri"].getStr
  let analysis = server.analysisFor(uri)
  if analysis == nil or uri notin server.documents: return newJNull()
  let text = server.documents[uri]
  let (line, character) = (params["position"]["line"].getInt, params["position"]["character"].getInt)
  let found = wordAt(text, positionToIndex(text, line, character, server.encoding))
  let compiler = analysis.result.compiler
  if found.isNone or compiler == nil: return newJNull()
  let word = found.get

  let place = placeOf(analysis, uri, line)
  var local = none(LocalVariable)
  if word.kind in {wkScore, wkData} and word.namespace.isNone:
    local = findLocal(compiler, place, if word.kind == wkScore: lkScore else: lkData, pathRoot(word.text))
  let key = wordKey(compiler, place, word, pathRoot(word.text))

  var (displayPath, declaredAt) = ("", Position())
  if local.isSome:
    (displayPath, declaredAt) = (local.get.path, local.get.position)
  else:
    case word.kind
    of wkScore:
      if key notin compiler.globals: return newJNull()
      (displayPath, declaredAt) = (compiler.globals[key].path, compiler.globals[key].position)
    of wkData:
      if key notin compiler.dataGlobals: return newJNull()
      (displayPath, declaredAt) = (compiler.dataGlobals[key].path, compiler.dataGlobals[key].position)
    of wkEntityData: return newJNull()
    of wkName:
      if key in compiler.mcfuns:
        (displayPath, declaredAt) = (compiler.mcfuns[key].path, compiler.mcfuns[key].mcfun.position)
      elif key in compiler.namedDataFiles:
        (displayPath, declaredAt) = (compiler.namedDataFiles[key].path, compiler.namedDataFiles[key].position)
      else:
        return newJNull()
  let definitionPath = analysis.absolutePath(displayPath)
  let position = diagnosticRange(server.textOf(definitionPath), some(declaredAt), server.encoding)["start"]
  %*{"uri": pathToUri(definitionPath), "range": {"start": position, "end": position}}

func completionLabel(key, ownPrefix: string): string =
  ## A name of this namespace without its `ns:`, any other with it: `heal`, `magic:fireball`.
  if key.startsWith(ownPrefix): key[ownPrefix.len .. ^1] else: key

proc completion(server: LanguageServer, params: JsonNode): JsonNode =
  let uri = params["textDocument"]["uri"].getStr
  if uri notin server.documents: return newJNull()
  let text = server.documents[uri]
  let (line, character) = (params["position"]["line"].getInt, params["position"]["character"].getInt)
  var start = positionToIndex(text, line, character, server.encoding)
  while start > 0 and isNameChar(text[start - 1]): dec start
  let sigil = if start > 0: text[start - 1] else: '\0'

  var items: seq[JsonNode]
  proc item(label: string, kind: int, detail = "") =
    items.add(if detail.len > 0: %*{"label": label, "kind": kind, "detail": detail}
              else: %*{"label": label, "kind": kind})
  let analysis = server.analysisFor(uri)
  let compiler = if analysis != nil: analysis.result.compiler else: nil
  let place = if analysis != nil: placeOf(analysis, uri, line) else: Place()

  # A name in the file's own namespace without its `ns:`, any other with it.
  let own = if compiler != nil: compiler.fileNamespaces.getOrDefault(place.path, compiler.packNamespace) & ":" else: ""
  case sigil
  of '#':
    if compiler != nil:
      for name in compiler.globals.keys: item(completionLabel(name, own), completionVariable, "score")
      for local in visibleLocals(compiler, place, lkScore): item(local.name, completionVariable, "local score")
  of '$':
    if compiler != nil:
      for name in compiler.dataGlobals.keys: item(completionLabel(name, own), completionVariable, "data")
      for local in visibleLocals(compiler, place, lkData): item(local.name, completionVariable, "local data")
  else:
    # A word at the start of a line, with no indent, is likely at the top level.
    if start == 0 or text[start - 1] == '\n':
      for word in folders.keys: item(word, completionKeyword, "data file")
    for keyword in keywords: item($keyword, completionKeyword)
    for each in builtins: item(each.name, completionFunction, each.signature)
    if compiler != nil:
      for key, dataFile in compiler.namedDataFiles: item(completionLabel(key, own), completionConstant, dataFile.id)
      for key, declaration in compiler.mcfuns:
        item(completionLabel(key, own), completionFunction, signature(declaration.mcfun))
  %items

proc handle*(server: LanguageServer, meth: string, params: JsonNode): JsonNode =
  ## The answer to a request, or nil for a notification. A request that the server does not know gets null.
  case meth
  of "initialize": server.initialize(params)
  of "shutdown": newJNull()
  of "textDocument/didOpen":
    let document = params["textDocument"]
    server.documents[document["uri"].getStr] = document["text"].getStr
    server.check(document["uri"].getStr)
    nil
  of "textDocument/didChange":
    server.didChange(params)
    nil
  of "textDocument/didClose":
    let uri = params["textDocument"]["uri"].getStr
    if uri in server.documents:
      server.documents.del(uri)
      # The file on disk counts again.
      server.check(uri)
    nil
  of "textDocument/hover": server.hover(params)
  of "textDocument/definition": server.definition(params)
  of "textDocument/completion": server.completion(params)
  else: newJNull()
