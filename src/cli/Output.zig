// Lines for people: a green ✓ or a red ✗ at the start, and dim details. There are colors only in a terminal,
// and not when NO_COLOR is set (https://no-color.org).
const std = @import("std");
const Project = @import("../Project.zig");

const Self = @This();

writer: *std.Io.Writer,
color: bool,

pub fn bold(self: Self) []const u8 {
    return if (self.color) "\x1b[1m" else "";
}

pub fn dim(self: Self) []const u8 {
    return if (self.color) "\x1b[2m" else "";
}

pub fn reset(self: Self) []const u8 {
    return if (self.color) "\x1b[0m" else "";
}

fn green(self: Self) []const u8 {
    return if (self.color) "\x1b[32m" else "";
}

fn red(self: Self) []const u8 {
    return if (self.color) "\x1b[31m" else "";
}

fn yellow(self: Self) []const u8 {
    return if (self.color) "\x1b[33m" else "";
}

pub fn success(self: Self, comptime format: []const u8, args: anytype) std.Io.Writer.Error!void {
    try self.writer.print("{s}✓{s} " ++ format ++ "\n", .{ self.green(), self.reset() } ++ args);
}

// Failures go to stderr, so they still show when the normal output is piped somewhere.
pub fn failure(self: Self, comptime format: []const u8, args: anytype) void {
    self.writer.flush() catch {};
    std.debug.print("{s}✗{s} " ++ format ++ "\n", .{ self.red(), self.reset() } ++ args);
}

// Something that works, but likely not as the user wants. It goes to stderr, like a failure.
pub fn warning(self: Self, comptime format: []const u8, args: anytype) void {
    self.writer.flush() catch {};
    std.debug.print("{s}!{s} " ++ format ++ "\n", .{ self.yellow(), self.reset() } ++ args);
}

// `✗ src/main.poplar:3:5  Message`, or the message alone when it has no position.
pub fn diagnostics(self: Self, list: []const Project.Diagnostic) void {
    for (list) |diagnostic| {
        const message: Capitalized = .{ .text = diagnostic.message };
        if (diagnostic.line == 0) {
            if (diagnostic.path.len == 0) {
                self.failure("{f}", .{message});
            } else {
                self.failure("{s}{s}{s}  {f}", .{ self.bold(), diagnostic.path, self.reset(), message });
            }
        } else if (diagnostic.column) |column| {
            self.failure("{s}{s}:{d}:{d}{s}  {f}", .{ self.bold(), diagnostic.path, diagnostic.line, column, self.reset(), message });
        } else {
            self.failure("{s}{s}:{d}{s}  {f}", .{ self.bold(), diagnostic.path, diagnostic.line, self.reset(), message });
        }
    }
}

// The compiler's messages start in lowercase, which the language server shows as it is. On the command line
// each line starts with a capital letter.
const Capitalized = struct {
    text: []const u8,

    pub fn format(self: Capitalized, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        if (self.text.len == 0) return;
        try writer.writeByte(std.ascii.toUpper(self.text[0]));
        try writer.writeAll(self.text[1..]);
    }
};

// `✗ 2 errors, nothing was written`
pub fn errorCount(self: Self, count: usize, rest: []const u8) void {
    self.failure("{d} error{s}{s}", .{ count, if (count == 1) "" else "s", rest });
}
