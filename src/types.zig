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
    pub fn get_cint(this: Self) ?cintTypes {
        const fields = @typeInfo(cintTypes).@"enum".field_names;
        inline for (fields) |fieldname|
            if (this == @field(Self, fieldname))
                return @field(cintTypes, fieldname);
        return null;
    }
};
pub const Type = struct {
    raw: TypeIdx,
    decor: []packed struct {
        @"const": bool,
        @"volatile": bool,
    },
};
