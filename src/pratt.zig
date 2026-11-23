//! A hand-written parser for cshl: the same `Ast` that parse.zig makes from
//! tree-sitter, from the source directly. Depends only on ast.zig.
//!
//! From loosest to tightest:
//!
//!   a <| b          (<| a b), right to left
//!   a |> b          (|> a b), left to right
//!   f | x, f|(a, b) (f x), (f a b): call what's on the left
//!   f x y           (f (x y)): juxtaposition calls, right to left
//!   a = b           (= a b), right to left; ~x anywhere an operand can be is
//!                   ([] x...), with x everything up to the end
//!   and or xor > == != < > <= >= <=> (don't chain) > band bor bxor >
//!   shl shr > + - > * / % > as
//!   tight: no space between the parts. f(a, b) f[a] f{..} f"s" are calls,
//!   x.y x:y members, and a name, symbol or number right after something
//!   calls it, right to left: @refT@this() is (@refT (@this))
//!
//! (a, b) and [a, b] are ([] a b), {a; b} is ({} a b), with a trailing nul
//! when the last statement ends in `;`. Comments are whitespace.
const std = @import("std");
const ast = @import("ast.zig");
const Ast = ast.Ast;
const FileItem = ast.FileItem;
const SrcRef = ast.SrcRef;

pub const builtin_file: FileItem = .{ .disk = .{ .filename = "<builtin>", .content = "[]{}" } };
const list_head: Ast = .{ .id = .{ .src = &builtin_file, .off = 0, .len = 2 } };
const block_head: Ast = .{ .id = .{ .src = &builtin_file, .off = 2, .len = 2 } };

pub const Diagnostic = struct {
    off: u32 = 0,
    len: u32 = 0,
    msg: []const u8 = "",
};

pub const Error = error{ OutOfMemory, SyntaxError, SourceTooLong };

/// Parses `file` into a `({} statements...)` tree. The nodes are allocated in
/// `gpa` and reference `file`, so both must outlive the result; an arena suits.
/// On `error.SyntaxError`, `diag` (if given) says what and where.
pub fn parse(gpa: std.mem.Allocator, file: *const FileItem, diag: ?*Diagnostic) Error!Ast {
    const src = file.bytes();
    if (src.len > std.math.maxInt(u32)) return error.SourceTooLong;
    var p: Parser = .{ .gpa = gpa, .file = file, .src = src, .diag = diag };
    const t = try p.peek(.prefix);
    if (t.tag == .eof) return .{ .call = try gpa.dupe(Ast, &.{block_head}) };
    const body = try p.statements(block_head, null);
    const end = try p.peek(.infix);
    if (end.tag != .eof) return p.fail(end, "expected `;` between statements");
    return body;
}

const Tag = enum { word, symbol, number, string, op, eof };
const Token = struct {
    tag: Tag,
    start: u32,
    end: u32,
    /// whether whitespace or a comment comes right before it
    spaced: bool,
};
/// Operand expected (prefix) or something after one (infix). After an
/// operand `and`, `as`... are operators and `!=` is one token; before one
/// they're a name and a `!`.
const Mode = enum { prefix, infix };

const keywords = [_][]const u8{ "and", "or", "xor", "band", "bor", "bxor", "shl", "shr", "as" };
const levels = [_]struct { ops: []const []const u8, chains: bool }{
    .{ .ops = &.{ "and", "or", "xor" }, .chains = true },
    .{ .ops = &.{ "==", "!=", "<", ">", "<=", ">=", "<=>" }, .chains = false },
    .{ .ops = &.{ "band", "bor", "bxor" }, .chains = true },
    .{ .ops = &.{ "shl", "shr" }, .chains = true },
    .{ .ops = &.{ "+", "-" }, .chains = true },
    .{ .ops = &.{ "*", "/", "%" }, .chains = true },
    .{ .ops = &.{"as"}, .chains = true },
};

fn isIdStart(c: u8) bool {
    return std.ascii.isAlphabetic(c) or c == '_' or c == '@';
}
fn isIdRest(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}
fn isKeyword(s: []const u8) bool {
    for (keywords) |k| if (std.mem.eql(u8, s, k)) return true;
    return false;
}

const Parser = struct {
    gpa: std.mem.Allocator,
    file: *const FileItem,
    src: []const u8,
    diag: ?*Diagnostic,
    pos: u32 = 0,

    fn fail(self: *Parser, t: Token, msg: []const u8) Error {
        return self.failAt(t.start, @max(t.end - t.start, 1), msg);
    }
    fn failAt(self: *Parser, off: u32, len: u32, msg: []const u8) Error {
        if (self.diag) |d| d.* = .{ .off = off, .len = len, .msg = msg };
        return error.SyntaxError;
    }
    fn ref(self: *Parser, start: u32, end: u32) SrcRef {
        return .{ .src = self.file, .off = start, .len = end - start };
    }
    fn text(self: *Parser, t: Token) []const u8 {
        return self.src[t.start..t.end];
    }
    fn idOf(self: *Parser, t: Token) Ast {
        return .{ .id = self.ref(t.start, t.end) };
    }
    fn call(self: *Parser, items: []const Ast) Error!Ast {
        return .{ .call = try self.gpa.dupe(Ast, items) };
    }

    // ------------------------------------------------------------- tokens

    /// Whitespace and comments from pos: where the next token starts.
    fn skip(self: *Parser) Error!struct { u32, bool } {
        var i = self.pos;
        const s = self.src;
        while (i < s.len) {
            if (std.ascii.isWhitespace(s[i])) {
                i += 1;
            } else if (s[i] == '/' and i + 1 < s.len and s[i + 1] == '/') {
                while (i < s.len and s[i] != '\n' and s[i] != '\r') i += 1;
            } else if (s[i] == '/' and i + 1 < s.len and s[i + 1] == '*') {
                const end = std.mem.indexOfPos(u8, s, i + 2, "*/") orelse
                    return self.failAt(i, 2, "this comment doesn't end: no `*/`");
                i = @intCast(end + 2);
            } else break;
        }
        return .{ i, i != self.pos };
    }

    fn peek(self: *Parser, mode: Mode) Error!Token {
        const start, const spaced = try self.skip();
        const s = self.src;
        var t: Token = .{ .tag = .op, .start = start, .end = start + 1, .spaced = spaced };
        if (start >= s.len) {
            t.tag = .eof;
            t.end = start;
            return t;
        }
        const c = s[start];
        const next: u8 = if (start + 1 < s.len) s[start + 1] else 0;
        switch (c) {
            '"' => {
                t.tag = .string;
                var i = start + 1;
                while (true) {
                    if (i >= s.len or s[i] == '\n' or s[i] == '\r')
                        return self.failAt(start, 1, "this string doesn't end: no `\"` on its line");
                    if (s[i] == '"') break;
                    if (s[i] == '\\') i = try self.escape(i) else i += 1;
                }
                t.end = i + 1;
            },
            '0'...'9' => {
                t.tag = .number;
                var i = start + 1;
                if (c == '0' and next == 'b' and start + 2 < s.len and (s[start + 2] == '0' or s[start + 2] == '1')) {
                    i = start + 2;
                    while (i < s.len and (s[i] == '0' or s[i] == '1')) i += 1;
                } else if (c == '0' and next == 'x' and start + 2 < s.len and isHex(s[start + 2])) {
                    i = start + 2;
                    while (i < s.len and isHex(s[i])) i += 1;
                } else while (i < s.len and std.ascii.isDigit(s[i])) i += 1;
                t.end = i;
            },
            '\'', '`', '\\', '?', '#', '$' => t.tag = .symbol,
            '!' => if (mode == .infix and next == '=') {
                t.end = start + 2;
            } else {
                t.tag = .symbol;
            },
            '.' => if (next == '.') {
                t.tag = .symbol;
                t.end = start + 2;
            },
            '=' => if (next == '=') {
                t.end = start + 2;
            },
            '<' => if (next == '=' and start + 2 < s.len and s[start + 2] == '>') {
                t.end = start + 3;
            } else if (next == '=' or next == '|') {
                t.end = start + 2;
            },
            '>' => if (next == '=') {
                t.end = start + 2;
            },
            '|' => if (next == '>' or next == '(' or next == '[') {
                t.end = start + 2;
            },
            '+', '-', '*', '/', '%', '~', ':', ',', ';', '(', ')', '[', ']', '{', '}' => {},
            else => if (isIdStart(c)) {
                t.tag = .word;
                var i = start + 1;
                while (i < s.len and isIdRest(s[i])) i += 1;
                if (i < s.len and (s[i] == '?' or s[i] == '#' or s[i] == '!' or s[i] == '$')) i += 1;
                t.end = i;
                // an operator after an operand, a name otherwise
                if (mode == .infix and isKeyword(s[start..i])) t.tag = .op;
            } else return self.failAt(start, 1, "this character isn't part of cshl"),
        }
        return t;
    }
    fn isHex(c: u8) bool {
        return std.ascii.isDigit(c) or (c >= 'a' and c <= 'f');
    }
    /// The escape at s[i] (a `\`): where it ends.
    fn escape(self: *Parser, i: u32) Error!u32 {
        const s = self.src;
        if (i + 1 < s.len) switch (s[i + 1]) {
            '"', '\\', 'n', 'r', 't', '0' => return i + 2,
            'x' => if (i + 2 < s.len and s[i + 2] == '{') {
                // \x{hex hex ...}
                var j = i + 3;
                var digits = false;
                while (j < s.len) : (j += 1) {
                    if (isHex(s[j])) {
                        digits = true;
                    } else if (s[j] == ' ' or s[j] == '\t') {
                        if (!digits) break;
                        digits = false;
                    } else break;
                }
                if (digits and j < s.len and s[j] == '}') return j + 1;
                return self.failAt(i, j - i, "expected \\x{...}: hex bytes, space between them");
            },
            else => {},
        };
        return self.failAt(i, 2, "this escape isn't one of \\\" \\\\ \\n \\r \\t \\0 \\x{..}");
    }

    fn take(self: *Parser, mode: Mode) Error!Token {
        const t = try self.peek(mode);
        self.pos = t.end;
        return t;
    }
    fn isOp(self: *Parser, t: Token, op: []const u8) bool {
        return t.tag == .op and std.mem.eql(u8, self.text(t), op);
    }
    fn expect(self: *Parser, mode: Mode, op: []const u8, open: ?Token, msg: []const u8) Error!Token {
        const t = try self.peek(mode);
        if (!self.isOp(t, op)) {
            if (open) |o| if (t.tag == .eof) return self.fail(o, msg);
            return self.fail(t, msg);
        }
        self.pos = t.end;
        return t;
    }

    // ------------------------------------------------------------- grammar

    pub fn expression(self: *Parser) Error!Ast {
        return self.backward();
    }

    fn backward(self: *Parser) Error!Ast {
        const l = try self.forward();
        const t = try self.peek(.infix);
        if (!self.isOp(t, "<|")) return l;
        self.pos = t.end;
        return self.call(&.{ self.idOf(t), l, try self.backward() });
    }

    fn forward(self: *Parser) Error!Ast {
        var l = try self.separated();
        while (true) {
            const t = try self.peek(.infix);
            if (!self.isOp(t, "|>")) return l;
            self.pos = t.end;
            l = try self.call(&.{ self.idOf(t), l, try self.separated() });
        }
    }

    fn separated(self: *Parser) Error!Ast {
        var l = try self.application();
        while (true) {
            const t = try self.peek(.infix);
            if (self.isOp(t, "|")) {
                self.pos = t.end;
                l = try self.call(&.{ l, try self.application() });
            } else if (self.isOp(t, "|(") or self.isOp(t, "|[")) {
                self.pos = t.end;
                const close: []const u8 = if (self.src[t.start + 1] == '(') ")" else "]";
                var items: std.ArrayList(Ast) = .empty;
                try items.append(self.gpa, l);
                try self.sequenceOf(&items, close, t);
                l = .{ .call = try items.toOwnedSlice(self.gpa) };
            } else return l;
        }
    }

    /// f x y: (f (x y)), when what follows can start an operand
    fn application(self: *Parser) Error!Ast {
        const f = try self.assignment();
        if (!try self.startsOperand()) return f;
        return self.call(&.{ f, try self.application() });
    }
    fn startsOperand(self: *Parser) Error!bool {
        const t = try self.peek(.infix);
        return switch (t.tag) {
            .word, .symbol, .number, .string => true,
            .op => for ([_][]const u8{ "(", "[", "{", "~" }) |o| {
                if (self.isOp(t, o)) break true;
            } else false,
            .eof => false,
        };
    }

    fn assignment(self: *Parser) Error!Ast {
        if (try self.rest()) |r| return r;
        const l = try self.level(0);
        const t = try self.peek(.infix);
        if (!self.isOp(t, "=")) return l;
        self.pos = t.end;
        return self.call(&.{ self.idOf(t), l, try self.assignment() });
    }
    /// ~x: ([] x), with x everything after it
    fn rest(self: *Parser) Error!?Ast {
        const t = try self.peek(.prefix);
        if (!self.isOp(t, "~")) return null;
        self.pos = t.end;
        return try self.call(&.{ list_head, try self.expression() });
    }

    fn level(self: *Parser, i: usize) Error!Ast {
        if (i == levels.len) return self.tight();
        var l = try self.level(i + 1);
        while (true) {
            const t = try self.peek(.infix);
            const is_op = t.tag == .op and for (levels[i].ops) |o| {
                if (std.mem.eql(u8, self.text(t), o)) break true;
            } else false;
            if (!is_op) return l;
            self.pos = t.end;
            const r = if (try self.rest()) |x| x else try self.level(i + 1);
            l = try self.call(&.{ self.idOf(t), l, r });
            if (!levels[i].chains) {
                const n = try self.peek(.infix);
                if (n.tag == .op) for (levels[i].ops) |o| if (std.mem.eql(u8, self.text(n), o))
                    return self.fail(n, "comparisons don't chain: put one in parentheses");
                return l;
            }
        }
    }

    /// x, then names, symbols or numbers right after it: (x (y z))
    fn tight(self: *Parser) Error!Ast {
        const p = try self.postfix(try self.atom());
        if (try self.adjacentWord() == null) return p;
        return self.call(&.{ p, try self.wordRest() });
    }
    fn adjacentWord(self: *Parser) Error!?Token {
        const t = try self.peek(.infix);
        if (t.spaced) return null;
        return switch (t.tag) {
            .word, .symbol, .number => t,
            else => null,
        };
    }
    fn wordRest(self: *Parser) Error!Ast {
        const w = (try self.adjacentWord()).?;
        self.pos = w.end;
        const p = try self.postfix(self.leaf(w));
        if (try self.adjacentWord() == null) return p;
        return self.call(&.{ p, try self.wordRest() });
    }
    fn leaf(self: *Parser, t: Token) Ast {
        const r = self.ref(t.start, t.end);
        return switch (t.tag) {
            .number => .{ .num = r },
            .string => .{ .str = self.ref(t.start + 1, t.end - 1) },
            else => .{ .id = r },
        };
    }

    /// x followed by calls f(a) f[a] f{..} f"s" (right after it) and members
    /// x.y x:y
    fn postfix(self: *Parser, first: Ast) Error!Ast {
        var x = first;
        while (true) {
            const t = try self.peek(.infix);
            if (t.tag == .string and !t.spaced) {
                self.pos = t.end;
                x = try self.call(&.{ x, self.leaf(t) });
            } else if (t.tag == .op and !t.spaced and (self.isOp(t, "(") or self.isOp(t, "["))) {
                self.pos = t.end;
                var items: std.ArrayList(Ast) = .empty;
                try items.append(self.gpa, x);
                try self.sequenceOf(&items, if (self.isOp(t, "(")) ")" else "]", t);
                x = .{ .call = try items.toOwnedSlice(self.gpa) };
            } else if (t.tag == .op and !t.spaced and self.isOp(t, "{")) {
                self.pos = t.end;
                x = try self.call(&.{ x, try self.block(t) });
            } else if (self.isOp(t, ".") or self.isOp(t, ":")) {
                self.pos = t.end;
                x = try self.call(&.{ self.idOf(t), x, try self.member() });
            } else return x;
        }
    }
    /// what's after . or :: an atom, then names right after it, (a (b c))
    fn member(self: *Parser) Error!Ast {
        const a = try self.atom();
        if (try self.adjacentWord() == null) return a;
        return self.call(&.{ a, try self.memberRest() });
    }
    fn memberRest(self: *Parser) Error!Ast {
        const w = (try self.adjacentWord()).?;
        self.pos = w.end;
        if (try self.adjacentWord() == null) return self.leaf(w);
        return self.call(&.{ self.leaf(w), try self.memberRest() });
    }

    fn atom(self: *Parser) Error!Ast {
        const t = try self.take(.prefix);
        switch (t.tag) {
            .word, .symbol, .number, .string => return self.leaf(t),
            .eof => return self.fail(t, "expected something here, and the file ends"),
            .op => {},
        }
        if (self.isOp(t, "(") or self.isOp(t, "[")) {
            var items: std.ArrayList(Ast) = .empty;
            try items.append(self.gpa, list_head);
            try self.sequenceOf(&items, if (self.isOp(t, "(")) ")" else "]", t);
            return .{ .call = try items.toOwnedSlice(self.gpa) };
        }
        if (self.isOp(t, "{")) return self.block(t);
        return self.fail(t, "expected a name, a number, a string or a bracket here");
    }

    /// a, b, ... up to close, with a trailing comma allowed
    fn sequenceOf(self: *Parser, items: *std.ArrayList(Ast), close: []const u8, open: Token) Error!void {
        const msg = if (std.mem.eql(u8, close, ")")) "expected `,` or a `)` to close this `(`" else "expected `,` or a `]` to close this `[`";
        while (true) {
            const n = try self.peek(.prefix);
            if (self.isOp(n, close)) break;
            if (n.tag == .eof) return self.fail(open, msg);
            try items.append(self.gpa, try self.expression());
            const t = try self.peek(.infix);
            if (self.isOp(t, ",")) {
                self.pos = t.end;
                continue;
            }
            if (self.isOp(t, close)) break;
            return if (t.tag == .eof) self.fail(open, msg) else self.fail(t, msg);
        }
        _ = try self.expect(.infix, close, open, msg);
    }

    fn block(self: *Parser, open: Token) Error!Ast {
        if (self.isOp(try self.peek(.prefix), "}")) {
            _ = try self.take(.prefix);
            return self.call(&.{block_head});
        }
        const b = try self.statements(block_head, open);
        _ = try self.expect(.infix, "}", open, "expected `;` or a `}` to close this `{`");
        return b;
    }
    /// a; b; c, with a nul at the end for a trailing `;`. stops before `}`
    /// or the end
    fn statements(self: *Parser, head: Ast, open: ?Token) Error!Ast {
        var items: std.ArrayList(Ast) = .empty;
        try items.append(self.gpa, head);
        while (true) {
            try items.append(self.gpa, try self.expression());
            const t = try self.peek(.infix);
            if (!self.isOp(t, ";")) break;
            self.pos = t.end;
            const n = try self.peek(.prefix);
            if (n.tag == .eof or self.isOp(n, "}")) {
                try items.append(self.gpa, .{ .nil = self.ref(t.start, t.end) });
                break;
            }
        }
        const t = try self.peek(.infix);
        if (open != null and t.tag != .eof and !self.isOp(t, "}"))
            return self.fail(t, "expected `;` between statements");
        return .{ .call = try items.toOwnedSlice(self.gpa) };
    }
};

// ------------------------------------------------------------------ tests

fn expectParse(source: []const u8, expected: []const u8) !void {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const file: FileItem = .{ .disk = .{ .filename = "<test>", .content = source } };
    const tree = try parse(arena.allocator(), &file, null);
    var out: std.Io.Writer.Allocating = .init(arena.allocator());
    try tree.format(&out.writer);
    try std.testing.expectEqualStrings(expected, out.written());
}
fn expectError(source: []const u8, off: u32) !void {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const file: FileItem = .{ .disk = .{ .filename = "<test>", .content = source } };
    var diag: Diagnostic = .{};
    try std.testing.expectError(error.SyntaxError, parse(arena.allocator(), &file, &diag));
    try std.testing.expectEqual(off, diag.off);
}

test "atoms and lists" {
    try expectParse("x; 5; \"hi\\n\"; [a, b]; (a,); {}", "({} x 5 \"hi\\n\" ([] a b) ([] a) ({}))");
    try expectParse("{1;}; {1}; 2;", "({} ({} 1 nul) ({} 1) 2 nul)");
    try expectParse("", "({})");
}

test "calls put the function first" {
    try expectParse("@bind[x,5]; (x + y) == 11", "({} (@bind x 5) (== ([] (+ x y)) 11))");
    try expectParse("z <| 0 as i32", "({} (<| z (as 0 i32)))");
    try expectParse("@using @import @path \"lib\"", "({} (@using (@import (@path \"lib\"))))");
    try expectParse("x:add(5) // c\n", "({} ((: x add) 5))");
    try expectParse("@refT@this()", "({} (@refT (@this)))");
}

test "~ is the rest, as any right operand" {
    try expectParse("x as ~f y", "({} (as x ([] (f y))))");
    try expectParse("a + ~b * c == d", "({} (+ a ([] (== (* b c) d))))");
    try expectParse("x = ~f y", "({} (= x ([] (f y))))");
    try expectParse("a + b + c", "({} (+ (+ a b) c))");
}

test "spacing decides" {
    try expectParse("f(a) ; f (a)", "({} (f a) (f ([] a)))");
    try expectParse("f|(a, b) | x", "({} ((f a b) x))");
    try expectParse("f| (a, b)", "({} (f ([] a b)))");
    try expectParse("'{x}; `'(y)", "({} (' ({} x)) (` (' y)))");
    try expectParse("0as ull; a!=b; x != !y", "({} (as 0 ull) (= a! b) (!= x (! y)))");
    try expectParse("?slice(uc); !(t).ok(v)", "({} (? (slice uc)) ((. (! t) ok) v))");
    try expectParse("def x = f y", "({} (def ((= x f) y)))");
    try expectParse("a |> b <| c d", "({} (<| (|> a b) (c d)))");
    try expectParse("0x1f 0b102", "({} (0x1f (0b10 2)))");
}

test "errors say where" {
    try expectError("x <| (1, ", 5);
    try expectError("f(a b", 1);
    try expectError("a == b == c", 7);
    try expectError("\"abc", 0);
    try expectError("{ a b; c d e } }", 15);
}
