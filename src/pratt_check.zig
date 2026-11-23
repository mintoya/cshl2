//! The hand-written parser (pratt.zig) against the tree-sitter one
//! (parse.zig): on every .cshl file here, every case in the tree-sitter
//! corpus, and every file cut off at each line, they have to give the same
//! tree, down to where each leaf is in the source, or both reject it.
const std = @import("std");
const ast = @import("ast.zig");
const pratt = @import("pratt.zig");
const ts = @import("parse.zig");
const Ast = ast.Ast;

fn isBuiltin(r: ast.SrcRef) bool {
    return r.src == &pratt.builtin_file or r.src == &ts.builtin_file;
}
fn same(a: Ast, b: Ast) bool {
    if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
    return switch (a) {
        .call => |xs| xs.len == b.call.len and for (xs, b.call) |x, y| {
            if (!same(x, y)) break false;
        } else true,
        inline .nil, .str, .num, .id => |r, tag| blk: {
            const o = @field(b, @tagName(tag));
            break :blk isBuiltin(r) == isBuiltin(o) and r.off == o.off and r.len == o.len;
        },
    };
}

/// null when they agree, else what differs
fn compare(a: std.mem.Allocator, name: []const u8, source: []const u8) !?[]const u8 {
    const file: ast.FileItem = .{ .disk = .{ .filename = "<check>", .content = source } };
    var pd: pratt.Diagnostic = .{};
    const p = pratt.parse(a, &file, &pd);
    const t = ts.parse(a, &file, null);
    if (p) |pt| {
        if (t) |tt| {
            if (same(pt, tt)) return null;
            return try std.fmt.allocPrint(a, "{s}: different trees\n  pratt:       {f}\n  tree-sitter: {f}", .{ name, pt, tt });
        } else |_| return try std.fmt.allocPrint(a, "{s}: tree-sitter rejects it, pratt gives {f}", .{ name, pt });
    } else |e| {
        if (e != error.SyntaxError) return e;
        if (t) |tt| return try std.fmt.allocPrint(a, "{s}: pratt rejects it at {d} ({s}), tree-sitter gives {f}", .{ name, pd.off, pd.msg, tt }) else |_| return null;
    }
}

fn cshlFiles(gpa: std.mem.Allocator, io: std.Io, dir_path: []const u8, out: *std.ArrayList([]const u8)) !void {
    var dir = try std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true });
    defer dir.close(io);
    var it = dir.iterate();
    while (try it.next(io)) |e| if (e.kind == .file and std.mem.endsWith(u8, e.name, ".cshl"))
        try out.append(gpa, try std.fs.path.join(gpa, &.{ dir_path, e.name }));
}

test "pratt and tree-sitter parse the same" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    var problems: std.ArrayList([]const u8) = .empty;
    var checked: usize = 0;

    var paths: std.ArrayList([]const u8) = .empty;
    for ([_][]const u8{ ".", "test", "test/lib" }) |d| try cshlFiles(a, io, d, &paths);
    for (paths.items) |path| {
        const source = try std.Io.Dir.cwd().readFileAlloc(io, path, a, .limited(1 << 20));
        checked += 1;
        if (try compare(a, path, source)) |m| try problems.append(a, m);
        // cut off after each line
        var i: usize = 0;
        while (std.mem.indexOfScalarPos(u8, source, i, '\n')) |nl| : (i = nl + 1) {
            checked += 1;
            const name = try std.fmt.allocPrint(a, "{s} up to line {d}", .{ path, std.mem.count(u8, source[0..nl], "\n") + 1 });
            if (try compare(a, name, source[0..nl])) |m| try problems.append(a, m);
        }
    }

    // the corpus: a ===== title ===== header, the source, then --- and the
    // expected tree
    const corpus = try std.Io.Dir.cwd().readFileAlloc(io, "tree-sitter-cshl/test/corpus/expressions.txt", a, .limited(1 << 20));
    var sections = std.mem.splitSequence(u8, corpus, "\n---\n");
    while (sections.next()) |sec| {
        // the source follows the second ===== line of the header
        const bar = "==================\n";
        const first = std.mem.lastIndexOf(u8, sec, bar) orelse continue;
        const title_start = std.mem.lastIndexOf(u8, sec[0..first], bar) orelse continue;
        const title = std.mem.trim(u8, sec[title_start + bar.len .. first], "\n");
        checked += 1;
        if (try compare(a, title, sec[first + bar.len ..])) |m| try problems.append(a, m);
    }

    for (problems.items) |m| std.debug.print("{s}\n", .{m});
    if (problems.items.len != 0) std.debug.print("{d} of {d} disagree\n", .{ problems.items.len, checked });
    try std.testing.expectEqual(@as(usize, 0), problems.items.len);
}
