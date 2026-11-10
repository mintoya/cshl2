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
    arr, // TODO
    ptr,
    refT,
    fnptr, // TODO
    @"comptime",
    @"const",
    @"volatile",
    @"struct", // TODO
    this,
    opaqueType, // TODO
    @"fn", // TODO
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
pub const SGList = @import("sglist.zig").SgList;
pub const Decor = enum(u8) { @"const", @"volatile", @"*", null };
pub const DecorMap = struct {
    map: std.ArrayHashMapUnmanaged(
        []const Decor,
        u32,
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
    list: SGList(Decor, 5, 33) = .empty,
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
    ) !u32 {
        const owned = try alloc.dupe(Decor, std.mem.span(key));
        defer alloc.free(owned);
        var k = owned;
        normalize(&k);

        if (self.map.get(k)) |v| return v;

        const new = try self.list.getContiguous(alloc, k.len + 1);
        const res: u32 = @intCast(self.list.len - new.len);
        @memcpy(new[0..k.len], k);
        new[k.len] = .null;
        try self.map.put(alloc, new[0..k.len], res);
        return res;
    }
    pub fn asSliceTemp(
        self: @This(),
        val: u32,
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

pub const Layout = struct { size: usize, alignment: u16 };
pub const Type = struct {
    raw: TypeIdx,
    decorators: packed struct {
        @"comptime": bool,
        @"&": bool,
        decor: u30,
    },

    pub const LayoutError = error{ NoLayout, Unimplemented };

    pub fn layout(self: Type, decors: *const DecorMap, types: *const TypeMap) LayoutError!?Layout {
        const of = struct {
            fn of(comptime T: type) Layout {
                return .{ .size = @sizeOf(T), .alignment = @alignOf(T) };
            }
        }.of;
        for (std.mem.span(decors.asSliceTemp(self.decorators.decor))) |d| switch (d) {
            .@"*" => return of(*anyopaque),
            else => {},
        };
        return switch (self.raw) {
            .void => .{ .size = 0, .alignment = 1 },
            .bool => of(bool),
            .schar => of(i8),
            .uchar => of(u8),
            .sshort => of(c_short),
            .ushort => of(c_ushort),
            .sint => of(c_int),
            .uint => of(c_uint),
            .slong => of(c_long),
            .ulong => of(c_ulong),
            .slonglong => of(c_longlong),
            .ulonglong => of(c_ulonglong),
            .int => of(std.math.big.int.Const),
            .builtin => of(BuiltinTypes),
            .type => of(Type),
            .inlineast, .ast => of(@import("ast.zig").Ast),
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

    entries: std.ArrayList(Entry) = .empty,
    layouts: std.ArrayList(Type.LayoutError!Layout) = .empty,
    pub const empty: @This() = .{};

    pub fn deinit(self: *@This(), alloc: std.mem.Allocator) void {
        for (self.entries.items) |e| switch (e) {
            .@"struct" => |members| alloc.free(members),
            .@"fn" => |members| alloc.free(members),
        };
        self.entries.deinit(alloc);
        self.layouts.deinit(alloc);
    }

    pub fn add(self: *@This(), alloc: std.mem.Allocator, decors: *const DecorMap, entry: Entry) !TypeIdx {
        const idx: TypeIdx = @fromBackingInt(@intCast(first + @as(u32, @intCast(self.entries.items.len))));
        const l: Type.LayoutError!Layout = switch (entry) {
            .@"fn" => .{
                .size = @sizeOf(*const fn () callconv(.c) void),
                .alignment = @alignOf(*const fn () callconv(.c) void),
            },
            .@"struct" => |members| structLayout(members, decors, self),
        };
        try self.entries.ensureUnusedCapacity(alloc, 1);
        try self.layouts.ensureUnusedCapacity(alloc, 1);
        self.entries.appendAssumeCapacity(switch (entry) {
            .@"struct" => |members| .{ .@"struct" = try alloc.dupe(StructMember, members) },
            .@"fn" => |members| .{ .@"fn" = try alloc.dupe(Type, members) },
        });
        self.layouts.appendAssumeCapacity(l);
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
        return self.layouts.items[i - first];
    }
    pub fn get(self: *const @This(), idx: TypeIdx) Entry {
        const i = @backingInt(idx);
        std.debug.assert(i >= first);
        return self.entries.items[i - first];
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
