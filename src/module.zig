//! A lowered program: the runtime part of a file, as functions of IR nodes
//! over typed registers, plus the read-only bytes `rom` nodes read.
const std = @import("std");
const ir = @import("ir.zig");
const types = @import("types.zig");
const Type = types.Type;

pub const Reg = ir.node.Reg;

pub const Func = struct {
    nodes: std.ArrayList(ir.node) = .empty,
    /// the type of each register; registers are the function's locals
    regs: std.ArrayList(Type) = .empty,
    /// the registers `arg` nodes fill, in order
    params: std.ArrayList(Reg) = .empty,
    ret: Type,
    /// the register holding the function's value at the end; null for void
    result: ?Reg = null,
    /// a usize 0, for movs with no offset
    zero: ?Reg = null,
};

pub const Module = struct {
    funcs: std.ArrayList(Func) = .empty,
    /// read-only bytes, read with memcpy, so nothing in it is aligned
    rom: std.ArrayList(u8) = .empty,
    /// rom offsets that hold a lowered function's address instead of bytes
    func_addrs: std.AutoArrayHashMapUnmanaged(usize, u32) = .empty,
    /// the function the file's top level lowered into
    main: ?u32 = null,
    /// @cinclude headers, in order, each once
    includes: std.StringArrayHashMapUnmanaged(void) = .empty,

    /// Appends bytes to rom and returns their offset.
    pub fn addRom(self: *Module, gpa: std.mem.Allocator, bytes: []const u8) !usize {
        const off = self.rom.items.len;
        try self.rom.appendSlice(gpa, bytes);
        return off;
    }

    /// Reserves a pointer-sized rom slot holding function `f`'s address.
    pub fn addFuncAddr(self: *Module, gpa: std.mem.Allocator, f: u32) !usize {
        const zeros: [@sizeOf(usize)]u8 = @splat(0);
        const off = try self.addRom(gpa, &zeros);
        try self.func_addrs.put(gpa, off, f);
        return off;
    }
};
