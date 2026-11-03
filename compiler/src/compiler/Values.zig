// Build-time values: evaluating constant expressions, and writing values as text or SNBT.
const std = @import("std");
const Compiler = @import("../Compiler.zig");
const Ast = @import("../Ast.zig");
const Environment = @import("../Environment.zig");
const Token = @import("../Token.zig");
const Calls = @import("Calls.zig");
const Data = @import("Data.zig");

pub fn containsRuntimeValue(self: *const Compiler, expression: *const Ast.Expr, env: *const Environment) bool {
    return switch (expression.kind) {
        .identifier => |identifier| identifier.storage != .compile_time or isParam(expression, env),
        .minecraft_check => true,
        .prefix => |prefix| containsRuntimeValue(self, prefix.operand, env),
        .infix => |infix| containsRuntimeValue(self, infix.left, env) or containsRuntimeValue(self, infix.right, env),
        .cast => |cast| containsRuntimeValue(self, cast.value, env),
        .list => |elements| for (elements) |element| {
            if (containsRuntimeValue(self, element, env)) break true;
        } else false,
        .compound => |entries| for (entries) |entry| {
            if (containsRuntimeValue(self, entry.value, env)) break true;
        } else false,
        // An mcfun runs in the game. `text(#hp)` only names the score, so it is known when the pack is built.
        .call => |call| {
            if (Calls.isBuiltinCall(call, "text")) return false;
            if (!Calls.isBuiltinCall(call, "len") and !Data.isStringCall(call) and !Data.isStringTest(call)) return true;
            for (call.args) |arg| {
                if (containsRuntimeValue(self, arg, env)) return true;
            }
            return false;
        },
        else => false,
    };
}

pub fn isParam(expression: *const Ast.Expr, env: *const Environment) bool {
    if (expression.kind != .identifier or expression.kind.identifier.storage != .compile_time) return false;
    const value = env.get(expression.kind.identifier.name) orelse return false;
    return value == .param;
}

// `text(x)` and `len(x)` on a compile-time value are known when the pack is built.
pub fn evaluateCall(self: *Compiler, call: Ast.Call, env: *Environment) Compiler.CompileError!?Compiler.Value {
    if (call.callee.kind != .identifier) {
        try self.addError("only named functions can be called", .{});
        return null;
    }
    const name = call.callee.kind.identifier.name;
    if (Calls.isBuiltinCall(call, "text")) {
        if (call.args.len != 1) {
            try self.addError("'text' expects 1 argument, found {d}", .{call.args.len});
            return null;
        }
        return Data.textComponent(self, call.args[0], env);
    }
    if (Data.isStringCall(call) or Data.isStringTest(call)) return Data.evaluateStringCall(self, call, env);
    if (Calls.isBuiltinCall(call, "len") and call.args.len == 1) {
        const value = try evaluate(self, call.args[0], env) orelse return null;
        switch (value) {
            .list => |elements| return .{ .number = @intCast(elements.len) },
            .compound => |entries| return .{ .number = @intCast(entries.len) },
            .string => |text| return .{ .number = @intCast(std.unicode.utf8CountCodepoints(text) catch text.len) },
            else => {},
        }
    }
    if (self.functions.contains(name)) {
        try self.addError("mcfun '{s}' runs in the game, so its result is not known when the pack is built", .{name});
    } else if (Calls.isBuiltin(name)) {
        try self.addError("'{s}' changes data in the game, so it has no build-time value", .{name});
    } else {
        try self.addError("unknown function '{s}'", .{name});
    }
    return null;
}

pub const cast_error = "'as' sets the NBT type of a value that is stored in data: '$x = ... as float;' or '@s.$path = ... as float;'";

pub fn evaluate(self: *Compiler, expression: *const Ast.Expr, env: *Environment) Compiler.CompileError!?Compiler.Value {
    const outer_position = self.enterExpression(expression);
    defer self.restorePosition(outer_position);
    return switch (expression.kind) {
        .cast => {
            try self.addError(cast_error, .{});
            return null;
        },
        .minecraft_check => {
            try self.addError("a Minecraft check such as 'block ~ ~ ~ stone' only works as an 'if' or 'while' condition", .{});
            return null;
        },
        .string => |text| .{ .string = text },
        .number => |number| .{ .number = number },
        .boolean => |boolean| .{ .boolean = boolean },
        .null => .null,
        .identifier => |identifier| {
            switch (identifier.storage) {
                .compile_time => {},
                .score => {
                    try self.addError("score '#{s}' cannot be used here", .{identifier.name});
                    return null;
                },
                .data => {
                    try self.addError("data '${s}' cannot be used here", .{identifier.name});
                    return null;
                },
                .entity_data => {
                    try self.addError("entity data '{s}.${s}' cannot be used here", .{ identifier.selector.?, identifier.name });
                    return null;
                },
            }

            const value = env.get(identifier.name) orelse {
                try self.addError("unknown name '{s}'", .{identifier.name});
                return null;
            };
            if (value == .param) {
                try self.addError("parameter '{s}' is a runtime value and cannot be used at compile time", .{identifier.name});
                return null;
            }
            return value;
        },
        .prefix => |prefix| evaluatePrefix(self, prefix, env),
        .infix => |infix| evaluateInfix(self, infix, env),
        .call => |call| evaluateCall(self, call, env),
        .selector => |text| .{ .string = text },
        .list => |elements| {
            const values = try self.gpa.alloc(Compiler.Value, elements.len);
            for (elements, values) |element, *value| value.* = try evaluate(self, element, env) orelse return null;
            return .{ .list = values };
        },
        .compound => |entries| {
            const values = try self.gpa.alloc(Compiler.Value.Entry, entries.len);
            for (entries, values, 0..) |entry, *value, index| {
                for (entries[0..index]) |earlier| {
                    if (std.mem.eql(u8, earlier.key, entry.key)) {
                        try self.addError("key '{s}' is used more than once", .{entry.key});
                        return null;
                    }
                }
                value.* = .{ .key = entry.key, .value = try evaluate(self, entry.value, env) orelse return null };
            }
            return .{ .compound = values };
        },
    };
}

pub fn evaluatePrefix(self: *Compiler, prefix: Ast.Prefix, env: *Environment) Compiler.CompileError!?Compiler.Value {
    const operand = try evaluate(self, prefix.operand, env) orelse return null;

    if (prefix.op == .minus and operand == .number) return checkedNumber(self, std.math.sub(i64, 0, operand.number));
    if (prefix.op == .bang and operand == .boolean) return .{ .boolean = !operand.boolean };

    try self.addError("operator '{s}' cannot be used with {s}", .{ operatorText(prefix.op), @tagName(operand) });
    return null;
}

pub fn evaluateInfix(self: *Compiler, infix: Ast.Infix, env: *Environment) Compiler.CompileError!?Compiler.Value {
    const left = try evaluate(self, infix.left, env) orelse return null;
    const right = try evaluate(self, infix.right, env) orelse return null;

    if (infix.op == .plus and (left == .string or right == .string)) {
        const text = try std.fmt.allocPrint(self.gpa, "{s}{s}", .{ try valueToText(self, left), try valueToText(self, right) });
        return .{ .string = text };
    }

    if (left == .number and right == .number) {
        const a = left.number;
        const b = right.number;

        switch (infix.op) {
            .plus => return checkedNumber(self, std.math.add(i64, a, b)),
            .minus => return checkedNumber(self, std.math.sub(i64, a, b)),
            .star => return checkedNumber(self, std.math.mul(i64, a, b)),
            .slash => return checkedNumber(self, std.math.divFloor(i64, a, b)),
            .percent => return checkedNumber(self, floorMod(a, b)),
            .less => return .{ .boolean = a < b },
            .less_eql => return .{ .boolean = a <= b },
            .greater => return .{ .boolean = a > b },
            .greater_eql => return .{ .boolean = a >= b },
            else => {},
        }
    }

    if (left == .boolean and right == .boolean) {
        switch (infix.op) {
            .@"and" => return .{ .boolean = left.boolean and right.boolean },
            .@"or" => return .{ .boolean = left.boolean or right.boolean },
            else => {},
        }
    }

    if ((infix.op == .eql_eql or infix.op == .bang_eql) and std.meta.activeTag(left) == std.meta.activeTag(right)) {
        const is_equal = valuesEqual(left, right);
        return .{ .boolean = if (infix.op == .eql_eql) is_equal else !is_equal };
    }

    try self.addError("operator '{s}' cannot be used with {s} and {s}", .{
        operatorText(infix.op),
        @tagName(left),
        @tagName(right),
    });
    return null;
}

pub fn checkedNumber(self: *Compiler, result: error{ Overflow, DivisionByZero }!i64) Compiler.CompileError!?Compiler.Value {
    const number = result catch |err| switch (err) {
        error.Overflow => {
            try self.addError("integer overflow", .{});
            return null;
        },
        error.DivisionByZero => {
            try self.addError("division by zero", .{});
            return null;
        },
    };
    return .{ .number = number };
}

// Same result as Java's Math.floorMod, which Minecraft uses for `%=`.
pub fn floorMod(a: i64, b: i64) error{DivisionByZero}!i64 {
    if (b == 0) return error.DivisionByZero;
    if (b == -1) return 0;

    const remainder = @rem(a, b);
    return if (remainder != 0 and (remainder < 0) != (b < 0)) remainder + b else remainder;
}

pub fn valuesEqual(left: Compiler.Value, right: Compiler.Value) bool {
    return switch (left) {
        .string => |text| std.mem.eql(u8, text, right.string),
        .number => |number| number == right.number,
        .boolean => |boolean| boolean == right.boolean,
        .null => true,
        .list => |elements| elements.len == right.list.len and for (elements, right.list) |element, other| {
            if (std.meta.activeTag(element) != std.meta.activeTag(other) or !valuesEqual(element, other)) break false;
        } else true,
        .compound => |entries| entries.len == right.compound.len and for (entries, right.compound) |entry, other| {
            if (!std.mem.eql(u8, entry.key, other.key) or std.meta.activeTag(entry.value) != std.meta.activeTag(other.value) or !valuesEqual(entry.value, other.value)) break false;
        } else true,
        .param, .local => unreachable, // `evaluate` never returns a parameter or a local.
    };
}

pub fn operatorText(op: Token.TokenType) []const u8 {
    return switch (op) {
        .plus => "+",
        .minus => "-",
        .star => "*",
        .slash => "/",
        .percent => "%",
        .bang => "!",
        .less => "<",
        .less_eql => "<=",
        .greater => ">",
        .greater_eql => ">=",
        .eql_eql => "==",
        .bang_eql => "!=",
        .@"and" => "and",
        .@"or" => "or",
        else => @tagName(op),
    };
}

pub fn valueToText(self: *Compiler, value: Compiler.Value) Compiler.CompileError![]const u8 {
    return switch (value) {
        .string => |text| text,
        .number => |number| try std.fmt.allocPrint(self.gpa, "{d}", .{number}),
        .boolean => |boolean| if (boolean) "true" else "false",
        .null => "null",
        .list, .compound => valueToSnbt(self, value),
        .param, .local => unreachable, // `evaluate` never returns a parameter or a local.
    };
}

// A key is written as it is when it is a plain name, else in quotes.
pub fn snbtKey(self: *Compiler, key: []const u8) Compiler.CompileError![]const u8 {
    for (key) |ch| {
        if (!std.ascii.isAlphanumeric(ch) and ch != '_' and ch != '-' and ch != '.' and ch != '+') return valueToSnbt(self, .{ .string = key });
    }
    return if (key.len == 0) "\"\"" else key;
}

pub fn valueToSnbt(self: *Compiler, value: Compiler.Value) Compiler.CompileError![]const u8 {
    switch (value) {
        .list => |elements| {
            var snbt: std.ArrayList(u8) = .empty;
            try snbt.append(self.gpa, '[');
            for (elements, 0..) |element, index| {
                if (index > 0) try snbt.append(self.gpa, ',');
                try snbt.appendSlice(self.gpa, try valueToSnbt(self, element));
            }
            try snbt.append(self.gpa, ']');
            return snbt.toOwnedSlice(self.gpa);
        },
        .compound => |entries| {
            var snbt: std.ArrayList(u8) = .empty;
            try snbt.append(self.gpa, '{');
            for (entries, 0..) |entry, index| {
                if (index > 0) try snbt.append(self.gpa, ',');
                try snbt.print(self.gpa, "{s}:{s}", .{ try snbtKey(self, entry.key), try valueToSnbt(self, entry.value) });
            }
            try snbt.append(self.gpa, '}');
            return snbt.toOwnedSlice(self.gpa);
        },
        .string => |text| {
            var snbt: std.ArrayList(u8) = .empty;
            try snbt.append(self.gpa, '"');
            for (text) |ch| {
                if (ch == '"' or ch == '\\') try snbt.append(self.gpa, '\\');
                try snbt.append(self.gpa, ch);
            }
            try snbt.append(self.gpa, '"');
            return snbt.toOwnedSlice(self.gpa);
        },
        else => return valueToText(self, value),
    }
}

test "unrolls for with string concatenation" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    var compiler = try Compiler.compileForTest(arena.allocator(),
        \\mcfun main() { for (0..3) |i| { /say {{"step " + i}}; } }
    );
    const commands = (try compiler.compile()).functions[0].commands;

    try std.testing.expectEqual(0, compiler.errors.items.len);
    try std.testing.expectEqual(3, commands.len);
    try std.testing.expectEqualStrings("say step 0", commands[0].raw);
    try std.testing.expectEqualStrings("say step 2", commands[2].raw);
}

test "folds compile-time if" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    var compiler = try Compiler.compileForTest(arena.allocator(),
        \\mcfun main() { for (0..4) |i| { if (i % 2 == 0) { /say {{i}}; } } }
    );
    const program = try compiler.compile();
    try std.testing.expectEqual(0, compiler.errors.items.len);

    try std.testing.expectEqualStrings("say 0\nsay 2\n", try Compiler.renderForTest(arena.allocator(), program, "main"));
}
