const std = @import("std");
pub const node = union(enum(u8)) {
    pub const Reg = u32;
    pub const mathKind = enum(u8) {
        ADD,
        SUB,
        MUL,
        DIV,
        MOD,
        BAND,
        BOR,
        BXOR,
        SHL,
        SHR,
        // reesult type not the same
        EQ, // ==
        NE, // !=
        LT, // <
        GT, // >
        LE, // <=
        GE, // >=
        AND, // !!&&!!
        OR, // !!||!!
        XOR, // !!^!!
        CMP, // (a-b)?(a-b)<0?-1:1:0
    };
    pub const movKind = enum(u8) {
        // worth casting eveerything to char pointners
        VV, // memcpy(&r,&l,size)
        VP, // memcpy(&r,l,size)
        PV, // memcpy(r,&l,size)
        PP, // memcpy(r,l,size)
    };
    mov: struct {
        kind: movKind,
        l: Reg,
        r: Reg,
        size: usize,
    },
    // read from offset off into register d from rom
    // there are no globals alowed, so no equivalet 'ram'
    rom: struct { d: Reg, off: usize },
    math: struct { // only integers and pointers, pointers as whatever usize is
        op: mathKind,
        l: Reg,
        r: Reg,
        d: Reg,
    },
    // only ints and pointers
    // TODO: ub?
    cast: struct { l: Reg, d: Reg },
    call: struct { @"fn": Reg, d: Reg, args: [:std.math.maxInt(Reg)]Reg },
    arg: struct { idx: u32, d: Reg },
    ret: Reg,
    // d is a pointer, d = &l
    // element pointeer would be an addition after this or something
    ldp: struct { l: Reg, d: Reg },

    @"if": Reg,
    @"else": void,
    endif: void,

    loop: void,
    repeat: u32, // un-nesting level - 1
    endloop: void,
    c: []const u8,
};
pub const Ir = struct {
    loc: *const @import("ast.zig").SrcRef,
    node: node,
};
