## Checks command text against the command tree of mcmeta, and finds the ids in it.

import std/[json, math, options, strformat, strutils, tables]
import config

type
  Registries* = OrderedTable[string, seq[string]]
    ## The ids of each registry, without `minecraft:`: `mob_effect` → `absorption`, `bad_omen`, ...

  NodeKind* = enum
    nkRoot, nkLiteral, nkArgument

  Properties* = object
    min*, max*: Option[float]
    kind*: Option[string] ## The `type` of a `brigadier:string`: `word`, `phrase` or `greedy`.
    registry*: Option[string]

  Node* = ref object
    kind*: NodeKind
    children*: OrderedTable[string, Node]
    executable*: bool
    redirect*: seq[string]
    parser*: string
    properties*: Properties

  Failure* = object
    message*: string
    at*: int

  Id* = object
    at*: int
    namesDeclaration*: bool
      ## True where the id names a function or a data file (`function`, `predicate`, a tag). False
      ## for other ids, such as a storage or a bossbar, which are not declared in Poplar.
    canBePackName*: bool
      ## True where a bare name can only be a mistake for a pack's own name: a function or a data
      ## file. False where the compiler knows the vanilla ids, so `speed` in `effect give @s speed`
      ## is the effect, even with an `mcfun speed`.

  Checked* = object
    failure*: Option[Failure]
    ids*: seq[Id]
      ## Each id in an id position (after a `#`), such as `self:heal` in
      ## `function self:heal` or `magic:undead` in `@e[type=#magic:undead]`.
      ## Text arguments, such as the message of `say`, have none.

  CommandTree* = ref object
    root*: Node
    registries*: Registries

  Problem = object
    at: int
    expected: string
    outOfRange: bool
    message: Option[string]   ## A finished message, for a problem inside an argument.
    unknownIn: Option[string] ## The registry when the id is not in it.

  Walk = object
    tree: CommandTree
    text: string
    poplarNamespaces: seq[string]
    furthest: Option[Problem]
    ids: seq[Id]
      ## Only filled on the path that matches, because each
      ## argument adds its ids after the rest matched.

const commandsJson = staticRead("../mcmeta/commands.json")
const registriesJson = staticRead("../mcmeta/registries.json")

const selectorOptions = ["advancements", "distance", "dx", "dy", "dz", "gamemode", "level", "limit",
                         "name", "nbt", "predicate", "scores", "sort", "tag", "team", "type", "x",
                         "x_rotation", "y", "y_rotation", "z"]
  ## The options of a selector, as the game knows them.

func toNode(json: JsonNode): Node =
  result = Node(kind: parseEnum[NodeKind]("nk" & json["type"].getStr.capitalizeAscii),
                executable: json{"executable"}.getBool, parser: json{"parser"}.getStr)
  if json.hasKey("children"):
    for name, child in json["children"]: result.children[name] = toNode(child)
  if json.hasKey("redirect"):
    for name in json["redirect"]: result.redirect.add name.getStr
  let properties = json{"properties"}
  if properties != nil:
    if properties.hasKey("min"): result.properties.min = some(properties["min"].getFloat)
    if properties.hasKey("max"): result.properties.max = some(properties["max"].getFloat)
    if properties.hasKey("type"): result.properties.kind = some(properties["type"].getStr)
    if properties.hasKey("registry"):
      result.properties.registry = some(properties["registry"].getStr)

proc loadCommandTree*(): CommandTree =
  result = CommandTree(root: toNode(parseJson(commandsJson)))
  for registry, ids in parseJson(registriesJson).pairs:
    result.registries[registry] = @[]
    for id in ids: result.registries[registry].add id.getStr

# ---- numbers in command text

func parseWholeNumber(word: string): Option[int64] =
  ## An optional sign, then digits that `_` can separate.
  let digits = if word.startsWith('+') or word.startsWith('-'): word[1..^1] else: word
  if digits.len == 0 or digits[0] == '_' or digits[^1] == '_' or
     not digits.allCharsInSet(Digits + {'_'}):
    return none(int64)
  try:
    some(parseBiggestInt(word[0 ..< word.len - digits.len] & digits.replace("_", "")))
  except ValueError:
    none(int64)

func validUnderscores(text: string, digits: set[char]): bool =
  var index = 0
  while index < text.len:
    if text[index] == '_':
      if index == 0 or index + 1 == text.len: return false
      if text[index - 1] notin digits or text[index + 1] notin digits: return false
      inc index
    inc index
  true

func parseDecimal(word: string): Option[float] =
  ## A decimal or hex (`0x1.8p3`) number, `inf` or `nan`, with an optional sign. `_` can separate
  ## digits.
  let negative = word.startsWith('-')
  let unsigned = if word.startsWith('+') or negative: word[1..^1] else: word
  if unsigned.len == 0: return none(float)
  let sign = if negative: -1.0 else: 1.0

  let hex = unsigned.len >= 2 and unsigned[0] == '0' and unsigned[1] in {'x', 'X'}
  let body = if hex: unsigned[2..^1] else: unsigned
  let digits = if hex: HexDigits else: Digits
  var pos = 0
  var integerPart, fractionPart = ""
  proc scan(target: var string) =
    while pos < body.len and body[pos] in digits + {'_'}:
      if body[pos] != '_': target.add body[pos]
      inc pos
  scan(integerPart)
  if pos < body.len and body[pos] == '.':
    inc pos
    scan(fractionPart)
  var valid = integerPart.len + fractionPart.len > 0
  var exponent = 0
  if valid and pos < body.len and (ord(body[pos]) or 0x20) == ord(if hex: 'p' else: 'e'):
    inc pos
    var exponentNegative = false
    if pos < body.len and body[pos] in {'+', '-'}:
      exponentNegative = body[pos] == '-'
      inc pos
    valid = pos < body.len and body[pos].isDigit
    while pos < body.len and body[pos] in Digits + {'_'}:
      if body[pos] != '_' and exponent < 0x1000_0000: exponent = exponent * 10 + ord(body[pos]) -
          ord('0')
      inc pos
    if exponentNegative: exponent = -exponent
  if valid and pos == body.len and validUnderscores(body, digits):
    if hex:
      var mantissa = 0.0
      for digit in integerPart & fractionPart: mantissa = mantissa * 16 + float(parseHexInt($digit))
      return some(sign * mantissa * pow(2.0, float(exponent - 4 * fractionPart.len)))
    let number = (if integerPart.len > 0: integerPart else: "0") & "." &
                 (if fractionPart.len > 0: fractionPart else: "0") & "e" & $exponent
    return some(sign * parseFloat(number))

  case unsigned.toLowerAscii
  of "inf", "infinity": some(sign * Inf)
  of "nan": some(NaN)
  else: none(float)

# ---- small checks

func readBalanced(text: string, start: int): int =
  ## Reads to the next space that is outside quotes and brackets.
  var pos = start
  var depth = 0
  var quote = '\0'
  while pos < text.len:
    let ch = text[pos]
    if quote != '\0':
      if ch == '\\': inc pos
      elif ch == quote: quote = '\0'
      inc pos
      continue
    case ch
    of '"', '\'': quote = ch
    of '[', '{', '(': inc depth
    of ']', '}', ')': depth = max(depth - 1, 0)
    of ' ':
      if depth == 0: break
    else: discard
    inc pos
  min(pos, text.len)

func parseNumber(parser, word: string): Option[float] =
  if parser != "brigadier:integer": return parseDecimal(word)
  let whole = parseWholeNumber(word)
  if whole.isSome: some(float(whole.get)) else: none(float)

func registryOf(parser: string, properties: Properties): Option[string] =
  ## The registry that an argument names: `minecraft:resource` with `registry: minecraft:mob_effect`
  ## → `mob_effect`.
  if parser in ["minecraft:item_stack", "minecraft:item_predicate"]: return some("item")
  if parser in ["minecraft:block_state", "minecraft:block_predicate"]: return some("block")
  if parser in ["minecraft:resource", "minecraft:resource_key", "minecraft:resource_or_tag",
                "minecraft:resource_or_tag_key"] and properties.registry.isSome:
    var registry = properties.registry.get
    registry.removePrefix("minecraft:")
    return some(registry)
  none(string)

func registryId(word: string): Option[string] =
  ## `minecraft:stone[lit=true]` → `stone`. None for a tag, `*`, or another namespace (the pack's
  ## own).
  if word.len == 0 or word[0] in {'#', '*'}: return none(string)
  var stop = word.find({'[', '{'})
  if stop < 0: stop = word.len
  let id = word[0..<stop]
  let separator = id.find(':')
  if separator < 0: return some(id)
  if id[0..<separator] != "minecraft": return none(string)
  some(id[separator + 1 .. ^1])

func suggestion*(closest: Option[string]): string =
  ## `. Did you mean 'x'?` at the end of a message, or nothing when there is no close match.
  if closest.isSome: &". Did you mean '{closest.get}'?" else: ""

func editDistance(a, b: string): Option[int] =
  ## Levenshtein distance. None for words longer than 64 characters.
  if a.len > 64 or b.len > 64: return none(int)
  var previous, current = newSeq[int](b.len + 1)
  for j in 0..b.len: previous[j] = j
  for i, aChar in a:
    current[0] = i + 1
    for j, bChar in b:
      let substitution = previous[j] + ord(aChar != bChar)
      current[j + 1] = min([substitution, previous[j + 1] + 1, current[j] + 1])
    previous = current
  some(previous[b.len])

func closestId*(ids: openArray[string], id: string): Option[string] =
  ## The id with the smallest edit distance, if it is 3 or less.
  var bestDistance = 4
  for candidate in ids:
    let distance = editDistance(candidate, id)
    if distance.isSome and distance.get < bestDistance:
      result = some(candidate)
      bestDistance = distance.get

func isMacroWord(word: string): bool =
  ## Minecraft checks a macro argument when the macro runs, so any argument kind accepts it here.
  "$(" in word

func isCoordinate(word: string): bool =
  if word.len == 0: return false
  if isMacroWord(word): return true
  let hasPrefix = word[0] in {'~', '^'}
  let number = if hasPrefix: word[1..^1] else: word
  if hasPrefix and number.len == 0: return true
  parseDecimal(number).isSome

func optionEnd(selector: string, start, close: int): int =
  ## The `,` or closing `]` that ends the option at `start`, outside quotes and brackets.
  var depth = 0
  var quote = '\0'
  for index in start..<close:
    let ch = selector[index]
    if quote != '\0':
      if ch == quote: quote = '\0'
      continue
    case ch
    of '"', '\'': quote = ch
    of '[', '{': inc depth
    of ']', '}': depth = max(depth - 1, 0)
    of ',':
      if depth == 0: return index
    else: discard
  close

func selectorFailure(registries: Registries, selector: string): Option[Failure] =
  ## What the game rejects inside `@e[...]`, where it would
  ## refuse the whole function. `at` is an offset in `selector`.
  if selector.len < 4 or selector[0] != '@' or selector[2] != '[': return none(Failure)
  let close = selector.len - 1

  var pos = 3
  while pos < close:
    let start = pos
    let stop = optionEnd(selector, start, close)
    pos = stop + 1
    let separator = selector.find('=', start, stop - 1)
    if separator < 0: continue
    let key = selector[start..<separator].strip(chars = {' '})

    if key notin selectorOptions:
      # Option names are short, so only a near match is worth suggesting.
      let closest = closestId(selectorOptions, key)
      let isNear = closest.isSome and editDistance(key, closest.get).get <= 2
      return some(Failure(message: &"unknown selector option '{key}'" &
                                   suggestion(if isNear: closest else: none(string)), at: start))

    var valueStart = separator + 1
    while valueStart < stop and selector[valueStart] in {' ', '!'}: inc valueStart
    let value = selector[valueStart..<stop].strip(leading = false, chars = {' '})
    if value.len == 0: continue

    # The game reads a quoted `name`, and quotes inside the NBT of `nbt`. Every other option refuses
    # them.
    if value[0] in {'"', '\''} and key notin ["name", "nbt"]:
      let unquoted = value.strip(chars = {'"', '\''})
      return some(Failure(message: &"selector option '{key}' cannot have quotes: write " &
                                   &"{key}={unquoted}",
                          at: valueStart))
    if key != "type": continue
    let id = registryId(value)
    if id.isNone or "entity_type" notin registries: continue
    let ids = registries["entity_type"]
    if id.get notin ids:
      let message = &"unknown entity_type '{id.get}'" & suggestion(closestId(ids, id.get))
      return some(Failure(message: message, at: valueStart))
  none(Failure)

func isEntity(word: string): bool =
  if word.len == 0: return false
  if word[0] != '@': return true
  if word.len < 2 or word[1] notin "aeprsn": return false
  word.len == 2 or (word[2] == '[' and word[^1] == ']')

func isResourceParser(parser: string): bool =
  parser in ["minecraft:resource", "minecraft:resource_key", "minecraft:resource_location",
             "minecraft:resource_or_tag", "minecraft:resource_or_tag_key", "minecraft:function",
             "minecraft:dimension"]

func isIdParser(parser: string, properties: Properties): bool =
  isResourceParser(parser) or registryOf(parser, properties).isSome or
    parser in ["minecraft:loot_predicate", "minecraft:loot_table", "minecraft:loot_modifier"]

func isEntityParser(parser: string): bool =
  parser in ["minecraft:entity", "minecraft:game_profile", "minecraft:score_holder"]

func isResourceLocation(word: string, poplarNamespaces: openArray[string]): bool =
  let location = if word.startsWith('#'): word[1..^1] else: word
  if location.len == 0: return false
  # `self:healPlayer` names a Poplar declaration with a capital. The compiler changes it into the
  # id.
  let colon = location.find(':')
  if colon >= 0 and location[0..<colon] in poplarNamespaces:
    return location[colon + 1 .. ^1].allCharsInSet(Letters + Digits + {'_', '-', '.', '/'})
  for ch in location:
    if not isResourceNameChar(ch) and ch notin {':', '/'}: return false
  true

func isUnquotedWord(word: string): bool =
  word.allCharsInSet(Letters + Digits + {'_', '-', '.', '+'})

func describeParser(parser: string): string =
  let separator = parser.find(':')
  if separator < 0: parser else: parser[separator + 1 .. ^1]

func describe(problem: Problem, text: string, registries: Registries): string =
  if problem.message.isSome: return problem.message.get
  let found = text[problem.at..<readBalanced(text, problem.at)]
  if problem.unknownIn.isSome:
    let registry = problem.unknownIn.get
    let id = registryId(found).get
    return &"unknown {registry} '{id}'" & suggestion(closestId(registries[registry], id))
  if problem.outOfRange: return &"{problem.expected} '{found}' is out of range"
  if found.len == 0: return &"expected {problem.expected}, found end of command"
  &"expected {problem.expected}, found '{found}'"

# ---- the walk through the tree

func fail(walk: var Walk, problem: Problem) =
  if walk.furthest.isSome and walk.furthest.get.at >= problem.at: return
  walk.furthest = some(problem)

func addIdStart(walk: var Walk, at: int, namesDeclaration, canBePackName: bool) =
  walk.ids.add Id(at: at, namesDeclaration: namesDeclaration, canBePackName: canBePackName)

func addIdStarts(walk: var Walk, parser: string, properties: Properties, start, stop: int) =
  ## `self:heal` or `#magic:swords` in an id argument, and `type=#magic:undead` in a selector.
  let word = walk.text[start..<stop]
  if isIdParser(parser, properties):
    let offset = if word.startsWith('#'): 1 else: 0
    let namesDeclaration = parser != "minecraft:resource_location"
    let registry = registryOf(parser, properties)
    let hasVanillaIds = registry.isSome and registry.get in walk.tree.registries
    walk.addIdStart(start + offset, namesDeclaration, namesDeclaration and not hasVanillaIds)
  elif isEntityParser(parser) and word.startsWith('@'):
    var quote = '\0'
    for index, ch in word:
      if quote != '\0':
        if ch == quote: quote = '\0'
        continue
      if ch in {'"', '\''}: quote = ch
      if ch != '=': continue
      var value = index + 1
      while value < word.len and word[value] in {'!', '#'}: inc value
      let keyStart = word[0..<index].rfind({'[', ','}) + 1
      let key = word[keyStart..<index].strip(chars = {' '})
      walk.addIdStart(start + value, true, key == "predicate")

func continuation(walk: Walk, node: Node): Node =
  ## `execute ... run` has no children, no redirect and is not executable. It continues from the
  ## root.
  if node.redirect.len > 0:
    result = walk.tree.root
    for name in node.redirect: result = result.children[name]
    return
  if node.children.len > 0: return node
  if not node.executable: return walk.tree.root
  nil

func isUnknownId(walk: Walk, registry, word: string): bool =
  ## Only vanilla ids are checked: a tag, `*`, or an id in another namespace (the pack's own)
  ## passes.
  let id = registryId(word)
  id.isSome and registry in walk.tree.registries and id.get notin walk.tree.registries[registry]

func readCoordinates(walk: var Walk, start, count: int): Option[int] =
  var pos = start
  for index in 0..<count:
    if index > 0:
      if pos >= walk.text.len or walk.text[pos] != ' ':
        walk.fail(Problem(at: min(pos + 1, walk.text.len), expected: "a coordinate"))
        return none(int)
      inc pos
    let stop = readBalanced(walk.text, pos)
    if not isCoordinate(walk.text[pos..<stop]):
      walk.fail(Problem(at: pos, expected: "a coordinate"))
      return none(int)
    pos = stop
  some(pos)

func readArgument(walk: var Walk, node: Node, pos: int): Option[int] =
  let parser = node.parser
  let text = walk.text
  let stop = readBalanced(text, pos)
  let word = text[pos..<stop]
  let properties = node.properties

  if parser == "minecraft:message": return some(text.len)
  if isMacroWord(word): return some(stop)

  let registry = registryOf(parser, properties)
  if registry.isSome and walk.isUnknownId(registry.get, word):
    walk.fail(Problem(at: pos, expected: registry.get, unknownIn: registry))
    return none(int)

  if parser == "brigadier:string":
    let stringType = properties.kind.get("word")
    if stringType == "greedy": return some(text.len)
    if word.len > 0 and (stringType == "phrase" or isUnquotedWord(word)): return some(stop)
  elif parser == "brigadier:bool":
    if word in ["true", "false"]: return some(stop)
  elif parser in ["brigadier:integer", "brigadier:float", "brigadier:double"]:
    let value = parseNumber(parser, word)
    if value.isSome:
      let isInRange = value.get >= properties.min.get(-Inf) and
                      value.get <= properties.max.get(Inf)
      if isInRange: return some(stop)
      walk.fail(Problem(at: pos, expected: describeParser(parser), outOfRange: true))
      return none(int)
  elif isEntityParser(parser):
    if isEntity(word):
      let failure = selectorFailure(walk.tree.registries, word)
      if failure.isNone: return some(stop)
      walk.fail(Problem(at: pos + failure.get.at, message: some(failure.get.message)))
      return none(int)
  elif parser in ["minecraft:block_pos", "minecraft:vec3"]:
    return walk.readCoordinates(pos, 3)
  elif parser in ["minecraft:vec2", "minecraft:column_pos", "minecraft:rotation"]:
    return walk.readCoordinates(pos, 2)
  elif isResourceParser(parser):
    if isResourceLocation(word, walk.poplarNamespaces): return some(stop)
  elif word.len > 0:
    return some(stop)

  walk.fail(Problem(at: pos, expected: describeParser(parser)))
  none(int)

func matchChildren(walk: var Walk, node: Node, pos: int): bool

func matchAfter(walk: var Walk, node: Node, stop: int): bool =
  if stop == walk.text.len:
    if node.executable: return true
    walk.fail(Problem(at: stop, expected: "more arguments"))
    return false

  if walk.text[stop] != ' ':
    walk.fail(Problem(at: stop, expected: "a space"))
    return false

  let next = walk.continuation(node)
  if next == nil:
    walk.fail(Problem(at: stop + 1, expected: "end of command"))
    return false
  walk.matchChildren(next, stop + 1)

func matchChildren(walk: var Walk, node: Node, pos: int): bool =
  if node.children.len == 0: return false
  var hasLiteral = false

  for name, child in node.children:
    if child.kind != nkLiteral: continue
    hasLiteral = true
    let stop = pos + name.len
    if not walk.text.continuesWith(name, pos): continue
    if stop < walk.text.len and walk.text[stop] != ' ': continue
    if walk.matchAfter(child, stop): return true

  for child in node.children.values:
    if child.kind != nkArgument: continue
    let stop = walk.readArgument(child, pos)
    if stop.isNone: continue
    if walk.matchAfter(child, stop.get):
      walk.addIdStarts(child.parser, child.properties, pos, stop.get)
      return true

  if hasLiteral: walk.fail(Problem(at: pos, expected: if node ==
      walk.tree.root: "a command" else: "a subcommand"))
  false

func checkText*(tree: CommandTree, text: string, poplarNamespaces: openArray[string]): Checked =
  ## `poplarNamespaces` are the namespaces whose ids can be Poplar names with capitals
  ## (`self:healPlayer`).
  var walk = Walk(tree: tree, text: text, poplarNamespaces: @poplarNamespaces)
  if walk.matchChildren(tree.root, 0): return Checked(ids: walk.ids)
  if walk.furthest.isNone: return Checked(failure: some(Failure(message: "invalid command", at: 0)))
  let failure = walk.furthest.get
  Checked(failure: some(Failure(message: failure.describe(text, tree.registries), at: failure.at)))

func checkSelector*(tree: CommandTree, selector: string): Option[Failure] =
  selectorFailure(tree.registries, selector)
