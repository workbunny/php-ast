const std = @import("std");
const ast = @import("ast.zig");
const Token = @import("token.zig").Token;
const Parser = @import("parser.zig").Parser;

const Node = ast.Node;
const Index = ast.Index;
const OptionalIndex = ast.OptionalIndex;
const SubRange = ast.SubRange;
const ListRange = ast.ListRange;
const ExtraIndex = ast.ExtraIndex;
const TokenIndex = ast.TokenIndex;

const expr = @import("parser_expr.zig");
const testing = @import("testing.zig");

/// 泛型类型 `Foo<int>` / `list<int>` / `array<int, int>`：承载基础类型与类型实参列表。
pub const GenericTypeComponents = struct {
    base: Index,
    args: SubRange,
};

pub fn isTypeStart(p: *Parser) bool {
    return switch (p.tokTag()) {
        .question, .lparen, .backslash, .kw_namespace, .identifier, .kw_true, .kw_false, .kw_null, .kw_static, .kw_list => true,
        else => false,
    };
}

pub fn parseType(p: *Parser) ast.ParseError!?Index {
    if (p.tokTag() == .question) {
        const q = p.nextToken();
        const inner = (try parseTypeUnion(p)) orelse return null;
        return (try p.addNode(.{ .tag = .type_nullable, .main_token = q, .data = .{ .node = inner } })) orelse unreachable;
    }
    return parseTypeUnion(p);
}

pub fn parseTypeUnion(p: *Parser) ast.ParseError!?Index {
    var left = (try parseTypeIntersect(p)) orelse return null;
    while (p.tokTag() == .pipe) {
        const op = p.nextToken();
        const right = (try parseTypeUnion(p)) orelse return null;
        left = (try p.addNode(.{ .tag = .type_union, .main_token = op, .data = .{ .node_and_node = .{ left, right } } })) orelse unreachable;
    }
    return left;
}

pub fn parseTypeIntersect(p: *Parser) ast.ParseError!?Index {
    var left = (try parseTypeAtom(p)) orelse return null;
    while (p.tokTag() == .ampersand) {
        const save = p.tok_i;
        _ = p.nextToken();
        if (!isTypeStart(p)) {
            p.tok_i = save;
            break;
        }
        const right = (try parseTypeAtom(p)) orelse {
            p.tok_i = save;
            break;
        };
        left = (try p.addNode(.{ .tag = .type_intersection, .main_token = save, .data = .{ .node_and_node = .{ left, right } } })) orelse unreachable;
    }
    return left;
}

pub fn parseTypeAtom(p: *Parser) ast.ParseError!?Index {
    var base: Index = undefined;
    // 括号分组仅出现于 DNF，用于包围交集类型 `(A&B)`；php-ast 不引入独立节点，
    // 与 PHP-Parser 行为一致——括号仅改变优先级，类型节点直接复用内部类型。
    if (p.tokTag() == .lparen) {
        _ = p.nextToken();
        const inner = (try parseTypeUnion(p)) orelse {
            p.warn(ast.Error.Tag.expected_token);
            return null;
        };
        _ = p.eatToken(.rparen);
        base = inner;
    } else {
        base = (try parseTypeBase(p)) orelse return null;
    }
    var result = base;

    // 泛型后缀：`Foo<int>` / `list<int>` / `array<int, int>`
    if (p.tokTag() == .less_than) {
        const args = try parseTypeArgs(p) orelse return null;
        const extra = try p.addExtra(GenericTypeComponents{
            .base = base,
            .args = .{ .start = args.start, .end = args.end },
        });
        result = (try p.addNode(.{
            .tag = .type_generic,
            .main_token = p.nodeMainToken(base),
            .data = .{ .extra_and_node = .{ extra, base } },
        })) orelse unreachable;
    }

    // 数组后缀：`T[]` / `T[][]`（php-ast 的 `Type\Array_`）
    while (p.tokTag() == .lbracket) {
        // 主 token 取 `[` 而非内部类型——否则 `(A&B)[]` 的区间停在 `&`，
        // 快照与代码改写都看不出数组后缀。
        const lbracket = p.nextToken();
        _ = p.eatToken(.rbracket);
        result = (try p.addNode(.{
            .tag = .type_array_of,
            .main_token = lbracket,
            .data = .{ .node = result },
        })) orelse unreachable;
    }
    return result;
}

/// 解析单一「原子」类型：伪类型、关键字类型、名字类型（不含泛型/数组后缀）。
fn parseTypeBase(p: *Parser) ast.ParseError!?Index {
    const t = p.tokTag();
    if (t == .kw_static) {
        const tok = p.nextToken();
        return (try p.addNode(.{ .tag = .type_static, .main_token = tok, .data = .{ .token = tok } })) orelse unreachable;
    }
    if (t == .kw_true or t == .kw_false or t == .kw_null) {
        const tok = p.nextToken();
        const name = (try p.addNode(.{ .tag = .name, .main_token = tok, .data = .{ .token = tok } })) orelse unreachable;
        return (try p.addNode(.{ .tag = .type_name, .main_token = tok, .data = .{ .node = name } })) orelse unreachable;
    }
    if (t == .identifier or t == .backslash or t == .kw_namespace or t == .kw_list) {
        // 伪类型 self / parent：直接记为专用节点，与 PHP-Parser 的 Type\Self_/Parent_ 对齐。
        if (t == .identifier) {
            if (p.isSoftKw("self")) {
                const tok = p.nextToken();
                return (try p.addNode(.{ .tag = .type_self, .main_token = tok, .data = .{ .token = tok } })) orelse unreachable;
            }
            if (p.isSoftKw("parent")) {
                const tok = p.nextToken();
                return (try p.addNode(.{ .tag = .type_parent, .main_token = tok, .data = .{ .token = tok } })) orelse unreachable;
            }
        }
        // 其余（callable/iterable/void/never/mixed/object/resource/list/array/class 等）按名字类型承载。
        const name = (try expr.parseName(p)) orelse return null;
        return (try p.addNode(.{ .tag = .type_name, .main_token = p.nodeMainToken(name), .data = .{ .node = name } })) orelse unreachable;
    }
    p.warn(ast.Error.Tag.expected_token);
    return null;
}

/// 解析泛型实参列表 `<T1, T2, ...>`，返回实参的 `ListRange`。
fn parseTypeArgs(p: *Parser) ast.ParseError!?ListRange {
    _ = p.nextToken(); // 消费 `<`
    var args = try std.ArrayList(Index).initCapacity(p.gpa, 0);
    defer args.deinit(p.gpa);
    while (p.tokTag() != .greater_than and p.tokTag() != .eof) {
        const tp = (try parseType(p)) orelse return null;
        try args.append(p.gpa, tp);
        if (p.tokTag() == .comma) _ = p.nextToken();
        if (p.tokTag() == .question) _ = p.nextToken(); // 容错：`Foo<?T>`
    }
    _ = p.eatToken(.greater_than);
    return try p.addNodeList(args.items);
}

// ===========================================================================
// 测试：类型语法
// ===========================================================================

test "type :: 联合/交集/可空 :: 三种复合类型各自成节点" {
    const gpa = std.testing.allocator;
    var tree = try ast.Ast.parse(gpa,
        \\<?php
        \\function f(int|string $x, ?Foo\Bar &$y): A&B { return 1; }
    , testing.v84);
    defer tree.deinit(gpa);

    try testing.expectNoErrors(tree);
    try testing.expectTagCounts(tree, .{
        .type_union = 1,
        .type_nullable = 1,
        .type_intersection = 1,
    });
    // 名字类型恰为 5 个：int / string / Foo\Bar / A / B
    try std.testing.expectEqual(@as(usize, 5), testing.countTag(tree, .type_name));
}

test "type :: 可空前缀 :: ? 作用于其后整个类型" {
    const gpa = std.testing.allocator;
    var tree = try ast.Ast.parse(gpa, "<?php function f(?int $x) {}", testing.v84);
    defer tree.deinit(gpa);

    try testing.expectNoErrors(tree);
    try testing.expectTagCounts(tree, .{ .type_nullable = 1, .type_name = 1 });
}

test "type :: 伪类型 self/parent/static :: 产出专用节点而非名字类型" {
    const gpa = std.testing.allocator;
    var tree = try ast.Ast.parse(gpa,
        \\<?php
        \\function f(self $a, parent $b, static $c): callable {}
    , testing.v84);
    defer tree.deinit(gpa);

    try testing.expectNoErrors(tree);
    try testing.expectTagCounts(tree, .{
        .type_self = 1,
        .type_parent = 1,
        .type_static = 1,
    });
}

test "type :: 关键字类型 true/false/null :: 归入 type_name" {
    const gpa = std.testing.allocator;
    var tree = try ast.Ast.parse(gpa,
        \\<?php
        \\function f(): true {}
        \\function g(): false {}
        \\function h(): null {}
    , testing.v84);
    defer tree.deinit(gpa);

    try testing.expectNoErrors(tree);
    try testing.expectTagCounts(tree, .{ .type_name = 3, .name = 3 });
}

test "type :: 泛型 :: list<int> 与 Foo<string> 产出 type_generic" {
    const gpa = std.testing.allocator;
    var tree = try ast.Ast.parse(gpa,
        \\<?php
        \\function f(list<int> $a, Foo<string> $b) {}
    , testing.v84);
    defer tree.deinit(gpa);

    try testing.expectNoErrors(tree);
    try testing.expectTagCounts(tree, .{ .type_generic = 2 });
}

test "type :: 数组后缀 :: Foo[] 与多维 Foo[][] 逐层包裹" {
    const gpa = std.testing.allocator;
    var tree = try ast.Ast.parse(gpa,
        \\<?php
        \\function f(Foo[] $a, Bar[][] $b) {}
    , testing.v84);
    defer tree.deinit(gpa);

    try testing.expectNoErrors(tree);
    // Foo[] 一层、Bar[][] 两层
    try testing.expectTagCounts(tree, .{ .type_array_of = 3 });
}

test "type :: DNF 联合含括号交集 :: 括号不单独成节点" {
    const gpa = std.testing.allocator;
    var tree = try ast.Ast.parse(gpa,
        \\<?php
        \\function f((Countable&ArrayAccess)|int $x) {}
    , testing.v84);
    defer tree.deinit(gpa);

    try testing.expectNoErrors(tree);
    // 括号仅改变优先级，不引入节点（与 PHP-Parser 行为一致）
    try testing.expectTagCounts(tree, .{
        .type_union = 1,
        .type_intersection = 1,
    });
}

test "type :: 数组后缀主 token :: 指向 [ 而非内部类型" {
    // 回归：此前 main_token 取内部类型的（`(A&B)` 为 `&`），快照与区间都看不出
    // 数组后缀。注：`(`/`)` 分组 token 未记录，故区间不含括号是另一已知项。
    const gpa = std.testing.allocator;
    var tree = try ast.Ast.parse(gpa, "<?php function f((A&B)[] $x) {}", testing.v84);
    defer tree.deinit(gpa);
    try testing.expectNoErrors(tree);

    const arr = testing.firstNode(tree, .type_array_of) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("[", tree.tokenSlice(tree.nodeMainToken(arr)));
}

test "type :: DNF 交集叠加数组后缀 :: (A&B)[] 组合成节点" {
    const gpa = std.testing.allocator;
    var tree = try ast.Ast.parse(gpa,
        \\<?php
        \\function f((Countable&ArrayAccess)[] $x) {}
    , testing.v84);
    defer tree.deinit(gpa);

    try testing.expectNoErrors(tree);
    try testing.expectTagCounts(tree, .{
        .type_intersection = 1,
        .type_array_of = 1,
    });
}
