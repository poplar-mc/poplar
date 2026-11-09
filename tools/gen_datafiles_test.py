#!/usr/bin/env python3
"""Writes tests/e2e/datafiles/src/main.poplar: one data file of each type, from the smallest vanilla file.

    python3 tools/gen_datafiles_test.py <mcmeta checkout>            the test
    python3 tools/gen_datafiles_test.py <mcmeta checkout> --missing  every tag also names a missing file

Run it at the top of the repo after a Minecraft update. With --missing the server must fail to start, with an error for every
type; a type without an error is in the wrong folder. The server stops at the first stage that fails, so a few types
that load later only show up once the earlier ones are fixed.
"""

import json
import re
import sys
from pathlib import Path

mcmeta = Path(sys.argv[1])
missing = "--missing" in sys.argv
compiler = Path(__file__).resolve().parent.parent

pairs = re.findall(r'"(\w+)": "([\w/]+)",', (compiler / "src/data_folders.nim").read_text())
# Vanilla has no item modifier. A special recipe such as repair_item is one object in the game, so a copy is an error.
own = {
    "predicate": {"type": "minecraft:random_chance", "chance": 1.0},
    "itemModifier": {"type": "minecraft:set_count", "count": 5},
    "recipe": {"type": "minecraft:crafting_shapeless", "ingredients": ["minecraft:dirt"], "result": {"id": "minecraft:diamond"}},
}
# Built-in registries cannot get new entries, so their tags name a vanilla one.
builtin_tags = {"item": "stone", "block": "stone", "entityType": "pig", "fluid": "water", "gameEvent": "step",
                "mobEffect": "speed", "potion": "water", "pointOfInterestType": "home"}


def tag_values(first):
    return {"values": [first] + (["datafiles:missing"] if missing else [])}


out = [
    "// One data file of each type. Each tag names the sample of its type, so the server fails to start",
    "// when a sample is missing or in the wrong folder. Each sample is the smallest vanilla file of its type.",
    "// Written by tools/gen_datafiles_test.py.",
    "namespace datafiles",
    "",
]
for word, folder in pairs:
    if word in own:
        body = own[word]
    else:
        data = json.loads((mcmeta / "data" / folder / "data.min.json").read_text())
        shaped = {key: value for key, value in data.items() if isinstance(value, (dict, list))}
        body = shaped[min(shaped, key=lambda key: len(json.dumps(shaped[key])))]
    out.append(f'{word} "sample" {json.dumps(body)}')
    if word != "itemModifier":
        out.append(f'{word}Tag "all" {json.dumps(tag_values("datafiles:sample"))}')
    out.append("")
for word, id in builtin_tags.items():
    out.append(f'{word}Tag "all" {json.dumps(tag_values(f"minecraft:{id}"))}')
out.append('''
predicate alwaysTrue { "type": "minecraft:random_chance", "chance": 1.0 }

functionTag runAll { "values": ["datafiles:tagged"] }

mcfun test:
    if predicate self:alwaysTrue and predicate datafiles:sample: /say predicate
    /execute in datafiles:sample run say dimension
    /function #self:runAll
    /forceload add 0 0
    /setblock 0 -60 0 minecraft:chest
    /item replace block 0 -60 0 container.0 with minecraft:stone
    /item modify block 0 -60 0 container.0 datafiles:sample
    /execute if data block 0 -60 0 Items[{count:5}] run say item modifier
    /setblock 0 -60 0 minecraft:air

mcfun tagged:
    /say function tag''')
(compiler / "tests/e2e/datafiles/src/main.poplar").write_text("\n".join(out) + "\n")
