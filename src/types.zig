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
    restrict, // (T) restrict verison of type T
    @"struct", // (B) creates namespace for  B, whatever is boudn to a referance becomes a runtime sized member of result type, otherwise, it's a compile time member, see @bind and bind.cshl
    this, // () within a struct, refers to the  type being created
    opaqueType, // (str) type of a c type with the name str
    @"fn", // ([..params],R,body) a function; params are `name as T`. if R is comptime it's cached and doesnt run if the args match, if R is volatile , it always runs, useful for things like compile time maps of type to something else
    returntype, //()  type of currrent function's result, not allowed  for a function that retuns any (as that is circular dependancy)
    @"if", //
    loop, // (B) create loop context, runs B until it doesn't @repeat; gives B's last value
    thisloop, // () the enclosing loop's nestedness, for @repeat
    repeat, // (?) repeat loop, if calleed  with id, then use nestedness to determine which loop to repeat
    @"defer",
    whendone, // (B) runs B once the top level is done, before main is lowered: compile-time code, in the scope it's written in
    yield,
    where, // (V) take address of V
    at, // (V) make a pointer to a referance to ti's pointee
    alloca, // (T) storage for a T, zeroed: at runtime in runtime code; gives a pointer
    alloc, // (T) compile time storage for a T, zeroed; gives a pointer
    free, // (P) frees what @alloc gave
    zero,
    len,
    get,
    ast_stringeq, // (ast, str) whether the ast's text is str
    ast_string, // (ast) the ast's text: an atom's own, a call as (f a b)
    apply,
    gensym, // (id) generates ast that is an identifer based on id and something else
    id, // (str) generatie ast identifer of the string
    compileError, // (str) generate compiel error who's content is str
    compiles, // (B) check if what's passed in
    log,
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
    isarray, // (T or value) whether it is an @arr[N, T] (not a pointer to one)
    isstruct, // (T or value) whether it is a @struct (not a pointer to one)
    isfnptr, // (T or value) whether it is a @fnptr (not a pointer to one)
    isreferance,
    isconst,
    isvolatile,
    isrestrict,
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
};
const List = std.ArrayList;
const SGList = @import("sglist.zig").SgList;
pub const Decor = packed struct {
    @"const": bool = false,
    @"volatile": bool = false,
    // @"atomic": bool, // c11
    @"*": enum(u2) {
        restrict = 2,
        default = 1,
        value = 0,
    } = .value,
    pub fn len(self: *const @This()) usize {
        var result: usize = 0;
        while (@as([*]const Decor, @ptrCast(self))[result].@"*" != .value) {
            result = result + 1;
        }
        return result + 1;
    }
    pub fn toSlice(self: *const @This()) []const Decor {
        const levels: [*]const Decor = @ptrCast(self);
        return levels[0..self.len()];
    }
};
pub const DecorIdx = u30;
pub const DecorMap = struct {
    map: std.ArrayHashMapUnmanaged(
        []const Decor,
        DecorIdx,
        struct {
            pub fn hash(self: @This(), K: []const Decor) u32 {
                _ = self;
                // the bits of each entry: its bytes can have padding
                var h = std.hash.Wyhash.init(0);
                for (K) |d| h.update(&.{@as(u8, @as(@typeInfo(Decor).@"struct".backing_integer.?, @bitCast(d)))});
                return @truncate(h.final());
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

    pub fn getOrSet(
        self: *@This(),
        alloc: std.mem.Allocator,
        key: []const Decor,
    ) !DecorIdx {
        std.debug.assert(key.len != 0 and key[0].len() == key.len);
        if (self.map.get(key)) |v| return v;
        const new = try self.list.getContiguous(alloc, key.len);
        const res: DecorIdx = @intCast(self.list.len - new.len);
        @memcpy(new, key);
        try self.map.put(alloc, new, res);
        return res;
    }
    pub fn asSlice(
        self: *const @This(),
        val: DecorIdx,
    ) []const Decor {
        const first: *const Decor = @ptrCast(self.list.getConst(val));
        return first.toSlice();
    }
};
test "decor map" {
    const a = std.testing.allocator;
    var m = DecorMap.empty;
    defer m.deinit(a);

    const plain = try m.getOrSet(a, &.{.{}});
    try std.testing.expectEqual(plain, try m.getOrSet(a, &.{.{}}));
    // T * const volatile: a const volatile pointer to a T
    const cv_pointer = try m.getOrSet(a, &.{ .{ .@"const" = true, .@"volatile" = true, .@"*" = .default }, .{} });
    try std.testing.expectEqual(cv_pointer, try m.getOrSet(a, &.{ .{ .@"volatile" = true, .@"const" = true, .@"*" = .default }, .{} }));
    try std.testing.expectEqualSlices(Decor, &.{.{}}, m.asSlice(plain));
    try std.testing.expectEqualSlices(Decor, &.{ .{ .@"const" = true, .@"volatile" = true, .@"*" = .default }, .{} }, m.asSlice(cv_pointer));
    // const T *: a pointer to const, not a const pointer
    try std.testing.expect(cv_pointer != try m.getOrSet(a, &.{ .{ .@"*" = .default }, .{ .@"const" = true } }));

    var buf = [_]Decor{ .{ .@"const" = true, .@"*" = .default }, .{} };
    const const_pointer = try m.getOrSet(a, &buf);
    buf = .{ .{ .@"*" = .default }, .{} };
    try std.testing.expectEqual(const_pointer, try m.getOrSet(a, &.{ .{ .@"const" = true, .@"*" = .default }, .{} }));
    try std.testing.expect(const_pointer != try m.getOrSet(a, &buf));
    // a restrict pointer isn't a plain one
    try std.testing.expect(const_pointer != try m.getOrSet(a, &.{ .{ .@"const" = true, .@"*" = .restrict }, .{} }));
    try std.testing.expectEqual(@as(usize, 2), m.asSlice(try m.getOrSet(a, &.{ .{ .@"*" = .restrict }, .{} })).len);
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
        decor: DecorIdx,
    },

    pub const LayoutError = error{ NoLayout, Unimplemented };

    pub fn layout(self: Type, decors: *const DecorMap, types: *const TypeMap) LayoutError!?Layout {
        // a level after the pointee's: a pointer
        if (decors.asSlice(self.decorators.decor).len > 1) return .of(*anyopaque);
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
                .fnptr, .@"struct", .arr, .@"opaque" => try types.cachedLayout(self.raw),
                .@"fn" => .of(FunctionHandle),
            },
        };
    }
};

pub const FunctionHandle = u32;
pub const TypeMap = struct {
    const Self = @This();
    pub const StructMember = struct {
        type: Type,
        value: [*]const u8,
        name: []const u8,
        /// a field takes space in every value, with `value` as its default;
        /// anything else belongs to the type, and `value` is the value
        field: bool = true,
    };
    pub const Entry = union(enum) {
        @"struct": []const StructMember,
        @"fn": []const Type,
        fnptr: []const Type,
        arr: struct { len: u64, elem: Type },
        /// a C type known only by its name
        @"opaque": []const u8,
    };

    const first: u32 = @backingInt(TypeIdx.builtin) + 1;
    entries: List(struct { Entry, Type.LayoutError!Layout }) = .empty,
    pub const empty: Self = .{};
    pub fn deinit(self: *Self, alloc: std.mem.Allocator) void {
        for (self.entries.items) |e| switch (e[0]) {
            .@"struct" => |members| alloc.free(members),
            .@"fn" => |members| alloc.free(members),
            .fnptr => |members| alloc.free(members),
            .@"opaque" => |name| alloc.free(name),
            .arr => {},
        };
        self.entries.deinit(alloc);
    }

    pub fn add(self: *Self, alloc: std.mem.Allocator, decors: *const DecorMap, entry: Entry) !TypeIdx {
        const idx: TypeIdx = @fromBackingInt(@intCast(first + @as(u32, @intCast(self.entries.items.len))));
        try self.entries.ensureUnusedCapacity(alloc, 1);
        self.entries.appendAssumeCapacity(.{ try owned(alloc, entry), entryLayout(entry, decors, self) });
        return idx;
    }
    pub fn set(self: *Self, alloc: std.mem.Allocator, decors: *const DecorMap, idx: TypeIdx, entry: Entry) !void {
        const i = @backingInt(idx) - first;
        const new = try owned(alloc, entry);
        switch (self.entries.items[i][0]) {
            .@"struct" => |members| alloc.free(members),
            .@"fn" => |members| alloc.free(members),
            .fnptr => |members| alloc.free(members),
            .@"opaque" => |name| alloc.free(name),
            .arr => {},
        }
        self.entries.items[i] = .{ new, entryLayout(new, decors, self) };
    }
    fn owned(alloc: std.mem.Allocator, entry: Entry) !Entry {
        return switch (entry) {
            .@"struct" => |members| .{ .@"struct" = try alloc.dupe(StructMember, members) },
            .@"fn" => |members| .{ .@"fn" = try alloc.dupe(Type, members) },
            .fnptr => |members| .{ .fnptr = try alloc.dupe(Type, members) },
            .@"opaque" => |name| .{ .@"opaque" = try alloc.dupe(u8, name) },
            .arr => entry,
        };
    }
    fn entryLayout(entry: Entry, decors: *const DecorMap, types: *const TypeMap) Type.LayoutError!Layout {
        return switch (entry) {
            .@"fn" => .of(FunctionHandle),
            .fnptr => .of(*fn () callconv(.c) void),
            .@"struct" => |members| structLayout(members, decors, types),
            .@"opaque" => error.NoLayout,
            .arr => |a| blk: {
                const l = (try a.elem.layout(decors, types)).?;
                break :blk .{ .size = l.size * a.len, .alignment = l.alignment };
            },
        };
    }
    fn structLayout(members: []const StructMember, decors: *const DecorMap, types: *const TypeMap) Type.LayoutError!Layout {
        var size: usize = 0;
        var alignment: u16 = 1;
        for (members) |m| {
            if (!m.field or m.type.decorators.@"comptime") continue;
            const l = (try m.type.layout(decors, types)).?;
            size = std.mem.alignForward(usize, size, l.alignment) + l.size;
            alignment = @max(alignment, l.alignment);
        }
        return .{ .size = std.mem.alignForward(usize, size, alignment), .alignment = alignment };
    }
    pub fn cachedLayout(self: *const Self, idx: TypeIdx) Type.LayoutError!Layout {
        const i = @backingInt(idx);
        std.debug.assert(i >= first);
        return self.entries.items[i - first][1];
    }
    pub fn get(self: *const Self, idx: TypeIdx) Entry {
        const i = @backingInt(idx);
        std.debug.assert(i >= first);
        return self.entries.items[i - first][0];
    }
};
test "layout" {
    var m = DecorMap.empty;
    defer m.deinit(std.testing.allocator);
    const plain = try m.getOrSet(std.testing.allocator, &.{.{}});
    const const_ptr = try m.getOrSet(std.testing.allocator, &.{ .{ .@"const" = true, .@"*" = .default }, .{} });

    var t = TypeMap.empty;
    defer t.deinit(std.testing.allocator);

    const int: Type = .{ .raw = .sint, .decorators = .{ .@"comptime" = false, .@"&" = false, .decor = @intCast(plain) } };
    try std.testing.expectEqual(@sizeOf(c_int), (try int.layout(&m, &t)).?.size);
    const ptr: Type = .{ .raw = .sint, .decorators = .{ .@"comptime" = false, .@"&" = false, .decor = @intCast(const_ptr) } };
    try std.testing.expectEqual(@sizeOf(*anyopaque), (try ptr.layout(&m, &t)).?.size);

    const char: Type = .{ .raw = .schar, .decorators = .{ .@"comptime" = false, .@"&" = false, .decor = @intCast(plain) } };
    var known_int = int;
    known_int.decorators.@"comptime" = true;

    // a function is the compiler's representation of one; a function pointer is an address
    const f = try t.add(std.testing.allocator, &m, .{ .@"fn" = &.{ int, int } });
    const function: Type = .{ .raw = f, .decorators = .{ .@"comptime" = false, .@"&" = false, .decor = @intCast(plain) } };
    try std.testing.expectEqual(@sizeOf(FunctionHandle), (try function.layout(&m, &t)).?.size);
    try std.testing.expect(t.get(f) == .@"fn");
    const p = try t.add(std.testing.allocator, &m, .{ .fnptr = &.{ int, int } });
    const fnptr: Type = .{ .raw = p, .decorators = .{ .@"comptime" = false, .@"&" = false, .decor = @intCast(plain) } };
    try std.testing.expectEqual(@sizeOf(*const fn () callconv(.c) void), (try fnptr.layout(&m, &t)).?.size);
    try std.testing.expect(t.get(p) == .fnptr);

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
test "Decor len and toSlice" {
    const d = [_]Decor{
        .{ .@"const" = true, .@"volatile" = false, .@"*" = .default },
        .{ .@"const" = false, .@"volatile" = true, .@"*" = .default },
        .{ .@"const" = false, .@"volatile" = false, .@"*" = .value },
    };
    try std.testing.expectEqual(@as(usize, 3), d[0].len());
    try std.testing.expectEqual(@as(usize, 1), d[2].len());
    try std.testing.expectEqual(@as(usize, 3), d[0].toSlice().len);
    try std.testing.expect(d[1].toSlice()[0].@"volatile");
}
