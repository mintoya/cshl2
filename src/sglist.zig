const std = @import("std");
pub fn SgList(T: type, comptime starting_shift: u7, comptime ending_shift: u7) type {
    return struct {
        const Self = @This();

        pub const empty: Self = .{};

        len: usize = 0,
        arrays: [ending_shift - starting_shift]?[*]T = @splat(null),

        fn idx1(i: usize) usize {
            return std.math.log2_int(usize, i + (1 << starting_shift)) - starting_shift;
        }
        fn sectionLen(section: usize) usize {
            return @as(usize, 1) << @intCast(section + starting_shift);
        }
        fn idx2(i: usize) usize {
            return i - (sectionLen(idx1(i)) - (1 << starting_shift));
        }

        pub fn get(self: *Self, index: usize) *T {
            std.debug.assert(index < self.len);
            return &self.arrays[idx1(index)].?[idx2(index)];
        }

        pub fn getConst(self: *const Self, index: usize) *const T {
            std.debug.assert(index < self.len);
            return &self.arrays[idx1(index)].?[idx2(index)];
        }
        pub fn append(self: *Self, allocator: std.mem.Allocator, value: T) !void {
            try self.push(allocator, value);
        }
        pub fn push(self: *Self, allocator: std.mem.Allocator, value: T) std.mem.Allocator.Error!void {
            if (self.len > std.math.maxInt(usize) - (1 << starting_shift)) return error.OutOfMemory;
            const section = idx1(self.len);
            if (section >= self.arrays.len or section + starting_shift >= @bitSizeOf(usize))
                return error.OutOfMemory;
            if (self.arrays[section] == null) {
                const items = try allocator.alloc(T, sectionLen(section));
                self.arrays[section] = items.ptr;
            }
            self.arrays[section].?[idx2(self.len)] = value;
            self.len += 1;
        }
        pub fn appendNTimes(self: *Self, alloc: std.mem.Allocator, it: T, N: usize) !void {
            for (0..N) |_| try self.push(alloc, it);
        }
        /// get contiguous section
        pub fn getContiguous(self: *Self, alloc: std.mem.Allocator, len: usize) std.mem.Allocator.Error![]T {
            if (len == 0) return &.{};
            while (true) {
                if (self.len > std.math.maxInt(usize) - (1 << starting_shift)) return error.OutOfMemory;
                const section = idx1(self.len);
                if (section >= self.arrays.len or section + starting_shift >= @bitSizeOf(usize)) return error.OutOfMemory;
                if (self.arrays[section] == null)
                    self.arrays[section] = (try alloc.alloc(T, sectionLen(section))).ptr;
                const off = idx2(self.len);
                const room = sectionLen(section) - off;
                if (room >= len) {
                    self.len += len;
                    return self.arrays[section].?[off..][0..len];
                }
                self.len += room;
            }
        }
        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            for (&self.arrays, 0..) |*array, section| {
                const ptr = array.* orelse break;
                allocator.free(ptr[0..sectionLen(section)]);
                array.* = null;
            }
            self.len = 0;
        }
    };
}

test "getContiguous" {
    const L = SgList(u32, 2, 10); // sections of 4, 8, 16, ...
    var l: L = .empty;
    defer l.deinit(std.testing.allocator);

    try l.append(std.testing.allocator, 1);
    // fits in the rest of the first section
    const a = try l.getContiguous(std.testing.allocator, 3);
    try std.testing.expectEqual(3, a.len);
    for (a, 0..) |*x, i| x.* = @intCast(10 + i);
    try std.testing.expectEqual(4, l.len);
    try std.testing.expectEqual(12, l.get(3).*);

    try l.append(std.testing.allocator, 2); // index 4, start of the 8 section
    // 7 left in this section, 10 doesn't fit: skips to the 16 section
    const b = try l.getContiguous(std.testing.allocator, 10);
    try std.testing.expectEqual(10, b.len);
    try std.testing.expectEqual(12 + 10, l.len);
    for (b, 0..) |*x, i| x.* = @intCast(100 + i);
    try std.testing.expectEqual(100, l.get(12).*);
    try std.testing.expectEqual(109, l.get(21).*);

    // bigger than the next section too: skips two, all stay allocated
    const c = try l.getContiguous(std.testing.allocator, 40);
    try std.testing.expectEqual(40, c.len);
    try std.testing.expectEqual(0, (try l.getContiguous(std.testing.allocator, 0)).len);
}
