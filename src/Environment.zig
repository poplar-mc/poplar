const std = @import("std");
const ast = @import("ast.zig");

const Environment = @This();

pub const Value = union(enum) {
    string: []const u8,
    number: i64,
    typed_number: ast.TypedNumber,
    boolean: bool,
    null,
    list: []const Value,
    compound: []const Entry,
    // A `#` or `$` variable declared in a function body. Its key in the environment has the sigil: `#i`.
    local: Local,

    pub const Entry = struct {
        key: []const u8,
        value: Value,
    };
};

// A local is a global with a generated name: `#i_countdown` for a score, `i_countdown` in `<ns>:data` for data.
pub const Local = struct {
    pub const Kind = enum { score, data };

    kind: Kind,
    generated_name: []const u8,
    // The mcfun that the local belongs to.
    owner: []const u8,
};

pub const AssignResult = enum { assigned, not_found, crosses_runtime_branch };

store: std.StringHashMapUnmanaged(Value) = .empty,
outer: ?*Environment = null,
// True for the scope of a runtime `if` body. Compile-time vars from outside it cannot change.
runtime_branch: bool = false,

pub fn get(self: *const Environment, name: []const u8) ?Value {
    if (self.store.get(name)) |value| return value;
    if (self.outer) |outer| return outer.get(name);
    return null;
}

// Returns false if the name is already visible, so names cannot be shadowed.
pub fn declare(self: *Environment, gpa: std.mem.Allocator, name: []const u8, value: Value) std.mem.Allocator.Error!bool {
    if (self.get(name) != null) return false;

    try self.store.put(gpa, name, value);
    return true;
}

pub fn assign(self: *Environment, name: []const u8, value: Value) AssignResult {
    if (self.store.getPtr(name)) |slot| {
        slot.* = value;
        return .assigned;
    }

    const outer = self.outer orelse return .not_found;
    if (self.runtime_branch and outer.get(name) != null) return .crosses_runtime_branch;
    return outer.assign(name, value);
}
