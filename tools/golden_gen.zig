//! fixture → 黄金快照迁移工具：把 PHP-Parser 测试用例的代码段导出为
//! `tests/golden/parser/**/*.php`，再由 `zig build test -Dupdate-golden` 生成同名
//! `*.txt` 快照（结构与诊断逐字节锁定）。此后整库行为的回归由这批快照兜住。
//!
//! PHP-Parser 是**开发期参照**而非构建依赖：未提供路径时本工具直接成功退出，
//! 下游 clone 不会因缺少参照而失败。迁入源码的来源与许可见 `NOTICE.md`。
//!
//! 用法（仓库根）：
//!   zig build golden-gen -- --php-parser <PHP-Parser 仓库根或 test/code/parser>
//!                           [--out <目录>]   默认 tests/golden/parser
//!                           [--prune]        删除迁移源已不存在的旧快照（.php 与 .txt）
//! 幂等：重复运行按当前迁移源覆盖 `.php`；`.txt` 只由 `-Dupdate-golden` 生成。
//!
//! `.test` 段格式见 `tools/fixtures.zig`。

const std = @import("std");
const fixtures = @import("fixtures.zig");

/// 默认输出根目录（相对仓库根）。
const DEFAULT_OUT_DIR = "tests/golden/parser";

fn usage() void {
    std.debug.print(
        \\用法: --php-parser <PHP-Parser 仓库根或 test/code/parser> [--out <目录>] [--prune]
        \\  未提供 --php-parser 时跳过（该参数是本工具唯一的迁移源）。
        \\
    , .{});
}

pub fn main(init: std.process.Init) !void {
    const gpa = std.heap.page_allocator;
    const io = init.io;
    const cwd = std.Io.Dir.cwd();

    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(gpa);
    var it = try std.process.Args.Iterator.initAllocator(init.minimal.args, gpa);
    defer it.deinit();
    while (it.next()) |a| try argv.append(gpa, try gpa.dupe(u8, a));
    defer {
        for (argv.items) |a| gpa.free(a);
    }

    var parser_arg: ?[]const u8 = null;
    var out_dir: []const u8 = DEFAULT_OUT_DIR;
    var prune = false;

    var i: usize = 1;
    while (i < argv.items.len) : (i += 1) {
        const a = argv.items[i];
        if (std.mem.eql(u8, a, "--php-parser")) {
            i += 1;
            if (i >= argv.items.len) {
                usage();
                return error.InvalidArgs;
            }
            parser_arg = argv.items[i];
        } else if (std.mem.eql(u8, a, "--out")) {
            i += 1;
            if (i >= argv.items.len) {
                usage();
                return error.InvalidArgs;
            }
            out_dir = argv.items[i];
        } else if (std.mem.eql(u8, a, "--prune")) {
            prune = true;
        } else if (std.mem.eql(u8, a, "-h") or std.mem.eql(u8, a, "--help")) {
            usage();
            return;
        } else {
            std.debug.print("未知参数: {s}\n", .{a});
            usage();
            return error.InvalidArgs;
        }
    }

    const raw = parser_arg orelse {
        std.debug.print("未提供 --php-parser：本工具以 PHP-Parser 为迁移源，跳过。\n", .{});
        usage();
        return;
    };
    const parser_dir = fixtures.resolveParserDir(gpa, io, raw) catch {
        std.debug.print("找不到 PHP-Parser 测试用例目录: {s}\n", .{raw});
        return error.ParserDirNotFound;
    };
    defer gpa.free(parser_dir);

    const rels = try fixtures.collectTestFiles(gpa, io, parser_dir);
    defer {
        for (rels) |r| gpa.free(r);
        gpa.free(rels);
    }

    try cwd.createDirPath(io, out_dir);

    // 本次写出的相对路径集合：`--prune` 依此清理失效旧文件
    var keep: std.StringHashMap(void) = .init(gpa);
    defer keep.deinit();

    var n_php: usize = 0;
    var n_tests: usize = 0;
    for (rels) |rel| {
        const full = try std.fs.path.join(gpa, &.{ parser_dir, rel });
        defer gpa.free(full);
        const flat = fixtures.readTestFlat(gpa, io, full) catch |e| {
            std.debug.print("读取失败 {s}: {s}\n", .{ rel, @errorName(e) });
            continue;
        };
        defer gpa.free(flat);

        const parsed = try fixtures.parse(gpa, flat);
        defer gpa.free(parsed.segments);

        // 输出子目录沿用迁移源的相对路径（去掉 `.test` 后缀）
        const stem = rel[0 .. rel.len - ".test".len];
        const sub = std.fs.path.dirname(stem) orelse "";
        const base = std.fs.path.basename(stem);
        const out_sub = try std.fs.path.join(gpa, &.{ out_dir, sub });
        defer gpa.free(out_sub);
        try cwd.createDirPath(io, out_sub);

        var touched = false;
        for (parsed.segments) |seg| {
            const expanded = try fixtures.expandAtAt(gpa, seg.code);
            defer gpa.free(expanded);
            // 以换行收尾：避免 heredoc / `?>` 段落在文件末尾无换行时语义歧义
            const src = try std.fmt.allocPrint(gpa, "{s}\n", .{expanded});
            defer gpa.free(src);

            const name = try std.fmt.allocPrint(gpa, "{s}_{d}.php", .{ base, seg.index });
            defer gpa.free(name);
            const out_path = try std.fs.path.join(gpa, &.{ out_sub, name });
            defer gpa.free(out_path);

            try cwd.writeFile(io, .{ .sub_path = out_path, .data = src });
            try keep.put(try gpa.dupe(u8, out_path), {});
            n_php += 1;
            touched = true;
        }
        if (touched) n_tests += 1;
    }

    std.debug.print(
        "已导出 {d} 段源码到 {s}（覆盖 {d} 个 .test）\n" ++
            "下一步：zig build test -Dupdate-golden 生成 *.txt 快照，并复核 git diff\n",
        .{ n_php, out_dir, n_tests },
    );

    if (prune) try pruneStale(gpa, io, out_dir, &keep);
}

/// 删除输出目录下本次未被写出的快照文件（`.php` 及其伴随 `.txt`）。
fn pruneStale(
    gpa: std.mem.Allocator,
    io: std.Io,
    out_dir: []const u8,
    keep: *const std.StringHashMap(void),
) !void {
    const cwd = std.Io.Dir.cwd();
    var dir = cwd.openDir(io, out_dir, .{ .iterate = true }) catch return;
    defer dir.close(io);
    var walker = try dir.walk(gpa);
    defer walker.deinit();

    var victims: std.ArrayList([]const u8) = .empty;
    defer {
        for (victims.items) |v| gpa.free(v);
        victims.deinit(gpa);
    }
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.path, ".php")) continue;
        const full = try std.fs.path.join(gpa, &.{ out_dir, entry.path });
        defer gpa.free(full);
        if (keep.contains(full)) continue;
        try victims.append(gpa, try gpa.dupe(u8, full));
    }

    var n: usize = 0;
    for (victims.items) |v| {
        cwd.deleteFile(io, v) catch continue;
        n += 1;
        const txt = try std.fmt.allocPrint(gpa, "{s}.txt", .{v[0 .. v.len - 4]});
        defer gpa.free(txt);
        cwd.deleteFile(io, txt) catch {};
    }
    if (n > 0) std.debug.print("已清理 {d} 个失效快照（--prune）\n", .{n});
}
