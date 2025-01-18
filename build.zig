const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const lib_mod = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const lib = b.addStaticLibrary(.{
        .name = "zig_coworkers",
        .root_module = lib_mod,
        .optimize = optimize,
    });
    b.installArtifact(lib);

    const lib_unit_tests = b.addTest(.{
        .root_module = lib_mod,
    });
    const run_lib_unit_tests = b.addRunArtifact(lib_unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_lib_unit_tests.step);

    const docs_install = b.addInstallDirectory(.{
        .source_dir = lib.getEmittedDocs(),
        .install_dir = .prefix,
        .install_subdir = "docs",
    });

    const docs_install_step = b.step("install_docs", "Install docs into zig-out/docs");
    docs_install_step.dependOn(&docs_install.step);

    const docs_show = b.addSystemCommand(&.{
        "python3",
        "-m",
        "http.server",
        "-b",
        "127.0.0.1",
        "8000",
        "-d",
        "zig-out/docs/",
    });
    const docs_show_step = b.step("show_docs", "Open an http server that serves the docs");
    docs_show_step.dependOn(&docs_install.step);
    docs_show_step.dependOn(&docs_show.step);
}
