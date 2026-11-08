## The data file types: the word in `predicate isSneaking { ... }` → the folder in `data/<ns>/`. The
## data folders of mcmeta 26.3, in camelCase, without `worldgen/`. `item_modifier` is not in mcmeta,
## because vanilla has none. Tags (`itemTag`) are found from the registries.

import std/[options, strutils, tables]

const folders* = {
  "advancement": "advancement",
  "bannerPattern": "banner_pattern",
  "blockTransformer": "block_transformer",
  "catSoundVariant": "cat_sound_variant",
  "catVariant": "cat_variant",
  "chatType": "chat_type",
  "chickenSoundVariant": "chicken_sound_variant",
  "chickenVariant": "chicken_variant",
  "contextFloatProvider": "context_float_provider",
  "contextIntProvider": "context_int_provider",
  "cowSoundVariant": "cow_sound_variant",
  "cowVariant": "cow_variant",
  "damageType": "damage_type",
  "decoratedPotPattern": "decorated_pot_pattern",
  "dialog": "dialog",
  "dimension": "dimension",
  "dimensionType": "dimension_type",
  "enchantment": "enchantment",
  "enchantmentProvider": "enchantment_provider",
  "frogVariant": "frog_variant",
  "instrument": "instrument",
  "itemModifier": "item_modifier",
  "jukeboxSong": "jukebox_song",
  "lootTable": "loot_table",
  "paintingVariant": "painting_variant",
  "pigSoundVariant": "pig_sound_variant",
  "pigVariant": "pig_variant",
  "predicate": "predicate",
  "recipe": "recipe",
  "sulfurCubeArchetype": "sulfur_cube_archetype",
  "testEnvironment": "test_environment",
  "testInstance": "test_instance",
  "timeline": "timeline",
  "tradeSet": "trade_set",
  "trialSpawner": "trial_spawner",
  "trimMaterial": "trim_material",
  "trimPattern": "trim_pattern",
  "villagerTrade": "villager_trade",
  "wolfSoundVariant": "wolf_sound_variant",
  "wolfVariant": "wolf_variant",
  "worldClock": "world_clock",
  "zombieNautilusVariant": "zombie_nautilus_variant",
  "biome": "worldgen/biome",
  "blockStateProvider": "worldgen/block_state_provider",
  "carver": "worldgen/carver",
  "densityFunction": "worldgen/density_function",
  "feature": "worldgen/feature",
  "flatLevelGeneratorPreset": "worldgen/flat_level_generator_preset",
  "materialCondition": "worldgen/material_condition",
  "materialRule": "worldgen/material_rule",
  "multiNoiseBiomeSourceParameterList": "worldgen/multi_noise_biome_source_parameter_list",
  "noise": "worldgen/noise",
  "noiseSettings": "worldgen/noise_settings",
  "placedFeature": "worldgen/placed_feature",
  "processorList": "worldgen/processor_list",
  "structure": "worldgen/structure",
  "structureSet": "worldgen/structure_set",
  "templatePool": "worldgen/template_pool",
  "worldPreset": "worldgen/world_preset",
}.toOrderedTable

func snakeCase(word: string): string =
  for ch in word:
    if ch.isUpperAscii:
      result.add '_'
      result.add ch.toLowerAscii
    else:
      result.add ch

func tagFolder*(word: string, registries: OrderedTable[string, seq[string]]): Option[string] =
  ## `itemTag` → `tags/item`, `biomeTag` → `tags/worldgen/biome`, `functionTag` → `tags/function`. A
  ## registry in `worldgen/` comes first, so `structureTag` is the worldgen structure.
  if not word.endsWith("Tag") or word.len == "Tag".len: return none(string)
  let registry = snakeCase(word[0 ..< word.len - "Tag".len])
  if registry == "function": return some("tags/function")
  let worldgen = "worldgen/" & registry
  if worldgen in registries: return some("tags/" & worldgen)
  if registry in registries: return some("tags/" & registry)
  none(string)
