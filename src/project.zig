//! 目录级能力：扫描目录、批量解析 `.php` 文件、组织为多文件森林。
//!
//! `Ast.parse` 只处理单个源码字符串；本模块在其上叠加「目录 → 项目」的能力：
//! - `loadDir` 递归收集目录下全部 `.php` 文件（跳过其他类型），逐个解析；
//! - 产物 `ProjectAst` 以**森林**形式保存（每文件一棵 `Ast`，文件边界天然保留），
//!   同时提供跨文件的顶层语句视图（`rootStmts`），供下游做整包分析时按文件定位节点。
//!
//! 设计要点：
//! - **文件排序**：按路径字典序解析存储，输出确定、可复现（黄金快照友好）。
//! - **源码自有**：`loadDir` 从文件读出源码（`[:0]const u8`，`Ast.parse` 需要），
//!   `ProjectAst` 拥有每文件的源码与路径，`deinit` 统一释放。
//! - **森林而非大树**：不合并节点索引（合并需对全部 `data` 引用做索引重映射，
//!   复杂度高且易错）；保留每文件独立索引，`TopStmt` 携带文件下标实现跨文件定位。
const std = @import("std");
const Ast = @import("ast.zig").Ast;
const Index = @import("ast.zig").Index;
const PhpVersion = @import("version.zig").PhpVersion;

/// 跨文件顶层语句视图的一项：`file` 为文件下标，`stmt` 为该文件内顶层语句的节点下标。
pub const TopStmt = struct {
    file: usize,
    stmt: Index,
};

/// 一个已解析的 PHP 文件。
pub const ProjectFile = struct {
    /// 相对 `ProjectAst.root_path` 的路径（排序依据）。
    path: []const u8,
    /// 文件源码（`ProjectAst` 拥有，`deinit` 释放）。
    source: [:0]const u8,
    /// 该文件的单文件 AST（`source` 由本结构持有，`Ast` 借用）。
    ast: Ast,
};

/// 目录加载的产物：多文件 AST 森林 + 跨文件顶层语句视图。
pub const ProjectAst = struct {
    /// 目标目录路径。
    root_path: []const u8,
    /// 统一应用于全部文件的目标 PHP 版本。
    version: PhpVersion,
    /// 文件森林，按路径字典序排序（确定性）。
    files: []ProjectFile,
    /// 跨文件顶层语句视图（顺序：文件序 × 文件内语句序）。
    top_stmts: []TopStmt,

    /// 释放全部文件（AST、源码、路径）与视图。必须传入与 `loadDir` 相同的 `gpa`。
    pub fn deinit(self: *ProjectAst, gpa: std.mem.Allocator) void {
        for (self.files) |*f| {
            f.ast.deinit(gpa);
            gpa.free(f.source);
            gpa.free(f.path);
        }
        gpa.free(self.files);
        gpa.free(self.top_stmts);
        gpa.free(self.root_path);
        self.* = undefined;
    }

    pub fn fileCount(self: ProjectAst) usize {
        return self.files.len;
    }

    pub fn fileAt(self: ProjectAst, i: usize) ProjectFile {
        return self.files[i];
    }

    /// 取某文件的相对路径（相对 `root_path`）。
    pub fn filePath(self: ProjectAst, i: usize) []const u8 {
        return self.files[i].path;
    }

    pub fn fileAst(self: ProjectAst, i: usize) *const Ast {
        return &self.files[i].ast;
    }

    /// 跨文件顶层语句视图（直接遍历入口）。
    pub fn rootStmts(self: ProjectAst) []const TopStmt {
        return self.top_stmts;
    }
};

/// 递归收集目录下全部 `.php` 文件的相对路径，追加到 `out`。
/// 路径分隔符由 `std.fs.path.join` 按当前 OS 生成。
fn collectPhpFiles(
    gpa: std.mem.Allocator,
    io: std.Io,
    dir: std.Io.Dir,
    sub: []const u8,
    out: *std.ArrayList([]const u8),
) !void {
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        switch (entry.kind) {
            .directory => {
                var sub_dir = try dir.openDir(io, entry.name, .{ .iterate = true });
                defer sub_dir.close(io);
                const child = try std.fs.path.join(gpa, &.{ sub, entry.name });
                defer gpa.free(child);
                try collectPhpFiles(gpa, io, sub_dir, child, out);
            },
            .file => {
                if (!std.mem.endsWith(u8, entry.name, ".php")) continue;
                const p = try std.fs.path.join(gpa, &.{ sub, entry.name });
                try out.append(gpa, p);
            },
            else => {},
        }
    }
}

/// 路径字典序（排序用，保证输出确定性）。
fn lessThanPath(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

/// 读取文件内容为 `[:0]const u8`（`Ast.parse` 要求 0 结尾）。
fn readSource(gpa: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, rel: []const u8) ![:0]const u8 {
    return dir.readFileAllocOptions(
        io,
        rel,
        gpa,
        std.Io.Limit.limited(std.math.maxInt(usize)),
        .@"1",
        0,
    );
}

/// 解析单个文件为 `ProjectFile`；失败时释放本文件已分配的资源。
fn loadOneFile(
    gpa: std.mem.Allocator,
    io: std.Io,
    dir: std.Io.Dir,
    rel: []const u8,
    version: PhpVersion,
) !ProjectFile {
    const source = try readSource(gpa, io, dir, rel);
    errdefer gpa.free(source);
    var ast = try Ast.parse(gpa, source, version);
    errdefer ast.deinit(gpa);
    const path = try gpa.dupe(u8, rel);
    errdefer gpa.free(path);
    return .{ .path = path, .source = source, .ast = ast };
}

/// 扫描目录并解析其中全部 `.php` 文件（递归、跳过其他类型），返回多文件森林。
///
/// `io` 为 Zig 0.16 显式 I/O 上下文（测试传 `std.testing.io`；生产代码经
/// `std.Io.Threaded.init` 等获得）。失败仅因 IO（目录不存在/读文件失败）或内存不足；
/// 单个文件的**语法**错误不中断，收集进对应 `Ast.errors`（与 `Ast.parse` 语义一致）。
/// 用毕调用 `ProjectAst.deinit`。
///
/// ```zig
/// var project = try php_ast.loadDir(gpa, io, "src/", .{ .id = 80500 });
/// defer project.deinit(gpa);
/// for (project.rootStmts()) |top| {
///     // top.file 为文件下标，top.stmt 为顶层语句节点
/// }
/// ```
pub fn loadDir(
    gpa: std.mem.Allocator,
    io: std.Io,
    dir_path: []const u8,
    version: PhpVersion,
) !ProjectAst {
    var dir = try std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true });
    defer dir.close(io);

    // 1. 递归收集全部 `.php` 相对路径，排序保证确定性输出。
    var rel_paths: std.ArrayList([]const u8) = .empty;
    defer {
        for (rel_paths.items) |p| gpa.free(p);
        rel_paths.deinit(gpa);
    }
    try collectPhpFiles(gpa, io, dir, "", &rel_paths);
    std.mem.sort([]const u8, rel_paths.items, {}, lessThanPath);

    // 2. 逐文件解析为森林；失败时只释放已解析部分（parsed_count 追踪进度）。
    const all_files = try gpa.alloc(ProjectFile, rel_paths.items.len);
    var parsed_count: usize = 0;
    errdefer {
        for (all_files[0..parsed_count]) |*f| {
            f.ast.deinit(gpa);
            gpa.free(f.source);
            gpa.free(f.path);
        }
        gpa.free(all_files);
    }
    for (rel_paths.items) |rel| {
        all_files[parsed_count] = try loadOneFile(gpa, io, dir, rel, version);
        parsed_count += 1;
    }

    // 3. 构建跨文件顶层语句视图（文件序 × 文件内语句序）。
    var top_count: usize = 0;
    for (all_files) |f| top_count += f.ast.rootStmts().len;
    const all_top = try gpa.alloc(TopStmt, top_count);
    errdefer gpa.free(all_top);
    var k: usize = 0;
    for (all_files, 0..) |f, i| {
        for (f.ast.rootStmts()) |stmt| {
            all_top[k] = .{ .file = i, .stmt = stmt };
            k += 1;
        }
    }

    const root = try gpa.dupe(u8, dir_path);
    errdefer gpa.free(root);

    return .{
        .root_path = root,
        .version = version,
        .files = all_files,
        .top_stmts = all_top,
    };
}

// ===========================================================================
// 测试
// ===========================================================================

const testing = @import("testing.zig");

test "project :: loadDir :: 递归收集 .php 并解析（跳过其他类型）" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    const gpa = std.testing.allocator;

    try tmp.dir.writeFile(io, .{ .sub_path = "a.php", .data = "<?php $a = 1;" });
    try tmp.dir.createDirPath(io, "lib");
    try tmp.dir.writeFile(io, .{ .sub_path = "lib/b.php", .data = "<?php function f() { return 2; }" });
    try tmp.dir.writeFile(io, .{ .sub_path = "ignore.txt", .data = "not php" });

    const tmp_path = try std.fs.path.join(gpa, &.{ ".zig-cache", "tmp", tmp.sub_path[0..] });
    defer gpa.free(tmp_path);

    var project = try loadDir(gpa, io, tmp_path, testing.v84);
    defer project.deinit(gpa);

    // 只收集 .php，忽略 .txt；排序后 a.php 在前
    try std.testing.expectEqual(@as(usize, 2), project.fileCount());
    try std.testing.expectEqualStrings("a.php", project.filePath(0));
    try std.testing.expect(std.mem.endsWith(u8, project.filePath(1), "b.php"));

    // 每个文件解析无语法错误
    try testing.expectNoErrors(project.fileAt(0).ast);
    try testing.expectNoErrors(project.fileAt(1).ast);

    // 跨文件顶层语句视图：a.php 的 $a = 1 与 b.php 的 function 声明各一条
    const top = project.rootStmts();
    try std.testing.expectEqual(@as(usize, 2), top.len);
    try std.testing.expectEqual(@as(usize, 0), top[0].file);
    try std.testing.expectEqual(@as(usize, 1), top[1].file);
}

test "project :: loadDir :: 空目录返回零文件" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    const gpa = std.testing.allocator;

    const tmp_path = try std.fs.path.join(gpa, &.{ ".zig-cache", "tmp", tmp.sub_path[0..] });
    defer gpa.free(tmp_path);

    var project = try loadDir(gpa, io, tmp_path, testing.v84);
    defer project.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 0), project.fileCount());
    try std.testing.expectEqual(@as(usize, 0), project.rootStmts().len);
}

test "project :: loadDir :: 目录不存在报错" {
    try std.testing.expectError(
        error.FileNotFound,
        loadDir(std.testing.allocator, std.testing.io, "definitely-not-exist-dir-xyz-12345", testing.v84),
    );
}

test "project :: loadDir :: 每个文件独立 AST 可溯源源码" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    const gpa = std.testing.allocator;

    try tmp.dir.writeFile(io, .{ .sub_path = "x.php", .data = "<?php echo 'hi';" });

    const tmp_path = try std.fs.path.join(gpa, &.{ ".zig-cache", "tmp", tmp.sub_path[0..] });
    defer gpa.free(tmp_path);

    var project = try loadDir(gpa, io, tmp_path, testing.v84);
    defer project.deinit(gpa);

    // 顶层语句的主 token 应能溯源回该文件源码
    const top = project.rootStmts();
    try std.testing.expectEqual(@as(usize, 1), top.len);
    const ast = project.fileAt(top[0].file).ast;
    const slice = ast.tokenSlice(ast.nodeMainToken(top[0].stmt));
    try std.testing.expectEqualStrings("echo", slice);
}
