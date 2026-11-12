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
    ts_c.addIncludePath(b.path("vendor/tree-sitter/lib/include"));

    const exe = b.addExecutable(.{
        .name = "ccshl",
        .root_module = compilerModule(b, b.path("src/main.zig"), target, optimize, ts_c),
    });
    b.installArtifact(exe);

    // the compiler as a C library, for plugins; include/ccshl.h declares it
    const lib = b.addLibrary(.{
        .name = "ccshl",
        .linkage = .static,
        .root_module = compilerModule(b, b.path("src/capi.zig"), target, optimize, ts_c),
    });
    b.installArtifact(lib);
    b.installFile("include/ccshl.h", "include/ccshl.h");

    // a plugin over it: unused bindings, and the type of every binding
    const inspect = b.addExecutable(.{
        .name = "cshl-inspect",
        .root_module = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true }),
    });
    inspect.root_module.addCSourceFile(.{ .file = b.path("tools/inspect.c"), .flags = &.{"-std=c11"} });
    inspect.root_module.addIncludePath(b.path("include"));
    inspect.root_module.linkLibrary(lib);
    b.installArtifact(inspect);

    // the language server, over the library; wheels (a submodule) is only
    // headers
    const lsp = b.addExecutable(.{
        .name = "cshl-lsp",
        .root_module = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true }),
    });
    lsp.root_module.addCSourceFiles(.{
        .files = &.{ "lsp/main.c", "lsp/json.c" },
        .flags = &.{ "-std=c23", "-fdefer-ts" },
    });
    lsp.root_module.addIncludePath(b.path("include"));
    lsp.root_module.addIncludePath(b.path("lsp/deps/wheels"));
    lsp.root_module.linkLibrary(lib);
    b.installArtifact(lsp);

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

/// The compiler with root as its root file: tree-sitter, the cshl grammar
/// and clap.
fn compilerModule(
    b: *std.Build,
    root: std.Build.LazyPath,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    ts_c: *std.Build.Step.TranslateC,
) *std.Build.Module {
    const m = b.createModule(.{
        .root_source_file = root,
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "tree_sitter", .module = ts_c.createModule() },
            .{ .name = "clap", .module = b.dependency("clap", .{}).module("clap") },
        },
        .link_libc = true,
    });
    m.addCSourceFile(.{
        .file = b.path("tree-sitter-cshl/src/parser.c"),
        .flags = &.{"-std=c11"},
    });
    m.addIncludePath(b.path("tree-sitter-cshl/src"));

    // tree-sitter's runtime, vendored (vendor/tree-sitter submodule) since
    // its own build.zig doesn't track this zig version's Build API.
    m.addCSourceFile(.{
        .file = b.path("vendor/tree-sitter/lib/src/lib.c"),
        .flags = &.{"-std=c11"},
    });
    m.addIncludePath(b.path("vendor/tree-sitter/lib/include"));
    m.addIncludePath(b.path("vendor/tree-sitter/lib/src"));
    m.addCMacro("_POSIX_C_SOURCE", "200112L");
    m.addCMacro("_DEFAULT_SOURCE", "");
    m.addCMacro("_BSD_SOURCE", "");
    m.addCMacro("_DARWIN_C_SOURCE", "");
    return m;
}
