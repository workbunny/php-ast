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
    tok_i: TokenIndex,

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

    /// 记录一条解析错误（不中断解析，继续向前兼容最坏情况）。
    pub fn warn(p: *Parser, tag: ast.Error.Tag) void {
        p.errors.append(p.gpa, .{ .tag = tag, .token = p.tok_i, .required = BASE_VERSION }) catch {};
    }

    /// 取走当前 token 并把游标推进到下一位，返回被取走的 token。
    pub fn nextToken(p: *Parser) TokenIndex {
        const ti = p.tok_i;
        p.tok_i += 1;
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

    /// 跳过到下一个语句边界：跨过 `;`、区块、行注释或文件尾。
    pub fn skipToNextStmt(p: *Parser) ast.ParseError!void {
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
