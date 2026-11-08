# Names and namespaces: registering mcfuns, globals and data files, and finding what a name refers to. Part of
# compiler.nim.

func qualifiedKey(namespace, name: string): string =
  ## `combat:heal`: how declarations are keyed in the compiler.
  namespace & ":" & name

proc outputNamespace(compiler: Compiler, namespace: string): Option[string] =
  ## Where the files of a namespace go. None is the pack namespace, which std is written into.
  if namespace == stdNamespace or namespace == compiler.packNamespace: none(string) else: some(namespace)

func outputPath(namespace, name: string): string =
  ## The path of an mcfun in its output namespace: `heal`, and `std/clamp` for std, which shares the pack namespace.
  if namespace == stdNamespace: "std/" & name else: name

proc functionName(compiler: Compiler, namespace, name: string): string =
  ## The IR name of an mcfun: `combat:heal`, `heal` in the pack namespace, `std/clamp` for std.
  let path = outputPath(namespace, name)
  let output = compiler.outputNamespace(namespace)
  if output.isSome: output.get & ":" & path else: path

proc isImported(compiler: Compiler, namespace: string): bool =
  compiler.scope.imports.anyIt(it.name == namespace)

proc resolveNamespace(compiler: Compiler, namespace: Option[string]): string =
  ## The namespace that a name refers to: its own `magic:`, which the file must import, or the current one.
  if namespace.isNone: return compiler.scope.namespace
  let name = namespace.get
  if name == compiler.scope.namespace or compiler.isImported(name): return name
  compiler.fail(&"namespace '{name}' is not imported. Add 'import {name};'")

func isValidNamespace(name: string): bool =
  ## A resource name with no `-`, because `namespace x;` is Poplar code, where `-` is the minus sign.
  isValidResourceName(name) and '-' notin name

proc jsonErrorPosition(dataFile: ast.DataFile): Option[Position] =
  ## Where the JSON body stops being valid, as a line and column in the source file.
  var scanner = initJsonScanner(dataFile.json)
  try:
    while scanner.next().kind != jtEndOfDocument: discard
    return none(Position)
  except JsonSyntaxError:
    let jsonLine = scanner.line
    let column = scanner.column
    some(Position(line: dataFile.jsonPosition.line + jsonLine - 1,
                  column: if jsonLine == 1: dataFile.jsonPosition.column + column - 1 else: column))

proc addDataFile(compiler: Compiler, dataFile: ast.DataFile) =
  var folder = folders.getOrDefault(dataFile.typeWord)
  if folder.len == 0:
    let tag = tagFolder(dataFile.typeWord, compiler.commandTree.registries)
    if tag.isNone:
      compiler.fail(&"unknown data file type '{dataFile.typeWord}'" &
                    suggestion(closestId(folders.keys.toSeq, dataFile.typeWord)))
    folder = tag.get

  let ownNamespace = compiler.scope.outputNamespace.get(compiler.packNamespace)
  var namespace, filePath: string
  case dataFile.name
  of IdentifierName(identifier):
    filePath = functionPath(identifier)
    if not isValidResourceName(filePath):
      compiler.fail(&"data file name '{identifier}' must only use letters, 0-9, '_', '.' and '-'")
    namespace = ownNamespace
  of IdName(id):
    let colon = id.find(':')
    namespace = if colon >= 0: id[0 ..< colon] else: ownNamespace
    filePath = if colon >= 0: id[colon + 1 .. ^1] else: id
    let isValid = filePath.split('/').allIt(isValidResourceName(it)) and isValidResourceName(namespace)
    if not isValid:
      compiler.fail(&"data file id '{id}' must only use a-z, 0-9, '_', '.', '-' and '/', with one ':' after the " &
                    "namespace")

  let isHookTag = folder == "tags/function" and namespace == "minecraft" and filePath in ["load", "tick"]
  if isHookTag: compiler.fail(&"Poplar writes the minecraft:{filePath} function tag. Use 'mcfun {filePath}'")

  let fullPath = &"data/{namespace}/{folder}/{filePath}.json"
  if fullPath in compiler.dataFilePaths:
    compiler.fail(&"{dataFile.typeWord} '{namespace}:{filePath}' is already declared at " &
                  compiler.dataFilePaths[fullPath])
  compiler.dataFilePaths[fullPath] = &"{compiler.path}:{dataFile.position.line}"

  # A data file in the namespace of its file can be named in Minecraft text: `self:isSitting`.
  if namespace == ownNamespace:
    let name = case dataFile.name
      of IdentifierName(identifier): identifier
      of IdName: filePath
    compiler.dataFileNames[qualifiedKey(compiler.scope.namespace, name)] = filePath

  case dataFile.name
  of IdentifierName(identifier):
    let key = qualifiedKey(compiler.scope.namespace, identifier)
    if key in compiler.namedDataFiles: compiler.fail(&"'{identifier}' is already the name of another data file")
    compiler.namedDataFiles[key] = NamedDataFile(typeWord: dataFile.typeWord, id: namespace & ":" & filePath,
                                                 path: compiler.path, position: dataFile.position)
  of IdName: discard

  let errorPosition = jsonErrorPosition(dataFile)
  if errorPosition.isSome:
    compiler.position = errorPosition.get
    compiler.fail(&"invalid JSON in {dataFile.typeWord} '{filePath}'")

  compiler.dataFiles.add DataFile(namespace: namespace, folder: folder, path: filePath, json: dataFile.json & "\n")

proc addDuplicateError(compiler: Compiler, existing, later: McfunDeclaration) =
  ## A name that the project and std both define is reported in the project file, where it can be renamed.
  ## Otherwise the later definition is reported.
  let (projectSide, other) = if existing.origin != orStd and later.origin == orStd: (existing, later)
                             else: (later, existing)
  compiler.path = projectSide.path
  compiler.position = projectSide.mcfun.position
  if other.origin == orStd and projectSide.origin != orStd:
    compiler.addError(&"function '{later.mcfun.name}' is already defined in {other.path}:" &
                      &"{other.mcfun.position.line}. Rename yours")
    return
  compiler.addError(&"function '{later.mcfun.name}' is already defined at {other.path}:{other.mcfun.position.line}")

proc addDataGlobal(compiler: Compiler, decl: VarDecl) =
  let name = decl.target.name
  if pathRoot(name).len != name.len: compiler.fail(&"'var' declares a whole variable. Set '${name}' in an mcfun")
  let value = evaluate(compiler, decl.value, Environment())
  case value
  of NullValue: compiler.fail("a data variable cannot start as null")
  else: discard
  let initialSnbt = valueToSnbt(value)

  let key = qualifiedKey(compiler.scope.namespace, name)
  if key in compiler.dataGlobals:
    let existing = compiler.dataGlobals[key]
    compiler.fail(&"data '${name}' is already declared at {existing.path}:{existing.position.line}")

  compiler.dataGlobals[key] = GlobalData(path: compiler.path, position: compiler.position, initialSnbt: initialSnbt,
                                         name: name, outputNamespace: compiler.scope.outputNamespace,
                                         storage: storageOf(compiler.scope.namespace))

proc addGlobal(compiler: Compiler, decl: VarDecl) =
  if decl.target.namespace.isSome:
    let namespace = decl.target.namespace.get
    compiler.fail(&"'{namespace}:' cannot be declared here. Declare it in a file with 'namespace {namespace};'")
  case decl.target.kind
  of ikScore: discard
  of ikCompileTime: compiler.fail("only score (#) and data ($) variables can be declared at the top level")
  of ikData:
    compiler.addDataGlobal(decl)
    return
  of ikEntityData: compiler.fail("entity data cannot be declared. Set it in an mcfun: '@s.$path = ...;'")

  let initialValue = compiler.toScoreValue(evaluate(compiler, decl.value, Environment()))

  let name = decl.target.name
  let key = qualifiedKey(compiler.scope.namespace, name)
  if key in compiler.globals:
    let existing = compiler.globals[key]
    compiler.fail(&"score '#{name}' is already declared at {existing.path}:{existing.position.line}")

  compiler.globals[key] = GlobalScore(path: compiler.path, position: compiler.position, initialValue: initialValue,
                                      name: name, outputNamespace: compiler.scope.outputNamespace)

proc findMcfun(compiler: Compiler, identifier: Identifier): FoundMcfun =
  ## `heal` in this namespace or `magic:heal` in an imported one.
  let namespace = compiler.resolveNamespace(identifier.namespace)
  let key = qualifiedKey(namespace, identifier.name)
  if key notin compiler.mcfuns: compiler.fail(&"unknown function '{identifier.name}'")
  FoundMcfun(key: key, declaration: compiler.mcfuns[key])

proc outputNamespaces(compiler: Compiler): seq[string] =
  ## The namespaces other than the pack namespace that have mcfuns: each one gets its own `poplar.<ns>` objective for
  ## temps and locals.
  var namespaces: OrderedSet[string]
  for declaration in compiler.mcfuns.values:
    let namespace = compiler.outputNamespace(declaration.namespace)
    if namespace.isSome: namespaces.incl namespace.get
  namespaces.toSeq
