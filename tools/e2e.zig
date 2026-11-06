const std = @import("std");

const Io = std.Io;
const Allocator = std.mem.Allocator;

const manifest_url = "https://piston-meta.mojang.com/mc/game/version_manifest_v2.json";
const eula_url = "https://aka.ms/MinecraftEULA";
/// The harness says this after each test, so it knows where the output of the test ends.
const end_marker = "poplar-e2e-end";

/// A flat world needs its layers in `generator-settings`, or the server logs an error.
const server_properties =
    \\level-type=minecraft\:flat
    \\generator-settings={"layers":[{"block":"minecraft:bedrock","height":1},{"block":"minecraft:stone","height":3}],"biome":"minecraft:plains"}
    \\online-mode=false
    \\generate-structures=false
    \\spawn-protection=0
    \\view-distance=3
    \\simulation-distance=3
    \\max-players=1
    \\
;

const Options = struct {
    poplar_path: []const u8,
    mcmeta_version_path: []const u8,
    tests_path: []const u8,
    cache_path: []const u8,
    accept_eula: bool,
};

const Manifest = struct {
    versions: []const struct {
        id: []const u8,
        url: []const u8,
    },
};

const VersionInfo = struct {
    downloads: struct {
        server: struct {
            sha1: []const u8,
            url: []const u8,
        },
    },
    javaVersion: struct {
        majorVersion: u32,
    },
};

const McmetaVersion = struct {
    id: []const u8,
};

const TestProject = struct {
    name: []const u8,
    expected: []const []const u8,
};

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;

    const args = try init.minimal.args.toSlice(arena);
    if (args.len < 5) {
        std.debug.print("usage: e2e <poplar> <mcmeta version.json> <tests dir> <cache dir> [--accept-eula]\n", .{});
        std.process.exit(2);
    }

    const options: Options = .{
        .poplar_path = args[1],
        .mcmeta_version_path = args[2],
        .tests_path = args[3],
        .cache_path = args[4],
        .accept_eula = args.len > 5 and std.mem.eql(u8, args[5], "--accept-eula"),
    };

    const failed = try run(arena, io, options);
    std.process.exit(@intCast(@min(failed, 255)));
}

/// Returns the number of failed tests.
fn run(arena: Allocator, io: Io, options: Options) !usize {
    const cwd = Io.Dir.cwd();

    const mcmeta_json = try cwd.readFileAlloc(io, options.mcmeta_version_path, arena, .unlimited);
    const version_id = (try parseJson(McmetaVersion, arena, mcmeta_json)).id;

    var cache_dir = try cwd.createDirPathOpen(io, options.cache_path, .{});
    defer cache_dir.close(io);

    const info = try loadVersionInfo(arena, io, cache_dir, version_id);
    try checkJava(arena, io, version_id, info.javaVersion.majorVersion);

    if (!options.accept_eula) {
        std.debug.print(
            \\The Minecraft server needs the Minecraft EULA to be accepted: {s}
            \\If you accept it, run: zig build e2e -Daccept-eula
            \\
        , .{eula_url});
        std.process.exit(1);
    }

    const jar_name = try std.fmt.allocPrint(arena, "server-{s}.jar", .{version_id});
    try ensureServerJar(arena, io, cache_dir, jar_name, info.downloads.server.url, info.downloads.server.sha1);

    try cache_dir.deleteTree(io, "server");
    var server_dir = try cache_dir.createDirPathOpen(io, "server/world/datapacks", .{});
    server_dir.close(io);
    server_dir = try cache_dir.openDir(io, "server", .{});
    defer server_dir.close(io);

    try server_dir.writeFile(io, .{ .sub_path = "eula.txt", .data = "eula=true\n" });
    try server_dir.writeFile(io, .{ .sub_path = "server.properties", .data = server_properties });

    var failed: usize = 0;
    const projects = try buildTestProjects(arena, io, options, server_dir, &failed);

    const server_path = try std.fs.path.join(arena, &.{ options.cache_path, "server" });
    const jar_path = try std.fs.path.join(arena, &.{ "..", jar_name });
    failed += try runServer(arena, io, server_path, jar_path, projects);

    std.debug.print("\n{d} failed\n", .{failed});
    return failed;
}

/// The version JSON is kept in the cache, so a run with the jar already there needs no network.
fn loadVersionInfo(arena: Allocator, io: Io, cache_dir: Io.Dir, version_id: []const u8) !VersionInfo {
    const cache_name = try std.fmt.allocPrint(arena, "{s}.json", .{version_id});

    const version_json = cache_dir.readFileAlloc(io, cache_name, arena, .unlimited) catch |err| switch (err) {
        error.FileNotFound => blk: {
            const manifest = try parseJson(Manifest, arena, try download(arena, io, manifest_url));
            const url = for (manifest.versions) |version| {
                if (std.mem.eql(u8, version.id, version_id)) break version.url;
            } else {
                std.debug.print("Minecraft version '{s}' is not in the Mojang version manifest\n", .{version_id});
                std.process.exit(1);
            };

            const fetched = try download(arena, io, url);
            try cache_dir.writeFile(io, .{ .sub_path = cache_name, .data = fetched });
            break :blk fetched;
        },
        else => return err,
    };

    return parseJson(VersionInfo, arena, version_json);
}

fn ensureServerJar(arena: Allocator, io: Io, cache_dir: Io.Dir, jar_name: []const u8, url: []const u8, sha1: []const u8) !void {
    if (cache_dir.readFileAlloc(io, jar_name, arena, .unlimited)) |jar| {
        if (std.mem.eql(u8, &sha1Hex(jar), sha1)) return;
    } else |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    }

    std.debug.print("downloading {s}\n", .{url});
    const jar = try download(arena, io, url);
    if (!std.mem.eql(u8, &sha1Hex(jar), sha1)) {
        std.debug.print("the downloaded server jar has the wrong SHA-1\n", .{});
        std.process.exit(1);
    }
    try cache_dir.writeFile(io, .{ .sub_path = jar_name, .data = jar });
}

fn download(arena: Allocator, io: Io, url: []const u8) ![]const u8 {
    var client: std.http.Client = .{ .allocator = arena, .io = io };
    defer client.deinit();

    var body: Io.Writer.Allocating = .init(arena);
    const result = try client.fetch(.{ .location = .{ .url = url }, .response_writer = &body.writer });
    if (result.status != .ok) {
        std.debug.print("download of {s} failed: HTTP {d}\n", .{ url, @backingInt(result.status) });
        std.process.exit(1);
    }
    return body.written();
}

fn checkJava(arena: Allocator, io: Io, version_id: []const u8, required: u32) !void {
    const hint = "Install a JDK from your package manager, for example: nix-env -iA nixpkgs.jdk";

    const result = std.process.run(arena, io, .{ .argv = &.{ "java", "-version" } }) catch |err| switch (err) {
        error.FileNotFound => {
            std.debug.print("Minecraft {s} needs Java {d}, but 'java' was not found. {s}{d}\n", .{ version_id, required, hint, required });
            std.process.exit(1);
        },
        else => return err,
    };

    // `java -version` writes `openjdk version "25.0.1" ...` to stderr.
    const marker = "version \"";
    const start = (std.mem.indexOf(u8, result.stderr, marker) orelse 0) + marker.len;
    const end = std.mem.indexOfAnyPos(u8, result.stderr, start, ".\"") orelse start;
    const major = std.fmt.parseInt(u32, result.stderr[start..end], 10) catch 0;

    if (major < required) {
        std.debug.print("Minecraft {s} needs Java {d}, but 'java' is version {d}. {s}{d}\n", .{ version_id, required, major, hint, required });
        std.process.exit(1);
    }
}

/// Builds each folder in the tests folder with poplar, and copies its datapack into the world.
fn buildTestProjects(arena: Allocator, io: Io, options: Options, server_dir: Io.Dir, failed: *usize) ![]const TestProject {
    var tests_dir = try Io.Dir.cwd().openDir(io, options.tests_path, .{ .iterate = true });
    defer tests_dir.close(io);

    var names: std.ArrayList([]const u8) = .empty;
    var iterator = tests_dir.iterate();
    while (try iterator.next(io)) |entry| {
        if (entry.kind == .directory) try names.append(arena, try arena.dupe(u8, entry.name));
    }
    std.mem.sort([]const u8, names.items, {}, lessThan);

    var projects: std.ArrayList(TestProject) = .empty;
    for (names.items) |name| {
        const project_path = try std.fs.path.join(arena, &.{ options.tests_path, name });
        const build = try std.process.run(arena, io, .{ .argv = &.{ options.poplar_path, "build", project_path } });
        if (build.term != .exited or build.term.exited != 0) {
            std.debug.print("FAIL {s}: poplar build failed\n{s}", .{ name, build.stderr });
            failed.* += 1;
            continue;
        }

        // `poplar-out/` holds one folder for the pack, named by poplar.json, and maybe a zip.
        const out_path = try std.fs.path.join(arena, &.{ name, "poplar-out" });
        var out_dir = try tests_dir.openDir(io, out_path, .{ .iterate = true });
        defer out_dir.close(io);
        var packs = out_dir.iterate();
        while (try packs.next(io)) |pack| {
            if (pack.kind != .directory) continue;
            const pack_path = try std.fs.path.join(arena, &.{ "world/datapacks", pack.name });
            try copyTree(arena, io, out_dir, pack.name, server_dir, pack_path);
        }

        const expect_path = try std.fs.path.join(arena, &.{ name, "expect.txt" });
        const expect_text = try tests_dir.readFileAlloc(io, expect_path, arena, .unlimited);
        try projects.append(arena, .{ .name = name, .expected = try nonEmptyLines(arena, expect_text) });
    }
    return projects.items;
}

/// A copy, not a symlink: Minecraft rejects datapacks that are symlinks.
fn copyTree(arena: Allocator, io: Io, source_dir: Io.Dir, source_path: []const u8, dest_dir: Io.Dir, dest_path: []const u8) !void {
    var source = try source_dir.openDir(io, source_path, .{ .iterate = true });
    defer source.close(io);
    var dest = try dest_dir.createDirPathOpen(io, dest_path, .{});
    defer dest.close(io);

    var walker = try source.walk(arena);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        switch (entry.kind) {
            .directory => try dest.createDirPath(io, entry.path),
            .file => try entry.dir.copyFile(entry.basename, dest, entry.path, io, .{ .make_path = true }),
            else => {},
        }
    }
}

/// Starts the server, runs `function <name>:test` for each project, and compares the `[Server]` messages.
fn runServer(arena: Allocator, io: Io, server_path: []const u8, jar_path: []const u8, projects: []const TestProject) !usize {
    std.debug.print("starting the Minecraft server\n", .{});
    var child = try std.process.spawn(io, .{
        .argv = &.{ "java", "-Xmx1G", "-jar", jar_path, "nogui" },
        .cwd = .{ .path = server_path },
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .inherit,
    });

    var buffer: [64 * 1024]u8 = undefined;
    var stdout_reader = child.stdout.?.readerStreaming(io, &buffer);
    const log = &stdout_reader.interface;
    const log_hint = try std.fmt.allocPrint(arena, "see {s}/logs/latest.log", .{server_path});

    var failed: usize = 0;
    var is_ready = false;
    while (try log.takeDelimiter('\n')) |line| {
        // An error while loading means that the compiler wrote a command that Minecraft does not accept.
        if (std.mem.indexOf(u8, line, "/ERROR]") != null) {
            std.debug.print("server error: {s}\n", .{trimLine(line)});
            failed += 1;
        }
        if (std.mem.indexOf(u8, line, "Done (") != null) {
            is_ready = true;
            break;
        }
    }
    if (!is_ready) {
        std.debug.print("FAIL: the server stopped before it was ready, {s}\n", .{log_hint});
        _ = try child.wait(io);
        return failed + projects.len;
    }

    for (projects) |project| {
        const commands = try std.fmt.allocPrint(arena, "function {s}:test\nsay {s}\n", .{ project.name, end_marker });
        try child.stdin.?.writeStreamingAll(io, commands);

        var messages: std.ArrayList([]const u8) = .empty;
        var other_output: std.ArrayList([]const u8) = .empty;
        var has_end = false;
        while (try log.takeDelimiter('\n')) |line| {
            const message = serverMessage(line) orelse {
                try other_output.append(arena, try arena.dupe(u8, trimLine(line)));
                continue;
            };
            if (std.mem.eql(u8, message, end_marker)) {
                has_end = true;
                break;
            }
            try messages.append(arena, try arena.dupe(u8, message));
        }

        if (has_end and linesEqual(project.expected, messages.items)) {
            std.debug.print("PASS {s}\n", .{project.name});
            continue;
        }

        failed += 1;
        std.debug.print("FAIL {s}\n", .{project.name});
        printLines("expected", project.expected);
        printLines("actual", messages.items);
        printLines("other output", other_output.items);
        if (!has_end) {
            std.debug.print("  the server stopped during this test, {s}\n", .{log_hint});
            _ = try child.wait(io);
            return failed;
        }
    }

    try child.stdin.?.writeStreamingAll(io, "stop\n");
    while (try log.takeDelimiter('\n')) |_| {}
    _ = try child.wait(io);
    return failed;
}

/// `[12:00:00] [Server thread/INFO]: [Not Secure] [Server] hello` → `hello`. `[Not Secure] ` is not always there.
fn serverMessage(line: []const u8) ?[]const u8 {
    const log_prefix = "]: ";
    const message_start = (std.mem.indexOf(u8, line, log_prefix) orelse return null) + log_prefix.len;

    var message = line[message_start..];
    if (std.mem.startsWith(u8, message, "[Not Secure] ")) message = message["[Not Secure] ".len..];
    if (!std.mem.startsWith(u8, message, "[Server] ")) return null;
    return trimLine(message["[Server] ".len..]);
}

fn trimLine(line: []const u8) []const u8 {
    return std.mem.trimEnd(u8, line, "\r");
}

fn nonEmptyLines(arena: Allocator, text: []const u8) ![]const []const u8 {
    var lines: std.ArrayList([]const u8) = .empty;
    var iterator = std.mem.splitScalar(u8, text, '\n');
    while (iterator.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len > 0) try lines.append(arena, trimmed);
    }
    return lines.items;
}

fn linesEqual(expected: []const []const u8, actual: []const []const u8) bool {
    if (expected.len != actual.len) return false;
    for (expected, actual) |expected_line, actual_line| {
        if (!std.mem.eql(u8, expected_line, actual_line)) return false;
    }
    return true;
}

fn printLines(label: []const u8, lines: []const []const u8) void {
    std.debug.print("  {s}:\n", .{label});
    for (lines) |line| std.debug.print("    {s}\n", .{line});
}

fn sha1Hex(data: []const u8) [std.crypto.hash.Sha1.digest_length * 2]u8 {
    var digest: [std.crypto.hash.Sha1.digest_length]u8 = undefined;
    std.crypto.hash.Sha1.hash(data, &digest, .{});
    return std.fmt.bytesToHex(digest, .lower);
}

fn parseJson(comptime T: type, arena: Allocator, json: []const u8) !T {
    return std.json.parseFromSliceLeaky(T, arena, json, .{ .ignore_unknown_fields = true });
}

fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}
