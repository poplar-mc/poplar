const std = @import("std");
const zli = @import("zli");
const build_options = @import("build_options");
const new = @import("new.zig");
const init = @import("init.zig");
const build = @import("build.zig");
const check = @import("check.zig");
const watch = @import("watch.zig");
const lsp = @import("lsp.zig");
const Config = @import("../Config.zig");
const Output = @import("Output.zig");

pub fn register(init_options: zli.InitOptions) !*zli.Command {
    const root = try zli.Command.init(init_options, .{
        .name = "poplar",
        .description = "Compile Poplar code into Minecraft datapacks",
        .version = try std.SemanticVersion.parse(build_options.version),
    }, showHelpOrVersion);
    try root.addFlag(.{
        .name = "version",
        .description = "Show the Poplar version and the Minecraft version it targets",
        .type = .Bool,
        .default_value = .{ .Bool = false },
    });

    try root.addCommands(&.{
        try new.register(init_options),
        try init.register(init_options),
        try build.register(init_options),
        try check.register(init_options),
        try watch.register(init_options),
        try lsp.register(init_options),
    });
    return root;
}

fn showHelpOrVersion(ctx: zli.CommandContext) !void {
    if (!ctx.flag("version", bool)) return ctx.command.printHelp();

    var arena: std.heap.ArenaAllocator = .init(ctx.allocator);
    defer arena.deinit();
    try ctx.writer.print("poplar {s} (Minecraft {s})\n", .{ build_options.version, try Config.minecraftVersion(arena.allocator()) });
}

// Exits with code 1 after a command printed its own error messages.
pub fn fail(ctx: zli.CommandContext) noreturn {
    ctx.writer.flush() catch {};
    std.process.exit(1);
}

// What `main` passes to every command.
pub const Shared = struct {
    // The folder of the standard library, which `import "std";` loads.
    std_path: []const u8,
    color: bool,
    environ_map: *const std.process.Environ.Map,
};

fn shared(ctx: zli.CommandContext) *const Shared {
    return @ptrCast(@alignCast(ctx.data.?));
}

pub fn stdPath(ctx: zli.CommandContext) []const u8 {
    return shared(ctx).std_path;
}

pub fn environment(ctx: zli.CommandContext) *const std.process.Environ.Map {
    return shared(ctx).environ_map;
}

pub fn output(ctx: zli.CommandContext) Output {
    return .{ .writer = ctx.writer, .color = shared(ctx).color };
}

// `1 ms`, for the time a build takes.
pub fn elapsedMilliseconds(ctx: zli.CommandContext, started: std.Io.Timestamp) i64 {
    return started.untilNow(ctx.io, .awake).toMilliseconds();
}

// The project folder: the optional `dir` argument, or the current folder.
pub fn projectPath(ctx: zli.CommandContext) []const u8 {
    return ctx.getArg("dir") orelse ".";
}

pub const dir_arg: zli.PositionalArg = .{
    .name = "dir",
    .description = "The project folder (default: the current folder)",
    .required = false,
};
