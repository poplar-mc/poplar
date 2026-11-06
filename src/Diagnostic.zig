//! An error in the user's files.

const std = @import("std");

/// `Reported` means that a diagnostic is already recorded, so the caller only has to stop what it is doing.
pub const Error = std.mem.Allocator.Error || error{Reported};

/// A place in a source file. Lines and columns start at 1.
pub const Position = struct {
    line: usize,
    column: usize,
};

path: []const u8,
/// Null when the error is not about one place in a file, such as a missing folder.
position: ?Position,
message: []const u8,

/// Ends the stop that `error.Reported` asked for, so that the next statement or declaration is checked.
pub fn recover(result: Error!void) std.mem.Allocator.Error!void {
    result catch |err| switch (err) {
        error.Reported => {},
        error.OutOfMemory => return error.OutOfMemory,
    };
}
