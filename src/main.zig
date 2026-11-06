const std = @import("std");
const cli = @import("cli/root.zig");
const project = @import("project.zig");

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    var stdout_buffer: [4096]u8 = undefined;
    // Streaming, so that stdout and stderr redirected to one file do not write over each other.
    var stdout_writer = std.Io.File.Writer.initStreaming(.stdout(), io, &stdout_buffer);
    var stdin_buffer: [1024]u8 = undefined;
    var stdin_reader = std.Io.File.Reader.init(.stdin(), io, &stdin_buffer);

    const root = try cli.register(.{
        .allocator = init.gpa,
        .io = io,
        .writer = &stdout_writer.interface,
        .reader = &stdin_reader.interface,
    });
    // `zig build run` and the e2e harness run a cached copy of the binary, so they point to `std/` with `POPLAR_STD`.
    var shared: cli.Shared = .{
        .std_path = init.environ_map.get("POPLAR_STD") orelse try project.installedStdPath(init.arena.allocator(), io),
        .color = init.environ_map.get("NO_COLOR") == null and (std.Io.File.stdout().isTty(io) catch false),
        .environ_map = init.environ_map,
    };
    // The allocator form works on every platform; Windows and WASI have no plain `iterate`.
    var args = try init.minimal.args.iterateAllocator(init.arena.allocator());
    root.runAndExit(&args, .{ .data = @ptrCast(&shared) });
}

test {
    _ = @import("CommandTree.zig");
    _ = @import("Compiler.zig");
    _ = @import("Config.zig");
    _ = @import("dot_env.zig");
    _ = @import("Lexer.zig");
    _ = @import("Lsp.zig");
    _ = @import("optimizer.zig");
    _ = @import("Parser.zig");
    _ = @import("project.zig");
    _ = @import("datapack_writer.zig");
}
