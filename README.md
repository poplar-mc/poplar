<img src="poplar-logo.svg" alt="Poplar logo" width="128">

# Poplar

Poplar is a programming language that compiles to Minecraft Java datapacks.

```poplar
namespace deaths;

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

## Install

Linux and macOS:

```sh
curl -fsSL https://raw.githubusercontent.com/poplar-mc/poplar/main/install.sh | sh
```

Windows (PowerShell):

```powershell
irm https://raw.githubusercontent.com/poplar-mc/poplar/main/install.ps1 | iex
```

The scripts download the latest [release](https://github.com/poplar-mc/poplar/releases) for your platform and install `poplar` with its standard library: in `~/.local` on Linux and macOS, and in `%LOCALAPPDATA%\Programs\poplar` on Windows. Set `POPLAR_PREFIX` to install somewhere else. Read [install.sh](install.sh) or [install.ps1](install.ps1) before you run them, if you like.

Then `poplar new my_pack` makes a project, and `poplar build` writes the datapack to `poplar-out/`. Later, `poplar update` installs a newer release. See [docs.md](docs.md) for the language.

## Repository
| Folder | What it is |
|---|---|
| `compiler/` | The compiler, the language server and the standard library (Zig 0.17.0) |
| `install.sh`, `install.ps1` | The install scripts |
| `.github/workflows/release.yml` | Builds the release archives when a release is published |
| `docs.md` | The user documentation |
| `editors/` | The Tree-sitter grammar (editor extensions are separate repos, such as `poplar-gram`, that fetch it from here) and a TextMate grammar |
| `examples/` | Example Poplar projects |

## Build from source
```sh
cd compiler
zig build test                                  # unit tests
zig build run -- build ../examples/hello        # compile a project
zig build -Doptimize=ReleaseSafe -p ~/.local    # install `poplar` and its std on the PATH
```

## Releases
Publish a release on GitHub with a tag such as `v0.1.0`. The release workflow then builds Poplar for Linux, macOS and Windows (x86_64 and arm64) and attaches `poplar-<os>-<arch>.tar.gz` (or `.zip` on Windows) to it. The install scripts always take the latest release. Set the version in `compiler/build.zig.zon` to match the tag, because `poplar --version` prints it.

## Editor
`poplar lsp` is the language server. The Gram (Zed) extension is in the `poplar-gram` repo.

The grammar's generated parser (`editors/tree-sitter-poplar/src/`) is committed, because editors compile it and do not generate it. After a change to `grammar.js`, run `tree-sitter generate` in that folder.

## License

Poplar is [MIT](LICENSE) licensed. The standard library (`compiler/std/`) is [MIT-0](compiler/std/LICENSE), so the packs you build with it need no license notice.

## AI disclosure

The language design and the engineering decisions in Poplar are made by Jordan Baron. The code, tests and documentation are written by Claude, an AI model by Anthropic, following those decisions. Every change is built and tested before it is committed: unit tests, and end-to-end tests that run the packs on a real Minecraft server.
