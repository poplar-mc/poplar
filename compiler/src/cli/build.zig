const std = @import("std");
const zli = @import("zli");
const Project = @import("../Project.zig");
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

    const result = try Project.compile(arena.allocator(), ctx.io, root.projectPath(ctx), .{ .std_path = root.stdPath(ctx), .output = .write });
    Project.printDiagnostics(result.diagnostics);
    try printSummary(ctx.writer, result.summary orelse root.fail(ctx));
}

pub fn printSummary(writer: *std.Io.Writer, summary: Project.Summary) !void {
    try writer.print("wrote {d} {s} to {s}\n", .{ summary.function_count, summary.functionsText(), summary.pack_path.? });
    if (summary.zip_path) |zip_path| try writer.print("wrote {s}\n", .{zip_path});
}
