const std = @import("std");
const zli = @import("zli");
const project = @import("../project.zig");
const root = @import("root.zig");

pub fn register(init_options: zli.InitOptions) !*zli.Command {
    const command = try zli.Command.init(init_options, .{
        .name = "new",
        .description = "Make a new project folder",
    }, run);
    try command.addPositionalArg(.{
        .name = "name",
        .description = "The folder to make. Its name is the pack name",
        .required = true,
    });
    return command;
}

fn run(ctx: zli.CommandContext) !void {
    const path = ctx.getArg("name").?;
    const cwd = std.Io.Dir.cwd();

    try cwd.createDirPath(ctx.io, path);
    var dir = try cwd.openDir(ctx.io, path, .{ .iterate = true });
    defer dir.close(ctx.io);

    var entries = dir.iterate();
    if (try entries.next(ctx.io) != null) {
        const out = root.output(ctx);
        out.failure("{s}{s}{s} is not empty", .{ out.bold(), path, out.reset() });
        root.fail(ctx);
    }

    var arena: std.heap.ArenaAllocator = .init(ctx.allocator);
    defer arena.deinit();
    try project.writeNewProject(arena.allocator(), ctx.io, dir, std.fs.path.basename(path));
    const out = root.output(ctx);
    try out.success("Made {s}{s}{s}", .{ out.bold(), path, out.reset() });
    try ctx.writer.print("  {s}Next: cd \"{s}\" && poplar build{s}\n", .{ out.dim(), path, out.reset() });
}
