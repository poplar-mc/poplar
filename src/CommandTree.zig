const std = @import("std");
const Config = @import("Config.zig");

const CommandTree = @This();

const commands_json = @embedFile("commands.json");
const registries_json = @embedFile("registries.json");

/// The ids of each registry, without `minecraft:`: `mob_effect` → `absorption`, `bad_omen`, ...
pub const Registries = std.json.ArrayHashMap([]const []const u8);

pub const Node = struct {
    pub const Kind = enum { root, literal, argument };

    type: Kind,
    children: ?std.json.ArrayHashMap(Node) = null,
    executable: bool = false,
    redirect: ?[]const []const u8 = null,
    parser: ?[]const u8 = null,
    properties: ?Properties = null,
};

pub const Properties = struct {
    min: ?f64 = null,
    max: ?f64 = null,
    type: ?[]const u8 = null,
    registry: ?[]const u8 = null,
};

pub const Failure = struct {
    message: []const u8,
    at: usize,
};

root: Node,
registries: Registries,

pub fn load(arena: std.mem.Allocator) !CommandTree {
    const root = try std.json.parseFromSliceLeaky(Node, arena, commands_json, .{ .ignore_unknown_fields = true });
    const registries = try std.json.parseFromSliceLeaky(Registries, arena, registries_json, .{});
    return .{ .root = root, .registries = registries };
}

pub const Checked = struct {
    failure: ?Failure = null,
    /// Each id in an id position (after a `#`), such as `self:heal` in `function self:heal` or `magic:undead`
    /// in `@e[type=#magic:undead]`. Text arguments, such as the message of `say`, have none.
    ids: []const Id = &.{},
};

pub const Id = struct {
    at: usize,
    /// True where the id names a function or a data file (`function`, `predicate`, a tag). False for other ids,
    /// such as a storage or a bossbar, which are not declared in Poplar.
    names_declaration: bool,
    /// True where a bare name can only be a mistake for a pack's own name: a function or a data file. False where the
    /// compiler knows the vanilla ids, so `speed` in `effect give @s speed` is the effect, even with an `mcfun speed`.
    can_be_pack_name: bool,
};

/// `poplar_namespaces` are the namespaces whose ids can be Poplar names with capitals (`self:healPlayer`).
pub fn checkText(
    self: *const CommandTree,
    arena: std.mem.Allocator,
    text: []const u8,
    poplar_namespaces: []const []const u8,
) std.mem.Allocator.Error!Checked {
    var walk: Walk = .{
        .arena = arena,
        .root = &self.root,
        .registries = &self.registries,
        .text = text,
        .poplar_namespaces = poplar_namespaces,
    };
    if (try walk.matchChildren(&self.root, 0)) return .{ .ids = walk.ids.items };

    const failure = walk.furthest orelse return .{ .failure = .{ .message = "invalid command", .at = 0 } };
    return .{ .failure = .{ .message = try failure.describe(arena, text, &self.registries), .at = failure.at } };
}

const Walk = struct {
    const Problem = struct {
        at: usize,
        expected: []const u8,
        out_of_range: bool = false,
        /// A finished message, for a problem inside an argument.
        message: ?[]const u8 = null,
        /// The registry when the id is not in it.
        unknown_in: ?[]const u8 = null,

        fn describe(
            problem: Problem,
            arena: std.mem.Allocator,
            text: []const u8,
            registries: *const Registries,
        ) std.mem.Allocator.Error![]const u8 {
            if (problem.message) |message| return message;
            const found = text[problem.at..readBalanced(text, problem.at)];
            if (problem.unknown_in) |registry| {
                const id = registryId(found).?;
                return std.fmt.allocPrint(
                    arena,
                    "unknown {s} '{s}'{f}",
                    .{ registry, id, Suggestion{ .closest = closestId(registries.map.get(registry).?, id) } },
                );
            }
            if (problem.out_of_range) return std.fmt.allocPrint(arena, "{s} '{s}' is out of range", .{ problem.expected, found });
            if (found.len == 0) return std.fmt.allocPrint(arena, "expected {s}, found end of command", .{problem.expected});
            return std.fmt.allocPrint(arena, "expected {s}, found '{s}'", .{ problem.expected, found });
        }
    };

    arena: std.mem.Allocator,
    root: *const Node,
    registries: *const Registries,
    text: []const u8,
    poplar_namespaces: []const []const u8,
    furthest: ?Problem = null,
    /// Only filled on the path that matches, because each argument adds its ids after the rest matched.
    ids: std.ArrayList(Id) = .empty,

    fn matchChildren(walk: *Walk, node: *const Node, pos: usize) std.mem.Allocator.Error!bool {
        const children = node.children orelse return false;
        var has_literal = false;

        for (children.map.keys(), children.map.values()) |name, *child| {
            if (child.type != .literal) continue;
            has_literal = true;

            const end = pos + name.len;
            if (!std.mem.startsWith(u8, walk.text[pos..], name)) continue;
            if (end < walk.text.len and walk.text[end] != ' ') continue;
            if (try walk.matchAfter(child, end)) return true;
        }

        for (children.map.values()) |*child| {
            if (child.type != .argument) continue;
            const end = try walk.readArgument(child, pos) orelse continue;
            if (try walk.matchAfter(child, end)) {
                try walk.addIdStarts(child.parser.?, child.properties orelse .{}, pos, end);
                return true;
            }
        }

        if (has_literal) walk.fail(.{ .at = pos, .expected = if (node == walk.root) "a command" else "a subcommand" });
        return false;
    }

    fn matchAfter(walk: *Walk, node: *const Node, end: usize) std.mem.Allocator.Error!bool {
        if (end == walk.text.len) {
            if (node.executable) return true;
            walk.fail(.{ .at = end, .expected = "more arguments" });
            return false;
        }

        if (walk.text[end] != ' ') {
            walk.fail(.{ .at = end, .expected = "a space" });
            return false;
        }

        const next = walk.continuation(node) orelse {
            walk.fail(.{ .at = end + 1, .expected = "end of command" });
            return false;
        };
        return walk.matchChildren(next, end + 1);
    }

    /// `self:heal` or `#magic:swords` in an id argument, and `type=#magic:undead` in a selector.
    fn addIdStarts(walk: *Walk, parser: []const u8, properties: Properties, start: usize, end: usize) std.mem.Allocator.Error!void {
        const word = walk.text[start..end];
        if (isIdParser(parser, properties)) {
            const offset: usize = if (std.mem.startsWith(u8, word, "#")) 1 else 0;
            const names_declaration = !eql(parser, "minecraft:resource_location");
            const has_vanilla_ids = if (registryOf(parser, properties)) |registry| walk.registries.map.contains(registry) else false;
            try walk.addIdStart(start + offset, names_declaration, names_declaration and !has_vanilla_ids);
        } else if (isEntityParser(parser) and std.mem.startsWith(u8, word, "@")) {
            var quote: ?u8 = null;
            for (word, 0..) |ch, index| {
                if (quote) |q| {
                    if (ch == q) quote = null;
                    continue;
                }
                if (ch == '"' or ch == '\'') quote = ch;
                if (ch != '=') continue;
                var value = index + 1;
                while (value < word.len and (word[value] == '!' or word[value] == '#')) value += 1;
                const key_start = if (std.mem.lastIndexOfAny(u8, word[0..index], "[,")) |separator| separator + 1 else 0;
                const key = std.mem.trim(u8, word[key_start..index], " ");
                try walk.addIdStart(start + value, true, eql(key, "predicate"));
            }
        }
    }

    fn addIdStart(walk: *Walk, at: usize, names_declaration: bool, can_be_pack_name: bool) std.mem.Allocator.Error!void {
        try walk.ids.append(walk.arena, .{ .at = at, .names_declaration = names_declaration, .can_be_pack_name = can_be_pack_name });
    }

    /// `execute ... run` has no children, no redirect and is not executable. It continues from the root.
    fn continuation(walk: *Walk, node: *const Node) ?*const Node {
        if (node.redirect) |path| {
            var target = walk.root;
            for (path) |name| target = target.children.?.map.getPtr(name).?;
            return target;
        }
        if (node.children != null) return node;
        if (!node.executable) return walk.root;
        return null;
    }

    fn fail(walk: *Walk, problem: Problem) void {
        if (walk.furthest) |furthest| {
            if (furthest.at >= problem.at) return;
        }
        walk.furthest = problem;
    }

    fn readArgument(walk: *Walk, node: *const Node, pos: usize) std.mem.Allocator.Error!?usize {
        const parser = node.parser.?;
        const text = walk.text;
        const end = readBalanced(text, pos);
        const word = text[pos..end];
        const properties = node.properties orelse Properties{};

        if (eql(parser, "minecraft:message")) return text.len;
        if (isMacroWord(word)) return end;

        if (registryOf(parser, properties)) |registry| {
            if (walk.isUnknownId(registry, word)) {
                walk.fail(.{ .at = pos, .expected = registry, .unknown_in = registry });
                return null;
            }
        }

        if (eql(parser, "brigadier:string")) {
            const string_type = properties.type orelse "word";
            if (eql(string_type, "greedy")) return text.len;
            if (word.len > 0 and (eql(string_type, "phrase") or isUnquotedWord(word))) return end;
        } else if (eql(parser, "brigadier:bool")) {
            if (eql(word, "true") or eql(word, "false")) return end;
        } else if (eql(parser, "brigadier:integer") or eql(parser, "brigadier:float") or eql(parser, "brigadier:double")) {
            if (parseNumber(parser, word)) |value| {
                if (value >= (properties.min orelse -std.math.inf(f64)) and value <= (properties.max orelse std.math.inf(f64))) return end;
                walk.fail(.{ .at = pos, .expected = describeParser(parser), .out_of_range = true });
                return null;
            }
        } else if (isEntityParser(parser)) {
            if (isEntity(word)) {
                const failure = try selectorFailure(walk.arena, walk.registries, word) orelse return end;
                walk.fail(.{ .at = pos + failure.at, .expected = "", .message = failure.message });
                return null;
            }
        } else if (eql(parser, "minecraft:block_pos") or eql(parser, "minecraft:vec3")) {
            return walk.readCoordinates(pos, 3);
        } else if (eql(parser, "minecraft:vec2") or eql(parser, "minecraft:column_pos") or eql(parser, "minecraft:rotation")) {
            return walk.readCoordinates(pos, 2);
        } else if (isResourceParser(parser)) {
            if (isResourceLocation(word, walk.poplar_namespaces)) return end;
        } else if (word.len > 0) {
            return end;
        }

        walk.fail(.{ .at = pos, .expected = describeParser(parser) });
        return null;
    }

    /// Only vanilla ids are checked: a tag, `*`, or an id in another namespace (the pack's own) passes.
    fn isUnknownId(walk: *const Walk, registry: []const u8, word: []const u8) bool {
        const id = registryId(word) orelse return false;
        const ids = walk.registries.map.get(registry) orelse return false;
        for (ids) |known| {
            if (eql(known, id)) return false;
        }
        return true;
    }

    fn readCoordinates(walk: *Walk, start: usize, count: usize) ?usize {
        var pos = start;

        for (0..count) |index| {
            if (index > 0) {
                if (pos >= walk.text.len or walk.text[pos] != ' ') {
                    walk.fail(.{ .at = @min(pos + 1, walk.text.len), .expected = "a coordinate" });
                    return null;
                }
                pos += 1;
            }

            const end = readBalanced(walk.text, pos);
            if (!isCoordinate(walk.text[pos..end])) {
                walk.fail(.{ .at = pos, .expected = "a coordinate" });
                return null;
            }
            pos = end;
        }

        return pos;
    }
};

/// Reads to the next space that is outside quotes and brackets.
fn readBalanced(text: []const u8, start: usize) usize {
    var pos = start;
    var depth: usize = 0;
    var quote: ?u8 = null;

    while (pos < text.len) : (pos += 1) {
        const ch = text[pos];
        if (quote) |q| {
            if (ch == '\\') {
                pos += 1;
            } else if (ch == q) {
                quote = null;
            }
            continue;
        }

        switch (ch) {
            '"', '\'' => quote = ch,
            '[', '{', '(' => depth += 1,
            ']', '}', ')' => depth -|= 1,
            ' ' => if (depth == 0) break,
            else => {},
        }
    }

    return @min(pos, text.len);
}

fn parseNumber(parser: []const u8, word: []const u8) ?f64 {
    if (!eql(parser, "brigadier:integer")) return std.fmt.parseFloat(f64, word) catch null;

    const int = std.fmt.parseInt(i64, word, 10) catch return null;
    return @floatFromInt(int);
}

/// The registry that an argument names: `minecraft:resource` with `registry: minecraft:mob_effect` → `mob_effect`.
fn registryOf(parser: []const u8, properties: Properties) ?[]const u8 {
    if (eql(parser, "minecraft:item_stack") or eql(parser, "minecraft:item_predicate")) return "item";
    if (eql(parser, "minecraft:block_state") or eql(parser, "minecraft:block_predicate")) return "block";

    const keyed = [_][]const u8{
        "minecraft:resource",
        "minecraft:resource_key",
        "minecraft:resource_or_tag",
        "minecraft:resource_or_tag_key",
    };
    for (keyed) |keyed_parser| {
        if (!eql(parser, keyed_parser)) continue;
        const registry = properties.registry orelse return null;
        return if (std.mem.startsWith(u8, registry, "minecraft:")) registry["minecraft:".len..] else registry;
    }
    return null;
}

/// `minecraft:stone[lit=true]` → `stone`. Null for a tag, `*`, or another namespace (the pack's own).
fn registryId(word: []const u8) ?[]const u8 {
    if (word.len == 0 or word[0] == '#' or word[0] == '*') return null;
    const end = std.mem.indexOfAny(u8, word, "[{") orelse word.len;
    const id = word[0..end];
    const separator = std.mem.indexOfScalar(u8, id, ':') orelse return id;
    if (!eql(id[0..separator], "minecraft")) return null;
    return id[separator + 1 ..];
}

/// `. Did you mean 'x'?` at the end of a message, or nothing when there is no close match.
pub const Suggestion = struct {
    closest: ?[]const u8,

    pub fn format(self: Suggestion, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        if (self.closest) |closest| try writer.print(". Did you mean '{s}'?", .{closest});
    }
};

/// The id with the smallest edit distance, if it is 3 or less.
pub fn closestId(ids: []const []const u8, id: []const u8) ?[]const u8 {
    var best: ?[]const u8 = null;
    var best_distance: usize = 4;
    for (ids) |candidate| {
        const distance = editDistance(candidate, id) orelse continue;
        if (distance < best_distance) {
            best = candidate;
            best_distance = distance;
        }
    }
    return best;
}

/// Levenshtein distance. Null for words longer than 64 characters.
fn editDistance(a: []const u8, b: []const u8) ?usize {
    if (a.len > 64 or b.len > 64) return null;
    var previous: [65]usize = undefined;
    var current: [65]usize = undefined;
    for (0..b.len + 1) |j| previous[j] = j;
    for (a, 0..) |a_char, i| {
        current[0] = i + 1;
        for (b, 0..) |b_char, j| {
            const substitution = previous[j] + @intFromBool(a_char != b_char);
            current[j + 1] = @min(substitution, previous[j + 1] + 1, current[j] + 1);
        }
        @memcpy(previous[0 .. b.len + 1], current[0 .. b.len + 1]);
    }
    return previous[b.len];
}

/// Minecraft checks a macro argument when the macro runs, so any argument kind accepts it here.
fn isMacroWord(word: []const u8) bool {
    return std.mem.indexOf(u8, word, "$(") != null;
}

fn isCoordinate(word: []const u8) bool {
    if (word.len == 0) return false;
    if (isMacroWord(word)) return true;

    const has_prefix = word[0] == '~' or word[0] == '^';
    const number = if (has_prefix) word[1..] else word;
    if (has_prefix and number.len == 0) return true;

    _ = std.fmt.parseFloat(f64, number) catch return false;
    return true;
}

/// The options of a selector, as the game knows them.
const selector_options = [_][]const u8{
    "advancements",
    "distance",
    "dx",
    "dy",
    "dz",
    "gamemode",
    "level",
    "limit",
    "name",
    "nbt",
    "predicate",
    "scores",
    "sort",
    "tag",
    "team",
    "type",
    "x",
    "x_rotation",
    "y",
    "y_rotation",
    "z",
};

pub fn checkSelector(self: *const CommandTree, arena: std.mem.Allocator, selector: []const u8) std.mem.Allocator.Error!?Failure {
    return selectorFailure(arena, &self.registries, selector);
}

/// What the game rejects inside `@e[...]`, where it would refuse the whole function. `at` is an offset in `selector`.
fn selectorFailure(arena: std.mem.Allocator, registries: *const Registries, selector: []const u8) std.mem.Allocator.Error!?Failure {
    if (selector.len < 4 or selector[0] != '@' or selector[2] != '[') return null;
    const close = selector.len - 1;

    var pos: usize = 3;
    while (pos < close) {
        const end = optionEnd(selector, pos, close);
        defer pos = end + 1;
        const separator = std.mem.indexOfScalarPos(u8, selector[0..end], pos, '=') orelse continue;
        const key = std.mem.trim(u8, selector[pos..separator], " ");

        var known = false;
        for (selector_options) |option| known = known or eql(option, key);
        if (!known) {
            // Option names are short, so only a near match is worth suggesting.
            const closest = closestId(&selector_options, key);
            const is_near = closest != null and editDistance(key, closest.?).? <= 2;
            return .{
                .message = try std.fmt.allocPrint(
                    arena,
                    "unknown selector option '{s}'{f}",
                    .{ key, Suggestion{ .closest = if (is_near) closest else null } },
                ),
                .at = pos,
            };
        }

        var value_start = separator + 1;
        while (value_start < end and (selector[value_start] == ' ' or selector[value_start] == '!')) value_start += 1;
        const value = std.mem.trimEnd(u8, selector[value_start..end], " ");
        if (value.len == 0) continue;

        // The game reads a quoted `name`, and quotes inside the NBT of `nbt`. Every other option refuses them.
        if ((value[0] == '"' or value[0] == '\'') and !eql(key, "name") and !eql(key, "nbt")) {
            return .{ .message = try std.fmt.allocPrint(arena, "selector option '{s}' cannot have quotes: write {s}={s}", .{ key, key, std.mem.trim(u8, value, "\"'") }), .at = value_start };
        }
        if (!eql(key, "type")) continue;
        const id = registryId(value) orelse continue;
        const ids = registries.map.get("entity_type") orelse continue;
        for (ids) |known_id| {
            if (eql(known_id, id)) break;
        } else {
            return .{
                .message = try std.fmt.allocPrint(
                    arena,
                    "unknown entity_type '{s}'{f}",
                    .{ id, Suggestion{ .closest = closestId(ids, id) } },
                ),
                .at = value_start,
            };
        }
    }
    return null;
}

/// The `,` or closing `]` that ends the option at `start`, outside quotes and brackets.
fn optionEnd(selector: []const u8, start: usize, close: usize) usize {
    var depth: usize = 0;
    var quote: ?u8 = null;
    for (selector[start..close], start..) |ch, index| {
        if (quote) |q| {
            if (ch == q) quote = null;
            continue;
        }
        switch (ch) {
            '"', '\'' => quote = ch,
            '[', '{' => depth += 1,
            ']', '}' => depth -|= 1,
            ',' => if (depth == 0) return index,
            else => {},
        }
    }
    return close;
}

fn isEntity(word: []const u8) bool {
    if (word.len == 0) return false;
    if (word[0] != '@') return true;
    if (word.len < 2 or std.mem.indexOfScalar(u8, "aeprsn", word[1]) == null) return false;
    return word.len == 2 or (word[2] == '[' and word[word.len - 1] == ']');
}

fn isIdParser(parser: []const u8, properties: Properties) bool {
    if (isResourceParser(parser) or registryOf(parser, properties) != null) return true;
    const loot_parsers = [_][]const u8{ "minecraft:loot_predicate", "minecraft:loot_table", "minecraft:loot_modifier" };
    for (loot_parsers) |loot_parser| {
        if (eql(parser, loot_parser)) return true;
    }
    return false;
}

fn isEntityParser(parser: []const u8) bool {
    return eql(parser, "minecraft:entity") or eql(parser, "minecraft:game_profile") or eql(parser, "minecraft:score_holder");
}

fn isResourceParser(parser: []const u8) bool {
    const resource_parsers = [_][]const u8{
        "minecraft:resource",
        "minecraft:resource_key",
        "minecraft:resource_location",
        "minecraft:resource_or_tag",
        "minecraft:resource_or_tag_key",
        "minecraft:function",
        "minecraft:dimension",
    };
    for (resource_parsers) |resource_parser| {
        if (eql(parser, resource_parser)) return true;
    }
    return false;
}

fn isResourceLocation(word: []const u8, poplar_namespaces: []const []const u8) bool {
    const location = if (std.mem.startsWith(u8, word, "#")) word[1..] else word;
    if (location.len == 0) return false;
    // `self:healPlayer` names a Poplar declaration with a capital. The compiler changes it into the id.
    if (std.mem.indexOfScalar(u8, location, ':')) |colon| {
        const is_poplar = for (poplar_namespaces) |namespace| {
            if (eql(namespace, location[0..colon])) break true;
        } else false;
        if (is_poplar) {
            for (location[colon + 1 ..]) |ch| {
                if (!std.ascii.isAlphanumeric(ch) and std.mem.indexOfScalar(u8, "_-./", ch) == null) return false;
            }
            return true;
        }
    }

    for (location) |ch| {
        if (!Config.isResourceNameChar(ch) and ch != ':' and ch != '/') return false;
    }
    return true;
}

fn isUnquotedWord(word: []const u8) bool {
    for (word) |ch| {
        const valid = std.ascii.isAlphanumeric(ch) or std.mem.indexOfScalar(u8, "_-.+", ch) != null;
        if (!valid) return false;
    }
    return true;
}

fn describeParser(parser: []const u8) []const u8 {
    const separator = std.mem.indexOfScalar(u8, parser, ':') orelse return parser;
    return parser[separator + 1 ..];
}

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn checkForTest(tree: *const CommandTree, arena: std.mem.Allocator, text: []const u8) !?Failure {
    return (try tree.checkText(arena, text, &.{})).failure;
}

test "checks the options of a selector the way the game does" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const tree = try load(arena.allocator());

    const valid = [_][]const u8{
        "execute as @e[type=zombie,tag=a,name=\"a b\",nbt={Tags:[\"x,y\"]},scores={a=1..},limit=1] run say x",
        "execute as @e[ type = !minecraft:zombie , type = !skeleton ] run say x",
        "execute as @e[type=#minecraft:undead,type=#self:mobs,predicate=self:lucky] run say x",
        "execute as @e[] run say x",
    };
    for (valid) |text| {
        if ((try tree.checkText(arena.allocator(), text, &.{"self"})).failure) |failure| {
            std.debug.print("'{s}': {s}\n", .{ text, failure.message });
            return error.TestUnexpectedResult;
        }
    }

    const quoted = (try checkForTest(&tree, arena.allocator(), "execute as @e[type=\"minecraft:zombie\"] run say x")).?;
    try std.testing.expectEqualStrings("selector option 'type' cannot have quotes: write type=minecraft:zombie", quoted.message);
    try std.testing.expectEqual(19, quoted.at);
    try std.testing.expectEqualStrings(
        "selector option 'tag' cannot have quotes: write tag=a",
        (try checkForTest(&tree, arena.allocator(), "execute as @e[tag=!\"a\"] run say x")).?.message,
    );
    try std.testing.expectEqualStrings(
        "unknown entity_type 'zombiee'. Did you mean 'zombie'?",
        (try checkForTest(&tree, arena.allocator(), "execute as @e[type=!zombiee] run say x")).?.message,
    );
    try std.testing.expectEqualStrings(
        "unknown selector option 'tagg'. Did you mean 'tag'?",
        (try checkForTest(&tree, arena.allocator(), "kill @e[tagg=a]")).?.message,
    );
    try std.testing.expectEqualStrings(
        "unknown selector option 'foo'",
        (try checkForTest(&tree, arena.allocator(), "kill @e[foo=1]")).?.message,
    );
}

test "finds ids in id arguments and selectors, not in text" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const tree = try load(arena.allocator());

    const text = "execute as @e[type=#self:undead] if predicate self:isSitting run say self:not_an_id";
    const checked = try tree.checkText(arena.allocator(), text, &.{"self"});
    try std.testing.expectEqual(null, checked.failure);
    try std.testing.expectEqual(2, checked.ids.len);
    for (checked.ids) |id| try std.testing.expect(
        std.mem.startsWith(u8, text[id.at..], "self:undead") or std.mem.startsWith(u8, text[id.at..], "self:isSitting"),
    );

    const storage = try tree.checkText(arena.allocator(), "data get storage self:data x", &.{"self"});
    try std.testing.expect((try tree.checkText(arena.allocator(), "function other:Caps", &.{"self"})).failure != null);
    try std.testing.expect(!storage.ids[0].names_declaration);
}

test "checks commands against the tree" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const tree = try load(arena.allocator());

    const valid = [_][]const u8{
        "say hi there",
        "effect give @p poison 10",
        "tp @s ~ ~1 ~",
        "execute as @a[tag=a, limit=1] if score @s ns matches 1.. run say x",
        "summon zombie ~ ~1 ~ {Tags:[\"a b\"],Data:[I;1,2]}",
    };
    for (valid) |text| {
        if (try checkForTest(&tree, arena.allocator(), text)) |failure| {
            std.debug.print("'{s}': {s}\n", .{ text, failure.message });
            return error.TestUnexpectedResult;
        }
    }

    const unknown = (try checkForTest(&tree, arena.allocator(), "efect give @p poison")).?;
    try std.testing.expectEqualStrings("expected a command, found 'efect'", unknown.message);

    const bad_number = (try checkForTest(&tree, arena.allocator(), "effect give @p poison abc")).?;
    try std.testing.expectEqualStrings("expected integer, found 'abc'", bad_number.message);
    try std.testing.expectEqual(22, bad_number.at);

    const effect = (try checkForTest(&tree, arena.allocator(), "effect give @p minecraft:poision 10")).?;
    try std.testing.expectEqualStrings("unknown mob_effect 'poision'. Did you mean 'poison'?", effect.message);
    const item = (try checkForTest(&tree, arena.allocator(), "give @s diamnod 2")).?;
    try std.testing.expectEqualStrings("unknown item 'diamnod'. Did you mean 'diamond'?", item.message);
    const block = (try checkForTest(&tree, arena.allocator(), "setblock ~ ~ ~ stonee[lit=true]")).?;
    try std.testing.expectEqualStrings("unknown block 'stonee'. Did you mean 'stone'?", block.message);

    const not_checked = [_][]const u8{ "give @s mypack:wand", "clear @s #minecraft:logs", "give @s $(item)" };
    for (not_checked) |text| try std.testing.expectEqual(null, try checkForTest(&tree, arena.allocator(), text));
}
