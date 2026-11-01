const std = @import("std");
const zli = @import("zli");
const Config = @import("../Config.zig");
const Project = @import("../Project.zig");
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

    for ([_][]const u8{ Config.file_name, "src/main.poplar" }) |path| {
        if (cwd.access(ctx.io, path, .{})) {
            std.debug.print("{s} already exists\n", .{path});
            root.fail(ctx);
        } else |_| {}
    }

    const folder = try cwd.realPathFileAlloc(ctx.io, ".", arena.allocator());
    Project.writeNewProject(arena.allocator(), ctx.io, cwd, std.fs.path.basename(folder)) catch |err| switch (err) {
        error.PathAlreadyExists => {
            std.debug.print("a project file already exists here\n", .{});
            root.fail(ctx);
        },
        else => return err,
    };
    try ctx.writer.print("made a project in {s}\n", .{folder});
}
