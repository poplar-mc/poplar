const std = @import("std");
const Diagnostic = @import("Diagnostic.zig");

const Config = @This();

const mcmeta_version_json = @embedFile("mcmeta_version.json");

pub const PackFormat = struct {
    major: u32,
    minor: u32 = 0,

    fn lessThan(a: PackFormat, b: PackFormat) bool {
        return a.major < b.major or (a.major == b.major and a.minor < b.minor);
    }
};

/// 1.21.9. Older versions also need the old `pack_format` and `supported_formats` fields in pack.mcmeta.
pub const oldest_format: PackFormat = .{ .major = 88 };

pub const file_name = "poplar.json";

pub const ParseError = error{InvalidConfig} || std.mem.Allocator.Error;

/// Where and why `poplar.json` is invalid.
pub const Problem = struct {
    position: ?Diagnostic.Position = null,
    message: []const u8 = "",
};

/// The name of the built pack: `poplar-out/<name>/` and `poplar-out/<name>.zip`.
zip_name: []const u8,
namespace: []const u8,
/// A JSON text component, already written as JSON.
description: []const u8,
min_format: PackFormat,
max_format: PackFormat,

/// The Minecraft version that the command data comes from.
const McmetaVersion = struct { name: []const u8, data_pack_version: u32, data_pack_version_minor: u32 };

fn mcmetaVersion(arena: std.mem.Allocator) !McmetaVersion {
    return std.json.parseFromSliceLeaky(McmetaVersion, arena, mcmeta_version_json, .{ .ignore_unknown_fields = true });
}

fn latestFormat(arena: std.mem.Allocator) !PackFormat {
    const version = try mcmetaVersion(arena);
    return .{ .major = version.data_pack_version, .minor = version.data_pack_version_minor };
}

pub fn minecraftVersion(arena: std.mem.Allocator) ![]const u8 {
    return (try mcmetaVersion(arena)).name;
}

/// Reads `poplar.json` from the project folder. A missing file gives the defaults.
pub fn load(arena: std.mem.Allocator, io: std.Io, project_dir: std.Io.Dir, folder_name: []const u8, problem: *Problem) !Config {
    const json = project_dir.readFileAlloc(io, file_name, arena, .unlimited) catch |err| switch (err) {
        error.FileNotFound => "{}",
        else => return err,
    };
    return parse(arena, json, folder_name, try latestFormat(arena), problem);
}

pub fn parse(arena: std.mem.Allocator, json: []const u8, folder_name: []const u8, latest: PackFormat, problem: *Problem) ParseError!Config {
    var reader: FieldReader = .{ .arena = arena, .scanner = .initCompleteInput(arena, json), .problem = problem };
    reader.scanner.enableDiagnostics(&reader.diagnostics);

    var zip_name: ?[]const u8 = null;
    var namespace: ?[]const u8 = null;
    var description: ?[]const u8 = null;
    var min_format: ?PackFormat = null;
    var max_format: ?PackFormat = null;

    if (try reader.next() != .object_begin) return reader.fail("poplar.json must be a JSON object", .{});
    while (true) {
        const field = switch (try reader.next()) {
            .object_end => break,
            .string, .allocated_string => |key| key,
            else => return reader.fail("expected a field name", .{}),
        };

        if (std.mem.eql(u8, field, "$schema")) {
            _ = try reader.readString(field);
        } else if (std.mem.eql(u8, field, "zipName")) {
            zip_name = try reader.readString(field);
        } else if (std.mem.eql(u8, field, "namespace")) {
            namespace = try reader.readString(field);
        } else if (std.mem.eql(u8, field, "description")) {
            description = try reader.readJson();
        } else if (std.mem.eql(u8, field, "minFormat")) {
            min_format = try reader.readFormat(field);
        } else if (std.mem.eql(u8, field, "maxFormat")) {
            max_format = try reader.readFormat(field);
        } else {
            return reader.fail("unknown field '{s}'. Fields: zipName, namespace, description, minFormat, maxFormat", .{field});
        }
    }

    const config: Config = .{
        .zip_name = zip_name orelse folder_name,
        .namespace = namespace orelse folder_name,
        .description = description orelse try std.json.Stringify.valueAlloc(arena, zip_name orelse folder_name, .{}),
        .min_format = min_format orelse latest,
        .max_format = max_format orelse min_format orelse latest,
    };
    return config.validate(arena, namespace != null, problem);
}

fn validate(config: Config, arena: std.mem.Allocator, has_namespace: bool, problem: *Problem) ParseError!Config {
    if (config.zip_name.len == 0 or std.mem.indexOfAny(u8, config.zip_name, "/\\") != null) {
        return failWithoutPosition(arena, problem, "\"zipName\" '{s}' must not be empty or contain '/' or '\\'", .{config.zip_name});
    }
    if (!isValidResourceName(config.namespace)) {
        if (has_namespace) {
            return failWithoutPosition(arena, problem, "\"namespace\" '{s}' must only use a-z, 0-9, '_', '.' and '-'", .{config.namespace});
        }
        return failWithoutPosition(arena, problem, "the project folder name '{s}' is not a valid namespace. Set \"namespace\" in poplar.json (a-z, 0-9, '_', '.' and '-')", .{config.namespace});
    }
    if (config.min_format.lessThan(oldest_format)) {
        return failWithoutPosition(arena, problem, "\"minFormat\" must be at least {d} (Minecraft 1.21.9)", .{oldest_format.major});
    }
    if (config.max_format.lessThan(config.min_format)) {
        return failWithoutPosition(arena, problem, "\"maxFormat\" must not be less than \"minFormat\"", .{});
    }
    return config;
}

pub fn isValidResourceName(name: []const u8) bool {
    if (name.len == 0) return false;

    for (name) |ch| {
        const is_valid = std.ascii.isLower(ch) or std.ascii.isDigit(ch) or ch == '_' or ch == '.' or ch == '-';
        if (!is_valid) return false;
    }
    return true;
}

fn failWithoutPosition(arena: std.mem.Allocator, problem: *Problem, comptime format: []const u8, args: anytype) ParseError {
    problem.* = .{ .message = try std.fmt.allocPrint(arena, format, args) };
    return error.InvalidConfig;
}

/// Reads the fields one token at a time, so that each problem has the line and column of its field.
const FieldReader = struct {
    arena: std.mem.Allocator,
    scanner: std.json.Scanner,
    diagnostics: std.json.Diagnostics = .{},
    problem: *Problem,

    fn next(reader: *FieldReader) ParseError!std.json.Token {
        return reader.scanner.nextAlloc(reader.arena, .alloc_if_needed) catch |err| switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            else => reader.fail("invalid JSON", .{}),
        };
    }

    fn readString(reader: *FieldReader, field: []const u8) ParseError![]const u8 {
        return switch (try reader.next()) {
            .string, .allocated_string => |text| text,
            else => reader.fail("\"{s}\" must be a string", .{field}),
        };
    }

    /// `121` or `[121, 0]`, the same as in pack.mcmeta.
    fn readFormat(reader: *FieldReader, field: []const u8) ParseError!PackFormat {
        switch (try reader.next()) {
            .number, .allocated_number => |number| return .{ .major = try reader.parseNumber(number, field) },
            .array_begin => {},
            else => return reader.fail("\"{s}\" must be a number or [major, minor]", .{field}),
        }

        var format: PackFormat = .{ .major = 0 };
        var count: usize = 0;
        while (true) : (count += 1) {
            const number = switch (try reader.next()) {
                .array_end => break,
                .number, .allocated_number => |number| try reader.parseNumber(number, field),
                else => return reader.fail("\"{s}\" must be [major, minor]", .{field}),
            };
            switch (count) {
                0 => format.major = number,
                1 => format.minor = number,
                else => return reader.fail("\"{s}\" must be [major, minor]", .{field}),
            }
        }
        if (count == 0) return reader.fail("\"{s}\" must be [major, minor]", .{field});
        return format;
    }

    fn parseNumber(reader: *FieldReader, number: []const u8, field: []const u8) ParseError!u32 {
        return std.fmt.parseInt(u32, number, 10) catch reader.fail("\"{s}\" must contain whole numbers", .{field});
    }

    /// Any JSON value, for example a text component. It is written to pack.mcmeta as it is.
    fn readJson(reader: *FieldReader) ParseError![]const u8 {
        const value = std.json.Value.jsonParse(reader.arena, &reader.scanner, .{ .max_value_len = std.json.default_max_value_len }) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return reader.fail("invalid JSON", .{}),
        };
        return std.json.Stringify.valueAlloc(reader.arena, value, .{});
    }

    fn fail(reader: *FieldReader, comptime format: []const u8, args: anytype) ParseError {
        reader.problem.* = .{
            .position = .{ .line = reader.diagnostics.getLine(), .column = reader.diagnostics.getColumn() },
            .message = try std.fmt.allocPrint(reader.arena, format, args),
        };
        return error.InvalidConfig;
    }
};

test "parses poplar.json" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const latest: PackFormat = .{ .major = 121 };
    var problem: Problem = .{};

    const defaults = try parse(arena.allocator(), "{}", "hello", latest, &problem);
    try std.testing.expectEqualStrings("hello", defaults.namespace);
    try std.testing.expectEqualStrings("\"hello\"", defaults.description);
    try std.testing.expectEqual(121, defaults.max_format.major);

    const full = try parse(arena.allocator(),
        \\{
        \\  "$schema": "https://example.com/poplar.schema.json",
        \\  "zipName": "My Pack",
        \\  "namespace": "demo",
        \\  "description": {"text": "Hi", "color": "green"},
        \\  "minFormat": [101, 1],
        \\  "maxFormat": 121
        \\}
    , "hello", latest, &problem);
    try std.testing.expectEqualStrings("My Pack", full.zip_name);
    try std.testing.expectEqualStrings("{\"text\":\"Hi\",\"color\":\"green\"}", full.description);
    try std.testing.expectEqual(1, full.min_format.minor);

    try std.testing.expectError(error.InvalidConfig, parse(arena.allocator(), "{\"zip\": true}", "hello", latest, &problem));
    try std.testing.expect(std.mem.startsWith(u8, problem.message, "unknown field 'zip'"));

    try std.testing.expectError(error.InvalidConfig, parse(arena.allocator(), "{\n  \"nmae\": \"x\"\n}", "hello", latest, &problem));
    try std.testing.expectEqual(2, problem.position.?.line);
    try std.testing.expect(std.mem.startsWith(u8, problem.message, "unknown field 'nmae'"));

    try std.testing.expectError(error.InvalidConfig, parse(arena.allocator(), "{\"minFormat\": 80}", "hello", latest, &problem));
    try std.testing.expectError(error.InvalidConfig, parse(arena.allocator(), "{\"minFormat\": 121, \"maxFormat\": 101}", "hello", latest, &problem));
}
