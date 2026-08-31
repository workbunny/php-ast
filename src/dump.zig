//! 把 AST 渲染为可读文本，用于调试与黄金快照比对。
//!
//! 输出形如：
//!
//! ```text
//! (root
//!   (stmt_expression `;`
//!     (expr_assign `=`
//!       (expr_variable `$a`)
//!       (expr_int `1`))))
//! ```
//!
//! 每个节点一行，缩进表示深度，反引号内是该节点主 token 的源码文本——用它而非
//! 完整区间，是因为后者在复合语句上会很长，反而淹没结构。
const std = @import("std");
const ast = @import("ast.zig");
const testing = @import("testing.zig");

const Index = ast.Index;

/// 渲染整棵树，从 `root` 开始。
pub fn dumpTree(gpa: std.mem.Allocator, tree: ast.Ast, w: anytype) !void {
    try dumpNode(gpa, tree, tree.root, 0, w);
}

/// 渲染以 `node` 为根的子树，`depth` 为起始缩进层级。
pub fn dumpNode(gpa: std.mem.Allocator, tree: ast.Ast, node: Index, depth: usize, w: anytype) !void {
    try writeIndent(w, depth);
    try w.print("({s}", .{@tagName(tree.nodeTag(node))});

    // 显示该节点覆盖的源码文本。限定名取完整区间（`Foo\Bar`），其余取主 token——
    // 复合语句的完整文本会很长，淹没结构。
    const ft = tree.firstToken(node);
    const lt = tree.lastToken(node);
    const is_name = switch (tree.nodeTag(node)) {
        .name, .name_fully_qualified, .name_relative, .name_var_like => true,
        else => false,
    };
    try w.writeAll(" `");
    if (is_name and ft < lt) {
        // 限定名是整体，按 [首 token 起点, 末 token 终点) 取完整文本
        const s = tree.tokens.items(.start)[ft];
        const e = tree.tokens.items(.start)[lt] + tree.tokenSlice(lt).len;
        try writeEscaped(w, tree.source[s..e]);
    } else {
        try writeEscaped(w, tree.tokenSlice(tree.nodeMainToken(node)));
    }
    try w.writeAll("`");

    // 声明类节点的 main_token 往往是关键字（`function`/`class`），不打印名字的话
    // 快照看不出名字是否解析正确——而名字错了往往不产生诊断，极易漏过。
    if (tree.nameToken(node)) |nt| {
        if (nt != tree.nodeMainToken(node)) {
            try w.writeAll(" name=`");
            try writeEscaped(w, tree.tokenSlice(nt));
            try w.writeAll("`");
        }
    }

    var kids: std.ArrayList(Index) = .empty;
    defer kids.deinit(gpa);
    var collect = Collect{ .gpa = gpa, .out = &kids };
    try tree.forEachChild(node, &collect, Collect.onChild);

    if (kids.items.len > 0) {
        try w.writeAll("\n");
        for (kids.items) |k| {
            try dumpNode(gpa, tree, k, depth + 1, w);
        }
        try writeIndent(w, depth);
    }
    try w.writeAll(")\n");
}

/// `forEachChild` 的适配器：分配器需显式持有，`ArrayList` 自身不带。
const Collect = struct {
    gpa: std.mem.Allocator,
    out: *std.ArrayList(Index),

    fn onChild(self: *@This(), child: Index) !void {
        try self.out.append(self.gpa, child);
    }
};

fn writeIndent(w: anytype, depth: usize) !void {
    for (0..depth) |_| try w.writeAll("  ");
}

/// 把文本中的换行/制表符转义，使每个节点只占一行。
fn writeEscaped(w: anytype, text: []const u8) !void {
    for (text) |c| {
        switch (c) {
            '\n' => try w.writeAll("\\n"),
            '\r' => try w.writeAll("\\r"),
            '\t' => try w.writeAll("\\t"),
            else => try w.writeByte(c),
        }
    }
}

// ===========================================================================
// 测试：渲染器
// ===========================================================================

test "dump :: 渲染 :: 嵌套结构按缩进展开" {
    const gpa = std.testing.allocator;
    var tree = try ast.Ast.parse(gpa, "<?php $a = 1;", testing.v84);
    defer tree.deinit(gpa);
    try testing.expectNoErrors(tree);

    var buf: std.Io.Writer.Allocating = .init(gpa);
    defer buf.deinit();
    try dumpTree(gpa, tree, &buf.writer);

    // 直接比对完整输出：结构、缩进、主 token 文本全在其中
    try std.testing.expectEqualStrings(
        \\(root `<?php`
        \\  (stmt_expression `=`
        \\    (expr_assign `=`
        \\      (expr_variable `$a`)
        \\      (expr_int `1`)
        \\    )
        \\  )
        \\)
        \\
    , buf.written());
}

test "dump :: 渲染 :: 特殊字符被转义为单行" {
    const gpa = std.testing.allocator;
    // 字符串字面量跨真实换行。若不转义，该节点的输出会断成两行，破坏
    // 「一节点一行」的结构约定。
    var tree = try ast.Ast.parse(gpa, "<?php \"a\nb\";", testing.v84);
    defer tree.deinit(gpa);
    try testing.expectNoErrors(tree);

    var buf: std.Io.Writer.Allocating = .init(gpa);
    defer buf.deinit();
    try dumpTree(gpa, tree, &buf.writer);

    try std.testing.expectEqualStrings(
        "(root `<?php`\n" ++
        "  (stmt_expression `\"`\n" ++
        "    (expr_encapsed `\"`\n" ++
        "      (expr_string_part `a\\nb`)\n" ++
        "    )\n" ++
        "  )\n" ++
        ")\n",
        buf.written(),
    );
}
