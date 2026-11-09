const std = @import("std");
pub const TypeIdx = enum(u32) {
    const Self = @This();

    bool,
    int,
    // c integer
    schar,
    sshort,
    sint,
    slong,
    slonglong,
    uchar,
    ushort,
    uint,
    ulong,
    ulonglong,
    //
    builtin,
    _,
    const cintTypes = enum(u8) {
        schar,
        sshort,
        sint,
        slong,
        slonglong,
        uchar,
        ushort,
        uint,
        ulong,
        ulonglong,
    };
    pub const BuiltinTypes = enum(u8) {
        void,
        bool,
        type,
        ast,
        inlineast,
        outlineast,
        any,
        int,
        schar,
        sshort,
        sint,
        slong,
        slonglong,
        uchar,
        ushort,
        uint,
        ulong,
        ulonglong,
        arr,
        ptr,
        refT,
        fnptr,
        @"comptime",
        @"const",
        @"volatile",
        @"struct",
        this,
        opaqueType,
        @"fn",
        returntype,
        @"if",
        loop,
        repeat,
        @"defer",
        yield,
        where,
        at,
        ref,
        comptime_alloc,
        comptime_free,
        stackptr,
        zero,
        len,
        get,
        ast_stringeq,
        apply,
        gensym,
        id,
        compileError,
        compiles,
        log,
        raw,
        typeof,
        sizeof,
        alignof,
        offsetof,
        membertype,
        fieldname,
        fieldval,
        fieldtype,
        //
        isptr,
        isreferance,
        isconst,
        isvolatile,
        iscomptime,
        //
        import,
        using,
        bind,
        unbind,
        path,
        cinclude,
        cexpr,
        @"+",
        @"-",
        @"*",
        @"/",
        @"%",
        @"==",
        @"!=",
        @"<",
        @">",
        @"<=",
        @">=",
        @"<=>",
        @"and",
        @"or",
        xor,
        band,
        bor,
        bxor,
        shl,
        shr,
        as,
        @"=",
        @".",
        @":",
        @"|>",
    };
    pub fn get_cint(this: Self) ?cintTypes {
        const fields = @typeInfo(cintTypes).@"enum".field_names;
        inline for (fields) |fieldname|
            if (this == @field(Self, fieldname))
                return @field(cintTypes, fieldname);
        return null;
    }
};
pub const Decor = enum(u2) { @"const", @"volatile", @"*", @"&" };
pub const Decors = packed struct(u128) {
    bits: u128 = 1,

    pub const capacity = 63;

    pub fn len(self: Decors) u7 {
        return @intCast((127 - @clz(self.bits)) / 2);
    }
    pub fn push(self: *Decors, d: Decor) void {
        std.debug.assert(self.len() < capacity);
        self.bits = (self.bits << 2) | @backingInt(d);
    }
    pub fn pop(self: *Decors) Decor {
        std.debug.assert(self.len() > 0);
        const d: Decor = @fromBackingInt(@intCast(@as(u2, @truncate(self.bits))));
        self.bits >>= 2;
        return d;
    }
    /// i = 0 is the latest.
    pub fn get(self: Decors, i: u6) Decor {
        std.debug.assert(i < self.len());
        return @fromBackingInt(@intCast(@as(u2, @truncate(self.bits >> (@as(u7, i) * 2)))));
    }
};
pub const Type = struct {
    raw: TypeIdx,
    decor: Decors = .{},
};

test "decors" {
    var d: Decors = .{};
    try std.testing.expectEqual(0, d.len());
    d.push(.@"const");
    d.push(.@"*");
    d.push(.@"volatile");
    try std.testing.expectEqual(3, d.len());
    try std.testing.expectEqual(Decor.@"volatile", d.get(0));
    try std.testing.expectEqual(Decor.@"*", d.get(1));
    try std.testing.expectEqual(Decor.@"const", d.get(2));
    try std.testing.expectEqual(Decor.@"volatile", d.pop());
    try std.testing.expectEqual(2, d.len());
    for (0..Decors.capacity - 2) |_| d.push(.@"&");
    try std.testing.expectEqual(Decors.capacity, d.len());
    try std.testing.expectEqual(16, @sizeOf(Decors));
}
