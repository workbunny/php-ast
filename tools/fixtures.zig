//! `.test` 用例文件的解析与外部参照定位——`tools/conformance.zig` 与
//! `tools/golden_gen.zig` 共用（规则只写一份：段切分、版本 mode、注入宏）。
//!
//! `.test` 格式：首行标题，之后以 `-----` 分隔的 (代码段, 期望段) 交替对。期望段
//! 以 `array(` 开头表示参照实现接受该代码段，以错误说明开头表示应报错；期望段首行
//! 的 `!!key=value` 是 mode 行，其中 `!!version=X.Y` 决定该段的解析版本，其余忽略。
//! 代码段内的 `@@{expr}@@` 是参照实现的测试注入宏（eval 后替换为文本），消费前须经
//! `expandAtAt` 展开。

const std = @import("std");

/// 段无 `!!version` 时的默认解析版本：与库的最新支持版本一致。
pub const DEFAULT_VERSION_ID: u32 = 80500;

/// 参照实现（PHP-Parser）的测试用例目录，相对其仓库根。
pub const PARSER_SUBDIR = "test/code/parser";

/// 一个 (代码段, 期望段) 对。
pub const Segment = struct {
    /// 代码段原文（**未**展开 `@@{}@@`；需要时调 `expandAtAt`）。
    code: []const u8,
    /// 期望段原文（已剥离 mode 行与首尾空白）。
    expect: []const u8,
    /// 该段的解析版本 id（见 `parseVersionId`）。
    version_id: u32,
    /// 段序号（0 基，按 `.test` 内的原始对位置计数）——与参照实现的段号口径一致，
    /// 也是快照文件名的一部分。
    index: usize,
};

/// `parse` 的结果：段列表 + 末尾孤立代码段计数（有代码却无期望，格式异常）。
pub const ParseResult = struct {
    /// 段列表（元素借用 `flat`，只释放切片本身）。
    segments: []Segment,
    /// 末尾孤立代码段数。
    unpaired: usize,
};

/// 切分 `.test` 内容为段列表。空段（缺代码或缺期望）会被跳过，但其序号仍占位
/// （`Segment.index` 按原始对位置计数）。
pub fn parse(gpa: std.mem.Allocator, flat: []const u8) !ParseResult {
    var raw: std.ArrayList([]const u8) = .empty;
    defer raw.deinit(gpa);
    var it = std.mem.splitSequence(u8, flat, "\n-----\n");
    _ = it.next(); // 标题段
    while (it.next()) |s| try raw.append(gpa, s);

    var out: std.ArrayList(Segment) = .empty;
    errdefer out.deinit(gpa);
    var i: usize = 0;
    while (i + 1 < raw.items.len) : (i += 2) {
        const code = std.mem.trim(u8, raw.items[i], " \t\n");
        var expect = std.mem.trim(u8, raw.items[i + 1], " \t\n");
        var version_id: u32 = DEFAULT_VERSION_ID;
        if (std.mem.startsWith(u8, expect, "!!")) {
            const nl = std.mem.indexOfScalar(u8, expect, '\n') orelse expect.len;
            const mode_line = std.mem.trim(u8, expect[2..nl], " \t\r");
            if (std.mem.startsWith(u8, mode_line, "version=")) {
                const vs = std.mem.trim(u8, mode_line["version=".len..], " \t");
                if (parseVersionId(vs)) |vid| version_id = vid;
            }
            expect = std.mem.trim(u8, expect[nl..], " \t\n");
        }
        if (code.len == 0 or expect.len == 0) continue;
        try out.append(gpa, .{
            .code = code,
            .expect = expect,
            .version_id = version_id,
            .index = i / 2,
        });
    }
    var unpaired: usize = 0;
    if (i < raw.items.len and std.mem.trim(u8, raw.items[i], " \t\n").len > 0) unpaired += 1;
    return .{ .segments = try out.toOwnedSlice(gpa), .unpaired = unpaired };
}

/// 解析版本串 `X.Y[.Z]` 为 id（`x.y.z → xyyzz`，如 8.5 → 80500、7.0 → 70000）。
/// 失败返回 null（调用方沿用默认版本）。
pub fn parseVersionId(s: []const u8) ?u32 {
    var parts = std.mem.splitScalar(u8, s, '.');
    const major_s = parts.next() orelse return null;
    const minor_s = parts.next() orelse return null;
    const patch_s = parts.next();
    const major = std.fmt.parseInt(u32, major_s, 10) catch return null;
    const minor = std.fmt.parseInt(u32, minor_s, 10) catch return null;
    const patch: u32 = if (patch_s) |p| std.fmt.parseInt(u32, p, 10) catch return null else 0;
    return major * 10000 + minor * 100 + patch;
}

/// 展开 `@@{expr}@@` 注入宏。expr 为双引号字符串字面量时按 PHP 转义规则 unescape
/// （常见项；未知转义去反斜杠保留字符）；否则整体以 `0` 占位（表达式形态不影响
/// 结构类别）。无闭合 `}@@` 时原样保留。
pub fn expandAtAt(gpa: std.mem.Allocator, code: []const u8) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(gpa);
    var i: usize = 0;
    while (i < code.len) {
        const m = std.mem.indexOfPos(u8, code, i, "@@{") orelse {
            try buf.appendSlice(gpa, code[i..]);
            break;
        };
        try buf.appendSlice(gpa, code[i..m]);
        const c = std.mem.indexOfPos(u8, code, m + 3, "}@@") orelse {
            try buf.appendSlice(gpa, code[m..]);
            break;
        };
        const inner = std.mem.trim(u8, code[m + 3 .. c], " \t");
        if (inner.len >= 2 and inner[0] == '"' and inner[inner.len - 1] == '"') {
            try appendUnescaped(gpa, &buf, inner[1 .. inner.len - 1]);
        } else {
            try buf.append(gpa, '0');
        }
        i = c + 3;
    }
    return buf.toOwnedSlice(gpa);
}

fn appendUnescaped(gpa: std.mem.Allocator, buf: *std.ArrayList(u8), s: []const u8) !void {
    var i: usize = 0;
    while (i < s.len) {
        if (s[i] != '\\') {
            try buf.append(gpa, s[i]);
            i += 1;
            continue;
        }
        i += 1;
        if (i >= s.len) break;
        const esc = s[i];
        i += 1;
        switch (esc) {
            'n' => try buf.append(gpa, '\n'),
            'r' => try buf.append(gpa, '\r'),
            't' => try buf.append(gpa, '\t'),
            'v' => try buf.append(gpa, 0x0b),
            'f' => try buf.append(gpa, 0x0c),
            'e' => try buf.append(gpa, 0x1b),
            '\\', '"', '$', '/' => try buf.append(gpa, esc),
            'x' => {
                var n2: usize = 0;
                while (n2 < 2 and i + n2 < s.len and
                    (std.ascii.isDigit(s[i + n2]) or (s[i + n2] | 32) >= 'a' and (s[i + n2] | 32) <= 'f'))
                {
                    n2 += 1;
                }
                if (n2 > 0) {
                    const val = std.fmt.parseInt(u8, s[i .. i + n2], 16) catch 0;
                    try buf.append(gpa, val);
                    i += n2;
                }
            },
            '0'...'7' => {
                // 八进制转义最多 3 位（`i` 已越过首位，从 `i - 1` 起算）
                var oct: u8 = 0;
                var nd: usize = 0;
                var k = i - 1;
                while (nd < 3 and k < s.len and s[k] >= '0' and s[k] <= '7') : (nd += 1) {
                    oct = oct * 8 + (s[k] - '0');
                    k += 1;
                }
                try buf.append(gpa, oct);
                i = k;
            },
            else => try buf.append(gpa, esc),
        }
    }
}

/// 递归收集目录下全部 `.test` 文件的**相对路径**（相对 `dir_path`，按字典序）。
/// 返回切片与其元素均需调用方释放。
pub fn collectTestFiles(gpa: std.mem.Allocator, io: std.Io, dir_path: []const u8) ![][]const u8 {
    var dir = try std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true });
    defer dir.close(io);
    var walker = try dir.walk(gpa);
    defer walker.deinit();

    var out: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (out.items) |p| gpa.free(p);
        out.deinit(gpa);
    }
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.path, ".test")) continue;
        // walker 复用内部缓冲，须复制
        try out.append(gpa, try gpa.dupe(u8, entry.path));
    }
    std.mem.sort([]const u8, out.items, {}, lessThanStr);
    return out.toOwnedSlice(gpa);
}

fn lessThanStr(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

/// 把用户给出的参照路径规整为测试用例目录：路径本身即用例目录，或其下存在
/// `test/code/parser`（即指向参照仓库根）均可，前者优先。
pub fn resolveParserDir(gpa: std.mem.Allocator, io: std.Io, path: []const u8) ![]const u8 {
    if (try containsTestFile(gpa, io, path, 2)) return gpa.dupe(u8, path);
    const sub = try std.fs.path.join(gpa, &.{ path, "test", "code", "parser" });
    if (try containsTestFile(gpa, io, sub, 2)) return sub;
    gpa.free(sub);
    return error.ParserDirNotFound;
}

/// 目录（至多 `depth` 层）内是否存在 `.test` 文件。
fn containsTestFile(gpa: std.mem.Allocator, io: std.Io, path: []const u8, depth: usize) !bool {
    _ = gpa;
    if (depth == 0) return false;
    var dir = std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true }) catch return false;
    defer dir.close(io);
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        switch (entry.kind) {
            .file => if (std.mem.endsWith(u8, entry.name, ".test")) return true,
            .directory => {
                const child = try std.fs.path.join(std.heap.page_allocator, &.{ path, entry.name });
                defer std.heap.page_allocator.free(child);
                if (try containsTestFile(std.heap.page_allocator, io, child, depth - 1)) return true;
            },
            else => {},
        }
    }
    return false;
}

/// 读整个文件为文本（默认上限 = 无限制）。
pub fn readFile(gpa: std.mem.Allocator, io: std.Io, path: []const u8) ![:0]u8 {
    return std.Io.Dir.cwd().readFileAllocOptions(
        io,
        path,
        gpa,
        std.Io.Limit.limited(std.math.maxInt(usize)),
        .@"1",
        0,
    );
}

/// 读 `.test` 文件并按 LF 归一化行尾（参照实现可能以 CRLF 检出）。
pub fn readTestFlat(gpa: std.mem.Allocator, io: std.Io, path: []const u8) ![]u8 {
    const content = try readFile(gpa, io, path);
    defer gpa.free(content);
    return std.mem.replaceOwned(u8, gpa, content, "\r", "");
}
