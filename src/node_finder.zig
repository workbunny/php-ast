//! 便捷查找：按谓词 / tag 收集节点，对齐 php-parser `NodeFinder` 语义
//! （见 `reference/PHP-Parser-full-5.8.0/lib/PhpParser/NodeFinder.php`）。
//!
//! php-parser 的 `NodeFinder` 依托 `NodeTraverser` + `FindingVisitor`/`FirstFindingVisitor`
//! （访客收集 / 短路）。SoA 形态：复用 `walk.WalkState` 做前序遍历（一次遍历一次分配），
//! `findFirst` 手写栈实现**短路**（命中即停，不会遍历完剩余树）。
//!
//! 对应关系：
//! - `findInstanceOf($n, X::class)` → `findTag(gpa, tree, root, .stmt_function, &out)`
//! - `find($n, fn($n)=>bool)`      → `find(gpa, tree, root, ctx, pred, &out)`
//! - `findFirstInstanceOf`          → `findFirstTag`
//! - `findFirst`                    → `findFirst`
const std = @import("std");
const ast = @import("ast.zig");
const Ast = ast.Ast;
const Index = ast.Index;
const walk = @import("walk.zig");

/// 收集全部满足谓词的节点（前序，含 `root` 自身）。
///
/// `pred(ctx, tree, node) bool`：返回 true 收集。`ctx` 可携带谓词需要的状态
/// （如外层符号表）。谓词返回 bool（非 error）——与 walk 回调形态不同，便于直接过滤。
pub fn find(
    gpa: std.mem.Allocator,
    tree: Ast,
    root: Index,
    ctx: anytype,
    comptime pred: fn (@TypeOf(ctx), Ast, Index) bool,
    out: *std.ArrayList(Index),
) !void {
    var ws = try walk.WalkState.init(gpa);
    defer ws.deinit();
    const Ctx = struct {
        gpa: std.mem.Allocator,
        inner: @TypeOf(ctx),
        out: *std.ArrayList(Index),
        fn f(self: *@This(), t: Ast, node: Index) !void {
            if (pred(self.inner, t, node)) try self.out.append(self.gpa, node);
        }
    };
    var c = Ctx{ .gpa = gpa, .inner = ctx, .out = out };
    try walk.walkStack(tree, root, &ws, &c, Ctx.f);
}

/// 收集全部 tag == `wanted` 的节点（`findInstanceOf` 的 SoA 等价——tag 过滤）。
pub fn findTag(
    gpa: std.mem.Allocator,
    tree: Ast,
    root: Index,
    wanted: ast.Node.Tag,
    out: *std.ArrayList(Index),
) !void {
    const Ctx = struct {
        wanted: ast.Node.Tag,
        fn pred(self: @This(), t: Ast, node: Index) bool {
            return t.nodeTag(node) == self.wanted;
        }
    };
    try find(gpa, tree, root, Ctx{ .wanted = wanted }, Ctx.pred, out);
}

/// 找第一个满足谓词的节点（短路：命中即停，不遍历剩余树）；无则 null。
pub fn findFirst(
    gpa: std.mem.Allocator,
    tree: Ast,
    root: Index,
    ctx: anytype,
    comptime pred: fn (@TypeOf(ctx), Ast, Index) bool,
) !?Index {
    var ws = try walk.WalkState.init(gpa);
    defer ws.deinit();
    ws.stack.clearRetainingCapacity();
    try ws.stack.append(gpa, root);
    while (ws.stack.pop()) |node| {
        if (pred(ctx, tree, node)) return node;
        ws.children.clearRetainingCapacity();
        try walk.childNodes(gpa, tree, node, &ws.children);
        var i: usize = ws.children.items.len;
        while (i > 0) : (i -= 1) try ws.stack.append(gpa, ws.children.items[i - 1]);
    }
    return null;
}

/// 找第一个 tag == `wanted` 的节点；无则 null。
pub fn findFirstTag(
    gpa: std.mem.Allocator,
    tree: Ast,
    root: Index,
    wanted: ast.Node.Tag,
) !?Index {
    const Ctx = struct {
        wanted: ast.Node.Tag,
        fn pred(self: @This(), t: Ast, node: Index) bool {
            return t.nodeTag(node) == self.wanted;
        }
    };
    return findFirst(gpa, tree, root, Ctx{ .wanted = wanted }, Ctx.pred);
}

// ===========================================================================
// 测试
// ===========================================================================

const testing = @import("testing.zig");

test "node_finder :: findTag :: 收集全部函数声明" {
    const gpa = std.testing.allocator;
    var tree = try ast.Ast.parse(gpa,
        \\<?php
        \\function a() {}
        \\$x = fn() => 1;
        \\function b() {}
    , testing.v84);
    defer tree.deinit(gpa);
    try testing.expectNoErrors(tree);

    var out: std.ArrayList(Index) = .empty;
    defer out.deinit(gpa);
    try findTag(gpa, tree, tree.root, .stmt_function, &out);
    try std.testing.expectEqual(@as(usize, 2), out.items.len);
}

test "node_finder :: findTag :: 从子树根开始（含 root 自身）" {
    const gpa = std.testing.allocator;
    var tree = try ast.Ast.parse(gpa, "<?php class C { public function m() {} }", testing.v84);
    defer tree.deinit(gpa);
    try testing.expectNoErrors(tree);

    const cls = (try findFirstTag(gpa, tree, tree.root, .stmt_class)) orelse return error.TestUnexpectedResult;
    var out: std.ArrayList(Index) = .empty;
    defer out.deinit(gpa);
    // 类方法 tag 为 stmt_method（非 stmt_function）
    try findTag(gpa, tree, cls, .stmt_method, &out);
    try std.testing.expectEqual(@as(usize, 1), out.items.len);
}

test "node_finder :: findFirstTag :: 短路命中" {
    const gpa = std.testing.allocator;
    var tree = try ast.Ast.parse(gpa, "<?php $a = 1; $b = 2; function f() {}", testing.v84);
    defer tree.deinit(gpa);
    try testing.expectNoErrors(tree);

    const fn_node = (try findFirstTag(gpa, tree, tree.root, .stmt_function)) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(.stmt_function, tree.nodeTag(fn_node));
}

test "node_finder :: findFirstTag :: 不存在返回 null" {
    const gpa = std.testing.allocator;
    var tree = try ast.Ast.parse(gpa, "<?php $a = 1;", testing.v84);
    defer tree.deinit(gpa);
    try testing.expectNoErrors(tree);

    const got = try findFirstTag(gpa, tree, tree.root, .stmt_class);
    try std.testing.expect(got == null);
}

test "node_finder :: find :: 通用谓词（带 ctx 状态过滤）" {
    const gpa = std.testing.allocator;
    var tree = try ast.Ast.parse(gpa,
        \\<?php
        \\foo();
        \\$x = 1;
        \\foo();
    , testing.v84);
    defer tree.deinit(gpa);
    try testing.expectNoErrors(tree);

    // 谓词：找函数名文本为 "foo" 的 expr_func_call（func_call 主 token 即函数名）。
    const Ctx = struct {
        fn pred(_: @This(), t: Ast, node: Index) bool {
            if (t.nodeTag(node) != .expr_func_call) return false;
            return std.mem.eql(u8, t.tokenSlice(t.nodeMainToken(node)), "foo");
        }
    };
    var out: std.ArrayList(Index) = .empty;
    defer out.deinit(gpa);
    try find(gpa, tree, tree.root, Ctx{}, Ctx.pred, &out);
    try std.testing.expectEqual(@as(usize, 2), out.items.len);
}
