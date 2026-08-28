const std = @import("std");
const ast = @import("ast.zig");
const Token = @import("token.zig").Token;
const Parser = @import("parser.zig").Parser;

const Node = ast.Node;
const Index = ast.Index;
const OptionalIndex = ast.OptionalIndex;
const SubRange = ast.SubRange;
const ListRange = ast.ListRange;
const ExtraIndex = ast.ExtraIndex;
const TokenIndex = ast.TokenIndex;
const PhpVersion = @import("version.zig").PhpVersion;

const decl = @import("parser_decl.zig");
const expr = @import("parser_expr.zig");

const OptionalTokenIndex = ast.OptionalTokenIndex;
const Tag = ast.Node.Tag;

/// if / while / for / foreach / namespace 等复合语句的附加负载，序列化进 `extra_data`。
pub const IfComponents = struct {
    cond: Index,
    then_body: Index,
    else_body: OptionalIndex,
};

pub const WhileComponents = struct {
    cond: Index,
    body: Index,
};

pub const ForComponents = struct {
    init: Index,
    cond: Index,
    inc: Index,
    body: Index,
};

pub const ForeachComponents = struct {
    expr: Index,
    key: OptionalIndex,
    value: Index,
    body: Index,
};

pub const NamespaceComponents = struct {
    name: OptionalIndex,
    stmts: SubRange,
};

/// do / switch / try / use / trait / declare / static 等语句的附加负载组件。
pub const DoComponents = struct { cond: Index, body: Index };
pub const SwitchComponents = struct { cond: Index, cases: SubRange };
pub const CaseStmtComponents = struct { stmts: SubRange };
pub const TryComponents = struct { catches: SubRange, finally: OptionalIndex };
pub const CatchComponents = struct { types: SubRange, body: Index };
pub const UseComponents = struct { uses: SubRange, kind: u32 };
pub const UseUseComponents = struct { alias: TokenIndex, kind: u32 };
pub const GroupUseComponents = struct { uses: SubRange, kind: u32 };
pub const TraitUseComponents = struct { traits: SubRange, adaptations: SubRange };
pub const TraitAdaptAliasComponents = struct { trait: OptionalIndex, method: TokenIndex, modifier: OptionalTokenIndex, alias: OptionalTokenIndex };
pub const TraitAdaptPrecComponents = struct { trait: OptionalIndex, method: TokenIndex, insteadof: SubRange };
pub const DeclareComponents = struct { declares: SubRange, stmts: OptionalIndex };
pub const StaticVarComponents = struct { name: TokenIndex, default: OptionalIndex };

/// 判断 token 是否为可见性修饰符（public/protected/private）。
fn isVisibility(tag: Token.Tag) bool {
    return tag == .kw_public or tag == .kw_protected or tag == .kw_private;
}

/// 语句解析总入口：按首 token 分派到具体 parse*；跳过 open/close_tag、注释、
/// InlineHTML 等包裹性 token。裸 `;` 产出 `Stmt\Nop`；无法识别的 token 产出
/// `Stmt\Error`；返回 null 仅用于 eof / 右花括号等结构性边界。
pub fn parseStatement(p: *Parser) ast.ParseError!?Index {
    const tk = p.tok_i;
    switch (p.tokTag()) {
        .eof, .rbrace => return null,
        .semicolon => {
            _ = p.nextToken();
            return (try p.addNode(.{
                .tag = .stmt_nop,
                .main_token = tk,
                .data = .{ .token = tk },
            })) orelse unreachable;
        },
        .kw_if => return parseIf(p),
        .kw_while => return parseWhile(p),
        .kw_for => return parseFor(p),
        .kw_foreach => return parseForeach(p),
        .kw_function => return decl.parseFunction(p, try decl.parseAttrGroups(p)),
        .kw_class => return decl.parseClass(p, try decl.parseAttrGroups(p)),
        .kw_enum => return decl.parseTypeDecl(p, .stmt_enum, try decl.parseAttrGroups(p)),
        .kw_interface => return decl.parseTypeDecl(p, .stmt_interface, try decl.parseAttrGroups(p)),
        .kw_trait => return decl.parseTypeDecl(p, .stmt_trait, try decl.parseAttrGroups(p)),
        .kw_namespace => return parseNamespace(p),
        .kw_return => return parseReturn(p),
        .kw_echo => return parseEcho(p),
        .kw_do => return parseDo(p),
        .kw_break, .kw_continue => return parseBreakOrContinue(p),
        .kw_switch => return parseSwitch(p),
        .kw_throw => return parseThrowStmt(p),
        .kw_try => return parseTry(p),
        .kw_const => return parseConst(p, p.emptySubRange()),
        .kw_use => return parseUse(p),
        .kw_declare => return parseDeclare(p),
        .kw_goto => return parseGoto(p),
        .kw_global => return parseGlobal(p),
        .kw_static => return parseStatic(p),
        .kw_unset => return parseUnset(p),
        .hash => {
            const attrs = try decl.parseAttrGroups(p);
            return switch (p.tokTag()) {
                .kw_function => decl.parseFunction(p, attrs),
                .kw_class => decl.parseClass(p, attrs),
                .kw_enum => decl.parseTypeDecl(p, .stmt_enum, attrs),
                .kw_interface => decl.parseTypeDecl(p, .stmt_interface, attrs),
                .kw_trait => decl.parseTypeDecl(p, .stmt_trait, attrs),
                .kw_const => parseConst(p, attrs),
                else => {
                    p.warn(ast.Error.Tag.expected_token);
                    return null;
                },
            };
        },
        .open_tag => {
            _ = p.nextToken();
            return parseStatement(p);
        },
        .close_tag => {
            _ = p.nextToken();
            return parseStatement(p);
        },
        .inline_html => {
            const t = p.nextToken();
            return (try p.addNode(.{
                .tag = .inline_html,
                .main_token = t,
                .data = .{ .token = t },
            })) orelse unreachable;
        },
        .comment, .doc_comment => {
            _ = p.nextToken();
            return parseStatement(p);
        },
        else => {
            // 标签：`identifier :`，仅当其后紧跟冒号时成立。
            if (p.tokTag() == .identifier and p.tok_i + 1 < p.tokens.len and
                p.tokens.items(.tag)[p.tok_i + 1] == .colon)
            {
                return parseLabel(p);
            }
            // __halt_compiler()：解析到此停止。
            if (p.tokTag() == .identifier) {
                const s = p.tokens.items(.start)[p.tok_i];
                const e = p.tokens.items(.end)[p.tok_i];
                if (std.mem.eql(u8, p.source[s..e], "__halt_compiler")) {
                    return parseHaltCompiler(p);
                }
            }
            // 无法识别的 token：保留为错误节点而非静默丢弃，便于上层错误恢复。
            const e = try parseExprStatement(p);
            if (e == null) {
                // parseExpr 未能消费当前 token（该 token 不能作表达式起始），必须先前进游标，
                // 否则 parseRoot 的主循环会原地重复产出错误节点、不断追加 stmt_error 直至内存耗尽。
                _ = p.nextToken();
                return (try p.addNode(.{
                    .tag = .stmt_error,
                    .main_token = tk,
                    .data = .{ .token = tk },
                })) orelse unreachable;
            }
            return e;
        },
    }
}

/// 表达式语句：解析一个表达式并消费结尾 `;`，如 `$a = 1;` 或 `foo();`。
pub fn parseExprStatement(p: *Parser) ast.ParseError!?Index {
    const e = try expr.parseExpr(p);
    if (e == null) return null;
    const ex = e.?;
    _ = p.eatToken(.semicolon);
    return (try p.addNode(.{
        .tag = .stmt_expression,
        .main_token = p.nodeMainToken(ex),
        .data = .{ .node = ex },
    })) orelse unreachable;
}

/// 语句块 `{ ... }`：解析到匹配的 `}` 为止，内部语句收集为 stmt_block。
pub fn parseBlock(p: *Parser) ast.ParseError!?Index {
    const lbrace = p.expectToken(.lbrace);
    var stmts = try std.ArrayList(Index).initCapacity(p.gpa, 0);
    defer stmts.deinit(p.gpa);
    while (p.tokTag() != .rbrace and p.tokTag() != .eof) {
        const s = (try parseStatement(p)) orelse {
            try p.skipToNextStmt();
            if (p.tokTag() == .close_tag) _ = p.nextToken();
            continue;
        };
        try stmts.append(p.gpa, s);
        if (p.tokTag() == .close_tag) _ = p.nextToken();
    }
    _ = p.eatToken(.rbrace);
    const lr = try p.addNodeList(stmts.items);
    const token: TokenIndex = if (stmts.items.len > 0) p.nodeMainToken(stmts.items[0]) else lbrace orelse 0;
    return (try p.addNode(.{
        .tag = .stmt_block,
        .main_token = token,
        .data = .{ .extra_range = .{ .start = lr.start, .end = lr.end } },
    })) orelse unreachable;
}

/// if 语句，支持 elseif 链与 else 分支：
/// `if ($a) { } elseif ($b) { } else { }`
pub fn parseIf(p: *Parser) ast.ParseError!?Index {
    const kw = p.nextToken();
    _ = p.expectToken(.lparen);
    const cond = (try expr.parseExpr(p)) orelse return null;
    _ = p.expectToken(.rparen);
    const then_b = (try parseStatement(p)) orelse return null;

    var else_b: ?Index = null;
    if (p.tokTag() == .kw_elseif) {
        else_b = (try parseIf(p)) orelse null;
    } else if (p.tokTag() == .kw_else) {
        _ = p.nextToken();
        else_b = (try parseStatement(p)) orelse null;
    }

    const components = IfComponents{
        .cond = cond,
        .then_body = then_b,
        .else_body = if (else_b) |b| OptionalIndex.fromIndex(b) else .none,
    };
    const extra = try p.addExtra(components);
    return (try p.addNode(.{
        .tag = .stmt_if,
        .main_token = kw,
        .data = .{ .extra_and_opt_node = .{ extra, components.else_body } },
    })) orelse unreachable;
}

/// while 循环：`while (cond) body`。
pub fn parseWhile(p: *Parser) ast.ParseError!?Index {
    const kw = p.nextToken();
    _ = p.expectToken(.lparen);
    const cond = (try expr.parseExpr(p)) orelse return null;
    _ = p.expectToken(.rparen);
    const body = (try parseStatement(p)) orelse return null;
    const extra = try p.addExtra(WhileComponents{ .cond = cond, .body = body });
    return (try p.addNode(.{
        .tag = .stmt_while,
        .main_token = kw,
        .data = .{ .extra_and_node = .{ extra, body } },
    })) orelse unreachable;
}

/// for 循环：`for (init; cond; inc) body`。
pub fn parseFor(p: *Parser) ast.ParseError!?Index {
    const kw = p.nextToken();
    _ = p.expectToken(.lparen);
    const init = (try expr.parseExpr(p)) orelse return null;
    _ = p.expectToken(.semicolon);
    const cond = (try expr.parseExpr(p)) orelse return null;
    _ = p.expectToken(.semicolon);
    const inc = (try expr.parseExpr(p)) orelse return null;
    _ = p.expectToken(.rparen);
    const body = (try parseStatement(p)) orelse return null;
    const extra = try p.addExtra(ForComponents{ .init = init, .cond = cond, .inc = inc, .body = body });
    return (try p.addNode(.{
        .tag = .stmt_for,
        .main_token = kw,
        .data = .{ .extra_and_node = .{ extra, body } },
    })) orelse unreachable;
}

/// foreach 循环：`foreach ($it as $k => $v) body`。
pub fn parseForeach(p: *Parser) ast.ParseError!?Index {
    const kw = p.nextToken();
    _ = p.expectToken(.lparen);
    const e = (try expr.parseExpr(p)) orelse return null;
    _ = p.expectToken(.kw_as);
    const key = if (p.tokTag() == .double_arrow) blk: {
        _ = p.nextToken();
        const k = (try expr.parseExpr(p)) orelse return null;
        break :blk OptionalIndex.fromIndex(k);
    } else .none;
    const value = (try expr.parseExpr(p)) orelse return null;
    _ = p.expectToken(.rparen);
    const body = (try parseStatement(p)) orelse return null;
    const extra = try p.addExtra(ForeachComponents{
        .expr = e,
        .key = key,
        .value = value,
        .body = body,
    });
    return (try p.addNode(.{
        .tag = .stmt_foreach,
        .main_token = kw,
        .data = .{ .extra_and_node = .{ extra, value } },
    })) orelse unreachable;
}

/// 命名空间声明：支持 `namespace Name;`（无括号，后续语句均属该空间，至文件尾）、
/// `namespace Name { ... }`（块形式）与 `namespace { ... }`（全局命名空间，名为空）。
pub fn parseNamespace(p: *Parser) ast.ParseError!?Index {
    const kw = p.nextToken();
    var name: OptionalIndex = .none;
    if (p.tokTag() == .identifier or p.tokTag() == .backslash or p.tokTag() == .kw_namespace) {
        name = OptionalIndex.fromIndex((try expr.parseName(p)) orelse return null);
    }
    var stmts = try std.ArrayList(Index).initCapacity(p.gpa, 0);
    defer stmts.deinit(p.gpa);
    if (p.tokTag() == .lbrace) {
        // 块形式：语句收集到 `}` 为止，并消费该 `}`
        _ = p.nextToken();
        while (p.tokTag() != .rbrace and p.tokTag() != .eof) {
            const s = (try parseStatement(p)) orelse null;
            if (s) |stmt| try stmts.append(p.gpa, stmt);
            try p.skipToNextStmt();
            if (p.tokTag() == .close_tag) _ = p.nextToken();
        }
        _ = p.eatToken(.rbrace);
    } else {
        // 无括号形式：消费 `;`，后续所有语句归属于该命名空间（至文件尾）
        _ = p.eatToken(.semicolon);
        while (p.tokTag() != .rbrace and p.tokTag() != .eof) {
            const s = (try parseStatement(p)) orelse null;
            if (s) |stmt| try stmts.append(p.gpa, stmt);
            try p.skipToNextStmt();
            if (p.tokTag() == .close_tag) _ = p.nextToken();
        }
    }
    const lr = try p.addNodeList(stmts.items);
    const extra = try p.addExtra(NamespaceComponents{ .name = name, .stmts = .{ .start = lr.start, .end = lr.end } });
    return (try p.addNode(.{
        .tag = .stmt_namespace,
        .main_token = kw,
        .data = .{ .extra_and_opt_node = .{ extra, name } },
    })) orelse unreachable;
}

/// return 语句：`return expr;` 或 `return;`。
pub fn parseReturn(p: *Parser) ast.ParseError!?Index {
    const kw = p.nextToken();
    const e = try expr.parseExpr(p);
    _ = p.eatToken(.semicolon);
    return (try p.addNode(.{
        .tag = .stmt_return,
        .main_token = kw,
        .data = .{ .opt_node = if (e) |x| OptionalIndex.fromIndex(x) else .none },
    })) orelse unreachable;
}

/// echo 语句：`echo $a, $b;`，支持逗号分隔的多个表达式。
pub fn parseEcho(p: *Parser) ast.ParseError!?Index {
    const kw = p.nextToken();
    var exprs = try std.ArrayList(Index).initCapacity(p.gpa, 0);
    defer exprs.deinit(p.gpa);
    while (true) {
        const e = (try expr.parseExpr(p)) orelse return null;
        try exprs.append(p.gpa, e);
        if (p.tokTag() == .comma) {
            _ = p.nextToken();
            continue;
        }
        break;
    }
    _ = p.eatToken(.semicolon);
    const lr = try p.addNodeList(exprs.items);
    return (try p.addNode(.{
        .tag = .stmt_echo,
        .main_token = kw,
        .data = .{ .extra_range = .{ .start = lr.start, .end = lr.end } },
    })) orelse unreachable;
}

/// do-while 语句：`do { ... } while (cond);`
pub fn parseDo(p: *Parser) ast.ParseError!?Index {
    const kw = p.nextToken();
    const body = (try parseBlock(p)) orelse return null;
    _ = p.eatToken(.kw_while);
    _ = p.eatToken(.lparen);
    const cond = (try expr.parseExpr(p)) orelse return null;
    _ = p.eatToken(.rparen);
    _ = p.eatToken(.semicolon);
    return (try p.addNode(.{
        .tag = .stmt_do,
        .main_token = kw,
        .data = .{ .node_and_node = .{ body, cond } },
    })) orelse unreachable;
}

/// break / continue 语句（可选层级表达式）。main_token 为关键字。
pub fn parseBreakOrContinue(p: *Parser) ast.ParseError!?Index {
    const kw = p.nextToken();
    const tag = if (p.tokens.items(.tag)[kw] == .kw_break) Tag.stmt_break else Tag.stmt_continue;
    var level: OptionalIndex = .none;
    if (p.tokTag() == .semicolon) {
        _ = p.nextToken();
    } else {
        const e = (try expr.parseExpr(p)) orelse return null;
        level = OptionalIndex.fromIndex(e);
        _ = p.eatToken(.semicolon);
    }
    return (try p.addNode(.{
        .tag = tag,
        .main_token = kw,
        .data = .{ .opt_node = level },
    })) orelse unreachable;
}

/// switch 语句：`switch (cond) { case/ default ... }`
pub fn parseSwitch(p: *Parser) ast.ParseError!?Index {
    const kw = p.nextToken();
    _ = p.eatToken(.lparen);
    const cond = (try expr.parseExpr(p)) orelse return null;
    _ = p.eatToken(.rparen);
    _ = p.eatToken(.lbrace);
    var cases = try std.ArrayList(Index).initCapacity(p.gpa, 0);
    defer cases.deinit(p.gpa);
    while (p.tokTag() != .rbrace and p.tokTag() != .eof) {
        if (cases.items.len > 0) _ = p.eatToken(.semicolon);
        switch (p.tokTag()) {
            .kw_case => {
                const ck = p.nextToken();
                const value = (try expr.parseExpr(p)) orelse return null;
                _ = p.eatToken(.colon);
                var stmts = try std.ArrayList(Index).initCapacity(p.gpa, 0);
                defer stmts.deinit(p.gpa);
                while (true) {
                    const t = p.tokTag();
                    if (t == .rbrace or t == .eof or t == .kw_case or t == .kw_default) break;
                    const s = (try parseStatement(p)) orelse {
                        try p.skipToNextStmt();
                        break;
                    };
                    try stmts.append(p.gpa, s);
                }
                const lr = try p.addNodeList(stmts.items);
                // 复用 stmt_case：value 经 opt_node、stmts 经 extra_range
                const extra = try p.addExtra(CaseStmtComponents{ .stmts = .{ .start = lr.start, .end = lr.end } });
                const node = (try p.addNode(.{
                    .tag = .stmt_switch_case,
                    .main_token = ck,
                    .data = .{ .extra_and_opt_node = .{ extra, OptionalIndex.fromIndex(value) } },
                })) orelse unreachable;
                try cases.append(p.gpa, node);
            },
            .kw_default => {
                const dk = p.nextToken();
                _ = p.eatToken(.colon);
                var stmts = try std.ArrayList(Index).initCapacity(p.gpa, 0);
                defer stmts.deinit(p.gpa);
                while (true) {
                    const t = p.tokTag();
                    if (t == .rbrace or t == .eof or t == .kw_case or t == .kw_default) break;
                    const s = (try parseStatement(p)) orelse {
                        try p.skipToNextStmt();
                        break;
                    };
                    try stmts.append(p.gpa, s);
                }
                const lr = try p.addNodeList(stmts.items);
                const node = (try p.addNode(.{
                    .tag = .stmt_default,
                    .main_token = dk,
                    .data = .{ .extra_range = .{ .start = lr.start, .end = lr.end } },
                })) orelse unreachable;
                try cases.append(p.gpa, node);
            },
            else => {
                try p.skipToNextStmt();
            },
        }
    }
    _ = p.eatToken(.rbrace);
    _ = p.eatToken(.semicolon);
    const lr = try p.addNodeList(cases.items);
    const extra = try p.addExtra(SwitchComponents{ .cond = cond, .cases = .{ .start = lr.start, .end = lr.end } });
    return (try p.addNode(.{
        .tag = .stmt_switch,
        .main_token = kw,
        .data = .{ .extra_and_node = .{ extra, cond } },
    })) orelse unreachable;
}

/// throw 语句：`throw expr;`
pub fn parseThrowStmt(p: *Parser) ast.ParseError!?Index {
    const kw = p.nextToken();
    const e = (try expr.parseExpr(p)) orelse return null;
    _ = p.eatToken(.semicolon);
    return (try p.addNode(.{
        .tag = .stmt_throw,
        .main_token = kw,
        .data = .{ .node = e },
    })) orelse unreachable;
}

/// try-catch-finally 语句。
pub fn parseTry(p: *Parser) ast.ParseError!?Index {
    const kw = p.nextToken();
    const body = (try parseBlock(p)) orelse return null;
    var catches = try std.ArrayList(Index).initCapacity(p.gpa, 0);
    defer catches.deinit(p.gpa);
    var finally: OptionalIndex = .none;
    while (p.tokTag() == .kw_catch) {
        const ck = p.nextToken();
        _ = p.eatToken(.lparen);
        var types = try std.ArrayList(Index).initCapacity(p.gpa, 0);
        defer types.deinit(p.gpa);
        while (true) {
            const tname = (try expr.parseName(p)) orelse break;
            try types.append(p.gpa, tname);
            if (p.tokTag() == .pipe) {
                _ = p.nextToken();
                continue;
            }
            break;
        }
        _ = p.nextToken(); // 捕获变量 $e
        _ = p.eatToken(.rparen);
        const cbody = (try parseBlock(p)) orelse return null;
        const lr = try p.addNodeList(types.items);
        const extra = try p.addExtra(CatchComponents{ .types = .{ .start = lr.start, .end = lr.end }, .body = cbody });
        const node = (try p.addNode(.{
            .tag = .stmt_catch,
            .main_token = ck,
            .data = .{ .extra_and_node = .{ extra, cbody } },
        })) orelse unreachable;
        try catches.append(p.gpa, node);
    }
    if (p.tokTag() == .kw_finally) {
        _ = p.nextToken();
        finally = OptionalIndex.fromIndex((try parseBlock(p)) orelse return null);
    }
    const lr = try p.addNodeList(catches.items);
    const extra = try p.addExtra(TryComponents{ .catches = .{ .start = lr.start, .end = lr.end }, .finally = finally });
    return (try p.addNode(.{
        .tag = .stmt_try,
        .main_token = kw,
        .data = .{ .extra_and_node = .{ extra, body } },
    })) orelse unreachable;
}

/// 全局常量声明：`#[A] const FOO = 1, BAR = 2;`
/// 常量上的注解（含 #[\Deprecated]）为 8.5 引入，故带属性的声明会被标注为 8.5。
pub fn parseConst(p: *Parser, attrs: SubRange) ast.ParseError!?Index {
    const kw = p.nextToken();
    var decls = try std.ArrayList(Index).initCapacity(p.gpa, 0);
    defer decls.deinit(p.gpa);
    while (true) {
        const name = p.nextToken(); // 标识符常量名
        _ = p.eatToken(.equals);
        const value = (try expr.parseExpr(p)) orelse return null;
        const node = (try p.addNode(.{
            .tag = .const_decl,
            .main_token = name,
            .data = .{ .node_and_token = .{ value, name } },
        })) orelse unreachable;
        // 全局常量上的注解为 8.5 引入
        if (attrs.start != attrs.end) {
            p.node_versions.items[@intFromEnum(node)] = PhpVersion.fromComponents(8, 5);
        }
        try decls.append(p.gpa, node);
        if (p.tokTag() == .comma) {
            _ = p.nextToken();
            continue;
        }
        break;
    }
    _ = p.eatToken(.semicolon);
    const lr = try p.addNodeList(decls.items);
    return (try p.addNode(.{
        .tag = .stmt_const,
        .main_token = kw,
        .data = .{ .extra_range = .{ .start = lr.start, .end = lr.end } },
    })) orelse unreachable;
}

/// use 导入语句：`use A\B\C, D\E as F;`（含分组 use）。kind 决定 use 种类。
pub fn parseUse(p: *Parser) ast.ParseError!?Index {
    const kw = p.nextToken();
    var kind: u32 = 0; // 0=普通 1=function 2=const
    if (p.tokTag() == .kw_function) {
        _ = p.nextToken();
        kind = 1;
    } else if (p.tokTag() == .kw_const) {
        _ = p.nextToken();
        kind = 2;
    }
    // 先解析首个 name；随后若为 `{` 则为分组 use（use A\B\{...}）。
    const first = (try expr.parseName(p)) orelse return null;
    if (p.tokTag() == .lbrace) {
        const prefix = first;
        _ = p.eatToken(.lbrace);
        var uses = try std.ArrayList(Index).initCapacity(p.gpa, 0);
        defer uses.deinit(p.gpa);
        while (p.tokTag() != .rbrace and p.tokTag() != .eof) {
            const name = (try expr.parseName(p)) orelse break;
            const u = try buildUseUse(p, name, kind);
            try uses.append(p.gpa, u);
            if (p.tokTag() == .comma) {
                _ = p.nextToken();
                continue;
            }
            break;
        }
        _ = p.eatToken(.rbrace);
        _ = p.eatToken(.semicolon);
        const lr = try p.addNodeList(uses.items);
        const extra = try p.addExtra(GroupUseComponents{ .uses = .{ .start = lr.start, .end = lr.end }, .kind = kind });
        return (try p.addNode(.{
            .tag = .stmt_group_use,
            .main_token = kw,
            .data = .{ .extra_and_node = .{ extra, prefix } },
        })) orelse unreachable;
    }
    // 普通（非分组）use：first 即首个 use use，其后可跟逗号列表。
    var uses = try std.ArrayList(Index).initCapacity(p.gpa, 0);
    defer uses.deinit(p.gpa);
    try uses.append(p.gpa, try buildUseUse(p, first, kind));
    while (p.tokTag() == .comma) {
        _ = p.nextToken();
        const name = (try expr.parseName(p)) orelse break;
        try uses.append(p.gpa, try buildUseUse(p, name, kind));
    }
    _ = p.eatToken(.semicolon);
    const lr = try p.addNodeList(uses.items);
    const extra = try p.addExtra(UseComponents{ .uses = .{ .start = lr.start, .end = lr.end }, .kind = kind });
    return (try p.addNode(.{
        .tag = .stmt_use,
        .main_token = kw,
        .data = .{ .extra = extra },
    })) orelse unreachable;
}

/// 由已解析的 name 构造一个 use_use 节点（处理可选的 `as 别名`）。
fn buildUseUse(p: *Parser, name: Index, kind: u32) !Index {
    var alias: TokenIndex = 0;
    if (p.tokTag() == .kw_as) {
        _ = p.nextToken();
        alias = p.nextToken();
    }
    const extra = try p.addExtra(UseUseComponents{ .alias = alias, .kind = kind });
    return (try p.addNode(.{
        .tag = .use_use,
        .main_token = p.nodeMainToken(name),
        .data = .{ .extra_and_node = .{ extra, name } },
    })) orelse unreachable;
}

/// trait 横向复用：`use A, B { A::foo as bar; B::baz insteadof A; }`
pub fn parseTraitUse(p: *Parser) ast.ParseError!?Index {
    const kw = p.nextToken();
    var traits = try std.ArrayList(Index).initCapacity(p.gpa, 0);
    defer traits.deinit(p.gpa);
    while (true) {
        const tname = (try expr.parseName(p)) orelse return null;
        try traits.append(p.gpa, tname);
        if (p.tokTag() == .comma) {
            _ = p.nextToken();
            continue;
        }
        break;
    }
    var adaptations = try std.ArrayList(Index).initCapacity(p.gpa, 0);
    defer adaptations.deinit(p.gpa);
    if (p.tokTag() == .lbrace) {
        _ = p.nextToken();
        while (p.tokTag() != .rbrace and p.tokTag() != .eof) {
            const adapt = (try parseTraitAdaptation(p)) orelse break;
            try adaptations.append(p.gpa, adapt);
            _ = p.eatToken(.semicolon);
        }
        _ = p.eatToken(.rbrace);
    }
    _ = p.eatToken(.semicolon);
    const lr1 = try p.addNodeList(traits.items);
    const lr2 = try p.addNodeList(adaptations.items);
    const extra = try p.addExtra(TraitUseComponents{
        .traits = .{ .start = lr1.start, .end = lr1.end },
        .adaptations = .{ .start = lr2.start, .end = lr2.end },
    });
    return (try p.addNode(.{
        .tag = .stmt_trait_use,
        .main_token = kw,
        .data = .{ .extra = extra },
    })) orelse unreachable;
}

/// trait 适配：别名 `A::foo as bar` 或优先级 `A::foo insteadof B`
fn parseTraitAdaptation(p: *Parser) ast.ParseError!?Index {
    var trait: OptionalIndex = .none;
    var method: TokenIndex = 0;
    if (p.tokTag() == .rbrace or p.tokTag() == .eof) return null;
    // A::foo
    const maybe_trait = (try expr.parseName(p)) orelse return null;
    if (p.tokTag() == .double_colon) {
        _ = p.nextToken();
        trait = OptionalIndex.fromIndex(maybe_trait);
        method = p.nextToken();
    } else {
        // 仅方法名（无 trait 限定）
        method = p.nodeMainToken(maybe_trait);
    }
    if (p.tokTag() == .kw_as) {
        _ = p.nextToken();
        var modifier: OptionalTokenIndex = .none;
        var alias: OptionalTokenIndex = .none;
        // 顺序：可视性修饰符 或 别名，二者择一（亦可 修饰符 别名）
        if (isVisibility(p.tokTag())) {
            modifier = OptionalTokenIndex.fromToken(p.nextToken());
            if (p.tokTag() == .identifier or p.tokTag() == .kw_as) {
                // 别名
                if (p.tokTag() == .kw_as) _ = p.nextToken();
                alias = OptionalTokenIndex.fromToken(p.nextToken());
            }
        } else {
            alias = OptionalTokenIndex.fromToken(p.nextToken());
        }
        const extra = try p.addExtra(TraitAdaptAliasComponents{
            .trait = trait,
            .method = method,
            .modifier = modifier,
            .alias = alias,
        });
        return (try p.addNode(.{
            .tag = .trait_use_adaptation_alias,
            .main_token = method,
            .data = .{ .extra_and_opt_node = .{ extra, trait } },
        })) orelse unreachable;
    } else if (p.tokTag() == .kw_insteadof) {
        _ = p.nextToken();
        var insteadof = try std.ArrayList(Index).initCapacity(p.gpa, 0);
        defer insteadof.deinit(p.gpa);
        while (true) {
            const tname = (try expr.parseName(p)) orelse break;
            try insteadof.append(p.gpa, tname);
            if (p.tokTag() == .comma) {
                _ = p.nextToken();
                continue;
            }
            break;
        }
        const lr = try p.addNodeList(insteadof.items);
        const extra = try p.addExtra(TraitAdaptPrecComponents{
            .trait = trait,
            .method = method,
            .insteadof = .{ .start = lr.start, .end = lr.end },
        });
        return (try p.addNode(.{
            .tag = .trait_use_adaptation_precedence,
            .main_token = method,
            .data = .{ .extra_and_opt_node = .{ extra, trait } },
        })) orelse unreachable;
    }
    return null;
}

/// declare 语句：`declare(ticks=1) { ... }` 或 `declare(strict_types=1);`
pub fn parseDeclare(p: *Parser) ast.ParseError!?Index {
    const kw = p.nextToken();
    _ = p.eatToken(.lparen);
    var declares = try std.ArrayList(Index).initCapacity(p.gpa, 0);
    defer declares.deinit(p.gpa);
    while (true) {
        const name = p.nextToken();
        _ = p.eatToken(.equals);
        const value = (try expr.parseExpr(p)) orelse return null;
        const node = (try p.addNode(.{
            .tag = .declare_declare,
            .main_token = name,
            .data = .{ .node_and_token = .{ value, name } },
        })) orelse unreachable;
        try declares.append(p.gpa, node);
        if (p.tokTag() == .comma) {
            _ = p.nextToken();
            continue;
        }
        break;
    }
    _ = p.eatToken(.rparen);
    var stmts: OptionalIndex = .none;
    if (p.tokTag() == .lbrace) {
        stmts = OptionalIndex.fromIndex((try parseBlock(p)) orelse return null);
    } else {
        _ = p.eatToken(.semicolon);
    }
    const lr = try p.addNodeList(declares.items);
    const extra = try p.addExtra(DeclareComponents{ .declares = .{ .start = lr.start, .end = lr.end }, .stmts = stmts });
    return (try p.addNode(.{
        .tag = .stmt_declare,
        .main_token = kw,
        .data = .{ .extra_and_opt_node = .{ extra, stmts } },
    })) orelse unreachable;
}

/// goto 语句 / 标签
pub fn parseGoto(p: *Parser) ast.ParseError!?Index {
    _ = p.nextToken(); // goto
    const label = p.nextToken();
    _ = p.eatToken(.semicolon);
    return (try p.addNode(.{
        .tag = .stmt_goto,
        .main_token = label,
        .data = .{ .token = label },
    })) orelse unreachable;
}

fn parseLabel(p: *Parser) ast.ParseError!?Index {
    const label = p.nextToken(); // 标识符
    _ = p.eatToken(.colon);
    return (try p.addNode(.{
        .tag = .stmt_label,
        .main_token = label,
        .data = .{ .token = label },
    })) orelse unreachable;
}

/// global 语句：`global $a, $b;`
pub fn parseGlobal(p: *Parser) ast.ParseError!?Index {
    const kw = p.nextToken();
    var vars = try std.ArrayList(Index).initCapacity(p.gpa, 0);
    defer vars.deinit(p.gpa);
    while (true) {
        const v = (try expr.parseExpr(p)) orelse return null;
        try vars.append(p.gpa, v);
        if (p.tokTag() == .comma) {
            _ = p.nextToken();
            continue;
        }
        break;
    }
    _ = p.eatToken(.semicolon);
    const lr = try p.addNodeList(vars.items);
    return (try p.addNode(.{
        .tag = .stmt_global,
        .main_token = kw,
        .data = .{ .extra_range = .{ .start = lr.start, .end = lr.end } },
    })) orelse unreachable;
}

/// static 变量声明：`static $a = 1, $b;`
pub fn parseStatic(p: *Parser) ast.ParseError!?Index {
    const kw = p.nextToken();
    var vars = try std.ArrayList(Index).initCapacity(p.gpa, 0);
    defer vars.deinit(p.gpa);
    while (true) {
        const name = p.nextToken(); // $var
        var default: OptionalIndex = .none;
        if (p.tokTag() == .equals) {
            _ = p.nextToken();
            default = OptionalIndex.fromIndex((try expr.parseExpr(p)) orelse return null);
        }
        const extra = try p.addExtra(StaticVarComponents{ .name = name, .default = default });
        const node = (try p.addNode(.{
            .tag = .static_var,
            .main_token = name,
            .data = .{ .extra = extra },
        })) orelse unreachable;
        try vars.append(p.gpa, node);
        if (p.tokTag() == .comma) {
            _ = p.nextToken();
            continue;
        }
        break;
    }
    _ = p.eatToken(.semicolon);
    const lr = try p.addNodeList(vars.items);
    return (try p.addNode(.{
        .tag = .stmt_static,
        .main_token = kw,
        .data = .{ .extra_range = .{ .start = lr.start, .end = lr.end } },
    })) orelse unreachable;
}

/// unset 语句：`unset($a, $b);`
pub fn parseUnset(p: *Parser) ast.ParseError!?Index {
    const kw = p.nextToken();
    _ = p.eatToken(.lparen);
    var vars = try std.ArrayList(Index).initCapacity(p.gpa, 0);
    defer vars.deinit(p.gpa);
    while (true) {
        const v = (try expr.parseExpr(p)) orelse return null;
        try vars.append(p.gpa, v);
        if (p.tokTag() == .comma) {
            _ = p.nextToken();
            continue;
        }
        break;
    }
    _ = p.eatToken(.rparen);
    _ = p.eatToken(.semicolon);
    const lr = try p.addNodeList(vars.items);
    return (try p.addNode(.{
        .tag = .stmt_unset,
        .main_token = kw,
        .data = .{ .extra_range = .{ .start = lr.start, .end = lr.end } },
    })) orelse unreachable;
}

/// __halt_compiler() ：解析到此停止，剩余源码整体忽略。
pub fn parseHaltCompiler(p: *Parser) ast.ParseError!?Index {
    const kw = p.nextToken();
    _ = p.eatToken(.lparen);
    _ = p.eatToken(.rparen);
    _ = p.eatToken(.semicolon);
    // 设 tok_i 到 eof，使 parseRoot 的 while 循环自然结束
    p.tok_i = @as(TokenIndex, @intCast(p.tokens.len - 1));
    return (try p.addNode(.{
        .tag = .stmt_halt,
        .main_token = kw,
        .data = .{ .token = kw },
    })) orelse unreachable;
}
