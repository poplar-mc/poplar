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

    pub const Entry = struct {
        key: []const u8,
        value: Value,
    };
};

/// A local is a global with a generated name: `#i_countdown` for a score, `i_countdown` in `<ns>:data` for data.
pub const Local = struct {
    pub const Kind = enum { score, data };

    kind: Kind,
    generated_name: []const u8,
    /// The mcfun that the local belongs to.
    owner: []const u8,
};

pub const AssignResult = enum { assigned, not_found, crosses_runtime_branch };

store: std.StringHashMapUnmanaged(Value) = .empty,
score_locals: std.StringHashMapUnmanaged(Local) = .empty,
data_locals: std.StringHashMapUnmanaged(Local) = .empty,
outer: ?*Environment = null,
/// True for the scope of a runtime `if` body. Compile-time vars from outside it cannot change.
runtime_branch: bool = false,

pub fn get(self: *const Environment, name: []const u8) ?Value {
    if (self.store.get(name)) |value| return value;
    if (self.outer) |outer| return outer.get(name);
    return null;
}

/// Returns false if the name is already visible, so names cannot be shadowed.
pub fn declare(self: *Environment, arena: std.mem.Allocator, name: []const u8, value: Value) std.mem.Allocator.Error!bool {
    if (self.get(name) != null) return false;

    try self.store.put(arena, name, value);
    return true;
}

/// The local `#name` or `$name` that is visible here.
pub fn getLocal(self: *const Environment, kind: Local.Kind, name: []const u8) ?Local {
    const locals = if (kind == .score) self.score_locals else self.data_locals;
    if (locals.get(name)) |local| return local;
    if (self.outer) |outer| return outer.getLocal(kind, name);
    return null;
}

pub fn declareLocal(self: *Environment, arena: std.mem.Allocator, name: []const u8, local: Local) std.mem.Allocator.Error!void {
    const locals = if (local.kind == .score) &self.score_locals else &self.data_locals;
    try locals.put(arena, name, local);
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
