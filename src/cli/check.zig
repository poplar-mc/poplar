const std = @import("std");
const zli = @import("zli");
const project = @import("../project.zig");
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

    const out = root.output(ctx);
    const result = try project.build(arena.allocator(), ctx.io, root.projectPath(ctx), .{ .std_path = root.stdPath(ctx), .mode = .check });
    out.diagnostics(result.diagnostics);
    const summary = result.summary orelse {
        out.errorCount(result.diagnostics.len, "");
        root.fail(ctx);
    };
    try out.success("No errors in {s}{s}{s} {s}({d} {s}){s}", .{ out.bold(), summary.name, out.reset(), out.dim(), summary.function_count, summary.functionsText(), out.reset() });
}
