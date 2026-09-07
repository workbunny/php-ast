const std = @import("std");
const ast = @import("ast.zig");
const Token = @import("token.zig").Token;
const PhpVersion = @import("version.zig").PhpVersion;
const BASE_VERSION = @import("version.zig").BASE_VERSION;
const stmt = @import("parser_stmt.zig");
const testing = @import("testing.zig");

const Node = ast.Node;
const Index = ast.Index;
const OptionalIndex = ast.OptionalIndex;
const SubRange = ast.SubRange;
const ListRange = ast.ListRange;
const ExtraIndex = ast.ExtraIndex;
const TokenIndex = ast.TokenIndex;

/// 共享解析机件（节点 / extra / 列表写入、token 前进、错误恢复、根入口）。
///
/// 具体的 `parse*` 语法函数分布在 `parser_stmt.zig` / `parser_decl.zig` /
/// `parser_expr.zig` / `parser_type.zig`，均以自由函数形式接收 `*Parser`；
/// 本文件只持有 `Parser` 结构定义与所有函数共用的小工具，便于按语法域拆分而不破坏
/// 单一的 SoA 节点表示（`Node { tag, main_token, data }` + `extra_data` 大板）。
pub const Parser = struct {
    gpa: std.mem.Allocator,
    source: [:0]const u8,
    tokens: Token.TokenList.Slice,
    nodes: ast.NodeList,
    extra_data: std.ArrayList(u32),
    errors: std.ArrayList(ast.Error),
    /// 与 `nodes` 等长：按节点顺序记录「引入版本」，`BASE_VERSION` 表示基础语法。
    node_versions: std.ArrayList(PhpVersion),
    /// 目标解析版本（`Ast.parse` 传入）。解析期内作**反向/消歧**判断用：如花括号
    /// 下标 `$a{'b'}` 是 ≤7.4 语法，8.0+ 不消费 `{` 为下标（避免误吞属性钩子/块）。
    version: PhpVersion,
    tok_i: TokenIndex,
    /// 已解析 `__HALT_COMPILER()`：其后的 token 流被整体截断（tok_i 置 eof），
    /// 外层块的「未闭合」是 halt 语义所致，不应按缺 `}` 报错。
    halted: bool = false,

    pub fn addNode(p: *Parser, elem: Node) ast.ParseError!?Index {
        try p.nodes.append(p.gpa, elem);
        try p.node_versions.append(p.gpa, ast.tagVersion(elem.tag));
        return @enumFromInt(p.nodes.len - 1);
    }

    /// 把一个 `Components` 负载序列化进 `extra_data`，返回起点下标。
    /// 字段顺序与 `Ast.extraData` 的反序列化顺序严格对齐。
    pub fn addExtra(p: *Parser, extra: anytype) ast.ParseError!ExtraIndex {
        const result = @as(ExtraIndex, @enumFromInt(p.extra_data.items.len));
        inline for (std.meta.fields(@TypeOf(extra))) |field| {
            const v = @field(extra, field.name);
            const T = field.type;
            if (T == SubRange) {
                try p.extra_data.append(p.gpa, @intFromEnum(v.start));
                try p.extra_data.append(p.gpa, @intFromEnum(v.end));
                continue;
            }
            try p.extra_data.append(p.gpa, switch (T) {
                Index,
                OptionalIndex,
                ast.OptionalTokenIndex,
                ExtraIndex,
                => @intFromEnum(v),
                bool => @intFromBool(v),
                u32 => v,
                else => @compileError("unsupported extra field type: " ++ @typeName(T)),
            });
        }
        return result;
    }

    /// 把一组 `Index` 写入 `extra_data`，返回其 `ListRange`。
    pub fn addNodeList(p: *Parser, list: []const Index) ast.ParseError!ListRange {
        const start: ExtraIndex = @enumFromInt(p.extra_data.items.len);
        for (list) |item| {
            try p.extra_data.append(p.gpa, @intFromEnum(item));
        }
        const end: ExtraIndex = @enumFromInt(p.extra_data.items.len);
        return .{ .start = start, .end = end };
    }

    /// 在 `extra_data` 末尾占一个空区间（start == end）。
    pub fn emptyRange(p: *Parser) ListRange {
        const i: ExtraIndex = @enumFromInt(p.extra_data.items.len);
        return .{ .start = i, .end = i };
    }

    /// 空 `SubRange`（start == end）。
    pub fn emptySubRange(p: *Parser) SubRange {
        const i: ExtraIndex = @enumFromInt(p.extra_data.items.len);
        return .{ .start = i, .end = i };
    }

    /// 记录一条解析错误（不中断解析，继续向前兼容最坏情况）。诊断区间为当前 token。
    pub fn warn(p: *Parser, tag: ast.Error.Tag) void {
        p.warnRange(tag, p.tok_i, p.tok_i);
    }

    /// 记录一条定位到指定 token 的解析错误（调用方在消费 token 前保留其下标）。
    pub fn warnAt(p: *Parser, tag: ast.Error.Tag, token: TokenIndex) void {
        p.warnRange(tag, token, token);
    }

    /// 记录一条覆盖 token 区间 `[start, end]`（均含）的诊断，供消息渲染取用范围。
    pub fn warnRange(p: *Parser, tag: ast.Error.Tag, start: TokenIndex, end: TokenIndex) void {
        p.addErrorRange(tag, start, end, start, 0);
    }

    /// 记录带附加 token 与数值参数的诊断（消息需引用具体文本/数值时使用）。
    pub fn addError(
        p: *Parser,
        tag: ast.Error.Tag,
        start: TokenIndex,
        end: TokenIndex,
        aux: TokenIndex,
        data: u32,
    ) void {
        p.addErrorRange(tag, start, end, aux, data);
    }

    fn addErrorRange(
        p: *Parser,
        tag: ast.Error.Tag,
        start: TokenIndex,
        end: TokenIndex,
        aux: TokenIndex,
        data: u32,
    ) void {
        // 错误恢复常在同一点多次触发**同一判据**（相邻 last 同 tag 同区间即视为
        // 重复，不再报）。不同 tag 可同区间并存（php-parser 对同一 token 会报多条
        // 不同消息，如钩子上的 `public public` = hook modifier + Multiple access）。
        if (p.errors.items.len > 0) {
            const last = p.errors.items[p.errors.items.len - 1];
            if (last.tag == tag and last.token == start and last.token_end == end) return;
        }
        p.errors.append(p.gpa, .{
            .tag = tag,
            .token = start,
            .token_end = end,
            .aux = aux,
            .data = data,
            .required = BASE_VERSION,
        }) catch {};
    }

    /// 语句收尾缺分号诊断。PHP 允许语句后紧跟结束标签 `?>` 时省略分号
    /// （`<?php echo 1 ?>` 合法），故当前 token 是 close_tag 时不报。
    pub fn warnMissingSemi(p: *Parser) void {
        if (p.tokTag() != .close_tag) p.warn(ast.Error.Tag.expected_semi);
    }

    /// 取走当前 token 并把游标推进到下一位，返回被取走的 token。
    ///
    /// eof 是 token 流的结构性终点（末尾哨兵，恒为末位），对它的「消费」应停在原地：
    /// 各解析函数在缺必需 token 时可能先消费分隔符再失败返回 null，若允许越过 eof，
    /// 上层错误恢复会把越界下标读崩。停在 eof 让此类残留无害化——诊断已由
    /// `expectToken`/`warn` 记录，AST 只是不再前进。
    pub fn nextToken(p: *Parser) TokenIndex {
        const ti = p.tok_i;
        if (p.tokens.items(.tag)[ti] != .eof) p.tok_i += 1;
        return ti;
    }

    /// 返回某节点所锚定的主 token（即其 main_token 字段）。
    pub fn nodeMainToken(p: *const Parser, idx: Index) TokenIndex {
        return p.nodes.items(.main_token)[@intFromEnum(idx)];
    }

    /// 当前 token 匹配 tag 则取走并返回，否则仅报警告并返回 null。
    pub fn expectToken(p: *Parser, tag: Token.Tag) ?TokenIndex {
        if (p.tokTag() == tag) return p.nextToken();
        p.warn(ast.Error.Tag.expected_token);
        return null;
    }

    /// 当前 token 匹配 tag 则取走并返回，否则直接返回 null。
    pub fn eatToken(p: *Parser, tag: Token.Tag) ?TokenIndex {
        if (p.tokTag() == tag) {
            return p.nextToken();
        }
        return null;
    }

    /// 当前游标 token 的 tag；token 序列耗尽时为 eof。
    pub fn tokTag(p: *const Parser) Token.Tag {
        return p.tokens.items(.tag)[p.tok_i];
    }

    /// 返回当前游标 token 对应的源片段切片。
    pub fn tokSlice(p: *const Parser) []const u8 {
        const s = p.tokens.items(.start)[p.tok_i];
        const e = p.tokens.items(.end)[p.tok_i];
        return p.source[s..e];
    }

    /// 判断当前 token 是否为指定拼写的小写「软关键字」（如 get/set）。
    pub fn isSoftKw(p: *const Parser, kw: []const u8) bool {
        return p.tokTag() == .identifier and std.mem.eql(u8, p.tokSlice(), kw);
    }

    /// 跳过注释 token（PHP 中注释等价空白，可出现在语句收尾分号等 token 之前）。
    pub fn skipComments(p: *Parser) void {
        while (p.tokTag() == .comment or p.tokTag() == .doc_comment) _ = p.nextToken();
    }

    /// 列表分隔符：消费 `,` 并继续。
    ///
    /// `allow_trailing` 为假时（PHP 不允许尾逗号的位置：`echo` / `global` / `static`
    /// 变量 / const 声明 / implements / extends / use / 属性声明 / declare / for 表达式
    /// 等），若 `,` 紧邻结束定界符（由调用方给出集合）则是尾逗号：报
    /// `trailing_comma` 并消费它，返回 false 表示列表结束（php-parser 同：报一条
    /// 专用错误，不按「缺元素」处理，也不影响后续解析）。
    ///
    /// `allow_trailing` 为真时（函数调用实参、数组字面量、参数表、组 use 等）不检查。
    pub fn eatListComma(
        p: *Parser,
        allow_trailing: bool,
        terminators: []const Token.Tag,
    ) bool {
        if (p.tokTag() != .comma) return false;
        const comma = p.tok_i;
        _ = p.nextToken();
        if (!allow_trailing) {
            for (terminators) |t| {
                if (p.tokTag() == t) {
                    p.warnAt(ast.Error.Tag.trailing_comma, comma);
                    return false;
                }
            }
        }
        return true;
    }

    /// 错误恢复：跳过到「语句同步点」——下一个 `;`（消费）、块闭合 `}`/EOF/close_tag
    /// （不消费），或可作新语句起始的 token（不消费）。
    ///
    /// 比 `skipToNextStmt` 保守：不会吞掉后续语句（php-parser 在语句起始 token 处即可
    /// 重新同步，缺分号后的 `bar()` / `baz()` 是两个错误而非一个）。
    /// `consume_rbrace`：真则在 `}` 处一并消费。表达式语句的恢复里遇到 `}` 说明该
    /// 花括号是表达式的一部分（`['b']` 的花括号下标），应继续跳到 `;`；块内恢复
    /// 时 `}` 是块闭合，不应消费。
    pub fn skipToStmtSync(p: *Parser, consume_rbrace: bool) void {
        while (true) {
            switch (p.tokTag()) {
                .eof, .close_tag => return,
                .rbrace => {
                    if (consume_rbrace) _ = p.nextToken() else return;
                },
                .semicolon => {
                    _ = p.nextToken();
                    return;
                },
                else => {
                    if (isStmtStartTag(p.tokTag())) return;
                    _ = p.nextToken();
                },
            }
        }
    }

    /// 能否作为一条新语句的起始 token（错误恢复的同步点判定）。标识符亦计入——
    /// 吞掉后续语句（漏报其错误）比在该点多报一条更不可接受。
    fn isStmtStartTag(tag: Token.Tag) bool {
        return switch (tag) {
            .variable, .hash, .dollar, .identifier => true,
            .kw_function, .kw_class, .kw_if, .kw_while, .kw_for, .kw_foreach,
            .kw_return, .kw_echo, .kw_use, .kw_namespace, .kw_const, .kw_switch,
            .kw_try, .kw_throw, .kw_do, .kw_break, .kw_continue, .kw_global,
            .kw_unset, .kw_list, .kw_new, .kw_clone, .kw_match, .kw_goto,
            .kw_declare, .kw_interface, .kw_trait, .kw_enum, .kw_abstract,
            .kw_final, .kw_readonly, .kw_print, .kw_case, .kw_default, .kw_elseif,
            .kw_else, .kw_catch, .kw_finally, .kw_endif, .kw_endwhile, .kw_endfor,
            .kw_endforeach, .kw_endswitch, .kw_fn, .kw_require, .kw_require_once,
            .kw_include, .kw_include_once, .kw_exit, .kw_eval, .kw_isset,
            .kw_empty, .kw_yield, .kw_array, => true,
            else => false,
        };
    }

    /// 跳过到下一个语句边界：先前进一个 token（保证恢复收敛），再跳到「语句同步点」
    /// ——`;`（消费）、块闭合 `}`/EOF/close_tag（不消费），或可作新语句起始的 token
    /// （不消费）。
    ///
    /// 不整块吞掉后续声明：语句起始 token（`class`/`function`/`$x` 等）处即重新同步，
    /// 使后续语句自身的错误也能被报出（php-parser 同）。
    pub fn skipToNextStmt(p: *Parser) ast.ParseError!void {
        if (p.tokTag() != .eof) _ = p.nextToken();
        p.skipToStmtSync(false);
    }

    /// 原始实现：跨过 `;`、区块、行注释或文件尾（吞掉整块）。
    pub fn skipToNextStmtBlock(p: *Parser) ast.ParseError!void {
        while (p.tokTag() != .eof) : (p.tok_i += 1) {
            switch (p.tokTag()) {
                .semicolon, .rbrace, .eof => {
                    p.tok_i += 1;
                    return;
                },
                .close_tag => return,
                else => {},
            }
        }
    }

    pub fn parseRoot(p: *Parser) ast.ParseError!Index {
        while (p.tokTag() == .open_tag) _ = p.nextToken();

        var stmts = try std.ArrayList(Index).initCapacity(p.gpa, 0);
        defer stmts.deinit(p.gpa);

        while (p.tokTag() != .eof) {
            const node = try stmt.parseStatement(p) orelse {
                try p.skipToNextStmt();
                if (p.tokTag() == .close_tag) _ = p.nextToken();
                continue;
            };
            try stmts.append(p.gpa, node);
            if (p.tokTag() == .close_tag) _ = p.nextToken();
            if (p.tokTag() == .rbrace) _ = p.nextToken();
        }

        const lr = try p.addNodeList(stmts.items);
        const root_node: Index = (try p.addNode(.{
            .tag = .root,
            .main_token = 0,
            .data = .{ .extra_range = .{ .start = lr.start, .end = lr.end } },
        })) orelse unreachable;
        return root_node;
    }
};

// ===========================================================================
// 测试：错误恢复与诊断收集
// ===========================================================================

test "parser :: 错误恢复 :: 缺表达式产出 stmt_error 而非中断" {
    const gpa = std.testing.allocator;
    var tree = try ast.Ast.parse(gpa, "<?php $a = ;", testing.v84);
    defer tree.deinit(gpa);
    // 解析不致命：错误以诊断形式收集，并保留错误节点
    try std.testing.expect(testing.countTag(tree,.stmt_error) >= 1);
}

test "parser :: 错误恢复 :: 出错后继续解析后续语句" {
    const gpa = std.testing.allocator;
    var tree = try ast.Ast.parse(gpa, "<?php $a = ; $b = 42;", testing.v84);
    defer tree.deinit(gpa);
    try std.testing.expect(tree.errors.len >= 1);
    // 出错点之后的合法语句仍应被解析出来
    try std.testing.expectEqual(@as(usize, 1), testing.countTag(tree,.expr_int));
}

test "parser :: 多错误 :: 一次收集全部诊断而非遇错即停" {
    const gpa = std.testing.allocator;
    var tree = try ast.Ast.parse(gpa, "<?php => 1; => 2;", testing.v84);
    defer tree.deinit(gpa);
    try std.testing.expect(tree.errors.len >= 2);
}

test "parser :: 未闭合括号 :: 产出诊断且不崩溃" {
    const gpa = std.testing.allocator;
    var tree = try ast.Ast.parse(gpa, "<?php if ($a { }", testing.v84);
    defer tree.deinit(gpa);
    try std.testing.expect(tree.errors.len >= 1);
}

test "parser :: 空输入 :: 产出空 root 而非错误" {
    const gpa = std.testing.allocator;
    var tree = try ast.Ast.parse(gpa, "<?php", testing.v84);
    defer tree.deinit(gpa);
    try testing.expectNoErrors(tree);
    try std.testing.expectEqual(@as(usize, 0), tree.rootStmts().len);
}
