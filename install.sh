#!/bin/sh
# Installs the latest Poplar release: `bin/poplar` and `lib/poplar/std` in $POPLAR_PREFIX (default: ~/.local).
#   curl -fsSL https://raw.githubusercontent.com/poplar-mc/poplar/main/install.sh | sh
set -eu

prefix="${POPLAR_PREFIX:-$HOME/.local}"
release_url="${POPLAR_RELEASE_URL:-https://github.com/poplar-mc/poplar/releases/latest/download}"

case "$(uname -s)" in
    Linux) os=linux ;;
    Darwin) os=macos ;;
    *) echo "Unsupported system: $(uname -s). On Windows, use install.ps1." >&2; exit 1 ;;
esac
case "$(uname -m)" in
    x86_64 | amd64) arch=x86_64 ;;
    arm64 | aarch64) arch=aarch64 ;;
    *) echo "Unsupported CPU: $(uname -m)." >&2; exit 1 ;;
esac

archive="poplar-$os-$arch.tar.gz"
temp="$(mktemp -d)"
trap 'rm -rf "$temp"' EXIT

echo "Downloading $archive"
curl -fsSL "$release_url/$archive" -o "$temp/$archive"
tar -xzf "$temp/$archive" -C "$temp"

mkdir -p "$prefix/bin" "$prefix/lib/poplar"
rm -rf "$prefix/lib/poplar/std"
# A rename replaces the file in one step, so this also works while `poplar lsp` or `poplar watch` runs the old one.
cp "$temp/bin/poplar" "$prefix/bin/.poplar.new"
mv -f "$prefix/bin/.poplar.new" "$prefix/bin/poplar"
cp -R "$temp/lib/poplar/std" "$prefix/lib/poplar/std"

echo "Installed $("$prefix/bin/poplar" --version) in $prefix"
case ":$PATH:" in
    *":$prefix/bin:"*) ;;
    *) echo "Add $prefix/bin to your PATH, for example: export PATH=\"$prefix/bin:\$PATH\"" ;;
esac
