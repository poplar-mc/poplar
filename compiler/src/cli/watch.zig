const std = @import("std");
const zli = @import("zli");
const Config = @import("../Config.zig");
const Project = @import("../Project.zig");
const root = @import("root.zig");
const build = @import("build.zig");

const poll_interval: std.Io.Duration = .fromMilliseconds(300);

pub fn register(init_options: zli.InitOptions) !*zli.Command {
    const command = try zli.Command.init(init_options, .{
        .name = "watch",
        .description = "Build again each time a file in src/ or poplar.json changes",
    }, run);
    try command.addPositionalArg(root.dir_arg);
    try command.addFlag(.{
        .name = "world",
        .description = "A world folder. Each build is copied into its datapacks/ folder, so /reload loads it",
        .type = .String,
        .default_value = .{ .String = "" },
    });
    return command;
}

// `--world`: after each build, the pack is copied into `<world>/datapacks/`. Minecraft does not follow
// symbolic links unless they are allowed in `allowed_symlinks.txt`, so it is a copy.
const WorldCopy = struct {
    // The copy has this file, so `watch` only replaces a folder that it made itself.
    const marker_name = ".poplar-watch";

    datapacks_path: []const u8,
    copied_before: bool = false,
    // Set after an error, so that it is printed one time.
    failed: bool = false,

    fn update(copy: *WorldCopy, ctx: zli.CommandContext, gpa: std.mem.Allocator, project_path: []const u8, pack_path: []const u8) !void {
        if (copy.failed) return;
        const io = ctx.io;
        var datapacks = try std.Io.Dir.cwd().openDir(io, copy.datapacks_path, .{});
        defer datapacks.close(io);
        const name = std.fs.path.basename(pack_path);

        const out = root.output(ctx);
        const world_name = std.fs.path.basename(std.fs.path.dirname(copy.datapacks_path).?);
        if (!try isReplaceable(io, datapacks, name)) {
            copy.failed = true;
            out.failure("{s}{s}/datapacks/{s}{s} already exists and was not made by poplar watch. Remove it, then run watch again", .{ out.bold(), world_name, name, out.reset() });
            return;
        }
        datapacks.deleteTree(io, name) catch |err| switch (err) {
            error.NotDir => try datapacks.deleteFile(io, name),
            else => return err,
        };

        var project_dir = try std.Io.Dir.cwd().openDir(io, project_path, .{});
        defer project_dir.close(io);
        var source = try project_dir.openDir(io, pack_path, .{ .iterate = true });
        defer source.close(io);
        var target = try datapacks.createDirPathOpen(io, name, .{});
        defer target.close(io);

        var walker = try source.walk(gpa);
        defer walker.deinit();
        while (try walker.next(io)) |entry| switch (entry.kind) {
            .directory => try target.createDirPath(io, entry.path),
            .file => try source.copyFile(entry.path, target, entry.path, io, .{}),
            else => {},
        };
        try target.writeFile(io, .{ .sub_path = marker_name, .data = "Copied by poplar watch, which replaces this folder after each build.\n" });

        if (!copy.copied_before) try out.success("Copied to {s}{s}/datapacks/{s}{s}. Run {s}/reload{s} in the game after each build", .{ out.bold(), world_name, name, out.reset(), out.bold(), out.reset() });
        copy.copied_before = true;
    }

    // Nothing there yet, a link from an older `watch`, or a copy with the marker.
    fn isReplaceable(io: std.Io, datapacks: std.Io.Dir, name: []const u8) !bool {
        var buffer: [std.fs.max_path_bytes]u8 = undefined;
        if (datapacks.readLink(io, name, &buffer)) |_| return true else |err| switch (err) {
            error.FileNotFound => return true,
            error.NotLink => {},
            else => return err,
        }
        var existing = datapacks.openDir(io, name, .{}) catch |err| switch (err) {
            error.NotDir => return false,
            else => return err,
        };
        defer existing.close(io);
        existing.access(io, marker_name, .{}) catch return false;
        return true;
    }
};

// The `datapacks` folder of the world, made if the world has none yet. Null after an error is printed.
fn datapacksPath(ctx: zli.CommandContext, arena: std.mem.Allocator, world: []const u8) !?[]const u8 {
    const cwd = std.Io.Dir.cwd();
    const out = root.output(ctx);
    const world_path = cwd.realPathFileAlloc(ctx.io, world, arena) catch {
        out.failure("The world folder {s}{s}{s} does not exist", .{ out.bold(), world, out.reset() });
        return null;
    };
    const level_path = try std.fs.path.join(arena, &.{ world_path, "level.dat" });
    cwd.access(ctx.io, level_path, .{}) catch {
        out.failure("{s}{s}{s} is not a Minecraft world: it has no level.dat", .{ out.bold(), world, out.reset() });
        return null;
    };
    const datapacks_path = try std.fs.path.join(arena, &.{ world_path, "datapacks" });
    try cwd.createDirPath(ctx.io, datapacks_path);
    return datapacks_path;
}

fn run(ctx: zli.CommandContext) !void {
    var arena: std.heap.ArenaAllocator = .init(ctx.allocator);
    defer arena.deinit();

    const project_path = root.projectPath(ctx);
    const world = ctx.flag("world", []const u8);
    var world_copy: ?WorldCopy = null;
    if (world.len > 0) {
        world_copy = .{ .datapacks_path = try datapacksPath(ctx, arena.allocator(), world) orelse root.fail(ctx) };
    }

    var last_fingerprint = try fingerprint(ctx.allocator, ctx.io, project_path);
    try rebuild(ctx, project_path, if (world_copy) |*copy| copy else null);

    while (true) {
        try ctx.io.sleep(poll_interval, .awake);
        const current = try fingerprint(ctx.allocator, ctx.io, project_path);
        if (current == last_fingerprint) continue;
        last_fingerprint = current;
        try rebuild(ctx, project_path, if (world_copy) |*copy| copy else null);
    }
}

fn rebuild(ctx: zli.CommandContext, project_path: []const u8, world_copy: ?*WorldCopy) !void {
    var arena: std.heap.ArenaAllocator = .init(ctx.allocator);
    defer arena.deinit();

    const out = root.output(ctx);
    const started = std.Io.Timestamp.now(ctx.io, .awake);
    const result = try Project.compile(arena.allocator(), ctx.io, project_path, .{ .std_path = root.stdPath(ctx), .output = .write });
    out.diagnostics(result.diagnostics);

    // The time of day (UTC, because Zig has no time zones), so that each build is easy to tell apart.
    const seconds_today: u64 = @intCast(@mod(std.Io.Timestamp.now(ctx.io, .real).toSeconds(), std.time.s_per_day));
    try ctx.writer.print("{s}{d:0>2}:{d:0>2}:{d:0>2} UTC{s} ", .{ out.dim(), seconds_today / 3600, seconds_today / 60 % 60, seconds_today % 60, out.reset() });
    if (result.summary) |summary| {
        try build.printBuilt(out, summary, root.elapsedMilliseconds(ctx, started));
        if (world_copy) |copy| try copy.update(ctx, arena.allocator(), project_path, summary.pack_path.?);
    } else {
        out.errorCount(result.diagnostics.len, ", waiting for changes");
    }
    try ctx.writer.flush();
}

// A hash of the path, size and change time of poplar.json and of every file in src/.
fn fingerprint(gpa: std.mem.Allocator, io: std.Io, project_path: []const u8) !u64 {
    var hasher: std.hash.Wyhash = .init(0);
    var project_dir = try std.Io.Dir.cwd().openDir(io, project_path, .{});
    defer project_dir.close(io);

    if (project_dir.statFile(io, Config.file_name, .{})) |stat| {
        hashFile(&hasher, Config.file_name, stat);
    } else |_| {}

    var src_dir = project_dir.openDir(io, "src", .{ .iterate = true }) catch return hasher.final();
    defer src_dir.close(io);

    var walker = try src_dir.walk(gpa);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        const stat = entry.dir.statFile(io, entry.basename, .{}) catch continue;
        hashFile(&hasher, entry.path, stat);
    }
    return hasher.final();
}

fn hashFile(hasher: *std.hash.Wyhash, path: []const u8, stat: std.Io.File.Stat) void {
    hasher.update(path);
    hasher.update(std.mem.asBytes(&stat.size));
    hasher.update(std.mem.asBytes(&stat.mtime.nanoseconds));
}
