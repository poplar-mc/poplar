//! Build-time values: evaluating constant expressions, and writing values as text or SNBT.

const std = @import("std");
const Compiler = @import("../Compiler.zig");
const ast = @import("../ast.zig");
const Environment = @import("../Environment.zig");
const calls = @import("calls.zig");
const data = @import("data.zig");

pub fn containsRuntimeValue(expression: *const ast.Expression) bool {
    return switch (expression.kind) {
        .identifier => |identifier| identifier.kind != .compile_time,
        .minecraft_check, .macro_key => true,
        .prefix => |prefix| containsRuntimeValue(prefix.operand),
        .infix => |infix| containsRuntimeValue(infix.left) or containsRuntimeValue(infix.right),
        .list => |elements| for (elements) |element| {
            if (containsRuntimeValue(element)) break true;
        } else false,
        .compound => |entries| for (entries) |entry| {
            if (containsRuntimeValue(entry.value)) break true;
        } else false,
        // An mcfun runs in the game. `text(#hp)` only names the score, so it is known when the pack is built.
        .call => |call| {
            if (calls.isBuiltinCall(call, "text")) return false;
            if (!calls.isBuiltinCall(call, "len") and !data.isStringCall(call) and !data.isStringTest(call)) return true;
            for (call.args) |arg| {
                if (containsRuntimeValue(arg)) return true;
            }
            return false;
        },
        else => false,
    };
}

/// `text(x)` and `len(x)` on a compile-time value are known when the pack is built.
fn evaluateCall(compiler: *Compiler, call: ast.Call, env: *Environment) Compiler.Error!Compiler.Value {
    if (call.callee.kind != .identifier) {
        return compiler.fail("only named functions can be called", .{});
    }
    const identifier = call.callee.kind.identifier;
    const name = identifier.name;
    if (calls.isBuiltinCall(call, "text")) {
        if (call.args.len != 1) {
            return compiler.fail("'text' expects 1 argument, found {d}", .{call.args.len});
        }
        return data.textComponent(compiler, call.args[0], env);
    }
    if (data.isStringCall(call) or data.isStringTest(call)) return data.evaluateStringCall(compiler, call, env);
    if (calls.isBuiltinCall(call, "len") and call.args.len == 1) {
        const value = try evaluate(compiler, call.args[0], env);
        switch (value) {
            .list => |elements| return .{ .number = @intCast(elements.len) },
            .compound => |entries| return .{ .number = @intCast(entries.len) },
            // The game counts UTF-16 units.
            .string => |text| return .{ .number = @intCast(std.unicode.calcUtf16LeLen(text) catch text.len) },
            else => {},
        }
    }
    if (try calls.calledKey(compiler, identifier) != null) {
        return compiler.fail("mcfun '{s}' runs in the game, so its result is not known when the pack is built", .{name});
    }
    if (identifier.namespace == null and calls.isBuiltin(name)) {
        return compiler.fail("'{s}' changes data in the game, so it has no build-time value", .{name});
    }
    return compiler.fail("unknown function '{s}'", .{name});
}

pub fn evaluate(compiler: *Compiler, expression: *const ast.Expression, env: *Environment) Compiler.Error!Compiler.Value {
    const outer_position = compiler.enterExpression(expression);
    defer compiler.restorePosition(outer_position);
    return switch (expression.kind) {
        .minecraft_check => {
            return compiler.fail("a Minecraft check such as 'block ~ ~ ~ stone' only works as an 'if' or 'while' condition", .{});
        },
        .macro_key => |name| {
            return compiler.fail(
                "'$({s})' is a macro argument, known only when the call starts, so it cannot be used at compile time",
                .{name},
            );
        },
        .string => |text| .{ .string = text },
        .number => |number| .{ .number = number },
        .typed_number => |number| .{ .typed_number = number },
        .boolean => |boolean| .{ .boolean = boolean },
        .null => .null,
        .identifier => |identifier| {
            switch (identifier.kind) {
                .compile_time => {},
                .score => {
                    return compiler.fail("score '#{s}' cannot be used here", .{identifier.name});
                },
                .data => {
                    return compiler.fail("data '${s}' cannot be used here", .{identifier.name});
                },
                .entity_data => {
                    return compiler.fail("entity data '{s}.${s}' cannot be used here", .{ identifier.selector.?, identifier.name });
                },
            }

            const value = env.get(identifier.name) orelse {
                return compiler.fail("unknown name '{s}'", .{identifier.name});
            };
            return value;
        },
        .prefix => |prefix| evaluatePrefix(compiler, prefix, env),
        .infix => |infix| evaluateInfix(compiler, infix, env),
        .call => |call| evaluateCall(compiler, call, env),
        .selector => |text| {
            if (try compiler.command_tree.checkSelector(compiler.arena, text)) |failure| {
                return compiler.fail("{s}", .{failure.message});
            }
            return .{ .string = text };
        },
        .list => |elements| {
            const values = try compiler.arena.alloc(Compiler.Value, elements.len);
            for (elements, values) |element, *value| value.* = try evaluate(compiler, element, env);
            return .{ .list = values };
        },
        .compound => |entries| {
            const values = try compiler.arena.alloc(Compiler.Value.Entry, entries.len);
            for (entries, values, 0..) |entry, *value, index| {
                for (entries[0..index]) |earlier| {
                    if (std.mem.eql(u8, earlier.key, entry.key)) {
                        return compiler.fail("key '{s}' is used more than once", .{entry.key});
                    }
                }
                value.* = .{ .key = entry.key, .value = try evaluate(compiler, entry.value, env) };
            }
            return .{ .compound = values };
        },
    };
}

fn evaluatePrefix(compiler: *Compiler, prefix: ast.Prefix, env: *Environment) Compiler.Error!Compiler.Value {
    const operand = try evaluate(compiler, prefix.operand, env);

    if (prefix.op == .negate and operand == .number) return checkedNumber(compiler, std.math.sub(i64, 0, operand.number));
    if (prefix.op == .negate and operand == .typed_number) {
        const text = operand.typed_number.text;
        const negated = if (text[0] == '-') text[1..] else try std.fmt.allocPrint(compiler.arena, "-{s}", .{text});
        return .{ .typed_number = .{ .text = negated, .type = operand.typed_number.type } };
    }
    if (prefix.op == .not and operand == .boolean) return .{ .boolean = !operand.boolean };

    return compiler.fail("operator '{s}' cannot be used with {s}", .{ prefixOperatorText(prefix.op), @tagName(operand) });
}

fn evaluateInfix(compiler: *Compiler, infix: ast.Infix, env: *Environment) Compiler.Error!Compiler.Value {
    const left = try evaluate(compiler, infix.left, env);
    const right = try evaluate(compiler, infix.right, env);

    if (infix.op == .add and (left == .string or right == .string)) {
        const text = try std.fmt.allocPrint(
            compiler.arena,
            "{s}{s}",
            .{ try valueToText(compiler, left), try valueToText(compiler, right) },
        );
        return .{ .string = text };
    }

    if (left == .number and right == .number) {
        const a = left.number;
        const b = right.number;

        switch (infix.op) {
            .add => return checkedNumber(compiler, std.math.add(i64, a, b)),
            .subtract => return checkedNumber(compiler, std.math.sub(i64, a, b)),
            .multiply => return checkedNumber(compiler, std.math.mul(i64, a, b)),
            .divide => return checkedNumber(compiler, std.math.divFloor(i64, a, b)),
            .modulo => return checkedNumber(compiler, floorMod(a, b)),
            .less => return .{ .boolean = a < b },
            .less_equal => return .{ .boolean = a <= b },
            .greater => return .{ .boolean = a > b },
            .greater_equal => return .{ .boolean = a >= b },
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

    if ((infix.op == .equal or infix.op == .not_equal) and std.meta.activeTag(left) == std.meta.activeTag(right)) {
        const is_equal = valuesEqual(left, right);
        return .{ .boolean = if (infix.op == .equal) is_equal else !is_equal };
    }

    if (left == .typed_number or right == .typed_number) {
        return compiler.fail(
            "build-time math only works on whole numbers with no suffix, so '{s}' cannot be used here",
            .{infixOperatorText(infix.op)},
        );
    }
    return compiler.fail("operator '{s}' cannot be used with {s} and {s}", .{
        infixOperatorText(infix.op),
        @tagName(left),
        @tagName(right),
    });
}

fn checkedNumber(compiler: *Compiler, result: error{ Overflow, DivisionByZero }!i64) Compiler.Error!Compiler.Value {
    const number = result catch |err| switch (err) {
        error.Overflow => {
            return compiler.fail("integer overflow", .{});
        },
        error.DivisionByZero => {
            return compiler.fail("division by zero", .{});
        },
    };
    return .{ .number = number };
}

/// Same result as Java's Math.floorMod, which Minecraft uses for `%=`.
fn floorMod(a: i64, b: i64) error{DivisionByZero}!i64 {
    if (b == 0) return error.DivisionByZero;
    if (b == -1) return 0;

    const remainder = @rem(a, b);
    return if (remainder != 0 and (remainder < 0) != (b < 0)) remainder + b else remainder;
}

fn valuesEqual(left: Compiler.Value, right: Compiler.Value) bool {
    return switch (left) {
        .string => |text| std.mem.eql(u8, text, right.string),
        .number => |number| number == right.number,
        .typed_number => |number| number.type == right.typed_number.type and std.mem.eql(u8, number.text, right.typed_number.text),
        .boolean => |boolean| boolean == right.boolean,
        .null => true,
        .list => |elements| elements.len == right.list.len and for (elements, right.list) |element, other| {
            if (std.meta.activeTag(element) != std.meta.activeTag(other) or !valuesEqual(element, other)) break false;
        } else true,
        .compound => |entries| entries.len == right.compound.len and for (entries, right.compound) |entry, other| {
            if (!std.mem.eql(u8, entry.key, other.key) or std.meta.activeTag(entry.value) != std.meta.activeTag(other.value) or !valuesEqual(entry.value, other.value)) break false;
        } else true,
    };
}

pub fn prefixOperatorText(op: ast.Prefix.Operator) []const u8 {
    return switch (op) {
        .negate => "-",
        .not => "!",
    };
}

pub fn infixOperatorText(op: ast.Infix.Operator) []const u8 {
    return switch (op) {
        .add => "+",
        .subtract => "-",
        .multiply => "*",
        .divide => "/",
        .modulo => "%",
        .equal => "==",
        .not_equal => "!=",
        .less => "<",
        .less_equal => "<=",
        .greater => ">",
        .greater_equal => ">=",
        .@"and" => "and",
        .@"or" => "or",
    };
}

pub fn valueToText(compiler: *Compiler, value: Compiler.Value) std.mem.Allocator.Error![]const u8 {
    return switch (value) {
        .string => |text| text,
        .number => |number| try std.fmt.allocPrint(compiler.arena, "{d}", .{number}),
        .typed_number => |number| try typedNumberSnbt(compiler, number),
        .boolean => |boolean| if (boolean) "true" else "false",
        .null => "null",
        .list, .compound => valueToSnbt(compiler, value),
    };
}

/// `0.05f`: the number as written, with the suffix of its type. A plain decimal has none, so it is a double.
fn typedNumberSnbt(compiler: *Compiler, number: ast.TypedNumber) std.mem.Allocator.Error![]const u8 {
    const suffix = if (number.type) |number_type| number_type.suffix() else "";
    return std.mem.concat(compiler.arena, u8, &.{ number.text, suffix });
}

/// A key is written as it is when it is a plain name, else in quotes.
pub fn snbtKey(compiler: *Compiler, key: []const u8) std.mem.Allocator.Error![]const u8 {
    for (key) |ch| {
        if (!std.ascii.isAlphanumeric(ch) and ch != '_' and ch != '-' and ch != '.' and ch != '+') return valueToSnbt(
            compiler,
            .{ .string = key },
        );
    }
    return if (key.len == 0) "\"\"" else key;
}

pub fn valueToSnbt(compiler: *Compiler, value: Compiler.Value) std.mem.Allocator.Error![]const u8 {
    switch (value) {
        .list => |elements| {
            var snbt: std.ArrayList(u8) = .empty;
            try snbt.append(compiler.arena, '[');
            for (elements, 0..) |element, index| {
                if (index > 0) try snbt.append(compiler.arena, ',');
                try snbt.appendSlice(compiler.arena, try valueToSnbt(compiler, element));
            }
            try snbt.append(compiler.arena, ']');
            return snbt.toOwnedSlice(compiler.arena);
        },
        .compound => |entries| {
            var snbt: std.ArrayList(u8) = .empty;
            try snbt.append(compiler.arena, '{');
            for (entries, 0..) |entry, index| {
                if (index > 0) try snbt.append(compiler.arena, ',');
                try snbt.print(compiler.arena, "{s}:{s}", .{ try snbtKey(compiler, entry.key), try valueToSnbt(compiler, entry.value) });
            }
            try snbt.append(compiler.arena, '}');
            return snbt.toOwnedSlice(compiler.arena);
        },
        .string => |text| {
            var snbt: std.ArrayList(u8) = .empty;
            try snbt.append(compiler.arena, '"');
            for (text) |ch| {
                if (ch == '"' or ch == '\\') try snbt.append(compiler.arena, '\\');
                try snbt.append(compiler.arena, ch);
            }
            try snbt.append(compiler.arena, '"');
            return snbt.toOwnedSlice(compiler.arena);
        },
        else => return valueToText(compiler, value),
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
