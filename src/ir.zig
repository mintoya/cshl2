const std = @import("std");
pub const node = union(enum(u8)) {
    pub const Reg = u32;
    pub const mathKind = enum(u8) {
        ADD,
        SUB,
        MUL,
        DIV,
        MOD,
        EQ,
        NE,
        LT,
        GT,
        LE,
        GE,
        // it's incredibly easy to implement short circuiting in the language, so that's not happening here
        AND,
        OR,
        XOR,
        BAND,
        BOR,
        BXOR,
        SHL,
        SHR,
        CMP,
    };
    pub const movKind = enum(u8) { VV, VP, PP };
    mov: struct {
        kind: movKind,
        off: Reg,
        l: Reg,
        r: Reg,
    },
    // read from offset off into register d from rom
    // globals are still out on the language
    rom: struct { d: Reg, off: usize },
    math: struct { // only integers and pointers, pointers as whatever usize is
        op: mathKind,
        l: Reg,
        r: Reg,
        d: Reg,
    },
    // int int, int ptr, ptr ptr
    cast: struct { l: Reg, d: Reg },
    call: struct { @"fn": Reg, d: Reg, args: [:std.math.maxInt(Reg)]Reg },
    arg: struct { idx: u32, d: Reg },
    // d is a pointer, d = &l
    ldp: struct { l: Reg, d: Reg },

    @"if": Reg,
    @"else": void,
    endif: void,

    loop: void,
    repeat: void,
    endloop: void,

    // C text as the value of d; d is void for a statement
    cexpr: struct { d: Reg, text: []const u8 },
};
