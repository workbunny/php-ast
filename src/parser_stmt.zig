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
const testing = @import("testing.zig");

const OptionalTokenIndex = ast.OptionalTokenIndex;
const Tag = ast.Node.Tag;

/// if / while / for / foreach / namespace 等复合语句的附加负载，序列化进 `extra_data`。
/// 语句块的负载：两条定界符 token 与内部语句区间。
pub const BlockComponents = struct {
    lbrace: TokenIndex,
    rbrace: TokenIndex,
    stmts: SubRange,
};

pub const IfComponents = struct {
    cond: Index,
    then_body: Index,
    else_body: OptionalIndex,
};

pub const WhileComponents = struct {
    cond: Index,
    body: Index,
};

/// `for` 的三段均可省略（`for (;;)`），故 init/cond/inc 为可选。
pub const ForComponents = struct {
    init: OptionalIndex,
    cond: OptionalIndex,
    inc: OptionalIndex,
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
    /// 结束定界符：块形式为 `}`，无括号形式为 `;`。
    close: TokenIndex,
};

/// do / switch / try / use / trait / declare / static 等语句的附加负载组件。
///
/// 凡以 `;` 结尾的语句都在此记录该分号的下标。定界符不是任何节点的子节点，
/// 只能这样单独存，`Ast.lastToken` 才能覆盖完整源码区间。
pub const DoComponents = struct { cond: Index, body: Index, semi: TokenIndex };
pub const SwitchComponents = struct { cond: Index, cases: SubRange };
pub const CaseStmtComponents = struct { stmts: SubRange };
pub const TryComponents = struct { catches: SubRange, finally: OptionalIndex };
pub const CatchComponents = struct { types: SubRange, body: Index };
pub const UseComponents = struct { uses: SubRange, kind: u32, semi: TokenIndex };
pub const UseUseComponents = struct { alias: TokenIndex, kind: u32 };
pub const GroupUseComponents = struct { uses: SubRange, kind: u32, semi: TokenIndex };
pub const TraitUseComponents = struct { traits: SubRange, adaptations: SubRange, semi: TokenIndex };
pub const TraitAdaptAliasComponents = struct { trait: OptionalIndex, method: TokenIndex, modifier: OptionalTokenIndex, alias: OptionalTokenIndex };
pub const TraitAdaptPrecComponents = struct { trait: OptionalIndex, method: TokenIndex, insteadof: SubRange };
pub const DeclareComponents = struct { declares: SubRange, stmts: OptionalIndex, semi: TokenIndex };
pub const StaticVarComponents = struct { name: TokenIndex, default: OptionalIndex };

/// 以 `;` 结尾的列表型语句（echo / const / global / static / unset）。
///
/// 原先这些节点把列表直接放在 `data.extra_range` 上，无处容纳尾部分号；
/// 改为经 Components 承载后，既不增大 `Node` 结构，又能带上定界符。
pub const EchoComponents = struct { exprs: SubRange, semi: TokenIndex };
pub const ConstComponents = struct { decls: SubRange, semi: TokenIndex };
pub const GlobalComponents = struct { vars: SubRange, semi: TokenIndex };
pub const StaticComponents = struct { vars: SubRange, semi: TokenIndex };
pub const UnsetComponents = struct { vars: SubRange, semi: TokenIndex };

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
        // 类修饰符：`abstract`/`final`/`readonly` 可连用于类声明前。
        // 修饰符本身不建节点（类节点已用 flags 记录），消费后落到真正的声明关键字。
        .kw_abstract, .kw_final, .kw_readonly => {
            _ = p.nextToken();
            return try parseStatement(p);
        },
        // 裸块 `{ ... }`：`if`/`while`/`for`/`foreach` 的循环体走本函数解析，
        // 缺少此分支时块体会被当作表达式语句，产出 expected_expr。
        .lbrace => return parseBlock(p),
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
///
/// 分号存入 `node_and_token`，使语句的 token 区间完整（否则代码改写会漏掉分号）。
/// 末尾无分号时（如文件尾）退化为用主 token 占位。
pub fn parseExprStatement(p: *Parser) ast.ParseError!?Index {
    const e = try expr.parseExpr(p);
    if (e == null) return null;
    const ex = e.?;
    const main = p.nodeMainToken(ex);
    const semi = (p.eatToken(.semicolon)) orelse main;
    return (try p.addNode(.{
        .tag = .stmt_expression,
        .main_token = main,
        .data = .{ .node_and_token = .{ ex, semi } },
    })) orelse unreachable;
}

/// 语句块 `{ ... }`：解析到匹配的 `}` 为止，内部语句收集为 stmt_block。
///
/// 定界符 `{` `}` 一并存入 `BlockComponents`，否则节点的 token 区间无法覆盖它们，
/// 代码改写会漏掉花括号。
pub fn parseBlock(p: *Parser) ast.ParseError!?Index {
    const lbrace = (p.expectToken(.lbrace)) orelse return null;
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
    // 块未闭合时以 `{` 兜底，保证区间左闭右不溢出
    const rbrace = (p.eatToken(.rbrace)) orelse lbrace;
    const lr = try p.addNodeList(stmts.items);
    const extra = try p.addExtra(BlockComponents{
        .lbrace = lbrace,
        .rbrace = rbrace,
        .stmts = .{ .start = lr.start, .end = lr.end },
    });
    return (try p.addNode(.{
        .tag = .stmt_block,
        .main_token = lbrace,
        .data = .{ .extra = extra },
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
    // 三段均可为空：`for (;;)`。先判分隔符再决定是否解析，避免把 `;` 当表达式起点
    // 而产出 expected_expr。第三段后紧跟 `)`，故以 `)` 判空。
    const init = if (p.tokTag() == .semicolon) null else (try expr.parseExpr(p));
    _ = p.expectToken(.semicolon);
    const cond = if (p.tokTag() == .semicolon) null else (try expr.parseExpr(p));
    _ = p.expectToken(.semicolon);
    const inc = if (p.tokTag() == .rparen) null else (try expr.parseExpr(p));
    _ = p.expectToken(.rparen);
    const body = (try parseStatement(p)) orelse return null;
    const extra = try p.addExtra(ForComponents{
        .init = if (init) |n| OptionalIndex.fromIndex(n) else .none,
        .cond = if (cond) |n| OptionalIndex.fromIndex(n) else .none,
        .inc = if (inc) |n| OptionalIndex.fromIndex(n) else .none,
        .body = body,
    });
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
    // `as` 之后先解析第一个表达式：若其后紧跟 `=>`，则它是键、需再解析值；
    // 否则它即值本身。原实现在 `as` 之后立刻判 `=>`，此时游标尚在键上，
    // 导致键恒为 none 且随即在 `=>` 处报 expected_token。
    const first = (try expr.parseExpr(p)) orelse return null;
    var key: OptionalIndex = .none;
    var value = first;
    if (p.tokTag() == .double_arrow) {
        _ = p.nextToken();
        key = OptionalIndex.fromIndex(first);
        value = (try expr.parseExpr(p)) orelse return null;
    }
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
    var close: TokenIndex = kw;
    if (p.tokTag() == .lbrace) {
        // 块形式：语句收集到 `}` 为止，并消费该 `}`
        _ = p.nextToken();
        while (p.tokTag() != .rbrace and p.tokTag() != .eof) {
            const s = (try parseStatement(p)) orelse {
                // 仅解析失败时才跳过——成功后再跳会吞掉下一条语句
                try p.skipToNextStmt();
                if (p.tokTag() == .close_tag) _ = p.nextToken();
                continue;
            };
            try stmts.append(p.gpa, s);
            if (p.tokTag() == .close_tag) _ = p.nextToken();
        }
        close = (p.eatToken(.rbrace)) orelse kw;
    } else {
        // 无括号形式：消费 `;`，后续所有语句归属于该命名空间（至文件尾）
        close = (p.eatToken(.semicolon)) orelse kw;
        while (p.tokTag() != .rbrace and p.tokTag() != .eof) {
            const s = (try parseStatement(p)) orelse {
                try p.skipToNextStmt();
                if (p.tokTag() == .close_tag) _ = p.nextToken();
                continue;
            };
            try stmts.append(p.gpa, s);
            if (p.tokTag() == .close_tag) _ = p.nextToken();
        }
    }
    const lr = try p.addNodeList(stmts.items);
    const extra = try p.addExtra(NamespaceComponents{
        .name = name,
        .stmts = .{ .start = lr.start, .end = lr.end },
        .close = close,
    });
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
    const semi = (p.eatToken(.semicolon)) orelse kw;
    return (try p.addNode(.{
        .tag = .stmt_return,
        .main_token = kw,
        .data = .{ .opt_node_and_token = .{ if (e) |x| OptionalIndex.fromIndex(x) else .none, semi } },
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
    const semi = (p.eatToken(.semicolon)) orelse kw;
    const lr = try p.addNodeList(exprs.items);
    const extra = try p.addExtra(EchoComponents{
        .exprs = .{ .start = lr.start, .end = lr.end },
        .semi = semi,
    });
    return (try p.addNode(.{
        .tag = .stmt_echo,
        .main_token = kw,
        .data = .{ .extra = extra },
    })) orelse unreachable;
}

/// do-while 语句：`do { ... } while (cond);`
pub fn parseDo(p: *Parser) ast.ParseError!?Index {
    const kw = p.nextToken();
    const body = (try parseBlock(p)) orelse return null;
    _ = p.eatToken(.kw_while);
    _ = p.eatToken(.lparen);
    const cond = (try expr.parseExpr(p)) orelse return null;
    const rparen = (p.eatToken(.rparen)) orelse kw;
    const semi = (p.eatToken(.semicolon)) orelse rparen;
    const extra = try p.addExtra(DoComponents{ .cond = cond, .body = body, .semi = semi });
    return (try p.addNode(.{
        .tag = .stmt_do,
        .main_token = kw,
        .data = .{ .extra = extra },
    })) orelse unreachable;
}

/// break / continue 语句（可选层级表达式）。main_token 为关键字。
pub fn parseBreakOrContinue(p: *Parser) ast.ParseError!?Index {
    const kw = p.nextToken();
    const tag = if (p.tokens.items(.tag)[kw] == .kw_break) Tag.stmt_break else Tag.stmt_continue;
    var level: OptionalIndex = .none;
    var semi = kw;
    if (p.tokTag() == .semicolon) {
        semi = p.nextToken();
    } else {
        const e = (try expr.parseExpr(p)) orelse return null;
        level = OptionalIndex.fromIndex(e);
        semi = (p.eatToken(.semicolon)) orelse kw;
    }
    return (try p.addNode(.{
        .tag = tag,
        .main_token = kw,
        .data = .{ .opt_node_and_token = .{ level, semi } },
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
    const semi = (p.eatToken(.semicolon)) orelse kw;
    return (try p.addNode(.{
        .tag = .stmt_throw,
        .main_token = kw,
        .data = .{ .node_and_token = .{ e, semi } },
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
    const semi = (p.eatToken(.semicolon)) orelse kw;
    const lr = try p.addNodeList(decls.items);
    const extra = try p.addExtra(ConstComponents{
        .decls = .{ .start = lr.start, .end = lr.end },
        .semi = semi,
    });
    return (try p.addNode(.{
        .tag = .stmt_const,
        .main_token = kw,
        .data = .{ .extra = extra },
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
        const rbrace = (p.eatToken(.rbrace)) orelse kw;
        const semi = (p.eatToken(.semicolon)) orelse rbrace;
        const lr = try p.addNodeList(uses.items);
        const extra = try p.addExtra(GroupUseComponents{
            .uses = .{ .start = lr.start, .end = lr.end },
            .kind = kind,
            .semi = semi,
        });
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
    const semi = (p.eatToken(.semicolon)) orelse kw;
    const lr = try p.addNodeList(uses.items);
    const extra = try p.addExtra(UseComponents{
        .uses = .{ .start = lr.start, .end = lr.end },
        .kind = kind,
        .semi = semi,
    });
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
    const semi = (p.eatToken(.semicolon)) orelse kw;
    const lr1 = try p.addNodeList(traits.items);
    const lr2 = try p.addNodeList(adaptations.items);
    const extra = try p.addExtra(TraitUseComponents{
        .traits = .{ .start = lr1.start, .end = lr1.end },
        .adaptations = .{ .start = lr2.start, .end = lr2.end },
        .semi = semi,
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
    const rparen = (p.eatToken(.rparen)) orelse kw;
    var stmts: OptionalIndex = .none;
    var semi: TokenIndex = rparen;
    if (p.tokTag() == .lbrace) {
        stmts = OptionalIndex.fromIndex((try parseBlock(p)) orelse return null);
    } else {
        semi = (p.eatToken(.semicolon)) orelse rparen;
    }
    const lr = try p.addNodeList(declares.items);
    const extra = try p.addExtra(DeclareComponents{
        .declares = .{ .start = lr.start, .end = lr.end },
        .stmts = stmts,
        .semi = semi,
    });
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
    const semi = (p.eatToken(.semicolon)) orelse label;
    return (try p.addNode(.{
        .tag = .stmt_goto,
        .main_token = label,
        .data = .{ .token_and_token = .{ label, semi } },
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
    const semi = (p.eatToken(.semicolon)) orelse kw;
    const lr = try p.addNodeList(vars.items);
    const extra = try p.addExtra(GlobalComponents{
        .vars = .{ .start = lr.start, .end = lr.end },
        .semi = semi,
    });
    return (try p.addNode(.{
        .tag = .stmt_global,
        .main_token = kw,
        .data = .{ .extra = extra },
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
    const semi = (p.eatToken(.semicolon)) orelse kw;
    const lr = try p.addNodeList(vars.items);
    const extra = try p.addExtra(StaticComponents{
        .vars = .{ .start = lr.start, .end = lr.end },
        .semi = semi,
    });
    return (try p.addNode(.{
        .tag = .stmt_static,
        .main_token = kw,
        .data = .{ .extra = extra },
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
    // 括号与分号都记下，否则语句区间会在 `)` 处截断
    const rparen = (p.eatToken(.rparen)) orelse kw;
    const semi = (p.eatToken(.semicolon)) orelse rparen;
    const lr = try p.addNodeList(vars.items);
    const extra = try p.addExtra(UnsetComponents{
        .vars = .{ .start = lr.start, .end = lr.end },
        .semi = semi,
    });
    return (try p.addNode(.{
        .tag = .stmt_unset,
        .main_token = kw,
        .data = .{ .extra = extra },
    })) orelse unreachable;
}

/// __halt_compiler() ：解析到此停止，剩余源码整体忽略。
pub fn parseHaltCompiler(p: *Parser) ast.ParseError!?Index {
    const kw = p.nextToken();
    _ = p.eatToken(.lparen);
    const rparen = (p.eatToken(.rparen)) orelse kw;
    const semi = (p.eatToken(.semicolon)) orelse rparen;
    // 设 tok_i 到 eof，使 parseRoot 的 while 循环自然结束
    p.tok_i = @as(TokenIndex, @intCast(p.tokens.len - 1));
    return (try p.addNode(.{
        .tag = .stmt_halt,
        .main_token = kw,
        .data = .{ .token_and_token = .{ kw, semi } },
    })) orelse unreachable;
}

// ===========================================================================
// 测试：语句
// ===========================================================================

test "stmt :: if/elseif/else :: 条件与分支体成节点" {
    const gpa = std.testing.allocator;
    var tree = try ast.Ast.parse(gpa,
        \\<?php
        \\if ($a) { echo 1; } elseif ($b) { echo 2; } else { echo 3; }
    , testing.v84);
    defer tree.deinit(gpa);
    try testing.expectNoErrors(tree);
    // elseif 解析为嵌套 if
    try testing.expectTagCounts(tree, .{ .stmt_if = 2, .stmt_echo = 3 });
}

test "stmt :: while :: 条件与循环体" {
    const gpa = std.testing.allocator;
    var tree = try ast.Ast.parse(gpa, "<?php while ($a) { $b(); }", testing.v84);
    defer tree.deinit(gpa);
    try testing.expectNoErrors(tree);
    try testing.expectTagCounts(tree, .{ .stmt_while = 1 });
}

test "stmt :: for :: 初始化/条件/递增/循环体四部分" {
    const gpa = std.testing.allocator;
    var tree = try ast.Ast.parse(gpa, "<?php for ($i = 0; $i < 3; $i++) { echo $i; }", testing.v84);
    defer tree.deinit(gpa);
    try testing.expectNoErrors(tree);
    try testing.expectTagCounts(tree, .{ .stmt_for = 1, .expr_post_inc = 1 });
}

test "stmt :: for :: 三段全空的无限循环" {
    const gpa = std.testing.allocator;
    var tree = try ast.Ast.parse(gpa, "<?php for (;;) { break; }", testing.v84);
    defer tree.deinit(gpa);
    try testing.expectNoErrors(tree);
    try testing.expectTagCounts(tree, .{ .stmt_for = 1, .stmt_break = 1 });
}

test "stmt :: for :: 部分段为空" {
    const gpa = std.testing.allocator;
    var tree = try ast.Ast.parse(gpa, "<?php for (; $i < 3;) { $i++; }", testing.v84);
    defer tree.deinit(gpa);
    try testing.expectNoErrors(tree);
    try testing.expectTagCounts(tree, .{ .stmt_for = 1, .expr_binary = 1 });
}

test "stmt :: foreach :: 带键与不带键两种形式" {
    const gpa = std.testing.allocator;
    var tree = try ast.Ast.parse(gpa,
        \\<?php
        \\foreach ($a as $v) {}
        \\foreach ($a as $k => $v) {}
    , testing.v84);
    defer tree.deinit(gpa);
    try testing.expectNoErrors(tree);
    try testing.expectTagCounts(tree, .{ .stmt_foreach = 2 });
}

test "stmt :: do-while :: 先体后条件" {
    const gpa = std.testing.allocator;
    var tree = try ast.Ast.parse(gpa, "<?php do { $x--; } while ($x > 0);", testing.v84);
    defer tree.deinit(gpa);
    try testing.expectNoErrors(tree);
    try testing.expectTagCounts(tree, .{ .stmt_do = 1, .expr_post_dec = 1 });
}

test "stmt :: switch :: case/default 与 break/continue" {
    const gpa = std.testing.allocator;
    var tree = try ast.Ast.parse(gpa,
        \\<?php
        \\switch ($x) {
        \\    case 1: echo 'a'; break;
        \\    case 2: echo 'b'; continue;
        \\    default: echo 'c';
        \\}
    , testing.v84);
    defer tree.deinit(gpa);
    try testing.expectNoErrors(tree);
    try testing.expectTagCounts(tree, .{
        .stmt_switch = 1,
        .stmt_switch_case = 2,
        .stmt_default = 1,
        .stmt_break = 1,
        .stmt_continue = 1,
    });
}

test "stmt :: echo/return :: 各自成节点" {
    const gpa = std.testing.allocator;
    var tree = try ast.Ast.parse(gpa,
        \\<?php
        \\function f() {
        \\    echo 1;
        \\    return 2;
        \\}
    , testing.v84);
    defer tree.deinit(gpa);
    try testing.expectNoErrors(tree);
    try testing.expectTagCounts(tree, .{ .stmt_echo = 1, .stmt_return = 1 });
}

test "stmt :: throw :: 产出 stmt_throw" {
    const gpa = std.testing.allocator;
    var tree = try ast.Ast.parse(gpa, "<?php throw new Exception('x');", testing.v84);
    defer tree.deinit(gpa);
    try testing.expectNoErrors(tree);
    try testing.expectTagCounts(tree, .{ .stmt_throw = 1, .expr_new = 1 });
}

test "stmt :: try/catch/finally :: 三者成节点" {
    const gpa = std.testing.allocator;
    var tree = try ast.Ast.parse(gpa,
        \\<?php
        \\try { foo(); } catch (Exception $e) { bar(); } finally { baz(); }
    , testing.v84);
    defer tree.deinit(gpa);
    try testing.expectNoErrors(tree);
    try testing.expectTagCounts(tree, .{ .stmt_try = 1, .stmt_catch = 1 });
}

test "stmt :: goto/label :: 分别成节点" {
    const gpa = std.testing.allocator;
    var tree = try ast.Ast.parse(gpa,
        \\<?php
        \\loop:
        \\goto loop;
    , testing.v84);
    defer tree.deinit(gpa);
    try testing.expectNoErrors(tree);
    try testing.expectTagCounts(tree, .{ .stmt_goto = 1, .stmt_label = 1 });
}

test "stmt :: const :: 多个声明各自成 const_decl" {
    const gpa = std.testing.allocator;
    var tree = try ast.Ast.parse(gpa, "<?php const FOO = 1, BAR = 2;", testing.v84);
    defer tree.deinit(gpa);
    try testing.expectNoErrors(tree);
    try testing.expectTagCounts(tree, .{ .stmt_const = 1, .const_decl = 2 });
}

test "stmt :: use :: 类/函数/常量三种导入形式" {
    const gpa = std.testing.allocator;
    var tree = try ast.Ast.parse(gpa,
        \\<?php
        \\use A\B\C;
        \\use function strlen;
    , testing.v84);
    defer tree.deinit(gpa);
    try testing.expectNoErrors(tree);
    try testing.expectTagCounts(tree, .{ .stmt_use = 2, .use_use = 2 });
}

test "stmt :: group_use :: 花括号批量导入" {
    const gpa = std.testing.allocator;
    var tree = try ast.Ast.parse(gpa, "<?php use A\\B\\{C, D as E};", testing.v84);
    defer tree.deinit(gpa);
    try testing.expectNoErrors(tree);
    try testing.expectTagCounts(tree, .{ .stmt_group_use = 1, .use_use = 2 });
}

test "stmt :: global/static/unset :: 各自成节点" {
    const gpa = std.testing.allocator;
    var tree = try ast.Ast.parse(gpa,
        \\<?php
        \\global $a, $b;
        \\static $x = 1, $y;
        \\unset($a, $b);
    , testing.v84);
    defer tree.deinit(gpa);
    try testing.expectNoErrors(tree);
    try testing.expectTagCounts(tree, .{
        .stmt_global = 1,
        .stmt_static = 1,
        .static_var = 2,
        .stmt_unset = 1,
    });
}

test "stmt :: declare :: strict_types 块形式" {
    const gpa = std.testing.allocator;
    var tree = try ast.Ast.parse(gpa, "<?php declare(strict_types=1) { $z = 1; }", testing.v84);
    defer tree.deinit(gpa);
    try testing.expectNoErrors(tree);
    try testing.expectTagCounts(tree, .{ .stmt_declare = 1, .declare_declare = 1 });
}

test "stmt :: trait use :: 别名与 insteadof 适配" {
    const gpa = std.testing.allocator;
    var tree = try ast.Ast.parse(gpa,
        \\<?php
        \\class C {
        \\    use A, B {
        \\        A::foo as bar;
        \\        B::baz insteadof A;
        \\    }
        \\}
    , testing.v84);
    defer tree.deinit(gpa);
    try testing.expectNoErrors(tree);
    try testing.expectTagCounts(tree, .{
        .stmt_trait_use = 1,
        .trait_use_adaptation_alias = 1,
        .trait_use_adaptation_precedence = 1,
    });
}

test "stmt :: __halt_compiler :: 其后源码整体忽略" {
    const gpa = std.testing.allocator;
    var tree = try ast.Ast.parse(gpa,
        \\<?php
        \\__halt_compiler();
        \\remaining source ignored
    , testing.v84);
    defer tree.deinit(gpa);
    try testing.expectNoErrors(tree);
    try testing.expectTagCounts(tree, .{ .stmt_halt = 1 });
}

test "stmt :: inline_html :: 闭合标签之间的文本" {
    const gpa = std.testing.allocator;
    var tree = try ast.Ast.parse(gpa,
        \\<?php echo 1; ?>
        \\<html>hi</html>
        \\<?php echo 2; ?>
    , testing.v84);
    defer tree.deinit(gpa);
    try testing.expectNoErrors(tree);
    try testing.expectTagCounts(tree, .{ .inline_html = 1 });
}

test "stmt :: 类修饰符 :: abstract/final/readonly 可连用且不建节点" {
    // 回归：修饰符此前未被消费，导致整个类声明解析失败（stmt_error + expected_expr）。
    const gpa = std.testing.allocator;
    const cases = [_][:0]const u8{
        "<?php abstract class C {}",
        "<?php final class C {}",
        "<?php readonly class C {}",
        "<?php abstract readonly class C {}",
        "<?php final class C { function __construct(public int $x) {} }",
    };

    for (cases) |src| {
        var tree = try ast.Ast.parse(gpa, src, testing.v84);
        defer tree.deinit(gpa);
        try testing.expectNoErrors(tree);
        try testing.expectTagCounts(tree, .{ .stmt_class = 1, .stmt_error = 0 });
    }
}

test "stmt :: namespace :: 其后多条语句全部归入（不吞语句）" {
    // 回归：此前循环无条件调用 skipToNextStmt，成功解析后又跳一条，
    // 导致命名空间内只保留第一条语句。
    const gpa = std.testing.allocator;
    const Case = struct { src: [:0]const u8, want: usize };
    const cases = [_]Case{
        .{ .src = "<?php\nnamespace N;\nuse A;\nuse B;\n", .want = 2 },
        .{ .src = "<?php\nnamespace N {\nuse A;\nuse B;\n}\n", .want = 2 },
        .{ .src = "<?php\nnamespace N;\nconst A = 1;\nconst B = 2;\n", .want = 2 },
        .{ .src = "<?php\nnamespace N;\ntrait T {}\ninterface I {}\nenum E {}\n", .want = 3 },
    };

    for (cases) |c| {
        var tree = try ast.Ast.parse(gpa, c.src, testing.v84);
        defer tree.deinit(gpa);
        try testing.expectNoErrors(tree);

        const ns = testing.firstNode(tree, .stmt_namespace) orelse return error.TestUnexpectedResult;
        const c2 = tree.extraData(tree.nodeData(ns).extra_and_opt_node[0], NamespaceComponents);
        const members = tree.extraDataSlice(c2.stmts, Index);
        if (members.len != c.want) {
            std.debug.print(
                "\n命名空间语句数不符: {s}\n  期望 {d} 条，实际 {d} 条\n",
                .{ c.src, c.want, members.len },
            );
            try std.testing.expectEqual(c.want, members.len);
        }
    }
}

test "stmt :: nop :: 裸分号成节点" {
    const gpa = std.testing.allocator;
    var tree = try ast.Ast.parse(gpa, "<?php ;", testing.v84);
    defer tree.deinit(gpa);
    try testing.expectNoErrors(tree);
    try testing.expectTagCounts(tree, .{ .stmt_nop = 1 });
}
