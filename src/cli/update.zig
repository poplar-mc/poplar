const std = @import("std");
const builtin = @import("builtin");
const zli = @import("zli");
const build_options = @import("build_options");
const root = @import("root.zig");

const latest_release_url = "https://api.github.com/repos/poplar-mc/poplar/releases/latest";
const install_script_url = "https://raw.githubusercontent.com/poplar-mc/poplar/main/install";

pub fn register(init_options: zli.InitOptions) !*zli.Command {
    const command = try zli.Command.init(init_options, .{
        .name = "update",
        .description = "Update Poplar to the latest release",
    }, run);
    try command.addFlag(.{
        .name = "yes",
        .description = "Update without asking",
        .type = .Bool,
        .default_value = .{ .Bool = false },
    });
    return command;
}

const Release = struct {
    tag_name: []const u8,
    html_url: []const u8,
};

fn run(ctx: zli.CommandContext) !void {
    var arena: std.heap.ArenaAllocator = .init(ctx.allocator);
    defer arena.deinit();
    const out = root.output(ctx);

    const release = latestRelease(arena.allocator(), ctx.io) catch |err| {
        out.failure("Could not check for updates: {t}", .{err});
        root.fail(ctx);
    };
    const latest = std.SemanticVersion.parse(std.mem.trimStart(u8, release.tag_name, "v")) catch {
        out.failure("Could not check for updates: the latest release has the tag '{s}'", .{release.tag_name});
        root.fail(ctx);
    };
    const current = try std.SemanticVersion.parse(build_options.version);
    if (latest.order(current) != .gt) {
        return out.success("poplar {s} is the latest version", .{build_options.version});
    }

    try ctx.writer.print("You have poplar {s}. {f} is available: {s}\n", .{ build_options.version, latest, release.html_url });
    if (!ctx.flag("yes", bool)) {
        if (!(std.Io.File.stdin().isTty(ctx.io) catch false)) {
            try ctx.writer.print("Run {s}poplar update --yes{s} to update\n", .{ out.bold(), out.reset() });
            return ctx.writer.flush();
        }
        try ctx.writer.writeAll("Update now? [y/N] ");
        try ctx.writer.flush();
        const answer = std.mem.trim(u8, try ctx.reader.takeDelimiter('\n') orelse "", " \t\r");
        if (!std.ascii.eqlIgnoreCase(answer, "y") and !std.ascii.eqlIgnoreCase(answer, "yes")) return;
    }
    try ctx.writer.flush();
    try runInstallScript(ctx, arena.allocator());
}

fn latestRelease(arena: std.mem.Allocator, io: std.Io) !Release {
    var client: std.http.Client = .{ .allocator = arena, .io = io };
    defer client.deinit();

    var body: std.Io.Writer.Allocating = .init(arena);
    const result = try client.fetch(.{
        .location = .{ .url = latest_release_url },
        .response_writer = &body.writer,
        // GitHub's API answers only requests that name their client.
        .headers = .{ .user_agent = .{ .override = "poplar/" ++ build_options.version } },
    });
    if (result.status != .ok) return error.UnexpectedStatus;
    return std.json.parseFromSliceLeaky(Release, arena, body.written(), .{ .ignore_unknown_fields = true });
}

// The same command as the README. `POPLAR_PREFIX` is the folder above this binary's `bin/`, so the script replaces
// the copy that is running instead of installing a second one.
fn runInstallScript(ctx: zli.CommandContext, arena: std.mem.Allocator) !void {
    const exe_dir = try std.process.executableDirPathAlloc(ctx.io, arena);
    var environment = try root.environment(ctx).clone(arena);
    try environment.put("POPLAR_PREFIX", std.fs.path.dirname(exe_dir) orelse exe_dir);

    const argv: []const []const u8 = if (builtin.os.tag == .windows)
        &.{ "powershell", "-NoProfile", "-ExecutionPolicy", "Bypass", "-Command", "irm " ++ install_script_url ++ ".ps1 | iex" }
    else
        &.{ "sh", "-c", "curl -fsSL " ++ install_script_url ++ ".sh | sh" };
    var child = try std.process.spawn(ctx.io, .{ .argv = argv, .environ_map = &environment });
    const term = try child.wait(ctx.io);
    if (!term.success()) {
        root.output(ctx).failure("The update failed", .{});
        root.fail(ctx);
    }
}
