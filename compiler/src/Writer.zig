const std = @import("std");
const Config = @import("Config.zig");
const Ir = @import("Ir.zig");

pub fn writeDatapack(
    io: std.Io,
    gpa: std.mem.Allocator,
    out_dir: std.Io.Dir,
    config: Config,
    program: Ir.Program,
) !void {
    const min = config.min_format;
    const max = config.max_format;
    const pack_mcmeta = try std.fmt.allocPrint(gpa,
        \\{{
        \\    "pack": {{
        \\        "description": {s},
        \\        "min_format": [{d}, {d}],
        \\        "max_format": [{d}, {d}]
        \\    }}
        \\}}
        \\
    , .{ config.description, min.major, min.minor, max.major, max.minor });
    try out_dir.writeFile(io, .{ .sub_path = "pack.mcmeta", .data = pack_mcmeta });

    for (program.functions) |function| {
        try writeFunction(io, gpa, out_dir, config.namespace, function);
    }

    if (program.load) |load| {
        try writeFunction(io, gpa, out_dir, config.namespace, load);
        try writeFunctionTag(io, gpa, out_dir, "load", config.namespace, &.{load.name});
    }

    if (program.tick.len > 0) try writeFunctionTag(io, gpa, out_dir, "tick", config.namespace, program.tick);

    for (program.data_files) |data_file| {
        const path = try std.fmt.allocPrint(gpa, "data/{s}/{s}/{s}.json", .{ data_file.namespace, data_file.folder, data_file.path });
        try out_dir.createDirPath(io, std.fs.path.dirname(path).?);
        try out_dir.writeFile(io, .{ .sub_path = path, .data = data_file.json });
    }
}

// Writes a `minecraft:<tag_name>` function tag with the functions in order.
fn writeFunctionTag(
    io: std.Io,
    gpa: std.mem.Allocator,
    out_dir: std.Io.Dir,
    comptime tag_name: []const u8,
    namespace: []const u8,
    function_names: []const []const u8,
) !void {
    const tag_dir_path = "data/minecraft/tags/function";
    try out_dir.createDirPath(io, tag_dir_path);

    var values: std.ArrayList(u8) = .empty;
    for (function_names, 0..) |name, index| {
        if (index > 0) try values.appendSlice(gpa, ", ");
        try values.print(gpa, "\"{f}\"", .{functionId(namespace, name)});
    }
    const tag = try std.fmt.allocPrint(gpa,
        \\{{
        \\    "values": [{s}]
        \\}}
        \\
    , .{values.items});
    try out_dir.writeFile(io, .{ .sub_path = tag_dir_path ++ "/" ++ tag_name ++ ".json", .data = tag });
}

// Writes a zip of the pack folder with no compression, so `pack.mcmeta` is at the root of the zip.
pub fn writeZip(io: std.Io, gpa: std.mem.Allocator, pack_dir: std.Io.Dir, out_dir: std.Io.Dir, zip_name: []const u8) !void {
    var bytes: std.ArrayList(u8) = .empty;
    var central_directory: std.ArrayList(u8) = .empty;
    var file_count: u16 = 0;

    var walker = try pack_dir.walk(gpa);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;

        const name = try gpa.dupe(u8, entry.path);
        std.mem.replaceScalar(u8, name, '\\', '/');
        const data = try entry.dir.readFileAlloc(io, entry.basename, gpa, .unlimited);
        const header: ZipEntryHeader = .{
            .crc = std.hash.Crc32.hash(data),
            .size = @intCast(data.len),
            .name_length = @intCast(name.len),
        };
        const local_header_offset: u32 = @intCast(bytes.items.len);

        try appendInt(&bytes, gpa, u32, 0x04034b50);
        try header.append(&bytes, gpa);
        try appendInt(&bytes, gpa, u16, 0); // extra field length
        try bytes.appendSlice(gpa, name);
        try bytes.appendSlice(gpa, data);

        try appendInt(&central_directory, gpa, u32, 0x02014b50);
        try appendInt(&central_directory, gpa, u16, zip_version);
        try header.append(&central_directory, gpa);
        try appendInt(&central_directory, gpa, u16, 0); // extra field length
        try appendInt(&central_directory, gpa, u16, 0); // comment length
        try appendInt(&central_directory, gpa, u16, 0); // disk number
        try appendInt(&central_directory, gpa, u16, 0); // internal attributes
        try appendInt(&central_directory, gpa, u32, 0); // external attributes
        try appendInt(&central_directory, gpa, u32, local_header_offset);
        try central_directory.appendSlice(gpa, name);
        file_count += 1;
    }

    const central_directory_offset: u32 = @intCast(bytes.items.len);
    try bytes.appendSlice(gpa, central_directory.items);

    try appendInt(&bytes, gpa, u32, 0x06054b50);
    try appendInt(&bytes, gpa, u16, 0); // disk number
    try appendInt(&bytes, gpa, u16, 0); // disk of the central directory
    try appendInt(&bytes, gpa, u16, file_count);
    try appendInt(&bytes, gpa, u16, file_count);
    try appendInt(&bytes, gpa, u32, @intCast(central_directory.items.len));
    try appendInt(&bytes, gpa, u32, central_directory_offset);
    try appendInt(&bytes, gpa, u16, 0); // comment length

    try out_dir.writeFile(io, .{ .sub_path = zip_name, .data = bytes.items });
}

// Version 2.0 of the zip format: stored files with no compression.
const zip_version = 20;

// The fields that the local header and the central directory header share, from "version needed" to "name length".
const ZipEntryHeader = struct {
    crc: u32,
    size: u32,
    name_length: u16,

    fn append(header: ZipEntryHeader, bytes: *std.ArrayList(u8), gpa: std.mem.Allocator) !void {
        try appendInt(bytes, gpa, u16, zip_version);
        try appendInt(bytes, gpa, u16, 0); // flags
        try appendInt(bytes, gpa, u16, 0); // method: stored
        try appendInt(bytes, gpa, u16, 0); // time
        try appendInt(bytes, gpa, u16, (1 << 5) | 1); // date: 1980-01-01
        try appendInt(bytes, gpa, u32, header.crc);
        try appendInt(bytes, gpa, u32, header.size); // compressed size
        try appendInt(bytes, gpa, u32, header.size);
        try appendInt(bytes, gpa, u16, header.name_length);
    }
};

fn appendInt(bytes: *std.ArrayList(u8), gpa: std.mem.Allocator, comptime T: type, value: T) !void {
    var buffer: [@sizeOf(T)]u8 = undefined;
    std.mem.writeInt(T, &buffer, value, .little);
    try bytes.appendSlice(gpa, &buffer);
}

fn writeFunction(
    io: std.Io,
    gpa: std.mem.Allocator,
    out_dir: std.Io.Dir,
    namespace: []const u8,
    function: Ir.McFunction,
) !void {
    const function_namespace, const function_path = splitFunctionName(namespace, function.name);
    const path = try std.fmt.allocPrint(gpa, "data/{s}/function/{f}.mcfunction", .{ function_namespace, functionPath(function_path) });
    try out_dir.createDirPath(io, std.fs.path.dirname(path).?);

    const text = try renderFunction(gpa, namespace, function);
    try out_dir.writeFile(io, .{ .sub_path = path, .data = text });
}

pub fn renderFunction(gpa: std.mem.Allocator, namespace: []const u8, function: Ir.McFunction) ![]const u8 {
    var text: std.ArrayList(u8) = .empty;

    for (function.commands) |command| {
        var line: std.ArrayList(u8) = .empty;
        try renderCommand(&line, gpa, namespace, command);

        // A line that uses a macro argument must start with `$`.
        if (std.mem.indexOf(u8, line.items, "$(") != null) try text.append(gpa, '$');
        try text.appendSlice(gpa, line.items);
        try text.append(gpa, '\n');
    }

    return text.toOwnedSlice(gpa);
}

fn renderCommand(text: *std.ArrayList(u8), gpa: std.mem.Allocator, namespace: []const u8, command: Ir.Command) !void {
    switch (command) {
        .raw => |command_text| try text.appendSlice(gpa, command_text),
        .function => |name| try text.print(gpa, "function {f}", .{functionId(namespace, name)}),
        .add_objective => |objective| try text.print(gpa, "scoreboard objectives add {f} dummy", .{objectiveText(objective.namespace orelse namespace, objective.name)}),
        .score_set => |set| try text.print(gpa, "scoreboard players set {f} {d}", .{ scoreText(namespace, set.score), set.value }),
        .score_set_if_unset => |set| {
            const score = scoreText(namespace, set.score);
            try text.print(gpa, "execute unless score {f} matches -2147483648.. run scoreboard players set {f} {d}", .{ score, score, set.value });
        },
        .score_add => |add| try text.print(gpa, "scoreboard players add {f} {d}", .{ scoreText(namespace, add.score), add.value }),
        .score_remove => |remove| try text.print(gpa, "scoreboard players remove {f} {d}", .{ scoreText(namespace, remove.score), remove.value }),
        .score_operation => |operation| try text.print(gpa, "scoreboard players operation {f} {s} {f}", .{
            scoreText(namespace, operation.target),
            operatorText(operation.op),
            scoreText(namespace, operation.source),
        }),
        .score_set_param => |set| try text.print(gpa, "scoreboard players set {f} $({s})", .{ scoreText(namespace, set.score), set.param }),
        .data_set => |data| try text.print(gpa, "data modify {f} set value {s}", .{ dataPathText(namespace, data.target), data.snbt }),
        .data_set_if_unset => |data| {
            const target = dataPathText(namespace, data.target);
            try text.print(gpa, "execute unless data {f} run data modify {f} set value {s}", .{ target, target, data.snbt });
        },
        .data_add => |add| {
            try text.print(gpa, "data modify {f} ", .{dataPathText(namespace, add.list)});
            switch (add.position) {
                .append => try text.appendSlice(gpa, "append"),
                .prepend => try text.appendSlice(gpa, "prepend"),
                .insert => |index| try text.print(gpa, "insert {d}", .{index}),
            }
            switch (add.source) {
                .snbt => |snbt| try text.print(gpa, " value {s}", .{snbt}),
                .from => |source| try text.print(gpa, " from {f}", .{dataPathText(namespace, source)}),
            }
        },
        .data_remove => |path| try text.print(gpa, "data remove {f}", .{dataPathText(namespace, path)}),
        .data_copy => |copy| try text.print(gpa, "data modify {f} set from {f}", .{
            dataPathText(namespace, copy.target),
            dataPathText(namespace, copy.source),
        }),
        .data_set_string => |set| {
            try text.print(gpa, "data modify {f} set string {f}", .{ dataPathText(namespace, set.target), dataPathText(namespace, set.source) });
            if (set.start) |start| try text.print(gpa, " {d}", .{start});
            if (set.end) |end| try text.print(gpa, " {d}", .{end});
        },
        .score_to_data => |copy| try text.print(gpa, "execute store result {f} {t} 1 run scoreboard players get {f}", .{
            dataPathText(namespace, copy.target),
            copy.type,
            scoreText(namespace, copy.score),
        }),
        .data_to_score => |copy| {
            try text.print(gpa, "execute store result score {f} run data get {f}", .{
                scoreText(namespace, copy.score),
                dataPathText(namespace, copy.source),
            });
            if (copy.scale != 1) try text.print(gpa, " {d}", .{copy.scale});
        },
        .function_with => |call| {
            try text.print(gpa, "function {f}", .{functionId(namespace, call.name)});
            switch (call.arguments) {
                .compound => |compound| try text.print(gpa, " {s}", .{compound}),
                .data_storage => try text.print(gpa, " with storage {s}:data", .{namespace}),
                .args_storage => try text.print(gpa, " with storage {s}:poplar args", .{namespace}),
                .macro_storage => try text.print(gpa, " with storage {s}:poplar macro", .{namespace}),
            }
        },
        .macro => |macro_text| try text.appendSlice(gpa, macro_text),
        .frame_push => try text.print(gpa, "data modify storage {s}:poplar stack append value {{}}", .{namespace}),
        .frame_pop => try text.print(gpa, "data remove storage {s}:poplar stack[-1]", .{namespace}),
        .stack_clear => try text.print(gpa, "data modify storage {s}:poplar stack set value []", .{namespace}),
        .execute => |execute| {
            try text.appendSlice(gpa, "execute");
            for (execute.checks) |check| try renderCheck(text, gpa, namespace, check);
            try renderRun(text, gpa, namespace, execute.run.*);
        },
        .execute_raw => |execute| {
            try text.print(gpa, "execute {s}", .{execute.subcommands});
            try renderRun(text, gpa, namespace, execute.run.*);
        },
        .return_run => |run| {
            try text.appendSlice(gpa, "return run ");
            try renderCommand(text, gpa, namespace, run.*);
        },
        .return_value => |value| try text.print(gpa, "return {d}", .{value}),
        .return_param => |param| try text.print(gpa, "return $({s})", .{param}),
        .store_result => |store| {
            switch (store.target) {
                .score => |score| try text.print(gpa, "execute store result score {f} run ", .{scoreText(namespace, score)}),
                .data => |data| try text.print(gpa, "execute store result {f} {t} 1 run ", .{ dataPathText(namespace, data.path), data.type }),
            }
            try renderCommand(text, gpa, namespace, store.run.*);
        },
        .score_get => |score| try text.print(gpa, "scoreboard players get {f}", .{scoreText(namespace, score)}),
        .data_get => |path| try text.print(gpa, "data get {f}", .{dataPathText(namespace, path)}),
    }
}

// `execute A run execute B run C` is the same as `execute A B run C`, so nested executes become one.
fn renderRun(text: *std.ArrayList(u8), gpa: std.mem.Allocator, namespace: []const u8, run: Ir.Command) std.mem.Allocator.Error!void {
    const start = text.items.len;
    try text.appendSlice(gpa, " run ");
    try renderCommand(text, gpa, namespace, run);

    const nested = " run execute ";
    if (std.mem.startsWith(u8, text.items[start..], nested)) try text.replaceRange(gpa, start, nested.len, " ");
}

fn renderCheck(text: *std.ArrayList(u8), gpa: std.mem.Allocator, namespace: []const u8, check: Ir.Check) !void {
    try text.appendSlice(gpa, if (check.negated) " unless " else " if ");
    switch (check.score_test) {
        .data_test => |path| return text.print(gpa, "data {f}", .{dataPathText(namespace, path)}),
        .function_returns => |name| return text.print(gpa, "function {f}", .{functionId(namespace, name)}),
        .raw => |raw| return text.appendSlice(gpa, raw),
        else => {},
    }
    try text.appendSlice(gpa, "score ");

    switch (check.score_test) {
        .matches => |matches| {
            try text.print(gpa, "{f} matches ", .{scoreText(namespace, matches.score)});
            if (matches.min != null and matches.min == matches.max) {
                try text.print(gpa, "{d}", .{matches.min.?});
            } else {
                if (matches.min) |min| try text.print(gpa, "{d}", .{min});
                try text.appendSlice(gpa, "..");
                if (matches.max) |max| try text.print(gpa, "{d}", .{max});
            }
        },
        .compare => |compare| try text.print(gpa, "{f} {s} {f}", .{
            scoreText(namespace, compare.left),
            compareText(compare.op),
            scoreText(namespace, compare.right),
        }),
        .data_test, .function_returns, .raw => unreachable,
    }
}

// Minecraft function names cannot have capitals, so a camelCase name is written in snake_case:
// `playerDied` → `player_died`, `poplar/usedCarrot/if_0` → `poplar/used_carrot/if_0`.
const FunctionPath = struct {
    name: []const u8,

    pub fn format(self: FunctionPath, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        for (self.name, 0..) |ch, index| {
            if (std.ascii.isUpper(ch)) {
                if (index > 0 and self.name[index - 1] != '/') try writer.writeByte('_');
                try writer.writeByte(std.ascii.toLower(ch));
            } else {
                try writer.writeByte(ch);
            }
        }
    }
};

pub fn functionPath(name: []const u8) FunctionPath {
    return .{ .name = name };
}

// `combat:healPlayer` → `combat:heal_player`. A name without a namespace is in the pack namespace.
const FunctionId = struct {
    pack_namespace: []const u8,
    name: []const u8,

    pub fn format(self: FunctionId, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        const namespace, const path = splitFunctionName(self.pack_namespace, self.name);
        try writer.print("{s}:{f}", .{ namespace, functionPath(path) });
    }
};

fn functionId(pack_namespace: []const u8, name: []const u8) FunctionId {
    return .{ .pack_namespace = pack_namespace, .name = name };
}

fn splitFunctionName(pack_namespace: []const u8, name: []const u8) struct { []const u8, []const u8 } {
    const namespace, const path = Ir.splitName(name);
    return .{ namespace orelse pack_namespace, path };
}

// `storage ns:data hp` or `entity @s Health`, the target of `data` and `execute store`.
const DataPathText = struct {
    namespace: []const u8,
    data_path: Ir.DataPath,

    pub fn format(self: DataPathText, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        const path = self.data_path.path;
        switch (self.data_path.holder) {
            .storage => |storage| switch (storage) {
                .data => try writer.print("storage {s}:data {s}", .{ self.data_path.namespace orelse self.namespace, path }),
                .args => try writer.print("storage {s}:poplar args.{s}", .{ self.namespace, path }),
                .frame => try writer.print("storage {s}:poplar stack[-1].{s}", .{ self.namespace, path }),
                .poplar => try writer.print("storage {s}:poplar {s}", .{ self.namespace, path }),
                .macro => if (path.len == 0)
                    try writer.print("storage {s}:poplar macro", .{self.namespace})
                else
                    try writer.print("storage {s}:poplar macro.{s}", .{ self.namespace, path }),
            },
            .entity => |selector| try writer.print("entity {s} {s}", .{ selector, path }),
        }
    }
};

fn dataPathText(namespace: []const u8, data_path: Ir.DataPath) DataPathText {
    return .{ .namespace = namespace, .data_path = data_path };
}

const ObjectiveText = struct {
    namespace: []const u8,
    objective: ?[]const u8,

    pub fn format(self: ObjectiveText, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.writeAll(self.namespace);
        if (self.objective) |objective| try writer.print(".{s}", .{objective});
    }
};

fn objectiveText(namespace: []const u8, objective: ?[]const u8) ObjectiveText {
    return .{ .namespace = namespace, .objective = objective };
}

const ScoreText = struct {
    namespace: []const u8,
    score: Ir.Score,

    pub fn format(self: ScoreText, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.print("{s} {f}", .{ self.score.holder, objectiveText(self.score.namespace orelse self.namespace, self.score.objective) });
    }
};

fn scoreText(namespace: []const u8, score: Ir.Score) ScoreText {
    return .{ .namespace = namespace, .score = score };
}

fn compareText(op: Ir.CompareOp) []const u8 {
    return switch (op) {
        .lt => "<",
        .le => "<=",
        .eq => "=",
        .ge => ">=",
        .gt => ">",
    };
}

fn operatorText(op: Ir.Operator) []const u8 {
    return switch (op) {
        .assign => "=",
        .add => "+=",
        .sub => "-=",
        .mul => "*=",
        .div => "/=",
        .mod => "%=",
    };
}

test "writes functions and tags" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const program: Ir.Program = .{
        .functions = &.{
            .{ .name = "main", .commands = &.{ .{ .raw = "say hi" }, .{ .function = "other" } } },
        },
        .load = .{ .name = "poplar/load", .commands = &.{.{ .score_set_if_unset = .{ .score = .{ .holder = "$hp" }, .value = 20 } }} },
        .tick = &.{"main"},
    };
    const config: Config = .{
        .zip_name = "demo",
        .namespace = "demo",
        .description = "\"Demo\"",
        .min_format = .{ .major = 121 },
        .max_format = .{ .major = 121 },
    };
    try writeDatapack(io, arena.allocator(), tmp.dir, config, program);

    const main_text = try tmp.dir.readFileAlloc(io, "data/demo/function/main.mcfunction", arena.allocator(), .unlimited);
    try std.testing.expectEqualStrings("say hi\nfunction demo:other\n", main_text);

    const load_text = try tmp.dir.readFileAlloc(io, "data/demo/function/poplar/load.mcfunction", arena.allocator(), .unlimited);
    try std.testing.expectEqualStrings(
        "execute unless score $hp demo matches -2147483648.. run scoreboard players set $hp demo 20\n",
        load_text,
    );

    const load_tag = try tmp.dir.readFileAlloc(io, "data/minecraft/tags/function/load.json", arena.allocator(), .unlimited);
    try std.testing.expectEqualStrings("{\n    \"values\": [\"demo:poplar/load\"]\n}\n", load_tag);

    const tick_tag = try tmp.dir.readFileAlloc(io, "data/minecraft/tags/function/tick.json", arena.allocator(), .unlimited);
    try std.testing.expectEqualStrings("{\n    \"values\": [\"demo:main\"]\n}\n", tick_tag);
}

test "writes a zip that can be extracted" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const io = std.testing.io;

    var pack = std.testing.tmpDir(.{ .iterate = true });
    defer pack.cleanup();
    try pack.dir.writeFile(io, .{ .sub_path = "pack.mcmeta", .data = "{}" });
    try pack.dir.createDirPath(io, "data/demo/function");
    try pack.dir.writeFile(io, .{ .sub_path = "data/demo/function/main.mcfunction", .data = "say hi\n" });

    var out = std.testing.tmpDir(.{});
    defer out.cleanup();
    try writeZip(io, arena.allocator(), pack.dir, out.dir, "demo.zip");

    var zip_file = try out.dir.openFile(io, "demo.zip", .{});
    defer zip_file.close(io);
    var buffer: [4096]u8 = undefined;
    var zip_reader = zip_file.reader(io, &buffer);

    var extracted = std.testing.tmpDir(.{});
    defer extracted.cleanup();
    try std.zip.extract(extracted.dir, &zip_reader, .{});

    const main_text = try extracted.dir.readFileAlloc(io, "data/demo/function/main.mcfunction", arena.allocator(), .unlimited);
    try std.testing.expectEqualStrings("say hi\n", main_text);
    const pack_mcmeta = try extracted.dir.readFileAlloc(io, "pack.mcmeta", arena.allocator(), .unlimited);
    try std.testing.expectEqualStrings("{}", pack_mcmeta);
}
