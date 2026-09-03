//! A3 预扫描工具：把 php-parser `test/code/parser/**/*.test` 的代码段喂给本库，
//! 报告两类差距——「期望接受却拒绝」（解析缺口）与「期望拒绝却接受」（宽松接受，
//! 需人工核对是否错误模型差异）。
//!
//! 工具只报告不判定（任何结果都 pass），供人工对照出修复清单；缺口清零后逐个迁移
//! 为自足 golden（reference/ 不入库
//!   zig test src/fixture_scan.zig --test-filter fixture_scan
//! 报告写入 `tests/a3_report.txt`。
//!
//! .test 格式：标题行后按 `-----` 分隔，(代码段, 期望段) 交替。期望段以 `array(`
//! 开头表示接受；以 `Syntax error` 等开头表示期望报错。代码段内的 `@@{expr}@@`
//! 是 php-parser 注入宏（CodeTestParser eval 后替换），本工具先展开再解析。

const std = @import("std");
const ast = @import("ast.zig");
const testing = @import("testing.zig");

const PARSER_DIR = "reference/PHP-Parser-full-5.8.0/test/code/parser";
const REPORT_PATH = "tests/a3_report.txt";

const Kind = enum { ok_reject, err_accept };

const Mismatch = struct {
    kind: Kind,
    path: []const u8, // rel 的 dupe，deinit 释放
    detail: []const u8, // owned，deinit 释放
};

const Report = struct {
    seg_total: usize = 0,
    seg_ok: usize = 0, // php-parser 期望接受
    seg_err: usize = 0, // php-parser 期望报错
    ok_accept: usize = 0,
    ok_reject: usize = 0,
    err_also_err: usize = 0,
    err_accept: usize = 0,
    unpaired: usize = 0,
    mismatches: std.ArrayList(Mismatch),
    gpa: std.mem.Allocator,

    fn init(gpa: std.mem.Allocator) Report {
        return .{ .gpa = gpa, .mismatches = .empty };
    }
    fn deinit(self: *Report) void {
        for (self.mismatches.items) |m| {
            self.gpa.free(m.path);
            self.gpa.free(m.detail);
        }
        self.mismatches.deinit(self.gpa);
    }
    /// path 拷贝一份持有（rel 来自外部列表）；detail 接管所有权。
    fn add(self: *Report, kind: Kind, path: []const u8, detail: []const u8) !void {
        try self.mismatches.append(self.gpa, .{
            .kind = kind,
            .path = try self.gpa.dupe(u8, path),
            .detail = detail,
        });
    }
};

fn lessThanPath(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

fn collectTests(gpa: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, sub: []const u8, out: *std.ArrayList([]const u8)) !void {
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        switch (entry.kind) {
            .directory => {
                var sub_dir = try dir.openDir(io, entry.name, .{ .iterate = true });
                defer sub_dir.close(io);
                const child = try std.fs.path.join(gpa, &.{ sub, entry.name });
                defer gpa.free(child);
                try collectTests(gpa, io, sub_dir, child, out);
            },
            .file => {
                if (!std.mem.endsWith(u8, entry.name, ".test")) continue;
                const p = if (sub.len == 0)
                    try gpa.dupe(u8, entry.name)
                else
                    try std.fs.path.join(gpa, &.{ sub, entry.name });
                try out.append(gpa, p);
            },
            else => {},
        }
    }
}

fn readFile(gpa: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, rel: []const u8) [:0]u8 {
    return dir.readFileAllocOptions(
        io,
        rel,
        gpa,
        std.Io.Limit.limited(std.math.maxInt(usize)),
        .@"1",
        0,
    ) catch |e| {
        std.debug.print("读取失败 {s}: {s}\n", .{ rel, @errorName(e) });
        return gpa.dupeZ(u8, "") catch unreachable;
    };
}

fn scanOne(gpa: std.mem.Allocator, rel: []const u8, content: [:0]u8, rep: *Report) !void {
    // 去掉 CR（reference 可能以 CRLF 检出），统一按 LF 切段
    const flat = try std.mem.replaceOwned(u8, gpa, content, "\r", "");
    defer gpa.free(flat);

    var segs: std.ArrayList([]const u8) = .empty;
    defer segs.deinit(gpa);
    var it = std.mem.splitSequence(u8, flat, "\n-----\n");
    _ = it.next(); // 标题段
    while (it.next()) |s| try segs.append(gpa, s);

    var i: usize = 0;
    while (i + 1 < segs.items.len) : (i += 2) {
        const code = std.mem.trim(u8, segs.items[i], " \t\n");
        const expect = std.mem.trim(u8, segs.items[i + 1], " \t\n");
        if (code.len == 0 or expect.len == 0) continue;
        const expect_ok = std.mem.startsWith(u8, expect, "array(");
        rep.seg_total += 1;
        if (expect_ok) rep.seg_ok += 1 else rep.seg_err += 1;

        // @@{expr}@@ 注入宏：双引号串 unescape 为内容、其它表达式占位 0。注入只改
        // 文本内容不改变语法类别，对接受/拒绝判定等价（heredoc 内容常以此宏写跨行体）。
        const expanded = try expandAtAt(gpa, code);
        defer gpa.free(expanded);
        const src = try gpa.dupeZ(u8, expanded);
        defer gpa.free(src);
        var tree = try ast.Ast.parse(gpa, src, testing.v85);
        defer tree.deinit(gpa);

        const no_diag = tree.errors.len == 0;
        const path = try std.fmt.allocPrint(gpa, "{s}[{d}]", .{ rel, i / 2 });
        defer gpa.free(path);

        if (expect_ok) {
            if (no_diag) {
                rep.ok_accept += 1;
            } else {
                rep.ok_reject += 1;
                try rep.add(.ok_reject, path, try describeDiag(gpa, &tree));
            }
        } else {
            if (no_diag) {
                rep.err_accept += 1;
                try rep.add(.err_accept, path, "");
            } else {
                rep.err_also_err += 1;
            }
        }
    }
    // 孤立代码段（期望缺失）提示，格式异常
    if (i < segs.items.len and std.mem.trim(u8, segs.items[i], " \t\n").len > 0) {
        rep.unpaired += 1;
    }
}

/// 展开 `@@{expr}@@` 注入宏。expr 为双引号字符串字面量时按 PHP 转义规则 unescape
/// （\n \r \t 等常见项，未知转义去反斜杠保留字符）；否则整体以 `0` 占位（表达式形态
/// 不影响本工具的接受/拒绝判定）。无闭合 `}@@` 时原样保留。
fn expandAtAt(gpa: std.mem.Allocator, code: []const u8) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
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

/// PHP 双引号字符串 unescape（本工具需要的常见子集）。
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
                // \xNN 两 hex 位（近似：直接吃两位字母数字）
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
            '0'...'7' => try buf.append(gpa, esc), // 八进制转义近似：保留字符
            else => try buf.append(gpa, esc),
        }
    }
}

fn describeDiag(gpa: std.mem.Allocator, tree: *ast.Ast) ![]const u8 {
    var ebuf: [160]u8 = undefined;
    const msg = tree.errors[0].format(tree, &ebuf);
    return std.fmt.allocPrint(gpa, "诊断 {d} 条，首个: {s} @ '{s}'", .{
        tree.errors.len,
        msg,
        tree.tokenSlice(tree.errors[0].token),
    });
}

test "fixture_scan :: parser/ 接受-拒绝差距预扫描" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var dir = std.Io.Dir.cwd().openDir(io, PARSER_DIR, .{ .iterate = true }) catch {
        std.debug.print("（reference/ 不存在，跳过 A3 预扫描）\n", .{});
        return;
    };
    defer dir.close(io);

    var rels: std.ArrayList([]const u8) = .empty;
    defer {
        for (rels.items) |r| gpa.free(r);
        rels.deinit(gpa);
    }
    try collectTests(gpa, io, dir, "", &rels);
    std.mem.sort([]const u8, rels.items, {}, lessThanPath);

    var rep = Report.init(gpa);
    defer rep.deinit();

    for (rels.items) |rel| {
        const full = readFile(gpa, io, dir, rel);
        defer gpa.free(full);
        try scanOne(gpa, rel, full, &rep);
    }

    // stdout 会被终端截断，报告写文件供完整阅读
    var buf: std.Io.Writer.Allocating = .init(gpa);
    defer buf.deinit();
    const w = &buf.writer;
    try w.print(
        "A3 预扫描 {s}\n.test {d} 个，配对代码段 {d}（期望接受 {d} / 期望报错 {d}）\n" ++
            "期望接受: 通过 {d}，拒绝 {d}\n期望报错: 一致 {d}，未报错 {d}\n",
        .{ PARSER_DIR, rels.items.len, rep.seg_total, rep.seg_ok, rep.seg_err,
            rep.ok_accept, rep.ok_reject, rep.err_also_err, rep.err_accept },
    );
    if (rep.unpaired > 0) try w.print("孤立代码段（无期望，格式异常）: {d}\n", .{rep.unpaired});

    try w.print("\n== 解析缺口：期望接受却拒绝（{d} 条，逐一待补） ==\n", .{rep.ok_reject});
    for (rep.mismatches.items) |m| {
        if (m.kind == .ok_reject) try w.print("[{s}] {s}\n", .{ m.path, m.detail });
    }

    try w.print("\n== 宽松接受：期望报错却无诊断（{d} 条，核对是否错误模型差异） ==\n", .{rep.err_accept});
    for (rep.mismatches.items) |m| {
        if (m.kind == .err_accept) try w.print("[{s}]\n", .{m.path});
    }

    var f = try std.Io.Dir.cwd().createFile(io, REPORT_PATH, .{});
    defer f.close(io);
    var fw = f.writer(io, &.{});
    try fw.interface.writeAll(buf.written());
    try fw.interface.flush();
    std.debug.print("A3 报告已写入 {s}（{d} 字节）\n", .{ REPORT_PATH, buf.written().len });
}
