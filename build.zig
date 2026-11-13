const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    b.dependOnDirectoryContents(b.path("tree-sitter-cshl"));
    const parser_dir = b.root.joinString(b.allocator, "tree-sitter-cshl/src") catch @panic("OOM");
    if (std.Io.Dir.cwd().access(b.graph.io, parser_dir, .{})) |_| {
        b.dependOnDirectoryContents(b.path("tree-sitter-cshl/src"));
    } else |err| switch (err) {
        error.FileNotFound => {},
        else => std.debug.panic("cannot access parser directory: {t}", .{err}),
    }
    const generate_parser: ?*std.Build.Step.Run = blk: {
        const parser_path = b.root.joinString(b.allocator, "tree-sitter-cshl/src/parser.c") catch @panic("OOM");
        std.Io.Dir.cwd().access(b.graph.io, parser_path, .{}) catch |err| switch (err) {
            error.FileNotFound => {
                const generate = b.addSystemCommand(&.{ "tree-sitter", "generate" });
                generate.setCwd(b.path("tree-sitter-cshl"));
                break :blk generate;
            },
            else => std.debug.panic("cannot access generated parser: {t}", .{err}),
        };
        break :blk null;
    };

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
                .{ .name = "ir_c", .module = ir_module },
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
    if (generate_parser) |generate| exe.step.dependOn(&generate.step);

    b.installArtifact(exe);

    const run_step = b.step("run", "Run the app");

    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);

    run_cmd.step.dependOn(b.getInstallStep());

    run_cmd.addPassthruArgs();

    const mod_tests = b.addTest(.{
        .root_module = exe.root_module,
    });
    if (generate_parser) |generate| mod_tests.step.dependOn(&generate.step);

    const run_mod_tests = b.addRunArtifact(mod_tests);

    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });
    if (generate_parser) |generate| exe_tests.step.dependOn(&generate.step);

    const run_exe_tests = b.addRunArtifact(exe_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_ir_tests.step);
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_exe_tests.step);
}
