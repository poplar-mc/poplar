//! A `.env` file: `KEY=VALUE` lines, `#` comments, an optional `export ` and optional quotes around the value.
//! There is no variable expansion and no multi-line value.

const std = @import("std");

pub const file_name = ".env";

pub const Lookup = union(enum) {
    value: []const u8,
    missing,
    /// The 1-based number of a line that is not `KEY=VALUE`.
    invalid_line: usize,
};

/// The value of `key` in the `.env` file of the project folder. The last line with the key wins.
pub fn read(arena: std.mem.Allocator, io: std.Io, project_path: []const u8, key: []const u8) !Lookup {
    var project_dir = try std.Io.Dir.cwd().openDir(io, project_path, .{});
    defer project_dir.close(io);
    const text = project_dir.readFileAlloc(io, file_name, arena, .limited(1 << 20)) catch |err| switch (err) {
        error.FileNotFound => return .missing,
        else => return err,
    };
    return find(text, key);
}

pub fn find(text: []const u8, key: []const u8) Lookup {
    var result: Lookup = .missing;
    var lines = std.mem.splitScalar(u8, text, '\n');
    var line_number: usize = 0;
    while (lines.next()) |raw_line| {
        line_number += 1;
        var line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        if (std.mem.startsWith(u8, line, "export ")) line = line["export ".len..];

        const equals = std.mem.indexOfScalar(u8, line, '=') orelse return .{ .invalid_line = line_number };
        const line_key = std.mem.trim(u8, line[0..equals], " \t");
        if (line_key.len == 0) return .{ .invalid_line = line_number };
        if (std.mem.eql(u8, line_key, key)) result = .{ .value = unquote(std.mem.trim(u8, line[equals + 1 ..], " \t")) };
    }
    return result;
}

fn unquote(value: []const u8) []const u8 {
    if (value.len >= 2 and (value[0] == '"' or value[0] == '\'') and value[value.len - 1] == value[0]) return value[1 .. value.len - 1];
    return value;
}

test find {
    const text =
        \\# my world
        \\OTHER=1
        \\export POPLAR_WORLD = "/home/me/saves/My World"
        \\
    ;
    try std.testing.expectEqualStrings("/home/me/saves/My World", find(text, "POPLAR_WORLD").value);
    try std.testing.expectEqualStrings("1", find(text, "OTHER").value);
    try std.testing.expectEqual(Lookup.missing, find(text, "NONE"));
    try std.testing.expectEqual(Lookup{ .invalid_line = 2 }, find("A=1\nnot a pair\n", "A"));
}
