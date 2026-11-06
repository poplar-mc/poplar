const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "poplar",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const mcmeta = b.dependency("mcmeta", .{});
    exe.root_module.addAnonymousImport("commands.json", .{ .root_source_file = mcmeta.path("commands/data.json") });
    exe.root_module.addAnonymousImport("mcmeta_version.json", .{ .root_source_file = mcmeta.path("version.json") });
    exe.root_module.addAnonymousImport("registries.json", .{ .root_source_file = mcmeta.path("registries/data.min.json") });
    exe.root_module.addAnonymousImport("poplar.schema.json", .{ .root_source_file = b.path("schema/poplar.schema.json") });

    const zli = b.dependency("zli", .{ .target = target, .optimize = optimize });
    exe.root_module.addImport("zli", zli.module("zli"));
    const lsp_kit = b.dependency("lsp_kit", .{ .target = target, .optimize = optimize });
    exe.root_module.addImport("lsp", lsp_kit.module("lsp"));

    const build_options = b.addOptions();
    build_options.addOption([]const u8, "version", @import("build.zig.zon").version);
    exe.root_module.addOptions("build_options", build_options);

    b.installArtifact(exe);
    // The standard library goes next to the binary: `bin/poplar` and `lib/poplar/std/`.
    b.installDirectory(.{ .source_dir = b.path("std"), .install_dir = .lib, .install_subdir = "poplar/std" });
    const std_source_path = b.root.joinString(b.allocator, "std") catch @panic("OOM");

    const run_step = b.step("run", "Build and run poplar");

    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);

    run_cmd.step.dependOn(b.getInstallStep());

    run_cmd.addPassthruArgs();
    run_cmd.setEnvironmentVariable("POPLAR_STD", std_source_path);

    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });

    const run_exe_tests = b.addRunArtifact(exe_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_exe_tests.step);

    const accept_eula = b.option(bool, "accept-eula", "Accept the Minecraft EULA (https://aka.ms/MinecraftEULA) for the e2e server") orelse false;

    const e2e_exe = b.addExecutable(.{
        .name = "e2e",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/e2e.zig"),
            .target = b.graph.host,
            .optimize = optimize,
        }),
    });

    const run_e2e = b.addRunArtifact(e2e_exe);
    run_e2e.addArtifactArg(exe);
    run_e2e.setEnvironmentVariable("POPLAR_STD", std_source_path);
    run_e2e.addFileArg(mcmeta.path("version.json"));
    run_e2e.addDirectoryArg(b.path("tests/e2e"));
    run_e2e.setCwd(b.path("."));
    run_e2e.addArg(".e2e");
    if (accept_eula) run_e2e.addArg("--accept-eula");
    run_e2e.has_side_effects = true;

    const e2e_step = b.step("e2e", "Run the test projects on a Minecraft server");
    e2e_step.dependOn(&run_e2e.step);
}
