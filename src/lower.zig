const std = @import("std");
const List = std.ArrayList;
const SGList = @import("sglist.zig").SgList;
const Ir = @import("ir.zig").Ir;
const Ast = @import("ast.zig").Ast;
const SrcRef = @import("ast.zig").SrcRef;

const Types = @import("types.zig");
const Type = Types.Type;
const TypeIdx = Types.TypeIdx;
const TypeMap = Types.TypeMap;
const Value = Types.Value;
const Function = struct {
    text: Ast,
    versions: List(struct {
        ir: List(Ir) = .empty,
        scope: *Scope,
    }) = .empty,
    scope: *Scope,
};
const Scope = struct {
    const Self = @This();
    names: std.StringHashMapUnmanaged(struct {
        parent: ?*const Self,
        idx: u32,
    }),
    children: List(struct { Type, ?*u8 }),
    kind: union(enum(u8)) {
        default: u32, // {...} // should carry over loop nestedness
        loop: u32, // @loop {...}
        function: []const Type, // @fn[...,T,{...}]
        structure: TypeIdx, // @struct {...}
        //   speculative?
    },
};
pub const State = struct {
    typemap: TypeMap = .empty,
    rom: List(u8) = .empty,
    functions: List(Function) = .empty,
    scopes: SGList(Scope, 5, 32) = .empty,
    place: *Scope,
    decors: Types.DecorMap = .empty,
    pub fn init() @This() {}
    pub fn compile(self: *@This(), alloc: std.mem.Allocator, text: Ast) !u32 {
        return switch (text) {
            .str => |s| self.compileString(alloc, s),
            .num => |n| self.compileInt(alloc, n),
            else => error.UnImplemented,
        };
    }
    pub fn pushRom(self: *@This(), alloc: std.mem.Allocator, bytes: []const u8) !u32 {
        _ = self;
        _ = alloc;
        _ = bytes;
        return error.UnImplemented;
    }
    pub fn newValue(self: *@This(), alloc: std.mem.Allocator, t: Type) !u32 {
        _ = self;
        _ = alloc;
        _ = t;
        return error.UnImplemented;
    }
    pub fn compileString(self: *@This(), alloc: std.mem.Allocator, ref: SrcRef) !u32 {
        const raw = ref.gets();
        var bytes: List(u8) = try .initCapacity(alloc, raw.len);
        errdefer bytes.deinit(alloc);
        var i: usize = 0;
        while (i < raw.len) {
            if (raw[i] != '\\') {
                bytes.appendAssumeCapacity(raw[i]);
                i += 1;
                continue;
            }
            switch (raw[i + 1]) {
                '"',
                '\\',
                => |c| bytes.appendAssumeCapacity(c),
                'n' => bytes.appendAssumeCapacity('\n'),
                'r' => bytes.appendAssumeCapacity('\r'),
                't' => bytes.appendAssumeCapacity('\t'),
                '0' => bytes.appendAssumeCapacity(0),
                'x' => {
                    // \x{hex hex ...}: one byte per group; the parser checked the shape
                    const close = std.mem.indexOfScalarPos(u8, raw, i, '}').?;
                    var groups = std.mem.tokenizeAny(u8, raw[i + 3 .. close], " \t");
                    while (groups.next()) |g| bytes.appendAssumeCapacity(try std.fmt.parseInt(u8, g, 16));
                    i = close + 1;
                    continue;
                },
                else => unreachable,
            }
            i += 2;
        }
        const arr = try self.typemap.add(alloc, &self.decors, .{ .arr = .{
            .len = bytes.items.len,
            .elem = .{
                .raw = .uchar,
                .decorators = .{
                    .@"comptime" = true,
                    .@"&" = false,
                    .decor = try self.decors.getOrSet(alloc, &[_]Types.Decor{.{}}),
                },
            },
        } });
        _ = arr;
        return error.UnImplemeented;
    }
    pub fn compileInt(self: *@This(), alloc: std.mem.Allocator, ref: SrcRef) !u32 {
        const text = ref.gets();
        const base: u8, const digits = if (std.mem.startsWith(u8, text, "0x"))
            .{ 16, text[2..] }
        else if (std.mem.startsWith(u8, text, "0b"))
            .{ 2, text[2..] }
        else
            .{ 10, text };
        var n: std.math.big.int.Managed = try .init(alloc);
        errdefer n.deinit();
        try n.setString(base, digits);
        const mem = try alloc.create(std.math.big.int.Const);
        mem.* = n.toConst();
        return self.push(alloc, try self.plain(alloc, .int, true), @ptrCast(mem));
    }
};
