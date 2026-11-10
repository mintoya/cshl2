const std = @import("std");
const Ast = @import("ast.zig");
const parse = @import("parse.zig");
const clap = @import("clap");
test "inc" {
    _ = Ast;
    _ = parse;
    _ = @import("types.zig");
}

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();

    const params = comptime clap.parseParamsComptime(
        \\-h, --help  Display this help and exit.
        \\<file>      The .cshl file to parse.
        \\
    );
    const parsers = comptime .{ .file = clap.parsers.string };
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
    const path = res.positionals[0] orelse {
        std.debug.print("ccshl: missing <file>; see --help\n", .{});
        std.process.exit(2);
    };

    const file = try arena.create(Ast.FileItem);
    file.* = try .fromfileAlloc(arena, init.io, try arena.dupeSentinel(u8, path, 0));

    var diag: parse.Diagnostic = .{};
    const tree = parse.parse(arena, file, &diag) catch |err| switch (err) {
        error.SyntaxError => {
            const src = file.bytes();
            const line = std.mem.count(u8, src[0..diag.off], "\n") + 1;
            const col = diag.off - (if (std.mem.lastIndexOfScalar(u8, src[0..diag.off], '\n')) |nl| nl + 1 else 0) + 1;
            if (diag.missing)
                std.debug.print("{s}:{d}:{d}: syntax error: missing `{s}`\n", .{ path, line, col, diag.kind })
            else
                std.debug.print("{s}:{d}:{d}: syntax error\n", .{ path, line, col });
            std.process.exit(1);
        },
        else => return err,
    };
    std.debug.print("{f}\n", .{tree});
}
