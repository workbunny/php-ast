//! 共享测试断言工具，供各源文件底部的 `test` 块以 `@import("testing.zig")` 引入。
//!
//! 对应 Zig 标准库中 `std.testing` 的角色：集中承载断言与测试辅助函数，
//! 消除各测试之间重复的手写计数/比较代码。
//!
//! **刻意不导入 `ast.zig`**：被测源文件的 `test` 块导入本模块，若本模块反向
//! 导入 `ast.zig` 会与 `ast.zig → parser.zig → parser_*.zig` 构成循环导入。
//! 因此本模块仅依赖 `std` 与 `version.zig`，节点类型一律通过 `anytype` +
//! comptime 推导，调用方无需为此分心。
//!
//! ```zig
//! var tree = try Ast.parse(gpa, "<?php $a = 1;", testing.v84);
//! defer tree.deinit(gpa);
//! try testing.expectNoErrors(tree);
//! try testing.expectTagCounts(tree, .{ .expr_assign = 1, .expr_int = 1 });
//! ```
const std = @import("std");
const PhpVersion = @import("version.zig").PhpVersion;

/// 常用目标版本常量，避免各测试散落 `.{ .id = 80400 }` 这类魔数。
pub const v80: PhpVersion = .{ .id = 80000 };
pub const v81: PhpVersion = .{ .id = 80100 };
pub const v82: PhpVersion = .{ .id = 80200 };
pub const v83: PhpVersion = .{ .id = 80300 };
pub const v84: PhpVersion = .{ .id = 80400 };
pub const v85: PhpVersion = .{ .id = 80500 };

/// 统计整棵树中某 tag 的出现次数。`tree` 可为 `Ast` 值或 `*Ast` / `*const Ast`。
///
/// 只回答「有没有」，不回答「挂在哪」——结构性断言请用
/// `expectTagCounts`（全树直方图）或黄金快照。
pub fn countTag(tree: anytype, tag: anytype) usize {
    var n: usize = 0;
    for (tree.nodes.items(.tag)) |t| {
        if (t == tag) n += 1;
    }
    return n;
}

/// 一次断言整棵树的 tag 直方图。
///
/// 相比逐条 `countTag(...) == 1`，本函数还要求**未列出的 tag 出现次数为 0**
/// 之外不做限制，但列出的每项必须精确相等；字段名拼错会在编译期报错，
/// 不会出现「断言了一个不存在的 tag 却悄然通过」。
///
/// ```zig
/// try testing.expectTagCounts(tree, .{ .expr_assign = 1, .expr_int = 1 });
/// ```
pub fn expectTagCounts(tree: anytype, expected: anytype) !void {
    // @TypeOf 仅取静态类型，不会求值 tree，故可安全用于运行时参数。
    const T = std.meta.Child(@TypeOf(tree.nodes.items(.tag)));
    inline for (@typeInfo(@TypeOf(expected)).@"struct".fields) |f| {
        const want: usize = @field(expected, f.name);
        const got = countTag(tree, @field(T, f.name));
        if (want != got) {
            std.debug.print("\n[{s}] 期望 {} 个，实际 {} 个\n", .{ f.name, want, got });
            try std.testing.expectEqual(want, got);
        }
    }
}

/// 断言解析未产生任何诊断；若产生则逐条打印可读文案后失败。
pub fn expectNoErrors(tree: anytype) !void {
    if (tree.errors.len == 0) return;
    std.debug.print("\n期望无解析错误，实际 {} 条：\n", .{tree.errors.len});
    var buf: [256]u8 = undefined;
    for (tree.errors) |e| {
        std.debug.print("  {s}\n", .{e.format(&tree, &buf)});
    }
    return error.TestUnexpectedResult;
}

/// 统计某类诊断的出现次数（负面测试用）。
pub fn countError(tree: anytype, tag: anytype) usize {
    var n: usize = 0;
    for (tree.errors) |e| {
        if (e.tag == tag) n += 1;
    }
    return n;
}

/// 取树中第一个匹配 `tag` 的节点下标，未找到返回 `null`。
///
/// 用于需要进一步检查某节点结构（子节点、`data`、源码切片）的场合，
/// 比「全树计数」更精确。
pub fn firstNode(tree: anytype, tag: anytype) ?@TypeOf(tree.root) {
    for (tree.nodes.items(.tag), 0..) |t, i| {
        if (t == tag) return @enumFromInt(i);
    }
    return null;
}

/// 断言某节点的主 token 能溯源回给定源码文本。
///
/// 这是对 `Ast.tokenSlice` 的直接校验：节点存的是 token 下标而非拷贝文本，
/// 溯源断了下游就无法做报错定位与代码改写。
pub fn expectSourceSlice(tree: anytype, node: anytype, want: []const u8) !void {
    const got = tree.tokenSlice(tree.nodeMainToken(node));
    try std.testing.expectEqualStrings(want, got);
}
