# TODO

## 1. Testing in the game
- [x] `zig build e2e`: start a headless Minecraft server, load a test datapack, run functions through the console, and check the chat output (`tools/e2e.zig`)
- [x] Check in the game (26.3): pack format 121, macro lines, `with storage`, `return run function`, `execute store result ... run function`, stack frames, `#global` holders, entity scores, `execute (...)`, `while`, `if`/`else`, the `load` hook
- [ ] Add a timeout to the harness, so that a server that hangs does not hang the run
- [ ] More e2e projects: `tick`, imports, `return` in nested `if`/`else`, mutual recursion

## 2. Small fixes
- [x] String escapes (`\"`, `\\`) in Poplar strings
- [x] `poplar.json`: zipName, namespace, description, minFormat, maxFormat, entry, zip
- [ ] Host `schema/poplar.schema.json` at a URL (or add it to SchemaStore), so projects outside this repo get editor checks
- [x] `poplar build` writes a zip with `pack.mcmeta` at the root
- [ ] Compress the zip (deflate). It is stored with no compression now
- [x] Optimizer passes on the IR: remove `*= 1`, `/= 1`, `+= 0`, and merge a computation into the copy of its temp (`src/Optimizer.zig`)
- [x] More optimizer passes: known values (fewer macro lines, math on known numbers), dead writes, `data get` scaling, `return $(n)` for a parameter
- [x] Optimizer: inline one-command generated functions, track `@s` scores, one-command `while` test

## 3. Language
- [x] `break` and `continue` in `while` (then `while (true)` with `break` is valid)
- [x] Types for `$` variables and mcfun parameters (`: int`, `list[T]`, `{field: T}`), inferred from the initial value
- [x] List and compound literals, with runtime parts; paths (`$stats.hp`); `append`, `prepend`, `insert`, `remove`, `len`; string and bool conditions
- [x] ~~`fun` that returns a compile-time value~~ (removed: `fun` hid build-time logic)
- [x] `return` inside `while` and `execute (...)`
- [x] `{{$x}}` inserts in `execute (...)` subcommands
- [x] `{{$x}}` and an mcfun parameter in the same command (through `<ns>:poplar macro`)
- [x] Any runtime value in `{{...}}`: scores, math, value calls, entity data
- [x] Entity NBT (`@s.$path`), reads and writes, and `as <type>` for the NBT type
- [x] Registry checks for commands (unknown effects, items, blocks) from mcmeta `registries/data.json`, with a suggestion

## 4. Larger projects
- [x] CLI with zli: `poplar new`, `init`, `build`, `check`, `watch`, `--version`
- [ ] CLI: `poplar install --world <path>` (build, then copy the pack into a world)
- [x] `import "std";`: the standard library in `std/`, installed next to the binary (`lib/poplar/std`), `POPLAR_STD` for development
- [x] Standard library v1: math (`abs`, `min`, `max`, `clamp`, `sign`, `pow`, `sqrt`, `random`), text (`tellraw`, `title`, `subtitle`, `actionBar` with `text(x)` parts), events (`onEvent(criteria, callback)`)
- [ ] More std: timers and cooldowns, ready-made events (`onJoin`, `onDeath`), raycast, list helpers, debug
- [x] LSP (`poplar lsp`, lsp-kit): diagnostics as you type, hover, go to definition, completion; Gram extension
- [x] User documentation in `docs.md` (a docs site can come later)
- [x] Local `#` and `$` variables in function bodies (block scope, `<var>_<mcfun>` names, saved on recursion)
- [ ] VS Code extension (it can reuse `editors/textmate/poplar.tmLanguage.json`)
- [x] String helpers: `slice`, `str`, `startsWith`, `endsWith`
- [ ] String concatenation (Minecraft has no native command; a macro line works for text without `"`)
- [x] `onTrigger(name, callback)`: `/trigger` commands without load or tick code
- [x] Strip back the language: remove `fun`, remove declared types, `if` on a data path is Minecraft's `if data`, std text functions are mcfuns
- [ ] LSP: completion and hover inside `/commands`, from the command tree
- [ ] LSP: columns for function and var definitions (they point to the start of the line now)
- [ ] Infer the NBT type of entity fields (`@s.$Health` is a float) from Spyglass vanilla-mcdoc (`api.spyglassmc.com/vanilla-mcdoc/symbols`), so `as` is optional there too
- [x] Positions (line and column) for expressions, not only statements
