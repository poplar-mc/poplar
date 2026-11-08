#!/bin/sh
# Copies the Minecraft data that the compiler embeds from misode/mcmeta, at the summary tag of a version.
#   tools/update_mcmeta.sh 26.3
set -eu

version="$1"
commit="$(git ls-remote https://github.com/misode/mcmeta "refs/tags/$version-summary" | cut -f1)"
if [ -z "$commit" ]; then
    echo "misode/mcmeta has no tag $version-summary" >&2
    exit 1
fi

base="https://raw.githubusercontent.com/misode/mcmeta/$commit"
cd "$(dirname "$0")/../mcmeta"
curl -fsSL "$base/commands/data.json" -o commands.json
curl -fsSL "$base/registries/data.min.json" -o registries.json
curl -fsSL "$base/version.json" -o version.json
printf 'misode/mcmeta %s-summary %s\n' "$version" "$commit" > source.txt
echo "mcmeta $version-summary at $commit"
