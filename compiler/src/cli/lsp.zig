const std = @import("std");
const zli = @import("zli");
const lsp = @import("lsp");
const Lsp = @import("../Lsp.zig");
const root = @import("root.zig");

pub fn register(init_options: zli.InitOptions) !*zli.Command {
    return zli.Command.init(init_options, .{
        .name = "lsp",
        .description = "Run the language server. An editor starts it and talks to it over stdin and stdout",
    }, run);
}

fn run(ctx: zli.CommandContext) !void {
    var read_buffer: [4096]u8 = undefined;
    var transport: lsp.Transport.Stdio = .init(&read_buffer, .stdin(), .stdout());
    var server: Lsp = .init(ctx.allocator, ctx.io, &transport.transport, root.stdPath(ctx));
    defer server.deinit();
    try lsp.basic_server.run(ctx.io, ctx.allocator, &transport.transport, &server, std.log.err);
}
