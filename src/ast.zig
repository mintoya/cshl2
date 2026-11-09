const std = @import("std");
const List = std.ArrayList;
pub const FileItem = union(enum) {
    disk: struct {
        filename: [:0]const u8,
        content: []const u8,
    },
    memory: List(u8),
    pub fn fromfileAlloc(alloc: std.mem.Allocator, io: std.Io, name: [:0]const u8) !@This() {
        return .{ .disk = .{
            .filename = name,
            .content = try std.Io.Dir.readFileAlloc(
                std.Io.Dir.cwd(),
                io,
                name,
                alloc,
                .limited(std.math.maxInt(u32)),
            ),
        } };
    }
    pub fn bytes(self: *const @This()) []const u8 {
        return switch (self.*) {
            .disk => |disk| disk.content,
            .memory => |memory| memory.items,
        };
    }
};
pub const SrcRef = struct {
    src: *const FileItem,
    off: u32,
    len: u32,
    pub fn gets(self: @This()) []const u8 {
        return self.src.bytes()[self.off .. self.len + self.off];
    }
};
test "srcref gets" {
    var bytes = "hello world".*;
    var buffer: FileItem = .{ .memory = .initBuffer(&bytes) };
    buffer.memory.items.len = bytes.len;
    const bifref: SrcRef = .{ .src = &buffer, .len = 4, .off = 1 };
    try std.testing.expect(std.mem.eql(
        u8,
        "ello",
        bifref.gets(),
    ));
}
pub const Ast = union(enum(u8)) {
    nil: SrcRef,
    str: SrcRef,
    num: SrcRef,
    id: SrcRef,
    call: []const Ast,

    /// Prints the tree as an s-expression: `(f a b)`, strings in quotes.
    pub fn format(self: Ast, w: *std.Io.Writer) std.Io.Writer.Error!void {
        switch (self) {
            .nil => try w.writeAll("nul"),
            .str => |s| try w.print("\"{s}\"", .{s.gets()}),
            .num, .id => |s| try w.writeAll(s.gets()),
            .call => |items| {
                try w.writeByte('(');
                for (items, 0..) |item, i| {
                    if (i != 0) try w.writeByte(' ');
                    try item.format(w);
                }
                try w.writeByte(')');
            },
        }
    }
};
