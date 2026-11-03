# Poplar

Poplar is a programming language that compiles to Minecraft Java datapacks (1.21.9 and newer).

```poplar
namespace demo;

import std;

var #deaths = 0;

mcfun load() {
    onEvent("deathCount", playerDied);
}

mcfun playerDied() {
    #deaths = #deaths + 1;
    std:tellraw(@a, ["Deaths: ", text(#deaths)]);
}
```

Every `mcfun` is a normal Minecraft function, so other datapacks can call it with `/function`. A variable is a scoreboard score (`#deaths`) or NBT data (`$item`). Any line that starts with `/` is a Minecraft command, checked when you build.

## Contents

- [Install](#install)
- [Your first pack](#your-first-pack)
- [Variables](#variables)
- [Scores](#scores)
- [Data](#data)
- [Entities](#entities)
- [Conditions](#conditions)
- [Loops and return](#loops-and-return)
- [Functions](#functions)
- [Commands](#commands)
- [Namespaces](#namespaces)
- [Events](#events)
- [Data files](#data-files)
- [Standard library](#standard-library)
- [Project](#project)
- [CLI](#cli)
- [Pack output](#pack-output)

## Install

Poplar is built from source with [Zig 0.17.0](https://ziglang.org/download/):

```sh
git clone <poplar repository> poplar
cd poplar/compiler
zig build -Doptimize=ReleaseSafe -p ~/.local
```

| Path | What it is |
|---|---|
| `~/.local/bin/poplar` | the compiler |
| `~/.local/lib/poplar/std/` | the [standard library](#standard-library) |

Make sure `~/.local/bin` is on your `PATH`, then run `poplar --version`. It prints the Poplar version and the Minecraft version the compiler targets.

The compiler looks for the standard library at `../lib/poplar/std` next to its binary. If you move the binary, set `POPLAR_STD` to the folder of the standard library.

**Editors.** `poplar lsp` is a language server: errors as you type, hover, go to definition and completion. For Gram and Zed, install the `poplar-gram` extension, which adds syntax highlighting and starts `poplar lsp` from your `PATH`.

## Your first pack

```sh
poplar new hello_pack
cd hello_pack
poplar build
```

`poplar new` makes this folder:

```
hello_pack/
├── poplar.json          the project config
├── poplar.schema.json   lets your editor check poplar.json
├── src/main.poplar      starts with `namespace hello_pack;`
└── .gitignore           ignores poplar-out/
```

`src/main.poplar` has one function:

```poplar
namespace hello_pack;

mcfun load() {
    /say Hello from hello_pack!;
}
```

`mcfun load` runs every time the pack loads. `poplar build` writes the datapack to `poplar-out/hello_pack/`, and the same pack as `poplar-out/hello_pack.zip` to share:

```
✓ Built hello_pack in 20 ms → poplar-out/hello_pack (1 function, zip)
```

Copy the folder (or the zip) into the `datapacks` folder of a world, open the world and run `/reload`.

While you work, let `poplar watch` build and copy the pack for you:

```sh
poplar watch --world ~/.minecraft/saves/"My World"
```

It builds every time you save a file and copies the pack into the world's `datapacks/` folder. Run `/reload` in the game to load the new build.

To skip `--world` each time, put the world in a `.env` file in the project folder. `poplar new` adds `.env` to `.gitignore`, because the path is yours:

```sh
# .env
POPLAR_WORLD="~/.minecraft/saves/My World"
```

## Variables

```poplar
namespace demo;

var #deaths = 0;          // a score
var $lastWinner = "Steve"; // NBT data in storage

mcfun load() {
    var rounds = 3;       // a constant
    /say Best of {{rounds}};
}
```

The sigil decides what a variable is:

| Form | What it is | Exists |
|---|---|---|
| `rounds` | a constant | only while the pack is built |
| `#deaths` | a [score](#scores) | in the game |
| `$lastWinner` | [NBT data](#data) in storage | in the game |

`var` declares a variable and `=` changes it. Every statement ends with `;`. `//` starts a comment. A name cannot be declared again in an inner block.

### Constants

A variable without a sigil is a constant: a number, a string, `true`, `false`, `null`, a list or a compound that the compiler knows. Use constants to build commands (`/say {{rounds}};`) and for [`for`](#for) loops. Math on constants runs in the compiler; `/` and `%` round down, the same as Minecraft.

A constant cannot hold a value from the game. `var copy = #deaths;` is an error. Use `var #copy = #deaths;` instead.

A string is written in double quotes. The only escapes are `\"` and `\\`.

A selector on its own, such as `@a` or `@e[type=zombie]`, is a constant string: `var everyone = @a;`.

### Global and local variables

A `#` or `$` variable declared at the top level of a file is **global**: every function sees the same value, and it keeps its value between calls and across `/reload`.

A `#` or `$` variable declared inside a function is **local**:

```poplar
namespace demo;

var #total = 0;

mcfun countdown() {
    var #i = 10;
    var $seen = [];
    while (#i > 0) {
        #i = #i - 1;
        append($seen, 1);
        #total = #total + #i;
    }
}
```

- It is visible from its declaration to the end of its block.
- Its value is set every time the declaration runs.
- It never holds a value from an earlier call. A data local is removed when the function ends (at the end of the body and at every `return`), so a copy from a path that does not exist this time leaves it empty. A score local needs no removal: every score write overwrites it, and a failed one writes 0.

  ```poplar
  mcfun show() {
      var $enchantments = @s.$SelectedItem.components."minecraft:enchantments";
      if ($enchantments) { /say enchanted; } else { /say plain; }
  }
  ```

  For an item without enchantments, the copy fails and `$enchantments` does not exist, so `show` says `plain`.
- Each function has its own locals, and a recursive call gets fresh ones.

In the game, a local is named `<name>_<function>`: `#i` above is the fake player `#i_countdown` in the objective `<namespace>`, and `$seen` is the key `seen_countdown` in `<namespace>:data`. A local only exists while its function runs, so to inspect one, print it from the function: `/say {{#i}};`.

## Scores

```poplar
namespace demo;

var #mana = 0;

mcfun regen() {
    if (@s.#mana < 100) {
        @s.#mana = @s.#mana + 5;
    }
}
```

A `#` variable is a scoreboard score: a 32-bit integer.

- A global `#mana` is its own `dummy` objective, `<namespace>.mana`. `poplar/load` adds it.
- `#mana` alone is the global value, held by the fake player `#global` (hidden from the sidebar).
- `@sel.#mana` is the value of an entity in the same objective: `@s.#mana`, `@p.#mana`, `@a.#mana`.
- A local is the fake player `#<name>_<function>` in the objective `<namespace>`.

Scores support `+ - * / %` and the comparisons `< <= > >= == !=`. The example above compiles to one command:

```mcfunction
execute if score @s demo.mana matches ..99 run scoreboard players add @s demo.mana 5
```

To **read** an entity score, the selector must name one entity: `@s`, `@p`, `@r`, `@n`, or a selector with `limit=1`. Writing to many entities at once (`@a.#mana = 0;`) is fine.

**Costs and caveats**

- **Integers only.** Math wraps on overflow. `/` and `%` round down.
- **One objective per global.** Each global `#` variable adds one objective to the world.
- **`/reload` keeps values.** A global's initial value is only set when `#global` has no value yet, so changing it in your code does not change an existing world. Entities get no initial value.
- **Reading an entity score needs one entity.**
- **A local costs one command per declaration** to set its value. It has no entity values: `@s.#i` is an error when `#i` is local.
- **A global that is only used on entities** (`@s.#mana`, never `#mana` alone) gets no initial value on `#global`, so it costs only its objective.

## Data

```poplar
namespace demo;

var $stats = {hp: 20, name: "Steve"};
var $names = [];
var #kills = 0;

mcfun win() {
    append($names, "Alex");
    $stats.hp = #kills * 2;
    if ($stats.name == "Steve") {
        /say Steve is still in the lead;
    }
}
```

A `$` variable is NBT. A global is a key in the storage `<namespace>:data`; a local is the key `<name>_<function>` there. NBT has no declared types in Poplar, the same as in the game: a variable holds whatever you put in it, and a list can hold values of different types.

### Values

| Write | Stored as |
|---|---|
| `20` | `20` (an int) |
| `20 as float` | `20f` |
| `true` / `false` | `true` / `false` (a byte, `1b` / `0b`) |
| `"Steve"` | `"Steve"` |
| `[1, "a"]` | `[1,"a"]` |
| `{hp: 20, "custom key": 1}` | `{hp:20,"custom key":1}` |

Number literals are integers. A global's initial value is set only if the key does not exist yet, so `/reload` keeps it.

### Assigning

`$x = ...` takes a constant, another `$` variable or entity data (copied as it is, with its NBT type), a score, or math. A score or math is stored as an `int`; write [`as`](#nbt-types-with-as) for another number type:

```poplar
$ratio = #kills * 2 as float;   // execute store result storage demo:data ratio float 1 run ...
$copy = @s.$SelectedItem;       // data modify storage demo:data copy set from entity @s SelectedItem
```

### Paths

Reach into a compound or a list with a path: `$stats.hp`, `$inventory[0].count`, `$names[-1]`, `$item.components."minecraft:custom_data"`. The root (`$stats`) must be declared; the rest of the path is not checked, the same as in commands.

A literal can contain game values. `$pos = [#x, #y, 0];` writes `[0,0,0]`, then stores `#x` and `#y` into `pos[0]` and `pos[1]`.

### List functions

| Function | Does |
|---|---|
| `append($list, value)` | adds `value` at the end |
| `prepend($list, value)` | adds `value` at the start |
| `insert($list, index, value)` | adds `value` at `index` |
| `remove($list, index)` | removes the value at `index` |
| `len(value)` | the number of elements of a list or compound, or the characters of a string |

`index` must be a constant integer. A score or math value is added as a `0` first, then stored into it.

### Strings

```poplar
namespace demo;

var $id = "";
var #kills = 0;

mcfun inspect() {
    $id = slice(@s.$SelectedItem.id, 10);         // "minecraft:diamond_sword" → "diamond_sword"
    var $label = str(#kills);                     // 5 → "5"
    if (endsWith(@s.$SelectedItem.id, "_sword")) {
        /say a sword;
    }
}
```

| Helper | Gives | Compiles to |
|---|---|---|
| `slice(text, start)`, `slice(text, start, end)` | the characters from `start` (included) to `end` (not included) | `data modify ... set string <text> <start> [<end>]` |
| `str(value)` | a number, score or math as text | `set string` from the number |
| `startsWith(text, "prefix")` | a condition | a substring of the text, then an NBT match |
| `endsWith(text, "suffix")` | a condition | the same, from the end |

`text` is a `$` path, entity data (`@s.$path`) or another string helper (`slice(str(#x), 1)`). `start` and `end` are constant integers; a negative one counts from the end, so `slice($id, -3)` is the last three characters. The prefix or suffix is a constant string. With only constants, the compiler does the work: `{{slice("minecraft:stone", 10)}}` writes `stone`.

`slice` and `str` give a string, so store them in data, pass them to a function or insert them with `{{...}}`. `startsWith` and `endsWith` are conditions for `if` and `while`.

### NBT types with `as`

The game reads some NBT fields as one type: an entity's `Health` is a float. `as` says which number type to store:

| `as` | Suffix |
|---|---|
| `byte` | `1b` |
| `short` | `1s` |
| `int` | `1` |
| `long` | `1L` |
| `float` | `1f` |
| `double` | `1d` |

`as` binds loosest: `#a + 1 as double` means `(#a + 1) as double`. It works on constants (`20 as float` is `20f`), on scores and math stored into NBT, and on [function arguments](#parameters). Anywhere else it is an error.

**Costs and caveats**

- **Paths are not checked.** A typo like `$stats.hpp` compiles and reads nothing in the game.
- **Math reads an `int`.** In math or a number comparison, `$x` is read with `data get`, which rounds a fraction down.
- **A literal with game values costs 1 + n commands:** one for the literal and one for each of the n game values.
- **A game value added to a list costs 2 commands.** A constant, or a copy from other data, is 1 command.
- **`remove` on a missing index does nothing** in the game.
- **A local is removed at each exit of its function:** one `data remove` per data local at the end of the body and at every `return`. A `return` whose value is a game value computes it into a temporary score first, because the value can read a local.
- **The list function names are reserved:** `append`, `prepend`, `insert`, `remove` and `len` cannot be function names, and neither can `slice`, `str`, `startsWith` and `endsWith`.
- **`slice` is one command.** `str` of a score or math is 2 (the number is stored first).
- **Each `startsWith` or `endsWith` runs 3 commands every time its condition is checked:** clear a scratch value, copy the start (or end) of the text into it, and compare it. Two of them in one condition cost 6; inside a `while`, the cost is per loop step.
- **A slice out of range fails,** the same as in Minecraft, and the target keeps its old value. `startsWith` and `endsWith` are false for a text shorter than the prefix.
- **Indices count UTF-16 units,** as in the game: a character outside the Basic Multilingual Plane, such as an emoji, counts as 2.
- **There is no concatenation.** Minecraft has no command that joins strings. Join them in a command with inserts: `/data modify storage demo:data name set value "{{$first}} {{$last}}";`.

## Entities

```poplar
namespace demo;

var #hp = 0;

mcfun check() {
    #hp = @s.$Health;
    if (@s.$Health < 10) {
        @s.$Glowing = true;
    }
}

mcfun heal() {
    @s.$Health = #hp + 4 as float;
}
```

A selector followed by `.#` or `.$` names a value of an entity:

| Form | Value |
|---|---|
| `@s.#mana` | the entity's score in the objective of `#mana` |
| `@s.$Health` | the entity's NBT at the path `Health` |

`@s.$Health` is `nbt(@s, "Health")` and `@s.#mana` is `score(@s, mana)`. Without a selector, `$item` is the pack's own storage and `#mana` is the global score.

- Reads work anywhere a value is expected. `@s.$Health * 10` is one command: `data get entity @s Health 10`.
- Writes use `data modify`: `@s.$Glowing = true;`. A copy from other NBT keeps its type: `$lastPos = @s.$Pos;`.
- Storing a score or math into entity data needs `as`, because the game reads each field as one type: `@s.$Health = #hp as float;`.
- Reads and writes need a selector for one entity (`@s`, `@p`, `@r`, `@n` or `limit=1`).

**Costs and caveats**

- **One entity per read or write.**
- **Players cannot be changed.** Minecraft refuses `data modify entity` on a player, and the compiler cannot check this.
- **The path is not checked.**
- **Scaled reads clamp.** `@s.$Health * 10` keeps the fraction until the end (`1.5 * 10` is `15`), and a value too large for an integer is clamped, not wrapped.

## Conditions

```poplar
if (#score > 10) {
    /say big;
} else if (#score > 5) {
    /say medium;
} else {
    /say small;
}
```

A condition works the same as `execute if` in Minecraft:

| Condition | Compiles to |
|---|---|
| `#a > 5`, `#a == #b` | `if score ...` |
| `@s.$SelectedItem.components.enchantments` | `if data entity @s SelectedItem.components.enchantments`: the path **exists** |
| `!$stats.bonus` | `unless data storage <ns>:data stats.bonus` |
| `@s.$OnGround == true` | `if data entity @s {OnGround:1b}` |
| `$name == "Steve"` | `if data storage <ns>:data {name:"Steve"}` |
| `$ratio == (5 as float)` | `if data storage <ns>:data {ratio:5f}` |
| `block ~ ~-1 ~ #minecraft:logs` | `if block ~ ~-1 ~ #minecraft:logs` |
| `items entity @s weapon.mainhand #self:swords` | `if items entity @s weapon.mainhand #<ns>:swords` |
| `!entity @s[type=#minecraft:undead]` | `unless entity @s[type=#minecraft:undead]` |
| `predicate self:isSitting` | `if predicate <ns>:is_sitting` |

Combine conditions with `and`, `or` and `!`. `as` binds loosest, so put it in brackets inside a comparison: `$ratio == (5 as float)`.

A condition that starts with an `execute if` subcommand is Minecraft text, the same as inside `execute (...)`: `biome`, `block`, `blocks`, `data`, `dimension`, `entity`, `function`, `items`, `loaded`, `predicate`, `score`, `slots` or `stopwatch`, followed by a space. The text ends at `and`, `or` or the closing `)`. It is checked against the command tree, `self:name` is an id in your pack ([ids in commands](#ids-in-commands)), and `{{...}}` inserts a constant or a parameter:

```poplar
namespace demo;

itemTag swords { "values": ["#minecraft:swords"] }

var #mana = 0;

mcfun tick() {
    if (block ~ ~-1 ~ #minecraft:logs and #mana > 5) {
        /say on a log;
    } else if (items entity @s weapon.mainhand #self:swords) {
        /say sword;
    }
}
```

```mcfunction
# tick
execute if block ~ ~-1 ~ #minecraft:logs if score #global demo.mana matches 6.. run return run say on a log
execute if items entity @s weapon.mainhand #demo:swords run return run say sword
```

A bare data path tests that the path exists, whatever its value. A bool always exists (`0b` or `1b`), so test it with `== true` or `== false`. Comparing data with a string, bool, list, compound or `as` number is an NBT match; comparing it with a plain number reads it into a score.

A condition with only constants is decided by the compiler, and only the branch that is taken is written.

A body with one command goes inline after `run`. A longer body becomes its own function, `poplar/<mcfun>/if_<n>`. Inside a runtime `if`, you cannot change a constant declared outside of it.

**Costs and caveats**

- **A body with more than one command is a function call.**
- **`else`, `else if` and `or` use one wrapper function.**
- **A Minecraft check is raw text.** Ids in your own namespace and tags are not checked, the same as in commands. A word `and` or `or` ends the text unless it is inside brackets or quotes.
- **`function` runs code.** `if (function #demo:checks)` runs every function in the tag to get the result.
- **No game values in a Minecraft check yet.** `{{#x}}` or `{{$x}}` in one is an error; use `execute (if ...) { }`.
- **`==` with data only works on key paths for now.** `$stats.name == "x"` works; `$list[0] == "x"` is an error. Two game values that are not numbers cannot be compared yet.

## Loops and return

### `while`

```poplar
while (#i > 0) {
    #i = #i - 1;
}
```

`while` runs in the game. Its condition must use a score or data value, or be `true`. `break` leaves the loop and `continue` starts the next step; `while (true)` must contain a `break` or a `return`.

Each loop becomes `poplar/<mcfun>/while_<n>`, which tests the condition, and `while_<n>_body`, which ends by running the test again.

### `for`

```poplar
for (0..3) |n| {
    /say step {{n}};
}
// say step 0
// say step 1
// say step 2
```

`for (a..b)` runs while the pack is built: the compiler writes the body once for each value from `a` up to, not including, `b`, and `n` is a constant. Use `while` for loops that depend on the game.

### `return`

`return value;` ends the `mcfun` and gives its caller a value; `return;` returns 0. If an `if` body contains a `return`, it must end with one, and if one branch of an `if`/`else` returns, every branch must. Code after `return`, `break` or `continue` in the same block is an error.

`return` also works inside `while` and `execute (...)`: the value is stored in a score and the body returns 1, so the call site can return too.

### `execute (...)`

```poplar
execute (as @e[type=zombie] at @s) {
    /say found;
    /particle flame ~ ~1 ~;
}
```

`execute (subcommands) { body }` runs the body with `execute <subcommands> run ...`. The subcommands are checked against the command tree and can contain `{{...}}` inserts. Nested executes are joined: `execute A run execute B run C` is written as `execute A B run C`. The compiler does not track `@s`: inside an `mcfun`, `@s` is whatever the caller ran it as.

**Costs and caveats**

- **`while` costs one function call per step.** Minecraft stops a run after `max_command_sequence_length` commands (65536 by default), so a very long or endless loop stops partway.
- **`break` is free; `continue` is one function call.**
- **`return` in a loop or `execute (...)` costs 2 commands** where it happens and one check at the call site (2 in an `mcfun` with parameters).
- **`return` in `execute (as @a)` returns for the first entity that returns.** It is an error in an `mcfun` with parameters and in an `execute` whose subcommands insert `{{$x}}`.
- **`for` copies its body** `b - a` times.

## Functions

```poplar
namespace demo;

var #hp = 0;

mcfun heal(amount) {
    #hp = #hp + amount;
}

mcfun double(x) {
    return x * 2;
}

mcfun load() {
    heal(5);
    #hp = double(#hp);
}
```

Every `mcfun` is one `.mcfunction` file. Minecraft function names cannot contain capital letters, so the file is the snake_case form of the name: `mcfun playerDied` is `player_died.mcfunction`, and you run it with `/function <namespace>:player_died`.

### `load` and `tick`

| In any namespace | Runs |
|---|---|
| `mcfun load()` | every time the pack loads, after Poplar sets up its scores and storage |
| `mcfun tick()` | every tick |

Each [namespace](#namespaces) can have its own. They run in import order: a namespace's `load` runs after the `load` of every namespace it imports. Neither can have parameters.

### Parameters

An `mcfun` with parameters is a [macro function](https://minecraft.wiki/w/Function_(Java_Edition)#Macros): each line that uses a parameter becomes a macro line with `$(amount)`. A parameter is a game value, so it cannot be a constant (`var x = amount;` is an error). Used in math or an `if`, it goes through a score, so it must be a number.

A call writes its arguments the way Minecraft passes macro arguments:

```poplar
heal(5);
// function demo:heal {amount:5}

heal(#hp * 2);
// execute store result storage demo:poplar args.amount int 1 run ...
// function demo:heal with storage demo:poplar args
```

With only constants and parameters, the arguments go into the call. With any game value, every argument is written to `<namespace>:poplar args` first; a score or math argument is an `int`, unless you write `as` (`heal(#hp as float)`).

A macro inserts a string argument **without quotes**, and a list or compound as SNBT. So `greet("Steve")` with `/say Hi {{name}};` writes `say Hi Steve`, and a text component should be a compound or a list: `tellraw(@a, {text: "hi"})`.

### Return values

A call can be used as a value: `#y = double(#y);` → `execute store result score ... run function demo:double ...`. Minecraft only returns integers.

### Recursion

An `mcfun` can call itself. A recursive call would overwrite the temporary scores and locals of the running call, so the compiler saves the ones that are still needed on a stack in storage around the call.

**Costs and caveats**

- **A function with parameters is a macro function.** Macro lines are slower than plain lines, because the game builds them again for new values.
- **Game-value arguments cost one command each.**
- **A `"` in an argument breaks forwarding.** Generated bodies receive the arguments as `{amount:"$(amount)"}`.
- **Recursion costs a frame per call:** `2 + 2n` commands to save and restore the `n` values that are still needed. Calls that are not recursive cost nothing extra.
- **Files are snake_case.**

## Commands

```poplar
namespace demo;

var #hp = 20;
var $item = "diamond";

mcfun load() {
    /give @s diamond 1;
    /say {{$item}} for you;
    /say hp is {{#hp}} and double is {{#hp * 2}};
}
```

A statement that starts with `/` is a Minecraft command, written to the file as you wrote it. It ends at the first `;` outside quotes and brackets, so `/tellraw @a {"text":"a;b"};` is fine.

The compiler checks every command against the command tree of the targeted version: literals, argument kinds, and vanilla ids of items, blocks, effects, entities and other registries.

```
src/main.poplar:2:21: unknown mob_effect 'poision'. Did you mean 'poison'?
```

Tags, `*`, `$(x)` and ids in other namespaces are not checked. There is no `say(...)` built-in; use `/say`.

### Ids in commands

```poplar
namespace demo;

predicate isSitting { "type": "minecraft:random_chance", "chance": 0.5 }
entityTypeTag undead { "values": ["minecraft:zombie", "minecraft:skeleton"] }

mcfun tick() {
    if (predicate self:isSitting) { /function self:healPlayer; }
    /execute as @e[type=#self:undead] run say grr;
}

mcfun healPlayer() {
    /effect give @s minecraft:instant_health;
}
```

```mcfunction
# tick, for the namespace demo
execute if predicate demo:is_sitting run function demo:heal_player
execute as @e[type=#demo:undead] run say grr
```

Minecraft needs a full id, `namespace:path`. In commands, `execute (...)` and conditions, refer to an `mcfun` or a [data file](#data-files) of your pack by its name in the source:

| You write | Means |
|---|---|
| `self:healPlayer` | `healPlayer` in this file's namespace: `demo:heal_player` |
| `magic:castSpell` | `castSpell` in the namespace `magic`, which the file imports: `magic:cast_spell` |
| `magic:cast_spell` | the real id, kept as it is |
| `std:clamp` | the standard library's `clamp`: `demo:std/clamp` (see [Standard library](#standard-library)) |
| `minecraft:stone`, `otherpack:thing` | not one of your namespaces: kept as it is |
| `self:boss` in `/bossbar add self:boss "Boss"` | an id that is not a function or data file (a storage, a bossbar): only the namespace is filled in, `demo:boss` |

The compiler writes the file name (`healPlayer` → `heal_player`), so the code does not change when a namespace is renamed. Only ids where Minecraft expects a function or a data file (`function`, `predicate`, `loot`, `item modify`, tags, selector values such as `type=`) are checked and converted; the command tree says which kind each argument is. A data file declared with a string is named by that string: `self:checks/rare` for `predicate "checks/rare"`. It works wherever Minecraft expects an id, with `#` for a tag, and in selector values such as `type=#self:undead`. Chat text and other text are not changed: `/say self:x` says `self:x`.

The compiler checks the name: `'self:isSiting' is not a data file or mcfun of namespace 'demo'. Did you mean 'isSitting'?`. `self:` only takes the name from the source: `'self:is_sitting' is a file name. Use the name from the source: 'self:isSitting'`.

**Costs and caveats**

- **No game cost.** The full id is written into the command.
- **Not in data file JSON.** A JSON body is written as it is, so ids there are written in full (`"#demo:handles"`).
- **The check does not look at the type.** `predicate self:healPlayer` passes the check because `healPlayer` is an mcfun; the game then finds no predicate with that name.
- **`self` is only for commands.** In Poplar code a plain name already means this namespace: write `healPlayer()`, not `self:healPlayer()`.

### Inserts with `{{...}}`

| Insert | Written as |
|---|---|
| a constant, `{{i}}` | its text: `say step 3`. A string has no quotes, a list or compound is SNBT |
| a parameter, `{{amount}}` | `$(amount)` in a macro line |
| a `$` variable, `{{$item}}` | a macro line that reads `<namespace>:data` |
| a score, math or entity data: `{{#hp}}`, `{{#hp * 2}}`, `{{@s.$CustomName}}` | a macro line, with the value copied in first |

A line with a game value moves into a helper function, `poplar/<mcfun>/macro_<n>`. Values other than whole `$` variables are copied into `<namespace>:poplar macro` first, named after their source: `$stats.hp` is `$(stats_hp)`, `#hp` is `$(hp)`, math is `$(value)`.

**Costs and caveats**

- **Checked for one version.** The ids come from the Minecraft version the compiler was built with.
- **A game-value insert adds a helper function call,** and macro lines are slower than plain lines.
- **Only whole `$` variables are free.** Every other game value costs one command to copy.
- **Scores and math are inserted as integers.**

## Namespaces

```poplar
// src/combat.poplar
namespace combat;

import magic;

var #mana = 0;

mcfun tick() {
    magic:heal();
    #magic:mana = #mana;
    /execute as @a run function magic:castSpell;
}
```

```poplar
// src/spells/magic.poplar
namespace magic;

var #mana = 0;

mcfun heal() {
    #mana = #mana + 1;
}

mcfun castSpell() {
    /say whoosh;
}
```

Every file starts with `namespace <name>;`. Every `.poplar` file in `src/` is part of the pack, wherever it is: folders are only for you. Files with the same namespace share their names. A plain name (`heal()`, `#mana`, `$item`) is in the file's namespace. A name in another namespace is written `magic:heal()`, `#magic:mana`, `$magic:item`, `@s.#magic:mana`, and the file must `import magic;` first.

Two namespaces can use the same names, because each one has its own files and state:

| In `namespace combat;` | Written as |
|---|---|
| `mcfun heal` | `data/combat/function/heal.mcfunction`, `combat:heal` |
| its helpers, temps and locals | `combat:poplar/heal/...`, the objective `combat` |
| `var #mana` | the objective `combat.mana` |
| `var $item` | the key `item` in the storage `combat:data` |
| `predicate isSitting` | `data/combat/predicate/is_sitting.json` |

Poplar's own functions (`poplar/load`, `poplar/tick`, the event checks) and the [standard library](#standard-library) go into the pack namespace, `"namespace"` in `poplar.json`. Use that name in a file to share it.

Each namespace can have [`load` and `tick`](#load-and-tick). They run in import order: if `combat` imports `magic`, `magic:load` runs first, so its state is ready. Namespaces that import each other run in alphabetical order.

A namespace name uses `a-z`, `0-9`, `_` and `.` (`bs.math`). Minecraft also allows `-`, but in Poplar code `-` is the minus sign.

**Costs and caveats**

- **No game cost.** A namespace only decides where files and scores go.
- **Each namespace adds one objective** for its temps and locals, set up in `poplar/load`.
- **A renamed namespace has new scores and storage.** A world keeps the old values under the old name.
- **`namespace minecraft;` writes into vanilla's namespace.** It can replace vanilla functions and data; Minecraft's own `load` and `tick` tags are Poplar's, so they cannot be written that way.

## Events

```poplar
namespace demo;

import std;

var #deaths = 0;

mcfun load() {
    onEvent("deathCount", playerDied);
    onEvent("minecraft.used:minecraft.snowball", threwSnowball);
}

mcfun playerDied() {
    #deaths = #deaths + 1;
}

mcfun threwSnowball() {
    std:tellraw(@s, {text: "Nice throw"});
}
```

`onEvent(criteria, callback)` runs the `mcfun` `callback` as a player, at the player, each time the [scoreboard criteria](https://minecraft.wiki/w/Scoreboard#Criteria) counts for that player. Call it in `mcfun load()` of any namespace, outside any runtime `if`, `while` or `execute`. The callback cannot have parameters.

Each event gets an objective, `<namespace>.event_<n>`, and `poplar/tick` checks it every tick:

```mcfunction
execute as @a[scores={demo.event_0=1..}] at @s run function demo:poplar/event_0
```

`poplar/event_<n>` resets the player's score and runs the callback. If you define `mcfun tick()`, `poplar/tick` runs it after the event checks.

**Costs and caveats**

- **One check per event every tick,** over all players.
- **The score is reset on each run.** A counting criteria (`deathCount`, `minecraft.used:...`) fires once per occurrence; a value criteria (`health`, `food`) fires every tick while it is above 0.
- **Only in `load`.**
- **The criteria is not checked.** A wrong one makes `scoreboard objectives add` fail in the game.

### Triggers

```poplar
namespace demo;

mcfun load() {
    onTrigger("showoff", show);
}

mcfun show() {
    /say I am showing off;
}
```

`/trigger <objective>` is the command that every player can use, so datapacks use it for their own commands. `onTrigger(name, callback)` sets one up: when a player runs `/trigger showoff`, the `mcfun` `show` runs as that player, at the player. The rules are the same as for `onEvent`.

`poplar/load` adds the objective `showoff` with the criteria `trigger`. The name is used as it is, without the namespace, because players type it. `poplar/tick` runs the callback for each player with a score, and then enables the trigger again for all players, because Minecraft disables a trigger after each use:

```mcfunction
# poplar/tick
execute as @a[scores={showoff=1..}] at @s run function demo:poplar/event_0
scoreboard players enable @a showoff

# poplar/event_0
scoreboard players reset @s showoff
function demo:show
```

**Costs and caveats**

- **Two commands every tick per trigger:** the check and the `enable`.
- **The name has no namespace.** Two packs that use the same trigger name share it. The name can only have letters, 0-9, `_`, `-`, `.` and `+`.
- **Any value counts once.** `/trigger showoff set 5` runs the callback once, like `/trigger showoff`. The callback cannot read the value, because the score is reset first.

## Data files

```poplar
namespace demo;

predicate lucky { "type": "minecraft:random_chance", "chance": 0.25 }

itemTag handles { "values": ["minecraft:stick", "minecraft:blaze_rod"] }

lootTable "minecraft:entities/zombie" {
  "type": "minecraft:entity",
  "pools": [{ "rolls": 1, "entries": [{ "type": "minecraft:item", "name": "minecraft:diamond" }] }]
}

mcfun tick() {
    if (predicate self:lucky) { /say lucky; }
}
```

Recipes, predicates, loot tables, advancements, tags and worldgen are JSON files in the pack. A data file declaration puts one there: the type word picks the folder, the name picks the file, and the body is the JSON: an object, or a list for the few types that are one (`blockTransformer`). The body is written as it is, so output from a generator such as [misode](https://misode.github.io) pastes in without changes. Floats, `null` and JSON escapes all work.

The example writes:

```
data/demo/predicate/lucky.json
data/demo/tags/item/handles.json
data/minecraft/loot_table/entities/zombie.json
```

The name is an identifier or a string:

| Name | File | Id |
|---|---|---|
| `lucky` | `data/demo/predicate/lucky.json` (snake_case, like an `mcfun`) | `demo:lucky`, or `self:lucky` in commands |
| `"checks/rare"` | `data/demo/predicate/checks/rare.json` | none; type `demo:checks/rare` |
| `"minecraft:entities/zombie"` | `data/minecraft/loot_table/entities/zombie.json` | none; it replaces the vanilla file |

In commands and conditions, refer to a data file by its name: `if (predicate self:lucky)` ([ids in commands](#ids-in-commands)). An identifier name is also a constant that holds the full id, for `{{...}}`. Inside JSON, write ids out (`"#demo:handles"`, `"demo:first_trident"` for an `mcfun firstTrident`).

The type word is the folder name in camelCase. Worldgen types drop `worldgen/`, and a tag is the registry name followed by `Tag`:

| Type words | Folder |
|---|---|
| `advancement`, `recipe`, `predicate`, `lootTable`, `itemModifier`, `enchantment`, `damageType`, `dialog`, `jukeboxSong`, `trimMaterial`, ... | the same name in snake_case: `loot_table`, `item_modifier`, ... |
| `biome`, `feature`, `placedFeature`, `noiseSettings`, `densityFunction`, `structure`, `templatePool`, ... | `worldgen/<name>` |
| `itemTag`, `blockTag`, `entityTypeTag`, `functionTag`, `biomeTag`, ... | `tags/item`, `tags/block`, `tags/entity_type`, `tags/function`, `tags/worldgen/biome` |

The type words are only special at the top level of a file, so you can still use `recipe` as a name inside an `mcfun`. A wrong word is an error with a suggestion: `unknown data file type 'recpie'. Did you mean 'recipe'?`.

**Costs and caveats**

- **No game cost.** A data file runs no commands.
- **Only the JSON syntax is checked.** The game checks the contents on `/reload` and skips a file it cannot read, with an error in the log. Generators produce JSON for one game version, so pick the version your pack targets.
- **No comments or inserts in the body.** It is plain JSON, so `//` and `{{...}}` are not read as Poplar.
- **A string id can replace a vanilla file,** such as a loot table. A tag adds to the vanilla tag unless it has `"replace": true`.
- **The `minecraft:load` and `minecraft:tick` function tags are Poplar's.** Use `mcfun load` and `mcfun tick` instead.

## Standard library

`import std;` loads the standard library, the namespace `std`: call its functions as `std:clamp(...)`. It is written in Poplar and installed next to the compiler (`lib/poplar/std/`), so you can read it. Only the functions your code can reach are written into the pack, as a copy in the pack namespace: `std:clamp` is the function `<pack namespace>:std/clamp`. Two packs built with different Poplar versions each have their own copy, so they cannot overwrite each other. A `std:name` in a command, such as `/function std:clamp {x:5,low:0,high:3};`, counts as a use too.

### Math

All math functions work on integers.

| Function | Returns |
|---|---|
| `abs(x)` | `x` without its sign |
| `sign(x)` | `1`, `-1` or `0` |
| `min(a, b)`, `max(a, b)` | the smaller or the larger of `a` and `b` |
| `clamp(x, low, high)` | `x`, moved into `low..high` (both included) |
| `pow(base, exponent)` | `base` to the power of `exponent`; a negative exponent gives `1` |
| `sqrt(x)` | the integer square root, rounded down; a negative `x` gives `0` |
| `random(low, high)` | a random integer in `low..high`, both included; if `high <= low`, `low` |

### Text

| Function | Shows `message` |
|---|---|
| `tellraw(target, message)` | in the chat of `target` |
| `title(target, message)` | as a large title |
| `subtitle(target, message)` | below the title (only together with a title) |
| `actionBar(target, message)` | above the hotbar |

`message` is a text component: a compound (`{text: "Hi", color: "gold"}`) or a list of parts (`["HP: ", text(#hp)]`). A plain string is inserted without quotes, as in any macro, so write `{text: "hi"}` rather than `"hi"`.

`text(value)` makes a text part that names a score or data. It is known when the pack is built, and the game reads the value when it shows the text:

| Call | Text component |
|---|---|
| `text(#hp)` | `{score:{name:"#global",objective:"<namespace>.hp"}}` |
| `text($name)` | `{storage:"<namespace>:data",nbt:"name"}` |
| `text(@s.$SelectedItem.id)` | `{entity:"@s",nbt:"SelectedItem.id"}` |

A game value cannot be passed as the message directly; wrap it in `text()`: `tellraw(@s, text($heldItem))`.

**Costs and caveats**

- **Every std function is a real function call.** The text functions are macro functions: one call plus one macro line per message. The math functions cost one extra command per game-value argument; `pow` makes one call per step of the exponent and `sqrt` about 16.
- **Its names are your project's names.** You cannot define your own `clamp` while you import `std`.
- **It comes with the compiler.** Rebuild your pack after an update.

## Project

```
my_pack/
├── poplar.json          the project config (optional)
├── src/
│   └── **/*.poplar      every source file, each starting with `namespace <name>;`
└── poplar-out/
    ├── <zipName>/       the datapack
    └── <zipName>.zip    the same datapack as a zip
```

Every build deletes and rewrites `poplar-out/`. Every field of `poplar.json` is optional:

| Field | Default | Description |
|---|---|---|
| `zipName` | the folder name | the name of the pack folder and the zip; no `/` or `\` |
| `namespace` | the folder name | the pack namespace, for Poplar's own files and the standard library: `a-z 0-9 _ . -` |
| `description` | `zipName` | the pack description, any JSON text component |
| `minFormat` | the targeted version | the lowest pack format: a number or `[major, minor]`, at least `88` (1.21.9) |
| `maxFormat` | `minFormat` | the highest pack format |
| `$schema` | | ignored by the compiler; lets editors check the file |

**Costs and caveats**

- **Minecraft 1.21.9 or newer** (pack format 88 or higher).

## CLI

| Command | Does |
|---|---|
| `poplar new <name>` | makes a project folder; the namespace is the lowercase name |
| `poplar init` | the same, in the current folder |
| `poplar build [dir]` | compiles into `poplar-out/` |
| `poplar check [dir]` | prints the errors, writes nothing |
| `poplar watch [dir] [--world <world>]` | builds again on every change; with a world, copies each build into the world's `datapacks/` |
| `poplar lsp` | the language server, over stdin and stdout |
| `poplar --version` | the Poplar and Minecraft versions |

`new` and `init` never overwrite a file. A failing command lists its errors, one per line, and exits with code 1:

```
✗ src/main.poplar:2:21  unknown mob_effect 'poision'. Did you mean 'poison'?
✗ 1 error, nothing was written
```

The output has colors in a terminal; set `NO_COLOR` to turn them off. Errors go to stderr.

`watch` takes the world from `--world`, else from the `POPLAR_WORLD` environment variable, else from `POPLAR_WORLD` in the project's `.env`. The first copy line names the source when it is not `--world`. With no world, `watch` still builds, but it prints a warning and copies nothing. A `.env` has `KEY=VALUE` lines, `#` comments, an optional `export ` and optional quotes; there is no variable expansion. A leading `~/` in `POPLAR_WORLD` is your home folder. The world must be a folder with `level.dat`. `watch` only replaces a pack folder that it copied itself (it contains a `.poplar-watch` file), so your own folders are left alone.

**Costs and caveats**

- **`poplar watch` polls** the files every 300 ms.
- **The language server compiles the whole project on each change.**
- **Go to definition jumps to the start of the line.**

## Pack output

For the pack namespace `demo` and a second namespace `combat`:

```
poplar-out/<zipName>/
├── pack.mcmeta
└── data/
    ├── minecraft/tags/function/   load.json, tick.json
    ├── combat/
    │   ├── function/              combat's mcfuns, and poplar/<mcfun>/ helpers
    │   └── <folder>/              combat's data files, such as predicate/lucky.json
    └── demo/function/
        ├── <name>.mcfunction      one per mcfun, in snake_case
        ├── std/                   the standard library functions that the pack uses
        └── poplar/
            ├── load.mcfunction    sets up scores and storage, then runs each namespace's load
            ├── tick.mcfunction    event checks, then each tick (only with events)
            ├── event_<n>.mcfunction
            └── <mcfun>/           if_<n>, while_<n>, execute_<n>, macro_<n>
```

| Name | Use |
|---|---|
| objective `combat.<name>` | one per global `#` variable of `combat` |
| objective `combat` | `combat`'s locals (`#<name>_<mcfun>`) and temporary scores |
| objective `demo` | the pack namespace's locals and temps, and the constants |
| objective `<ns>.event_<n>` | one per `onEvent`, in the namespace that registers it |
| storage `combat:data` | `combat`'s `$` variables, globals and locals |
| storage `demo:poplar` | `args`, `macro` and the recursion `stack` |

The optimizer computes math on known values, removes writes that nothing reads, folds `data get` and a multiplication into one scaled `data get`, writes results straight into their destination, puts one-command generated functions where they are called (and a helper that is the last command of its function, such as the `if`/`else` wrapper), and removes unused constants.

**Costs and caveats**

- **The output is not a line-by-line copy of your code.** The result in the game is the same.
