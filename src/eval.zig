//! Evaluates an Ast. For now everything runs here, compile time and runtime
//! alike: this is the reference for what a program means, and lowering the
//! runtime part to the IR comes after it.
//!
//! A value is a Type and a pointer to its bytes (`types.Value`); the size of
//! the bytes is the type's layout. A reference (the `&` bit) is a value whose
//! bytes are the place itself, so writing through it writes the place.
const std = @import("std");
const ast_mod = @import("ast.zig");
const Ast = ast_mod.Ast;
const FileItem = ast_mod.FileItem;
const SrcRef = ast_mod.SrcRef;
const parse = @import("parse.zig");
const types = @import("types.zig");
const Type = types.Type;
const TypeIdx = types.TypeIdx;
const Builtin = types.BuiltinTypes;
const Decor = types.Decor;
const Value = types.Value;
const CInt = TypeIdx.cintTypes;
const BigConst = std.math.big.int.Const;
const BigManaged = std.math.big.int.Managed;
const ir = @import("ir.zig");
const mod = @import("module.zig");
const Reg = mod.Reg;

pub const Error = error{ OutOfMemory, CompileError };

pub const Diagnostic = struct {
    msg: []const u8 = "",
    at: ?SrcRef = null,
};

pub const Scope = struct {
    parent: ?*Scope,
    /// null marks a name @unbind removed here
    names: std.StringArrayHashMapUnmanaged(?Value) = .empty,
    /// the struct @this() names inside a @struct block
    this: ?TypeIdx = null,
    defers: std.ArrayList(Ast) = .empty,
    /// a function body's scope: the function's return type, for @returntype()
    ret: ?Type = null,
    /// while the scope's defers run: the value it yielded, for @yield()
    yielded: ?Value = null,

    fn lookup(self: *const Scope, name: []const u8) ?Value {
        var s: ?*const Scope = self;
        while (s) |sc| : (s = sc.parent)
            if (sc.names.get(name)) |entry| return entry;
        return null;
    }
};

/// A parameter. A type that names an earlier parameter is evaluated per
/// call, from `T_ast`; until then T is @any().
const Param = struct { name: []const u8, T: Type, T_ast: ?Ast = null };

const Function = struct {
    params: []const Param,
    ret: Type,
    /// a return type naming a parameter, evaluated per call; ret is @any()
    ret_ast: ?Ast = null,
    body: Ast,
    closure: *Scope,
};

/// A call argument: its syntax, and its value when the caller already has it
/// (the receiver of `a:f(x)`).
const Arg = struct { ast: Ast, value: ?Value = null };

/// What a runtime value's bytes are while lowering: the register holding it,
/// in the function it belongs to. For a place, the register holds a pointer.
const RtSlot = struct { reg: Reg, func: u32 };

/// A @loop while lowering: the runtime branch depth it started at, and
/// whether a @repeat under a runtime branch made it a runtime loop.
const LoopCtx = struct { branch: u32, runtime: bool = false };

const IntVal = union(enum) {
    big: BigConst,
    c: struct { kind: CInt, v: i128 },
};

pub const Eval = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    decors: types.DecorMap = .empty,
    types: types.TypeMap = .empty,
    fns: std.ArrayList(Function) = .empty,
    /// @import results by path; null while the file is being evaluated
    files: std.StringHashMapUnmanaged(?Value) = .empty,
    arrays: std.AutoHashMapUnmanaged([2]u64, TypeIdx) = .empty,
    /// @opaqueType types by C name: the same name is the same type
    opaque_types: std.StringHashMapUnmanaged(TypeIdx) = .empty,
    /// function pointer types by signature: the same signature is the same type
    fn_types: std.StringHashMapUnmanaged(TypeIdx) = .empty,
    /// results of calls to functions that return a type, by function and
    /// argument bytes: the same arguments give the same type
    type_calls: std.StringHashMapUnmanaged(Value) = .empty,
    gensyms: u32 = 0,
    repeat: bool = false,
    /// while lowering: how many runtime branches the code being lowered is in
    rt_branch: u32 = 0,
    /// while lowering: the @loops being lowered, innermost last
    loops: std.ArrayList(LoopCtx) = .empty,
    diag: Diagnostic = .{},
    /// the innermost expression from a file being evaluated, for the
    /// positions of the IR it emits; code built by quotes keeps the one
    /// around it
    loc: ?SrcRef = null,
    /// while a macro's expansion runs: the file the macro is written in,
    /// whose positions don't replace the call site's
    macro_src: ?*const FileItem = null,
    root: *Scope,
    /// the function being lowered; null while everything runs at compile time
    rt: ?u32 = null,
    module: mod.Module = .{},
    /// the values that are registers, by the address of their RtSlot
    rt_values: std.AutoHashMapUnmanaged(usize, void) = .empty,
    /// lowered functions by function handle
    lowered: std.AutoHashMapUnmanaged(u32, u32) = .empty,
    /// the function pointer type of each lowered function, by handle
    fn_ptr_types: std.AutoHashMapUnmanaged(u32, Type) = .empty,

    /// `gpa` should be an arena: values are never freed one by one.
    pub fn init(gpa: std.mem.Allocator, io: std.Io) Error!Eval {
        const root = try gpa.create(Scope);
        root.* = .{ .parent = null };
        var self: Eval = .{ .gpa = gpa, .io = io, .root = root };
        // decoration id 0 is "none", so zeroed memory is a plain type
        const plain = try self.decors.getOrSet(gpa, &[_:.null]Decor{});
        std.debug.assert(plain == 0);
        // operators are names, bound to the builtins until a program rebinds them
        const info = @typeInfo(Builtin).@"enum";
        inline for (info.field_names, info.field_values) |name, value| {
            const b: Builtin = @enumFromInt(value);
            if (isOperator(b)) try root.names.put(gpa, name, try self.builtinValue(b));
        }
        return self;
    }

    // ---------------------------------------------------------------- errors

    fn fail(self: *Eval, at: Ast, comptime fmt: []const u8, args: anytype) Error {
        self.diag = .{
            .msg = std.fmt.allocPrint(self.gpa, fmt, args) catch "out of memory",
            .at = firstRef(at),
        };
        return error.CompileError;
    }

    fn firstRef(node: Ast) ?SrcRef {
        return switch (node) {
            .nil, .str, .num, .id => |r| r,
            .call => |items| for (items) |item| {
                if (item == .id and item.id.src == &parse.builtin_file) continue;
                if (firstRef(item)) |r| break r;
            } else null,
        };
    }

    // ----------------------------------------------------------------- types

    fn isOperator(b: Builtin) bool {
        return @intFromEnum(b) >= @intFromEnum(Builtin.@"+");
    }

    pub fn mk(raw: TypeIdx) Type {
        return .{ .raw = raw, .decorators = .{
            .@"comptime" = raw.get_comptime() != null,
            .@"&" = false,
            .decor = 0,
        } };
    }

    pub fn typeKey(T: Type) u64 {
        return @as(u64, @intFromEnum(T.raw)) << 32 | @as(u32, @bitCast(T.decorators));
    }

    fn typeEql(a: Type, b: Type) bool {
        return typeKey(a) == typeKey(b);
    }

    pub fn chain(self: *Eval, T: Type) []const Decor {
        return std.mem.span(self.decors.asSliceTemp(T.decorators.decor));
    }

    fn withChain(self: *Eval, T: Type, decors: []const Decor) Error!Type {
        const buf = try self.gpa.allocSentinel(Decor, decors.len, .null);
        @memcpy(buf, decors);
        var out = T;
        out.decorators.decor = @intCast(try self.decors.getOrSet(self.gpa, buf.ptr));
        return out;
    }

    fn appendDecor(self: *Eval, T: Type, d: Decor) Error!Type {
        const c = self.chain(T);
        const buf = try self.gpa.alloc(Decor, c.len + 1);
        @memcpy(buf[0..c.len], c);
        buf[c.len] = d;
        return self.withChain(T, buf);
    }

    fn ptrTo(self: *Eval, T: Type) Error!Type {
        var t = T;
        t.decorators.@"&" = false;
        t.decorators.@"comptime" = false;
        return self.appendDecor(t, .@"*");
    }

    pub fn isPtr(self: *Eval, T: Type) bool {
        return std.mem.indexOfScalar(Decor, self.chain(T), .@"*") != null;
    }

    /// The type a pointer points to: its chain up to the last `*`.
    fn pointee(self: *Eval, T: Type) Error!Type {
        const c = self.chain(T);
        const last = std.mem.lastIndexOfScalar(Decor, c, .@"*").?;
        var t = try self.withChain(T, c[0..last]);
        t.decorators.@"&" = false;
        t.decorators.@"comptime" = mk(T.raw).decorators.@"comptime";
        return t;
    }

    pub fn withChainPub(self: *Eval, T: Type, decors: []const Decor) Error!Type {
        return self.withChain(T, decors);
    }

    pub fn pointeePub(self: *Eval, T: Type) Error!Type {
        return self.pointee(T);
    }

    /// Whether T is a signed C integer; null when it isn't one.
    pub fn cintSigned(self: *Eval, T: Type) ?bool {
        if (self.isPtr(T)) return null;
        const kind = cintOf(T.raw) orelse return null;
        return cSigned(kind);
    }

    fn stripRef(T: Type) Type {
        var t = T;
        t.decorators.@"&" = false;
        return t;
    }

    /// What @typeof gives: no reference, and no qualifiers on the outermost level.
    fn typeOf(self: *Eval, T: Type) Error!Type {
        const t = stripRef(T);
        const c = self.chain(t);
        const keep = if (std.mem.lastIndexOfScalar(Decor, c, .@"*")) |i| i + 1 else 0;
        return self.withChain(t, c[0..keep]);
    }

    fn layoutOf(self: *Eval, T: Type, at: Ast) Error!types.Layout {
        const l = T.layout(&self.decors, &self.types) catch |e| return switch (e) {
            error.NoLayout => self.fail(at, "{f} has no layout", .{self.typeName(T)}),
            error.Unimplemented => self.fail(at, "the layout of {f} isn't known yet", .{self.typeName(T)}),
        };
        return l.?;
    }

    fn structMembers(self: *Eval, T: Type) ?[]const types.TypeMap.StructMember {
        if (@intFromEnum(T.raw) <= @intFromEnum(TypeIdx.builtin)) return null;
        if (self.isPtr(T)) return null;
        return switch (self.types.get(T.raw)) {
            .@"struct" => |m| m,
            else => null,
        };
    }

    fn fnEntry(self: *Eval, T: Type) ?[]const Type {
        if (@intFromEnum(T.raw) <= @intFromEnum(TypeIdx.builtin)) return null;
        if (self.isPtr(T)) return null;
        return switch (self.types.get(T.raw)) {
            .@"fn" => |m| m,
            else => null,
        };
    }

    fn arrEntry(self: *Eval, T: Type) ?@FieldType(types.TypeMap.Entry, "arr") {
        if (@intFromEnum(T.raw) <= @intFromEnum(TypeIdx.builtin)) return null;
        if (self.isPtr(T)) return null;
        return switch (self.types.get(T.raw)) {
            .arr => |a| a,
            else => null,
        };
    }

    /// The function pointer type with this signature, parameters then result.
    fn fnPtrType(self: *Eval, sig: []const Type) Error!Type {
        var key: std.ArrayList(u8) = .empty;
        for (sig) |t| {
            var x = t;
            x.decorators.@"comptime" = false;
            try key.appendSlice(self.gpa, std.mem.asBytes(&typeKey(x)));
        }
        const gop = try self.fn_types.getOrPut(self.gpa, key.items);
        if (!gop.found_existing)
            gop.value_ptr.* = try self.types.add(self.gpa, &self.decors, .{ .@"fn" = try self.gpa.dupe(Type, sig) });
        return mk(gop.value_ptr.*);
    }

    fn arrayOf(self: *Eval, len: usize, T: Type) Error!Type {
        const key = [2]u64{ len, typeKey(T) };
        const gop = try self.arrays.getOrPut(self.gpa, key);
        if (!gop.found_existing)
            gop.value_ptr.* = try self.types.add(self.gpa, &self.decors, .{ .arr = .{ .len = len, .T = T } });
        return mk(gop.value_ptr.*);
    }

    /// Byte offset of each runtime member, in order; comptime members get null.
    fn fieldOffset(self: *Eval, members: []const types.TypeMap.StructMember, index: usize, at: Ast) Error!usize {
        var off: usize = 0;
        for (members[0 .. index + 1], 0..) |m, i| {
            if (m.type.decorators.@"comptime") continue;
            const l = try self.layoutOf(m.type, at);
            off = std.mem.alignForward(usize, off, l.alignment);
            if (i == index) return off;
            off += l.size;
        }
        unreachable;
    }

    // ---------------------------------------------------------------- values

    fn alloc(self: *Eval, T: Type, at: Ast) Error!Value {
        const l = try self.layoutOf(T, at);
        const mem = try self.gpa.alignedAlloc(u8, .@"16", @max(l.size, 1));
        @memset(mem, 0);
        return .{ .T = T, .mem = mem.ptr };
    }

    fn valueOf(self: *Eval, comptime Z: type, T: Type, z: Z) Error!Value {
        const mem = try self.gpa.alignedAlloc(u8, .@"16", @max(@sizeOf(Z), 1));
        @memcpy(mem[0..@sizeOf(Z)], std.mem.asBytes(&z));
        return .{ .T = T, .mem = mem.ptr };
    }

    fn get(comptime Z: type, v: Value) Z {
        return @as(*align(1) const Z, @ptrCast(v.mem)).*;
    }

    fn put(comptime Z: type, mem: [*]u8, z: Z) void {
        @as(*align(1) Z, @ptrCast(mem)).* = z;
    }

    fn voidValue(self: *Eval) Error!Value {
        return self.valueOf(u8, mk(.void), 0);
    }

    fn boolValue(self: *Eval, b: bool, known: bool) Error!Value {
        var T = mk(.bool);
        T.decorators.@"comptime" = known;
        return self.valueOf(bool, T, b);
    }

    fn typeValue(self: *Eval, T: Type) Error!Value {
        return self.valueOf(Type, mk(.type), T);
    }

    fn astValue(self: *Eval, a: Ast) Error!Value {
        return self.valueOf(Ast, mk(.ast), a);
    }

    fn builtinValue(self: *Eval, b: Builtin) Error!Value {
        return self.valueOf(Builtin, mk(.builtin), b);
    }

    fn bigValue(self: *Eval, c: BigConst) Error!Value {
        return self.valueOf(BigConst, mk(.int), c);
    }

    fn smallBig(self: *Eval, n: anytype) Error!Value {
        var m = try BigManaged.initSet(self.gpa, n);
        return self.bigValue(m.toConst());
    }

    fn copy(self: *Eval, v: Value, at: Ast) Error!Value {
        if (self.isRt(v)) return self.use(v, at);
        const T = stripRef(v.T);
        const out = try self.alloc(T, at);
        const l = try self.layoutOf(T, at);
        @memcpy(out.mem[0..l.size], v.mem[0..l.size]);
        return out;
    }

    /// The value a reference refers to; anything else as it is.
    fn load(v: Value) Value {
        return .{ .T = stripRef(v.T), .mem = v.mem };
    }

    /// A zeroed T; an int is 0 and an ast is nil, since neither is all zero bytes.
    fn zero(self: *Eval, T: Type, at: Ast) Error!Value {
        const v = try self.alloc(T, at);
        try self.zeroInit(T, v.mem, at);
        return v;
    }

    fn zeroInit(self: *Eval, T: Type, mem: [*]u8, at: Ast) Error!void {
        if (self.isPtr(T)) return;
        switch (T.raw) {
            .int => put(BigConst, mem, (try BigManaged.initSet(self.gpa, 0)).toConst()),
            .ast, .inlineast => put(Ast, mem, .{ .nil = .{ .src = &parse.builtin_file, .off = 0, .len = 0 } }),
            else => if (self.structMembers(T)) |members| for (members, 0..) |m, i| {
                if (m.type.decorators.@"comptime") continue;
                try self.zeroInit(m.type, mem + try self.fieldOffset(members, i, at), at);
            },
        }
    }

    fn stringValue(self: *Eval, bytes: []const u8) Error!Value {
        const T = try self.arrayOf(bytes.len, mk(.schar));
        const mem = try self.gpa.alignedAlloc(u8, .@"16", @max(bytes.len, 1));
        @memcpy(mem[0..bytes.len], bytes);
        return .{ .T = T, .mem = mem.ptr };
    }

    fn asString(self: *Eval, v: Value, at: Ast) Error![]const u8 {
        const a = self.arrEntry(stripRef(v.T)) orelse return self.fail(at, "expected a string, found {f}", .{self.typeName(v.T)});
        if (a.T.raw != .schar and a.T.raw != .uchar) return self.fail(at, "expected a string, found {f}", .{self.typeName(v.T)});
        return v.mem[0..a.len];
    }

    fn asType(self: *Eval, v: Value, at: Ast) Error!Type {
        try self.needKnown(v, at);
        if (stripRef(v.T).raw != .type) return self.fail(at, "expected a type, found {f}", .{self.typeName(v.T)});
        return get(Type, v);
    }

    fn asAst(self: *Eval, v: Value, at: Ast) Error!Ast {
        try self.needKnown(v, at);
        const raw = stripRef(v.T).raw;
        if (raw != .ast and raw != .inlineast) return self.fail(at, "expected an ast, found {f}", .{self.typeName(v.T)});
        return get(Ast, v);
    }

    fn asBool(self: *Eval, v: Value, at: Ast) Error!bool {
        try self.needKnown(v, at);
        if (stripRef(v.T).raw != .bool or self.isPtr(v.T)) return self.fail(at, "expected a bool, found {f}", .{self.typeName(v.T)});
        return get(bool, v);
    }

    fn asUsize(self: *Eval, v: Value, at: Ast) Error!usize {
        return switch (try self.readInt(v, at)) {
            .big => |b| b.toInt(usize) catch self.fail(at, "{f} doesn't fit a count", .{b}),
            .c => |c| std.math.cast(usize, c.v) orelse self.fail(at, "{d} doesn't fit a count", .{c.v}),
        };
    }

    // ---------------------------------------------------------------- runtime

    fn func(self: *Eval) *mod.Func {
        return &self.module.funcs.items[self.rt.?];
    }

    pub fn isRt(self: *Eval, v: Value) bool {
        return self.rt_values.contains(@intFromPtr(v.mem));
    }

    fn slotOf(v: Value) *RtSlot {
        return @ptrCast(@alignCast(v.mem));
    }

    fn rtValue(self: *Eval, T: Type, reg: Reg) Error!Value {
        const slot = try self.gpa.create(RtSlot);
        slot.* = .{ .reg = reg, .func = self.rt.? };
        try self.rt_values.put(self.gpa, @intFromPtr(slot), {});
        return .{ .T = T, .mem = @ptrCast(slot) };
    }

    fn newReg(self: *Eval, T: Type) Error!Reg {
        var t = stripRef(T);
        t.decorators.@"comptime" = false;
        const f = self.func();
        try f.regs.append(self.gpa, t);
        return @intCast(f.regs.items.len - 1);
    }

    /// Names the register a runtime binding lives in, for debuggers: a
    /// place's storage (what its pointer was taken from), or the value's own
    /// register. The first name a register gets stays.
    fn nameReg(self: *Eval, name: []const u8, v: Value) Error!void {
        if (self.rt == null or !self.isRt(v)) return;
        const slot = slotOf(v);
        if (slot.func != self.rt.?) return;
        const f = self.func();
        var r = slot.reg;
        if (v.T.decorators.@"&") {
            var i = f.nodes.items.len;
            while (i > 0) {
                i -= 1;
                switch (f.nodes.items[i]) {
                    .ldp => |p| if (p.d == r) {
                        r = p.l;
                        break;
                    },
                    else => {},
                }
            }
        }
        const gop = try f.reg_names.getOrPut(self.gpa, r);
        if (!gop.found_existing) gop.value_ptr.* = name;
    }

    fn emit(self: *Eval, n: ir.node) Error!void {
        try self.func().nodes.append(self.gpa, n);
        try self.func().locs.append(self.gpa, self.loc);
    }

    fn regType(self: *Eval, r: Reg) Type {
        return self.func().regs.items[r];
    }

    /// A register holding known bytes, read from rom.
    fn romReg(self: *Eval, v: Value, at: Ast) Error!Reg {
        const T = stripRef(v.T);
        const l = try self.layoutOf(T, at);
        const off = try self.module.addRom(self.gpa, v.mem[0..l.size]);
        const d = try self.newReg(T);
        try self.emit(.{ .rom = .{ .d = d, .off = off } });
        return d;
    }

    /// The usize used for pointer offsets: what C calls unsigned long here.
    fn offsetType() Type {
        return mk(.ulong);
    }

    fn offsetReg(self: *Eval, off: usize, at: Ast) Error!Reg {
        if (off == 0) if (self.func().zero) |z| return z;
        const r = try self.romReg(try self.cValue(.ulong, off), at);
        if (off == 0) self.func().zero = r;
        return r;
    }

    fn ownReg(self: *Eval, v: Value, at: Ast) Error!Reg {
        const s = slotOf(v);
        if (s.func != self.rt.?) return self.fail(at, "a function can't capture a runtime value", .{});
        return s.reg;
    }

    /// The register holding v's value: a register as it is, a place read
    /// through its pointer, known bytes from rom.
    fn toReg(self: *Eval, v: Value, at: Ast) Error!Reg {
        if (!self.isRt(v)) return self.romReg(load(v), at);
        const r = try self.ownReg(v, at);
        if (!v.T.decorators.@"&") return r;
        const d = try self.newReg(v.T);
        try self.emit(.{ .mov = .{ .kind = .VP, .off = try self.offsetReg(0, at), .l = r, .r = d } });
        return d;
    }

    /// The value of v, read now if v is a runtime place.
    fn use(self: *Eval, v: Value, at: Ast) Error!Value {
        if (self.isRt(v) and v.T.decorators.@"&") return self.rtValue(stripRef(v.T), try self.toReg(v, at));
        return load(v);
    }

    fn needKnown(self: *Eval, v: Value, at: Ast) Error!void {
        if (self.isRt(v)) return self.fail(at, "needs a value known at compile time, found a runtime {f}", .{self.typeName(v.T)});
    }

    /// Runs f with nothing lowered: struct blocks, type functions and imports
    /// happen at compile time.
    fn atCompileTime(self: *Eval, comptime f: anytype, args: anytype) @typeInfo(@TypeOf(f)).@"fn".return_type.? {
        const saved = self.rt;
        self.rt = null;
        defer self.rt = saved;
        return @call(.auto, f, args);
    }

    fn mathKind(op: Builtin) ir.node.mathKind {
        return switch (op) {
            .@"+" => .ADD,
            .@"-" => .SUB,
            .@"*" => .MUL,
            .@"/" => .DIV,
            .@"%" => .MOD,
            .@"==" => .EQ,
            .@"!=" => .NE,
            .@"<" => .LT,
            .@">" => .GT,
            .@"<=" => .LE,
            .@">=" => .GE,
            .@"and" => .AND,
            .@"or" => .OR,
            .xor => .XOR,
            .band => .BAND,
            .bor => .BOR,
            .bxor => .BXOR,
            .shl => .SHL,
            .shr => .SHR,
            .@"<=>" => .CMP,
            else => unreachable,
        };
    }

    fn isComparison(op: Builtin) bool {
        return switch (op) {
            .@"==", .@"!=", .@"<", .@">", .@"<=", .@">=" => true,
            else => false,
        };
    }

    fn runtimeBool() Type {
        var T = mk(.bool);
        T.decorators.@"comptime" = false;
        return T;
    }

    /// An integer operation with a runtime operand: the known one becomes
    /// the other's C type.
    fn rtIntOp(self: *Eval, op: Builtin, lv: Value, rv: Value, at: Ast) Error!Value {
        const lt = stripRef(lv.T);
        const rt_ = stripRef(rv.T);
        const lk = cintOf(lt.raw);
        const rk = cintOf(rt_.raw);
        if ((lk == null and lt.raw != .int) or (rk == null and rt_.raw != .int) or self.isPtr(lt) or self.isPtr(rt_))
            return self.fail(at, "{f} and {f} aren't integers", .{ self.typeName(lv.T), self.typeName(rv.T) });
        if (lk != null and rk != null and lk.? != rk.?)
            return self.fail(at, "{f} and {f} don't mix; convert one with `as`", .{ self.typeName(lt), self.typeName(rt_) });
        const kind = lk orelse rk.?;
        const T = cintType(kind);
        const l = try self.toReg(try self.convert(lv, T, at), at);
        const r = try self.toReg(try self.convert(rv, T, at), at);
        const RT = if (isComparison(op)) runtimeBool() else T;
        const d = try self.newReg(RT);
        try self.emit(.{ .math = .{ .op = mathKind(op), .l = l, .r = r, .d = d } });
        return self.rtValue(RT, d);
    }

    fn rtBoolOp(self: *Eval, op: Builtin, lv: Value, rv: Value, at: Ast) Error!Value {
        if (stripRef(lv.T).raw != .bool or stripRef(rv.T).raw != .bool)
            return self.fail(at, "{s} needs bools, found {f} and {f}", .{ @tagName(op), self.typeName(lv.T), self.typeName(rv.T) });
        const l = try self.toReg(lv, at);
        const r = try self.toReg(rv, at);
        const d = try self.newReg(runtimeBool());
        try self.emit(.{ .math = .{ .op = mathKind(op), .l = l, .r = r, .d = d } });
        return self.rtValue(runtimeBool(), d);
    }

    /// @if with a runtime condition: both branches are lowered, and the
    /// value, if the branches have one, meets in a register.
    fn rtIf(self: *Eval, cond: Value, args: []const Ast, at: Ast, scope: *Scope) Error!Value {
        if (stripRef(cond.T).raw != .bool) return self.fail(args[0], "expected a bool, found {f}", .{self.typeName(cond.T)});
        try self.emit(.{ .@"if" = try self.toReg(cond, args[0]) });
        self.rt_branch += 1;
        defer self.rt_branch -= 1;
        const a = try self.eval(args[1], scope);
        const T = try self.typeOf(a.T);
        const result: ?Reg = if (T.raw == .void or args.len == 2) null else try self.newReg(T);
        if (result) |r| try self.emit(.{ .mov = .{ .kind = .VV, .off = try self.offsetReg(0, at), .l = try self.toReg(a, args[1]), .r = r } });
        try self.emit(.@"else");
        if (args.len == 3) {
            const b_ = try self.eval(args[2], scope);
            if (result) |r| {
                const bv = try self.convert(b_, T, args[2]);
                try self.emit(.{ .mov = .{ .kind = .VV, .off = try self.offsetReg(0, at), .l = try self.toReg(bv, args[2]), .r = r } });
            }
        }
        try self.emit(.endif);
        return if (result) |r| self.rtValue(T, r) else self.voidValue();
    }

    /// A type values have at runtime: not compile-time, and not a pattern
    /// like @ast() or a decorated @any().
    fn isRuntimeType(T: Type) bool {
        if (T.decorators.@"comptime") return false;
        return switch (T.raw) {
            .any, .ast, .inlineast, .type, .int, .builtin => false,
            else => true,
        };
    }

    /// Whether a value of T can exist at runtime: nothing in it, through
    /// fields, arrays and pointers, is compile-time only. A pointer to a
    /// struct holding a type can't be runtime.
    fn holdsRuntime(self: *Eval, T: Type) Error!bool {
        var seen: std.ArrayList(TypeIdx) = .empty;
        defer seen.deinit(self.gpa);
        return self.holdsRuntimeIn(T, &seen);
    }

    fn holdsRuntimeIn(self: *Eval, T: Type, seen: *std.ArrayList(TypeIdx)) Error!bool {
        if (T.decorators.@"comptime") return false;
        switch (T.raw) {
            .any, .ast, .inlineast, .type, .int, .builtin => return false,
            else => {},
        }
        if (@intFromEnum(T.raw) <= @intFromEnum(TypeIdx.builtin)) return true;
        if (std.mem.indexOfScalar(TypeIdx, seen.items, T.raw) != null) return true;
        try seen.append(self.gpa, T.raw);
        switch (self.types.get(T.raw)) {
            // only fields; the namespace is compile-time
            .@"struct" => |ms| for (ms) |m| {
                if (m.type.decorators.@"comptime") continue;
                if (!try self.holdsRuntimeIn(m.type, seen)) return false;
            },
            .arr => |a| return self.holdsRuntimeIn(a.T, seen),
            else => {},
        }
        return true;
    }

    /// @loop while lowering. A @repeat under a runtime branch makes it a
    /// runtime loop: `loop`, the body, the value into a register, `endloop`.
    /// Otherwise it runs at compile time, and whatever its passes lower stays
    /// in place, one after another.
    fn lowerLoop(self: *Eval, body: Ast, at: Ast, scope: *Scope) Error!Value {
        const start = self.func().nodes.items.len;
        try self.emit(.loop);
        try self.loops.append(self.gpa, .{ .branch = self.rt_branch });
        const v = self.eval(body, scope) catch |e| {
            _ = self.loops.pop();
            return e;
        };
        const ctx = self.loops.pop().?;
        if (!ctx.runtime) {
            _ = self.func().nodes.orderedRemove(start);
            _ = self.func().locs.orderedRemove(start);
            var val = v;
            while (self.repeat) {
                self.repeat = false;
                val = try self.eval(body, scope);
            }
            return val;
        }
        if (self.repeat) return self.fail(at, "a loop can't repeat both at compile time and at runtime", .{});
        const T = try self.typeOf(v.T);
        var result: ?Reg = null;
        if (T.raw != .void or self.isPtr(T)) {
            const r = try self.newReg(T);
            try self.emit(.{ .mov = .{ .kind = .VV, .off = try self.offsetReg(0, at), .l = try self.toReg(v, at), .r = r } });
            result = r;
        }
        try self.emit(.endloop);
        return if (result) |r| self.rtValue(T, r) else self.voidValue();
    }

    /// @get[x, i] of an array: element i, a place if x is. Indices aren't
    /// checked, as in C: the memory around an array may well be its own, as
    /// with an @arr[0, T] behind a pointer whose length is kept elsewhere.
    fn arrayGet(self: *Eval, x: Value, arr: @FieldType(types.TypeMap.Entry, "arr"), index: Ast, at: Ast, scope: *Scope) Error!Value {
        const iv = try self.eval(index, scope);
        const l = try self.layoutOf(arr.T, at);
        var E = arr.T;
        E.decorators.@"&" = x.T.decorators.@"&";
        if (!self.isRt(x) and !self.isRt(iv)) {
            const i = try self.asUsize(iv, index);
            return .{ .T = E, .mem = x.mem + i * l.size };
        }
        if (self.rt == null) return self.fail(index, "needs a known index", .{});
        // a pointer to the array: a place's own, or one to a copy of the value
        const base = if (self.isRt(x) and x.T.decorators.@"&") try self.ownReg(x, at) else blk: {
            const r = try self.toReg(x, at);
            const p = try self.newReg(try self.ptrTo(stripRef(x.T)));
            try self.emit(.{ .ldp = .{ .l = r, .d = p } });
            break :blk p;
        };
        const i = try self.toReg(try self.convert(iv, offsetType(), index), index);
        const off = try self.newReg(offsetType());
        try self.emit(.{ .math = .{ .op = .MUL, .l = i, .r = try self.offsetReg(l.size, at), .d = off } });
        const ep = try self.newReg(try self.ptrTo(arr.T));
        try self.emit(.{ .math = .{ .op = .ADD, .l = base, .r = off, .d = ep } });
        var place = arr.T;
        place.decorators.@"&" = true;
        const pv = try self.rtValue(place, ep);
        return if (self.isRt(x) and x.T.decorators.@"&") pv else self.use(pv, at);
    }

    /// A result type made @comptime: the function runs at compile time. Types
    /// that are always compile-time (@type(), @any(), @ast() ...) don't count.
    fn comptimeResult(T: Type) bool {
        return T.decorators.@"comptime" and !mk(T.raw).decorators.@"comptime";
    }

    /// Whether calling f lowers a call to a C function: when every parameter
    /// and the result can exist at runtime, all the way through. Anything
    /// else that takes compile-time things is inlined where it's called; a
    /// @comptime result runs at compile time.
    fn isRuntimeFn(self: *Eval, f: Function) Error!bool {
        if (comptimeResult(f.ret)) return false;
        for (f.params) |p| if (!isRuntimeType(p.T) or !try self.holdsRuntime(p.T)) return false;
        const void_ret = f.ret.raw == .void and f.ret.decorators.decor == 0;
        if (!void_ret and (!isRuntimeType(f.ret) or !try self.holdsRuntime(f.ret))) return false;
        return f.params.len != 0 or !void_ret;
    }

    /// The register type for a parameter or result: a place is a pointer.
    fn passType(self: *Eval, T: Type) Error!Type {
        return if (T.decorators.@"&") self.ptrTo(stripRef(T)) else T;
    }

    fn lowerFn(self: *Eval, handle: u32, at: Ast) Error!u32 {
        if (self.lowered.get(handle)) |i| return i;
        const f = self.fns.items[handle];
        _ = at;
        const idx: u32 = @intCast(self.module.funcs.items.len);
        try self.module.funcs.append(self.gpa, .{ .ret = f.ret });
        try self.lowered.put(self.gpa, handle, idx);
        const saved = self.rt;
        self.rt = idx;
        defer self.rt = saved;
        const sc = try self.gpa.create(Scope);
        sc.* = .{ .parent = f.closure, .ret = f.ret };
        for (f.params, 0..) |p, i| {
            const r = try self.newReg(try self.passType(p.T));
            try self.emit(.{ .arg = .{ .idx = @intCast(i), .d = r } });
            try self.func().params.append(self.gpa, r);
            try sc.names.put(self.gpa, p.name, try self.rtValue(p.T, r));
            try self.func().reg_names.put(self.gpa, r, p.name);
        }
        const result = try self.evalIn(&.{f.body}, sc);
        if (f.ret.raw != .void or self.isPtr(f.ret)) {
            self.func().result = if (f.ret.decorators.@"&") try self.ownReg(result, f.body) else try self.toReg(try self.convert(result, f.ret, f.body), f.body);
        }
        return idx;
    }

    fn callLowered(self: *Eval, handle: u32, args: []const Arg, at: Ast, caller: *Scope) Error!Value {
        const f = self.fns.items[handle];
        var regs: std.ArrayList(Reg) = .empty;
        for (f.params, args) |p, a| {
            const v = a.value orelse try self.eval(a.ast, caller);
            if (p.T.decorators.@"&") {
                if (!v.T.decorators.@"&" or !self.isRt(v)) return self.fail(a.ast, "`{s}` needs a runtime place", .{p.name});
                try regs.append(self.gpa, try self.ownReg(v, a.ast));
            } else try regs.append(self.gpa, try self.toReg(try self.convert(v, p.T, a.ast), a.ast));
        }
        const idx = try self.lowerFn(handle, at);
        const ptrT = Type{ .raw = (try self.fnTypeOf(handle)).raw, .decorators = .{ .@"comptime" = false, .@"&" = false, .decor = 0 } };
        const fr = try self.newReg(ptrT);
        try self.emit(.{ .rom = .{ .d = fr, .off = try self.module.addFuncAddr(self.gpa, idx) } });
        const retT = try self.passType(f.ret);
        const d = try self.newReg(retT);
        const list = try self.gpa.allocSentinel(Reg, regs.items.len, std.math.maxInt(Reg));
        @memcpy(list, regs.items);
        try self.emit(.{ .call = .{ .@"fn" = fr, .d = d, .args = list } });
        if (f.ret.raw == .void and !self.isPtr(f.ret)) return self.voidValue();
        return self.rtValue(f.ret, d);
    }

    fn fnTypeOf(self: *Eval, handle: u32) Error!Type {
        if (self.fn_ptr_types.get(handle)) |T| return T;
        const f = self.fns.items[handle];
        var sig: std.ArrayList(Type) = .empty;
        for (f.params) |p| try sig.append(self.gpa, try self.passType(p.T));
        try sig.append(self.gpa, try self.passType(f.ret));
        const T = try self.fnPtrType(sig.items);
        try self.fn_ptr_types.put(self.gpa, handle, T);
        return T;
    }

    /// Lowers a file's top level into the module's main function.
    pub fn lowerFile(self: *Eval, path: []const u8) Error!void {
        const idx: u32 = @intCast(self.module.funcs.items.len);
        try self.module.funcs.append(self.gpa, .{ .ret = mk(.void) });
        self.module.main = idx;
        self.rt = idx;
        defer self.rt = null;
        const v = try self.evalFile(path, null);
        const T = try self.typeOf(v.T);
        var ret = T;
        ret.decorators.@"comptime" = false;
        self.func().ret = ret;
        if (T.raw != .void or self.isPtr(T)) self.func().result = try self.toReg(v, .{ .nil = undefined });
    }

    // --------------------------------------------------------------- integers

    fn cintOf(raw: TypeIdx) ?CInt {
        return raw.get_cint();
    }

    fn cintType(kind: CInt) Type {
        return mk(std.meta.stringToEnum(TypeIdx, @tagName(kind)).?);
    }

    fn readC(kind: CInt, mem: [*]const u8) i128 {
        return switch (kind) {
            .schar => @as(*align(1) const i8, @ptrCast(mem)).*,
            .uchar => @as(*align(1) const u8, @ptrCast(mem)).*,
            .sshort => @as(*align(1) const c_short, @ptrCast(mem)).*,
            .ushort => @as(*align(1) const c_ushort, @ptrCast(mem)).*,
            .sint => @as(*align(1) const c_int, @ptrCast(mem)).*,
            .uint => @as(*align(1) const c_uint, @ptrCast(mem)).*,
            .slong => @as(*align(1) const c_long, @ptrCast(mem)).*,
            .ulong => @as(*align(1) const c_ulong, @ptrCast(mem)).*,
            .slonglong => @as(*align(1) const c_longlong, @ptrCast(mem)).*,
            .ulonglong => @as(*align(1) const c_ulonglong, @ptrCast(mem)).*,
        };
    }

    /// Writes x wrapped to the width of kind, as C conversions to unsigned do.
    fn writeC(kind: CInt, mem: [*]u8, x: i128) void {
        const u: u128 = @bitCast(x);
        switch (kind) {
            .schar => put(i8, mem, @bitCast(@as(u8, @truncate(u)))),
            .uchar => put(u8, mem, @truncate(u)),
            .sshort => put(c_short, mem, @bitCast(@as(c_ushort, @truncate(u)))),
            .ushort => put(c_ushort, mem, @truncate(u)),
            .sint => put(c_int, mem, @bitCast(@as(c_uint, @truncate(u)))),
            .uint => put(c_uint, mem, @truncate(u)),
            .slong => put(c_long, mem, @bitCast(@as(c_ulong, @truncate(u)))),
            .ulong => put(c_ulong, mem, @truncate(u)),
            .slonglong => put(c_longlong, mem, @bitCast(@as(c_ulonglong, @truncate(u)))),
            .ulonglong => put(c_ulonglong, mem, @truncate(u)),
        }
    }

    fn cBits(kind: CInt) u16 {
        return switch (kind) {
            .schar, .uchar => 8,
            .sshort, .ushort => @bitSizeOf(c_short),
            .sint, .uint => @bitSizeOf(c_int),
            .slong, .ulong => @bitSizeOf(c_long),
            .slonglong, .ulonglong => @bitSizeOf(c_longlong),
        };
    }

    fn cSigned(kind: CInt) bool {
        return switch (kind) {
            .schar, .sshort, .sint, .slong, .slonglong => true,
            else => false,
        };
    }

    fn readInt(self: *Eval, v: Value, at: Ast) Error!IntVal {
        try self.needKnown(v, at);
        const T = stripRef(v.T);
        if (!self.isPtr(T)) {
            if (T.raw == .int) return .{ .big = get(BigConst, v) };
            if (cintOf(T.raw)) |kind| return .{ .c = .{ .kind = kind, .v = readC(kind, v.mem) } };
        }
        return self.fail(at, "expected an integer, found {f}", .{self.typeName(v.T)});
    }

    fn cValue(self: *Eval, kind: CInt, x: i128) Error!Value {
        const T = cintType(kind);
        const v = try self.alloc(T, .{ .nil = undefined });
        writeC(kind, v.mem, x);
        return v;
    }

    /// A known integer as kind, if it fits.
    fn bigToC(self: *Eval, b: BigConst, kind: CInt, at: Ast) Error!i128 {
        if (!b.fitsInTwosComp(if (cSigned(kind)) .signed else .unsigned, cBits(kind)))
            return self.fail(at, "{f} doesn't fit {f}", .{ b, self.typeName(cintType(kind)) });
        return b.toInt(i128) catch unreachable;
    }

    fn intOp(self: *Eval, op: Builtin, lv: Value, rv: Value, at: Ast) Error!Value {
        if (self.isRt(lv) or self.isRt(rv)) return self.rtIntOp(op, lv, rv, at);
        const l = try self.readInt(lv, at);
        const r = try self.readInt(rv, at);
        if (l == .big and r == .big) return self.bigOp(op, l.big, r.big, at);
        const kind = if (l == .c) l.c.kind else r.c.kind;
        if (l == .c and r == .c and l.c.kind != r.c.kind)
            return self.fail(at, "{f} and {f} don't mix; convert one with `as`", .{ self.typeName(cintType(l.c.kind)), self.typeName(cintType(r.c.kind)) });
        const a: i128 = if (l == .c) l.c.v else try self.bigToC(l.big, kind, at);
        const b: i128 = if (r == .c) r.c.v else try self.bigToC(r.big, kind, at);
        const bits = cBits(kind);
        return switch (op) {
            .@"+" => self.cValue(kind, a +% b),
            .@"-" => self.cValue(kind, a -% b),
            .@"*" => self.cValue(kind, a *% b),
            .@"/", .@"%" => {
                if (b == 0) return self.fail(at, "division by zero", .{});
                return self.cValue(kind, if (op == .@"/") @divTrunc(a, b) else @rem(a, b));
            },
            .band => self.cValue(kind, a & b),
            .bor => self.cValue(kind, a | b),
            .bxor => self.cValue(kind, a ^ b),
            .shl, .shr => {
                const left = (op == .shl) == (b >= 0);
                const n = @abs(b);
                if (n >= bits) return self.cValue(kind, 0);
                const s: u7 = @intCast(n);
                return self.cValue(kind, if (left) a << s else a >> s);
            },
            .@"<=>" => self.cValue(kind, std.math.sign(a - b)),
            .@"==" => self.boolValue(a == b, false),
            .@"!=" => self.boolValue(a != b, false),
            .@"<" => self.boolValue(a < b, false),
            .@">" => self.boolValue(a > b, false),
            .@"<=" => self.boolValue(a <= b, false),
            .@">=" => self.boolValue(a >= b, false),
            else => unreachable,
        };
    }

    fn bigOp(self: *Eval, op: Builtin, a: BigConst, b: BigConst, at: Ast) Error!Value {
        const order = a.order(b);
        switch (op) {
            .@"==" => return self.boolValue(order == .eq, true),
            .@"!=" => return self.boolValue(order != .eq, true),
            .@"<" => return self.boolValue(order == .lt, true),
            .@">" => return self.boolValue(order == .gt, true),
            .@"<=" => return self.boolValue(order != .gt, true),
            .@">=" => return self.boolValue(order != .lt, true),
            .@"<=>" => return self.smallBig(@as(i8, switch (order) {
                .lt => -1,
                .eq => 0,
                .gt => 1,
            })),
            else => {},
        }
        var ma = try a.toManaged(self.gpa);
        var mb = try b.toManaged(self.gpa);
        var r = try BigManaged.init(self.gpa);
        switch (op) {
            .@"+" => try r.add(&ma, &mb),
            .@"-" => try r.sub(&ma, &mb),
            .@"*" => try r.mul(&ma, &mb),
            .@"/", .@"%" => {
                if (b.eqlZero()) return self.fail(at, "division by zero", .{});
                var rem = try BigManaged.init(self.gpa);
                try r.divTrunc(&rem, &ma, &mb);
                if (op == .@"%") r = rem;
            },
            .band => try r.bitAnd(&ma, &mb),
            .bor => try r.bitOr(&ma, &mb),
            .bxor => try r.bitXor(&ma, &mb),
            .shl, .shr => {
                const n = b.abs().toInt(usize) catch return self.fail(at, "shift by {f} is too far", .{b});
                if ((op == .shl) == b.positive) try r.shiftLeft(&ma, n) else try r.shiftRight(&ma, n);
            },
            else => unreachable,
        }
        return self.bigValue(r.toConst());
    }

    // ------------------------------------------------------------ conversion

    /// `v as T`. Always a new value, never a reference into v.
    fn convert(self: *Eval, value: Value, T: Type, at: Ast) Error!Value {
        if (self.isRt(value)) return self.rtConvert(value, T, at);
        if (try self.toFnPtr(value, T, at)) |v| return v;
        const v = load(value);
        var target = stripRef(T);
        if (typeEql(v.T, target)) return self.copy(v, at);
        // anything converts to void by being discarded
        if (target.raw == .void and !self.isPtr(target)) return self.voidValue();
        // qualifiers and comptime-ness don't change the bytes
        const vb = try self.typeOf(v.T);
        const tb = try self.typeOf(target);
        if (vb.raw == tb.raw and std.mem.eql(Decor, self.chain(vb), self.chain(tb))) {
            const out = try self.copy(v, at);
            return .{ .T = target, .mem = out.mem };
        }
        // a pointer to another pointer type is the same address
        if (self.isPtr(vb) and self.isPtr(tb)) return self.valueOf(usize, target, get(usize, v));
        if (!self.isPtr(vb) and !self.isPtr(tb)) {
            if (cintOf(tb.raw)) |kind| switch (try self.readInt(v, at)) {
                .big => |b| {
                    const out = try self.cValue(kind, try self.bigToC(b, kind, at));
                    return .{ .T = target, .mem = out.mem };
                },
                .c => |c| {
                    const out = try self.cValue(kind, c.v);
                    return .{ .T = target, .mem = out.mem };
                },
            };
            if (tb.raw == .int) switch (try self.readInt(v, at)) {
                .big => return self.copy(v, at),
                .c => |c| return self.smallBig(c.v),
            };
        }
        target = T;
        return self.fail(at, "can't convert {f} to {f}", .{ self.typeName(v.T), self.typeName(target) });
    }

    /// `f as @fnptr[...]`: a function whose signature matches, as a pointer.
    fn toFnPtr(self: *Eval, value: Value, T: Type, at: Ast) Error!?Value {
        const target = stripRef(T);
        const want = self.fnEntry(target) orelse return null;
        if (target.decorators.@"comptime") return null;
        const vt = stripRef(value.T);
        if (self.fnEntry(vt) == null or !vt.decorators.@"comptime") return null;
        const handle = get(u32, value);
        const have = self.fnEntry(try self.fnTypeOf(handle)).?;
        const same = have.len == want.len and for (have, want) |a, b| {
            var x = a;
            var y = b;
            x.decorators.@"comptime" = false;
            y.decorators.@"comptime" = false;
            if (!typeEql(x, y)) break false;
        } else true;
        if (!same) return self.fail(at, "{f} doesn't have the signature of {f}", .{ self.typeName(value.T), self.typeName(T) });
        if (self.rt != null) {
            if (!try self.isRuntimeFn(self.fns.items[handle])) return self.fail(at, "only a function over runtime types has a pointer", .{});
            const idx = try self.lowerFn(handle, at);
            const r = try self.newReg(target);
            try self.emit(.{ .rom = .{ .d = r, .off = try self.module.addFuncAddr(self.gpa, idx) } });
            return try self.rtValue(target, r);
        }
        return try self.valueOf(u64, target, handle);
    }

    fn rtConvert(self: *Eval, value: Value, T: Type, at: Ast) Error!Value {
        const target = stripRef(T);
        if (target.raw == .void and !self.isPtr(target)) return self.voidValue();
        const vb = try self.typeOf(value.T);
        const tb = try self.typeOf(target);
        var same = vb.raw == tb.raw and std.mem.eql(Decor, self.chain(vb), self.chain(tb));
        if (same) return self.rtValue(target, try self.toReg(value, at));
        // integers and pointers convert to each other
        const v_int = cintOf(vb.raw) != null and !self.isPtr(vb);
        const t_int = cintOf(tb.raw) != null and !self.isPtr(tb);
        same = (v_int or self.isPtr(vb)) and (t_int or self.isPtr(tb));
        if (!same) return self.fail(at, "can't convert a runtime {f} to {f}", .{ self.typeName(value.T), self.typeName(T) });
        const l = try self.toReg(value, at);
        const d = try self.newReg(target);
        try self.emit(.{ .cast = .{ .l = l, .d = d } });
        return self.rtValue(target, d);
    }

    // -------------------------------------------------------------- evaluate

    pub fn eval(self: *Eval, node: Ast, scope: *Scope) Error!Value {
        const saved = self.loc;
        defer self.loc = saved;
        if (node == .call) if (firstRef(node)) |r| if (r.src.* == .disk and r.src != self.macro_src) {
            self.loc = r;
        };
        return switch (node) {
            .nil => self.voidValue(),
            .num => |r| self.intLiteral(r.gets(), node),
            .str => |r| self.stringValue(try self.unescape(r.gets(), node)),
            .id => |r| self.lookupId(r.gets(), node, scope),
            .call => |items| self.evalCall(items, node, scope),
        };
    }

    fn intLiteral(self: *Eval, text: []const u8, at: Ast) Error!Value {
        var m = try BigManaged.init(self.gpa);
        const base: u8, const digits = if (std.mem.startsWith(u8, text, "0x"))
            .{ 16, text[2..] }
        else if (std.mem.startsWith(u8, text, "0b"))
            .{ 2, text[2..] }
        else
            .{ 10, text };
        m.setString(base, digits) catch return self.fail(at, "bad number `{s}`", .{text});
        return self.bigValue(m.toConst());
    }

    fn unescape(self: *Eval, text: []const u8, at: Ast) Error![]const u8 {
        var out: std.ArrayList(u8) = .empty;
        var i: usize = 0;
        while (i < text.len) : (i += 1) {
            if (text[i] != '\\') {
                try out.append(self.gpa, text[i]);
                continue;
            }
            i += 1;
            switch (text[i]) {
                'n' => try out.append(self.gpa, '\n'),
                't' => try out.append(self.gpa, '\t'),
                'r' => try out.append(self.gpa, '\r'),
                '0' => try out.append(self.gpa, 0),
                '"', '\\' => try out.append(self.gpa, text[i]),
                'x' => {
                    const end = std.mem.indexOfScalarPos(u8, text, i, '}').?;
                    var it = std.mem.tokenizeAny(u8, text[i + 2 .. end], " \t");
                    while (it.next()) |hex|
                        try out.append(self.gpa, std.fmt.parseInt(u8, hex, 16) catch
                            return self.fail(at, "bad escape `\\x{{{s}}}`", .{text[i + 2 .. end]}));
                    i = end;
                },
                else => return self.fail(at, "bad escape `\\{c}`", .{text[i]}),
            }
        }
        return out.items;
    }

    const builtin_aliases = std.StaticStringMap(Builtin).initComptime(.{
        .{ "alloca", .stackptr },
        .{ "alloc", .comptime_alloc },
        .{ "free", .comptime_free },
        .{ "yielded", .yield },
    });

    fn builtinByName(name: []const u8) ?Builtin {
        const b = std.meta.stringToEnum(Builtin, name) orelse builtin_aliases.get(name) orelse return null;
        return if (isOperator(b)) null else b;
    }

    fn lookupId(self: *Eval, name: []const u8, at: Ast, scope: *Scope) Error!Value {
        if (name.len > 1 and name[0] == '@') {
            const b = builtinByName(name[1..]) orelse return self.fail(at, "no builtin `{s}`", .{name});
            return self.builtinValue(b);
        }
        return scope.lookup(name) orelse self.fail(at, "`{s}` isn't bound", .{name});
    }

    fn headText(node: Ast) ?[]const u8 {
        return if (node == .id) node.id.gets() else null;
    }

    fn isListHead(node: Ast) bool {
        return node == .id and node.id.src == &parse.builtin_file and node.id.off == 0;
    }

    fn isBlockHead(node: Ast) bool {
        return node == .id and node.id.src == &parse.builtin_file and node.id.off == 2;
    }

    fn evalCall(self: *Eval, items: []const Ast, node: Ast, scope: *Scope) Error!Value {
        if (items.len == 0) return self.voidValue();
        const head = items[0];
        if (isListHead(head)) return switch (items.len) {
            1 => self.voidValue(),
            // (x) is a one-item list, and a one-item list is its item
            2 => self.eval(items[1], scope),
            else => self.fail(node, "lists of more than one value aren't values yet", .{}),
        };
        if (isBlockHead(head)) return self.evalBlock(items[1..], scope);
        if (headText(head)) |t| {
            if (std.mem.eql(u8, t, "'")) {
                if (items.len != 2) return self.fail(node, "' takes one argument; quote a list with '([...])", .{});
                return self.astValue(try self.quote(items[1], scope));
            }
            if (std.mem.eql(u8, t, "`")) {
                if (items.len != 2) return self.fail(node, "` takes one argument", .{});
                // outside a quote, ` runs the ast it's given, here
                return self.eval(try self.asAst(try self.eval(items[1], scope), items[1]), scope);
            }
            if (std.mem.eql(u8, t, "\\") or std.mem.eql(u8, t, ".."))
                return self.fail(node, "{s} only means something inside a quote", .{t});
        }

        var args: std.ArrayList(Arg) = .empty;
        var f: Value = undefined;
        // a:f(x) is T.f[a, x], with a evaluated once
        if (head == .call and head.call.len == 3 and headText(head.call[0]) != null and
            std.mem.eql(u8, headText(head.call[0]).?, ":"))
        {
            const obj = try self.eval(head.call[1], scope);
            f = try self.member(obj, head.call[2], head, true);
            try args.append(self.gpa, .{ .ast = head.call[1], .value = obj });
        } else f = try self.eval(head, scope);
        for (items[1..]) |a| try args.append(self.gpa, .{ .ast = a });
        return self.apply(f, args.items, node, scope, false);
    }

    fn evalBlock(self: *Eval, items: []const Ast, scope: *Scope) Error!Value {
        const sc = try self.gpa.create(Scope);
        sc.* = .{ .parent = scope };
        return self.evalIn(items, sc);
    }

    /// Runs statements in sc and yields the last one's value, then sc's defers.
    fn evalIn(self: *Eval, items: []const Ast, sc: *Scope) Error!Value {
        var result = try self.voidValue();
        for (items) |item| result = try self.eval(item, sc);
        sc.yielded = result;
        var i = sc.defers.items.len;
        while (i > 0) {
            i -= 1;
            _ = try self.eval(sc.defers.items[i], sc);
        }
        return result;
    }

    // ----------------------------------------------------------------- quote

    /// The ast with its unquotes run: ` x splices x's value, \ x keeps x as it
    /// is for a later quote, and .. ` x spreads x's items into the call.
    fn quote(self: *Eval, node: Ast, scope: *Scope) Error!Ast {
        if (node != .call or node.call.len == 0) return node;
        const items = node.call;
        if (headText(items[0])) |t| {
            // unquotes written inside an unquoted expression (`f(`x)) belong
            // to this quote: they run first, then the expression does; what
            // it gives is spliced as it is
            if (std.mem.eql(u8, t, "`") and items.len == 2)
                return self.toAst(try self.eval(try self.quote(items[1], scope), scope), items[1]);
            if (std.mem.eql(u8, t, "\\") and items.len == 2) return items[1];
        }
        var out: std.ArrayList(Ast) = .empty;
        for (items) |item| {
            if (item == .call and item.call.len == 2 and headText(item.call[0]) != null and
                std.mem.eql(u8, headText(item.call[0]).?, ".."))
            {
                const spread = try self.quote(item.call[1], scope);
                if (spread != .call or spread.call.len == 0)
                    return self.fail(item, ".. needs a list to spread", .{});
                try out.appendSlice(self.gpa, spread.call[1..]);
            } else try out.append(self.gpa, try self.quote(item, scope));
        }
        return .{ .call = out.items };
    }

    /// The syntax for a value spliced into a quote.
    fn toAst(self: *Eval, v: Value, at: Ast) Error!Ast {
        const T = stripRef(v.T);
        if (T.raw == .ast or T.raw == .inlineast) return get(Ast, v);
        if (T.raw == .int) {
            return .{ .num = try self.synth(try std.fmt.allocPrint(self.gpa, "{f}", .{get(BigConst, v)})) };
        }
        return self.fail(at, "{f} can't be spliced into syntax", .{self.typeName(v.T)});
    }

    /// Text that isn't in any source file, for ids made by @id and @gensym.
    fn synth(self: *Eval, text: []const u8) Error!SrcRef {
        const owned = try self.gpa.dupe(u8, text);
        const file = try self.gpa.create(FileItem);
        file.* = .{ .memory = .fromOwnedSlice(owned) };
        return .{ .src = file, .off = 0, .len = @intCast(owned.len) };
    }

    // ------------------------------------------------------------------ calls

    fn apply(self: *Eval, f: Value, args: []const Arg, at: Ast, scope: *Scope, outline: bool) Error!Value {
        const T = stripRef(f.T);
        if (T.raw == .builtin) {
            const asts = try self.gpa.alloc(Ast, args.len);
            for (args, asts) |a, *o| {
                if (a.value != null) return self.fail(at, "builtins can't be called with :", .{});
                o.* = a.ast;
            }
            return self.builtin(get(Builtin, f), asts, at, scope);
        }
        if (T.raw == .type) {
            // calling a type gives its initialized value
            if (args.len != 0) return self.fail(at, "a type takes no arguments", .{});
            return self.construct(get(Type, f), at);
        }
        if (self.fnEntry(T) != null and T.decorators.@"comptime")
            return self.callFn(get(u32, f), args, at, scope, outline);
        if (self.fnEntry(T)) |sig| return self.callFnPtr(f, sig, args, at, scope);
        // a callable: a struct value with a `()` member, called with itself first
        if (self.structMembers(T)) |members| for (members) |m| {
            if (!std.mem.eql(u8, m.name, "()") or !m.type.decorators.@"comptime") continue;
            const with_self = try self.gpa.alloc(Arg, args.len + 1);
            with_self[0] = .{ .ast = if (at == .call) at.call[0] else at, .value = f };
            @memcpy(with_self[1..], args);
            return self.apply(.{ .T = m.type, .mem = @constCast(m.value) }, with_self, at, scope, outline);
        };
        return self.fail(at, "{f} can't be called", .{self.typeName(f.T)});
    }

    /// A call through a function pointer: the arguments become its
    /// parameter types. Lowered, it's a call through the register.
    fn callFnPtr(self: *Eval, f: Value, sig: []const Type, args: []const Arg, at: Ast, scope: *Scope) Error!Value {
        const params = sig[0 .. sig.len - 1];
        const ret = sig[sig.len - 1];
        if (args.len != params.len) return self.fail(at, "expected {d} argument(s), found {d}", .{ params.len, args.len });
        if (!self.isRt(f)) {
            // known: it's a function, by its handle
            const handle: u32 = @truncate(get(u64, f));
            return self.callFn(handle, args, at, scope, false);
        }
        var regs: std.ArrayList(Reg) = .empty;
        for (params, args) |P, a| {
            const v = a.value orelse try self.eval(a.ast, scope);
            if (self.isPtr(P) and v.T.decorators.@"&" and self.isRt(v) and typeEql(stripRef(try self.ptrToKeep(v.T)), stripRef(P)))
                try regs.append(self.gpa, try self.ownReg(v, a.ast))
            else
                try regs.append(self.gpa, try self.toReg(try self.convert(v, P, a.ast), a.ast));
        }
        const fr = try self.toReg(f, at);
        const d = try self.newReg(ret);
        const list = try self.gpa.allocSentinel(Reg, regs.items.len, std.math.maxInt(Reg));
        @memcpy(list, regs.items);
        try self.emit(.{ .call = .{ .@"fn" = fr, .d = d, .args = list } });
        if (ret.raw == .void and !self.isPtr(ret)) return self.voidValue();
        return self.rtValue(ret, d);
    }

    fn ptrToKeep(self: *Eval, T: Type) Error!Type {
        return self.ptrTo(stripRef(T));
    }

    fn construct(self: *Eval, T: Type, at: Ast) Error!Value {
        const v = try self.zero(T, at);
        if (self.structMembers(T)) |members| for (members, 0..) |m, i| {
            if (m.type.decorators.@"comptime") continue;
            const l = try self.layoutOf(m.type, at);
            @memcpy((v.mem + try self.fieldOffset(members, i, at))[0..l.size], m.value[0..l.size]);
        };
        return v;
    }

    fn callFn(self: *Eval, handle: u32, args: []const Arg, at: Ast, caller: *Scope, outline: bool) Error!Value {
        const f = self.fns.items[handle];
        if (args.len != f.params.len)
            return self.fail(at, "expected {d} argument(s), found {d}", .{ f.params.len, args.len });
        // while lowering, a function over runtime types is a call to a C
        // function; any other function runs here, inlining what it lowers
        if (self.rt != null and try self.isRuntimeFn(f)) return self.callLowered(handle, args, at, caller);
        const sc = try self.gpa.create(Scope);
        sc.* = .{ .parent = f.closure, .ret = f.ret };
        for (f.params, args) |param, a| {
            var p = param;
            if (p.T_ast) |t| p.T = try self.typeArg(t, sc);
            const v: Value = switch (p.T.raw) {
                .ast, .inlineast => if (p.T.decorators.@"&") blk: {
                    // a reference to an ast takes the caller's variable
                    const name = headText(a.ast) orelse return self.fail(a.ast, "`{s}` takes a variable", .{p.name});
                    const v = caller.lookup(name) orelse return self.fail(a.ast, "`{s}` isn't bound", .{name});
                    if (!v.T.decorators.@"&") return self.fail(a.ast, "`{s}` isn't a variable", .{name});
                    break :blk v;
                } else if (p.T.decorators.decor == 0)
                    // only a bare @ast() takes the syntax, unevaluated
                    try self.astValue(a.ast)
                else
                    // a decorated one takes a value like any other type:
                    // @const(@ast()) is an ast, evaluated
                    try self.convert(a.value orelse try self.eval(a.ast, caller), p.T, a.ast),
                .any => try self.asAny(a.value orelse try self.eval(a.ast, caller), p.T, a.ast),
                else => blk: {
                    const v = a.value orelse try self.eval(a.ast, caller);
                    if (p.T.decorators.@"&") {
                        if (!v.T.decorators.@"&") return self.fail(a.ast, "`{s}` needs a place", .{p.name});
                        break :blk v;
                    }
                    break :blk try self.convert(v, p.T, a.ast);
                },
            };
            try sc.names.put(self.gpa, p.name, v);
        }
        const ret = if (f.ret_ast) |t| try self.typeArg(t, sc) else f.ret;
        sc.ret = ret;
        var key: ?[]const u8 = null;
        // a type result is interned by the arguments, unless it's
        // @volatile(@type()): one that can change, like a lookup; that still
        // runs at compile time
        const volatile_type = ret.raw == .type and !self.isPtr(ret) and
            std.mem.indexOfScalar(Decor, self.chain(ret), .@"volatile") != null;
        if (ret.raw == .type and !self.isPtr(ret) and !volatile_type) {
            var bytes: std.ArrayList(u8) = .empty;
            try bytes.appendSlice(self.gpa, std.mem.asBytes(&handle));
            for (sc.names.values()) |entry| {
                const v = entry.?;
                const l = try self.layoutOf(stripRef(v.T), at);
                try bytes.appendSlice(self.gpa, std.mem.asBytes(&typeKey(v.T)));
                try bytes.appendSlice(self.gpa, v.mem[0..l.size]);
            }
            if (self.type_calls.get(bytes.items)) |v| return v;
            key = bytes.items;
        }
        // a function giving a type, or a @comptime(T), runs at compile time
        // a body building syntax runs at compile time too; what it builds
        // runs where it's used
        const builds_syntax = (ret.raw == .ast or ret.raw == .inlineast) and !self.isPtr(ret);
        const at_ct = key != null or volatile_type or builds_syntax or comptimeResult(ret);
        const result = if (at_ct) try self.atCompileTime(evalIn, .{ self, &.{f.body}, sc }) else try self.evalIn(&.{f.body}, sc);
        if (key) |k| {
            const v = try self.convert(result, ret, f.body);
            try self.type_calls.put(self.gpa, k, v);
            return v;
        }
        return switch (ret.raw) {
            // the syntax returned is run in place of the call
            .inlineast => {
                const code = try self.asAst(result, f.body);
                if (outline) return self.astValue(code);
                // the expansion is at the call site, except what the caller
                // wrote into it
                const saved = self.macro_src;
                defer self.macro_src = saved;
                if (firstRef(f.body)) |r| self.macro_src = r.src;
                return self.eval(code, caller);
            },
            .any, .ast => result,
            else => if (ret.decorators.@"&") result else self.convert(result, ret, f.body),
        };
    }

    /// `v as T` where T is @any(), maybe decorated; a parameter of that type
    /// binds its argument the same way. The decorators must match v's.
    /// @refT(@any()) gives the place itself; any other @any() a copy of the
    /// value, with v's own type.
    fn asAny(self: *Eval, v: Value, T: Type, at: Ast) Error!Value {
        if (!self.anyMatches(T, v.T))
            return self.fail(at, "{f} doesn't match {f}", .{ self.typeName(v.T), self.typeName(T) });
        if (T.decorators.@"&") return v;
        return self.copy(v, at);
    }

    /// Whether an argument of type A fits a parameter that is @any() with
    /// decorators: the reference bit must match, and the parameter's
    /// decoration levels must be A's outermost ones. Qualifiers written on
    /// the `any` level must match A's exactly; none written means any.
    fn anyMatches(self: *Eval, P: Type, A: Type) bool {
        if (P.decorators.@"&" and !A.decorators.@"&") return false;
        const pc = self.chain(P);
        const ac = self.chain(A);
        // P is: the any level's qualifiers, then its pointer levels
        const star = std.mem.indexOfScalar(Decor, pc, .@"*") orelse pc.len;
        const quals = pc[0..star];
        const levels = pc[star..];
        if (!std.mem.endsWith(Decor, ac, levels)) return false;
        if (quals.len == 0) return true;
        // A's level that the any stands for: after its last `*` before the levels
        const rest = ac[0 .. ac.len - levels.len];
        const start = if (std.mem.lastIndexOfScalar(Decor, rest, .@"*")) |i| i + 1 else 0;
        return std.mem.eql(Decor, rest[start..], quals);
    }

    /// a.b: a field of a value, or a member of a type's namespace; a field of
    /// a place is a place. With `method`, b is looked up in a's type.
    fn member(self: *Eval, obj: Value, name_ast: Ast, at: Ast, method: bool) Error!Value {
        const name = headText(name_ast) orelse return self.fail(name_ast, "expected a member name", .{});
        const vt = stripRef(obj.T);
        const owner: Type = if (vt.raw == .type and !method) get(Type, obj) else vt;
        const members = self.structMembers(owner) orelse
            return self.fail(at, "{f} has no members", .{self.typeName(owner)});
        for (members, 0..) |m, i| {
            if (!std.mem.eql(u8, m.name, name)) continue;
            if (m.type.decorators.@"comptime") return .{ .T = m.type, .mem = @constCast(m.value) };
            if (owner.raw != vt.raw or vt.raw == .type)
                return self.fail(at, "`{s}` is a field; it needs a value of {f}", .{ name, self.typeName(owner) });
            var T = m.type;
            T.decorators.@"&" = obj.T.decorators.@"&";
            const off = try self.fieldOffset(members, i, at);
            if (self.isRt(obj)) {
                // the field's pointer is the struct's plus the offset
                const base = if (obj.T.decorators.@"&") try self.ownReg(obj, at) else blk: {
                    const p = try self.newReg(try self.ptrTo(vt));
                    try self.emit(.{ .ldp = .{ .l = try self.ownReg(obj, at), .d = p } });
                    break :blk p;
                };
                const fp = try self.newReg(try self.ptrTo(m.type));
                try self.emit(.{ .math = .{ .op = .ADD, .l = base, .r = try self.offsetReg(off, at), .d = fp } });
                var place = m.type;
                place.decorators.@"&" = true;
                const pv = try self.rtValue(place, fp);
                return if (obj.T.decorators.@"&") pv else self.use(pv, at);
            }
            return .{ .T = T, .mem = obj.mem + off };
        }
        return self.fail(at, "{f} has no member `{s}`", .{ self.typeName(owner), name });
    }

    // --------------------------------------------------------------- builtins

    fn arity(self: *Eval, args: []const Ast, n: usize, b: Builtin, at: Ast) Error!void {
        if (args.len != n) return self.fail(at, "{s} takes {d} argument(s), found {d}", .{ builtinName(b), n, args.len });
    }

    fn builtinName(b: Builtin) []const u8 {
        return @tagName(b);
    }

    fn typeArg(self: *Eval, a: Ast, scope: *Scope) Error!Type {
        return self.asType(try self.eval(a, scope), a);
    }

    fn builtin(self: *Eval, b: Builtin, args: []const Ast, at: Ast, scope: *Scope) Error!Value {
        switch (b) {
            // types
            .void, .bool, .type, .ast, .inlineast, .any, .int, .schar, .sshort, .sint, .slong, .slonglong, .uchar, .ushort, .uint, .ulong, .ulonglong => {
                try self.arity(args, 0, b, at);
                return self.typeValue(mk(std.meta.stringToEnum(TypeIdx, @tagName(b)).?));
            },
            .ptr => {
                try self.arity(args, 1, b, at);
                return self.typeValue(try self.ptrTo(try self.typeArg(args[0], scope)));
            },
            .refT => {
                try self.arity(args, 1, b, at);
                var T = try self.typeArg(args[0], scope);
                if (T.decorators.@"&") return self.fail(at, "a reference can't be to a reference", .{});
                T.decorators.@"&" = true;
                return self.typeValue(T);
            },
            .@"const", .@"volatile" => {
                try self.arity(args, 1, b, at);
                return self.typeValue(try self.appendDecor(try self.typeArg(args[0], scope), if (b == .@"const") .@"const" else .@"volatile"));
            },
            .@"comptime" => {
                try self.arity(args, 1, b, at);
                var T = try self.typeArg(args[0], scope);
                T.decorators.@"comptime" = true;
                return self.typeValue(T);
            },
            .arr => {
                try self.arity(args, 2, b, at);
                const n = try self.asUsize(try self.eval(args[0], scope), args[0]);
                return self.typeValue(try self.arrayOf(n, try self.typeArg(args[1], scope)));
            },
            .@"struct" => return self.makeStruct(args, at, scope),
            .this => {
                try self.arity(args, 0, b, at);
                var s: ?*Scope = scope;
                while (s) |sc| : (s = sc.parent) if (sc.this) |idx| return self.typeValue(mk(idx));
                return self.fail(at, "@this() outside a @struct", .{});
            },
            .@"fn" => return self.makeFn(args, at, scope),
            .fnptr => {
                // @fnptr[[T, U], R]: runtime types only; @comptime is stripped
                try self.arity(args, 2, b, at);
                const plist = args[0];
                if (plist != .call or plist.call.len == 0 or !isListHead(plist.call[0]))
                    return self.fail(plist, "@fnptr's parameters are a list of types", .{});
                var sig: std.ArrayList(Type) = .empty;
                for (plist.call[1..]) |p| {
                    var T = try self.passType(try self.typeArg(p, scope));
                    T.decorators.@"comptime" = false;
                    if (!isRuntimeType(T)) return self.fail(p, "{f} isn't a runtime type", .{self.typeName(T)});
                    try sig.append(self.gpa, T);
                }
                var R = try self.passType(try self.typeArg(args[1], scope));
                R.decorators.@"comptime" = false;
                if (!isRuntimeType(R)) return self.fail(args[1], "{f} isn't a runtime type", .{self.typeName(R)});
                try sig.append(self.gpa, R);
                return self.typeValue(try self.fnPtrType(sig.items));
            },
            .opaqueType => {
                // @opaqueType("FILE"): the C type by that name
                try self.arity(args, 1, b, at);
                const name = try self.asString(try self.eval(args[0], scope), args[0]);
                const gop = try self.opaque_types.getOrPut(self.gpa, name);
                if (!gop.found_existing) {
                    gop.key_ptr.* = try self.gpa.dupe(u8, name);
                    gop.value_ptr.* = try self.types.add(self.gpa, &self.decors, .{ .@"opaque" = name });
                }
                return self.typeValue(mk(gop.value_ptr.*));
            },
            .returntype => {
                try self.arity(args, 0, b, at);
                var s: ?*Scope = scope;
                while (s) |sc| : (s = sc.parent) if (sc.ret) |T| return self.typeValue(T);
                return self.fail(at, "@returntype() outside a function", .{});
            },

            // control flow
            .@"if" => {
                if (args.len != 2 and args.len != 3) return self.fail(at, "@if takes 2 or 3 arguments", .{});
                const c = try self.eval(args[0], scope);
                if (self.isRt(c)) return self.rtIf(c, args, at, scope);
                if (try self.asBool(c, args[0])) return self.eval(args[1], scope);
                return if (args.len == 3) self.eval(args[2], scope) else self.voidValue();
            },
            .loop => {
                try self.arity(args, 1, b, at);
                if (self.rt != null) return self.lowerLoop(args[0], at, scope);
                while (true) {
                    const v = try self.eval(args[0], scope);
                    if (!self.repeat) return v;
                    self.repeat = false;
                }
            },
            .repeat => {
                try self.arity(args, 0, b, at);
                // under a runtime branch the next pass is decided at runtime
                if (self.rt != null and self.loops.items.len != 0) {
                    const loop = &self.loops.items[self.loops.items.len - 1];
                    if (self.rt_branch > loop.branch) {
                        loop.runtime = true;
                        try self.emit(.repeat);
                        return self.voidValue();
                    }
                }
                self.repeat = true;
                return self.voidValue();
            },
            .@"defer" => {
                try self.arity(args, 1, b, at);
                try scope.defers.append(self.gpa, args[0]);
                return self.voidValue();
            },
            .yield => {
                try self.arity(args, 0, b, at);
                var s: ?*Scope = scope;
                while (s) |sc| : (s = sc.parent) if (sc.yielded) |v| return v;
                return self.fail(at, "@yield() outside deferred code", .{});
            },

            // places
            .where => {
                try self.arity(args, 1, b, at);
                // the address of the value; a reference already is one, so for
                // a reference it's that address as a pointer
                const v = try self.eval(args[0], scope);
                const P = try self.ptrTo(v.T);
                if (self.isRt(v)) {
                    if (v.T.decorators.@"&") return self.rtValue(P, try self.ownReg(v, at));
                    const p = try self.newReg(P);
                    try self.emit(.{ .ldp = .{ .l = try self.ownReg(v, at), .d = p } });
                    return self.rtValue(P, p);
                }
                // a known value of a runtime type gets storage of its own while lowering
                if (self.rt != null and isRuntimeType(stripRef(v.T))) {
                    const r = try self.romReg(load(v), at);
                    const p = try self.newReg(P);
                    try self.emit(.{ .ldp = .{ .l = r, .d = p } });
                    return self.rtValue(P, p);
                }
                return self.valueOf(usize, P, @intFromPtr(v.mem));
            },
            .at => {
                try self.arity(args, 1, b, at);
                const p = try self.use(try self.eval(args[0], scope), at);
                if (!self.isPtr(p.T)) return self.fail(at, "@at needs a pointer, found {f}", .{self.typeName(p.T)});
                if (self.isRt(p)) {
                    var T = try self.pointee(p.T);
                    T.decorators.@"&" = true;
                    return self.rtValue(T, try self.ownReg(p, at));
                }
                const addr = get(usize, p);
                if (addr == 0) return self.fail(at, "@at of a null pointer", .{});
                var T = try self.pointee(p.T);
                T.decorators.@"&" = true;
                return .{ .T = T, .mem = @ptrFromInt(addr) };
            },
            .ref => {
                try self.arity(args, 1, b, at);
                const v = try self.eval(args[0], scope);
                if (v.T.decorators.@"&") return v;
                var c = try self.copy(v, at);
                c.T.decorators.@"&" = true;
                return c;
            },
            .stackptr, .comptime_alloc => {
                try self.arity(args, 1, b, at);
                const T = try self.typeArg(args[0], scope);
                // runtime storage for a runtime type while lowering
                if (self.rt != null and b == .stackptr and try self.holdsRuntime(T)) {
                    const s = try self.newReg(T);
                    try self.emit(.{ .mov = .{ .kind = .VV, .off = try self.offsetReg(0, at), .l = try self.romReg(try self.zero(T, at), at), .r = s } });
                    const P = try self.ptrTo(T);
                    const p = try self.newReg(P);
                    try self.emit(.{ .ldp = .{ .l = s, .d = p } });
                    return self.rtValue(P, p);
                }
                const storage = try self.zero(T, at);
                var P = try self.ptrTo(T);
                P.decorators.@"comptime" = b == .comptime_alloc;
                return self.valueOf(usize, P, @intFromPtr(storage.mem));
            },
            .comptime_free => {
                try self.arity(args, 1, b, at);
                _ = try self.eval(args[0], scope);
                return self.voidValue();
            },
            .zero => {
                try self.arity(args, 1, b, at);
                return self.zero(try self.typeArg(args[0], scope), at);
            },

            // ast metaprogramming
            .len => {
                try self.arity(args, 1, b, at);
                const v = try self.eval(args[0], scope);
                const T = stripRef(v.T);
                if (T.raw == .ast or T.raw == .inlineast) {
                    const a = get(Ast, v);
                    return self.smallBig(if (a == .call) a.call.len else 0);
                }
                if (self.arrEntry(T)) |arr| return self.smallBig(arr.len);
                if (T.raw == .type) if (self.structMembers(get(Type, v))) |m| return self.smallBig(m.len);
                return self.fail(at, "@len of {f}", .{self.typeName(v.T)});
            },
            .get => {
                if (args.len != 2 and args.len != 3) return self.fail(at, "@get takes 2 or 3 arguments", .{});
                const x = try self.eval(args[0], scope);
                if (self.arrEntry(stripRef(x.T))) |arr| {
                    if (args.len != 2) return self.fail(at, "@get of an array takes one index", .{});
                    return self.arrayGet(x, arr, args[1], at, scope);
                }
                const a = try self.asAst(x, args[0]);
                const items: []const Ast = if (a == .call) a.call else &.{};
                const i = try self.asUsize(try self.eval(args[1], scope), args[1]);
                if (args.len == 2) return self.astValue(if (i < items.len) items[i] else .{ .nil = firstRef(a) orelse undefined });
                const j = try self.asUsize(try self.eval(args[2], scope), args[2]);
                const lo = @min(i, j);
                const hi = @min(@max(i, j), items.len);
                const slice = try self.gpa.dupe(Ast, items[@min(lo, items.len)..hi]);
                if (i > j) std.mem.reverse(Ast, slice);
                return self.astValue(.{ .call = slice });
            },
            .ast_stringeq => {
                try self.arity(args, 2, b, at);
                const a = try self.asAst(try self.eval(args[0], scope), args[0]);
                const s = try self.asString(try self.eval(args[1], scope), args[1]);
                const text: ?[]const u8 = switch (a) {
                    .id, .num, .str => |r| r.gets(),
                    else => null,
                };
                return self.boolValue(text != null and std.mem.eql(u8, text.?, s), true);
            },
            // the text of an ast: an atom's own text, a call as (f a b)
            .ast_string => {
                try self.arity(args, 1, b, at);
                const a = try self.asAst(try self.eval(args[0], scope), args[0]);
                return switch (a) {
                    .id, .num, .str => |r| self.stringValue(r.gets()),
                    else => self.stringValue(try std.fmt.allocPrint(self.gpa, "{f}", .{a})),
                };
            },
            .gensym => {
                if (args.len > 1) return self.fail(at, "@gensym takes at most 1 argument", .{});
                const prefix = if (args.len == 1) headText(args[0]) orelse return self.fail(args[0], "@gensym's prefix is a bare name", .{}) else "g";
                self.gensyms += 1;
                return self.astValue(.{ .id = try self.synth(try std.fmt.allocPrint(self.gpa, "{s}__{d}", .{ prefix, self.gensyms })) });
            },
            .id => {
                try self.arity(args, 1, b, at);
                return self.astValue(.{ .id = try self.synth(try self.asString(try self.eval(args[0], scope), args[0])) });
            },
            .compileError => {
                try self.arity(args, 1, b, at);
                const msg = try self.asString(try self.eval(args[0], scope), args[0]);
                return self.fail(at, "{s}", .{msg});
            },
            .compiles => {
                try self.arity(args, 1, b, at);
                const saved = self.diag;
                // whether it works; what it lowers is dropped either way
                const ok = if (self.evalForType(args[0], scope)) |_| true else |e| switch (e) {
                    error.CompileError => false,
                    else => return e,
                };
                self.diag = saved;
                return self.boolValue(ok, true);
            },
            .log => {
                try self.arity(args, 1, b, at);
                const v = try self.eval(args[0], scope);
                std.debug.print("{f}: {f}\n", .{ self.fmtValue(v), self.typeName(v.T) });
                return v;
            },
            .outlineast => {
                try self.arity(args, 1, b, at);
                const c = args[0];
                if (c != .call or c.call.len == 0) return self.astValue(c);
                const f = try self.eval(c.call[0], scope);
                var call_args: std.ArrayList(Arg) = .empty;
                for (c.call[1..]) |a| try call_args.append(self.gpa, .{ .ast = a });
                return self.apply(f, call_args.items, c, scope, true);
            },

            // reflection and layout
            .typeof => {
                try self.arity(args, 1, b, at);
                // the type a variable would take: a value known at compile time
                // doesn't make it @comptime, unless it always is (@int() ...)
                var T = try self.typeOf((try self.evalForType(args[0], scope)).T);
                T.decorators.@"comptime" = mk(T.raw).decorators.@"comptime";
                return self.typeValue(T);
            },
            .sizeof, .alignof => {
                try self.arity(args, 1, b, at);
                const l = try self.layoutOf(try self.typeArg(args[0], scope), at);
                return self.smallBig(if (b == .sizeof) l.size else l.alignment);
            },
            .isptr => {
                try self.arity(args, 1, b, at);
                return self.boolValue(self.isPtr((try self.eval(args[0], scope)).T), true);
            },
            .isreferance => {
                try self.arity(args, 1, b, at);
                return self.boolValue((try self.eval(args[0], scope)).T.decorators.@"&", true);
            },
            .iscomptime => {
                try self.arity(args, 1, b, at);
                return self.boolValue((try self.eval(args[0], scope)).T.decorators.@"comptime", true);
            },
            .isconst, .isvolatile => {
                try self.arity(args, 1, b, at);
                const c = self.chain((try self.eval(args[0], scope)).T);
                const top = if (std.mem.lastIndexOfScalar(Decor, c, .@"*")) |i| c[i + 1 ..] else c;
                return self.boolValue(std.mem.indexOfScalar(Decor, top, if (b == .isconst) .@"const" else .@"volatile") != null, true);
            },
            .apply => {
                // f applied to each item of x's list, keeping its head
                try self.arity(args, 2, b, at);
                const f = try self.eval(args[0], scope);
                const x = try self.asAst(try self.eval(args[1], scope), args[1]);
                if (x != .call or x.call.len == 0) return self.fail(args[1], "@apply needs a list", .{});
                const out = try self.gpa.alloc(Ast, x.call.len);
                out[0] = x.call[0];
                for (x.call[1..], out[1..]) |item, *o| {
                    const v = try self.apply(f, &.{.{ .ast = item, .value = try self.astValue(item) }}, at, scope, true);
                    o.* = try self.toAst(v, at);
                }
                return self.astValue(.{ .call = out });
            },
            .offsetof => {
                try self.arity(args, 2, b, at);
                const T = try self.typeArg(args[0], scope);
                const name = headText(args[1]) orelse return self.fail(args[1], "@offsetof needs a field name", .{});
                const members = self.structMembers(T) orelse return self.fail(at, "{f} isn't a struct", .{self.typeName(T)});
                for (members, 0..) |m, i| if (std.mem.eql(u8, m.name, name)) {
                    if (m.type.decorators.@"comptime") return self.fail(args[1], "`{s}` is in the namespace, not a field", .{name});
                    return self.smallBig(try self.fieldOffset(members, i, at));
                };
                return self.fail(args[1], "{f} has no field `{s}`", .{ self.typeName(T), name });
            },
            .membertype => {
                try self.arity(args, 1, b, at);
                const T = try self.typeArg(args[0], scope);
                if (self.isPtr(T)) return self.typeValue(try self.pointee(T));
                if (self.arrEntry(T)) |a| return self.typeValue(a.T);
                return self.fail(at, "{f} is neither an array nor a pointer", .{self.typeName(T)});
            },
            .fieldtype => {
                try self.arity(args, 2, b, at);
                const xv = try self.evalForType(args[0], scope);
                const T = if (stripRef(xv.T).raw == .type and !self.isRt(xv)) get(Type, xv) else try self.typeOf(xv.T);
                const i = try self.asUsize(try self.eval(args[1], scope), args[1]);
                if (self.fnEntry(T)) |sig| {
                    if (i >= sig.len) return self.fail(at, "{f} has {d} parameter(s) and a return type", .{ self.typeName(T), sig.len - 1 });
                    return self.typeValue(sig[i]);
                }
                const members = self.structMembers(T) orelse return self.fail(at, "{f} isn't a struct or a function", .{self.typeName(T)});
                if (i >= members.len) return self.fail(at, "{f} has {d} members", .{ self.typeName(T), members.len });
                var MT = members[i].type;
                MT.decorators.@"comptime" = mk(MT.raw).decorators.@"comptime";
                return self.typeValue(MT);
            },
            .fieldval => {
                try self.arity(args, 2, b, at);
                const x = try self.eval(args[0], scope);
                const i = try self.asUsize(try self.eval(args[1], scope), args[1]);
                const vt = stripRef(x.T);
                const owner = if (vt.raw == .type and !self.isRt(x)) get(Type, x) else vt;
                const members = self.structMembers(owner) orelse return self.fail(at, "{f} isn't a struct", .{self.typeName(owner)});
                if (i >= members.len) return self.fail(at, "{f} has {d} members", .{ self.typeName(owner), members.len });
                return self.member(x, .{ .id = try self.synth(members[i].name) }, at, false);
            },
            .fieldname => {
                try self.arity(args, 2, b, at);
                const T = try self.typeArg(args[0], scope);
                const members = self.structMembers(T) orelse return self.fail(at, "{f} isn't a struct", .{self.typeName(T)});
                const i = try self.asUsize(try self.eval(args[1], scope), args[1]);
                if (i >= members.len) return self.fail(at, "{f} has {d} members", .{ self.typeName(T), members.len });
                return self.astValue(.{ .id = try self.synth(members[i].name) });
            },

            // modules
            .bind => {
                try self.arity(args, 2, b, at);
                const name = headText(args[0]) orelse return self.fail(args[0], "@bind needs a name", .{});
                const v = try self.eval(args[1], scope);
                try self.bindNew(scope, name, v, args[0]);
                try self.nameReg(name, v);
                return v;
            },
            .unbind => {
                try self.arity(args, 1, b, at);
                const name = headText(args[0]) orelse return self.fail(args[0], "@unbind needs a name", .{});
                try scope.names.put(self.gpa, name, null);
                return self.voidValue();
            },
            .using => {
                try self.arity(args, 1, b, at);
                const T = try self.typeArg(args[0], scope);
                const members = self.structMembers(T) orelse return self.fail(at, "@using needs a struct, found {f}", .{self.typeName(T)});
                for (members) |m| if (m.type.decorators.@"comptime")
                    try self.bindNew(scope, m.name, .{ .T = m.type, .mem = @constCast(m.value) }, at);
                return self.voidValue();
            },
            .path => {
                const here: []const u8 = blk: {
                    const r = firstRef(at) orelse break :blk ".";
                    break :blk switch (r.src.*) {
                        .disk => |d| d.filename,
                        .memory => ".",
                    };
                };
                if (args.len == 0) return self.stringValue(here);
                try self.arity(args, 1, b, at);
                const p = try self.asString(try self.eval(args[0], scope), args[0]);
                if (std.fs.path.isAbsolute(p)) return self.stringValue(p);
                const dir = std.fs.path.dirname(here) orelse ".";
                return self.stringValue(try std.fs.path.join(self.gpa, &.{ dir, p }));
            },
            .import => {
                try self.arity(args, 1, b, at);
                return self.importFile(try self.asString(try self.eval(args[0], scope), args[0]), at);
            },

            // operators
            .@"+", .@"-", .@"*", .@"/", .@"%", .@"<=>", .band, .bor, .bxor, .shl, .shr, .@"<", .@">", .@"<=", .@">=" => {
                try self.arity(args, 2, b, at);
                return self.intOp(b, try self.use(try self.eval(args[0], scope), at), try self.use(try self.eval(args[1], scope), at), at);
            },
            .@"==", .@"!=" => {
                try self.arity(args, 2, b, at);
                const l = try self.use(try self.eval(args[0], scope), at);
                const r = try self.use(try self.eval(args[1], scope), at);
                if (self.isPtr(l.T) and self.isPtr(r.T)) {
                    if (!typeEql(stripRef(l.T), stripRef(r.T)))
                        return self.fail(at, "{f} and {f} are different pointer types", .{ self.typeName(l.T), self.typeName(r.T) });
                    if (self.isRt(l) or self.isRt(r)) {
                        const d = try self.newReg(runtimeBool());
                        try self.emit(.{ .math = .{ .op = mathKind(b), .l = try self.toReg(l, at), .r = try self.toReg(r, at), .d = d } });
                        return self.rtValue(runtimeBool(), d);
                    }
                    const same = get(usize, l) == get(usize, r);
                    return self.boolValue(if (b == .@"==") same else !same, true);
                }
                if (self.isRt(l) or self.isRt(r)) {
                    if (stripRef(l.T).raw == .bool) return self.rtBoolOp(b, l, r, at);
                    return self.rtIntOp(b, l, r, at);
                }
                const eq = try self.equal(l, r, at);
                return self.boolValue(if (b == .@"==") eq else !eq, l.T.decorators.@"comptime" and r.T.decorators.@"comptime");
            },
            .@"and", .@"or" => {
                try self.arity(args, 2, b, at);
                // both sides always run; short circuiting is a macro over @if
                const lv = try self.eval(args[0], scope);
                const rv = try self.eval(args[1], scope);
                if (self.isRt(lv) or self.isRt(rv)) return self.rtBoolOp(b, try self.use(lv, args[0]), try self.use(rv, args[1]), at);
                const l = try self.asBool(lv, args[0]);
                const r = try self.asBool(rv, args[1]);
                return self.boolValue(if (b == .@"and") l and r else l or r, true);
            },
            .xor => {
                try self.arity(args, 2, b, at);
                const lv = try self.eval(args[0], scope);
                const rv = try self.eval(args[1], scope);
                if (self.isRt(lv) or self.isRt(rv)) return self.rtBoolOp(.xor, lv, rv, at);
                return self.boolValue(try self.asBool(lv, args[0]) != try self.asBool(rv, args[1]), true);
            },
            .as => {
                try self.arity(args, 2, b, at);
                const v = try self.eval(args[0], scope);
                const T = try self.typeArg(args[1], scope);
                if (T.raw == .any) return self.asAny(v, T, at);
                return self.convert(v, T, at);
            },
            .@"=" => {
                try self.arity(args, 2, b, at);
                const place = try self.eval(args[0], scope);
                if (!place.T.decorators.@"&") return self.fail(args[0], "can only assign to a place", .{});
                const T = stripRef(place.T);
                const v = try self.convert(try self.eval(args[1], scope), T, args[1]);
                if (self.isRt(place)) {
                    try self.emit(.{ .mov = .{ .kind = .VP, .off = try self.offsetReg(0, at), .l = try self.toReg(v, args[1]), .r = try self.ownReg(place, args[0]) } });
                    return place;
                }
                if (self.isRt(v)) return self.fail(args[1], "a runtime value can't be stored in compile-time storage", .{});
                const l = try self.layoutOf(T, at);
                @memcpy(place.mem[0..l.size], v.mem[0..l.size]);
                return place;
            },
            .@".", .@":" => {
                try self.arity(args, 2, b, at);
                return self.member(try self.eval(args[0], scope), args[1], at, b == .@":");
            },
            // left |> body: body in a new scope, with left bound to _; a
            // place stays a place
            .@"|>" => {
                try self.arity(args, 2, b, at);
                const v = try self.eval(args[0], scope);
                const child = try self.gpa.create(Scope);
                child.* = .{ .parent = scope };
                try child.names.put(self.gpa, "_", v);
                return self.evalIn(args[1..2], child);
            },
            // #include in the C output; only at the top level
            .cinclude => {
                try self.arity(args, 1, b, at);
                const h = try self.asString(try self.eval(args[0], scope), args[0]);
                var s: ?*const Scope = scope;
                while (s) |sc| : (s = sc.parent)
                    if (sc.ret != null) return self.fail(at, "@cinclude is only allowed at the top level", .{});
                if (self.rt != null) try self.module.includes.put(self.gpa, h, {});
                return self.voidValue();
            },
            // @cexpr[T, "c"]: C text as a value of T; with @void() a statement
            .cexpr => {
                try self.arity(args, 2, b, at);
                const T = try self.typeArg(args[0], scope);
                const text = try self.asString(try self.eval(args[1], scope), args[1]);
                if (self.rt == null) return self.fail(at, "@cexpr only exists in the C output; it can't run at compile time", .{});
                if (!isRuntimeType(T)) return self.fail(args[0], "{f} isn't a runtime type", .{self.typeName(T)});
                const d = try self.newReg(T);
                try self.emit(.{ .cexpr = .{ .d = d, .text = text } });
                if (T.raw == .void and !self.isPtr(T)) return self.voidValue();
                return self.rtValue(T, d);
            },
        }
    }

    /// Evaluates x for its type only: IR it emits is dropped.
    fn evalForType(self: *Eval, x: Ast, scope: *Scope) Error!Value {
        if (self.rt == null) return self.eval(x, scope);
        const f = self.func();
        const n = f.nodes.items.len;
        const saved_zero = f.zero;
        const v = self.eval(x, scope) catch |e| {
            self.func().nodes.shrinkRetainingCapacity(n);
            self.func().locs.shrinkRetainingCapacity(n);
            self.func().zero = saved_zero;
            return e;
        };
        self.func().nodes.shrinkRetainingCapacity(n);
        self.func().locs.shrinkRetainingCapacity(n);
        self.func().zero = saved_zero;
        return v;
    }

    /// Binds name in scope; a name is bound once per scope. Inner scopes can
    /// shadow it, and @unbind frees it to be bound again.
    fn bindNew(self: *Eval, scope: *Scope, name: []const u8, v: Value, at: Ast) Error!void {
        const gop = try scope.names.getOrPut(self.gpa, name);
        if (gop.found_existing and gop.value_ptr.* != null)
            return self.fail(at, "`{s}` is already bound in this scope", .{name});
        gop.value_ptr.* = v;
    }

    fn equal(self: *Eval, l: Value, r: Value, at: Ast) Error!bool {
        const lt = stripRef(l.T);
        const rt = stripRef(r.T);
        if (lt.raw == .type and rt.raw == .type) return typeEql(try self.typeOf(get(Type, l)), try self.typeOf(get(Type, r)));
        if (lt.raw == .bool and rt.raw == .bool) return get(bool, l) == get(bool, r);
        if (lt.raw == .builtin and rt.raw == .builtin) return get(Builtin, l) == get(Builtin, r);
        if ((lt.raw == .ast or lt.raw == .inlineast) and (rt.raw == .ast or rt.raw == .inlineast))
            return astEql(get(Ast, l), get(Ast, r));
        const v = try self.intOp(.@"==", l, r, at);
        return get(bool, v);
    }

    /// Same shape and same spelling; where the syntax came from doesn't matter.
    fn astEql(a: Ast, b: Ast) bool {
        if (@intFromEnum(a) != @intFromEnum(b)) return false;
        return switch (a) {
            .nil => true,
            .str, .num, .id => |r| std.mem.eql(u8, r.gets(), switch (b) {
                .str, .num, .id => |q| q.gets(),
                else => unreachable,
            }),
            .call => |items| items.len == b.call.len and for (items, b.call) |x, y| {
                if (!astEql(x, y)) break false;
            } else true,
        };
    }

    fn makeFn(self: *Eval, args: []const Ast, at: Ast, scope: *Scope) Error!Value {
        if (args.len != 3) return self.fail(at, "@fn takes [params], return type and body", .{});
        const plist = args[0];
        if (plist != .call or plist.call.len == 0 or !isListHead(plist.call[0]))
            return self.fail(plist, "@fn's parameters are a list: [x as T, ...]", .{});
        var params: std.ArrayList(Param) = .empty;
        var sig: std.ArrayList(Type) = .empty;
        for (plist.call[1..]) |p| {
            const ok = p == .call and p.call.len == 3 and headText(p.call[0]) != null and
                std.mem.eql(u8, headText(p.call[0]).?, "as") and p.call[1] == .id;
            if (!ok) return self.fail(p, "a parameter is `name as T`", .{});
            // a type naming an earlier parameter waits for the call
            const dependent = namesAny(p.call[2], params.items);
            const T = if (dependent) mk(.any) else try self.typeArg(p.call[2], scope);
            try params.append(self.gpa, .{ .name = p.call[1].id.gets(), .T = T, .T_ast = if (dependent) p.call[2] else null });
            try sig.append(self.gpa, T);
        }
        const ret_dependent = namesAny(args[1], params.items);
        const ret = if (ret_dependent) mk(.any) else try self.typeArg(args[1], scope);
        try sig.append(self.gpa, ret);
        var T = mk(try self.types.add(self.gpa, &self.decors, .{ .@"fn" = sig.items }));
        T.decorators.@"comptime" = true;
        const handle: u32 = @intCast(self.fns.items.len);
        const body = try self.fireUnquotes(args[2], scope);
        try self.fns.append(self.gpa, .{ .params = params.items, .ret = ret, .ret_ast = if (ret_dependent) args[1] else null, .body = body, .closure = scope });
        return self.valueOf(u32, T, handle);
    }

    /// Whether the syntax names one of the parameters.
    fn namesAny(node: Ast, params: []const Param) bool {
        switch (node) {
            .id => |id| {
                const t = id.gets();
                for (params) |p| if (std.mem.eql(u8, p.name, t)) return true;
                return false;
            },
            .call => |items| {
                for (items) |item| if (namesAny(item, params)) return true;
                return false;
            },
            else => return false,
        }
    }

    /// Unquotes written in a function's body fire when the function is
    /// defined, in the scope that defines it: their results are spliced in.
    /// A quote's unquotes are its own, and a nested @fn fires its own when
    /// it's defined, so neither is looked into.
    fn fireUnquotes(self: *Eval, node: Ast, scope: *Scope) Error!Ast {
        if (node != .call or node.call.len == 0) return node;
        const items = node.call;
        if (headText(items[0])) |t| {
            if (std.mem.eql(u8, t, "'") or std.mem.eql(u8, t, "@fn")) return node;
            if (std.mem.eql(u8, t, "`") and items.len == 2)
                return self.toAst(try self.eval(try self.quote(items[1], scope), scope), items[1]);
        }
        var out: ?[]Ast = null;
        for (items, 0..) |item, i| {
            const fired = try self.fireUnquotes(item, scope);
            if (out == null and !astSame(fired, item)) {
                out = try self.gpa.dupe(Ast, items);
            }
            if (out) |o| o[i] = fired;
        }
        return if (out) |o| .{ .call = o } else node;
    }

    fn astSame(a: Ast, b: Ast) bool {
        return switch (a) {
            .call => |x| b == .call and x.ptr == b.call.ptr and x.len == b.call.len,
            else => std.meta.eql(a, b),
        };
    }

    /// @struct{...}: runs the block; bindings to places (from <-) are the
    /// fields, in order, with their current values as initial values; the
    /// rest is the namespace.
    fn makeStruct(self: *Eval, args: []const Ast, at: Ast, scope: *Scope) Error!Value {
        if (args.len != 1) return self.fail(at, "@struct takes a block", .{});
        var block = args[0];
        // @struct `x builds it from the block x holds
        if (block == .call and block.call.len == 2 and headText(block.call[0]) != null and
            std.mem.eql(u8, headText(block.call[0]).?, "`"))
            block = try self.asAst(try self.eval(block.call[1], scope), block.call[1]);
        if (block != .call or block.call.len == 0 or !isBlockHead(block.call[0]))
            return self.fail(block, "@struct takes a block: @struct{{...}}, or @struct `x for the block x holds", .{});
        const saved = self.rt;
        self.rt = null;
        defer self.rt = saved;
        const idx = try self.types.reserve(self.gpa);
        const sc = try self.gpa.create(Scope);
        sc.* = .{ .parent = scope, .this = idx };
        // the entry is updated after each statement, so @this() can be used
        // with the fields declared so far
        for (block.call[1..]) |item| {
            _ = try self.eval(item, sc);
            try self.setStruct(idx, sc, at);
        }
        var i = sc.defers.items.len;
        while (i > 0) {
            i -= 1;
            _ = try self.eval(sc.defers.items[i], sc);
        }
        try self.setStruct(idx, sc, at);
        return self.typeValue(mk(idx));
    }

    fn setStruct(self: *Eval, idx: TypeIdx, sc: *Scope, at: Ast) Error!void {
        var members: std.ArrayList(types.TypeMap.StructMember) = .empty;
        for (sc.names.keys(), sc.names.values()) |name, entry| {
            const v = entry orelse continue;
            var T = v.T;
            if (T.decorators.@"&") {
                T = stripRef(T);
                T.decorators.@"comptime" = false;
            } else T.decorators.@"comptime" = true;
            const l = try self.layoutOf(T, at);
            const bytes = try self.gpa.alignedAlloc(u8, .@"16", @max(l.size, 1));
            @memcpy(bytes[0..l.size], v.mem[0..l.size]);
            try members.append(self.gpa, .{ .type = T, .value = bytes.ptr, .name = name });
        }
        try self.types.set(self.gpa, &self.decors, idx, .{ .@"struct" = members.items });
    }

    fn importFile(self: *Eval, path: []const u8, at: Ast) Error!Value {
        if (self.files.get(path)) |entry|
            return entry orelse self.fail(at, "{s} imports itself", .{path});
        try self.files.put(self.gpa, path, null);
        const v = try self.atCompileTime(evalFile, .{ self, path, @as(?Ast, at) });
        try self.files.put(self.gpa, path, v);
        return v;
    }

    /// Parses and runs a file in a fresh scope; its value is its last expression.
    pub fn evalFile(self: *Eval, path: []const u8, at: ?Ast) Error!Value {
        const file = try self.gpa.create(FileItem);
        file.* = FileItem.fromfileAlloc(self.gpa, self.io, try self.gpa.dupeSentinel(u8, path, 0)) catch |e| {
            self.diag = .{ .msg = try std.fmt.allocPrint(self.gpa, "can't read {s}: {s}", .{ path, @errorName(e) }), .at = if (at) |a| firstRef(a) else null };
            return error.CompileError;
        };
        var pdiag: parse.Diagnostic = .{};
        const tree = parse.parse(self.gpa, file, &pdiag) catch |e| switch (e) {
            error.SyntaxError => {
                self.diag = .{
                    .msg = if (pdiag.missing) try std.fmt.allocPrint(self.gpa, "syntax error: missing `{s}`", .{pdiag.kind}) else "syntax error",
                    .at = .{ .src = file, .off = pdiag.off, .len = pdiag.len },
                };
                return error.CompileError;
            },
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                self.diag = .{ .msg = try std.fmt.allocPrint(self.gpa, "can't parse {s}: {s}", .{ path, @errorName(e) }) };
                return error.CompileError;
            },
        };
        const sc = try self.gpa.create(Scope);
        sc.* = .{ .parent = self.root };
        return self.evalIn(tree.call[1..], sc);
    }

    // -------------------------------------------------------------- printing

    const TypeName = struct {
        e: *Eval,
        T: Type,
        pub fn format(self: TypeName, w: *std.Io.Writer) std.Io.Writer.Error!void {
            return self.e.writeType(w, self.T);
        }
    };

    pub fn typeName(self: *Eval, T: Type) TypeName {
        return .{ .e = self, .T = T };
    }

    fn writeType(self: *Eval, w: *std.Io.Writer, T: Type) std.Io.Writer.Error!void {
        const c = self.chain(T);
        if (T.decorators.@"&") try w.writeAll("@refT(");
        var i = c.len;
        while (i > 0) {
            i -= 1;
            try w.writeAll(switch (c[i]) {
                .@"const" => "@const(",
                .@"volatile" => "@volatile(",
                .@"*" => "@ptr(",
                .null => unreachable,
            });
        }
        if (@intFromEnum(T.raw) <= @intFromEnum(TypeIdx.builtin)) {
            try w.print("@{s}()", .{@tagName(T.raw)});
        } else switch (self.types.get(T.raw)) {
            .@"struct" => try w.print("@struct#{d}", .{@intFromEnum(T.raw)}),
            .@"opaque" => |name| try w.print("@opaqueType(\"{s}\")", .{name}),
            .arr => |a| {
                try w.print("@arr[{d}, ", .{a.len});
                try self.writeType(w, a.T);
                try w.writeAll("]");
            },
            .@"fn" => |sig| {
                try w.writeAll(if (T.decorators.@"comptime") "@fn[[" else "@fnptr[[");
                for (sig[0 .. sig.len - 1], 0..) |p, j| {
                    if (j != 0) try w.writeAll(", ");
                    try self.writeType(w, p);
                }
                try w.writeAll("], ");
                try self.writeType(w, sig[sig.len - 1]);
                try w.writeAll("]");
            },
        }
        for (c) |_| try w.writeAll(")");
        if (T.decorators.@"&") try w.writeAll(")");
    }

    const ValueFmt = struct {
        e: *Eval,
        v: Value,
        pub fn format(self: ValueFmt, w: *std.Io.Writer) std.Io.Writer.Error!void {
            return self.e.writeValue(w, self.v);
        }
    };

    pub fn fmtValue(self: *Eval, v: Value) ValueFmt {
        return .{ .e = self, .v = v };
    }

    fn writeValue(self: *Eval, w: *std.Io.Writer, value: Value) std.Io.Writer.Error!void {
        if (self.isRt(value)) return w.print("<runtime {f}>", .{self.typeName(value.T)});
        const v = load(value);
        const T = v.T;
        if (self.isPtr(T)) return w.print("0x{x}", .{get(usize, v)});
        if (cintOf(T.raw)) |kind| return w.print("{d}", .{readC(kind, v.mem)});
        switch (T.raw) {
            .void => return w.writeAll("void"),
            .bool => return w.writeAll(if (get(bool, v)) "true" else "false"),
            .int => return w.print("{f}", .{get(BigConst, v)}),
            .type => return self.writeType(w, get(Type, v)),
            .ast, .inlineast => return w.print("'{f}", .{get(Ast, v)}),
            .builtin => {
                const b = get(Builtin, v);
                return if (isOperator(b)) w.writeAll(@tagName(b)) else w.print("@{s}", .{@tagName(b)});
            },
            else => {},
        }
        if (@intFromEnum(T.raw) <= @intFromEnum(TypeIdx.builtin)) return w.writeAll("?");
        switch (self.types.get(T.raw)) {
            .@"fn" => return w.print("fn#{d}", .{get(u32, v)}),
            .@"opaque" => return w.writeAll("?"),
            .arr => |a| {
                if (a.T.raw == .schar or a.T.raw == .uchar) return w.print("\"{f}\"", .{std.zig.fmtString(v.mem[0..a.len])});
                const l = (a.T.layout(&self.decors, &self.types) catch return w.writeAll("[?]")).?;
                try w.writeAll("[");
                for (0..a.len) |i| {
                    if (i != 0) try w.writeAll(", ");
                    try self.writeValue(w, .{ .T = a.T, .mem = v.mem + i * l.size });
                }
                return w.writeAll("]");
            },
            .@"struct" => |members| {
                try w.writeAll("{");
                var first = true;
                for (members, 0..) |m, i| {
                    if (m.type.decorators.@"comptime") continue;
                    if (!first) try w.writeAll(", ");
                    first = false;
                    const off = self.fieldOffset(members, i, .{ .nil = undefined }) catch return w.writeAll("?}");
                    try w.print("{s} = ", .{m.name});
                    try self.writeValue(w, .{ .T = m.type, .mem = v.mem + off });
                }
                return w.writeAll("}");
            },
        }
    }
};
