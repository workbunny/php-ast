//! 符合性对照（conformance）：以 PHP-Parser 的测试用例为 oracle，度量本库解析器的
//! 接受面与诊断质量是否与之一致，并作为防回归门禁——任何差异必须落在白名单内，
//! 且全等段数不得低于基线，否则以非零码退出。
//!
//! 判定口径：
//!   「接受」= parse 诊断与旁路语义层 semantic.check 诊断均无。
//! 术语：
//!   误拒 (false_reject) —— oracle 期望接受，本库却产出诊断（本库过严）；
//!   漏报 (missed_error) —— oracle 期望报错，本库却无诊断（本库过宽）；
//!   诊断质量          —— 两边都报的段里，按 条数 / 文本 / 位置 逐条比对的一致度。
//!
//! PHP-Parser 是**开发期参照**而非构建依赖：未提供路径时本工具直接成功退出，
//! 下游 clone 不会因缺少参照而构建失败。
//!
//! 用法（仓库根）：
//!   zig build conformance -- --php-parser <PHP-Parser 仓库根或 test/code/parser>
//!                             [--report-dir <目录>]    默认 zig-out/conformance
//!                             [--known-diffs <文件>]   默认 tools/known_diffs.txt
//! 产物：<report-dir>/acceptance_report.txt（误拒/漏报清单）、
//!       <report-dir>/diagnostic_report.txt（诊断质量统计与差异明细）。
//!
//! 门禁数据（`known_diffs.txt`）：首行 `baseline=N` 为全等段数下限；其余每行
//! `<段标识> <类别> <成因说明>`，段标识即报告里的 `路径[段号]`。
//!
//! `.test` 段格式见 `tools/fixtures.zig`。

const std = @import("std");
const ast = @import("ast"); // src/ast.zig（见 build.zig 的模块映射）
const fixtures = @import("fixtures.zig");

/// 默认报告目录：生成物，不入库。
const DEFAULT_REPORT_DIR = "zig-out/conformance";
/// 默认门禁数据文件（白名单 + 基线），相对仓库根。
const DEFAULT_KNOWN_DIFFS = "tools/known_diffs.txt";
/// 接受面报告文件名：本库接受/拒绝与 oracle 不一致的段（误拒 / 漏报）。
const ACCEPTANCE_REPORT = "acceptance_report.txt";
/// 诊断质量报告文件名：两边都报的段里，条数/文本/位置的一致度与差异明细。
const DIAGNOSTIC_REPORT = "diagnostic_report.txt";

fn usage() void {
    std.debug.print(
        \\用法: --php-parser <PHP-Parser 仓库根或 test/code/parser> [--report-dir <目录>] [--known-diffs <文件>]
        \\  未提供 --php-parser 时跳过（该参数是本工具唯一的外部依赖）。
        \\
    , .{});
}

/// 入口（0.16 启动器自动构造 `std.process.Init`，含默认 io）。分配用
/// `page_allocator`：单次运行的开发工具，进程退出即回收全部内存。
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

    var parser_arg: ?[]const u8 = null;
    var report_dir: []const u8 = DEFAULT_REPORT_DIR;
    var known_path: []const u8 = DEFAULT_KNOWN_DIFFS;

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
        } else if (std.mem.eql(u8, a, "--report-dir")) {
            i += 1;
            if (i >= argv.items.len) {
                usage();
                return error.InvalidArgs;
            }
            report_dir = argv.items[i];
        } else if (std.mem.eql(u8, a, "--known-diffs")) {
            i += 1;
            if (i >= argv.items.len) {
                usage();
                return error.InvalidArgs;
            }
            known_path = argv.items[i];
        } else if (std.mem.eql(u8, a, "-h") or std.mem.eql(u8, a, "--help")) {
            usage();
            return;
        } else {
            std.debug.print("未知参数: {s}\n", .{a});
            usage();
            return error.InvalidArgs;
        }
    }

    const raw_parser = parser_arg orelse {
        std.debug.print("未提供 --php-parser：本工具以 PHP-Parser 为参照，跳过对照。\n", .{});
        usage();
        return;
    };
    const parser_dir = fixtures.resolveParserDir(gpa, io, raw_parser) catch {
        std.debug.print("找不到 PHP-Parser 测试用例目录: {s}\n", .{raw_parser});
        return error.ParserDirNotFound;
    };
    defer gpa.free(parser_dir);

    try std.Io.Dir.cwd().createDirPath(io, report_dir);
    const accept_path = try std.fs.path.join(gpa, &.{ report_dir, ACCEPTANCE_REPORT });
    defer gpa.free(accept_path);
    const diag_path = try std.fs.path.join(gpa, &.{ report_dir, DIAGNOSTIC_REPORT });
    defer gpa.free(diag_path);
    try runChecks(gpa, io, parser_dir, accept_path, diag_path, known_path);
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

/// 门禁数据：全等段数下限 + 已知未对齐段白名单。数据落在 `tools/known_diffs.txt`
/// （`--known-diffs` 可覆盖），白名单维护不必改代码，也不会被误当作代码改动。
const GateData = struct {
    /// 全等段数下限（文件里的 `baseline=N`）；0 表示未声明（不做该判定）。
    baseline: usize = 0,
    /// 白名单段标识。
    entries: []const []const u8 = &.{},

    /// 段标识是否在白名单内（容忍路径分隔符差异）。
    fn isKnown(self: GateData, id: []const u8) bool {
        for (self.entries) |e| {
            if (samePath(e, id)) return true;
        }
        return false;
    }
};

/// 读门禁数据文件。文件缺失即报错——它是入库的受控资产，缺失属异常状态，
/// 不能退化为「只报告不判定」而让门禁静默失效。
fn loadGate(gpa: std.mem.Allocator, io: std.Io, path: []const u8) !GateData {
    const content = try fixtures.readFile(gpa, io, path);
    defer gpa.free(content);

    var data = GateData{};
    var list: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, content, '\n');
    while (it.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        if (std.mem.startsWith(u8, line, "baseline=")) {
            const v = std.mem.trim(u8, line["baseline=".len..], " \t");
            data.baseline = std.fmt.parseInt(usize, v, 10) catch 0;
            continue;
        }
        // 每行格式：`<段标识> <类别> <成因说明>`，首个空白前是段标识
        const sp = std.mem.indexOfAny(u8, line, " \t") orelse line.len;
        const id = gpa.dupe(u8, line[0..sp]) catch continue;
        list.append(gpa, id) catch continue;
    }
    data.entries = list.toOwnedSlice(gpa) catch &.{};
    return data;
}

/// 段标识比较：容忍路径分隔符差异（fixture 相对路径在不同平台为 `\` 或 `/`）。
fn samePath(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        const nx: u8 = if (x == '\\') '/' else x;
        const ny: u8 = if (y == '\\') '/' else y;
        if (nx != ny) return false;
    }
    return true;
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

fn scanOne(gpa: std.mem.Allocator, rel: []const u8, flat: []const u8, rep: *Report, mrep: ?*MsgReport) !void {
    const parsed = try fixtures.parse(gpa, flat);
    defer gpa.free(parsed.segments);
    rep.unpaired += parsed.unpaired;

    for (parsed.segments) |seg| {
        const expect_ok = std.mem.startsWith(u8, seg.expect, "array(");
        rep.segments += 1;
        if (expect_ok) rep.accept_expected += 1 else rep.error_expected += 1;

        // @@{expr}@@ 注入宏：双引号串 unescape 为内容、其它表达式占位 0。注入只改
        // 文本内容不改变语法类别，对接受/拒绝判定等价（heredoc 内容常以此宏写跨行体）。
        const expanded = try fixtures.expandAtAt(gpa, seg.code);
        defer gpa.free(expanded);
        const src = try gpa.dupeZ(u8, expanded);
        defer gpa.free(src);
        var tree = try ast.Ast.parse(gpa, src, .{ .id = seg.version_id });
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
        const path = try std.fmt.allocPrint(gpa, "{s}[{d}]", .{ rel, seg.index });
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
                    // WantMsg 的 raw/full 均借用 `seg.expect` 切片，只释放列表本身
                    var wants = try extractWantMsgs(gpa, seg.expect);
                    defer wants.deinit(gpa);
                    try compareMsgs(gpa, mr, path, wants.items, &tree, ck.errors.items, src);
                }
            }
        }
    }
    // 孤立代码段（期望缺失）由 `fixtures.parse` 统计
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
    known_path: []const u8,
) !void {
    const rels = try fixtures.collectTestFiles(gpa, io, parser_dir);
    defer {
        for (rels) |r| gpa.free(r);
        gpa.free(rels);
    }

    const gate = loadGate(gpa, io, known_path) catch |e| {
        std.debug.print("门禁数据不可用 {s}: {s}\n", .{ known_path, @errorName(e) });
        return error.GateDataMissing;
    };

    var rep = Report.init(gpa);
    defer rep.deinit();

    var mrep = MsgReport.init(gpa);
    defer mrep.deinit();

    for (rels) |rel| {
        const full_path = try std.fs.path.join(gpa, &.{ parser_dir, rel });
        defer gpa.free(full_path);
        const flat = fixtures.readTestFlat(gpa, io, full_path) catch |e| {
            std.debug.print("读取失败 {s}: {s}\n", .{ rel, @errorName(e) });
            continue;
        };
        defer gpa.free(flat);
        try scanOne(gpa, rel, flat, &rep, &mrep);
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
        .{ parser_dir, rels.len, rep.segments, rep.accept_expected, rep.error_expected, rep.accept_clean, rep.false_reject, rep.both_reported, rep.missed_error },
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

    try writeDiagnosticReport(gpa, io, &mrep, parser_dir, diag_path, gate);
}

/// 诊断质量报告：两边都报的段里，消息 条数/文本/位置 的一致度与差异明细，
/// 写完后做防回归判定（白名单 + 基线）。文本比较口径：先比正文（去掉 `from..to`），
/// 正文全等才比位置——故四类互斥。
fn writeDiagnosticReport(
    gpa: std.mem.Allocator,
    io: std.Io,
    mrep: *MsgReport,
    parser_dir: []const u8,
    diag_path: []const u8,
    gate: GateData,
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
        .{ parser_dir, s.total, s.full_match, s.count_diff, s.raw_diff, s.pos_diff, if (s.total == 0) 0 else s.full_match * 100 / s.total },
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

    // ---- 防回归门禁 ----
    // 报告写完再判定，保证失败时仍能读到明细：未对齐段必须全部落在白名单内，
    // 且全等段数不得低于基线。门禁数据缺失（baseline=0 且白名单为空）时只报告。
    if (gate.baseline == 0 and gate.entries.len == 0) {
        std.debug.print("门禁数据为空：本次只报告不判定。\n", .{});
        return;
    }
    var unexpected: usize = 0;
    for (mrep.diffs.items) |d| {
        if (!gate.isKnown(d.path)) {
            std.debug.print("未在白名单的差异: {s}（{s}）\n", .{ d.path, d.kind });
            unexpected += 1;
        }
    }
    if (unexpected > 0) return error.ConformanceRegression;
    if (gate.baseline > 0 and mrep.stat.full_match < gate.baseline) {
        std.debug.print(
            "诊断全等段数退化: {d} < {d}（基线）\n",
            .{ mrep.stat.full_match, gate.baseline },
        );
        return error.ConformanceRegression;
    }
}
