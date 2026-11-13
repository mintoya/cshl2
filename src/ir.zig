const std = @import("std");
pub const c = @import("ir_c");
pub const CNodeUnion = c.Ir_node;
const Payload = @FieldType(CNodeUnion, "unnamed_0");

pub const NodeTag = enum(c._enum_Ir_node) {
    mov =
        c.Ir_mov_enum,
    rom =
        c.Ir_rom_enum,
    math =
        c.Ir_math_enum,
    cast =
        c.Ir_cast_enum,
    @"fn" =
        c.Ir_fn_enum,
    call =
        c.Ir_call_enum,
    arg =
        c.Ir_arg_enum,
    ret =
        c.Ir_ret_enum,
    ldp =
        c.Ir_ldp_enum,
    @"if" =
        c.Ir_if_enum,
    @"else" =
        c.Ir_else_enum,
    endif =
        c.Ir_endif_enum,
    loop =
        c.Ir_loop_enum,
    repeat =
        c.Ir_repeat_enum,
    endloop =
        c.Ir_endloop_enum,
    c =
        c.Ir_c_enum,
};

// Zig control-flow convenience; all payload layouts come from C.
pub const node = union(NodeTag) {
    pub const Reg = c.Reg;
    pub const mathKind = c.mathKind;
    pub const movKind = c.movKind;
    /// Copy size bytes from l to r; see movKind in ir.c for address/pointer modes.
    mov: c.Ir_mov,
    /// Read ROM at offset off into register d. There is no global RAM counterpart.
    rom: c.Ir_rom,
    /// Integer/pointer operation: d = l op r. Comparisons may change the result type.
    math: c.Ir_math,
    /// Cast l into d; integers and pointers only. TODO: define UB behavior.
    cast: c.Ir_cast,
    /// Call fn with argument registers args, terminated by maxInt(Reg); result goes into d.
    @"fn": c.Ir_fn,
    /// Begin the alternative branch of the current conditional.
    call: c.Ir_call,
    /// Load function argument idx into register d.
    arg: c.Ir_arg,
    /// Return the value in this register.
    ret: c.Reg,
    /// Take a register address: d = &l. Add an offset afterward to select an element.
    ldp: c.Ir_ldp,
    /// Begin a conditional on this register.
    @"if": c.Ir_if,
    /// Begin a conditional on this register.
    @"else": void,
    /// End the current conditional.
    endif: void,
    /// Begin a loop.
    loop: void,
    /// Repeat a loop; payload is the number of nesting levels to unwind minus one.
    repeat: c.Ir_repeat,
    /// End the current loop.
    endloop: void,
    /// Raw C source as pointer and byte length; no NUL terminator required.
    c: @import("ir_c").Ir_c,
    pub fn toc(value: @This()) CNodeUnion {
        var result: CNodeUnion = std.mem.zeroes(CNodeUnion);
        switch (value) {
            inline else => |payload, tag| {
                result.tag = @backingInt(tag);
                if (@TypeOf(payload) != void) {
                    result.unnamed_0 = @unionInit(Payload, "Ir_" ++ @tagName(tag), payload);
                }
            },
        }
        return result;
    }
};

pub const Ir = struct {
    loc: *const @import("ast.zig").SrcRef,
    node: node,
};

test "node.toc C-derived instruction payloads" {
    const math = node.toc(.{ .math = .{ .op = c.MathKind_add, .l = 1, .r = 2, .d = 3 } });
    try std.testing.expectEqual(c.Ir_math_enum, math.tag);
    try std.testing.expectEqual(c.MathKind_add, math.unnamed_0.Ir_math.op);
    try std.testing.expectEqual(@as(node.Reg, 3), math.unnamed_0.Ir_math.d);
    const conditional = node.toc(.{ .@"if" = 7 });
    try std.testing.expectEqual(c.Ir_if_enum, conditional.tag);
    try std.testing.expectEqual(@as(node.Reg, 7), conditional.unnamed_0.Ir_if);
    try std.testing.expectEqual(c.Ir_else_enum, node.toc(.@"else").tag);
    try std.testing.expectEqual(c.Ir_endif_enum, node.toc(.endif).tag);
    var args = [_:std.math.maxInt(node.Reg)]node.Reg{ 1, 2 };
    const call = node.toc(.{ .call = .{ .@"fn" = 3, .d = 4, .args = &args } });
    try std.testing.expect(call.unnamed_0.Ir_call.args == @as([*c]node.Reg, &args));
    const source = "x += 1;";
    const raw = node.toc(.{ .c = .{
        .d = 5,
        .sring = .{ .ptr = source.ptr, .len = source.len },
    } });
    try std.testing.expectEqual(c.Ir_c_enum, raw.tag);
    try std.testing.expectEqual(@as(node.Reg, 5), raw.unnamed_0.Ir_c.d);
    const text = raw.unnamed_0.Ir_c.sring;
    try std.testing.expectEqualStrings(source, text.ptr[0..text.len]);
}
