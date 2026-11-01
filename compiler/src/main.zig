const std = @import("std");
const cli = @import("cli/root.zig");
const Project = @import("Project.zig");

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
    var std_path = init.environ_map.get("POPLAR_STD") orelse try Project.installedStdPath(init.arena.allocator(), io);
    var args = init.minimal.args.iterate();
    root.runAndExit(&args, .{ .data = @ptrCast(&std_path) });
}

test {
    _ = @import("Commands.zig");
    _ = @import("Compiler.zig");
    _ = @import("Config.zig");
    _ = @import("Lexer.zig");
    _ = @import("Lsp.zig");
    _ = @import("Optimizer.zig");
    _ = @import("Parser.zig");
    _ = @import("Project.zig");
    _ = @import("Writer.zig");
}
