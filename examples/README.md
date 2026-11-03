# Examples

Each folder is a complete Poplar project. Build one with `poplar build examples/<name>`, or try it in a world with `poplar watch examples/<name> --world <world folder>`.

| Example | What it shows |
|---|---|
| [hello](hello) | The smallest pack: `mcfun load`, constants, `{{...}}` inserts and `for` |
| [mana](mana) | Per-player scores, `tick` with `execute (as @a)`, `onTrigger`, `actionBar` and `text()` |
| [showoff](showoff) | `/trigger showoff`: NBT data, `if` on a data path, `slice`, and a `$` compound passed `with` to a macro function |
| [deaths](deaths) | `onEvent("deathCount", ...)`, entity and global scores, std `random` and `max`, `title` and `subtitle` |
| [crafting](crafting) | Data files: a recipe that uses an item tag, a vanilla loot table override, a predicate and an advancement reward |
| [toolkit](toolkit) | Several files in one namespace, recursion, `while` with locals, and the string helpers |
