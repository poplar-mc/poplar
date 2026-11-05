// The data file types: the word in `predicate isSneaking { ... }` → the folder in `data/<ns>/`.
// The data folders of mcmeta 26.3, in camelCase, without `worldgen/`. `item_modifier` is not in mcmeta,
// because vanilla has none. Tags (`itemTag`) are found from the registries.
const std = @import("std");

pub const folders = std.StaticStringMap([]const u8).initComptime(.{
    .{ "advancement", "advancement" },
    .{ "bannerPattern", "banner_pattern" },
    .{ "blockTransformer", "block_transformer" },
    .{ "catSoundVariant", "cat_sound_variant" },
    .{ "catVariant", "cat_variant" },
    .{ "chatType", "chat_type" },
    .{ "chickenSoundVariant", "chicken_sound_variant" },
    .{ "chickenVariant", "chicken_variant" },
    .{ "contextFloatProvider", "context_float_provider" },
    .{ "contextIntProvider", "context_int_provider" },
    .{ "cowSoundVariant", "cow_sound_variant" },
    .{ "cowVariant", "cow_variant" },
    .{ "damageType", "damage_type" },
    .{ "decoratedPotPattern", "decorated_pot_pattern" },
    .{ "dialog", "dialog" },
    .{ "dimension", "dimension" },
    .{ "dimensionType", "dimension_type" },
    .{ "enchantment", "enchantment" },
    .{ "enchantmentProvider", "enchantment_provider" },
    .{ "frogVariant", "frog_variant" },
    .{ "instrument", "instrument" },
    .{ "itemModifier", "item_modifier" },
    .{ "jukeboxSong", "jukebox_song" },
    .{ "lootTable", "loot_table" },
    .{ "paintingVariant", "painting_variant" },
    .{ "pigSoundVariant", "pig_sound_variant" },
    .{ "pigVariant", "pig_variant" },
    .{ "predicate", "predicate" },
    .{ "recipe", "recipe" },
    .{ "sulfurCubeArchetype", "sulfur_cube_archetype" },
    .{ "testEnvironment", "test_environment" },
    .{ "testInstance", "test_instance" },
    .{ "timeline", "timeline" },
    .{ "tradeSet", "trade_set" },
    .{ "trialSpawner", "trial_spawner" },
    .{ "trimMaterial", "trim_material" },
    .{ "trimPattern", "trim_pattern" },
    .{ "villagerTrade", "villager_trade" },
    .{ "wolfSoundVariant", "wolf_sound_variant" },
    .{ "wolfVariant", "wolf_variant" },
    .{ "worldClock", "world_clock" },
    .{ "zombieNautilusVariant", "zombie_nautilus_variant" },
    .{ "biome", "worldgen/biome" },
    .{ "blockStateProvider", "worldgen/block_state_provider" },
    .{ "carver", "worldgen/carver" },
    .{ "densityFunction", "worldgen/density_function" },
    .{ "feature", "worldgen/feature" },
    .{ "flatLevelGeneratorPreset", "worldgen/flat_level_generator_preset" },
    .{ "materialCondition", "worldgen/material_condition" },
    .{ "materialRule", "worldgen/material_rule" },
    .{ "multiNoiseBiomeSourceParameterList", "worldgen/multi_noise_biome_source_parameter_list" },
    .{ "noise", "worldgen/noise" },
    .{ "noiseSettings", "worldgen/noise_settings" },
    .{ "placedFeature", "worldgen/placed_feature" },
    .{ "processorList", "worldgen/processor_list" },
    .{ "structure", "worldgen/structure" },
    .{ "structureSet", "worldgen/structure_set" },
    .{ "templatePool", "worldgen/template_pool" },
    .{ "worldPreset", "worldgen/world_preset" },
});

// `itemTag` → `tags/item`, `biomeTag` → `tags/worldgen/biome`, `functionTag` → `tags/function`.
// A registry in `worldgen/` comes first, so `structureTag` is the worldgen structure.
pub fn tagFolder(arena: std.mem.Allocator, word: []const u8, registries: *const std.array_hash_map.String([]const []const u8)) std.mem.Allocator.Error!?[]const u8 {
    if (!std.mem.endsWith(u8, word, "Tag") or word.len == "Tag".len) return null;
    const registry = try snakeCase(arena, word[0 .. word.len - "Tag".len]);
    if (std.mem.eql(u8, registry, "function")) return "tags/function";
    const worldgen = try std.fmt.allocPrint(arena, "worldgen/{s}", .{registry});
    if (registries.contains(worldgen)) return try std.fmt.allocPrint(arena, "tags/{s}", .{worldgen});
    if (registries.contains(registry)) return try std.fmt.allocPrint(arena, "tags/{s}", .{registry});
    return null;
}

fn snakeCase(arena: std.mem.Allocator, word: []const u8) std.mem.Allocator.Error![]const u8 {
    var result: std.ArrayList(u8) = .empty;
    for (word) |ch| {
        if (std.ascii.isUpper(ch)) {
            try result.append(arena, '_');
            try result.append(arena, std.ascii.toLower(ch));
        } else {
            try result.append(arena, ch);
        }
    }
    return result.items;
}
