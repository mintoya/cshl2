const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // tree-sitter's C API plus the generated cshl grammar.
    const ts_c = b.addTranslateC(.{
        .root_source_file = b.path("src/tree_sitter.h"),
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = "ccshl",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "tree_sitter", .module = ts_c.createModule() },
                .{ .name = "clap", .module = b.dependency("clap", .{}).module("clap") },
            },
            .link_libc = true,
        }),
    });
    exe.root_module.addCSourceFile(.{
        .file = b.path("tree-sitter-cshl/src/parser.c"),
        .flags = &.{"-std=c11"},
    });
    exe.root_module.addIncludePath(b.path("tree-sitter-cshl/src"));
    exe.root_module.linkSystemLibrary("tree-sitter", .{});

    b.installArtifact(exe);

    const run_step = b.step("run", "Run the app");

    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);

    run_cmd.step.dependOn(b.getInstallStep());

    run_cmd.addPassthruArgs();

    const mod_tests = b.addTest(.{
        .root_module = exe.root_module,
    });

    const run_mod_tests = b.addRunArtifact(mod_tests);

    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });

    const run_exe_tests = b.addRunArtifact(exe_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_exe_tests.step);

    // the language tests: every test/*.cshl must give true
    const run_cshl = b.addRunArtifact(exe);
    run_cshl.addArgs(&.{ "--test", "test", "--zig", b.graph.zig_exe });
    run_cshl.setCwd(b.path("."));
    run_cshl.has_side_effects = true;
    test_step.dependOn(&run_cshl.step);
}
