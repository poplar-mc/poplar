import std/[options, strutils, unittest]
import ../src/command_tree

let tree = loadCommandTree()

proc failure(text: string): Option[Failure] = tree.checkText(text, []).failure

test "checks the options of a selector the way the game does":
  for text in ["execute as @e[type=zombie,tag=a,name=\"a b\",nbt={Tags:[\"x,y\"]},scores={a=1..},limit=1] run say x",
               "execute as @e[ type = !minecraft:zombie , type = !skeleton ] run say x",
               "execute as @e[type=#minecraft:undead,type=#self:mobs,predicate=self:lucky] run say x",
               "execute as @e[] run say x"]:
    check tree.checkText(text, ["self"]).failure.isNone

  let quoted = failure("execute as @e[type=\"minecraft:zombie\"] run say x").get
  check quoted.message == "selector option 'type' cannot have quotes: write type=minecraft:zombie"
  check quoted.at == 19
  check failure("execute as @e[tag=!\"a\"] run say x").get.message ==
    "selector option 'tag' cannot have quotes: write tag=a"
  check failure("execute as @e[type=!zombiee] run say x").get.message ==
    "unknown entity_type 'zombiee'. Did you mean 'zombie'?"
  check failure("kill @e[tagg=a]").get.message == "unknown selector option 'tagg'. Did you mean 'tag'?"
  check failure("kill @e[foo=1]").get.message == "unknown selector option 'foo'"

test "finds ids in id arguments and selectors, not in text":
  let text = "execute as @e[type=#self:undead] if predicate self:isSitting run say self:not_an_id"
  let checked = tree.checkText(text, ["self"])
  check checked.failure.isNone
  check checked.ids.len == 2
  for id in checked.ids:
    check text.continuesWith("self:undead", id.at) or text.continuesWith("self:isSitting", id.at)

  check tree.checkText("function other:Caps", ["self"]).failure.isSome
  check not tree.checkText("data get storage self:data x", ["self"]).ids[0].namesDeclaration

test "checks commands against the tree":
  for text in ["say hi there", "effect give @p poison 10", "tp @s ~ ~1 ~",
               "execute as @a[tag=a, limit=1] if score @s ns matches 1.. run say x",
               "summon zombie ~ ~1 ~ {Tags:[\"a b\"],Data:[I;1,2]}"]:
    check failure(text).isNone

  check failure("efect give @p poison").get.message == "expected a command, found 'efect'"
  let badNumber = failure("effect give @p poison abc").get
  check badNumber.message == "expected integer, found 'abc'"
  check badNumber.at == 22
  check failure("effect give @p minecraft:poision 10").get.message ==
    "unknown mob_effect 'poision'. Did you mean 'poison'?"
  check failure("give @s diamnod 2").get.message == "unknown item 'diamnod'. Did you mean 'diamond'?"
  check failure("setblock ~ ~ ~ stonee[lit=true]").get.message == "unknown block 'stonee'. Did you mean 'stone'?"
  for text in ["give @s mypack:wand", "clear @s #minecraft:logs", "give @s $(item)"]:
    check failure(text).isNone
