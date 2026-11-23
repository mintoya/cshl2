const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const ir_preprocess = b.addSystemCommand(&.{ "zig", "cc", "-std=c23", "-fdefer-ts", "-Wno-pragma-once-outside-header", "-E", "-P" });
    ir_preprocess.addFileArg(b.path("src/ir.c"));
    ir_preprocess.addArg("-o");
    const ir_source = ir_preprocess.addOutputFileArg("ir-expanded.h");
    const ir_c = b.addTranslateC(.{
        .root_source_file = ir_source,
        .target = target,
        .optimize = optimize,
    });
    ir_c.addCFlags(&.{
        "-cflags",
        "-std=c23",
        "-fdefer-ts",
        "--",
    });
    const ir_module = ir_c.createModule();
    const install_header = b.addInstallFileWithDir(ir_source, .header, "ccshl_ir.h");
    b.step("ir-header", "Install the shared C instruction header").dependOn(&install_header.step);
    const ir_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/ir.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "ir_c", .module = ir_module }},
    }) });
    const run_ir_tests = b.addRunArtifact(ir_tests);
    b.step("test-ir", "Test the C-derived instruction types").dependOn(&run_ir_tests.step);

    const exe = b.addExecutable(.{
        .name = "ccshl",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "ir_c", .module = ir_module },
                .{ .name = "clap", .module = b.dependency("clap", .{}).module("clap") },
            },
        }),
    });

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
    test_step.dependOn(&run_ir_tests.step);
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_exe_tests.step);

    const check_exe = b.addExecutable(.{ .name = "ccshl", .root_module = exe.root_module });
    const check_step = b.step("check", "Compile without installing (used by ZLS build-on-save)");
    check_step.dependOn(&check_exe.step);
    check_step.dependOn(&ir_tests.step);
    check_step.dependOn(&mod_tests.step);
}
