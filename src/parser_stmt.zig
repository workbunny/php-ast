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
/// 语句块。`lbrace`/`rbrace` 槽常规存 `{`/`}`；**替代语法**（`if (x): ... endif;`
/// 等，见 `parseColonBody`/`parseIfAltBody`）无花括号时复用这两槽存 `:` 与 end
/// 关键字 token（如 `endif`），使 mainToken/lastToken 覆盖整段——下游据其是否
/// 为 `:`/end 关键字还原替代语法形态。
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

/// `for` 的三段均可省略（`for (;;)`），且每段是逗号分隔的表达式列表
/// （`for ($i = 0, $j = 1; ...; $i++, $j--)`），故 init/cond/inc 为子节点列表。
pub const ForComponents = struct {
    init: SubRange,
    cond: SubRange,
    inc: SubRange,
    body: Index,
};

pub const ForeachComponents = struct {
    expr: Index,
    key: OptionalIndex,
    value: Index,
    body: Index,
    /// 值按引用遍历 `as &$v` / `as $k => &$v`（Foreach_.byRef，键不可引用）。
    value_by_ref: bool,
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
/// 顶层 `const A = 1, B = 2;` 的负载。`attrs` 为常量声明前的属性组区间
/// （`#[Example] const X = ...`，semantic 层据此判定「多常量带属性」）。
pub const ConstComponents = struct {
    attrs: SubRange,
    decls: SubRange,
    semi: TokenIndex,
};
pub const GlobalComponents = struct { vars: SubRange, semi: TokenIndex };
pub const StaticComponents = struct { vars: SubRange, semi: TokenIndex };
pub const UnsetComponents = struct { vars: SubRange, semi: TokenIndex };

/// 判断 token 是否为可见性修饰符（public/protected/private）。
fn isVisibility(tag: Token.Tag) bool {
    return tag == .kw_public or tag == .kw_protected or tag == .kw_private;
}

/// 跳过注释 / 文档注释（trait 适配等宽松处可跨行注释分隔 token）。
fn skipComments(p: *Parser) void {
    while (p.tokTag() == .comment or p.tokTag() == .doc_comment) {
        _ = p.nextToken();
    }
}

/// 判断顶层 `function` / `static function` 起始的语句是否为闭包表达式（无名字函数）。
/// 调用时游标停在起始关键字上（`at_static=false` 停在 function，否则停在 static），
/// 不修改游标。
fn isClosureAhead(p: *Parser, at_static: bool) bool {
    const save = p.tok_i;
    _ = p.nextToken(); // function 或 static
    if (at_static) {
        // static 后可接 `function`（静态闭包）或 `fn`（静态箭头）
        if (p.tokTag() != .kw_function and p.tokTag() != .kw_fn) {
            p.tok_i = save;
            return false;
        }
        _ = p.nextToken(); // function / fn
    }
    // 闭包特征：function/fn 后直接 `(`，或 `&(`（按引用返回的闭包）。
    const is_closure = p.tokTag() == .lparen or (p.tokTag() == .ampersand and blk: {
        _ = p.nextToken();
        break :blk p.tokTag() == .lparen;
    });
    p.tok_i = save;
    return is_closure;
}

/// 语句解析总入口：按首 token 分派到具体 parse*；跳过 open/close_tag、注释、
/// InlineHTML 等包裹性 token。裸 `;` 产出 `Stmt\Nop`；无法识别的 token 产出
/// `Stmt\Error`；返回 null 仅用于 eof / 右花括号等结构性边界。
pub fn parseStatement(p: *Parser) ast.ParseError!?Index {
    const tk = p.tok_i;
    switch (p.tokTag()) {
        .eof, .rbrace => return null,
        // 非法字符：`lexScanDiag` 已报 `Unexpected character` / `Unexpected null
        // byte`，此处静默跳过（php-parser 由宿主词法报错后不再额外产出语法错误），
        // 避免同一处重复报 expected_expr。
        .invalid => {
            _ = p.nextToken();
            return parseStatement(p);
        },
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
        // 类修饰符：`abstract`/`final`/`readonly` 可**连锁**用于类声明前
        // （`abstract readonly class`）。连续吃修饰符至非修饰符，再看是否到类关键字：
        // 是 → 交还 parseStatement 处理声明；否 → 整串回卷（修饰符只是**名字**，
        // 半保留字 `readonly()`/`final()` 作函数调用，php.y identifier → semi_reserved）。
        .kw_abstract, .kw_final, .kw_readonly => {
            const save = p.tok_i;
            // 连锁消费时顺带做引擎级语义诊断：重复修饰符与 abstract+final 组合
            // （`abstract final class`）。修饰符 token 被连锁吞掉后不随 AST 保留，
            // 事实不可恢复，故就地收集（见 doc/special.md P6 语义诊断分层）。
            var seen_abs = false;
            var seen_fin = false;
            var final_token: ast.TokenIndex = 0;
            while (p.tokTag() == .kw_abstract or p.tokTag() == .kw_final or p.tokTag() == .kw_readonly) {
                const ti = p.tok_i;
                switch (p.tokTag()) {
                    .kw_abstract => {
                        if (seen_abs) p.warnAt(ast.Error.Tag.multiple_abstract_modifiers, ti) else seen_abs = true;
                    },
                    .kw_final => {
                        if (final_token == 0) final_token = ti;
                        if (seen_fin) p.warnAt(ast.Error.Tag.multiple_final_modifiers, ti) else seen_fin = true;
                    },
                    else => {},
                }
                _ = p.nextToken();
            }
            const is_decl = switch (p.tokTag()) {
                .kw_class, .kw_enum, .kw_interface, .kw_trait => true,
                else => false,
            };
            if (is_decl) {
                if (seen_abs and seen_fin) {
                    // 定位在 `final` 修饰符上（php-parser 同），非 `class`
                    const ft = if (final_token != 0) final_token else p.tok_i;
                    p.warnAt(ast.Error.Tag.final_on_abstract_class, ft);
                }
                return try parseStatement(p);
            }
            p.tok_i = save;
            return parseExprStatement(p);
        },
        // 裸块 `{ ... }`：`if`/`while`/`for`/`foreach` 的循环体走本函数解析，
        // 缺少此分支时块体会被当作表达式语句，产出 expected_expr。
        .lbrace => return parseBlock(p),
        .kw_function => {
            // 顶层 `function(...)` / `function &(...)`（无名字）是闭包表达式语句，
            // 非命名函数声明（后者必带名字）。前瞻区分后交表达式路径解析。
            if (isClosureAhead(p, false)) return parseExprStatement(p);
            return decl.parseFunction(p, try decl.parseAttrGroups(p));
        },
        .kw_class => return decl.parseClass(p, try decl.parseAttrGroups(p)),
        .kw_enum => return decl.parseTypeDecl(p, .stmt_enum, try decl.parseAttrGroups(p)),
        .kw_interface => return decl.parseTypeDecl(p, .stmt_interface, try decl.parseAttrGroups(p)),
        .kw_trait => return decl.parseTypeDecl(p, .stmt_trait, try decl.parseAttrGroups(p)),
        .kw_namespace => {
            // `namespace\fn\use()`（relative 名调用/常量）vs `namespace fn { }`（声明）。
            // 前瞻：namespace 后跟 `\` 是表达式（相对名），否则是声明语句。
            const save = p.tok_i;
            _ = p.nextToken();
            const is_rel = p.tokTag() == .backslash;
            p.tok_i = save;
            if (is_rel) return parseExprStatement(p);
            return parseNamespace(p);
        },
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
        .kw_static => {
            // `static function(){}`（无名字）= 静态闭包表达式，非静态变量声明。
            if (isClosureAhead(p, true)) return parseExprStatement(p);
            return parseStatic(p);
        },
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
            // 注释等价空白：连续吃掉。但注释后紧跟块/文件边界（`}`/EOF，无主语句）
            // 时产出 Stmt\Nop 承载注释（php-parser 语义：纯注释块 = Nop，nopPositions/
            // comments fixture 依赖此形态），否则上层循环会把「解析到边界返回 null」
            // 误当错误而 skipToNextStmt 越界吞掉闭合符。
            const c0 = tk;
            while (p.tokTag() == .comment or p.tokTag() == .doc_comment) _ = p.nextToken();
            if (p.tokTag() == .rbrace or p.tokTag() == .eof) {
                return (try p.addNode(.{
                    .tag = .stmt_nop,
                    .main_token = c0,
                    .data = .{ .token = c0 },
                })) orelse unreachable;
            }
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
                // eof/rbrace 是结构性边界（主循环以 eof 退出），不可再推进；此处直接返回
                // null 让调用方收尾，诊断已在 parseExpr 内记过。
                if (p.tokTag() == .eof or p.tokTag() == .rbrace) return null;
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
    // 表达式语句以 `;` 收尾（PHP 硬性要求，php-parser 亦报 Syntax error
    // unexpected X/EOF）。分号前允许注释（等价空白）；缺分号时：报 expected_semi
    // 并**跳过到语句同步点**（错误恢复：php-parser 在出错后跳到同步点，不会继续
    // 解析该句剩余 token 而产出额外诊断——如 `$a{'b'};` 的 `{...}` 不再被当裸块
    // 解析）；跳到可作新语句起始的 token 即停，避免吞掉后续语句。
    // 分号位置用主 token 兜底。
    p.skipComments();
    const semi = (p.eatToken(.semicolon)) orelse blk: {
        p.warnMissingSemi();
        p.skipToStmtSync(true);
        break :blk main;
    };
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
            // 已在块/文件边界：错误恢复到此为止，让 while 条件收尾——不吞 `}`，
            // 否则 `1 + }`（recovery[4]）的 `}` 被吞、误报块未闭合。
            if (p.tokTag() == .rbrace or p.tokTag() == .eof) break;
            try p.skipToNextStmt();
            if (p.tokTag() == .close_tag) _ = p.nextToken();
            continue;
        };
        try stmts.append(p.gpa, s);
        if (p.tokTag() == .close_tag) _ = p.nextToken();
    }
    // 块未闭合（到 EOF 未见 `}`）：php-parser 报 unexpected EOF（recovery[7]：
    // `while (true) { ...` 缺 `}`）。合法代码块必有闭合 `}`，误伤面为零；但
    // `__HALT_COMPILER()` 会截断 token 流到 eof（halt 语义合法），需豁免。
    if (p.tokTag() == .eof and !p.halted) p.warn(ast.Error.Tag.unexpected_eof);
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

    var then_b: Index = undefined;
    var alt_mode = false; // then 走替代语法 `:`（需 endif 收尾）
    if (p.tokTag() == .colon) {
        alt_mode = true;
        then_b = (try parseIfAltBody(p)) orelse return null; // 收到 endif/elseif/else 停（不消费）
    } else {
        then_b = (try parseStatement(p)) orelse return null;
    }

    var else_b: ?Index = null;
    if (p.tokTag() == .kw_elseif) {
        else_b = (try parseIf(p)) orelse null;
    } else if (p.tokTag() == .kw_else) {
        _ = p.nextToken();
        if (p.tokTag() == .colon) {
            // 替代语法 else 体：到 endif 结束（endif 在此被吃，链终止）
            else_b = (try parseColonBody(p, .kw_endif)) orelse null;
            alt_mode = false; // endif 已被消费
        } else {
            else_b = (try parseStatement(p)) orelse null;
        }
    }
    if (alt_mode and p.tokTag() == .kw_endif) {
        // 无 else 链的替代 then：endif 属于 then 体，把结束符并入其 block
        _ = p.nextToken();
        _ = p.eatToken(.semicolon);
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

/// 替代语法 if 的 then 体：游标在 `:` 上。收集语句直到 endif/elseif/else（不消费，
/// 归调用方继续分支链）；产 stmt_block（无 `{`）。遇 endif 直接结束是"无分支链"情况，
/// 由调用方吃 endif 并入区间——这里若先遇 endif 就停，调用方再吃。
fn parseIfAltBody(p: *Parser) ast.ParseError!?Index {
    const colon_tok = p.nextToken(); // ':'
    var stmts = try std.ArrayList(Index).initCapacity(p.gpa, 0);
    defer stmts.deinit(p.gpa);
    const end_tok: TokenIndex = colon_tok;
    while (true) {
        const t = p.tokTag();
        if (t == .kw_endif or t == .kw_elseif or t == .kw_else or t == .eof) break;
        const s = (try parseStatement(p)) orelse {
            try p.skipToNextStmt();
            if (p.tokTag() == .close_tag) _ = p.nextToken();
            continue;
        };
        try stmts.append(p.gpa, s);
        if (p.tokTag() == .close_tag) _ = p.nextToken();
    }
    const lr = try p.addNodeList(stmts.items);
    const extra = try p.addExtra(BlockComponents{
        .lbrace = colon_tok,
        .rbrace = end_tok, // endif 未到则占冒号（有分支链时 endif 属于链尾 else 段）
        .stmts = .{ .start = lr.start, .end = lr.end },
    });
    return (try p.addNode(.{
        .tag = .stmt_block,
        .main_token = colon_tok,
        .data = .{ .extra = extra },
    })) orelse unreachable;
}

/// while 循环：`while (cond) body`。
pub fn parseWhile(p: *Parser) ast.ParseError!?Index {
    const kw = p.nextToken();
    _ = p.expectToken(.lparen);
    const cond = (try expr.parseExpr(p)) orelse return null;
    _ = p.expectToken(.rparen);
    const body = (try parseBody(p, .kw_endwhile)) orelse return null;
    const extra = try p.addExtra(WhileComponents{ .cond = cond, .body = body });
    return (try p.addNode(.{
        .tag = .stmt_while,
        .main_token = kw,
        .data = .{ .extra_and_node = .{ extra, body } },
    })) orelse unreachable;
}

/// for 循环：`for (init; cond; inc) body`。每段为逗号分隔的表达式列表，
/// 可整体省略：`for (;;)`。原实现各段只取单个表达式，遇 `$i = 0, $j = 1` 多
/// 初始表达式即在 `,` 处报 expected_token——对齐 php-parser `Stmt\For` 的
/// init/cond/loop 均为数组。
pub fn parseFor(p: *Parser) ast.ParseError!?Index {
    const kw = p.nextToken();
    _ = p.expectToken(.lparen);
    const init = try parseForSection(p, .semicolon);
    _ = p.expectToken(.semicolon);
    const cond = try parseForSection(p, .semicolon);
    _ = p.expectToken(.semicolon);
    const inc = try parseForSection(p, .rparen);
    _ = p.expectToken(.rparen);
    const body = (try parseBody(p, .kw_endfor)) orelse return null;
    const extra = try p.addExtra(ForComponents{
        .init = init,
        .cond = cond,
        .inc = inc,
        .body = body,
    });
    return (try p.addNode(.{
        .tag = .stmt_for,
        .main_token = kw,
        .data = .{ .extra_and_node = .{ extra, body } },
    })) orelse unreachable;
}

/// 收集 for 段内逗号分隔的表达式列表，至 `term`（不含）为止；段空（`for (;;)` 或
/// 立即遇分隔符）返回空范围。解析失败返回空范围，让调用方在分隔符处报期望错。
fn parseForSection(p: *Parser, term: Token.Tag) ast.ParseError!SubRange {
    var list = try std.ArrayList(Index).initCapacity(p.gpa, 0);
    defer list.deinit(p.gpa);
    while (p.tokTag() != term and p.tokTag() != .eof) {
        const e = (try expr.parseExpr(p)) orelse return p.emptySubRange();
        try list.append(p.gpa, e);
        // `for ($a, ; ...)`：PHP 不允许尾逗号（段结束定界符 `;` 或 `)`）
        if (p.eatListComma(false, &.{ term, .rparen })) continue;
        break;
    }
    if (list.items.len == 0) return p.emptySubRange();
    const lr = try p.addNodeList(list.items);
    return .{ .start = lr.start, .end = lr.end };
}

/// foreach 循环：`foreach ($it as $k => $v) body`。
pub fn parseForeach(p: *Parser) ast.ParseError!?Index {
    const kw = p.nextToken();
    _ = p.expectToken(.lparen);
    const e = (try expr.parseExpr(p)) orelse return null;
    var key: OptionalIndex = .none;
    var value = e;
    var value_by_ref = false;
    if (p.tokTag() == .kw_as) {
        _ = p.nextToken();
        // `as` 之后先解析第一个表达式：若其后紧跟 `=>`，则它是键、需再解析值；
        // 否则它即值本身（引用值：`as &$v`，或 `as $k => &$v`）。
        if (p.tokTag() == .ampersand) {
            _ = p.nextToken();
            value_by_ref = true;
        }
        const first = (try expr.parseExpr(p)) orelse return null;
        value = first;
        if (p.tokTag() == .double_arrow) {
            _ = p.nextToken();
            key = OptionalIndex.fromIndex(first);
            value_by_ref = false;
            if (p.tokTag() == .ampersand) {
                _ = p.nextToken();
                value_by_ref = true;
            }
            value = (try expr.parseExpr(p)) orelse return null;
        }
    } else {
        // `foreach ($foo) {` 缺 `as`：报错（expecting 'as'）后跳过到 `)`，
        // foreach 视为无 key/value——不再继续解析 value 而连锁多报。
        _ = p.expectToken(.kw_as);
        while (p.tokTag() != .rparen and p.tokTag() != .eof) _ = p.nextToken();
    }
    _ = p.expectToken(.rparen);
    const body = (try parseBody(p, .kw_endforeach)) orelse return null;
    const extra = try p.addExtra(ForeachComponents{
        .expr = e,
        .key = key,
        .value = value,
        .body = body,
        .value_by_ref = value_by_ref,
    });
    return (try p.addNode(.{
        .tag = .stmt_foreach,
        .main_token = kw,
        .data = .{ .extra_and_node = .{ extra, value } },
    })) orelse unreachable;
}

/// 替代语法体（php `if (x): ... endif;` 族）：游标在 `:` 上。收集语句至 `end_tag`
/// （含；吃掉其后 `;`），产 `stmt_block`——无花括号，BlockComponents 的 lbrace/rbrace
/// 槽存 `:` 与 end 关键字的 token，使 lastToken/区间覆盖整段替代语法（打印器按此还原
/// `: ... endif;`）。嵌套控制流各自消费自己的 endXXX：语句解析遇其它 endXXX 属语法
/// 错误（诊断后跳过），不会把别人的收尾符当自身结束。
fn parseColonBody(p: *Parser, end_tag: Token.Tag) ast.ParseError!?Index {
    const colon_tok = p.nextToken(); // ':'
    var stmts = try std.ArrayList(Index).initCapacity(p.gpa, 0);
    defer stmts.deinit(p.gpa);
    var end_tok: TokenIndex = colon_tok;
    while (true) {
        const t = p.tokTag();
        if (t == end_tag) {
            end_tok = p.nextToken();
            _ = p.eatToken(.semicolon);
            break;
        }
        if (t == .eof) break;
        const s = (try parseStatement(p)) orelse {
            try p.skipToNextStmt();
            if (p.tokTag() == .close_tag) _ = p.nextToken();
            continue;
        };
        try stmts.append(p.gpa, s);
        if (p.tokTag() == .close_tag) _ = p.nextToken();
    }
    const lr = try p.addNodeList(stmts.items);
    const extra = try p.addExtra(BlockComponents{
        .lbrace = colon_tok,
        .rbrace = end_tok,
        .stmts = .{ .start = lr.start, .end = lr.end },
    });
    return (try p.addNode(.{
        .tag = .stmt_block,
        .main_token = colon_tok,
        .data = .{ .extra = extra },
    })) orelse unreachable;
}

/// 控制流体：`{ }` 块 / 单语句 / 替代语法 `: ... endXXX;`。
fn parseBody(p: *Parser, end_tag: Token.Tag) ast.ParseError!?Index {
    return switch (p.tokTag()) {
        .lbrace => parseBlock(p),
        .colon => parseColonBody(p, end_tag),
        else => parseStatement(p),
    };
}

/// 命名空间声明：支持 `namespace Name;`（无括号，后续语句均属该空间，至文件尾）、
/// `namespace Name { ... }`（块形式）与 `namespace { ... }`（全局命名空间，名为空）。
pub fn parseNamespace(p: *Parser) ast.ParseError!?Index {
    const kw = p.nextToken();
    var name: OptionalIndex = .none;
    if (expr.isNamePart(p.tokTag())) {
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
    // 无表达式 return：`return;`（`;`/`}`/eof 等非表达式起始 token 时产空值 return，
    // 对齐 php `return;` 与 `return;` 的合法形态；其余走表达式）。
    var e: OptionalIndex = .none;
    if (expr.isValueStart(p.tokTag())) {
        const x = (try expr.parseExpr(p)) orelse return null;
        e = OptionalIndex.fromIndex(x);
    }
    const semi = (p.eatToken(.semicolon)) orelse kw;
    return (try p.addNode(.{
        .tag = .stmt_return,
        .main_token = kw,
        .data = .{ .opt_node_and_token = .{ e, semi } },
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
        // `echo $a, ;`：PHP 不允许尾逗号（`echo` 列表的结束定界符是 `;`）
        if (p.eatListComma(false, &.{.semicolon})) continue;
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
    // do 无替代语法（无 enddo）；体可为块或单语句（`do $A; while ($a);`）。
    const body = (try parseBody(p, .eof)) orelse return null;
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
                // case 分隔符：PHP 允许 `case 1:` 与 `case 1;` 两种写法。
                if (p.eatToken(.colon) == null) _ = p.eatToken(.semicolon);
                var stmts = try std.ArrayList(Index).initCapacity(p.gpa, 0);
                defer stmts.deinit(p.gpa);
                while (true) {
                    // 先跳过注释再判界：注释不能把 case 边界带进 parseStatement
                    // （否则 `case` 落错误恢复被吞、cond 被当缺分号语句报错）。
                    p.skipComments();
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
                    // 同 case 块：注释不跨 case/default 边界（见上）。
                    p.skipComments();
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
        // `const A = 42, ;`：PHP 不允许尾逗号（结束定界符 `;`）
        if (p.eatListComma(false, &.{.semicolon})) continue;
        break;
    }
    const semi = (p.eatToken(.semicolon)) orelse kw;
    const lr = try p.addNodeList(decls.items);
    const extra = try p.addExtra(ConstComponents{
        .attrs = attrs,
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
    // 先解析首个 name；分组 use 必须形如 `use A\B\{...}`（name 后是 `\` 且再后为
    // `{`）。`use Foo {Bar}`（`{` 直接跟名）不是分组——PHP 报 unexpected '{'
    // expecting ';'，随后的 `{Bar, Baz}` 恢复为独立块（与 Stmt_Use(Foo) 平级）。
    const first = (try expr.parseName(p)) orelse return null;
    const is_group = p.tokTag() == .backslash and p.tok_i + 1 < p.tokens.len and
        p.tokens.items(.tag)[p.tok_i + 1] == .lbrace;
    if (is_group) {
        const prefix = first;
        _ = p.nextToken(); // 吃 `\`
        _ = p.eatToken(.lbrace);
        var uses = try std.ArrayList(Index).initCapacity(p.gpa, 0);
        defer uses.deinit(p.gpa);
        while (p.tokTag() != .rbrace and p.tokTag() != .eof) {
            // 组内子项可带类型前缀：`use A\B\{C\D, function b\c, const D};`
            var item_kind = kind;
            if (p.tokTag() == .kw_function) {
                item_kind = 1;
                _ = p.nextToken();
            } else if (p.tokTag() == .kw_const) {
                item_kind = 2;
                _ = p.nextToken();
            }
            // 组内项不允许完全限定名（`use A\B\{\C}` 的 `\C` 前导 `\` 非法；
            // php-parser 报 unexpected T_NAME_FULLY_QUALIFIED）。
            if (p.tokTag() == .backslash) {
                p.warnAt(ast.Error.Tag.expected_token, p.tok_i);
            }
            const name = (try expr.parseName(p)) orelse break;
            const u = try buildUseUse(p, name, item_kind);
            try uses.append(p.gpa, u);
            // 组 use `use A\{B, }`：PHP **允许**尾逗号（与顶层 use 列表不同）
            if (p.eatListComma(true, &.{})) continue;
            break;
        }
        const rbrace = (p.eatToken(.rbrace)) orelse kw;
        p.skipComments();
        const semi = (p.eatToken(.semicolon)) orelse blk: {
            // use 声明以 `;` 收尾（PHP 硬性，`?>` 前可省）；缺分号时下一个 token
            // 留给外层循环当新语句起点（错误恢复，php-parser 同法）。
            p.warnMissingSemi();
            break :blk rbrace;
        };
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
    // `use A, ;`：PHP 不允许尾逗号（结束定界符 `;`）
    while (p.eatListComma(false, &.{.semicolon})) {
        const name = (try expr.parseName(p)) orelse break;
        try uses.append(p.gpa, try buildUseUse(p, name, kind));
    }
    p.skipComments();
    const semi = (p.eatToken(.semicolon)) orelse blk: {
        // use 声明以 `;` 收尾（`?>` 前可省）；缺分号（`use Foo {Bar}` 的 `{`、
        // 下一条 use 等）报 expected_semi，token 留给外层恢复。
        p.warnMissingSemi();
        break :blk kw;
    };
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
        // `use A, ;`（trait use）：PHP 不允许尾逗号（结束定界符 `;` 或适配块 `{`）
        if (p.eatListComma(false, &.{ .semicolon, .lbrace })) continue;
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
    skipComments(p);
    if (p.tokTag() == .rbrace or p.tokTag() == .eof) return null;
    // A::foo
    const maybe_trait = (try expr.parseName(p)) orelse return null;
    if (p.tokTag() == .double_colon) {
        _ = p.nextToken();
        // 方法名前可跨行注释（semiReserved fixture：`TraitA::\n// c\n# a\ncatch`）
        skipComments(p);
        trait = OptionalIndex.fromIndex(maybe_trait);
        method = p.nextToken();
    } else {
        // 仅方法名（无 trait 限定）
        method = p.nodeMainToken(maybe_trait);
    }
    skipComments(p);
    if (p.tokTag() == .kw_as) {
        _ = p.nextToken();
        skipComments(p);
        var modifier: OptionalTokenIndex = .none;
        var alias: OptionalTokenIndex = .none;
        // 顺序：可视性修饰符 或 别名，二者择一（亦可 修饰符 别名；别名目标可为
        // 关键字——semiReserved `as protected public` / `as foreach` / `as die`）。
        if (isVisibility(p.tokTag())) {
            modifier = OptionalTokenIndex.fromToken(p.nextToken());
            skipComments(p);
            // 修饰符后别名：标识符/关键字均可
            if (p.tokTag() == .identifier or p.tokTag().isKeyword()) {
                if (p.tokTag() == .kw_as) _ = p.nextToken();
                alias = OptionalTokenIndex.fromToken(p.nextToken());
            }
        } else if (p.tokTag() == .identifier or p.tokTag().isKeyword()) {
            alias = OptionalTokenIndex.fromToken(p.nextToken());
        } else if (p.tokTag() == .kw_as) {
            // `as as` 形式（少见）：吃掉双 as
            _ = p.nextToken();
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
            // `A::b insteadof C, ;`：PHP 不允许尾逗号（结束定界符 `;`）
            if (p.eatListComma(false, &.{.semicolon})) continue;
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
        // `declare(a=42, )`：PHP 不允许尾逗号（结束定界符 `)`）
        if (p.eatListComma(false, &.{.rparen})) continue;
        break;
    }
    const rparen = (p.eatToken(.rparen)) orelse kw;
    var stmts: OptionalIndex = .none;
    var semi: TokenIndex = rparen;
    if (p.tokTag() == .lbrace) {
        stmts = OptionalIndex.fromIndex((try parseBlock(p)) orelse return null);
    } else if (p.tokTag() == .colon) {
        // 替代语法体 `declare (...) : ... enddeclare;`
        stmts = OptionalIndex.fromIndex((try parseColonBody(p, .kw_enddeclare)) orelse return null);
    } else if (p.tokTag() != .semicolon and p.tokTag() != .eof and p.tokTag() != .rbrace) {
        // 单语句体 `declare (a='b') $C;`（blockless）
        stmts = OptionalIndex.fromIndex((try parseStatement(p)) orelse return null);
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
        // global_var = simple_variable：`global $a, $$b, ${'c'}`，**不含后缀链**
        // （`global $$foo->bar` 是语法错误——对齐 php-parser grammar 严格形态）。
        const v = (try expr.parseSimpleVariable(p)) orelse return null;
        try vars.append(p.gpa, v);
        // `global $a, ;`：PHP 不允许尾逗号（结束定界符 `;`）
        if (p.eatListComma(false, &.{.semicolon})) continue;
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
        // `static $a, ;`：PHP 不允许尾逗号（结束定界符 `;`）
        if (p.eatListComma(false, &.{.semicolon})) continue;
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
        // 尾逗号 `unset($a, $b,)` 直接遇 `)`
        if (p.tokTag() == .rparen or p.tokTag() == .eof) break;
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
    p.skipComments();
    const semi = (p.eatToken(.semicolon)) orelse blk: {
        // `__halt_compiler()` 后必须有 `;`（`?>` 前可省；php-parser 其余报
        // unexpected EOF expecting ';'）。
        p.warnMissingSemi();
        break :blk rparen;
    };
    // 设 tok_i 到 eof，使 parseRoot 的 while 循环自然结束（halt 语义：其后代码整体截断）
    p.tok_i = @as(TokenIndex, @intCast(p.tokens.len - 1));
    p.halted = true;
    return (try p.addNode(.{
        .tag = .stmt_halt,
        .main_token = kw,
        .data = .{ .token_and_token = .{ kw, semi } },
    })) orelse unreachable;
}

// ===========================================================================
// 测试：语句
// ===========================================================================

test "stmt :: 表达式语句缺分号 :: 报 expected_semi（`?>` 前可省）" {
    const gpa = std.testing.allocator;
    var t = try ast.Ast.parse(gpa, "<?php $a = 1 $b = 2;", testing.v85);
    defer t.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 1), testing.countError(&t, .expected_semi));

    // 注释夹在语句与分号之间合法（注释等价空白）
    var c = try ast.Ast.parse(gpa, "<?php echo 1 // c\n;", testing.v85);
    defer c.deinit(gpa);
    try testing.expectNoErrors(c);

    // `?>` 前省略分号合法
    var ct = try ast.Ast.parse(gpa, "<?php echo 1 ?>", testing.v85);
    defer ct.deinit(gpa);
    try testing.expectNoErrors(ct);
}

test "stmt :: foreach :: 缺 as 只报一条并恢复解析 body" {
    const gpa = std.testing.allocator;
    var t = try ast.Ast.parse(gpa, "<?php foreach ($foo) { $bar; }", testing.v85);
    defer t.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 1), t.errors.len); // expecting 'as'
    try testing.expectTagCounts(t, .{ .stmt_foreach = 1 });
}

test "stmt :: 表达式残缺 :: 不吞块闭合符（recovery[4] 形态）" {
    const gpa = std.testing.allocator;
    var t = try ast.Ast.parse(gpa, "<?php function test() { 1 + }", testing.v85);
    defer t.deinit(gpa);
    // 只报 expected_expr（`+` 后缺操作数）；`}` 应闭合函数体，不再连锁 unexpected_eof
    try std.testing.expectEqual(@as(usize, 1), testing.countError(&t, .expected_expr));
    try std.testing.expectEqual(@as(usize, 0), testing.countError(&t, .unexpected_eof));
}

test "stmt :: 尾逗号 :: 不允许尾逗号的位置报 trailing_comma，允许的放行" {
    const gpa = std.testing.allocator;
    // PHP 不允许尾逗号的位置（php-parser：`A trailing comma is not allowed here`）；
    // 每例期望 1 条，仅 `for` 的三段各一条（共 3 条）。
    inline for (.{
        .{ "<?php echo $a, ;", 1 },
        .{ "<?php global $a, ;", 1 },
        .{ "<?php static $a, ;", 1 },
        .{ "<?php const A = 42, ;", 1 },
        .{ "<?php use A, ;", 1 },
        .{ "<?php declare(a=42, );", 1 },
        .{ "<?php for ($a, ; $b, ; $c, );", 3 },
        .{ "<?php class X implements Y, { }", 1 },
        .{ "<?php class X { const A = 42, ; }", 1 },
        .{ "<?php class X { public $x, ; }", 1 },
        .{ "<?php class X { use A, ; }", 1 },
        .{ "<?php class X { use A { A::b insteadof C, ; } }", 1 },
    }) |c| {
        var t = try ast.Ast.parse(gpa, c.@"0", testing.v84);
        defer t.deinit(gpa);
        try std.testing.expectEqual(c.@"1", testing.countError(&t, .trailing_comma));
    }

    // 允许尾逗号的位置：不报
    inline for (.{
        "<?php use A\\{B, };",
        "<?php foo($a, );",
        "<?php [1, 2, ];",
        "<?php unset($a, );",
        "<?php isset($a, );",
    }) |src| {
        var t = try ast.Ast.parse(gpa, src, testing.v84);
        defer t.deinit(gpa);
        try testing.expectNoErrors(t);
    }
}

test "stmt :: 缺分号恢复 :: 跳到语句同步点，不吞后续语句也不重复报" {
    const gpa = std.testing.allocator;
    // 块内两条缺分号语句：php-parser 各报一条 + 块未闭合到 EOF 一条。
    var a = try ast.Ast.parse(gpa, "<?php function foo() {\n    bar()\n    baz()\n}", testing.v85);
    defer a.deinit(gpa);
    // bar() 缺分号、baz() 缺分号：两条 expected_semi（不吞掉 baz）
    try std.testing.expectEqual(@as(usize, 2), testing.countError(&a, .expected_semi));

    // `$a{'b'};`（PHP 8 起花括号下标非法）：`{...}` 不再被当裸块解析而额外报错
    var b = try ast.Ast.parse(gpa, "<?php $a{'b'};", testing.v85);
    defer b.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 1), testing.countError(&b, .expected_semi));
}

test "stmt :: switch :: case 分号分隔与注释不跨 case 边界" {
    const gpa = std.testing.allocator;
    var t = try ast.Ast.parse(gpa,
        \\<?php
        \\switch ($a) {
        \\    case 0:
        \\        break;
        \\    // Comment
        \\    case 1;
        \\    default:
        \\}
    , testing.v85);
    defer t.deinit(gpa);
    try testing.expectNoErrors(t);
    // switch 的分支节点是 stmt_switch_case（stmt_case 属 enum case）
    try testing.expectTagCounts(t, .{ .stmt_switch_case = 2, .stmt_default = 1 });
}

test "stmt :: 未闭合块到 EOF :: 报 unexpected_eof（halt 截断豁免）" {
    const gpa = std.testing.allocator;
    var t = try ast.Ast.parse(gpa, "<?php while (true) { $i = 1;", testing.v85);
    defer t.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 1), testing.countError(&t, .unexpected_eof));

    // __HALT_COMPILER() 截断 token 流到 eof，不是真未闭合
    var h = try ast.Ast.parse(gpa, "<?php if (true) { __halt_compiler(); }", testing.v85);
    defer h.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 0), testing.countError(&h, .unexpected_eof));
}

test "stmt :: 块内注释到边界 :: 产 stmt_nop 不越界吞闭合符" {
    const gpa = std.testing.allocator;
    // 函数体（语句列表）内注释到块边界 → Stmt\Nop 承载注释
    var t = try ast.Ast.parse(gpa, "<?php function bar() { return null; // comment\n}", testing.v85);
    defer t.deinit(gpa);
    try testing.expectNoErrors(t);
    try testing.expectTagCounts(t, .{ .stmt_nop = 1 });

    // 文件末尾注释（根语句列表）同例
    var r = try ast.Ast.parse(gpa, "<?php echo 1; // trailing", testing.v85);
    defer r.deinit(gpa);
    try testing.expectNoErrors(r);
    try testing.expectTagCounts(r, .{ .stmt_nop = 1 });
}

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

test "stmt :: for :: 各段逗号分隔多表达式（对齐 For_ init/cond/loop 数组）" {
    const gpa = std.testing.allocator;
    var tree = try ast.Ast.parse(gpa,
        \\<?php
        \\for ($i = 0, $j = 1; $i < 10, $j < 10; $i++, $j--) { }
    , testing.v84);
    defer tree.deinit(gpa);
    try testing.expectNoErrors(tree);
    // init 两表达式 + cond 两表达式 + inc 两个自增/自减
    try testing.expectTagCounts(tree, .{
        .stmt_for = 1,
        .expr_assign = 2,
        .expr_binary = 2,
        .expr_post_inc = 1,
        .expr_post_dec = 1,
    });
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

test "stmt :: foreach :: 值按引用 as &$v 与 as $k => &$v" {
    const gpa = std.testing.allocator;
    var tree = try ast.Ast.parse(gpa,
        \\<?php
        \\foreach ($a as &$v) { $v++; }
        \\foreach ($a as $k => &$v) { unset($v); }
    , testing.v84);
    defer tree.deinit(gpa);
    try testing.expectNoErrors(tree);
    try testing.expectTagCounts(tree, .{ .stmt_foreach = 2, .expr_post_inc = 1 });
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

test "stmt :: use :: 收尾与分组形态的非法写法均有诊断" {
    const gpa = std.testing.allocator;
    // `use Foo {Bar, Baz}`：`{` 直接跟名不是分组——缺分号，随后块恢复为平级语句
    // （块内 `Bar` 与缺尾分号也会各报一条，收集式模型下全记录）。
    var a = try ast.Ast.parse(gpa, "<?php use Foo {Bar, Baz}", testing.v84);
    defer a.deinit(gpa);
    try std.testing.expect(testing.countError(&a, .expected_semi) >= 1);

    // 分组缺收尾分号
    var b = try ast.Ast.parse(gpa, "<?php use Foo\\{Bar} use Bar;", testing.v84);
    defer b.deinit(gpa);
    try std.testing.expect(testing.countError(&b, .expected_semi) >= 1);

    // 分组项不允许完全限定名
    var c = try ast.Ast.parse(gpa, "<?php use Foo\\{\\Bar};", testing.v84);
    defer c.deinit(gpa);
    try std.testing.expect(c.errors.len > 0);

    // 合法分组无诊断
    var d = try ast.Ast.parse(gpa, "<?php use Foo\\{Bar, Baz as Q};", testing.v84);
    defer d.deinit(gpa);
    try testing.expectNoErrors(d);
}

test "stmt :: halt :: 缺收尾分号报 expected_semi" {
    const gpa = std.testing.allocator;
    var t = try ast.Ast.parse(gpa, "<?php __halt_compiler()", testing.v85);
    defer t.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 1), testing.countError(&t, .expected_semi));

    var ok = try ast.Ast.parse(gpa, "<?php __halt_compiler();", testing.v85);
    defer ok.deinit(gpa);
    try testing.expectNoErrors(ok);
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
