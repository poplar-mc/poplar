const std = @import("std");
const zli = @import("zli");
const Project = @import("../Project.zig");
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
        std.debug.print("{s} is not empty\n", .{path});
        root.fail(ctx);
    }

    var arena: std.heap.ArenaAllocator = .init(ctx.allocator);
    defer arena.deinit();
    try Project.writeNewProject(arena.allocator(), ctx.io, dir, std.fs.path.basename(path));
    try ctx.writer.print("made {s}. Build it with: poplar build \"{s}\"\n", .{ path, path });
}
