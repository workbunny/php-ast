//! 一致性对照工具（parity check）：以 php-parser 的 parser 测试子集为基准（oracle），
//! 度量本库解析器与基准的接受面、诊断质量是否一致。只报告不判定（任何结果都 pass），
//! 产出两份报告供人工逐条校准与回归追踪。
//!
//! 判定口径：
//!   「接受」= parse 诊断与旁路语义层 semantic.check 诊断均无。
//! 术语：
//!   误拒 (false_reject) —— 基准期望接受，本库却产出诊断（本库过严）；
//!   漏报 (missed_error) —— 基准期望报错，本库却无诊断（本库过宽）；
//!   诊断质量          —— 两边都报的段里，按 条数 / 文本 / 位置 逐条比对的一致度。
//! 基准与产物：
//!   无参数  基准 = 随库收录的 `tests/third_party/php-parser/test/code/parser`
//!             （php-parser 5.8.0，BSD 3-Clause），报告写到当前目录（仓库根）；
//!   一个参数（基准目录）—— 报告同时写到该目录，便于对自定义 php-parser clone 对照。
//! 用法（项目根）：
//!   zig build check-parity                    # 默认基准，报告落仓库根
//!   zig build check-parity -- <php-parser test/code/parser 目录>
//! 产物：acceptance_report.txt（误拒/漏报清单）、diagnostic_report.txt
//!   （诊断质量统计与差异明细，含期望/实际与源码行）。
//!
//! .test 格式：标题行后按 `-----` 分隔，(代码段, 期望段) 交替。期望段以 `array(`
//! 开头表示接受；以 `Syntax error` 等开头表示期望报错。期望段首行 `!!key=value`
//! 是 mode 行（`!!version=X.Y` 按该版本解析，其余忽略）。代码段内的 `@@{expr}@@`
//! 是 php-parser 注入宏（CodeTestParser eval 后替换），本工具先展开再解析。

const std = @import("std");
const ast = @import("ast"); // src/ast.zig（见 build.zig 的 check-parity 模块映射）

/// 默认对照基准（oracle）：php-parser 5.8.0 的 parser 测试子集，随本库 clone 收录于
/// `tests/third_party/php-parser`（BSD 3-Clause）。命令行给参数时以参数为准。
const DEFAULT_PARSER_DIR = "tests/third_party/php-parser/test/code/parser";
/// 接受面报告文件名：本库接受/拒绝与基准不一致的段（误拒 / 漏报）。
const ACCEPTANCE_REPORT = "acceptance_report.txt";
/// 诊断质量报告文件名：两边都报的段里，条数/文本/位置的一致度与差异明细。
const DIAGNOSTIC_REPORT = "diagnostic_report.txt";

/// 报告落点：指定基准目录时写到该目录（与基准同处，便于对照）；未指定时写到
/// 当前目录（仓库根）。文件名见上两个常量。
fn reportPath(gpa: std.mem.Allocator, base: []const u8, name: []const u8) ![]const u8 {
    if (base.len == 0) return gpa.dupe(u8, name);
    return std.fs.path.join(gpa, &.{ base, name });
}

/// 入口：`parity_check [基准目录]`。
///   无参数 —— 基准 = 库内 `tests/third_party/php-parser/test/code/parser`，
///            报告写在当前目录（仓库根）；
///   有参数 —— 参数即基准目录（php-parser 的 `test/code/parser` 级目录，
///            例如某处 php-parser clone 的 `test/code/parser`），报告写进该目录。
/// 两种情形都产出 acceptance_report.txt 与 diagnostic_report.txt。
/// 0.16 启动器自动构造 `std.process.Init`（含默认 io），main 接收之。
/// 分配用 `page_allocator`：工具是单次运行的开发对照（进程退出即回收全部内存，
/// 无需逐次释放）；若需排查本工具自身的内存泄漏，改回 `init.gpa`（debug 检测
/// 分配器）运行一次即可。参数解析：0.16 无 argsAlloc，用 `Args.Iterator`
/// （迭代缓冲会复用，先收集）。
pub fn main(init: std.process.Init) !void {
    const gpa = std.heap.page_allocator;
    const io = init.io;

    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(gpa);
    var it = try std.process.Args.Iterator.initAllocator(init.minimal.args, gpa);
    defer it.deinit();
    while (it.next()) |a| {
        try argv.append(gpa, try gpa.dupe(u8, a));
    }
    defer {
        for (argv.items) |a| gpa.free(a);
    }
    if (argv.items.len > 2) { // argv[0]（程序路径）+ 至多 1 个参数
        std.debug.print("用法: parity_check [基准目录]\n", .{});
        std.process.exit(2);
    }
    const parser_dir = if (argv.items.len == 2) argv.items[1] else DEFAULT_PARSER_DIR;
    const report_base = if (argv.items.len == 2) argv.items[1] else "";
    const accept_path = try reportPath(gpa, report_base, ACCEPTANCE_REPORT);
    defer gpa.free(accept_path);
    const diag_path = try reportPath(gpa, report_base, DIAGNOSTIC_REPORT);
    defer gpa.free(diag_path);
    try runChecks(gpa, io, parser_dir, accept_path, diag_path);
}

const Kind = enum { false_reject, missed_error };

// ---- 诊断质量对照 ----

/// 一条期望消息：`full` 为原文（含 ` from L:C to L:C`），`raw` 为去掉位置后缀的正文。
const WantMsg = struct {
    raw: []const u8,
    full: []const u8,
    /// 消息中 `from` 后的行号（1 基，段内相对行），用于取源码行定位。
    line: usize,
    col: usize,
};

const LineCol = struct { line: usize, col: usize };

/// 解析 `from L:C` 得到行列（失败返回 0）。
fn parseLineCol(msg: []const u8) LineCol {
    var res = LineCol{ .line = 0, .col = 0 };
    const k = std.mem.indexOf(u8, msg, " from ") orelse return res;
    var it = std.mem.splitScalar(u8, msg[k + 6 ..], ':');
    res.line = std.fmt.parseInt(usize, it.next() orelse return res, 10) catch 0;
    var rest = it.next() orelse return res;
    // `C to ...`：列号到空格止
    if (std.mem.indexOfScalar(u8, rest, ' ')) |sp| rest = rest[0..sp];
    res.col = std.fmt.parseInt(usize, rest, 10) catch 0;
    return res;
}

/// 取源码第 `line` 行（1 基）原文，用于报告中人工核对定位。
fn srcLineAt(gpa: std.mem.Allocator, src: []const u8, line: usize) []const u8 {
    if (line == 0) return gpa.dupe(u8, "") catch "";
    var it = std.mem.splitScalar(u8, src, '\n');
    var i: usize = 1;
    while (it.next()) |l| : (i += 1) {
        if (i == line) return gpa.dupe(u8, std.mem.trim(u8, l, "\r")) catch "";
    }
    return gpa.dupe(u8, "<行号越界>") catch "";
}

const MsgStat = struct {
    /// 期望报错且本库也报错的段
    total: usize = 0,
    /// 文本与位置逐条全等
    full_match: usize = 0,
    /// 消息条数不同
    count_diff: usize = 0,
    /// 条数相同但正文不同
    raw_diff: usize = 0,
    /// 正文相同但位置不同
    pos_diff: usize = 0,
};

const MsgDiff = struct {
    path: []const u8,
    kind: []const u8,
    want: []const u8,
    got: []const u8,
    src: []const u8,
    line: usize,
};

const MsgReport = struct {
    stat: MsgStat = .{},
    diffs: std.ArrayList(MsgDiff),
    gpa: std.mem.Allocator,

    fn init(gpa: std.mem.Allocator) MsgReport {
        return .{ .gpa = gpa, .diffs = .empty };
    }
    fn deinit(self: *MsgReport) void {
        for (self.diffs.items) |d| {
            self.gpa.free(d.path);
            self.gpa.free(d.want);
            self.gpa.free(d.got);
        }
        self.diffs.deinit(self.gpa);
    }
    fn add(
        self: *MsgReport,
        path: []const u8,
        kind: []const u8,
        want: []const u8,
        got: []const u8,
        src: []const u8,
        line: usize,
    ) !void {
        try self.diffs.append(self.gpa, .{
            .path = try self.gpa.dupe(u8, path),
            .kind = kind,
            .want = try self.gpa.dupe(u8, want),
            .got = try self.gpa.dupe(u8, got),
            .src = try self.gpa.dupe(u8, src),
            .line = line,
        });
    }
};

const Mismatch = struct {
    kind: Kind,
    path: []const u8, // rel 的 dupe，deinit 释放
    detail: []const u8, // owned，deinit 释放
};

const Report = struct {
    segments: usize = 0, // 配对代码段总数
    accept_expected: usize = 0, // 其中 php-parser 期望接受
    error_expected: usize = 0, // 其中 php-parser 期望报错
    accept_clean: usize = 0, // 期望接受且本库无诊断
    false_reject: usize = 0, // 期望接受却本库有诊断（误拒）
    both_reported: usize = 0, // 期望报错且本库也报
    missed_error: usize = 0, // 期望报错却本库无诊断（漏报）
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

/// 解析版本串 `X.Y`（可带 `.Z`）为 PhpVersion.id 数值（x.y.z → xyyzz，如 8.5 → 80500、
/// 7.0 → 70000、5.6 → 50600）。失败返回 null（沿用默认 v85）。
fn parseVersionId(s: []const u8) ?u32 {
    var parts = std.mem.splitScalar(u8, s, '.');
    const major_s = parts.next() orelse return null;
    const minor_s = parts.next() orelse return null;
    const patch_s = parts.next(); // 可能为 null（X.Y 两段）
    const major = std.fmt.parseInt(u32, major_s, 10) catch return null;
    const minor = std.fmt.parseInt(u32, minor_s, 10) catch return null;
    const patch: u32 = if (patch_s) |p| std.fmt.parseInt(u32, p, 10) catch return null else 0;
    return major * 10000 + minor * 100 + patch;
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

fn scanOne(gpa: std.mem.Allocator, rel: []const u8, content: [:0]u8, rep: *Report, mrep: ?*MsgReport) !void {
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
        var expect = std.mem.trim(u8, segs.items[i + 1], " \t\n");
        // 期望段首行 `!!key=value`（php-parser CodeTestParser extractMode）：仅
        // `!!version=X.Y` 影响解析（该段在指定版本下解析）；其余（如 `!!attributes`）
        // 只是比对模式的开关，不影响接受/拒绝。统一剥离 mode 行；version 按对应
        // 版本喂给本库（无 mode = 最新版 v85）。
        var version_id: u32 = 80500;
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
        const expect_ok = std.mem.startsWith(u8, expect, "array(");
        rep.segments += 1;
        if (expect_ok) rep.accept_expected += 1 else rep.error_expected += 1;

        // @@{expr}@@ 注入宏：双引号串 unescape 为内容、其它表达式占位 0。注入只改
        // 文本内容不改变语法类别，对接受/拒绝判定等价（heredoc 内容常以此宏写跨行体）。
        const expanded = try expandAtAt(gpa, code);
        defer gpa.free(expanded);
        const src = try gpa.dupeZ(u8, expanded);
        defer gpa.free(src);
        var tree = try ast.Ast.parse(gpa, src, .{ .id = version_id });
        defer tree.deinit(gpa);

        // parse 宽松只报语法层诊断；php-parser 的引擎级语义错误（保留名、魔法方法
        // static、namespace 顶层规则等）在本库的旁路语义层 `semantic` 报告——两处
        // 均无诊断才算「接受」。局部语义诊断（修饰符重复等）已随 parse 收集于
        // tree.errors。
        const semantic = @import("ast").semantic;
        var ck = semantic.Checker.init(gpa);
        defer ck.deinit();
        try ck.run(&tree);

        const no_diag = tree.errors.len == 0 and ck.errors.items.len == 0;
        const path = try std.fmt.allocPrint(gpa, "{s}[{d}]", .{ rel, i / 2 });
        defer gpa.free(path);

        if (expect_ok) {
            if (no_diag) {
                rep.accept_clean += 1;
            } else {
                rep.false_reject += 1;
                try rep.add(.false_reject, path, try describeDiag(gpa, &tree, ck.errors.items.len));
            }
        } else {
            if (no_diag) {
                rep.missed_error += 1;
                try rep.add(.missed_error, path, "");
            } else {
                rep.both_reported += 1;
                // 两边都报错：进入诊断质量对照，逐条比对消息文本与位置
                if (mrep) |mr| {
                    // WantMsg 的 raw/full 均借用 `expect` 切片，只释放列表本身
                    var wants = try extractWantMsgs(gpa, expect);
                    defer wants.deinit(gpa);
                    try compareMsgs(gpa, mr, path, wants.items, &tree, ck.errors.items, src);
                }
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
            '0'...'7' => {
                // 八进制转义 `\1`、`\0`：最多 3 位八进制（遇非 0-7 停），值为字节。
                // 此前把 `\1` 当字面 `'1'` 保留——lexerErrors 用 `@@{"\1"}@@` 注入
                // 控制字节时展开出错（注入的是 '1' 而非字节 1），对照判定失真。
                var oct: u8 = 0;
                var nd: usize = 0;
                // `i` 已越过 esc（首个八进制位），故从 `i - 1` 起算——否则 `\1`
                // （反斜杠后仅一位且无后续字符）会解析出 0 而注入错字节。
                var k = i - 1;
                while (nd < 3 and k < s.len and s[k] >= '0' and s[k] <= '7') : (nd += 1) {
                    oct = oct * 8 + (s[k] - '0');
                    k += 1;
                }
                try buf.append(gpa, oct);
                i = k;
                continue;
            },
            else => try buf.append(gpa, esc),
        }
    }
}

/// 去掉 php-parser 消息的位置后缀 ` from L:C to L:C`。
fn stripPos(s: []const u8) []const u8 {
    if (std.mem.lastIndexOf(u8, s, " from ")) |k| {
        const tail = s[k..];
        // 形如 ` from 1:2 to 3:4`：`from` 后至少两个 `数字:数字`
        var parts = std.mem.splitScalar(u8, tail, ' ');
        _ = parts.next(); // 空（前导空格已并入 tail 起点）
        _ = parts.next(); // "from"
        const a = parts.next() orelse return s;
        const t = parts.next() orelse return s; // "to"
        const b = parts.next() orelse return s;
        if (t.len == 0) return s;
        if (std.mem.count(u8, a, ":") == 1 and std.mem.count(u8, b, ":") == 1 and
            parts.next() == null)
        {
            return s[0..k];
        }
    }
    return s;
}

/// 提取期望段中的消息行（`array(` 之前的非空行，跳过 `!!` mode 行）。
fn extractWantMsgs(gpa: std.mem.Allocator, expect: []const u8) !std.ArrayList(WantMsg) {
    var out: std.ArrayList(WantMsg) = .empty;
    var lines = std.mem.splitScalar(u8, expect, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0) continue;
        if (std.mem.startsWith(u8, line, "!!")) continue;
        if (std.mem.startsWith(u8, line, "array(")) break;
        const lc = parseLineCol(line);
        try out.append(gpa, .{ .raw = stripPos(line), .full = line, .line = lc.line, .col = lc.col });
    }
    return out;
}

/// 比对单段：期望消息 vs 本库诊断（parse + 语义层，按 token 顺序归并）。
fn compareMsgs(
    gpa: std.mem.Allocator,
    mrep: *MsgReport,
    path: []const u8,
    want: []const WantMsg,
    tree: *ast.Ast,
    sem: []const ast.Error,
    src: []const u8,
) !void {
    mrep.stat.total += 1;

    // 归并两类诊断并**保持产出顺序**（不排序）：php-parser 按解析/归约顺序报错，
    // 与其源码位置顺序未必一致（如管道链先报内层）。
    var all: std.ArrayList(ast.Error) = .empty;
    defer all.deinit(gpa);
    try all.appendSlice(gpa, tree.errors);
    try all.appendSlice(gpa, sem);

    const sline = if (want.len > 0) want[0].line else 0;
    const srcline = srcLineAt(gpa, src, sline);
    defer gpa.free(srcline);

    if (all.items.len != want.len) {
        mrep.stat.count_diff += 1;
        const wj = try joinMsgs(gpa, want);
        defer gpa.free(wj);
        const gj = try joinErrs(gpa, tree, all.items);
        defer gpa.free(gj);
        try mrep.add(path, "条数", wj, gj, srcline, sline);
        return;
    }

    var raw_ok = true;
    var pos_ok = true;
    var ebuf: [256]u8 = undefined;
    for (want, all.items) |w, g| {
        const got_raw = g.rawMessage(tree, &ebuf);
        if (!std.mem.eql(u8, w.raw, got_raw)) raw_ok = false;
        const got_full = g.format(tree, &ebuf);
        if (!std.mem.eql(u8, w.full, got_full)) pos_ok = false;
    }

    if (!raw_ok) {
        mrep.stat.raw_diff += 1;
        const wj = try joinMsgs(gpa, want);
        defer gpa.free(wj);
        const gj = try joinErrs(gpa, tree, all.items);
        defer gpa.free(gj);
        try mrep.add(path, "文本", wj, gj, srcline, sline);
    } else if (!pos_ok) {
        mrep.stat.pos_diff += 1;
        const wj = try joinMsgs(gpa, want);
        defer gpa.free(wj);
        const gj = try joinErrs(gpa, tree, all.items);
        defer gpa.free(gj);
        try mrep.add(path, "位置", wj, gj, srcline, sline);
    } else {
        mrep.stat.full_match += 1;
    }
}

fn lessThanErrToken(_: void, a: ast.Error, b: ast.Error) bool {
    return a.token < b.token;
}

fn joinMsgs(gpa: std.mem.Allocator, msgs: []const WantMsg) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    for (msgs, 0..) |m, i| {
        if (i > 0) try buf.appendSlice(gpa, " | ");
        try buf.appendSlice(gpa, m.full);
    }
    return buf.toOwnedSlice(gpa);
}

fn joinErrs(gpa: std.mem.Allocator, tree: *ast.Ast, errs: []const ast.Error) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    var ebuf: [256]u8 = undefined;
    for (errs, 0..) |e, i| {
        if (i > 0) try buf.appendSlice(gpa, " | ");
        try buf.appendSlice(gpa, e.format(tree, &ebuf));
    }
    return buf.toOwnedSlice(gpa);
}

fn describeDiag(gpa: std.mem.Allocator, tree: *ast.Ast, semantic_n: usize) ![]const u8 {
    if (tree.errors.len > 0) {
        var ebuf: [160]u8 = undefined;
        const msg = tree.errors[0].format(tree, &ebuf);
        return std.fmt.allocPrint(gpa, "诊断 {d} 条（含语义层 {d}），首个: {s} @ '{s}'", .{
            tree.errors.len,
            semantic_n,
            msg,
            tree.tokenSlice(tree.errors[0].token),
        });
    }
    return std.fmt.allocPrint(gpa, "诊断 {d} 条（均来自语义层）", .{semantic_n});
}

fn runChecks(
    gpa: std.mem.Allocator,
    io: std.Io,
    parser_dir: []const u8,
    accept_path: []const u8,
    diag_path: []const u8,
) !void {
    var dir = std.Io.Dir.cwd().openDir(io, parser_dir, .{ .iterate = true }) catch {
        std.debug.print("(跳过对照：基准目录不存在 {s})\n", .{parser_dir});
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

    var mrep = MsgReport.init(gpa);
    defer mrep.deinit();

    for (rels.items) |rel| {
        const full = readFile(gpa, io, dir, rel);
        defer gpa.free(full);
        try scanOne(gpa, rel, full, &rep, &mrep);
    }

    // stdout 会被终端截断，报告写文件供完整阅读
    var buf: std.Io.Writer.Allocating = .init(gpa);
    defer buf.deinit();
    const w = &buf.writer;
    try w.print(
        "php-ast 一致性对照（接受面）\n" ++
            "基准:   {s}（.test {d} 个，配对代码段 {d}：期望接受 {d} / 期望报错 {d}）\n" ++
            "口径:   「接受」= parse 与 semantic.check 均无诊断\n" ++
            "期望接受: 通过 {d}，误拒 {d}\n期望报错: 已报 {d}，漏报 {d}\n",
        .{ parser_dir, rels.items.len, rep.segments, rep.accept_expected, rep.error_expected,
            rep.accept_clean, rep.false_reject, rep.both_reported, rep.missed_error },
    );
    if (rep.unpaired > 0) try w.print("孤立代码段（无期望，格式异常）: {d}\n", .{rep.unpaired});

    try w.print("\n== 误拒（期望接受却有诊断，{d} 条） ==\n", .{rep.false_reject});
    for (rep.mismatches.items) |m| {
        if (m.kind == .false_reject) try w.print("[{s}] {s}\n", .{ m.path, m.detail });
    }

    try w.print("\n== 漏报（期望报错却无诊断，{d} 条） ==\n", .{rep.missed_error});
    for (rep.mismatches.items) |m| {
        if (m.kind == .missed_error) try w.print("[{s}]\n", .{m.path});
    }

    var f = try std.Io.Dir.cwd().createFile(io, accept_path, .{});
    defer f.close(io);
    var fw = f.writer(io, &.{});
    try fw.interface.writeAll(buf.written());
    try fw.interface.flush();
    std.debug.print("接受面报告写入 {s} ({d} bytes)\n", .{ accept_path, buf.written().len });

    try writeDiagnosticReport(gpa, io, &mrep, parser_dir, diag_path);
}

/// 诊断质量报告：两边都报的段里，消息 条数/文本/位置 的一致度与差异明细
/// （只报告不判定，供逐条校准）。文本比较口径：先比正文（去掉 `from..to`），
/// 正文全等才比位置——故四类互斥。
fn writeDiagnosticReport(
    gpa: std.mem.Allocator,
    io: std.Io,
    mrep: *MsgReport,
    parser_dir: []const u8,
    diag_path: []const u8,
) !void {
    var mbuf: std.Io.Writer.Allocating = .init(gpa);
    defer mbuf.deinit();
    const w = &mbuf.writer;
    const s = mrep.stat;
    try w.print("php-ast 一致性对照（诊断质量）\n", .{});
    try w.print(
        "基准:   {s}\n" ++
            "样本:   期望报错且本库也报的段 {d}\n" ++
            "比对:   文本+位置全等 {d} | 条数不同 {d} | 正文不同 {d} | 位置不同 {d}\n" ++
            "一致率: {d}%\n",
        .{ parser_dir, s.total, s.full_match, s.count_diff, s.raw_diff, s.pos_diff,
            if (s.total == 0) 0 else s.full_match * 100 / s.total },
    );

    for ([_][]const u8{ "条数", "文本", "位置" }) |dim| {
        var n: usize = 0;
        for (mrep.diffs.items) |d| {
            if (std.mem.eql(u8, d.kind, dim)) n += 1;
        }
        try w.print("\n== {s}不一致（{d} 条，每条含源码行便于定位） ==\n", .{ dim, n });
        for (mrep.diffs.items) |d| {
            if (!std.mem.eql(u8, d.kind, dim)) continue;
            try w.print("[{s}]\n  源码{d}: {s}\n  期望: {s}\n  实际: {s}\n", .{ d.path, d.line, d.src, d.want, d.got });
        }
    }

    var mf = try std.Io.Dir.cwd().createFile(io, diag_path, .{});
    defer mf.close(io);
    var mfw = mf.writer(io, &.{});
    try mfw.interface.writeAll(mbuf.written());
    try mfw.interface.flush();
    std.debug.print("诊断质量报告写入 {s} ({d} bytes)\n", .{ diag_path, mbuf.written().len });
}
