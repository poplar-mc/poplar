const std = @import("std");
const Commands = @import("Commands.zig");
const Compiler = @import("Compiler.zig");
const Config = @import("Config.zig");
const Lexer = @import("Lexer.zig");
const Parser = @import("Parser.zig");
const Writer = @import("Writer.zig");

const schema_json = @embedFile("poplar.schema.json");

pub const out_dir_name = "poplar-out";

pub const Output = enum { write, check };

pub const Summary = struct {
    // `zipName`, the name of the pack.
    name: []const u8,
    function_count: usize,
    // `poplar-out/<zipName>`, or null for `.check`.
    pack_path: ?[]const u8 = null,
    zip_path: ?[]const u8 = null,

    pub fn functionsText(summary: Summary) []const u8 {
        return if (summary.function_count == 1) "function" else "functions";
    }
};

// The folder that a source path is relative to.
const Root = enum {
    // `src/` of the project.
    project,
    // The standard library, from `import "std";`.
    std,

    fn displayName(root: Root) []const u8 {
        return switch (root) {
            .project => "src",
            .std => "std",
        };
    }
};

// A file to load. The path is relative to its root folder.
const PendingFile = struct {
    root: Root,
    path: []const u8,
    // Null for the entry file.
    imported_by: ?ImportSite,
};

const ImportSite = struct {
    path: []const u8,
    line: usize,
    column: usize,
};

// An error in the user's files. A line of 0 means that it has no position in a file.
pub const Diagnostic = struct {
    path: []const u8,
    line: usize,
    column: ?usize,
    message: []const u8,
};

pub const Options = struct {
    // The folder of the standard library, which `import "std";` loads.
    std_path: []const u8,
    output: Output,
    // Absolute path → the text of a file that is open in an editor. It is read instead of the file on disk.
    overlay: ?*const std.StringHashMapUnmanaged([]const u8) = null,
    // The language server loads the command tree one time and passes it in.
    command_tree: ?*const Commands = null,
};

pub const Result = struct {
    // Null when there were errors.
    summary: ?Summary = null,
    diagnostics: []const Diagnostic = &.{},
    // Null when the compile stopped before the compiler ran (no project, or a bad poplar.json).
    compiler: ?*Compiler = null,
    // Display path (`src/main.poplar`, `std/math.poplar`) → absolute path, for every file that was read.
    files: std.StringArrayHashMapUnmanaged([]const u8) = .empty,
};

// Compiles the project in `project_path`. Errors in the user's files are in the result, not printed.
pub fn compile(arena: std.mem.Allocator, io: std.Io, project_path: []const u8, options: Options) !Result {
    var diagnostics: std.ArrayList(Diagnostic) = .empty;
    const cwd = std.Io.Dir.cwd();

    const project_real_path = cwd.realPathFileAlloc(io, project_path, arena) catch |err| switch (err) {
        error.FileNotFound => return onlyDiagnostic(arena, "", 0, null, try std.fmt.allocPrint(arena, "the project folder {s} does not exist", .{project_path})),
        else => return err,
    };

    var project_dir = try cwd.openDir(io, project_path, .{});
    defer project_dir.close(io);

    var problem: Config.Problem = .{};
    const config = Config.load(arena, io, project_dir, std.fs.path.basename(project_real_path), &problem) catch |err| switch (err) {
        error.InvalidConfig => return onlyDiagnostic(arena, Config.file_name, problem.line, if (problem.line == 0) null else problem.column, problem.message),
        else => return err,
    };

    var src_dir = project_dir.openDir(io, "src", .{}) catch |err| switch (err) {
        error.FileNotFound => return onlyDiagnostic(arena, "", 0, null, try std.fmt.allocPrint(arena, "the folder {s} is not a Poplar project: it has no src/ folder", .{project_path})),
        else => return err,
    };
    defer src_dir.close(io);

    const command_tree = options.command_tree orelse blk: {
        const tree = try arena.create(Commands);
        tree.* = try Commands.load(arena);
        break :blk tree;
    };
    const compiler = try arena.create(Compiler);
    compiler.* = Compiler.init(arena, command_tree);
    compiler.namespace = config.namespace;

    var loader: Loader = .{
        .allocator = arena,
        .io = io,
        .src_dir = src_dir,
        .src_path = try std.fs.path.join(arena, &.{ project_real_path, "src" }),
        .std_path = options.std_path,
        .overlay = options.overlay,
        .compiler = compiler,
        .diagnostics = &diagnostics,
    };
    defer loader.deinit();

    var result: Result = .{ .compiler = compiler };
    const sources_loaded = try loader.load(config.entry);
    result.files = loader.files;
    if (!sources_loaded) {
        result.diagnostics = diagnostics.items;
        return result;
    }

    const ir_program = try compiler.compile();
    if (compiler.errors.items.len > 0) {
        for (compiler.errors.items) |err| try diagnostics.append(arena, .{ .path = err.path, .line = err.line, .column = err.column, .message = err.message });
        result.diagnostics = diagnostics.items;
        return result;
    }

    var summary: Summary = .{ .name = config.zip_name, .function_count = ir_program.functions.len };
    if (options.output == .write) {
        try project_dir.deleteTree(io, out_dir_name);
        var out_dir = try project_dir.createDirPathOpen(io, out_dir_name, .{});
        defer out_dir.close(io);
        var pack_dir = try out_dir.createDirPathOpen(io, config.zip_name, .{ .open_options = .{ .iterate = true } });
        defer pack_dir.close(io);

        try Writer.writeDatapack(io, arena, pack_dir, config, ir_program);
        summary.pack_path = try std.fs.path.join(arena, &.{ out_dir_name, config.zip_name });

        const zip_file_name = try std.fmt.allocPrint(arena, "{s}.zip", .{config.zip_name});
        try Writer.writeZip(io, arena, pack_dir, out_dir, zip_file_name);
        summary.zip_path = try std.fs.path.join(arena, &.{ out_dir_name, zip_file_name });
    }
    result.summary = summary;
    return result;
}

fn onlyDiagnostic(arena: std.mem.Allocator, path: []const u8, line: usize, column: ?usize, message: []const u8) !Result {
    return .{ .diagnostics = try arena.dupe(Diagnostic, &.{.{ .path = path, .line = line, .column = column, .message = message }}) };
}

// Where `zig build` installs the standard library: `lib/poplar/std` next to the `bin` folder of the binary.
pub fn installedStdPath(arena: std.mem.Allocator, io: std.Io) ![]const u8 {
    const exe_dir = try std.process.executableDirPathAlloc(io, arena);
    return std.fs.path.join(arena, &.{ exe_dir, "..", "lib", "poplar", "std" });
}

// Parses the entry file and every file that it imports, each one time, and gives each program to the compiler.
const Loader = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    src_dir: std.Io.Dir,
    // The absolute path of `src_dir`.
    src_path: []const u8,
    std_path: []const u8,
    overlay: ?*const std.StringHashMapUnmanaged([]const u8),
    compiler: *Compiler,
    diagnostics: *std.ArrayList(Diagnostic),
    // Opened when the first file imports "std", so projects without it do not need the folder.
    std_dir: ?std.Io.Dir = null,
    std_real_path: []const u8 = "",
    files: std.StringArrayHashMapUnmanaged([]const u8) = .empty,

    fn deinit(loader: *Loader) void {
        if (loader.std_dir) |dir| dir.close(loader.io);
    }

    // Returns false if there were errors. `entry_file` is relative to `src/`.
    fn load(loader: *Loader, entry_file: []const u8) !bool {
        const allocator = loader.allocator;
        var pending: std.ArrayList(PendingFile) = .empty;
        // A key is the root and the path, so `src/std.poplar` and the library's `std.poplar` are different files.
        var loaded: std.StringHashMapUnmanaged(void) = .empty;
        try pending.append(allocator, .{ .root = .project, .path = entry_file, .imported_by = null });
        try loaded.put(allocator, try loadedKey(allocator, .project, entry_file), {});

        var has_errors = false;
        var index: usize = 0;
        while (index < pending.items.len) : (index += 1) {
            const file = pending.items[index];
            const display_path = try std.fs.path.join(allocator, &.{ file.root.displayName(), file.path });

            const input = try loader.read(file, display_path) orelse {
                if (file.imported_by) |site| {
                    try loader.addError(site.path, site.line, site.column, "cannot find '{s}'", .{display_path});
                } else {
                    try loader.addError("", 0, null, "the entry file {s} does not exist", .{display_path});
                }
                has_errors = true;
                continue;
            };

            var parser = try Parser.init(allocator, Lexer.init(input));
            const program = try parser.parseProgram();

            // The parser skips a declaration that has an error. The rest still loads, so the editor knows its names.
            if (parser.errors.items.len > 0) {
                for (parser.errors.items) |err| try loader.diagnostics.append(allocator, .{ .path = display_path, .line = err.line, .column = err.column, .message = err.message });
                has_errors = true;
            }

            const directory = std.fs.path.dirnamePosix(file.path) orelse ".";
            for (program.imports) |import| {
                const site: ImportSite = .{ .path = display_path, .line = import.line, .column = import.column };

                // A library name has no `.poplar`: `import "std";` loads `std.poplar` from the standard library.
                if (std.mem.eql(u8, import.path, "std")) {
                    if (!try loader.openStd()) {
                        try loader.addError(site.path, site.line, site.column, "cannot find the standard library at '{s}'", .{loader.std_path});
                        has_errors = true;
                        continue;
                    }
                    try addPending(allocator, &pending, &loaded, .{ .root = .std, .path = "std.poplar", .imported_by = site });
                    continue;
                }

                const path = try std.fs.path.resolveAllocPosix(allocator, &.{ directory, import.path });
                const is_outside = std.fs.path.isAbsolutePosix(import.path) or std.mem.eql(u8, path, "..") or std.mem.startsWith(u8, path, "../");
                if (is_outside) {
                    try loader.addError(display_path, import.line, import.column, "import '{s}' is outside {s}/", .{ import.path, file.root.displayName() });
                    has_errors = true;
                    continue;
                }
                try addPending(allocator, &pending, &loaded, .{ .root = file.root, .path = path, .imported_by = site });
            }

            const origin: Compiler.Origin = if (index == 0) .entry else if (file.root == .std) .std else .project;
            try loader.compiler.addProgram(display_path, program, origin);
        }

        return !has_errors;
    }

    // The text of a file: from the overlay when an editor has it open, else from the disk. Null if it does not exist.
    fn read(loader: *Loader, file: PendingFile, display_path: []const u8) !?[]const u8 {
        const root_path = switch (file.root) {
            .project => loader.src_path,
            .std => loader.std_real_path,
        };
        const absolute_path = try std.fs.path.join(loader.allocator, &.{ root_path, file.path });
        try loader.files.put(loader.allocator, display_path, absolute_path);

        if (loader.overlay) |overlay| {
            if (overlay.get(absolute_path)) |text| return text;
        }
        const root_dir = switch (file.root) {
            .project => loader.src_dir,
            .std => loader.std_dir.?,
        };
        return root_dir.readFileAlloc(loader.io, file.path, loader.allocator, .unlimited) catch |err| switch (err) {
            error.FileNotFound => null,
            else => err,
        };
    }

    fn openStd(loader: *Loader) !bool {
        if (loader.std_dir != null) return true;
        const cwd = std.Io.Dir.cwd();
        loader.std_dir = cwd.openDir(loader.io, loader.std_path, .{}) catch return false;
        loader.std_real_path = try cwd.realPathFileAlloc(loader.io, loader.std_path, loader.allocator);
        return true;
    }

    fn addError(loader: *Loader, path: []const u8, line: usize, column: ?usize, comptime format: []const u8, args: anytype) !void {
        const message = try std.fmt.allocPrint(loader.allocator, format, args);
        try loader.diagnostics.append(loader.allocator, .{ .path = path, .line = line, .column = column, .message = message });
    }
};

// Queues a file, unless it is already loaded or queued.
fn addPending(allocator: std.mem.Allocator, pending: *std.ArrayList(PendingFile), loaded: *std.StringHashMapUnmanaged(void), file: PendingFile) !void {
    const entry = try loaded.getOrPut(allocator, try loadedKey(allocator, file.root, file.path));
    if (entry.found_existing) return;
    try pending.append(allocator, file);
}

fn loadedKey(allocator: std.mem.Allocator, root: Root, path: []const u8) ![]const u8 {
    return std.fmt.allocPrint(allocator, "{t}:{s}", .{ root, path });
}

// Writes the files of a new project into `dir`. It never overwrites a file.
pub fn writeNewProject(arena: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, name: []const u8) !void {
    const namespace = try namespaceFromName(arena, name);

    const poplar_json = try std.fmt.allocPrint(arena,
        \\{{
        \\  "$schema": "./poplar.schema.json",
        \\  "zipName": {f},
        \\  "namespace": "{s}"
        \\}}
        \\
    , .{ std.json.fmt(name, .{}), namespace });

    const main_poplar = try std.fmt.allocPrint(arena,
        \\mcfun load() {{
        \\    /say Hello from {s}!;
        \\}}
        \\
    , .{namespace});

    try dir.createDirPath(io, "src");
    try writeNewFile(io, dir, Config.file_name, poplar_json);
    try writeNewFile(io, dir, "poplar.schema.json", schema_json);
    try writeNewFile(io, dir, "src/main.poplar", main_poplar);
    try writeNewFile(io, dir, ".gitignore", out_dir_name ++ "/\n.env\n");
}

fn writeNewFile(io: std.Io, dir: std.Io.Dir, path: []const u8, data: []const u8) !void {
    const file = try dir.createFile(io, path, .{ .exclusive = true });
    defer file.close(io);
    try file.writeStreamingAll(io, data);
}

// `My Pack` → `my_pack`. A namespace may only use a-z, 0-9, `_`, `.` and `-`.
pub fn namespaceFromName(arena: std.mem.Allocator, name: []const u8) ![]const u8 {
    const namespace = try arena.alloc(u8, name.len);
    for (name, namespace) |ch, *out| {
        const lower = std.ascii.toLower(ch);
        const is_valid = std.ascii.isLower(lower) or std.ascii.isDigit(lower) or lower == '_' or lower == '.' or lower == '-';
        out.* = if (is_valid) lower else '_';
    }
    return namespace;
}

test "loads imported files once and ignores the rest" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(io, .{ .sub_path = "main.poplar", .data = "import \"lib/a.poplar\";\nmcfun one() {}\n" });
    try tmp.dir.createDirPath(io, "lib");
    try tmp.dir.writeFile(io, .{ .sub_path = "lib/a.poplar", .data = "import \"../main.poplar\";\nmcfun two() {}\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "unused.poplar", .data = "mcfun broken( {" });

    const command_tree = try Commands.load(arena.allocator());
    var compiler = Compiler.init(arena.allocator(), &command_tree);

    try std.testing.expect(try loadForTest(arena.allocator(), io, tmp.dir, "no-std", &compiler));
    try std.testing.expectEqual(2, compiler.functions.count());
}

test "loads the standard library apart from a project file with the same name" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, "src");
    try tmp.dir.createDirPath(io, "std");
    try tmp.dir.writeFile(io, .{ .sub_path = "src/main.poplar", .data = "import \"std\";\nimport \"std.poplar\";\nmcfun one() {}\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "src/std.poplar", .data = "mcfun two() {}\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "std/std.poplar", .data = "import \"more.poplar\";\nmcfun three() {}\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "std/more.poplar", .data = "mcfun four() {}\n" });

    var src_dir = try tmp.dir.openDir(io, "src", .{});
    defer src_dir.close(io);
    const std_path = try tmp.dir.realPathFileAlloc(io, "std", arena.allocator());

    const command_tree = try Commands.load(arena.allocator());
    var compiler = Compiler.init(arena.allocator(), &command_tree);

    try std.testing.expect(try loadForTest(arena.allocator(), io, src_dir, std_path, &compiler));
    try std.testing.expectEqual(4, compiler.functions.count());
}

test "makes a namespace from a project name" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    const namespace = try namespaceFromName(arena.allocator(), "My Pack!");
    try std.testing.expectEqualStrings("my_pack_", namespace);
    try std.testing.expect(Config.isValidResourceName(namespace));
}

test "a name that the project and std both define is reported in the project file" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, "src");
    try tmp.dir.createDirPath(io, "std");
    try tmp.dir.writeFile(io, .{ .sub_path = "src/main.poplar", .data = "import \"std\";\n\nmcfun hello() {}\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "std/std.poplar", .data = "mcfun hello() {}\n" });

    var src_dir = try tmp.dir.openDir(io, "src", .{});
    defer src_dir.close(io);
    const std_path = try tmp.dir.realPathFileAlloc(io, "std", arena.allocator());

    const command_tree = try Commands.load(arena.allocator());
    var compiler = Compiler.init(arena.allocator(), &command_tree);
    _ = try loadForTest(arena.allocator(), io, src_dir, std_path, &compiler);

    try std.testing.expectEqual(1, compiler.errors.items.len);
    try std.testing.expectEqualStrings("src/main.poplar", compiler.errors.items[0].path);
    try std.testing.expectEqual(3, compiler.errors.items[0].line);
    try std.testing.expectEqualStrings("function 'hello' is already defined in std/std.poplar:1. Rename yours", compiler.errors.items[0].message);
}

test "only the std mcfuns that the project calls are written" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, "src");
    try tmp.dir.createDirPath(io, "std");
    try tmp.dir.writeFile(io, .{ .sub_path = "src/main.poplar", .data = "import \"std\";\nmcfun main() { /say {{double(2)}}; }\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "std/std.poplar", .data = "mcfun double(x) { return twice(x); }\nmcfun twice(x) { return x * 2; }\nmcfun unused() {}\n" });

    var src_dir = try tmp.dir.openDir(io, "src", .{});
    defer src_dir.close(io);
    const std_path = try tmp.dir.realPathFileAlloc(io, "std", arena.allocator());

    const command_tree = try Commands.load(arena.allocator());
    var compiler = Compiler.init(arena.allocator(), &command_tree);
    try std.testing.expect(try loadForTest(arena.allocator(), io, src_dir, std_path, &compiler));
    const program = try compiler.compile();

    var names: std.ArrayList([]const u8) = .empty;
    for (program.functions) |function| {
        if (!std.mem.startsWith(u8, function.name, "poplar/")) try names.append(arena.allocator(), function.name);
    }
    std.mem.sort([]const u8, names.items, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lessThan);
    try std.testing.expectEqualDeep(&[_][]const u8{ "double", "main", "twice" }, names.items);
}

// Loads `main.poplar` from `src_dir`, as `compile` does.
fn loadForTest(arena: std.mem.Allocator, io: std.Io, src_dir: std.Io.Dir, std_path: []const u8, compiler: *Compiler) !bool {
    var diagnostics: std.ArrayList(Diagnostic) = .empty;
    var loader: Loader = .{
        .allocator = arena,
        .io = io,
        .src_dir = src_dir,
        .src_path = try src_dir.realPathFileAlloc(io, ".", arena),
        .std_path = std_path,
        .overlay = null,
        .compiler = compiler,
        .diagnostics = &diagnostics,
    };
    defer loader.deinit();
    return loader.load("main.poplar");
}
