//! 黄金快照测试：把 `tests/golden/**/*.php` 的解析结果与同名 `.txt` 逐字节比对。
//!
//! 与专用测试的分工：专用测试断言「某个具体性质」（有几个节点、区间到哪），
//! 快照则锁住**整棵树的结构**，一条断言覆盖全部细节，新增语法时补一个 fixture
//! 即可，无需手写大量断言。
//!
//! 快照不对就两种可能：解析行为变了（需确认是否有意），或行为正确、快照待更新。
//! 后者跑：
//!
//! ```bash
//! zig build test -- --update-golden
//! ```
//!
//! 更新后必须 `git diff` 复核，确认改动符合预期再提交——否则快照测试会退化成
//! 「把错误结果固化下来」。
const std = @import("std");
const ast = @import("ast.zig");
const dump = @import("dump.zig");
const testing = @import("testing.zig");

/// 由 `build.zig` 注入：`zig build test -Dupdate-golden` 时为 true。
/// 直接用环境变量不可靠（测试进程未必继承），故走 build option。
const UPDATE_GOLDEN = @import("golden_options").update_golden;

const GOLDEN_DIR = "tests/golden";

/// 快照比对不通过时的报错：打印期望与实际的差异片段。
const DiffError = error{
    SnapshotMismatch,
    SnapshotMissing,
};

test "golden :: 全部 fixture 与快照一致" {
    const gpa = std.testing.allocator;

    const io = std.testing.io;
    // 以 cwd 定位 fixture 目录，故 `zig build test` 需在项目根执行。
    var dir = std.Io.Dir.cwd().openDir(io, GOLDEN_DIR, .{ .iterate = true }) catch {
        // 不在项目根下运行时跳过，避免误报（专用测试不依赖 cwd）
        return;
    };
    defer dir.close(io);

    var checked: usize = 0;
    var walker = try dir.walk(gpa);
    defer walker.deinit();

    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.path, ".php")) continue;

        const php_path = try std.fs.path.join(gpa, &.{ GOLDEN_DIR, entry.path });
        defer gpa.free(php_path);
        const txt_path = try std.fmt.allocPrint(gpa, "{s}.txt", .{php_path[0 .. php_path.len - 4]});
        defer gpa.free(txt_path);

        checked += 1;
        try checkOne(gpa, io, php_path, txt_path);
    }

    if (checked == 0) {
        std.debug.print("\n未发现任何 golden fixture（目录: {s}）\n", .{GOLDEN_DIR});
        return error.TestUnexpectedResult;
    }
}

fn writeSnapshot(gpa: std.mem.Allocator, io: std.Io, path: []const u8, data: []const u8) !void {
    _ = gpa;
    var f = try std.Io.Dir.cwd().createFile(io, path, .{});
    defer f.close(io);
    var w = f.writer(io, &.{});
    try w.interface.writeAll(data);
    try w.interface.flush();
}

/// 读整个文件；按源码/快照均为 UTF-8 文本处理。
fn readFile(gpa: std.mem.Allocator, io: std.Io, path: []const u8) ![:0]u8 {
    return std.Io.Dir.cwd().readFileAllocOptions(
        io,
        path,
        gpa,
        std.Io.Limit.limited(std.math.maxInt(usize)),
        .@"1",
        0,
    );
}

/// 解析单个 fixture 并与快照比对。
fn checkOne(gpa: std.mem.Allocator, io: std.Io, php_path: []const u8, txt_path: []const u8) !void {
    const src = readFile(gpa, io, php_path) catch |e| {
        std.debug.print("\n读取 fixture 失败: {s} ({s})\n", .{ php_path, @errorName(e) });
        return error.TestUnexpectedResult;
    };
    defer gpa.free(src);

    var tree = try ast.Ast.parse(gpa, src, testing.v85);
    defer tree.deinit(gpa);

    var buf: std.Io.Writer.Allocating = .init(gpa);
    defer buf.deinit();

    if (tree.errors.len > 0) {
        // 诊断也写入快照，这样「引入新错误」同样会被比出来
        var ebuf: [256]u8 = undefined;
        try buf.writer.print("; {d} 条诊断\n", .{tree.errors.len});
        for (tree.errors) |e| {
            const msg = e.format(&tree, &ebuf);
            try buf.writer.print(";   {s}\n", .{msg});
        }
    }
    try dump.dumpTree(gpa, tree, &buf.writer);
    const got = buf.written();

    const want = readFile(gpa, io, txt_path) catch {
        if (UPDATE_GOLDEN) {
            try writeSnapshot(gpa, io, txt_path, got);
            std.debug.print("已生成快照: {s}\n", .{txt_path});
            return;
        }
        std.debug.print(
            "\n缺少快照文件: {s}\n请生成后提交（差异如下）\n{s}\n",
            .{ txt_path, got },
        );
        return error.TestUnexpectedResult;
    };
    defer gpa.free(want);

    if (!std.mem.eql(u8, want, got)) {
        if (UPDATE_GOLDEN) {
            try writeSnapshot(gpa, io, txt_path, got);
            std.debug.print("已更新快照: {s}\n", .{txt_path});
            return;
        }
        try reportDiff(gpa, php_path, want, got);
        return error.TestUnexpectedResult;
    }
}

/// 打印首个差异处的上下文，便于定位是结构变了还是缩进变了。
fn reportDiff(gpa: std.mem.Allocator, path: []const u8, want: []const u8, got: []const u8) !void {
    _ = gpa;
    std.debug.print("\n快照不一致: {s}\n", .{path});

    var want_it = std.mem.splitScalar(u8, want, '\n');
    var got_it = std.mem.splitScalar(u8, got, '\n');
    var line: usize = 0;
    var shown: usize = 0;
    while (shown < 20) : (line += 1) {
        const w = want_it.next() orelse "";
        const g = got_it.next() orelse "";
        if (!std.mem.eql(u8, w, g)) {
            std.debug.print("  第 {d} 行\n    期望: {s}\n    实际: {s}\n", .{ line + 1, w, g });
            shown += 1;
        }
        if (want_it.peek() == null and got_it.peek() == null) break;
    }
}

// ===========================================================================
// 测试：快照机制自身
// ===========================================================================

test "golden :: 快照文本随结构变化" {
    const gpa = std.testing.allocator;
    // 不同源码应产出不同快照
    var a: std.Io.Writer.Allocating = .init(gpa);
    defer a.deinit();
    {
        var t = try ast.Ast.parse(gpa, "<?php $a = 1;", testing.v84);
        defer t.deinit(gpa);
        try dump.dumpTree(gpa, t, &a.writer);
    }
    var b: std.Io.Writer.Allocating = .init(gpa);
    defer b.deinit();
    {
        var t = try ast.Ast.parse(gpa, "<?php $a = 2;", testing.v84);
        defer t.deinit(gpa);
        try dump.dumpTree(gpa, t, &b.writer);
    }
    try std.testing.expect(!std.mem.eql(u8, a.written(), b.written()));
}
