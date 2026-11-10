const std = @import("std");
const Ast = @import("ast.zig");
const parse = @import("parse.zig");
const eval = @import("eval.zig");
const c_backend = @import("c.zig");
const clap = @import("clap");
test "inc" {
    _ = Ast;
    _ = parse;
    _ = @import("types.zig");
    _ = @import("eval.zig");
}

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();

    const params = comptime clap.parseParamsComptime(
        \\-h, --help  Display this help and exit.
        \\--ast              Print the file's ast instead of running it.
        \\--emit-c           Print the file lowered to C instead of running it.
        \\--test <dir>       Run every .cshl file in dir; each must give true.
        \\--zig <path>       The zig whose `zig cc` compiles the tests' C (default: zig).
        \\<file>             The .cshl file to run.
        \\
    );
    const parsers = comptime .{ .file = clap.parsers.string, .dir = clap.parsers.string, .path = clap.parsers.string };
    var cdiag: clap.Diagnostic = .{};
    var res = clap.parse(clap.Help, &params, parsers, init.minimal.args, .{
        .diagnostic = &cdiag,
        .allocator = init.gpa,
    }) catch |err| {
        try cdiag.reportToFile(init.io, .stderr(), err);
        std.process.exit(2);
    };
    defer res.deinit();

    if (res.args.help != 0)
        return clap.helpToFile(init.io, .stderr(), clap.Help, &params, .{});
    if (res.args.@"test") |dir| std.process.exit(try runTests(init, dir, res.args.zig orelse "zig"));
    const path = res.positionals[0] orelse {
        std.debug.print("ccshl: missing <file>; see --help\n", .{});
        std.process.exit(2);
    };

    if (res.args.ast != 0) {
        const file = try arena.create(Ast.FileItem);
        file.* = try .fromfileAlloc(arena, init.io, try arena.dupeSentinel(u8, path, 0));
        var diag: parse.Diagnostic = .{};
        const tree = parse.parse(arena, file, &diag) catch |err| switch (err) {
            error.SyntaxError => {
                report(path, file.bytes(), diag.off, if (diag.missing) "syntax error: missing a token" else "syntax error");
                std.process.exit(1);
            },
            else => return err,
        };
        std.debug.print("{f}\n", .{tree});
        return;
    }

    if (res.args.@"emit-c" != 0) {
        var e = try eval.Eval.init(arena, init.io);
        const code = lowerToC(arena, &e, path) catch |err| switch (err) {
            error.CompileError => {
                reportDiag(&e, path);
                std.process.exit(1);
            },
            else => return err,
        };
        var buf: [4096]u8 = undefined;
        var out = std.Io.File.stdout().writer(init.io, &buf);
        try out.interface.writeAll(code);
        try out.interface.flush();
        return;
    }

    var e = try eval.Eval.init(arena, init.io);
    const v = e.evalFile(path, null) catch |err| switch (err) {
        error.CompileError => {
            if (e.diag.at) |at| switch (at.src.*) {
                .disk => |d| report(d.filename, d.content, at.off, e.diag.msg),
                .memory => std.debug.print("<macro>: error: {s}\n", .{e.diag.msg}),
            } else std.debug.print("{s}: error: {s}\n", .{ path, e.diag.msg });
            std.process.exit(1);
        },
        else => return err,
    };
    std.debug.print("{f}\n", .{e.fmtValue(v)});
}

/// Lowers path to C, compiles it with `zig cc` and runs it; null when it
/// prints true, otherwise why not. zig cc's Debug mode traps on undefined
/// behaviour, so the generated C is checked for that too.
fn compiledFails(init: std.process.Init, gpa: std.mem.Allocator, path: []const u8, name: []const u8, zig: []const u8) !?[]const u8 {
    var e = try eval.Eval.init(gpa, init.io);
    const code = lowerToC(gpa, &e, path) catch |err| switch (err) {
        error.CompileError => return try std.fmt.allocPrint(gpa, "lowering: {s}", .{e.diag.msg}),
        else => return err,
    };
    const dir = ".zig-cache/cshl-c";
    try std.Io.Dir.cwd().createDirPath(init.io, dir);
    const c_path = try std.fmt.allocPrint(gpa, "{s}/{s}.c", .{ dir, name });
    const exe_path = try std.fmt.allocPrint(gpa, "{s}/{s}.out", .{ dir, name });
    try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = c_path, .data = code });
    const cc = try std.process.run(gpa, init.io, .{ .argv = &.{ zig, "cc", "-std=c11", "-w", "-o", exe_path, c_path } });
    if (!cc.term.success()) return try std.fmt.allocPrint(gpa, "zig cc failed on {s}:\n{s}", .{ c_path, cc.stderr });
    const run = try std.process.run(gpa, init.io, .{ .argv = &.{exe_path} });
    if (!run.term.success()) return try std.fmt.allocPrint(gpa, "{s} didn't exit cleanly", .{exe_path});
    if (!std.mem.eql(u8, run.stdout, "true\n")) return try std.fmt.allocPrint(gpa, "printed {s}", .{std.mem.trimEnd(u8, run.stdout, "\n")});
    return null;
}

/// Lowers a file and writes it as C. An unsupported construct is reported
/// as a compile error.
fn lowerToC(gpa: std.mem.Allocator, e: *eval.Eval, path: []const u8) ![]const u8 {
    try e.lowerFile(path);
    var out: std.Io.Writer.Allocating = .init(gpa);
    var why: []const u8 = "";
    c_backend.write(gpa, e, &out.writer, &why) catch |err| switch (err) {
        error.Unsupported => {
            e.diag = .{ .msg = try std.fmt.allocPrint(gpa, "can't write C: {s}", .{why}) };
            return error.CompileError;
        },
        else => return err,
    };
    return out.written();
}

fn reportDiag(e: *eval.Eval, path: []const u8) void {
    if (e.diag.at) |at| switch (at.src.*) {
        .disk => |d| report(d.filename, d.content, at.off, e.diag.msg),
        .memory => std.debug.print("<macro>: error: {s}\n", .{e.diag.msg}),
    } else std.debug.print("{s}: error: {s}\n", .{ path, e.diag.msg });
}

fn report(path: []const u8, src: []const u8, off: u32, msg: []const u8) void {
    const line = std.mem.count(u8, src[0..off], "\n") + 1;
    const col = off - (if (std.mem.lastIndexOfScalar(u8, src[0..off], '\n')) |nl| nl + 1 else 0) + 1;
    std.debug.print("{s}:{d}:{d}: error: {s}\n", .{ path, line, col, msg });
}

/// The `// error: text` in a file's leading comments: the file must fail with
/// a message containing text.
fn expectedError(source: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, source, '\n');
    while (lines.next()) |line| {
        const t = std.mem.trim(u8, line, " \t\r");
        if (t.len == 0) continue;
        if (!std.mem.startsWith(u8, t, "//")) return null;
        const comment = std.mem.trim(u8, t[2..], " \t");
        if (std.mem.startsWith(u8, comment, "error:")) return std.mem.trim(u8, comment["error:".len..], " \t");
    }
    return null;
}

/// Runs each .cshl file in dir with a fresh evaluator. A file passes when it
/// gives true, or, with `// error: text` at the top, when it fails with a
/// message containing text. Returns the exit code.
fn runTests(init: std.process.Init, directory: []const u8, zig: []const u8) !u8 {
    const gpa = init.gpa;
    var dir = try std.Io.Dir.cwd().openDir(init.io, directory, .{ .iterate = true });
    defer dir.close(init.io);
    var names: std.ArrayList([]const u8) = .empty;
    defer {
        for (names.items) |name| gpa.free(name);
        names.deinit(gpa);
    }
    var it = dir.iterate();
    while (try it.next(init.io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".cshl")) continue;
        try names.append(gpa, try gpa.dupe(u8, entry.name));
    }
    std.mem.sort([]const u8, names.items, {}, struct {
        fn less(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.less);

    var failed: usize = 0;
    for (names.items) |name| {
        var arena: std.heap.ArenaAllocator = .init(gpa);
        defer arena.deinit();
        const path = try std.fs.path.join(arena.allocator(), &.{ directory, name });
        const source = try std.Io.Dir.cwd().readFileAlloc(init.io, path, arena.allocator(), .unlimited);
        const expected = expectedError(source);
        var e = try eval.Eval.init(arena.allocator(), init.io);
        if (e.evalFile(path, null)) |v| {
            const out = try std.fmt.allocPrint(arena.allocator(), "{f}", .{e.fmtValue(v)});
            if (expected == null and std.mem.eql(u8, out, "true")) {
                // the same file compiled to C must agree
                if (try compiledFails(init, arena.allocator(), path, name, zig)) |why| {
                    std.debug.print("FAIL {s} (C): {s}\n", .{ name, why });
                    failed += 1;
                    continue;
                }
                std.debug.print("PASS {s}\n", .{name});
                continue;
            }
            if (expected) |want|
                std.debug.print("FAIL {s}: expected an error containing \"{s}\", gave {s}\n", .{ name, want, out })
            else
                std.debug.print("FAIL {s}: gave {s}\n", .{ name, out });
        } else |err| switch (err) {
            error.CompileError => {
                if (expected) |want| if (std.mem.indexOf(u8, e.diag.msg, want) != null) {
                    std.debug.print("PASS {s}\n", .{name});
                    continue;
                };
                std.debug.print("FAIL {s}: ", .{name});
                if (expected) |want| std.debug.print("expected an error containing \"{s}\", got ", .{want});
                if (e.diag.at) |at| switch (at.src.*) {
                    .disk => |d| report(d.filename, d.content, at.off, e.diag.msg),
                    .memory => std.debug.print("<macro>: error: {s}\n", .{e.diag.msg}),
                } else std.debug.print("error: {s}\n", .{e.diag.msg});
            },
            else => return err,
        }
        failed += 1;
    }
    std.debug.print("{d} passed, {d} failed\n", .{ names.items.len - failed, failed });
    return if (failed != 0 or names.items.len == 0) 1 else 0;
}
