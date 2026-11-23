const std = @import("std");
const List = std.ArrayList;
const Ir = @import("ir.zig").Ir;
const Ast = @import("ast.zig").Ast;

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
    children: List(struct { Type, ?[*]u8 }),
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
    //ram : List(u8),
    functions: List(Function) = .empty,
    place: *Scope,
};
