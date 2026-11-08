import std/[options, sequtils, strutils, unittest]
import ../src/[command_tree, compiler, datapack_writer, ir, lexer, parser]

let tree = loadCommandTree()

proc parseForTest(source: string): auto =
  var sourceParser = initParser(initLexer(source))
  result = sourceParser.parseProgram()
  doAssert sourceParser.errors.len == 0, sourceParser.errors[0].message

proc compileForTest(source: string): Compiler =
  result = initCompiler(tree)
  result.addProgram("main.poplar", parseForTest(source), orProject)

proc render(program: Program, name: string): string =
  for function in program.functions:
    if function.name == name: return renderFunction("ns", function)
  raiseAssert "no function " & name

proc hasFunction(program: Program, name: string): bool = program.functions.anyIt(it.name == name)

proc messages(compiler: Compiler): seq[string] = compiler.errors.mapIt(it.message)

proc rawText(command: Command): string =
  case command
  of RawCommand(raw): raw
  else: raiseAssert "not a raw command"

suite "statements":
  test "assigns outer var from for body":
    let compiler = compileForTest("""
mcfun main() {
    var total = 0;
    for (1..4) |i| { total = total + i; }
    /say {{total}};
}""")
    let commands = compiler.compile().functions[0].commands
    check compiler.errors.len == 0
    check commands[0].rawText == "say 6"

  test "if else chain uses one wrapper, inlined when it is the last command":
    let compiler = compileForTest("""
var #hp = 0;
mcfun main() {
    if (#hp <= 0) { /say dead; } else if (#hp < 5) { /say low; } else { /say ok; }
}""")
    let program = compiler.compile()
    check compiler.errors.len == 0
    check program.render("main") == """
execute if score #global ns.hp matches ..0 run return run say dead
execute if score #global ns.hp matches ..4 run return run say low
say ok
"""
    check not program.hasFunction("poplar/main/if_0")

  test "rejects compile-time change in runtime if":
    let compiler = compileForTest("""
var #a = 0;
mcfun main() { var count = 0; if (#a > 0) { count = 1; } }""")
    discard compiler.compile()
    check compiler.messages == @["cannot change compile-time 'count' inside a runtime 'if' or 'execute'"]

  test "errors point to their expression":
    let compiler = compileForTest("""
var #total = 0;
mcfun helper() {
    missing();
}
mcfun main() {
    var x = y;
    var copy = #total;
}""")
    discard compiler.compile()
    let errors = compiler.errors
    check errors.len == 3
    check errors[0].position.get.line == 3
    check errors[0].position.get.column == 5
    check errors[1].position.get.line == 6
    check errors[1].position.get.column == 13
    check errors[2].message == "'copy' is a build-time constant, but this value only exists in the game. Use " &
                               "'var #copy' for a score or 'var $copy' for data"

  test "break, continue and return in loops and execute bodies":
    let compiler = compileForTest("""
var #i = 0;
mcfun count() {
    while (true) {
        #i = #i + 1;
        if (#i > 9) { break; }
        if (#i == 5) { continue; }
    }
}
mcfun find() {
    while (#i < 100) {
        if (#i > 50) { return #i; }
        #i = #i + 1;
    }
    return -1;
}
mcfun any() {
    execute (as @e) { if (@s.#i > 5) { return 1; } }
    return 0;
}""")
    let program = compiler.compile()
    check compiler.errors.len == 0
    check program.render("poplar/count/while_0_body") == """
scoreboard players add #global ns.i 1
execute if score #global ns.i matches 10.. run return 0
execute if score #global ns.i matches 5 run return run function ns:poplar/count/while_0
function ns:poplar/count/while_0
"""
    check program.render("find") == """
execute if function ns:poplar/find/while_0 run return run scoreboard players get #poplar.find.result poplar.ns
return -1
"""
    check program.render("poplar/find/if_1") == """
scoreboard players operation #poplar.find.result poplar.ns = #global ns.i
return 1
"""
    check program.render("any") == """
execute as @e if function ns:poplar/any/execute_1 run return run scoreboard players get #poplar.any.result poplar.ns
return 0
"""

  test "return errors":
    let compiler = compileForTest("""
var #a = 0;
mcfun f() {
    if (#a > 0) {
        if (#a > 1) { return 1; }
        #a = 2;
    }
    if (#a == 9) { break; }
    while (true) { #a = 1; }
    return 1;
    #a = 4;
}""")
    discard compiler.compile()
    let errors = compiler.errors
    check compiler.messages == @[
      "if one branch of an 'if' contains 'return', 'break' or 'continue', every branch must end with one",
      "'break' must be inside a 'while' (not in 'execute (...)')",
      "this 'while' never stops: add a 'break' or 'return', or use a score or data value in the condition",
      "code after 'return', 'break' or 'continue' is never run",
    ]
    check errors[0].position.get.line == 3
    check errors[3].position.get.line == 10

  test "locals are set on every call, saved around a recursive call, and data locals are removed at each exit":
    let compiler = compileForTest("""
mcfun walk() {
    var #mine = $(depth);
    var $seen = true;
    if ($(depth) > 0) { walk() with {depth: $(depth) - 1}; }
    /say {{#mine}} {{$seen}};
}
mcfun twice() {
    var $v = $(n);
    return $v * 2;
}""")
    let program = compiler.compile()
    check compiler.errors.len == 0
    check program.render("walk") == """
$scoreboard players set #mine_walk poplar.ns $(depth)
data modify storage ns:data seen_walk set value true
scoreboard players operation #poplar.walk.t0 poplar.ns = #mine_walk poplar.ns
$execute if score #poplar.walk.t0 poplar.ns matches 1.. run function ns:poplar/walk/if_0 {depth:"$(depth)"}
execute store result storage ns:poplar macro.mine int 1 run scoreboard players get #mine_walk poplar.ns
data modify storage ns:poplar macro.seen_walk set from storage ns:data seen_walk
function ns:poplar/walk/macro_1 with storage ns:poplar macro
data remove storage ns:data seen_walk
"""
    check program.render("twice") == """
$data modify storage ns:data v_twice set value $(n)
execute store result score #poplar.twice.t0 poplar.ns run data get storage ns:data v_twice 2
data remove storage ns:data v_twice
return run scoreboard players get #poplar.twice.t0 poplar.ns
"""
    check program.render("poplar/walk/if_0") == """
$scoreboard players set #poplar.walk.t0 poplar.ns $(depth)
execute store result storage ns:poplar args.depth int 1 run scoreboard players remove #poplar.walk.t0 poplar.ns 1
data modify storage ns:poplar stack append value {}
execute store result storage ns:poplar stack[-1].s_mine_walk int 1 run scoreboard players get #mine_walk poplar.ns
data modify storage ns:poplar stack[-1].d_seen_walk set from storage ns:data seen_walk
function ns:walk with storage ns:poplar args
execute store result score #mine_walk poplar.ns run data get storage ns:poplar stack[-1].s_mine_walk
data modify storage ns:data seen_walk set from storage ns:poplar stack[-1].d_seen_walk
data remove storage ns:poplar stack[-1]
"""

  test "local errors":
    let compiler = compileForTest("""
var #hp = 0;
mcfun c() { var #a_b = 1; }
mcfun b_c() { var #a = 1; }
mcfun main() {
    var #hp = 1;
    var #i = 0;
    @s.#i = 1;
    if (#i > 0) { var #inner = 1; }
    #inner = 2;
}""")
    discard compiler.compile()
    check compiler.messages == @[
      "'#a_b' in 'c' and '#a' in 'b_c' both become '#a_b_c'. Rename one",
      "'#hp' is already declared",
      "'#i' is local, so it has no entity values. Declare it at the top level",
      "unknown score '#inner'",
    ]

  test "a wrapper that can return is not inlined where the return value is read":
    let compiler = compileForTest("""
var #a = 0;
mcfun pick() {
    if (#a > 0) { /say a; } else { /say b; }
}
mcfun main() { #a = pick(); }""")
    let program = compiler.compile()
    check compiler.errors.len == 0
    check program.render("pick") == "function ns:poplar/pick/if_0\n"

suite "values":
  test "unrolls for with string concatenation":
    let compiler = compileForTest("""mcfun main() { for (0..3) |i| { /say {{"step " + i}}; } }""")
    let commands = compiler.compile().functions[0].commands
    check compiler.errors.len == 0
    check commands.len == 3
    check commands[0].rawText == "say step 0"
    check commands[2].rawText == "say step 2"

  test "folds compile-time if":
    let compiler = compileForTest("mcfun main() { for (0..4) |i| { if (i % 2 == 0) { /say {{i}}; } } }")
    let program = compiler.compile()
    check compiler.errors.len == 0
    check program.render("main") == "say 0\nsay 2\n"

suite "scores":
  test "lowers score expression in place":
    let compiler = compileForTest("""
var #a = 0;
var #b = 1;
var #c = 2;
mcfun f() { #a = (#b + 3) * #c; }""")
    let program = compiler.compile()
    check compiler.errors.len == 0
    check program.render("f") == """
scoreboard players operation #global ns.a = #global ns.b
scoreboard players add #global ns.a 3
scoreboard players operation #global ns.a *= #global ns.c
"""

  test "uses temp when target is read after write":
    let compiler = compileForTest("""
var #a = 0;
var #b = 1;
mcfun f() { #a = #b - #a; }""")
    let program = compiler.compile()
    check compiler.errors.len == 0
    check program.render("f") == """
scoreboard players operation #poplar.f.t0 poplar.ns = #global ns.b
execute store result score #global ns.a run scoreboard players operation #poplar.f.t0 poplar.ns -= #global ns.a
"""

  test "entity scores and execute blocks":
    let compiler = compileForTest("""
var #mana = 0;
var #max = 100;
mcfun tick() {
    @a.#mana = 0;
    execute (as @a at @s) {
        @s.#mana = @s.#mana + 1;
        if (@s.#mana > #max) { @s.#mana = #max; }
        /particle heart ~ ~2 ~;
    }
}""")
    let program = compiler.compile()
    check compiler.errors.len == 0
    check program.render("tick") == """
scoreboard players set @a ns.mana 0
execute as @a at @s run function ns:poplar/tick/execute_0
"""
    check program.render("poplar/tick/execute_0") == """
scoreboard players add @s ns.mana 1
execute if score @s ns.mana > #global ns.max run scoreboard players operation @s ns.mana = #global ns.max
particle heart ~ ~2 ~
"""
    check renderFunction("ns", program.load.get) == """
scoreboard objectives add poplar.ns dummy
scoreboard objectives add ns.mana dummy
scoreboard objectives add ns.max dummy
execute unless score #global ns.max matches -2147483648.. run scoreboard players set #global ns.max 100
"""

  test "entity score errors":
    let compiler = compileForTest("""
var #mana = 0;
mcfun main() {
    #mana = @a.#mana;
    execute (az @a) { /say hi; }
    @s.$Health = #mana;
}""")
    discard compiler.compile()
    check compiler.messages == @["'@a.#mana' needs a selector for one entity (@s, @p, @r, @n or limit=1)",
                                 "expected a subcommand, found 'az'"]
    check compiler.errors[1].position.get.column == 14

suite "conditions":
  test "negated and becomes or":
    let compiler = compileForTest("""
var #a = 0;
var #b = 0;
mcfun main() { if (!(#a > 1 and #b == 2)) { /say x; } }""")
    let program = compiler.compile()
    check compiler.errors.len == 0
    check program.render("main") == """
execute unless score #global ns.a matches 2.. run return run say x
execute unless score #global ns.b matches 2 run return run say x
"""

  test "Minecraft checks in conditions mix with score checks":
    let compiler = compileForTest("""
predicate isSitting { "type": "minecraft:random_chance", "chance": 0.5 }
var #mana = 0;
mcfun main() {
    if (block ~ ~-1 ~ #minecraft:logs and #mana > 5) { /say log; }
    if (!predicate self:isSitting or entity @s[type=pig]) { /say hi; }
    if (block ~ ~ ~ stoen) { /say typo; }
}""")
    let program = compiler.compile()
    check compiler.messages == @["unknown block 'stoen'. Did you mean 'stone'?"]
    check compiler.errors[0].position.get.column == 21
    check program.render("main") == """
execute if block ~ ~-1 ~ #minecraft:logs if score #global ns.mana matches 6.. run say log
execute unless predicate ns:is_sitting run return run say hi
execute if entity @s[type=pig] run return run say hi
"""

suite "data":
  test "data variables use storage and macros":
    let compiler = compileForTest("""
var $item = "diamond";
var $count = 3;
var #kills = 0;
mcfun main() {
    $count = #kills;
    /give @p {{$item}} {{$count}};
}""")
    let program = compiler.compile()
    check compiler.errors.len == 0
    check program.render("main") == """
execute store result storage ns:data count int 1 run scoreboard players get #global ns.kills
function ns:poplar/main/macro_0 with storage ns:data
"""
    check program.render("poplar/main/macro_0") == "$give @p $(item) $(count)\n"
    check renderFunction("ns", program.load.get) == """
scoreboard objectives add poplar.ns dummy
scoreboard objectives add ns.kills dummy
execute unless score #global ns.kills matches -2147483648.. run scoreboard players set #global ns.kills 0
execute unless data storage ns:data item run data modify storage ns:data item set value "diamond"
execute unless data storage ns:data count run data modify storage ns:data count set value 3
"""

  test "reads and writes entity data":
    let compiler = compileForTest("""
var #hp = 0;
var $pos = 0;
mcfun main() {
    #hp = @s.$Health * 10;
    @s.$Health = #hp;
    @s.$data.x = #hp + 1;
    $pos = @s.$Pos;
    @s.$Glowing = 1b;
}""")
    let program = compiler.compile()
    check compiler.errors.len == 0
    check program.render("main") == """
execute store result score #global ns.hp run data get entity @s Health 10
execute store result entity @s Health int 1 run scoreboard players get #global ns.hp
scoreboard players operation #poplar.main.t0 poplar.ns = #global ns.hp
execute store result entity @s data.x int 1 run scoreboard players add #poplar.main.t0 poplar.ns 1
data modify storage ns:data pos set from entity @s Pos
data modify entity @s Glowing set value 1b
"""

  test "SNBT numbers are written as they are, and scores reject them":
    let compiler = compileForTest("""
var $small = 0.05f;
var $item = {myNum: 0.05f, count: 1b, list: [5s, 5L, 0.5]};
var #hp = 0;
mcfun main() {
    $small = -0.5d;
    if ($small == 0.05f) { /say same; }
    if ($small == -0.5d) { /say negative; }
    #hp = 0.05;
    #hp = 5b;
    if (#hp > 0.5f) { /say big; }
    $small = 0.5 + 1;
}""")
    let program = compiler.compile()
    check compiler.messages == @[
      "a score holds whole numbers, so it cannot hold '0.05'",
      "a score has no number types: write '5' with no suffix",
      "a score holds whole numbers with no suffix, so it cannot be compared with '0.5'",
      "build-time math only works on whole numbers with no suffix, so '+' cannot be used here",
    ]
    let load = renderFunction("ns", program.load.get)
    check "small set value 0.05f" in load
    check "item set value {myNum:0.05f,count:1b,list:[5s,5L,0.5]}" in load
    let main = program.render("main")
    check "data modify storage ns:data small set value -0.5d\n" in main
    check "{small:0.05f}" in main
    check "{small:-0.5d}" in main

  test "a score or math is stored as an int, and a macro argument as its own text":
    let compiler = compileForTest("""
var #a = 3;
var $ratio = 0f;
var $speeds = [1, 2];
mcfun heal() { /say $(label) $(amount); }
mcfun main() {
    $ratio = #a * 2;
    $speeds = #a;
    heal() with {amount: #a, label: "hi"};
}
mcfun setSpeed() {
    $ratio = $(speed);
    @s.$Health = $(speed);
    $speeds = {first: $(speed)};
}""")
    let program = compiler.compile()
    check compiler.errors.len == 0
    check program.render("main") == """
scoreboard players operation #poplar.main.t0 poplar.ns = #global ns.a
execute store result storage ns:data ratio int 1 run scoreboard players operation #poplar.main.t0 poplar.ns *= #poplar.c2 poplar.ns
execute store result storage ns:data speeds int 1 run scoreboard players get #global ns.a
execute store result storage ns:poplar args.amount int 1 run scoreboard players get #global ns.a
data modify storage ns:poplar args.label set value "hi"
function ns:heal with storage ns:poplar args
"""
    check program.render("setSpeed") == """
$data modify storage ns:data ratio set value $(speed)
$data modify entity @s Health set value $(speed)
data modify storage ns:data speeds set value {first:0}
$data modify storage ns:data speeds.first set value $(speed)
"""
    let load = renderFunction("ns", program.load.get)
    check "ratio set value 0f" in load
    check "speeds set value [1,2]" in load

  test "paths, literals with runtime parts, list helpers and data conditions":
    let compiler = compileForTest("""
var #x = 3;
var $stats = {hp: 20, name: "x"};
var $pos = [0, 0];
var $names = [];
var $flag = true;
mcfun main() {
    $stats.hp = #x;
    $pos = [#x, 1];
    append($names, "Steve");
    append($names, #x);
    #x = len($names);
    if ($stats.name == "x" and $flag == true) { /say ok; }
    if ($stats.bonus) { /say bonus; }
    if (!@s.$SelectedItem.components.enchantments) { /say plain; }
}""")
    let program = compiler.compile()
    check compiler.errors.len == 0
    check program.render("main") == """
execute store result storage ns:data stats.hp int 1 run scoreboard players get #global ns.x
data modify storage ns:data pos set value [0,1]
execute store result storage ns:data pos[0] int 1 run scoreboard players get #global ns.x
data modify storage ns:data names append value "Steve"
data modify storage ns:data names append value 0
execute store result storage ns:data names[-1] int 1 run scoreboard players get #global ns.x
execute store result score #global ns.x run data get storage ns:data names
execute if data storage ns:data {stats:{name:"x"}} if data storage ns:data {flag:1b} run say ok
execute if data storage ns:data stats.bonus run say bonus
execute unless data entity @s SelectedItem.components.enchantments run say plain
"""

  test "string helpers use set string, and run in the compiler on constants":
    let compiler = compileForTest("""
var $id = "minecraft:diamond";
var #n = 42;
mcfun main() {
    $id = slice(@s.$SelectedItem.id, 10, -2);
    $id = str(#n);
    /say {{slice("minecraft:stone", 10)}};
    if (endsWith($id, "_sword")) { /say sword; }
    #n = slice($id, 1);
}""")
    let program = compiler.compile()
    check compiler.messages == @["'slice' gives a string, so it cannot be a score. Store it in data: " &
                                 "'$x = slice(...);'"]
    check program.render("main") == """
data modify storage ns:data id set string entity @s SelectedItem.id 10 -2
execute store result storage ns:poplar string int 1 run scoreboard players get #global ns.n
data modify storage ns:data id set string storage ns:poplar string
say stone
data modify storage ns:poplar string_test set value ""
data modify storage ns:poplar string_test set string storage ns:data id -6
execute if data storage ns:poplar {string_test:"_sword"} run say sword
"""

suite "calls":
  test "a recursive call saves the locals of an mcfun in another namespace where they are":
    let compiler = initCompiler(tree)
    compiler.addProgram("magic.poplar", parseForTest("""
namespace magic;
mcfun down() {
    var #i = 1;
    var $name = "a";
    if (#i > 0) { down(); }
    /say {{#i}} {{$name}};
}"""), orProject)
    let program = compiler.compile()
    check compiler.errors.len == 0
    check program.render("magic:poplar/down/if_0") == """
data modify storage ns:poplar stack append value {}
execute store result storage ns:poplar stack[-1].s_i_down int 1 run scoreboard players get #i_down poplar.magic
data modify storage ns:poplar stack[-1].d_name_down set from storage magic:data name_down
function magic:down
execute store result score #i_down poplar.magic run data get storage ns:poplar stack[-1].s_i_down
data modify storage magic:data name_down set from storage ns:poplar stack[-1].d_name_down
data remove storage ns:poplar stack[-1]
"""

  test "a name with a namespace is never a builtin, and an mcfun is not known at build time":
    let compiler = compileForTest("""
var $list = [];
var #n = 0;
mcfun main() { #n = ns:len($list); }
mcfun one() { return 1; }
mcfun range() { for (0..one()) |i| { /say {{i}}; } }""")
    discard compiler.compile()
    check compiler.messages == @["unknown function 'len'",
                                 "mcfun 'one' runs in the game, so its result is not known when the pack is built"]

  test "return values, mcfun calls as values and while":
    let compiler = compileForTest("""
var #x = 0;
mcfun sign() {
    if (#x > 0) { return 1; } else if (#x < 0) { return -1; }
    return 0;
}
mcfun main() {
    #x = sign() + 1;
    while (#x < 5) { #x = #x + 1; }
}""")
    let program = compiler.compile()
    check compiler.errors.len == 0
    check program.render("sign") == """
execute if score #global ns.x matches 1.. run return 1
execute if score #global ns.x matches ..-1 run return -1
return 0
"""
    check program.render("main") == """
execute store result score #global ns.x run function ns:sign
scoreboard players add #global ns.x 1
execute if score #global ns.x matches ..4 run function ns:poplar/main/while_0_body
"""
    check not program.hasFunction("poplar/main/while_0")
    check program.render("poplar/main/while_0_body") == """
scoreboard players add #global ns.x 1
execute if score #global ns.x matches ..4 run function ns:poplar/main/while_0_body
"""

  test "with compounds become macro arguments":
    let compiler = compileForTest("""
var #hp = 0;
mcfun heal() {
    #hp = #hp + $(amount);
    if (#hp > 10) { /say $(amount); #hp = 10; }
}
mcfun main() {
    heal() with {amount: 5};
    heal() with {amount: #hp * 2};
}""")
    let program = compiler.compile()
    check compiler.errors.len == 0
    check program.render("heal") == """
$scoreboard players set #poplar.heal.t0 poplar.ns $(amount)
scoreboard players operation #global ns.hp += #poplar.heal.t0 poplar.ns
$execute if score #global ns.hp matches 11.. run function ns:poplar/heal/if_0 {amount:"$(amount)"}
"""
    check program.render("poplar/heal/if_0") == """
$say $(amount)
scoreboard players set #global ns.hp 10
"""
    check program.render("main") == """
function ns:heal {amount:5}
scoreboard players operation #poplar.main.t0 poplar.ns = #global ns.hp
execute store result storage ns:poplar args.amount int 1 run scoreboard players operation #poplar.main.t0 poplar.ns *= #poplar.c2 poplar.ns
function ns:heal with storage ns:poplar args
"""

  test "with: a compound must have the keys the body uses, and a declared non-compound is an error":
    let compiler = compileForTest("""
var $num = 0.05f;
var $list = [1];
var $later = 0;
var $raw = 0;
var $comp = {a: 1};
var #hp = 0;
mcfun two() { if ($(a) > 0) { /say $(b); } }
mcfun plain() { /say x; }
mcfun set() { $later = {a: 1, b: 2}; /data modify storage self:data raw set value {a: 1, b: 2}; }
mcfun main() {
    two() with {a: 1};
    two() with {a: #hp};
    two() with {a: 1, b: 2, extra: 3};
    plain() with {a: 1};
    two() with $comp;
    two() with $later;
    two() with $raw;
    two() with $num;
    two() with $list;
}""")
    discard compiler.compile()
    check compiler.messages == @[
      "mcfun 'two' uses '$(b)', but this compound has no key 'b'",
      "mcfun 'two' uses '$(b)', but this compound has no key 'b'",
      "'with' needs a compound, but '$num' is 0.05f. Declare it as a compound: 'var $num = {name: 0.05f};'",
      "'with' needs a compound, but '$list' is [1]. Declare it as a compound: 'var $list = {name: [1]};'",
    ]

  test "mcfun call errors":
    let compiler = compileForTest("""
mcfun heal() {
    var copy = $(amount);
}
mcfun main() { heal(); heal(5); heal() with 5; }""")
    discard compiler.compile()
    check compiler.messages == @[
      "'copy' is a build-time constant, but this value only exists in the game. Use 'var #copy' for a score or " &
        "'var $copy' for data",
      "mcfun 'heal' uses '$(amount)', so it needs a compound: 'heal() with {amount: ...}'",
      "mcfun 'heal' takes no arguments. Pass them as a compound: 'heal() with {amount: ...}'",
      "'with' needs a compound ('{name: ...}'), a '$' variable, 'entity <selector>' or 'block <position>'",
    ]

  test "recursive calls save live temps in a frame":
    let compiler = compileForTest("""
var #x = 0;
mcfun fact() {
    if ($(n) <= 1) { return 1; }
    return $(n) * fact() with {n: $(n) - 1};
}
mcfun double() { return $(v) * 2; }
mcfun main() { #x = 2 * double() with {v: 3}; }""")
    let program = compiler.compile()
    check compiler.errors.len == 0
    check program.render("fact") == """
$scoreboard players set #poplar.fact.t0 poplar.ns $(n)
execute if score #poplar.fact.t0 poplar.ns matches ..1 run return 1
scoreboard players operation #poplar.fact.t2 poplar.ns = #poplar.fact.t0 poplar.ns
execute store result storage ns:poplar args.n int 1 run scoreboard players remove #poplar.fact.t2 poplar.ns 1
data modify storage ns:poplar stack append value {}
execute store result storage ns:poplar stack[-1].t0 int 1 run scoreboard players get #poplar.fact.t0 poplar.ns
execute store result score #poplar.fact.t1 poplar.ns run function ns:fact with storage ns:poplar args
execute store result score #poplar.fact.t0 poplar.ns run data get storage ns:poplar stack[-1].t0
data remove storage ns:poplar stack[-1]
return run scoreboard players operation #poplar.fact.t0 poplar.ns *= #poplar.fact.t1 poplar.ns
"""
    check program.render("main") == """
scoreboard players set #global ns.x 2
execute store result score #poplar.main.t0 poplar.ns run function ns:double {v:3}
scoreboard players operation #global ns.x *= #poplar.main.t0 poplar.ns
"""
    check renderFunction("ns", program.load.get).startsWith("data modify storage ns:poplar stack set value []\n")

suite "declarations":
  test "data files go to their folder, and self: names them in commands":
    let compiler = compileForTest("""
predicate isSneaking { "condition": "minecraft:entity_properties" }
lootTable "minecraft:entities/zombie" { "pools": [{ "rolls": 0.5 }] }
biomeTag hot { "values": [] }
recpie a {}
recipe b {
  "a": [1,]
}
recipe "b" {}
mcfun main() { /execute if predicate self:isSneaking run say hi; }""")
    let program = compiler.compile()
    check compiler.messages == @["unknown data file type 'recpie'. Did you mean 'recipe'?",
                                 "invalid JSON in recipe 'b'",
                                 "recipe 'ns:b' is already declared at main.poplar:5"]
    check compiler.errors[1].position.get.line == 6
    check program.functions[0].commands[0].rawText == "execute if predicate ns:is_sneaking run say hi"
    let files = program.dataFiles
    check files[0].folder == "predicate"
    check files[0].path == "is_sneaking"
    check files[1].namespace == "minecraft"
    check files[1].path == "entities/zombie"
    check files[2].folder == "tags/worldgen/biome"

  test "two namespaces keep their own names, files and scores":
    const packSource = """
namespace ns;
import magic;
var #mana = 0;
mcfun load() { #mana = 1; }
mcfun heal() { magic:heal(); /function magic:castSpell; /function self:heal; /give @s minecraft:stone; }"""
    const magicSource = """
namespace magic;
var #mana = 0;
mcfun load() { #mana = 2; }
mcfun heal() { #mana = #mana + 1; }
mcfun castSpell() { ns:heal(); }
mcfun build() { var $player = {mana: #mana}; }"""
    let compiler = initCompiler(tree)
    for source in [packSource, magicSource]: compiler.addProgram("main.poplar", parseForTest(source), orProject)
    let program = compiler.compile()
    check compiler.messages == @["namespace 'ns' is not imported. Add 'import ns;'"]
    check program.render("heal") == """
function magic:heal
function magic:cast_spell
function ns:heal
give @s minecraft:stone
"""
    check program.render("magic:heal") == "scoreboard players add #global magic.mana 1\n"
    check program.render("magic:build") == """
data modify storage magic:data player_build set value {mana:0}
execute store result storage magic:data player_build.mana int 1 run scoreboard players get #global magic.mana
data remove storage magic:data player_build
"""
    check renderFunction("ns", program.load.get).endsWith("function magic:load\nfunction ns:load\n")

suite "load":
  test "selectors as values, text parts and events":
    let compiler = compileForTest("""
var #hp = 7;
var $stats = {maxHp: 20};
mcfun tellraw() { /tellraw $(target) $(message); }
mcfun load() { onEvent("deathCount", playerDied); }
mcfun playerDied() { var #left = 3; tellraw() with {target: @a, message: ["HP ", text(#hp), text($stats.maxHp), text(@s.$CustomName), text(#left)]}; }
mcfun greet() { /say $(target); }
mcfun main() { greet() with {target: @p}; }""")
    let program = compiler.compile()
    check compiler.errors.len == 0
    check program.render("playerDied") == """
scoreboard players set #left_playerDied poplar.ns 3
function ns:tellraw {target:"@a",message:["HP ",{score:{name:"#global",objective:"ns.hp"}},{storage:"ns:data",nbt:"stats.maxHp"},{entity:"@s",nbt:"CustomName"},{score:{name:"#left_playerDied",objective:"poplar.ns"}}]}
"""
    check program.render("main") == "function ns:greet {target:\"@p\"}\n"
    check program.render("poplar/event_0") == "scoreboard players reset @s ns.event_0\nfunction ns:player_died\n"
    check program.render("poplar/tick") ==
      "execute as @a[scores={ns.event_0=1..}] at @s run function ns:poplar/event_0\n"
    check program.tick == @["poplar/tick"]

    let load = renderFunction("ns", program.load.get)
    check "scoreboard objectives add ns.event_0 deathCount\n" in load
    # `load` has only the event, so `poplar/load` does not call it.
    check "function ns:load" notin load

  test "onEvent errors":
    let compiler = compileForTest("""
mcfun load() {
    onEvent("deathCount", withMacroArgument);
    onEvent("deathCount", missing);
}
mcfun withMacroArgument() { /say $(x); }
mcfun other() { onEvent("deathCount", other); }""")
    discard compiler.compile()
    check compiler.messages == @[
      "the callback 'withMacroArgument' is run by the game, so it gets no macro arguments and cannot use '$(x)'",
      "unknown function 'missing'",
      "'onEvent' must be in 'mcfun load'",
    ]

  test "load and tick of a project namespace are run by the game, std's are not":
    let compiler = compileForTest("""
var #mana = 0;
mcfun load() { /say loaded; }
mcfun tick() { /say tick; }""")
    let program = compiler.compile()
    check renderFunction("ns", program.load.get) == """
scoreboard objectives add poplar.ns dummy
scoreboard objectives add ns.mana dummy
function ns:load
"""
    check program.tick == @["tick"]

    let library = initCompiler(tree)
    library.addProgram("lib.poplar", parseForTest("mcfun load() {} mcfun tick() {}"), orStd)
    let libraryProgram = library.compile()
    check libraryProgram.load.isNone
    check libraryProgram.tick.len == 0

  test "onTrigger makes a trigger objective, runs the callback and enables it again, even with the namespace name":
    let compiler = compileForTest("""
mcfun load() {
    onTrigger("ns", show);
    onTrigger("bad name", show);
    onTrigger("ns.mana", show);
}
mcfun show() { /say shown; }""")
    let program = compiler.compile()
    check compiler.messages == @[
      "the trigger name 'bad name' can only have letters, 0-9, '_', '-', '.' and '+'",
      "the trigger name 'ns.mana' starts with 'ns.', which Poplar uses for its own objectives",
    ]
    check program.render("poplar/tick") == """
execute as @a[scores={ns=1..}] at @s run function ns:poplar/event_0
scoreboard players enable @a ns
"""
    check program.render("poplar/event_0") == "scoreboard players reset @s ns\nfunction ns:show\n"
    check "scoreboard objectives add poplar.ns dummy\nscoreboard objectives add ns trigger\n" in
      renderFunction("ns", program.load.get)

  test "player events: first join, join, death and respawn":
    let compiler = compileForTest("""
mcfun load() { onFirstJoin(welcome); onJoin(greet); onRespawn(back); onJoin(); }
mcfun welcome() {}
mcfun greet() {}
mcfun back() {}""")
    let program = compiler.compile()
    check compiler.messages == @["'onJoin' expects 1 argument (callback), found 0"]
    check program.render("poplar/tick") == """
execute as @a[tag=!ns.event_0] at @s run function ns:poplar/event_0
execute as @a[tag=!ns.event_1] at @s run function ns:poplar/event_1
execute as @a[scores={ns.event_1=1..}] at @s run function ns:poplar/event_1
execute as @a[scores={ns.event_2=1..,ns.event_2_alive=1..}] at @s run function ns:poplar/event_2
"""

suite "Minecraft text":
  test "a bare name from this pack is an error where it can only be a function or a data file":
    let compiler = compileForTest("""
predicate isVehicle { "type": "minecraft:random_chance", "chance": 1.0 }
functionTag greeters { "values": [] }
lootTable "minecraft:entities/zombie" { "pools": [] }
mcfun speed() { /effect give @s speed; }
mcfun zombie() { /summon zombie; /kill @e[type=zombie,tag=speed,team=speed]; /say speed; }
mcfun main() {
    /execute if predicate isVehicle run say x;
    /execute if predicate is_vehicle run say x;
    if (predicate isVehicle) { /say x; }
    /function speed;
    /function #greeters;
    /kill @e[predicate=isVehicle];
    /loot give @s loot entities/zombie;
    /execute if predicate other run say x;
    /execute if predicate isMissing run say x;
    /data get storage speed x;
}""")
    discard compiler.compile()
    let errors = compiler.errors
    check errors.len == 7
    check errors[6].message == "'isMissing' cannot be an id, because an id has no capital letters. To name " &
                               "something in this pack, write 'self:isMissing'"
    check errors[0].message == "'isVehicle' is in this pack, but with no namespace it means 'minecraft:isVehicle'. " &
                               "Write 'self:isVehicle'"
    check errors[0].position.get.column == 27
    check errors[1].message == "'is_vehicle' is in this pack, but with no namespace it means " &
                               "'minecraft:is_vehicle'. Write 'self:isVehicle'"
    check errors[3].message == "'speed' is in this pack, but with no namespace it means 'minecraft:speed'. Write " &
                               "'self:speed'"
    check errors[4].message == "'greeters' is in this pack, but with no namespace it means 'minecraft:greeters'. " &
                               "Write 'self:greeters'"

  test "inserts compile-time and runtime values into commands":
    let compiler = compileForTest("""
var #hp = 0;
mcfun main() {
    var n = 2;
    /effect give @p poison {{n * 5}};
    /say {{#hp}} {{#hp * 2}} {{@s.$CustomName}} $(hp) {{#hp}};
}
mcfun bad() { /effect give @p poison {{"x"}}; }""")
    let program = compiler.compile()
    check compiler.errors.len == 1
    check compiler.errors[0].position.get.line == 7
    check compiler.errors[0].position.get.column == 38

    # The macro key `hp` has the name `hp`, so the score gets `hp_2`. The same score again uses it again.
    check program.render("main") == """
effect give @p poison 10
$data modify storage ns:poplar macro set value {hp:"$(hp)"}
execute store result storage ns:poplar macro.hp_2 int 1 run scoreboard players get #global ns.hp
scoreboard players operation #poplar.main.t0 poplar.ns = #global ns.hp
execute store result storage ns:poplar macro.value int 1 run scoreboard players operation #poplar.main.t0 poplar.ns *= #poplar.c2 poplar.ns
data modify storage ns:poplar macro.CustomName set from entity @s CustomName
function ns:poplar/main/macro_0 with storage ns:poplar macro
"""
    check program.render("poplar/main/macro_0") == "$say $(hp_2) $(value) $(CustomName) $(hp) $(hp_2)\n"

  test "a command uses a data variable and a macro key together":
    let compiler = compileForTest("""
var $item = "diamond";
mcfun give() { /give @s {{$item}} $(count); }""")
    let program = compiler.compile()
    check compiler.errors.len == 0
    check program.render("give") == """
$data modify storage ns:poplar macro set value {count:"$(count)"}
data modify storage ns:poplar macro.item set from storage ns:data item
function ns:poplar/give/macro_0 with storage ns:poplar macro
"""
    check program.render("poplar/give/macro_0") == "$give @s $(item) $(count)\n"
