const std = @import("std");
const zli = @import("zli");
const project = @import("../project.zig");
const Output = @import("Output.zig");
const root = @import("root.zig");

pub fn register(init_options: zli.InitOptions) !*zli.Command {
    const command = try zli.Command.init(init_options, .{
        .name = "build",
        .description = "Compile the project into poplar-out/",
    }, run);
    try command.addPositionalArg(root.dir_arg);
    return command;
}

fn run(ctx: zli.CommandContext) !void {
    var arena: std.heap.ArenaAllocator = .init(ctx.allocator);
    defer arena.deinit();

    const out = root.output(ctx);
    const started = std.Io.Timestamp.now(ctx.io, .awake);
    const result = try project.build(arena.allocator(), ctx.io, root.projectPath(ctx), .{ .std_path = root.stdPath(ctx), .mode = .write });
    out.diagnostics(result.diagnostics);
    const summary = result.summary orelse {
        out.errorCount(result.diagnostics.len, ", nothing was written");
        root.fail(ctx);
    };
    try printBuilt(out, summary, root.elapsedMilliseconds(ctx, started));
}

/// `✓ Built hello in 18 ms → poplar-out/hello (7 functions, zip)`
pub fn printBuilt(out: Output, summary: project.Summary, milliseconds: i64) !void {
    try out.success("Built {s}{s}{s} in {d} ms {s}→ {s} ({d} {s}, zip){s}", .{
        out.bold(),  summary.name,        out.reset(),            milliseconds,
        out.dim(),   summary.pack_path.?, summary.function_count, summary.functionsText(),
        out.reset(),
    });
}
