//! 内存 / 分配测量工具：把解析过程包在统计型 allocator 里，报告每个输入文件的
//! 分配次数、累计分配字节、峰值驻留（live 字节峰值）与解析后驻留（AST 实占）。
//!
//! 与 `test` 的分工：测试判对错，本工具只出数字——用于观察解析的内存开销与临时
//! 缓冲规模（峰值 − 驻留 ≈ 临时缓冲），为优化留基线。**不对解析速度作结论**：那需要
//! 与参照实现的稳定基准，属另一件事。
//!
//! 用法（仓库根）：
//!   zig build measure                     # 扫 tests/golden/**，按峰值列前 10 + 合计
//!   zig build measure -- --all            # 全部逐条列出
//!   zig build measure -- <file.php>...    # 只测指定文件
//!
//! 无外部依赖（不需要 PHP-Parser 参照）。测量建议配 `-Doptimize=ReleaseFast`：
//! Debug 下的分配器与内联策略与发布构建不同，绝对值仅供横向比较同一模式内的差异。

const std = @import("std");
const ast = @import("ast");

/// 解析目标版本：与黄金快照一致（`testing.v85`），便于和快照口径对齐。
const TARGET_VERSION_ID: u32 = 80500;

/// 默认扫的语料根目录（相对仓库根）。
const GOLDEN_DIR = "tests/golden";

/// 默认列出条数（按峰值驻留降序）；`--all` 时全部列出。
const DEFAULT_TOP = 10;

/// 统计型 allocator：把每次分配/释放折算成次数、累计字节与 live 峰值。
///
/// 只做计量，不改变语义——所有调用原样转发给 `child`（`rawAlloc`/`rawResize`/
/// `rawRemap`/`rawFree`），故 1 字节的重排都不介入解析行为。
const CountingAllocator = struct {
    child: std.mem.Allocator,
    allocations: usize = 0,
    deallocations: usize = 0,
    allocated_bytes: usize = 0,
    freed_bytes: usize = 0,
    live_bytes: usize = 0,
    peak_live_bytes: usize = 0,

    fn allocator(self: *CountingAllocator) std.mem.Allocator {
        return .{
            .ptr = self,
            .vtable = &.{
                .alloc = alloc,
                .resize = resize,
                .remap = remap,
                .free = free,
            },
        };
    }

    /// 计入一次「变大」：累计分配、live、峰值三者同步推进。
    fn noteGrow(self: *CountingAllocator, delta: usize) void {
        self.allocated_bytes += delta;
        self.live_bytes += delta;
        if (self.live_bytes > self.peak_live_bytes) self.peak_live_bytes = self.live_bytes;
    }

    /// 计入一次「变小」：只回落 live（累计分配是历史量，不回退）。
    fn noteShrink(self: *CountingAllocator, delta: usize) void {
        self.freed_bytes += delta;
        self.live_bytes -= delta;
    }

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ra: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        const p = self.child.rawAlloc(len, alignment, ra) orelse return null;
        self.allocations += 1;
        self.noteGrow(len);
        return p;
    }

    fn resize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ra: usize) bool {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        if (!self.child.rawResize(memory, alignment, new_len, ra)) return false;
        if (new_len > memory.len) self.noteGrow(new_len - memory.len) else self.noteShrink(memory.len - new_len);
        return true;
    }

    fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ra: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        const p = self.child.rawRemap(memory, alignment, new_len, ra) orelse return null;
        if (new_len > memory.len) self.noteGrow(new_len - memory.len) else self.noteShrink(memory.len - new_len);
        return p;
    }

    fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ra: usize) void {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        self.child.rawFree(memory, alignment, ra);
        self.deallocations += 1;
        self.noteShrink(memory.len);
    }
};

/// 单次测量的结果。
const Sample = struct {
    path: []const u8,
    source_bytes: usize,
    allocations: usize,
    allocated_bytes: usize,
    peak_live_bytes: usize,
    resident_bytes: usize,
};

/// 把字节数渲染成便于阅读的 `12.3 KB` 形式；小于 1 KB 显示字节。
fn fmtBytes(buf: []u8, n: usize) []const u8 {
    if (n < 1024) return std.fmt.bufPrint(buf, "{d} B", .{n}) catch "?";
    if (n < 1024 * 1024) {
        return std.fmt.bufPrint(buf, "{d:.1} KB", .{@as(f64, @floatFromInt(n)) / 1024.0}) catch "?";
    }
    return std.fmt.bufPrint(buf, "{d:.2} MB", .{@as(f64, @floatFromInt(n)) / (1024.0 * 1024.0)}) catch "?";
}

/// 测量单个源码：解析一次，报告分配与驻留。解析失败仍返回样本（含失败时的部分计量），
/// 由调用方决定如何呈现——本工具不判对错。
fn measure(
    gpa: std.mem.Allocator,
    path: []const u8,
    source: [:0]const u8,
) !Sample {
    var counter = CountingAllocator{ .child = gpa };
    const alloc = counter.allocator();

    var tree = try ast.Ast.parse(alloc, source, .{ .id = TARGET_VERSION_ID });
    // 驻留取 `deinit` 前：此刻临时缓冲已释放，live 即 AST 自身占用。
    const resident = counter.live_bytes;
    tree.deinit(alloc);

    return .{
        .path = path,
        .source_bytes = source.len,
        .allocations = counter.allocations,
        .allocated_bytes = counter.allocated_bytes,
        .peak_live_bytes = counter.peak_live_bytes,
        .resident_bytes = resident,
    };
}

fn printHeader() void {
    std.debug.print("{s:<46} {s:>9} {s:>8} {s:>11} {s:>11} {s:>11}\n", .{
        "文件",
        "源码",
        "分配次数",
        "累计分配",
        "峰值驻留",
        "解析后驻留",
    });
}

fn printRow(s: Sample) void {
    var b1: [24]u8 = undefined;
    var b2: [24]u8 = undefined;
    var b3: [24]u8 = undefined;
    var b4: [24]u8 = undefined;
    // 路径取末两段，避免超长列宽
    const short = blk: {
        var it = std.mem.splitBackwardsScalar(u8, s.path, '/');
        const last = it.next() orelse s.path;
        const prev = it.next() orelse break :blk last;
        break :blk s.path[s.path.len - last.len - prev.len - 1 ..];
    };
    std.debug.print("{s:<46} {s:>9} {d:>8} {s:>11} {s:>11} {s:>11}\n", .{
        short,
        fmtBytes(&b1, s.source_bytes),
        s.allocations,
        fmtBytes(&b2, s.allocated_bytes),
        fmtBytes(&b3, s.peak_live_bytes),
        fmtBytes(&b4, s.resident_bytes),
    });
}

fn usage() void {
    std.debug.print(
        \\用法: [--all] [<file.php>...]
        \\  无参数时扫 {s} 下全部 .php，按峰值驻留列前 {d} + 合计；`--all` 列全部。
        \\
    , .{ GOLDEN_DIR, DEFAULT_TOP });
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
    defer for (argv.items) |a| gpa.free(a);

    if (argv.items.len > 1 and (std.mem.eql(u8, argv.items[1], "-h") or std.mem.eql(u8, argv.items[1], "--help"))) {
        usage();
        return;
    }

    var show_all = false;
    var files: std.ArrayList([]const u8) = .empty;
    defer files.deinit(gpa);
    for (argv.items[1..]) |a| {
        if (std.mem.eql(u8, a, "--all")) {
            show_all = true;
        } else if (a.len > 0 and a[0] == '-') {
            std.debug.print("未知选项: {s}\n", .{a});
            usage();
            return error.InvalidArgument;
        } else {
            try files.append(gpa, a);
        }
    }

    // 无位置参数时扫描默认语料
    if (files.items.len == 0) {
        var dir = cwd.openDir(io, GOLDEN_DIR, .{ .iterate = true }) catch {
            std.debug.print("找不到语料目录 {s}（请在仓库根运行）\n", .{GOLDEN_DIR});
            return error.GoldenDirNotFound;
        };
        defer dir.close(io);
        var walker = try dir.walk(gpa);
        defer walker.deinit();
        while (try walker.next(io)) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.endsWith(u8, entry.path, ".php")) continue;
            try files.append(gpa, try std.fmt.allocPrint(gpa, "{s}/{s}", .{ GOLDEN_DIR, entry.path }));
        }
        std.mem.sort([]const u8, files.items, {}, struct {
            fn lt(_: void, a: []const u8, b: []const u8) bool {
                return std.mem.lessThan(u8, a, b);
            }
        }.lt);
    }
    if (files.items.len == 0) {
        std.debug.print("没有可测量的文件\n", .{});
        return;
    }

    std.debug.print("优化模式: {s}（建议 -Doptimize=ReleaseFast 对比发布构建）\n\n", .{@tagName(@import("builtin").mode)});
    printHeader();

    var samples: std.ArrayList(Sample) = .empty;
    defer samples.deinit(gpa);

    var totals = Sample{
        .path = "合计",
        .source_bytes = 0,
        .allocations = 0,
        .allocated_bytes = 0,
        .peak_live_bytes = 0,
        .resident_bytes = 0,
    };
    for (files.items) |path| {
        const src = cwd.readFileAllocOptions(
            io,
            path,
            gpa,
            std.Io.Limit.limited(std.math.maxInt(usize)),
            .@"1",
            0,
        ) catch |e| {
            std.debug.print("{s:<46} 读取失败: {s}\n", .{ path, @errorName(e) });
            continue;
        };
        defer gpa.free(src);

        const s = measure(gpa, path, src) catch |e| {
            std.debug.print("{s:<46} 解析失败（跳过）: {s}\n", .{ path, @errorName(e) });
            continue;
        };
        try samples.append(gpa, s);

        totals.source_bytes += s.source_bytes;
        totals.allocations += s.allocations;
        totals.allocated_bytes += s.allocated_bytes;
        totals.peak_live_bytes += s.peak_live_bytes;
        totals.resident_bytes += s.resident_bytes;
    }

    // 逐条列出：默认按峰值降序取前 N，`--all` 全列
    std.mem.sort(Sample, samples.items, {}, struct {
        fn gt(_: void, a: Sample, b: Sample) bool {
            return a.peak_live_bytes > b.peak_live_bytes;
        }
    }.gt);
    const listed = if (show_all) samples.items.len else @min(DEFAULT_TOP, samples.items.len);
    for (samples.items[0..listed]) |s| printRow(s);
    if (listed < samples.items.len) {
        std.debug.print("… 另有 {d} 个文件未列出（--all 查看）\n", .{samples.items.len - listed});
    }

    std.debug.print("\n", .{});
    printRow(totals);
    std.debug.print(
        "\n口径: 累计分配 = 历次分配字节之和（含临时缓冲与扩容）；峰值驻留 = live 字节峰值；\n" ++
            "      解析后驻留 = AST 自身占用（deinit 前，临时缓冲已释放）。\n" ++
            "      峰值 − 驻留 ≈ 解析期临时缓冲。\n",
        .{},
    );
}
