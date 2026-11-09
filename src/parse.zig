//! Turns a tree-sitter-cshl parse tree into an `Ast`.
//!
//!   id, number          -> .id, .num
//!   string              -> .str, the text between the quotes (escapes kept raw)
//!   [a, b] / (a, b)     -> ([] a b)
//!   {a; b} / program    -> ({} a b)
//!   call                -> (function arguments...), e.g. a + b -> (+ a b)
//!
//! Comments are dropped. `[]` and `{}` point into `builtin_file`, since the
//! source has no such token.
const std = @import("std");
const ts = @import("tree_sitter");
const ast = @import("ast.zig");
const Ast = ast.Ast;
const FileItem = ast.FileItem;
const SrcRef = ast.SrcRef;

pub const builtin_file: FileItem = .{ .disk = .{ .filename = "<builtin>", .content = "[]{}" } };
const list_head: Ast = .{ .id = .{ .src = &builtin_file, .off = 0, .len = 2 } };
const block_head: Ast = .{ .id = .{ .src = &builtin_file, .off = 2, .len = 2 } };

pub const Diagnostic = struct {
    /// Byte offset of the first syntax error.
    off: u32 = 0,
    len: u32 = 0,
    missing: bool = false,
    /// The missing token's kind when `missing`.
    kind: []const u8 = "",
};

pub const Error = error{ OutOfMemory, ParserInit, SyntaxError, SourceTooLong };

/// Parses `file` into a `({} statements...)` tree. The nodes are allocated in
/// `gpa` and reference `file`, so both must outlive the result; an arena suits.
/// On `error.SyntaxError`, `diag` (if given) holds the first error's location.
pub fn parse(gpa: std.mem.Allocator, file: *const FileItem, diag: ?*Diagnostic) Error!Ast {
    const src = file.bytes();
    if (src.len > std.math.maxInt(u32)) return error.SourceTooLong;

    const parser = ts.ts_parser_new() orelse return error.OutOfMemory;
    defer ts.ts_parser_delete(parser);
    if (!ts.ts_parser_set_language(parser, ts.tree_sitter_cshl())) return error.ParserInit;

    const tree = ts.ts_parser_parse_string(parser, null, src.ptr, @intCast(src.len)) orelse
        return error.ParserInit;
    defer ts.ts_tree_delete(tree);

    const root = ts.ts_tree_root_node(tree);
    if (ts.ts_node_has_error(root)) {
        if (diag) |d| d.* = firstError(root) orelse .{};
        return error.SyntaxError;
    }
    const conv: Converter = .{ .gpa = gpa, .file = file, .ids = .init(ts.tree_sitter_cshl()) };
    return conv.node(root);
}

fn firstError(node: ts.TSNode) ?Diagnostic {
    if (ts.ts_node_is_error(node) or ts.ts_node_is_missing(node)) {
        const start = ts.ts_node_start_byte(node);
        return .{
            .off = start,
            .len = ts.ts_node_end_byte(node) - start,
            .missing = ts.ts_node_is_missing(node),
            .kind = std.mem.span(ts.ts_node_type(node)),
        };
    }
    var i: u32 = 0;
    while (i < ts.ts_node_child_count(node)) : (i += 1) {
        const child = ts.ts_node_child(node, i);
        if (ts.ts_node_has_error(child)) if (firstError(child)) |d| return d;
    }
    return null;
}

/// The grammar's symbol and field ids, looked up once by name.
const Ids = struct {
    id: ts.TSSymbol,
    number: ts.TSSymbol,
    string: ts.TSSymbol,
    list: ts.TSSymbol,
    block: ts.TSSymbol,
    program: ts.TSSymbol,
    call: ts.TSSymbol,
    comment: ts.TSSymbol,
    function: ts.TSFieldId,
    argument: ts.TSFieldId,

    fn init(lang: ?*const ts.TSLanguage) Ids {
        const ids: Ids = .{
            .id = sym(lang, "id"),
            .number = sym(lang, "number"),
            .string = sym(lang, "string"),
            .list = sym(lang, "list"),
            .block = sym(lang, "block"),
            .program = sym(lang, "program"),
            .call = sym(lang, "call"),
            .comment = sym(lang, "comment"),
            .function = ts.ts_language_field_id_for_name(lang, "function", "function".len),
            .argument = ts.ts_language_field_id_for_name(lang, "argument", "argument".len),
        };
        std.debug.assert(ids.function != 0 and ids.argument != 0);
        return ids;
    }

    fn sym(lang: ?*const ts.TSLanguage, comptime name: []const u8) ts.TSSymbol {
        const s = ts.ts_language_symbol_for_name(lang, name.ptr, name.len, true);
        std.debug.assert(s != 0);
        return s;
    }
};

const Converter = struct {
    gpa: std.mem.Allocator,
    file: *const FileItem,
    ids: Ids,

    fn ref(self: Converter, n: ts.TSNode) SrcRef {
        const start = ts.ts_node_start_byte(n);
        return .{ .src = self.file, .off = start, .len = ts.ts_node_end_byte(n) - start };
    }

    fn node(self: Converter, n: ts.TSNode) Error!Ast {
        const sym = ts.ts_node_symbol(n);
        const ids = self.ids;
        // Anonymous nodes only show up as a call's operator: `+`, `<~`, `.`.
        if (!ts.ts_node_is_named(n) or sym == ids.id) return .{ .id = self.ref(n) };
        if (sym == ids.number) return .{ .num = self.ref(n) };
        if (sym == ids.string) {
            var r = self.ref(n);
            r.off += 1;
            r.len -= 2;
            return .{ .str = r };
        }
        if (sym == ids.list) return self.sequence(n, list_head);
        if (sym == ids.block or sym == ids.program) return self.sequence(n, block_head);
        if (sym == ids.call) return self.call(n);
        std.debug.panic("cshl: unexpected tree-sitter node `{s}`", .{ts.ts_node_type(n)});
    }

    /// (head children...), over the named, non-comment children.
    fn sequence(self: Converter, n: ts.TSNode, head: Ast) Error!Ast {
        var items: std.ArrayList(Ast) = .empty;
        errdefer items.deinit(self.gpa);
        try items.append(self.gpa, head);
        var i: u32 = 0;
        while (i < ts.ts_node_named_child_count(n)) : (i += 1) {
            const child = ts.ts_node_named_child(n, i);
            if (ts.ts_node_symbol(child) == self.ids.comment) continue;
            try items.append(self.gpa, try self.node(child));
        }
        return .{ .call = try items.toOwnedSlice(self.gpa) };
    }

    /// (function arguments...). The fields are in source order, so `a + b`
    /// lists `a` before its function `+`; brackets and commas have no field.
    fn call(self: Converter, n: ts.TSNode) Error!Ast {
        var items: std.ArrayList(Ast) = .empty;
        errdefer items.deinit(self.gpa);
        try items.append(self.gpa, undefined);
        var function: ?Ast = null;

        var cursor = ts.ts_tree_cursor_new(n);
        defer ts.ts_tree_cursor_delete(&cursor);
        if (ts.ts_tree_cursor_goto_first_child(&cursor)) while (true) {
            const field = ts.ts_tree_cursor_current_field_id(&cursor);
            if (field == self.ids.function)
                function = try self.node(ts.ts_tree_cursor_current_node(&cursor))
            else if (field == self.ids.argument)
                try items.append(self.gpa, try self.node(ts.ts_tree_cursor_current_node(&cursor)));
            if (!ts.ts_tree_cursor_goto_next_sibling(&cursor)) break;
        };

        items.items[0] = function orelse
            std.debug.panic("cshl: call without a function at byte {d}", .{ts.ts_node_start_byte(n)});
        return .{ .call = try items.toOwnedSlice(self.gpa) };
    }
};

fn expectParse(source: []const u8, expected: []const u8) !void {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const file: FileItem = .{ .disk = .{ .filename = "<test>", .content = source } };
    const tree = try parse(arena.allocator(), &file, null);
    var out: std.Io.Writer.Allocating = .init(arena.allocator());
    try tree.format(&out.writer);
    try std.testing.expectEqualStrings(expected, out.written());
}

test "atoms and lists" {
    try expectParse("x; 5; \"hi\\n\"; [a, b]; (a,); {}", "({} x 5 \"hi\\n\" ([] a b) ([] a) ({}))");
}

test "calls put the function first" {
    try expectParse("@bind[x,5]; (x + y) == 11", "({} (@bind x 5) (== ([] (+ x y)) 11))");
    try expectParse("z <- 0 as i32", "({} (<- z (as 0 i32)))");
    try expectParse("@using @import @path \"lib\"", "({} (@using (@import (@path \"lib\"))))");
    try expectParse("x:add(5) // c\n", "({} ((: x add) 5))");
    try expectParse("@refT@this()", "({} (@refT (@this)))");
}

test "syntax errors report a location" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const file: FileItem = .{ .disk = .{ .filename = "<test>", .content = "x <~ (1, " } };
    var diag: Diagnostic = .{};
    try std.testing.expectError(error.SyntaxError, parse(arena.allocator(), &file, &diag));
}
