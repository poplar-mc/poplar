const std = @import("std");
const zli = @import("zli");
const Project = @import("../Project.zig");
const root = @import("root.zig");

pub fn register(init_options: zli.InitOptions) !*zli.Command {
    const command = try zli.Command.init(init_options, .{
        .name = "check",
        .description = "Find errors without writing any files",
    }, run);
    try command.addPositionalArg(root.dir_arg);
    return command;
}

fn run(ctx: zli.CommandContext) !void {
    var arena: std.heap.ArenaAllocator = .init(ctx.allocator);
    defer arena.deinit();

    const result = try Project.compile(arena.allocator(), ctx.io, root.projectPath(ctx), .{ .std_path = root.stdPath(ctx), .output = .check });
    Project.printDiagnostics(result.diagnostics);
    const summary = result.summary orelse root.fail(ctx);
    try ctx.writer.print("ok: {d} {s}\n", .{ summary.function_count, summary.functionsText() });
}
