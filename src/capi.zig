//! The compiler as a C library, for plugins: outside programs that watch a
//! compilation and keep what they want from it. ccshl.h declares this.
//!
//! cshl_compile runs a file, calling the handler with each message as it
//! happens; the session it returns keeps everything the messages refer to
//! (names, files, types) until cshl_free. Types are opaque 64-bit handles,
//! read back with the cshl_type_* functions.
const std = @import("std");
const eval = @import("eval.zig");
const types = @import("types.zig");
const Type = types.Type;
const TypeIdx = types.TypeIdx;
const SrcRef = @import("ast.zig").SrcRef;

pub const Kind = enum(c_int) { bind = 0, use = 1, @"error" = 2, trace = 3 };

pub const Message = extern struct {
    kind: Kind,
    /// the binding: bound, or used
    id: u64,
    /// for bind: the binding this one was copied from (@using), or 0
    origin: u64,
    /// for bind: the name; for error: the message
    name: [*]const u8,
    name_len: usize,
    /// where, as the file's path and a byte range; file_len is 0 for code
    /// that isn't in a file (built by quotes)
    file: [*]const u8,
    file_len: usize,
    offset: u32,
    length: u32,
    /// for bind: the type of the value
    type: u64,
    /// for bind, when the value is a type: that type; 0 otherwise
    holds: u64,
};

pub const Handler = ?*const fn (ctx: ?*anyopaque, msg: *const Message) callconv(.c) void;

const Session = struct {
    arena: std.heap.ArenaAllocator,
    threaded: std.Io.Threaded,
    e: eval.Eval,
    handler: Handler,
    ctx: ?*anyopaque,
    failed: bool = false,
    /// type names, formatted once each
    names: std.AutoHashMapUnmanaged(u64, []const u8) = .empty,
};

fn handle(T: Type) u64 {
    var h: u64 = 0;
    @memcpy(std.mem.asBytes(&h)[0..@sizeOf(Type)], std.mem.asBytes(&T));
    return h;
}

fn typeOf(h: u64) Type {
    var T: Type = undefined;
    @memcpy(std.mem.asBytes(&T), std.mem.asBytes(&h)[0..@sizeOf(Type)]);
    return T;
}

fn place(at: ?SrcRef, m: *Message) void {
    const r = at orelse return;
    switch (r.src.*) {
        .disk => |d| {
            m.file = d.filename.ptr;
            m.file_len = d.filename.len;
        },
        .memory => {},
    }
    m.offset = r.off;
    m.length = r.len;
}

fn empty(kind: Kind) Message {
    return .{ .kind = kind, .id = 0, .origin = 0, .name = "", .name_len = 0, .file = "", .file_len = 0, .offset = 0, .length = 0, .type = 0, .holds = 0 };
}

fn forward(ctx: ?*anyopaque, msg: *const eval.Message) void {
    const s: *Session = @ptrCast(@alignCast(ctx.?));
    const h = s.handler orelse return;
    var m: Message = undefined;
    switch (msg.*) {
        .bind => |b| {
            m = empty(.bind);
            m.id = b.id;
            m.origin = b.origin;
            m.name = b.name.ptr;
            m.name_len = b.name.len;
            m.type = handle(b.T);
            if (b.holds) |H| m.holds = handle(H);
            place(b.at, &m);
        },
        .use => |u| {
            m = empty(.use);
            m.id = u.id;
            place(u.at, &m);
        },
    }
    h(s.ctx, &m);
}

/// Runs the file at path; lower nonzero lowers it as for C output instead of
/// only interpreting it. Never null unless out of memory; cshl_failed says
/// whether it compiled, and the handler got an error message if not.
export fn cshl_compile(path: [*:0]const u8, lower: c_int, handler: Handler, ctx: ?*anyopaque) ?*Session {
    const gpa = std.heap.c_allocator;
    const s = gpa.create(Session) catch return null;
    s.* = .{ .arena = .init(gpa), .threaded = .init(gpa, .{}), .e = undefined, .handler = handler, .ctx = ctx };
    const a = s.arena.allocator();
    s.e = eval.Eval.init(a, s.threaded.io()) catch {
        cshl_free(s);
        return null;
    };
    s.e.hook = .{ .ctx = s, .send = forward };
    const p = std.mem.span(path);
    const result = if (lower != 0) s.e.lowerFile(p) else if (s.e.evalFile(p, null)) |_| {} else |err| err;
    result catch |err| switch (err) {
        error.CompileError => {
            s.failed = true;
            if (handler) |h| {
                var m = empty(.@"error");
                m.name = s.e.diag.msg.ptr;
                m.name_len = s.e.diag.msg.len;
                place(s.e.diag.at, &m);
                h(ctx, &m);
                // the calls it came through, innermost first
                for (s.e.diag.trace.items) |r| {
                    var t = empty(.trace);
                    place(r, &t);
                    h(ctx, &t);
                }
            }
        },
        else => {
            cshl_free(s);
            return null;
        },
    };
    return s;
}

export fn cshl_failed(s: *Session) c_int {
    return @intFromBool(s.failed);
}

export fn cshl_free(s: *Session) void {
    s.arena.deinit();
    s.threaded.deinit();
    std.heap.c_allocator.destroy(s);
}

pub const TypeKind = enum(c_int) {
    void,
    bool,
    type,
    ast,
    any,
    /// a compile-time integer
    int,
    /// a C integer
    cint,
    builtin,
    pointer,
    @"struct",
    /// a function: compile-time, by its handle
    function,
    /// a function pointer
    fnptr,
    array,
    /// a C type by name (@opaqueType)
    @"opaque",
};

export fn cshl_type_kind(s: *Session, h: u64) TypeKind {
    const T = typeOf(h);
    if (s.e.isPtr(T)) return .pointer;
    return switch (T.raw) {
        .void => .void,
        .bool => .bool,
        .type => .type,
        .ast, .inlineast => .ast,
        .any => .any,
        .int => .int,
        .builtin => .builtin,
        .schar, .sshort, .sint, .slong, .slonglong, .uchar, .ushort, .uint, .ulong, .ulonglong => .cint,
        _ => switch (s.e.types.get(T.raw)) {
            .@"struct" => .@"struct",
            .@"fn" => if (T.decorators.@"comptime") .function else .fnptr,
            .arr => .array,
            .@"opaque" => .@"opaque",
        },
    };
}

/// The type's name, as errors print it; the text lives as long as s.
export fn cshl_type_name(s: *Session, h: u64, len: *usize) [*]const u8 {
    const gop = s.names.getOrPut(s.arena.allocator(), h) catch {
        len.* = 0;
        return "";
    };
    if (!gop.found_existing) {
        gop.value_ptr.* = std.fmt.allocPrint(s.arena.allocator(), "{f}", .{s.e.typeName(typeOf(h))}) catch "";
    }
    len.* = gop.value_ptr.len;
    return gop.value_ptr.ptr;
}

/// Whether the value is a place (a reference), and whether it's known at
/// compile time.
export fn cshl_type_is_ref(h: u64) c_int {
    return @intFromBool(typeOf(h).decorators.@"&");
}
export fn cshl_type_is_comptime(h: u64) c_int {
    return @intFromBool(typeOf(h).decorators.@"comptime");
}

/// The type a pointer points to, or an array's element type; 0 otherwise.
export fn cshl_type_pointee(s: *Session, h: u64) u64 {
    const T = typeOf(h);
    if (s.e.isPtr(T)) return handle(s.e.pointeePub(T) catch return 0);
    if (s.e.arrEntry(T)) |a| return handle(a.T);
    return 0;
}

/// A struct's members, an array's length, or a function's parameters.
export fn cshl_type_len(s: *Session, h: u64) usize {
    const T = typeOf(h);
    if (s.e.structMembers(T)) |m| return m.len;
    if (s.e.arrEntry(T)) |a| return a.len;
    if (s.e.fnEntry(T)) |sig| return sig.len - 1;
    return 0;
}

/// Member i of a struct, or parameter i of a function; 0 past the end.
export fn cshl_type_member(s: *Session, h: u64, i: usize) u64 {
    const T = typeOf(h);
    if (s.e.structMembers(T)) |m| return if (i < m.len) handle(m[i].type) else 0;
    if (s.e.fnEntry(T)) |sig| return if (i + 1 < sig.len) handle(sig[i]) else 0;
    return 0;
}

/// The name of struct member i; the text lives as long as s.
export fn cshl_type_member_name(s: *Session, h: u64, i: usize, len: *usize) [*]const u8 {
    len.* = 0;
    const m = s.e.structMembers(typeOf(h)) orelse return "";
    if (i >= m.len) return "";
    len.* = m[i].name.len;
    return m[i].name.ptr;
}

/// For struct member i whose value is a type (a namespace member like
/// `Self <~ @this()`): that type; 0 otherwise.
export fn cshl_type_member_holds(s: *Session, h: u64, i: usize) u64 {
    const m = s.e.structMembers(typeOf(h)) orelse return 0;
    if (i >= m.len) return 0;
    if (m[i].type.raw != .type or s.e.isPtr(m[i].type)) return 0;
    var T: Type = undefined;
    @memcpy(std.mem.asBytes(&T), m[i].value[0..@sizeOf(Type)]);
    return handle(T);
}

/// A function's result type; 0 for anything else.
export fn cshl_type_result(s: *Session, h: u64) u64 {
    const sig = s.e.fnEntry(typeOf(h)) orelse return 0;
    return handle(sig[sig.len - 1]);
}
