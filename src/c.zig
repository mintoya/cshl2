//! Writes a lowered module as C: typedefs for the types registers use, the
//! rom bytes, one C function per lowered function with its registers as
//! locals, and a main that runs the file's top level and prints its value.
const std = @import("std");
const ir = @import("ir.zig");
const mod = @import("module.zig");
const types = @import("types.zig");
const Eval = @import("eval.zig").Eval;
const Type = types.Type;
const TypeIdx = types.TypeIdx;
const Decor = types.Decor;
const Reg = mod.Reg;
const SrcRef = @import("ast.zig").SrcRef;

pub const Error = error{ OutOfMemory, WriteFailed, Unsupported, CompileError };

const Emitter = struct {
    gpa: std.mem.Allocator,
    e: *Eval,
    decls: std.Io.Writer.Allocating,
    names: std.AutoHashMapUnmanaged(u64, []const u8) = .empty,
    count: u32 = 0,
    /// what Unsupported was about
    why: []const u8 = "",
    /// the cshl names of the current function's registers
    reg_names: ?*const std.AutoHashMapUnmanaged(Reg, []const u8) = null,
    /// each source file's line start offsets, by its FileItem's address
    line_starts: std.AutoHashMapUnmanaged(usize, []const u32) = .empty,

    fn key(T: Type) u64 {
        var t = T;
        t.decorators.@"comptime" = false;
        t.decorators.@"&" = false;
        return Eval.typeKey(t);
    }

    fn fresh(self: *Emitter) Error![]const u8 {
        self.count += 1;
        return std.fmt.allocPrint(self.gpa, "t{d}", .{self.count});
    }

    fn unsupported(self: *Emitter, comptime fmt: []const u8, args: anytype) Error {
        self.why = try std.fmt.allocPrint(self.gpa, fmt, args);
        return error.Unsupported;
    }

    /// The C name of T, declaring it first if it needs a declaration.
    fn cType(self: *Emitter, T: Type) Error![]const u8 {
        const k = key(T);
        if (self.names.get(k)) |n| return n;
        const w = &self.decls.writer;
        const c = self.e.chain(T);
        if (c.len != 0) {
            // the base type, then each decoration around it
            var name = try self.cType(try self.e.withChainPub(T, &.{}));
            for (c) |d| {
                const next = try self.fresh();
                switch (d) {
                    .@"const" => try w.print("typedef {s} const {s};\n", .{ name, next }),
                    .@"volatile" => try w.print("typedef {s} volatile {s};\n", .{ name, next }),
                    .@"*" => try w.print("typedef {s} *{s};\n", .{ name, next }),
                    .null => unreachable,
                }
                name = next;
            }
            try self.names.put(self.gpa, k, name);
            return name;
        }
        const builtin: ?[]const u8 = switch (T.raw) {
            .void => "void",
            .bool => "_Bool",
            .schar => "signed char",
            .uchar => "unsigned char",
            .sshort => "short",
            .ushort => "unsigned short",
            .sint => "int",
            .uint => "unsigned int",
            .slong => "long",
            .ulong => "unsigned long",
            .slonglong => "long long",
            .ulonglong => "unsigned long long",
            .int, .type, .ast, .inlineast, .any, .builtin => return self.unsupported("{f} only exists at compile time", .{self.e.typeName(T)}),
            _ => null,
        };
        if (builtin) |n| return n;
        const name = try self.fresh();
        switch (self.e.types.get(T.raw)) {
            .@"struct" => |members| {
                // declared before its fields, so pointers to it work inside it
                try w.print("typedef struct s_{s} {s};\n", .{ name, name });
                try self.names.put(self.gpa, k, name);
                var fields: std.ArrayList([]const u8) = .empty;
                for (members) |m| {
                    if (m.type.decorators.@"comptime") continue;
                    // a void field has no bytes, and C has no void fields;
                    // fields are reached by offset, so it can go
                    if (m.type.raw == .void and m.type.decorators.decor == 0) continue;
                    try fields.append(self.gpa, try self.cType(m.type));
                }
                try w.print("struct s_{s} {{", .{name});
                for (fields.items, 0..) |f, i| try w.print(" {s} m{d};", .{ f, i });
                if (fields.items.len == 0) try w.writeAll(" char empty;");
                try w.writeAll(" };\n");
                return name;
            },
            // a C type by its own name
            .@"opaque" => |c_name| {
                try self.names.put(self.gpa, k, c_name);
                return c_name;
            },
            .arr => |a| {
                const el = try self.cType(a.T);
                // v[0] for @arr[0, T]: a GNU C zero-length array, size 0 as
                // in the layout
                try w.print("typedef struct {{ {s} v[{d}]; }} {s};\n", .{ el, a.len, name });
            },
            .@"fn" => |sig| {
                var params: std.ArrayList([]const u8) = .empty;
                for (sig[0 .. sig.len - 1]) |p| try params.append(self.gpa, try self.cType(p));
                const ret = try self.cType(sig[sig.len - 1]);
                try w.print("typedef {s} (*{s})(", .{ ret, name });
                if (params.items.len == 0) try w.writeAll("void");
                for (params.items, 0..) |p, i| try w.print("{s}{s}", .{ if (i == 0) "" else ", ", p });
                try w.writeAll(");\n");
            },
        }
        try self.names.put(self.gpa, k, name);
        return name;
    }

    /// A register's own declaration has no outermost qualifiers: it holds a
    /// value, and has to be assigned to get one.
    fn declType(self: *Emitter, T: Type) Error!Type {
        const c = self.e.chain(T);
        const keep = if (std.mem.lastIndexOfScalar(Decor, c, .@"*")) |i| i + 1 else 0;
        return self.e.withChainPub(T, c[0..keep]);
    }

    fn isVoid(self: *Emitter, T: Type) bool {
        return T.raw == .void and !self.e.isPtr(T);
    }

    fn sameType(a: Type, b: Type) bool {
        return key(a) == key(b);
    }

    /// A register in C: rN, or for one bound to a name, the name made a C
    /// identifier with N after it. A name can be any bytes, so bytes outside
    /// [A-Za-z0-9_] are written _xHH, and a name not starting with a letter
    /// or _ gets v_ in front; N keeps them apart and off C's keywords.
    const RegName = struct {
        name: ?[]const u8,
        r: Reg,
        pub fn format(self: RegName, w: *std.Io.Writer) std.Io.Writer.Error!void {
            const name = self.name orelse return w.print("r{d}", .{self.r});
            if (name.len == 0 or !(std.ascii.isAlphabetic(name[0]) or name[0] == '_')) try w.writeAll("v_");
            for (name) |c| {
                if (std.ascii.isAlphanumeric(c) or c == '_') try w.writeByte(c) else try w.print("_x{x:0>2}", .{c});
            }
            try w.print("_{d}", .{self.r});
        }
    };

    fn reg(self: *const Emitter, r: Reg) RegName {
        return .{ .name = if (self.reg_names) |n| n.get(r) else null, .r = r };
    }

    fn function(self: *Emitter, w: *std.Io.Writer, idx: u32, f: *const mod.Func) Error!void {
        const regs = f.regs.items;
        self.reg_names = &f.reg_names;
        defer self.reg_names = null;
        const ret = if (f.result) |r| try self.cType(regs[r]) else "void";
        try w.print("static {s} f{d}(", .{ ret, idx });
        if (f.params.items.len == 0) try w.writeAll("void");
        for (f.params.items, 0..) |p, i| try w.print("{s}{s} a{d}", .{ if (i == 0) "" else ", ", try self.cType(regs[p]), i });
        try w.writeAll(") {\n");
        for (regs, 0..) |T, i| {
            if (self.isVoid(T)) continue;
            try w.print("  {s} {f};\n", .{ try self.cType(try self.declType(T)), self.reg(@intCast(i)) });
        }
        for (f.nodes.items, f.locs.items) |n, loc| {
            if (loc) |l| try self.line(w, l);
            try self.node(w, regs, n);
        }
        if (f.result) |r| try w.print("  return {f};\n", .{ self.reg(r) });
        try w.writeAll("}\n");
    }

    /// `#line N "file"` before the C for a node: debuggers then step, break
    /// and backtrace by the .cshl file. It's written before every node, since
    /// the lines after a #line count up from it.
    fn line(self: *Emitter, w: *std.Io.Writer, loc: SrcRef) Error!void {
        const d = loc.src.disk;
        const content = d.content;
        const gop = try self.line_starts.getOrPut(self.gpa, @intFromPtr(loc.src));
        if (!gop.found_existing) {
            var starts: std.ArrayList(u32) = .empty;
            try starts.append(self.gpa, 0);
            for (content, 0..) |c, i| if (c == '\n') try starts.append(self.gpa, @intCast(i + 1));
            gop.value_ptr.* = starts.items;
        }
        const starts = gop.value_ptr.*;
        // the last line start at or before off
        var lo: usize = 0;
        var hi: usize = starts.len;
        while (hi - lo > 1) {
            const mid = (lo + hi) / 2;
            if (starts[mid] <= loc.off) lo = mid else hi = mid;
        }
        const n: u32 = @intCast(lo + 1);
        try w.print("#line {d} \"", .{n});
        for (d.filename) |c| switch (c) {
            '"', '\\' => try w.print("\\{c}", .{c}),
            else => try w.writeByte(c),
        };
        try w.writeAll("\"\n");
    }

    fn node(self: *Emitter, w: *std.Io.Writer, regs: []const Type, n: ir.node) Error!void {
        const e = self.e;
        switch (n) {
            .mov => |m| switch (m.kind) {
                .VV => if (!self.isVoid(regs[m.r])) try w.print("  {f} = {f};\n", .{ self.reg(m.r), self.reg(m.l) }),
                // the register types say which side is the pointer
                .VP => {
                    const l = regs[m.l];
                    if (e.isPtr(l) and sameType(try e.pointeePub(l), regs[m.r]))
                        try w.print("  {f} = *({s} *)((char *){f} + {f});\n", .{ self.reg(m.r), try self.cType(regs[m.r]), self.reg(m.l), self.reg(m.off) })
                    else
                        try w.print("  *({s} *)((char *){f} + {f}) = {f};\n", .{ try self.cType(regs[m.l]), self.reg(m.r), self.reg(m.off), self.reg(m.l) });
                },
                .PP => try w.print("  memcpy((char *){f} + {f}, (char *){f} + {f}, sizeof *{f});\n", .{ self.reg(m.r), self.reg(m.off), self.reg(m.l), self.reg(m.off), self.reg(m.r) }),
            },
            .rom => |r| {
                if (self.e.module.func_addrs.get(r.off)) |f|
                    try w.print("  {f} = ({s})&f{d};\n", .{ self.reg(r.d), try self.cType(regs[r.d]), f })
                else if (!self.isVoid(regs[r.d]))
                    try w.print("  memcpy(&{f}, cshl_rom + {d}, sizeof {f});\n", .{ self.reg(r.d), r.off, self.reg(r.d) });
            },
            .math => |m| try self.math(w, regs, m.op, m.l, m.r, m.d),
            .cast => |c| try w.print("  {f} = ({s}){f};\n", .{ self.reg(c.d), try self.cType(regs[c.d]), self.reg(c.l) }),
            .call => |c| {
                try w.writeAll("  ");
                if (!self.isVoid(regs[c.d])) try w.print("{f} = ", .{ self.reg(c.d) });
                try w.print("{f}(", .{ self.reg(c.@"fn") });
                for (c.args, 0..) |a, i| try w.print("{s}{f}", .{ if (i == 0) "" else ", ", self.reg(a) });
                try w.writeAll(");\n");
            },
            .arg => |a| try w.print("  {f} = a{d};\n", .{ self.reg(a.d), a.idx }),
            .ldp => |p| try w.print("  {f} = &{f};\n", .{ self.reg(p.d), self.reg(p.l) }),
            .@"if" => |c| try w.print("  if ({f}) {{\n", .{ self.reg(c) }),
            .@"else" => try w.writeAll("  } else {\n"),
            .endif => try w.writeAll("  }\n"),
            .loop => try w.writeAll("  for (;;) {\n"),
            .repeat => try w.writeAll("  continue;\n"),
            .endloop => try w.writeAll("  break; }\n"),
            .cexpr => |c| if (self.isVoid(regs[c.d]))
                try w.print("  {s};\n", .{c.text})
            else
                try w.print("  {f} = ({s});\n", .{ self.reg(c.d), c.text }),
        }
    }

    fn math(self: *Emitter, w: *std.Io.Writer, regs: []const Type, op: ir.node.mathKind, l: Reg, r: Reg, d: Reg) Error!void {
        const T = try self.cType(regs[d]);
        if (self.e.isPtr(regs[d])) return switch (op) {
            .ADD => w.print("  {f} = ({s})((char *){f} + {f});\n", .{ self.reg(d), T, self.reg(l), self.reg(r) }),
            .SUB => w.print("  {f} = ({s})((char *){f} - {f});\n", .{ self.reg(d), T, self.reg(l), self.reg(r) }),
            else => self.unsupported("pointer {s}", .{@tagName(op)}),
        };
        const sym: []const u8 = switch (op) {
            // wrap, as the evaluator does; signed overflow isn't defined in C
            .ADD, .SUB, .MUL => return w.print("  {f} = ({s})((unsigned long long){f} {s} (unsigned long long){f});\n", .{ self.reg(d), T, self.reg(l), switch (op) {
                .ADD => "+",
                .SUB => "-",
                else => "*",
            }, self.reg(r) }),
            .CMP => return w.print("  {f} = ({f} > {f}) - ({f} < {f});\n", .{ self.reg(d), self.reg(l), self.reg(r), self.reg(l), self.reg(r) }),
            // a negative count shifts the other way; past the width it's 0
            .SHL, .SHR => return w.print(
                "  {{ long long n = {s}(long long){f}; {f} = (n >= (long long)(8 * sizeof {f}) || -n >= (long long)(8 * sizeof {f})) ? 0 : n >= 0 ? ({s})((unsigned long long){f} << n) : ({s})({f} >> -n); }}\n",
                .{ if (op == .SHR) "-" else "", self.reg(r), self.reg(d), self.reg(d), self.reg(d), T, self.reg(l), T, self.reg(l) },
            ),
            .DIV => "/",
            .MOD => "%",
            .EQ => "==",
            .NE => "!=",
            .LT => "<",
            .GT => ">",
            .LE => "<=",
            .GE => ">=",
            .AND => "&&",
            .OR => "||",
            .XOR => "!=",
            .BAND => "&",
            .BOR => "|",
            .BXOR => "^",
        };
        try w.print("  {f} = {f} {s} {f};\n", .{ self.reg(d), self.reg(l), sym, self.reg(r) });
    }
};

/// Writes the module e lowered as a C program. On error.Unsupported, `why`
/// says what couldn't be written.
pub fn write(gpa: std.mem.Allocator, e: *Eval, out: *std.Io.Writer, why: *[]const u8) Error!void {
    var em: Emitter = .{ .gpa = gpa, .e = e, .decls = .init(gpa) };
    errdefer why.* = em.why;
    var body: std.Io.Writer.Allocating = .init(gpa);
    const funcs = e.module.funcs.items;
    for (funcs, 0..) |*f, i| try em.function(&body.writer, @intCast(i), f);

    try out.writeAll("#include <stdio.h>\n#include <string.h>\n");
    // "<h>" as is, anything else in quotes
    for (e.module.includes.keys()) |h| {
        if (h.len > 0 and h[0] == '<') try out.print("#include {s}\n", .{h}) else try out.print("#include \"{s}\"\n", .{h});
    }
    try out.writeAll("\n");
    try out.writeAll(em.decls.written());
    const rom = e.module.rom.items;
    try out.print("\nstatic const unsigned char cshl_rom[{d}] = {{", .{@max(rom.len, 1)});
    for (rom, 0..) |byte, i| try out.print("{s}{d}", .{ if (i == 0) "" else ",", byte });
    if (rom.len == 0) try out.writeAll("0");
    try out.writeAll("};\n\n");
    for (funcs, 0..) |*f, i| {
        const ret = if (f.result) |r| try em.cType(f.regs.items[r]) else "void";
        try out.print("static {s} f{d}(", .{ ret, i });
        if (f.params.items.len == 0) try out.writeAll("void");
        for (f.params.items, 0..) |p, j| try out.print("{s}{s}", .{ if (j == 0) "" else ", ", try em.cType(f.regs.items[p]) });
        try out.writeAll(");\n");
    }
    try out.writeAll("\n");
    try out.writeAll(body.written());

    const main = e.module.main orelse return;
    const m = funcs[main];
    try out.writeAll("\nint main(void) {\n");
    if (m.result) |r| {
        const T = m.regs.items[r];
        try out.print("  {s} r = f{d}();\n", .{ try em.cType(T), main });
        if (T.raw == .bool and !e.isPtr(T))
            try out.writeAll("  puts(r ? \"true\" : \"false\");\n")
        else if (e.cintSigned(T)) |signed|
            try out.writeAll(if (signed) "  printf(\"%lld\\n\", (long long)r);\n" else "  printf(\"%llu\\n\", (unsigned long long)r);\n")
        else
            try out.writeAll("  (void)r;\n  puts(\"<value>\");\n");
    } else try out.print("  f{d}();\n  puts(\"void\");\n", .{main});
    try out.writeAll("  return 0;\n}\n");
}
