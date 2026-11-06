const std = @import("std");
const zli = @import("zli");
const Config = @import("../Config.zig");
const project = @import("../project.zig");
const root = @import("root.zig");

pub fn register(init_options: zli.InitOptions) !*zli.Command {
    return zli.Command.init(init_options, .{
        .name = "init",
        .description = "Make a project in the current folder",
    }, run);
}

fn run(ctx: zli.CommandContext) !void {
    const cwd = std.Io.Dir.cwd();
    var arena: std.heap.ArenaAllocator = .init(ctx.allocator);
    defer arena.deinit();
    const out = root.output(ctx);

    for ([_][]const u8{ Config.file_name, "src/main.poplar" }) |path| {
        if (cwd.access(ctx.io, path, .{})) {
            out.failure("{s}{s}{s} already exists, so this folder has a project", .{ out.bold(), path, out.reset() });
            root.fail(ctx);
        } else |_| {}
    }

    const folder = try cwd.realPathFileAlloc(ctx.io, ".", arena.allocator());
    project.writeNewProject(arena.allocator(), ctx.io, cwd, std.fs.path.basename(folder)) catch |err| switch (err) {
        error.PathAlreadyExists => {
            out.failure("A project file already exists here", .{});
            root.fail(ctx);
        },
        else => return err,
    };
    try out.success("Made a project in {s}{s}{s}", .{ out.bold(), std.fs.path.basename(folder), out.reset() });
    try ctx.writer.print("  {s}Next: poplar build{s}\n", .{ out.dim(), out.reset() });
}
