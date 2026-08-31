const std = @import("std");
const ast = @import("ast.zig");
const testing = @import("testing.zig");

const Index = ast.Index;
const TokenIndex = ast.TokenIndex;

/// 枚举某节点的全部直接子节点（节点下标），追加到 `out`。
///
/// 子节点关系定义在 `Ast.forEachChild`（唯一事实来源），此处仅适配为「收集到
/// ArrayList」的形态，供需要物化子节点列表的场合使用。
pub fn childNodes(gpa: std.mem.Allocator, tree: ast.Ast, node: Index, out: *std.ArrayList(Index)) !void {
    const Ctx = struct {
        gpa: std.mem.Allocator,
        out: *std.ArrayList(Index),
        fn onChild(self: @This(), child: Index) !void {
            try self.out.append(self.gpa, child);
        }
    };
    try tree.forEachChild(node, Ctx{ .gpa = gpa, .out = out }, Ctx.onChild);
}

/// 深度优先遍历整棵树：从 `start` 出发，对每个访问到的节点调用 `visit(ctx, tree, node)`。
/// 顺序为前序（先节点本身，再其子节点）。`allocator` 仅用于遍历期间的临时栈。
///
/// ```zig
/// var count: usize = 0;
/// try php_ast.walk.walk(tree, tree.root, gpa, &count, struct {
///     fn f(c: *usize, _: php_ast.Ast, _: php_ast.Index) !void { c.* += 1; }
/// }.f);
/// ```
pub fn walk(
    tree: ast.Ast,
    start: Index,
    allocator: std.mem.Allocator,
    ctx: anytype,
    comptime visit: fn (@TypeOf(ctx), ast.Ast, Index) anyerror!void,
) !void {
    var stack = try std.ArrayList(Index).initCapacity(allocator, 0);
    defer stack.deinit(allocator);
    try stack.append(allocator, start);
    while (stack.pop()) |node| {
        try visit(ctx, tree, node);
        var children = try std.ArrayList(Index).initCapacity(allocator, 0);
        defer children.deinit(allocator);
        try childNodes(allocator, tree, node, &children);
        // 逆序压栈以保持前序遍历顺序
        var i: usize = children.items.len;
        while (i > 0) : (i -= 1) try stack.append(allocator, children.items[i - 1]);
    }
}

/// 可复用的遍历状态：预先持有「栈」与「子节点 scratch 缓冲」，使一次遍历只分配
/// 一次（预热后零分配），而非像 `walk` 那样每个节点都新建一份子节点缓冲。
///
/// 适合在同一进程里反复遍历多棵树、或对单棵大树做多次遍历的场景（如统计 + 改写两轮）。
pub const WalkState = struct {
    allocator: std.mem.Allocator,
    stack: std.ArrayList(Index),
    children: std.ArrayList(Index),

    /// 分配底层缓冲（容量从 0 起步，首次遍历时按需增长到能容纳最深节点的子节点数后稳定）。
    pub fn init(allocator: std.mem.Allocator) !WalkState {
        return .{
            .allocator = allocator,
            .stack = try std.ArrayList(Index).initCapacity(allocator, 0),
            .children = try std.ArrayList(Index).initCapacity(allocator, 0),
        };
    }

    pub fn deinit(self: *WalkState) void {
        self.stack.deinit(self.allocator);
        self.children.deinit(self.allocator);
    }
};

/// 深度优先前序遍历的「零每节点分配」变体：复用 `state` 持有的栈与子节点缓冲，
/// 不产生 `walk` 那样的每节点 `ArrayList` 分配。语义与 `walk` 完全一致（前序、栈内逆序压栈）。
///
/// ```zig
/// var ws = try php_ast.walk.WalkState.init(gpa);
/// defer ws.deinit();
/// var count: usize = 0;
/// try php_ast.walk.walkStack(tree, tree.root, &ws, &count, struct {
///     fn f(c: *usize, _: php_ast.Ast, _: php_ast.Index) !void { c.* += 1; }
/// }.f);
/// ```
pub fn walkStack(
    tree: ast.Ast,
    start: Index,
    state: *WalkState,
    ctx: anytype,
    comptime visit: fn (@TypeOf(ctx), ast.Ast, Index) anyerror!void,
) !void {
    state.stack.clearRetainingCapacity();
    try state.stack.append(state.allocator, start);
    while (state.stack.pop()) |node| {
        try visit(ctx, tree, node);
        state.children.clearRetainingCapacity();
        try childNodes(state.allocator, tree, node, &state.children);
        // 逆序压栈以保持前序遍历顺序
        var i: usize = state.children.items.len;
        while (i > 0) : (i -= 1) try state.stack.append(state.allocator, state.children.items[i - 1]);
    }
}

/// 取紧贴 `node` 之前、仅被注释/文档注释隔开的注释 token 列表（按源码顺序）。
/// 注释始终作为 token 保留，本函数按需向前扫描还原 `leading_comments`。
pub fn leadingComments(gpa: std.mem.Allocator, tree: ast.Ast, node: Index, out: *std.ArrayList(TokenIndex)) !void {
    const ft = tree.firstToken(node);
    if (ft == 0) return;
    var i = ft;
    while (i > 0) {
        i -= 1;
        const tg = tree.tokenTag(i);
        if (tg == .comment or tg == .doc_comment) {
            try out.append(gpa, i);
        } else break;
    }
    std.mem.reverse(TokenIndex, out.items);
}

/// 取紧贴 `node` 之后、仅被注释/文档注释隔开的注释 token 列表（按源码顺序）。
pub fn trailingComments(gpa: std.mem.Allocator, tree: ast.Ast, node: Index, out: *std.ArrayList(TokenIndex)) !void {
    const lt = tree.lastToken(node);
    var i = lt + 1;
    while (i < tree.tokens.len) : (i += 1) {
        const tg = tree.tokenTag(i);
        if (tg == .comment or tg == .doc_comment) {
            try out.append(gpa, i);
        } else break;
    }
}

// ===========================================================================
// 测试：树遍历与注释取回
// ===========================================================================

fn countVisit(c: *usize, _: ast.Ast, _: Index) !void {
    c.* += 1;
}

test "walk :: 前序遍历 :: 访问到树中每个节点且不重不漏" {
    const gpa = std.testing.allocator;
    var tree = try ast.Ast.parse(gpa,
        \\<?php
        \\function f(int $x) { return $x + 1; }
        \\class C { public int $y; }
    , testing.v84);
    defer tree.deinit(gpa);
    try testing.expectNoErrors(tree);

    var visited: usize = 0;
    try walk(tree, tree.root, gpa, &visited, countVisit);
    try std.testing.expectEqual(tree.nodes.len, visited);
}

test "walk :: walkStack 复用状态 :: 与 walk 产出完全一致" {
    const gpa = std.testing.allocator;
    var tree = try ast.Ast.parse(gpa,
        \\<?php
        \\function f(int $x) { return $x + 1; }
        \\class C { public int $y; }
    , testing.v84);
    defer tree.deinit(gpa);
    try testing.expectNoErrors(tree);

    var by_walk: usize = 0;
    try walk(tree, tree.root, gpa, &by_walk, countVisit);

    var ws = try WalkState.init(gpa);
    defer ws.deinit();
    var by_stack: usize = 0;
    try walkStack(tree, tree.root, &ws, &by_stack, countVisit);

    try std.testing.expectEqual(by_walk, by_stack);
}

test "walk :: arena 分配器 :: parse 与 walkStack 照常工作" {
    // 验证分配器可替换：全部分配进 arena，deinit 后整批回收。
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    var tree = try ast.Ast.parse(gpa,
        \\<?php
        \\function f(int $x) { return $x + 1; }
    , testing.v84);
    try testing.expectNoErrors(tree);

    var ws = try WalkState.init(gpa);
    defer ws.deinit();
    var visited: usize = 0;
    try walkStack(tree, tree.root, &ws, &visited, countVisit);
    try std.testing.expectEqual(tree.nodes.len, visited);
    // arena 下 tree.deinit 的释放为 no-op，真实回收发生在 arena.deinit()
    tree.deinit(gpa);
}

test "walk :: childNodes :: 二元表达式展开出两个操作数" {
    const gpa = std.testing.allocator;
    var tree = try ast.Ast.parse(gpa, "<?php $a + $b;", testing.v84);
    defer tree.deinit(gpa);
    try testing.expectNoErrors(tree);

    const bin = testing.firstNode(tree, .expr_binary) orelse return error.TestUnexpectedResult;
    var kids = try std.ArrayList(Index).initCapacity(gpa, 0);
    defer kids.deinit(gpa);
    try childNodes(gpa, tree, bin, &kids);

    try std.testing.expectEqual(@as(usize, 2), kids.items.len);
    try std.testing.expectEqual(.expr_variable, tree.nodeTag(kids.items[0]));
    try std.testing.expectEqual(.expr_variable, tree.nodeTag(kids.items[1]));
}

test "walk :: leadingComments :: 取回紧邻节点的 docblock" {
    const gpa = std.testing.allocator;
    var tree = try ast.Ast.parse(gpa,
        \\<?php
        \\/** doc */
        \\function f() {}
    , testing.v84);
    defer tree.deinit(gpa);
    try testing.expectNoErrors(tree);

    const fn_node = testing.firstNode(tree, .stmt_function) orelse return error.TestUnexpectedResult;
    var comments = try std.ArrayList(TokenIndex).initCapacity(gpa, 0);
    defer comments.deinit(gpa);
    try leadingComments(gpa, tree, fn_node, &comments);

    try std.testing.expectEqual(@as(usize, 1), comments.items.len);
    try std.testing.expectEqual(.doc_comment, tree.tokenTag(comments.items[0]));
}

test "walk :: trailingComments :: 取回节点之后的行尾注释" {
    const gpa = std.testing.allocator;
    // 注释紧跟在字面量 `1` 之后；以 expr_int 为主 token 便于定位其后位置。
    var tree = try ast.Ast.parse(gpa,
        \\<?php
        \\$a = 1 // 行尾注释
        \\;
    , testing.v84);
    defer tree.deinit(gpa);
    try testing.expectNoErrors(tree);

    const lit = testing.firstNode(tree, .expr_int) orelse return error.TestUnexpectedResult;
    var comments = try std.ArrayList(TokenIndex).initCapacity(gpa, 0);
    defer comments.deinit(gpa);
    try trailingComments(gpa, tree, lit, &comments);

    try std.testing.expectEqual(@as(usize, 1), comments.items.len);
    try std.testing.expectEqual(.comment, tree.tokenTag(comments.items[0]));
}
