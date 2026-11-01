# Poplar

Poplar is a programming language that compiles to Minecraft Java datapacks.

```poplar
import "std";

var #deaths = 0;

mcfun load() {
    onEvent("deathCount", playerDied);
}

mcfun playerDied() {
    #deaths = #deaths + 1;
    tellraw(@a, ["Deaths: ", text(#deaths)]);
}
```

## Repository
| Folder | What it is |
|---|---|
| `compiler/` | The compiler, the language server and the standard library (Zig 0.17.0) |
| `docs.md` | The user documentation |
| `editors/` | The Tree-sitter grammar (editor extensions are separate repos, such as `poplar-gram`, that fetch it from here) and a TextMate grammar |
| `examples/` | Example Poplar projects |

## Build
```sh
cd compiler
zig build test                                  # unit tests
zig build run -- build ../examples/hello        # compile a project
zig build -Doptimize=ReleaseSafe -p ~/.local    # install `poplar` and its std on the PATH
```

Then `poplar new myPack` makes a project, and `poplar build` writes the datapack to `poplar-out/`.

## Editor
`poplar lsp` is the language server. The Gram (Zed) extension is in the `poplar-gram` repo.

The grammar's generated parser (`editors/tree-sitter-poplar/src/`) is committed, because editors compile it and do not generate it. After a change to `grammar.js`, run `tree-sitter generate` in that folder.
