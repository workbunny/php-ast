//! 父链映射：一次遍历为树上每个节点建立 → parent 关系。
//!
//! 对齐 php-parser `NodeVisitor\ParentConnectingVisitor` 语义
//! （见 `reference/PHP-Parser-full-5.8.0/lib/PhpParser/NodeVisitor/ParentConnectingVisitor.php`）：
//! 其以 visitor 栈维护"当前栈顶即父"，在节点 attribute 上记 parent。SoA 形态下
//! 节点无法挂属性 → 产出**旁表** `ParentMap`（node → parent），下游经 `parentOf`
//! 查询，沿链可走到 `root`（root 的 parent 为 null）。
//!
//! 设计：一次显式栈 DFS（压栈时已知 parent，无需额外查找）；`build` 是纯增量
//! 旁表构建，不改动 AST、无每节点分配（复用单份栈缓冲）。
const std = @import("std");
const ast = @import("ast.zig");
const Ast = ast.Ast;
const Index = ast.Index;
const walk = @import("walk.zig");

/// 节点 → parent 的旁表。
pub const ParentMap = struct {
    gpa: std.mem.Allocator,
    /// 根节点（parent 为 null 的唯一点）。
    root: Index,
    /// node → parent（不含 root）。
    index: std.AutoHashMap(Index, Index),

    pub fn deinit(self: *ParentMap) void {
        self.index.deinit();
        self.* = undefined;
    }

    /// 取节点的父；`root` 返回 null。
    pub fn parentOf(self: ParentMap, node: Index) ?Index {
        return self.index.get(node);
    }

    /// 从 `node` 沿父链上行到根，把路径（含自身）追加到 `out`（自上而下：node, parent, ..., root）。
    pub fn chainToRoot(self: ParentMap, node: Index, out: *std.ArrayList(Index)) !void {
        var cur: ?Index = node;
        while (cur) |n| {
            try out.append(self.gpa, n);
            cur = self.index.get(n);
        }
    }
};

/// 构建整树（从 `root` 起）的父链映射。
pub fn build(gpa: std.mem.Allocator, tree: Ast, root: Index) !ParentMap {
    var map = std.AutoHashMap(Index, Index).init(gpa);
    errdefer map.deinit();

    var ws = try walk.WalkState.init(gpa);
    defer ws.deinit();
    var stack: std.ArrayList(?Index) = .empty;
    defer stack.deinit(gpa);

    ws.stack.clearRetainingCapacity();
    try ws.stack.append(gpa, root);
    try stack.append(gpa, null); // root 的 parent
    while (ws.stack.pop()) |node| {
        const parent = stack.pop().?;
        if (parent) |p| try map.put(node, p);
        ws.children.clearRetainingCapacity();
        try walk.childNodes(gpa, tree, node, &ws.children);
        var i: usize = ws.children.items.len;
        while (i > 0) : (i -= 1) {
            try ws.stack.append(gpa, ws.children.items[i - 1]);
            try stack.append(gpa, node);
        }
    }

    return .{ .gpa = gpa, .root = root, .index = map };
}

// ===========================================================================
// 测试
// ===========================================================================

const testing = @import("testing.zig");
const node_finder = @import("node_finder.zig");

test "parent_map :: build :: root 无父、非 root 沿链到根" {
    const gpa = std.testing.allocator;
    var tree = try ast.Ast.parse(gpa,
        \\<?php
        \\function f(int $x) { return $x + 1; }
        \\class C { public function m() { echo 1; } }
    , testing.v84);
    defer tree.deinit(gpa);
    try testing.expectNoErrors(tree);

    var map = try build(gpa, tree, tree.root);
    defer map.deinit();

    // root 无父
    try std.testing.expect(map.parentOf(tree.root) == null);

    // 任一 expr_int 的父链应能走到 root
    const lit = (try node_finder.findFirstTag(gpa, tree, tree.root, .expr_int)) orelse return error.TestUnexpectedResult;
    var chain: std.ArrayList(Index) = .empty;
    defer chain.deinit(gpa);
    try map.chainToRoot(lit, &chain);
    try std.testing.expect(chain.items.len >= 3); // lit → ... → root
    try std.testing.expectEqual(tree.root, chain.items[chain.items.len - 1]);

    // 相邻两节点关系正确：expr_binary 的左操作数 parent 是 expr_binary
    const bin = (try node_finder.findFirstTag(gpa, tree, tree.root, .expr_binary)) orelse return error.TestUnexpectedResult;
    const bin_parent = map.parentOf(bin);
    try std.testing.expect(bin_parent != null);
}

test "parent_map :: build :: 每节点恰一父（除 root）" {
    const gpa = std.testing.allocator;
    var tree = try ast.Ast.parse(gpa,
        \\<?php
        \\if ($a) { $b = fn() => $a + 1; } else { foo(2); }
    , testing.v84);
    defer tree.deinit(gpa);
    try testing.expectNoErrors(tree);

    var map = try build(gpa, tree, tree.root);
    defer map.deinit();

    // 每个非 root 节点都应有 parent
    const Ctx = struct {
        root: Index,
        map: *const ParentMap,
        missing: *usize,
        fn f(self: *@This(), _: Ast, node: Index) !void {
            if (node != self.root and self.map.parentOf(node) == null) self.missing.* += 1;
        }
    };
    var missing: usize = 0;
    var ws = try walk.WalkState.init(gpa);
    defer ws.deinit();
    var ctx = Ctx{ .root = tree.root, .map = &map, .missing = &missing };
    try walk.walkStack(tree, tree.root, &ws, &ctx, Ctx.f);
    try std.testing.expectEqual(@as(usize, 0), missing);
}
