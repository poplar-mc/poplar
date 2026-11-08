# Build-time values: evaluating constant expressions, and writing values as text or SNBT. Part of compiler.nim.

func tagName(value: Value): string =
  ## The kind of a value, as error messages name it.
  case value
  of StringValue: "string"
  of NumberValue: "number"
  of TypedNumberValue: "typed_number"
  of BooleanValue: "boolean"
  of NullValue: "null"
  of ListValue: "list"
  of CompoundValue: "compound"

func numberOf(value: Value): Option[int64] =
  case value
  of NumberValue(number): some(number)
  else: none(int64)

proc containsRuntimeValue(expression: Expression): bool =
  case expression
  of NameExpression(identifier): identifier.kind != ikCompileTime
  of MinecraftCheck, MacroKey: true
  of PrefixExpression(prefix): containsRuntimeValue(prefix.operand)
  of InfixExpression(infix): containsRuntimeValue(infix.left) or containsRuntimeValue(infix.right)
  of ListExpression(elements): elements.anyIt(containsRuntimeValue(it))
  of CompoundExpression(entries): entries.anyIt(containsRuntimeValue(it.value))
  of CallExpression(call):
    # An mcfun runs in the game. `text(#hp)` only names the score, so it is known when the pack is built.
    if isBuiltinCall(call, "text"): false
    elif not isBuiltinCall(call, "len") and not isStringCall(call) and not isStringTest(call): true
    else: call.args.anyIt(containsRuntimeValue(it))
  else: false

func prefixOperatorText(op: PrefixOperator): string =
  case op
  of poNegate: "-"
  of poNot: "!"

func infixOperatorText(op: InfixOperator): string =
  case op
  of ioAdd: "+"
  of ioSubtract: "-"
  of ioMultiply: "*"
  of ioDivide: "/"
  of ioModulo: "%"
  of ioEqual: "=="
  of ioNotEqual: "!="
  of ioLess: "<"
  of ioLessEqual: "<="
  of ioGreater: ">"
  of ioGreaterEqual: ">="
  of ioAnd: "and"
  of ioOr: "or"

func typedNumberSnbt(number: TypedNumber): string =
  ## `0.05f`: the number as written, with the suffix of its type. A plain decimal has none, so it is a double.
  number.text & (if number.numberType.isSome: number.numberType.get.suffix else: "")

func valueToText(value: Value): string =
  case value
  of StringValue(text): text
  of NumberValue(number): $number
  of TypedNumberValue(number): typedNumberSnbt(number)
  of BooleanValue(boolean): (if boolean: "true" else: "false")
  of NullValue: "null"
  of ListValue, CompoundValue: valueToSnbt(value)

func snbtKey(key: string): string =
  ## A key is written as it is when it is a plain name, else in quotes.
  if not key.allCharsInSet(Letters + Digits + {'_', '-', '.', '+'}): return valueToSnbt(StringValue(text: key))
  if key.len == 0: "\"\"" else: key

func valueToSnbt(value: Value): string =
  case value
  of ListValue(elements): "[" & elements.mapIt(valueToSnbt(it)).join(",") & "]"
  of CompoundValue(entries): "{" & entries.mapIt(snbtKey(it.key) & ":" & valueToSnbt(it.value)).join(",") & "}"
  of StringValue(text):
    var snbt = "\""
    for ch in text:
      if ch in {'"', '\\'}: snbt.add '\\'
      snbt.add ch
    snbt & "\""
  else: valueToText(value)

func valuesEqual(left, right: Value): bool =
  ## Both values have the same kind.
  case left
  of StringValue(text):
    case right
    of StringValue(other): text == other
    else: false
  of NumberValue(number):
    case right
    of NumberValue(other): number == other
    else: false
  of TypedNumberValue(number):
    case right
    of TypedNumberValue(other): number.numberType == other.numberType and number.text == other.text
    else: false
  of BooleanValue(boolean):
    case right
    of BooleanValue(other): boolean == other
    else: false
  of NullValue: true
  of ListValue(elements):
    case right
    of ListValue(others):
      if elements.len != others.len: return false
      for index, element in elements:
        if tagName(element) != tagName(others[index]) or not valuesEqual(element, others[index]): return false
      true
    else: false
  of CompoundValue(entries):
    case right
    of CompoundValue(others):
      if entries.len != others.len: return false
      for index, entry in entries:
        let other = others[index]
        if entry.key != other.key or tagName(entry.value) != tagName(other.value) or
           not valuesEqual(entry.value, other.value): return false
      true
    else: false

# ---- math that finds overflow

func checkedAdd(a, b: int64): Option[int64] =
  if (b > 0 and a > high(int64) - b) or (b < 0 and a < low(int64) - b): none(int64) else: some(a + b)

func checkedSub(a, b: int64): Option[int64] =
  if (b < 0 and a > high(int64) + b) or (b > 0 and a < low(int64) + b): none(int64) else: some(a - b)

func checkedMul(a, b: int64): Option[int64] =
  if a == 0 or b == 0: return some(0'i64)
  if (a == -1 and b == low(int64)) or (b == -1 and a == low(int64)): return none(int64)
  let product = a *% b
  if product div b != a: none(int64) else: some(product)

func floorMod(a, b: int64): int64 =
  ## The same result as Java's Math.floorMod, which Minecraft uses for `%=`. `b` is not 0.
  if b == -1: return 0
  let remainder = a mod b
  if remainder != 0 and (remainder < 0) != (b < 0): remainder + b else: remainder

proc checkedNumber(compiler: Compiler, number: Option[int64]): Value =
  if number.isNone: compiler.fail("integer overflow")
  NumberValue(number: number.get)

# ---- evaluation

proc evaluateCall(compiler: Compiler, call: Call, env: Environment): Value =
  ## `text(x)` and `len(x)` on a compile-time value are known when the pack is built.
  let callee = identifierOf(call.callee)
  if callee.isNone: compiler.fail("only named functions can be called")
  let identifier = callee.get
  let name = identifier.name
  if isBuiltinCall(call, "text"):
    if call.args.len != 1: compiler.fail(&"'text' expects 1 argument, found {call.args.len}")
    return textComponent(compiler, call.args[0], env)
  if isStringCall(call) or isStringTest(call): return evaluateStringCall(compiler, call, env)
  if isBuiltinCall(call, "len") and call.args.len == 1:
    let value = evaluate(compiler, call.args[0], env)
    case value
    of ListValue(elements): return NumberValue(number: elements.len)
    of CompoundValue(entries): return NumberValue(number: entries.len)
    # The game counts UTF-16 units.
    of StringValue(text): return NumberValue(number: utf16Length(text).get(text.len))
    else: discard
  if calledKey(compiler, identifier).isSome:
    compiler.fail(&"mcfun '{name}' runs in the game, so its result is not known when the pack is built")
  if identifier.namespace.isNone and isBuiltin(name):
    compiler.fail(&"'{name}' changes data in the game, so it has no build-time value")
  compiler.fail(&"unknown function '{name}'")

proc evaluatePrefix(compiler: Compiler, prefix: Prefix, env: Environment): Value =
  let operand = evaluate(compiler, prefix.operand, env)
  case operand
  of NumberValue(number):
    if prefix.op == poNegate: return compiler.checkedNumber(checkedSub(0, number))
  of TypedNumberValue(number):
    if prefix.op == poNegate:
      let negated = if number.text[0] == '-': number.text[1 .. ^1] else: "-" & number.text
      return TypedNumberValue(typedNumber: TypedNumber(text: negated, numberType: number.numberType))
  of BooleanValue(boolean):
    if prefix.op == poNot: return BooleanValue(boolean: not boolean)
  else: discard
  compiler.fail(&"operator '{prefixOperatorText(prefix.op)}' cannot be used with {tagName(operand)}")

proc evaluateNumbers(compiler: Compiler, op: InfixOperator, a, b: int64): Option[Value] =
  case op
  of ioAdd: some(compiler.checkedNumber(checkedAdd(a, b)))
  of ioSubtract: some(compiler.checkedNumber(checkedSub(a, b)))
  of ioMultiply: some(compiler.checkedNumber(checkedMul(a, b)))
  of ioDivide:
    if b == 0: compiler.fail("division by zero")
    some(compiler.checkedNumber(if a == low(int64) and b == -1: none(int64) else: some(floorDiv(a, b))))
  of ioModulo:
    if b == 0: compiler.fail("division by zero")
    some(NumberValue(number: floorMod(a, b)))
  of ioLess: some(BooleanValue(boolean: a < b))
  of ioLessEqual: some(BooleanValue(boolean: a <= b))
  of ioGreater: some(BooleanValue(boolean: a > b))
  of ioGreaterEqual: some(BooleanValue(boolean: a >= b))
  else: none(Value)

proc evaluateInfix(compiler: Compiler, infix: Infix, env: Environment): Value =
  let left = evaluate(compiler, infix.left, env)
  let right = evaluate(compiler, infix.right, env)
  let (leftTag, rightTag) = (tagName(left), tagName(right))

  if infix.op == ioAdd and "string" in [leftTag, rightTag]:
    return StringValue(text: valueToText(left) & valueToText(right))

  let (leftNumber, rightNumber) = (numberOf(left), numberOf(right))
  if leftNumber.isSome and rightNumber.isSome:
    let number = compiler.evaluateNumbers(infix.op, leftNumber.get, rightNumber.get)
    if number.isSome: return number.get

  case left
  of BooleanValue(a):
    case right
    of BooleanValue(b):
      if infix.op == ioAnd: return BooleanValue(boolean: a and b)
      if infix.op == ioOr: return BooleanValue(boolean: a or b)
    else: discard
  else: discard

  if infix.op in {ioEqual, ioNotEqual} and leftTag == rightTag:
    let isEqual = valuesEqual(left, right)
    return BooleanValue(boolean: if infix.op == ioEqual: isEqual else: not isEqual)

  let opText = infixOperatorText(infix.op)
  if "typed_number" in [leftTag, rightTag]:
    compiler.fail(&"build-time math only works on whole numbers with no suffix, so '{opText}' cannot be used here")
  compiler.fail(&"operator '{opText}' cannot be used with {leftTag} and {rightTag}")

proc evaluate(compiler: Compiler, expression: Expression, env: Environment): Value =
  let outerPosition = compiler.enterExpression(expression)
  defer: compiler.position = outerPosition
  case expression
  of MinecraftCheck:
    compiler.fail("a Minecraft check such as 'block ~ ~ ~ stone' only works as an 'if' or 'while' condition")
  of MacroKey(key):
    compiler.fail(&"'$({key})' is a macro argument, known only when the call starts, so it cannot be used at " &
                  "compile time")
  of StringExpression(text): StringValue(text: text)
  of NumberExpression(number): NumberValue(number: number)
  of TypedNumberExpression(number): TypedNumberValue(typedNumber: number)
  of BooleanExpression(boolean): BooleanValue(boolean: boolean)
  of NullExpression: NullValue()
  of NameExpression(identifier):
    case identifier.kind
    of ikCompileTime: discard
    of ikScore: compiler.fail(&"score '#{identifier.name}' cannot be used here")
    of ikData: compiler.fail(&"data '${identifier.name}' cannot be used here")
    of ikEntityData: compiler.fail(&"entity data '{identifier.selector.get}.${identifier.name}' cannot be used here")
    let value = env.get(identifier.name)
    if value.isNone: compiler.fail(&"unknown name '{identifier.name}'")
    value.get
  of PrefixExpression(prefix): compiler.evaluatePrefix(prefix, env)
  of InfixExpression(infix): compiler.evaluateInfix(infix, env)
  of CallExpression(call): compiler.evaluateCall(call, env)
  of SelectorExpression(selector):
    let failure = compiler.commandTree.checkSelector(selector)
    if failure.isSome: compiler.fail(failure.get.message)
    StringValue(text: selector)
  of ListExpression(elements):
    var values: seq[Value]
    for element in elements: values.add evaluate(compiler, element, env)
    ListValue(elements: values)
  of CompoundExpression(entries):
    var values: seq[ValueEntry]
    for index, entry in entries:
      for earlier in entries[0 ..< index]:
        if earlier.key == entry.key: compiler.fail(&"key '{entry.key}' is used more than once")
      values.add ValueEntry(key: entry.key, value: evaluate(compiler, entry.value, env))
    CompoundValue(entries: values)
