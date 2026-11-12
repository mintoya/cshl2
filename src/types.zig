const std = @import("std");
pub const TypeIdx = enum(u32) {
    const Self = @This();

    void,
    bool,
    type,
    ast,
    inlineast,
    any,

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
    pub const cintTypes = enum(u8) {
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
    pub const comptimeTypes = enum(u8) {
        builtin,
        type,
        ast,
        inlineast,
        any,
        int,
    };
    pub fn get_cint(this: Self) ?cintTypes {
        const fields = @typeInfo(cintTypes).@"enum".field_names;
        inline for (fields) |fieldname|
            if (this == @field(Self, fieldname))
                return @field(cintTypes, fieldname);
        return null;
    }
    pub fn get_comptime(this: Self) ?comptimeTypes {
        const fields = @typeInfo(comptimeTypes).@"enum".field_names;
        inline for (fields) |fieldname|
            if (this == @field(Self, fieldname))
                return @field(comptimeTypes, fieldname);
        return null;
    }
};
pub const BuiltinTypes = enum(u8) {
    // all functions,  so @name(...)
    void, // () void type
    bool, // () bool type
    type, // () type type
    ast, // () ast type
    inlineast, // () inline ast type, when returned from a function, get's unquoted, otherwise meaningless
    outlineast, // (function call) given functoin that returns inlineast, gives the ast before it get's unquoted
    any, // () type of any, only meaningful in functoin signature and type casting
    int, // () compiel time integer, arbitrary precision, signed
    schar, // () signed c char
    sshort, // () signecd c short
    sint, // () signed c int
    slong, // () signed c long
    slonglong, // () signed c longlong
    uchar, // () unsigned c longlong
    ushort, // () unsigned c longlong
    uint, // () unsigned c longlong
    ulong, // () unsigned c longlong
    ulonglong, // () unsigned c longlong
    arr, // (N,T) type of an array of N T's
    ptr, // (T) pointer to T
    refT, // (T) referance to T
    fnptr, // ((..A),R) type of  function pointer that takes args ..A and returns R
    @"comptime", // (T) compile time version of type T
    @"const", // (T) constant version of type T
    @"volatile", // (T) volatile verison of type T
    @"struct", // (B) creates namespace for  B, whatever is boudn to a referance becomes a runtime sized member of result type, otherwise, it's a compile time member, see @bind and bind.cshl
    this, // () within a struct, refers to the  type being created
    opaqueType, // (str) type of a c type with the name str
    @"fn", // ((..A),R) type of  function that takes args ..A and returns R, if R is comptime it's cached and dnoesnt run if the args match, if R is volatile , it always runs, useful for things like compile time maps of type to something else
    returntype, //()  type of currrent function's result, not allowed  for a function that retuns any (as that is circular dependancy)
    @"if", //
    loop, // (B) create loop context, returns loop nestedness,
    repeat, // (?) repeat loop, if calleed  with id, then use nestedness to determine which loop to repeat
    @"defer",
    yield,
    where, // (V) take address of V
    at, // (V) make a pointer to a referance to ti's pointee
    comptime_alloc,
    comptime_free,
    stackptr,
    zero,
    len,
    get,
    ast_stringeq,
    apply,
    gensym, // (id) generates ast that is an identifer based on id and something else
    id,
    compileError, // (str) generate compiel error who's content is str
    compiles, // (B) check if what's passed in
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
pub const SGList = @import("sglist.zig").SgList;
pub const Decor = enum(u8) { @"const", @"volatile", @"*", null };
pub const DecorMap = struct {
    map: std.ArrayHashMapUnmanaged(
        []const Decor,
        u30,
        struct {
            pub fn hash(self: @This(), K: []const Decor) u32 {
                _ = self;
                return @truncate(std.hash.Wyhash.hash(
                    0,
                    @as([*]const u8, @ptrCast(K.ptr))[0 .. @sizeOf(Decor) * K.len],
                ));
            }
            pub fn eql(self: @This(), a: []const Decor, b: []const Decor, b_index: usize) bool {
                _ = self;
                _ = b_index;
                return std.mem.eql(Decor, a, b);
            }
        },
        true,
    ) = .empty,
    list: SGList(Decor, 5, 11) = .empty,
    pub const empty: @This() = .{};
    pub fn deinit(self: *@This(), alloc: std.mem.Allocator) void {
        self.list.deinit(alloc);
        self.map.deinit(alloc);
    }

    fn normalize(k: *[]Decor) void {
        const s = k.*;
        var out: usize = 0;
        var i: usize = 0;
        while (i < s.len) {
            var c = false;
            var v = false;
            while (i < s.len and s[i] != .@"*") : (i += 1) switch (s[i]) {
                .@"const" => c = true,
                .@"volatile" => v = true,
                .@"*", .null => unreachable,
            };
            if (c) {
                s[out] = .@"const";
                out += 1;
            }
            if (v) {
                s[out] = .@"volatile";
                out += 1;
            }
            if (i < s.len) {
                s[out] = .@"*";
                out += 1;
                i += 1;
            }
        }
        k.* = s[0..out];
    }
    pub fn getOrSet(
        self: *@This(),
        alloc: std.mem.Allocator,
        key: [*:.null]const Decor,
    ) !u30 {
        const owned = try alloc.dupe(Decor, std.mem.span(key));
        defer alloc.free(owned);
        var k = owned;
        normalize(&k);

        if (self.map.get(k)) |v| return v;

        const new = try self.list.getContiguous(alloc, k.len + 1);
        const res: u30 = @intCast(self.list.len - new.len);
        @memcpy(new[0..k.len], k);
        new[k.len] = .null;
        try self.map.put(alloc, new[0..k.len], res);
        return res;
    }
    pub fn asSliceTemp(
        self: @This(),
        val: u30,
    ) [*:.null]const Decor {
        return @ptrCast(self.list.getConst(val));
    }
};
test "decor map" {
    var m = DecorMap.empty;
    defer m.deinit(std.testing.allocator);

    const plain_decor = try m.getOrSet(
        std.testing.allocator,
        &[_:.null]Decor{},
    );
    try std.testing.expectEqual(
        plain_decor,
        try m.getOrSet(
            std.testing.allocator,
            &[_:.null]Decor{},
        ),
    );
    const volatile_const_pointer = try m.getOrSet(
        std.testing.allocator,
        &[_:.null]Decor{ .@"volatile", .@"const", .@"*" },
    );
    try std.testing.expectEqual(
        volatile_const_pointer,
        try m.getOrSet(
            std.testing.allocator,
            &[_:.null]Decor{ .@"volatile", .@"const", .@"*" },
        ),
    );
    try std.testing.expectEqualSlices(Decor, &.{}, std.mem.span(m.asSliceTemp(plain_decor)));
    try std.testing.expectEqualSlices(
        Decor,
        &.{ .@"const", .@"volatile", .@"*" },
        std.mem.span(m.asSliceTemp(volatile_const_pointer)),
    );
    // every spelling of the same qualifiers is the same type
    try std.testing.expectEqual(
        volatile_const_pointer,
        try m.getOrSet(
            std.testing.allocator,
            &[_:.null]Decor{ .@"const", .@"volatile", .@"const", .@"volatile", .@"*" },
        ),
    );
    // but qualifiers on different sides of a * are different levels
    try std.testing.expect(volatile_const_pointer != try m.getOrSet(
        std.testing.allocator,
        &[_:.null]Decor{ .@"volatile", .@"*", .@"const" },
    ));

    var buf = [_:.null]Decor{ .@"const", .@"*" };
    const const_pointer = try m.getOrSet(std.testing.allocator, &buf);
    buf = .{ .@"*", .@"*" };
    try std.testing.expectEqual(
        const_pointer,
        try m.getOrSet(std.testing.allocator, &[_:.null]Decor{ .@"const", .@"*" }),
    );
    try std.testing.expect(const_pointer != try m.getOrSet(std.testing.allocator, &buf));
}

pub const Layout = struct {
    size: usize,
    alignment: u16,
    pub fn of(t: type) @This() {
        return .{ .size = @sizeOf(t), .alignment = @alignOf(t) };
    }
};
pub const Type = struct {
    raw: TypeIdx,
    decorators: packed struct {
        @"comptime": bool,
        @"&": bool,
        decor: u30,
    },

    pub const LayoutError = error{ NoLayout, Unimplemented };

    pub fn layout(self: Type, decors: *const DecorMap, types: *const TypeMap) LayoutError!?Layout {
        for (std.mem.span(decors.asSliceTemp(self.decorators.decor))) |d| switch (d) {
            .@"*" => return .of(*anyopaque),
            else => {},
        };
        return switch (self.raw) {
            .void => .{ .size = 0, .alignment = 1 },
            .bool => .of(bool),
            .schar => .of(i8),
            .uchar => .of(u8),
            .sint => .of(c_int),
            .uint => .of(c_uint),
            .slong => .of(c_long),
            .ulong => .of(c_ulong),
            .sshort => .of(c_short),
            .ushort => .of(c_ushort),
            .slonglong => .of(c_longlong),
            .ulonglong => .of(c_ulonglong),
            .int => .of(std.math.big.int.Const),
            .builtin => .of(BuiltinTypes),
            .type => .of(Type),
            .inlineast, .ast => .of(@import("ast.zig").Ast),
            .any => return error.NoLayout,
            _ => switch (types.get(self.raw)) {
                // a function is comptime: its layout is the compiler's
                // representation of one, not decided yet; a function pointer
                // is the same entry at runtime
                .@"fn" => if (self.decorators.@"comptime")
                    error.Unimplemented
                else
                    try types.cachedLayout(self.raw),
                .@"struct" => try types.cachedLayout(self.raw),
            },
        };
    }
};

/// The types in `_`
pub const TypeMap = struct {
    pub const StructMember = struct {
        type: Type,
        value: [*]const u8,
        name: []const u8,
    };
    pub const Entry = union(enum) {
        @"struct": []const StructMember,
        @"fn": []const Type,
    };

    const first: u32 = @backingInt(TypeIdx.builtin) + 1;
    entries: std.ArrayList(struct { Entry, Type.LayoutError!Layout }) = .empty,
    pub const empty: @This() = .{};

    pub fn deinit(self: *@This(), alloc: std.mem.Allocator) void {
        for (self.entries.items) |e| switch (e[0]) {
            .@"struct" => |members| alloc.free(members),
            .@"fn" => |members| alloc.free(members),
        };
        self.entries.deinit(alloc);
    }
    pub fn add(self: *@This(), alloc: std.mem.Allocator, decors: *const DecorMap, entry: Entry) !TypeIdx {
        const idx: TypeIdx = @fromBackingInt(@intCast(first + @as(u32, @intCast(self.entries.items.len))));
        const l: Type.LayoutError!Layout = switch (entry) {
            .@"fn" => .of(*const fn () callconv(.c) void),
            .@"struct" => |members| structLayout(members, decors, self),
        };
        try self.entries.ensureUnusedCapacity(alloc, 1);
        self.entries.appendAssumeCapacity(.{ switch (entry) {
            .@"struct" => |members| .{ .@"struct" = try alloc.dupe(StructMember, members) },
            .@"fn" => |members| .{ .@"fn" = try alloc.dupe(Type, members) },
        }, l });
        return idx;
    }
    fn structLayout(members: []const StructMember, decors: *const DecorMap, types: *const TypeMap) Type.LayoutError!Layout {
        var size: usize = 0;
        var alignment: u16 = 1;
        for (members) |m| {
            if (m.type.decorators.@"comptime") continue;
            const l = (try m.type.layout(decors, types)).?;
            size = std.mem.alignForward(usize, size, l.alignment) + l.size;
            alignment = @max(alignment, l.alignment);
        }
        return .{ .size = std.mem.alignForward(usize, size, alignment), .alignment = alignment };
    }
    pub fn cachedLayout(self: *const @This(), idx: TypeIdx) Type.LayoutError!Layout {
        const i = @backingInt(idx);
        std.debug.assert(i >= first);
        return self.entries.items[i - first][1];
    }
    pub fn get(self: *const @This(), idx: TypeIdx) Entry {
        const i = @backingInt(idx);
        std.debug.assert(i >= first);
        return self.entries.items[i - first][0];
    }
};
test "layout" {
    var m = DecorMap.empty;
    defer m.deinit(std.testing.allocator);
    const plain = try m.getOrSet(std.testing.allocator, &[_:.null]Decor{});
    const const_ptr = try m.getOrSet(std.testing.allocator, &[_:.null]Decor{ .@"const", .@"*" });

    var t = TypeMap.empty;
    defer t.deinit(std.testing.allocator);

    const int: Type = .{ .raw = .sint, .decorators = .{ .@"comptime" = false, .@"&" = false, .decor = @intCast(plain) } };
    try std.testing.expectEqual(@sizeOf(c_int), (try int.layout(&m, &t)).?.size);
    const ptr: Type = .{ .raw = .sint, .decorators = .{ .@"comptime" = false, .@"&" = false, .decor = @intCast(const_ptr) } };
    try std.testing.expectEqual(@sizeOf(*anyopaque), (try ptr.layout(&m, &t)).?.size);

    const char: Type = .{ .raw = .schar, .decorators = .{ .@"comptime" = false, .@"&" = false, .decor = @intCast(plain) } };
    var known_int = int;
    known_int.decorators.@"comptime" = true;

    // functions and function pointers share an entry
    const f = try t.add(std.testing.allocator, &m, .{ .@"fn" = &.{ int, int } });
    const fnptr: Type = .{ .raw = f, .decorators = .{ .@"comptime" = false, .@"&" = false, .decor = @intCast(plain) } };
    try std.testing.expectEqual(@sizeOf(*const fn () callconv(.c) void), (try fnptr.layout(&m, &t)).?.size);
    var function = fnptr;
    function.decorators.@"comptime" = true;
    try std.testing.expectError(error.Unimplemented, function.layout(&m, &t));

    // { char; int; comptime int; fn pointer }: the comptime member takes no space
    const bytes: [8]u8 = @splat(0);
    const s = try t.add(std.testing.allocator, &m, .{ .@"struct" = &.{
        .{ .type = char, .value = &bytes, .name = "c" },
        .{ .type = int, .value = &bytes, .name = "i" },
        .{ .type = known_int, .value = &bytes, .name = "n" },
        .{ .type = fnptr, .value = &bytes, .name = "f" },
    } });
    const st: Type = .{ .raw = s, .decorators = .{ .@"comptime" = false, .@"&" = false, .decor = @intCast(plain) } };
    const Expected = extern struct { c: i8, i: c_int, f: *const fn () callconv(.c) void };
    const l = (try st.layout(&m, &t)).?;
    try std.testing.expectEqual(@sizeOf(Expected), l.size);
    try std.testing.expectEqual(@alignOf(Expected), l.alignment);
    try std.testing.expectEqual(f, @as(TypeIdx, @fromBackingInt(@intCast(@backingInt(TypeIdx.builtin) + 1))));
}

pub const Value = struct { T: Type, mem: [*]u8 };
