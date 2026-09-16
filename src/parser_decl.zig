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

const stmt = @import("parser_stmt.zig");
const expr = @import("parser_expr.zig");
const testing = @import("testing.zig");
const types = @import("parser_type.zig");
const reserved = @import("reserved.zig");

/// 声明类节点（函数/类/属性/参数/属性组等）的附加负载组件，序列化进 extra_data。
pub const AttributeComponents = struct {
    name: Index,
    args: SubRange,
};

pub const CaseComponents = struct {
    name: TokenIndex,
    value: OptionalIndex,
    attrs: SubRange,
    /// 声明结尾的 `;`。定界符不是子节点，只能这样单独存。
    semi: TokenIndex,
};

pub const TypeDeclComponents = struct {
    name: TokenIndex,
    attrs: SubRange,
    backing: OptionalIndex,
    /// interface → extends 名字列表；enum → implements 名字列表；trait → 空。
    /// 语义由所属 tag（stmt_interface/stmt_enum）决定。
    ext_impl: SubRange,
    stmts: SubRange,
    flags: u32,
};

pub const PropertyComponents = struct {
    type: OptionalIndex,
    flags: u32,
    visibility: u32,
    /// 属性项列表 `$a = 1, $b = 2`（对齐 php-parser Property 的 props: array；
    /// 每项 property_item：name token + optional default）。
    props: SubRange,
    hooks: SubRange,
    attrs: SubRange,
    /// 声明结尾的 `;`。
    semi: TokenIndex,
    /// 源码中是否出现钩子块 `{ ... }`。`hooks` 为空区间无法区分「无钩子」与
    /// 「空钩子块 `$a { }`」（二者同为空区间）；空钩子块是非法构造（semantic 层
    /// 报 `hook_empty`），必须能回溯此事实，故单独标记。
    has_hook_block: bool,
    /// 钩子块的 `{` token（无钩子块时为 0）——「多属性带钩子」诊断定位在它上面。
    hook_lbrace: TokenIndex,
};

pub const PropertyHookComponents = struct {
    name: TokenIndex,
    flags: u32,
    params: SubRange,
    attrs: SubRange,
    /// 源码中是否出现参数表 `( ... )`。`params` 为空区间无法区分「空参数表
    /// `get()`」与「无参数表 `get {}`」，而钩子上出现任何参数表（含空）都非法
    /// （semantic 层报 `hook_get_params`），故单独标记。
    has_param_list: bool,
    /// 参数表的 `(` token（无参数表时为 0）——诊断定位在 `(` 上（php-parser 同）。
    lparen: TokenIndex,
};

pub const ClassComponents = struct {
    name: TokenIndex,
    attrs: SubRange,
    extends: OptionalIndex,
    /// implements 名字列表（`class A implements B, C`，可多个）。
    implements: SubRange,
    stmts: SubRange,
    flags: u32,
};

pub const FunctionComponents = struct {
    name: TokenIndex,
    attrs: SubRange,
    params: SubRange,
    ret: OptionalIndex,
    body: OptionalIndex,
    /// 引用返回 `function &name(...)`（Function_.byRef）。
    by_ref: bool,
};

pub const ParamComponents = struct {
    name: TokenIndex,
    flags: u32, // 1=abstract 2=final 4=static 8=readonly（参数位不使用）
    promoted: u32, // 构造器属性提升可见性：0=非提升 1=public 2=protected 3=private
    variadic: bool, // 可变参数 `...$x`
    /// 引用参数 `&$x`（Param.byRef，可叠加变长：`&...$x`）。
    by_ref: bool,
    type: OptionalIndex,
    default: OptionalIndex,
    /// 提升属性钩子（8.4 `__construct(public $h { set => $v; })`）；非提升参数为空。
    hooks: SubRange,
    attrs: SubRange,
    /// 源码中是否出现钩子块 `{ ... }`（含空块）——同 `PropertyComponents`：
    /// 空区间无法区分「无钩子」与「空钩子块」，而空钩子块非法需能回溯。
    has_hook_block: bool,
    /// 钩子块的 `{` token（无钩子块时为 0）——诊断定位在它上面。
    hook_lbrace: TokenIndex,
};

pub const PropertyMods = struct {
    flags: u32,
    visibility: u32,
    /// 是否出现过任何修饰符/可见性/`var`。属性（PHP 8.5 起）与部分语境依赖此判定
    /// 「无修饰符声明」是否合法。
    has_modifier: bool = false,
    /// 首个修饰符/可见性 token（消息需引用修饰符文本时取用）。
    first_mod_token: TokenIndex = 0,
    /// `final` 修饰符 token（`final` 与 `abstract` 冲突时报错定位在此）。
    final_token: TokenIndex = 0,
    /// 是否已出现 set 侧可见性修饰符（`private(set)`）。非对称可见性每个属性
    /// 至多一个，重复即为 `Multiple access type modifiers are not allowed`。
    set_seen: bool = false,
};

/// 类方法（Stmt\ClassMethod）：含可见性 / static / abstract / final / byRef 等修饰符。
pub const MethodComponents = struct {
    name: TokenIndex,
    attrs: SubRange,
    params: SubRange,
    ret: OptionalIndex,
    body: OptionalIndex,
    /// 声明的修饰符起始 token（无修饰符时即 `function`）。语义诊断（如「魔法方法
    /// 不能 static」）定位在修饰符上，故需记录。
    mod_start: TokenIndex,
    flags: u32, // 位标志：1=abstract 2=final 4=static 8=readonly
    visibility: u32, // 0=public 1=protected 2=private
    by_ref: bool,
};

/// 类常量（Stmt\ClassConst）：可见性、类型（PHP 8.3 起支持）与初值。
///
/// 一项声明可含多个常量（`const A = 1, B = 2`），对齐 php-parser `consts: array`——
/// 各项与顶层 const 同构为 `.const_decl` 子节点（`name = value`，name 可为关键字：
/// semiReserved 的 `const TRAIT = 3`）。
pub const ClassConstComponents = struct {
    type: OptionalIndex,
    flags: u32, // 可见性：0=public 1=protected 2=private
    decls: SubRange,
    attrs: SubRange,
    /// 声明结尾的 `;`。
    semi: TokenIndex,
};

/// 解析函数声明（顶层或类内方法）：`function name(params): ret { body }`，
/// 无体时以 `;` 结束（前向声明 / 接口方法）。
pub fn parseFunction(p: *Parser, attrs: SubRange) ast.ParseError!?Index {
    const kw = p.nextToken();
    // 引用返回：`function &name(...)`（顶层函数返回引用，与方法 parseMethod 同款）
    var by_ref = false;
    if (p.tokTag() == .ampersand) {
        _ = p.nextToken();
        by_ref = true;
    }
    // 函数名位（php.y `fn_identifier`）：只接受 T_STRING 与 readonly / exit / clone；
    // `function list() {}` 一类 semi_reserved 关键字是语法错（方法名位才允许，
    // 见 `parseMethod`）。缺名时不消费 token，交给外层恢复。
    if (!reserved.isFnIdentifier(p.tokTag(), p.version)) {
        p.warnAtExpected(ast.Error.Tag.expected_token, p.tok_i, .name);
        return null;
    }
    const name_tok = p.nextToken();
    const plr = (try parseParamList(p)) orelse return null;
    var ret: OptionalIndex = .none;
    if (p.tokTag() == .colon) {
        _ = p.nextToken();
        const rt = (try types.parseType(p)) orelse return null;
        ret = OptionalIndex.fromIndex(rt);
    }
    var body: OptionalIndex = .none;
    if (p.tokTag() == .semicolon) {
        _ = p.nextToken();
    } else if (p.tokTag() == .lbrace) {
        const b = (try stmt.parseBlock(p)) orelse return null;
        body = OptionalIndex.fromIndex(b);
    }
    // 既非 `;` 亦非 `{`（`function foo(Bar)` 紧跟下一条语句）：函数体缺失。此处
    // **不报诊断**，当前 token 留给外层当新语句起点——php-parser 在该状态只报参数
    // 位错误，对缺体本身静默（recovery[21] 的 `function foo(Bar)` 后接 `class Bar`）。
    const extra = try p.addExtra(FunctionComponents{
        .name = name_tok,
        .attrs = attrs,
        .params = plr,
        .ret = ret,
        .body = body,
        .by_ref = by_ref,
    });
    return (try p.addNode(.{
        .tag = .stmt_function,
        .main_token = kw,
        .data = .{ .extra_and_opt_node = .{ extra, ret } },
    })) orelse unreachable;
}

/// 解析单个函数参数：`Type &$name = default`，含属性组、引用符号与默认值。
pub fn parseParam(p: *Parser) ast.ParseError!?Index {
    var attrs = p.emptySubRange();
    if (p.tokTag() == .hash) attrs = try parseAttrGroups(p);
    var flags: u32 = 0;
    // 构造器属性提升：`public`/`protected`/`private` 置于参数类型前。
    // 修饰符与类型间的顺序在 PHP 中较自由（`public readonly int`、`readonly public int`），
    // 故循环吸收而非只判一次——漏掉 `readonly` 会让 `$x` 被当作表达式而报 expected_variable。
    var promoted: u32 = 0;
    // `public final int $x` 形式的构造器属性提升为 8.5 引入
    var is_final_promoted = false;
    while (true) {
        switch (p.tokTag()) {
            .kw_public => {
                promoted = 1;
                _ = p.nextToken();
            },
            .kw_protected => {
                promoted = 2;
                _ = p.nextToken();
            },
            .kw_private => {
                promoted = 3;
                _ = p.nextToken();
            },
            .kw_readonly => {
                flags |= 32;
                _ = p.nextToken();
            },
            .kw_final => {
                is_final_promoted = true;
                _ = p.nextToken();
            },
            else => break,
        }
    }
    var type_opt: OptionalIndex = .none;
    if (types.isTypeStart(p)) {
        const ty = (try types.parseType(p)) orelse return null;
        type_opt = OptionalIndex.fromIndex(ty);
    }
    // 引用符号在前、变长省略号在后：`Type &...$x`（引用可变参数）。顺序不可调换——
    // 调换后 `&...` 的 `&` 会先被吃掉，剩余 `...` 在 variable 处误报 expected_variable。
    var by_ref = false;
    var amp_tok: ?TokenIndex = null;
    if (p.tokTag() == .ampersand) {
        amp_tok = p.tok_i;
        _ = p.nextToken();
        by_ref = true;
    }
    var variadic = false;
    if (p.tokTag() == .ellipsis) {
        _ = p.nextToken();
        variadic = true;
    }
    if (p.tokTag() != .variable) {
        // 参数名位只接受变量本身（php-parser：`expecting T_VARIABLE`，不含 `$`/`{`）。
        // `&` 已被消费而缺变量名（`function foo(&)`）时诊断落在 `&` 上——php-parser 报
        // `unexpected T_AMPERSAND_NOT_FOLLOWED_BY_VAR_OR_VARARG, expecting T_VARIABLE`。
        p.warnAtExpected(ast.Error.Tag.expected_variable, amp_tok orelse p.tok_i, .variable);
        return null;
    }
    const var_tok = p.nextToken();
    var def: OptionalIndex = .none;
    if (p.tokTag() == .equals) {
        _ = p.nextToken();
        const d = (try expr.parseExpr(p)) orelse return null;
        def = OptionalIndex.fromIndex(d);
    }
    // 提升属性的属性钩子：`__construct(public $h { set => $value; })`（8.4）。仅提升
    // （promoted != 0）可带钩子，且其后不能跟默认值（钩子取代 setter 默认赋值语义）。
    var hooks: SubRange = p.emptySubRange();
    var has_hook_block = false;
    var hook_lbrace: TokenIndex = 0;
    if (promoted != 0 and p.tokTag() == .lbrace) {
        has_hook_block = true;
        hook_lbrace = p.tok_i;
        _ = p.nextToken();
        var list = try std.ArrayList(Index).initCapacity(p.gpa, 0);
        defer list.deinit(p.gpa);
        while (p.tokTag() != .rbrace and p.tokTag() != .eof) {
            const h = (try parsePropertyHook(p)) orelse {
                try p.skipToNextStmt();
                continue;
            };
            try list.append(p.gpa, h);
        }
        _ = p.eatToken(.rbrace);
        const lr = try p.addNodeList(list.items);
        hooks = .{ .start = lr.start, .end = lr.end };
    }
    const extra = try p.addExtra(ParamComponents{ .name = var_tok, .flags = flags, .promoted = promoted, .variadic = variadic, .by_ref = by_ref, .type = type_opt, .default = def, .hooks = hooks, .attrs = attrs, .has_hook_block = has_hook_block, .hook_lbrace = hook_lbrace });
    const node = (try p.addNode(.{
        .tag = .param,
        .main_token = var_tok,
        .data = .{ .extra_and_opt_node = .{ extra, def } },
    })) orelse unreachable;
    if (promoted != 0 and is_final_promoted) {
        p.node_versions.items[@intFromEnum(node)] = PhpVersion.fromComponents(8, 5);
    }
    return node;
}

pub fn parseClass(p: *Parser, attrs: SubRange) ast.ParseError!?Index {
    const flags = parseModifiers(p);
    const kw = p.nextToken();
    // 类名位只接受 T_STRING（php.y）：关键字（`class static {}`）是语法错，不产类节点。
    if (reserved.isForbiddenDeclName(p.tokTag(), p.version)) {
        p.warnAtExpected(ast.Error.Tag.expected_token, p.tok_i, .name);
        return null;
    }
    const name_tok = p.nextToken();
    var extends: OptionalIndex = .none;
    if (p.tokTag() == .kw_extends) {
        _ = p.nextToken();
        const en = (try expr.parseName(p)) orelse return null;
        extends = OptionalIndex.fromIndex(en);
    }
    var impl: SubRange = p.emptySubRange();
    if (p.tokTag() == .kw_implements) {
        _ = p.nextToken();
        var impls: std.ArrayList(Index) = .empty;
        defer impls.deinit(p.gpa);
        const im = (try expr.parseName(p)) orelse return null;
        try impls.append(p.gpa, im);
        // `class X implements Y, {` / `interface I extends J, {}`：PHP 不允许尾逗号
        // （结束定界符 `{` / `;`）
        while (p.eatListComma(false, &.{ .lbrace, .semicolon })) {
            const more = (try expr.parseName(p)) orelse return null;
            try impls.append(p.gpa, more);
        }
        const ilr = try p.addNodeList(impls.items);
        impl = .{ .start = ilr.start, .end = ilr.end };
    }
    _ = p.expectToken(.lbrace);
    var stmts = try std.ArrayList(Index).initCapacity(p.gpa, 0);
    defer stmts.deinit(p.gpa);
    while (p.tokTag() != .rbrace and p.tokTag() != .eof) {
        // parseClassMember 返回 null 表示「注释后即类体结束」（rbrace/eof），须 break
        // 收尾；其余解析失败（半途成员）才 skipToNextStmt——否则吞掉 `}` 会把类外
        // 语句并进类体（semiReserved 等类尾注释的 fixture 报错错位）。
        const m = (try parseClassMember(p)) orelse {
            if (p.tokTag() == .rbrace or p.tokTag() == .eof) break;
            try p.skipToNextStmt();
            if (p.tokTag() == .close_tag) _ = p.nextToken();
            continue;
        };
        try stmts.append(p.gpa, m);
        if (p.tokTag() == .close_tag) _ = p.nextToken();
    }
    _ = p.eatToken(.rbrace);
    const lr = try p.addNodeList(stmts.items);
    const extra = try p.addExtra(ClassComponents{
        .name = name_tok,
        .attrs = attrs,
        .extends = extends,
        .implements = impl,
        .stmts = .{ .start = lr.start, .end = lr.end },
        .flags = flags,
    });
    return (try p.addNode(.{
        .tag = .stmt_class,
        .main_token = kw,
        .data = .{ .extra_and_opt_node = .{ extra, extends } },
    })) orelse unreachable;
}

/// 解析类方法（Stmt\ClassMethod）：承载可见性 / static / abstract / final / byRef 等修饰符，
/// 与顶层函数（stmt_function）区分开，对齐 php-parser 的 `Stmt\ClassMethod`。
pub fn parseMethod(p: *Parser, attrs: SubRange, mods: PropertyMods) ast.ParseError!?Index {
    // 引擎级语义诊断（就地——修饰符事实在此即知，信息随后不可恢复）：
    // readonly 只能修饰属性（`readonly function` 非法）；abstract 与 final 互斥。
    if ((mods.flags & 1) != 0 and (mods.flags & 2) != 0) {
        // 定位在 `final` 修饰符上（php-parser 同），非 `function`
        const ft = if (mods.final_token != 0) mods.final_token else p.tok_i;
        p.warnAt(ast.Error.Tag.final_on_abstract_member, ft);
    }
    const kw = p.nextToken();
    var by_ref = false;
    if (p.tokTag() == .ampersand) {
        _ = p.nextToken();
        by_ref = true;
    }
    const name_tok = p.nextToken();
    // readonly 方法：消息含方法名（`aux` 指向方法名 token）；区间落在 readonly
    // 修饰符本身（php-parser 报 `readonly function foo()` 的 readonly 处）。
    if ((mods.flags & 8) != 0) {
        const rt = if (mods.first_mod_token != 0) mods.first_mod_token else kw;
        p.addError(.readonly_method, rt, rt, name_tok, 0);
    }
    const plr = (try parseParamList(p)) orelse return null;
    var ret: OptionalIndex = .none;
    if (p.tokTag() == .colon) {
        _ = p.nextToken();
        const rt = (try types.parseType(p)) orelse return null;
        ret = OptionalIndex.fromIndex(rt);
    }
    var body: OptionalIndex = .none;
    if (p.tokTag() == .lbrace) {
        const b = (try stmt.parseBlock(p)) orelse return null;
        body = OptionalIndex.fromIndex(b);
    } else {
        _ = p.eatToken(.semicolon);
    }
    const extra = try p.addExtra(MethodComponents{
        .name = name_tok,
        .attrs = attrs,
        .params = plr,
        .ret = ret,
        .body = body,
        .mod_start = if (mods.first_mod_token != 0) mods.first_mod_token else kw,
        .flags = mods.flags,
        .visibility = mods.visibility & 0xFF,
        .by_ref = by_ref,
    });
    return (try p.addNode(.{
        .tag = .stmt_method,
        .main_token = kw,
        .data = .{ .extra_and_opt_node = .{ extra, ret } },
    })) orelse unreachable;
}

/// 解析匿名类 `new [readonly] class(...) [extends X] [implements Y] { ... }`，复用
/// 类节点（stmt_class），名字为空。`readonly` 前缀由调用方已消费（flags 传入）；
/// 构造参数 `(args)` 在类名后、extends 前，故在此解析并随结果返回（php-parser
/// New_ 的 args 与 class 并列，归 expr_new 承载）。
pub const AnonymousClassResult = struct {
    node: Index,
    args: ListRange,
};

pub fn parseAnonymousClass(p: *Parser, attrs: SubRange, readonly_flags: u32) ast.ParseError!?AnonymousClassResult {
    const kw = p.nextToken();
    var args: ListRange = p.emptyRange();
    if (p.tokTag() == .lparen) {
        args = try expr.parseArgs(p);
    }
    var extends: OptionalIndex = .none;
    if (p.tokTag() == .kw_extends) {
        _ = p.nextToken();
        const e = (try expr.parseName(p)) orelse return null;
        extends = OptionalIndex.fromIndex(e);
    }
    var impl: SubRange = p.emptySubRange();
    if (p.tokTag() == .kw_implements) {
        _ = p.nextToken();
        var impls: std.ArrayList(Index) = .empty;
        defer impls.deinit(p.gpa);
        const im = (try expr.parseName(p)) orelse return null;
        try impls.append(p.gpa, im);
        // `class X implements Y, {` / `interface I extends J, {}`：PHP 不允许尾逗号
        // （结束定界符 `{` / `;`）
        while (p.eatListComma(false, &.{ .lbrace, .semicolon })) {
            const more = (try expr.parseName(p)) orelse return null;
            try impls.append(p.gpa, more);
        }
        const ilr = try p.addNodeList(impls.items);
        impl = .{ .start = ilr.start, .end = ilr.end };
    }
    if (p.tokTag() != .lbrace) {
        p.warn(ast.Error.Tag.expected_token);
        return null;
    }
    var stmts = try std.ArrayList(Index).initCapacity(p.gpa, 0);
    defer stmts.deinit(p.gpa);
    _ = p.nextToken();
    while (p.tokTag() != .rbrace and p.tokTag() != .eof) {
        const m = (try parseClassMember(p)) orelse {
            if (p.tokTag() == .rbrace or p.tokTag() == .eof) break;
            try p.skipToNextStmt();
            if (p.tokTag() == .close_tag) _ = p.nextToken();
            continue;
        };
        try stmts.append(p.gpa, m);
        if (p.tokTag() == .close_tag) _ = p.nextToken();
    }
    _ = p.eatToken(.rbrace);
    const lr = try p.addNodeList(stmts.items);
    const extra = try p.addExtra(ClassComponents{
        .name = 0,
        .attrs = attrs,
        .extends = extends,
        .implements = impl,
        .stmts = .{ .start = lr.start, .end = lr.end },
        .flags = readonly_flags,
    });
    const node = (try p.addNode(.{
        .tag = .stmt_class,
        .main_token = kw,
        .data = .{ .extra_and_opt_node = .{ extra, extends } },
    })) orelse unreachable;
    return .{ .node = node, .args = args };
}

/// 解析类体成员：按首 token 分流到 trait use / 方法 / 常量 / 属性。
pub fn parseClassMember(p: *Parser) ast.ParseError!?Index {
    // 类体内的注释/文档注释不建节点（注释驻 token 流，`docCommentBefore` 仍可取回），
    // 先跳过，否则 `}` 前/成员间的注释会被当作成员起始解析（如 `// my comment` 报
    // expected_variable）。对齐 php-parser 把纯注释留白、不产成员的处理。
    while (p.tokTag() == .comment or p.tokTag() == .doc_comment) {
        _ = p.nextToken();
    }
    // 注释后即类体结束：返回 null 让调用方循环收尾（吃 `}` 退出），不按成员解析。
    if (p.tokTag() == .rbrace or p.tokTag() == .eof) return null;
    var attrs = p.emptySubRange();
    if (p.tokTag() == .hash) attrs = try parseAttrGroups(p);
    const mods = parsePropertyModifiers(p);
    if (p.tokTag() == .kw_use) return stmt.parseTraitUse(p);
    if (p.tokTag() == .kw_function) return parseMethod(p, attrs, mods);
    if (p.tokTag() == .kw_const) {
        // 类常量仅接受可见性与 PHP 8.5 的 final；abstract/static/readonly 修饰符
        // 非法（static const / abstract const / readonly const）。修饰符 token 已被
        // 收集循环消费、随 AST 不保留，就地诊断（信息不可恢复）。消息含修饰符名，
        // 由 `first_mod_token` 提供。
        if ((mods.flags & (1 | 4 | 8)) != 0) {
            // 区间即该修饰符本身（php-parser 报在修饰符上，不含 `const`）
            p.addError(.invalid_const_modifier, mods.first_mod_token, mods.first_mod_token, mods.first_mod_token, 0);
        }
        return parseClassConst(p, attrs, mods.visibility);
    }
    return parseProperty(p, attrs, mods);
}

/// 收集类/方法修饰符（abstract/final/static/readonly），累积为位标志返回。
fn parseModifiers(p: *Parser) u32 {
    var flags: u32 = 0;
    while (true) {
        switch (p.tokTag()) {
            .kw_abstract => {
                flags |= 1;
                _ = p.nextToken();
            },
            .kw_final => {
                flags |= 2;
                _ = p.nextToken();
            },
            .kw_static => {
                flags |= 4;
                _ = p.nextToken();
            },
            .kw_readonly => {
                flags |= 8;
                _ = p.nextToken();
            },
            .kw_public, .kw_protected, .kw_private, .kw_var, .kw_const => _ = p.nextToken(),
            else => return flags,
        }
    }
}

/// `(` 之后是否为 `set`（非对称可见性 `public(set)`）。不消费 token：用于把
/// `public (A&B)|C $p;` 的类型括号与 `public(set) $p;` 的 set 括号区分开。
fn isSetVisibility(p: *Parser) bool {
    if (p.tokTag() != .lparen) return false;
    const next = p.tok_i + 1;
    if (next >= p.tokens.len) return false;
    if (p.tokens.items(.tag)[next] != .identifier) return false;
    const s = p.tokens.items(.start)[next];
    const e = p.tokens.items(.end)[next];
    return std.mem.eql(u8, p.source[s..e], "set");
}

/// 收集属性修饰符与可见性，支持 PHP 8.4 非对称可见性 `public(private)`。
///
/// 就地判定「重复修饰符」（`public public`、`static static $a` 等）：第二次
/// 起同一修饰符只吃 token 不再次置位，若此处不报，事实随 token 消费永久丢失，
/// 事后无法从树恢复（故归 parse 期，见 `doc/special.md` P6 的语义诊断分层）。
fn parsePropertyModifiers(p: *Parser) PropertyMods {
    var res = PropertyMods{ .flags = 0, .visibility = 0 };
    res.visibility |= 3 << 8;
    var vis_count: u8 = 0;
    while (true) {
        switch (p.tokTag()) {
            .kw_abstract => {
                if (!res.has_modifier) res.first_mod_token = p.tok_i;
                res.has_modifier = true;
                if ((res.flags & 1) != 0) p.warnAt(ast.Error.Tag.multiple_abstract_modifiers, p.tok_i) else res.flags |= 1;
                _ = p.nextToken();
            },
            .kw_final => {
                if (!res.has_modifier) res.first_mod_token = p.tok_i;
                res.has_modifier = true;
                if (res.final_token == 0) res.final_token = p.tok_i;
                if ((res.flags & 2) != 0) p.warnAt(ast.Error.Tag.multiple_final_modifiers, p.tok_i) else res.flags |= 2;
                _ = p.nextToken();
            },
            .kw_static => {
                if (!res.has_modifier) res.first_mod_token = p.tok_i;
                res.has_modifier = true;
                if ((res.flags & 4) != 0) p.warnAt(ast.Error.Tag.multiple_static_modifiers, p.tok_i) else res.flags |= 4;
                _ = p.nextToken();
            },
            .kw_readonly => {
                if (!res.has_modifier) res.first_mod_token = p.tok_i;
                res.has_modifier = true;
                if ((res.flags & 8) != 0) p.warnAt(ast.Error.Tag.multiple_readonly_modifiers, p.tok_i) else res.flags |= 8;
                _ = p.nextToken();
            },
            .kw_public, .kw_protected, .kw_private, .kw_var => {
                if (!res.has_modifier) res.first_mod_token = p.tok_i;
                res.has_modifier = true;
                const v: u8 = switch (p.tokTag()) {
                    .kw_public => 0,
                    .kw_protected => 1,
                    .kw_private => 2,
                    .kw_var => 0,
                    else => 0,
                };
                const vtok = p.tok_i;
                _ = p.nextToken();
                // `vis(set)`（8.4 非对称可见性）：仅当 `(` 后确为 `set` 才消费该括号；
                // 否则这个 `(` 属类型位（DNF 类型 `(A&B)|C` 的起始）——按普通可见性收下，
                // 游标留在 `(` 交类型解析。**不得回卷到可见性 token 本身**：修饰符收集已
                // 结束，上层会再次见到 `public` 并按「缺少属性名」报错（DNF 属性被误拒）。
                if (isSetVisibility(p)) {
                    const lp = p.tok_i;
                    _ = p.nextToken(); // `(`
                    _ = p.nextToken(); // `set`
                    const rp = p.eatToken(.rparen) orelse lp;
                    if (res.set_seen) {
                        // set 侧已出现过：`private(set) private(set)` /
                        // `private(set) public(set)` 为重复修饰符，区间覆盖
                        // 整个重复的修饰符（含 `(set)`）。
                        p.addError(ast.Error.Tag.multiple_access_modifiers, vtok, rp, vtok, 0);
                    } else {
                        res.set_seen = true;
                        // 高字节写入 set 侧可见性（默认 3 = 未指定），
                        // 使「无 set/有 set」可区分（set_vis != 3 即非对称）。
                        res.visibility = (res.visibility & 0xFF) | (@as(u32, v) << 8);
                    }
                } else if (vis_count == 0) {
                    res.visibility |= v;
                } else {
                    // 第二及以后的可见性 token 且后无 `(set)`：重复可见性。
                    p.warnAt(ast.Error.Tag.multiple_access_modifiers, vtok);
                }
                vis_count += 1;
            },
            else => return res,
        }
    }
}

/// 解析属性声明：`Type $name = default;`；或带 `get`/`set` 钩子块的形态。
pub fn parseProperty(p: *Parser, attrs: SubRange, mods: PropertyMods) ast.ParseError!?Index {
    var type_opt: OptionalIndex = .none;
    if (types.isTypeStart(p)) {
        const ty = (try types.parseType(p)) orelse return null;
        type_opt = OptionalIndex.fromIndex(ty);
        // PHP 8.5：属性声明必须有可见性或修饰符（`var` 亦等价 public）——无修饰符
        // typed property `Foo $a;` 已移除（recovery[19]：拼错可见性的 `publi $foo;`
        // 在此报错并整条丢弃恢复，php-parser 同——语法错、无 Property 节点）。
        // 版本编码 major*10000+minor*100：8.5 = 80500。报点落在类型起始 token
        // （`publi`），php-parser 报 unexpected T_STRING 同此。
        // 8.4 及以下该形态合法。
        if (p.version.id >= 80500 and !mods.has_modifier) {
            const ty_tok = p.nodeMainToken(ty);
            p.warnAt(ast.Error.Tag.expected_token, ty_tok);
            return null;
        }
    }
    // 属性项列表：`public $a = 'b', $c = 'd';`（每项 property_item：名字 + 可选初值）。
    // 尾随属性钩子 `{ get => ...; }` 只可能出现在单属性声明后（多属性带钩子是语法错误，
    // 交由错误恢复兜底，不在此特判）。
    var items = try std.ArrayList(Index).initCapacity(p.gpa, 0);
    defer items.deinit(p.gpa);
    var first_name: TokenIndex = 0;
    var has_item = false;
    while (true) {
        if (p.tokTag() != .variable) {
            p.warn(ast.Error.Tag.expected_variable);
            return null;
        }
        const name_tok = p.nextToken();
        if (!has_item) {
            first_name = name_tok;
            has_item = true;
        }
        var def: OptionalIndex = .none;
        if (p.tokTag() == .equals) {
            _ = p.nextToken();
            const d = (try expr.parseExpr(p)) orelse return null;
            def = OptionalIndex.fromIndex(d);
        }
        const item = (try p.addNode(.{
            .tag = .property_item,
            .main_token = name_tok,
            .data = .{ .opt_node_and_token = .{ def, name_tok } },
        })) orelse unreachable;
        try items.append(p.gpa, item);
        // `public $x, ;`：PHP 不允许尾逗号（结束定界符 `;` 或钩子块 `{`）
        if (p.eatListComma(false, &.{ .semicolon, .lbrace })) continue;
        break;
    }
    var hooks: SubRange = p.emptySubRange();
    var has_hook_block = false;
    var hook_lbrace: TokenIndex = 0;
    var semi: TokenIndex = first_name;
    if (p.tokTag() == .lbrace) {
        has_hook_block = true;
        hook_lbrace = p.tok_i;
        _ = p.nextToken();
        var list = try std.ArrayList(Index).initCapacity(p.gpa, 0);
        defer list.deinit(p.gpa);
        while (p.tokTag() != .rbrace and p.tokTag() != .eof) {
            const h = (try parsePropertyHook(p)) orelse {
                try p.skipToNextStmt();
                if (p.tokTag() == .close_tag) _ = p.nextToken();
                continue;
            };
            try list.append(p.gpa, h);
        }
        semi = (p.eatToken(.rbrace)) orelse first_name;
        const lr = try p.addNodeList(list.items);
        hooks = .{ .start = lr.start, .end = lr.end };
        // 带钩子属性以 `}` 收尾：PHP 不要求其后再加分号（php.y 的 hook 属性形态
        // 声明结束即块闭合），故此处不检查分号。
    } else {
        // 属性声明以 `;` 收尾（PHP 硬性：recovery[25] 的 `private $foo` 后直接下个
        // 成员或类 `}` 均缺分号，须报）。缺分号时 token 留给类体循环处理（下个成员
        // 或 `}` 收尾），错误恢复。
        p.skipComments();
        const sc = p.eatToken(.semicolon);
        if (sc) |x| {
            semi = x;
        } else if (p.tokTag() != .close_tag) {
            // 属性声明缺分号：php-parser 期望 `';' or '{'`——属性可带钩子块
            // （`public $x { set ... }`），故 `{` 亦在期望集内（recovery[25] 首条）。
            p.addErrorExpected(ast.Error.Tag.expected_semi, .semi_or_lbrace, p.tok_i, p.tok_i, p.tok_i, 0);
        }
    }
    const lr2 = try p.addNodeList(items.items);
    const extra = try p.addExtra(PropertyComponents{
        .type = type_opt,
        .flags = mods.flags,
        .visibility = mods.visibility,
        .props = .{ .start = lr2.start, .end = lr2.end },
        .hooks = hooks,
        .attrs = attrs,
        .semi = semi,
        .has_hook_block = has_hook_block,
        .hook_lbrace = hook_lbrace,
    });
    const node = (try p.addNode(.{
        .tag = .stmt_property,
        .main_token = first_name,
        .data = .{ .extra_and_opt_node = .{ extra, type_opt } },
    })) orelse unreachable;
    // 非对称可见性：非静态为 8.4，静态为 8.5（set_vis == 3 表示未指定非对称）
    const set_vis = (mods.visibility >> 8) & 0xFF;
    if (set_vis != 3) {
        const ver: u16 = if ((mods.flags & 4) != 0) 5 else 4;
        p.node_versions.items[@intFromEnum(node)] = PhpVersion.fromComponents(8, ver);
    }
    return node;
}

/// 解析属性访问钩子 `get`/`set`，分表达式（`=> expr;`）与语句块两种形态。
pub fn parsePropertyHook(p: *Parser) ast.ParseError!?Index {
    var attrs = p.emptySubRange();
    if (p.tokTag() == .hash) attrs = try parseAttrGroups(p);
    // 钩子前缀：final/abstract 修饰符与 `&`（引用 getter）。循环吸收不设顺序约束。
    // 其余修饰符（public/protected/private/static/readonly）在钩子上非法——逐条就地
    // 诊断（消息含修饰符名）；可见性重复另报 Multiple access type modifiers。
    var flags: u32 = 0;
    var vis_count: u8 = 0;
    while (true) {
        switch (p.tokTag()) {
            .kw_final => {
                flags |= 4;
                _ = p.nextToken();
            },
            .ampersand => {
                flags |= 16;
                _ = p.nextToken();
            },
            .kw_abstract => {
                // abstract 在钩子上非法（php-parser：`Cannot use the abstract
                // modifier on a property hook`）——仅 final 与 & 合法。
                const mt = p.tok_i;
                _ = p.nextToken();
                p.addError(.hook_modifier, mt, mt, mt, 0);
            },
            .kw_public, .kw_protected, .kw_private => {
                // 钩子上不允许可见性修饰（php-parser：`Cannot use the X modifier on
                // a property hook`）；连续两个可见性另报重复（与属性同规则）。
                const mt = p.tok_i;
                _ = p.nextToken();
                if (p.tokTag() == .lparen) {
                    // `public(set)` 非对称形态在钩子上同样非法，但属可见性重复语义
                    _ = p.nextToken();
                    if (p.isSoftKw("set")) _ = p.nextToken() else p.warn(ast.Error.Tag.expected_token);
                    _ = p.eatToken(.rparen);
                }
                if (vis_count > 0) p.warnAt(ast.Error.Tag.multiple_access_modifiers, mt);
                // 钩子上任何可见性都是非法修饰符（php-parser 对第二个 public 同时报
                // `hook modifier` 与 `Multiple access` 两条：`public public get;`）
                p.addError(.hook_modifier, mt, mt, mt, 0);
                vis_count += 1;
            },
            .kw_static, .kw_readonly => {
                const mt = p.tok_i;
                _ = p.nextToken();
                p.addError(.hook_modifier, mt, mt, mt, 0);
            },
            else => break,
        }
    }
    if (p.tokTag() != .identifier) {
        p.warn(ast.Error.Tag.expected_token);
        return null;
    }
    const is_set = p.isSoftKw("set");
    const is_get = p.isSoftKw("get");
    if (!is_set and !is_get) {
        // 未知钩子名（`FOO => bar;`）：php-parser 报 `Unknown hook "X", expected
        // "get" or "set"` 并**保留**该钩子节点（错误不丢结构，收集式模型同旨）。
        // 保留节点也使其计入钩子列表，`Property hook list cannot be empty` 不会误报。
        const mt = p.tok_i;
        _ = p.nextToken();
        p.addError(.unknown_hook, mt, mt, mt, 0);
        const extra = try p.addExtra(PropertyHookComponents{
            .name = mt,
            .flags = 32, // 未知钩子标记
            .params = p.emptySubRange(),
            .attrs = attrs,
            .has_param_list = false,
            .lparen = 0,
        });
        // 跳过其体到下一个钩子边界
        while (p.tokTag() != .semicolon and p.tokTag() != .rbrace and p.tokTag() != .eof) {
            _ = p.nextToken();
        }
        _ = p.eatToken(.semicolon);
        return (try p.addNode(.{
            .tag = .property_hook,
            .main_token = mt,
            .data = .{ .extra_and_opt_node = .{ extra, .none } },
        })) orelse unreachable;
    }
    const name_tok = p.nextToken();
    if (is_set) flags |= 1;
    var params: SubRange = p.emptySubRange();
    var has_param_list = false;
    var lparen: TokenIndex = 0;
    if (p.tokTag() == .lparen) {
        has_param_list = true;
        lparen = p.tok_i;
        params = (try parseParamList(p)) orelse return null;
    }
    // 三种体：`=> expr` 表达式、`{ ... }` 块、无体抽象声明 `set;` / `&get;`。
    var body: OptionalIndex = .none;
    if (p.tokTag() == .double_arrow) {
        _ = p.nextToken();
        const e = (try expr.parseExpr(p)) orelse return null;
        body = OptionalIndex.fromIndex(e);
        _ = p.eatToken(.semicolon);
    } else if (p.tokTag() == .lbrace) {
        const b = (try stmt.parseBlock(p)) orelse return null;
        body = OptionalIndex.fromIndex(b);
    } else {
        _ = p.eatToken(.semicolon); // 抽象钩子：无体，分号收尾
    }
    const extra = try p.addExtra(PropertyHookComponents{
        .name = name_tok,
        .flags = flags,
        .params = params,
        .attrs = attrs,
        .has_param_list = has_param_list,
        .lparen = lparen,
    });
    return (try p.addNode(.{
        .tag = .property_hook,
        .main_token = name_tok,
        .data = .{ .extra_and_opt_node = .{ extra, body } },
    })) orelse unreachable;
}

/// 解析类常量（Stmt\ClassConst）：`[可见性] const NAME[: type] = value;`，支持 PHP 8.3 类型。
/// 与属性节点（stmt_property）区分，对齐 php-parser 的 `Stmt\ClassConst`。
/// `const` 之后是否为 **typed** class const（`const <type> NAME = ...`）的有界前瞻。
///
/// 只读 token、不改游标：从当前位置扫到第一个 `=`（或 `;` / `,` / eof）为止，区间内
/// 出现两个及以上名字 token（类型名 + 常量名）才算带类型；无类型形态在第一个名字后
/// 紧跟 `=`，只会数到一个。扫描有上限，畸形输入不会扫穿全文。
///
/// 判据只看 token 形态，不靠 parseType 的成败——后者对「名字」输入必然成功（把常量名
/// 当成单名类型吃掉），那正是原「试探后回卷」方案的歧义来源。
fn looksLikeTypedClassConst(p: *Parser) bool {
    const tags = p.tokens.items(.tag);
    var names: usize = 0;
    var i = p.tok_i;
    const stop = @min(i + 64, tags.len);
    while (i < stop) : (i += 1) {
        switch (tags[i]) {
            .eof, .equals, .semicolon, .comma => break,
            .identifier => names += 1,
            else => if (tags[i].isKeyword()) {
                names += 1;
            },
        }
    }
    return names >= 2;
}

pub fn parseClassConst(p: *Parser, attrs: SubRange, visibility: u32) ast.ParseError!?Index {
    const kw = p.nextToken();
    var type_opt: OptionalIndex = .none;
    // PHP 8.3 typed class const：`const int X = 1`（类型在名字前），与无类型形态
    // （`const A = 1`）由前瞻区分（见 `looksLikeTypedClassConst`）：确认类型位之后还有
    // 常量名才走类型解析，不做「先解析、不符再回卷」。
    if (types.isTypeStart(p) and looksLikeTypedClassConst(p)) {
        if (try types.parseType(p)) |ty| type_opt = OptionalIndex.fromIndex(ty);
    }
    // 常量列表：`const NAME = value, NAME2 = value2;`（每项 const_decl，与顶层 const 同构）。
    var decls = try std.ArrayList(Index).initCapacity(p.gpa, 0);
    defer decls.deinit(p.gpa);
    while (true) {
        // 常量名：标识符或关键字均可（semiReserved：`const TRAIT = 3`）。
        const name_tok = p.nextToken();
        _ = p.eatToken(.equals) orelse {
            p.warn(ast.Error.Tag.expected_token);
            return null;
        };
        const value = (try expr.parseExpr(p)) orelse return null;
        const item = (try p.addNode(.{
            .tag = .const_decl,
            .main_token = name_tok,
            .data = .{ .node_and_token = .{ value, name_tok } },
        })) orelse unreachable;
        try decls.append(p.gpa, item);
        // `const A = 42, ;`（类常量）：PHP 不允许尾逗号（结束定界符 `;`）
        if (p.eatListComma(false, &.{.semicolon})) continue;
        break;
    }
    p.skipComments();
    const semi = (p.eatToken(.semicolon)) orelse blk: {
        // 类常量以 `;` 收尾（PHP 硬性；recovery[25]：`const X = 1` 后直接类 `}` 缺分号，
        // 期望集合只有 `';'`——常量声明不接块）。
        if (p.tokTag() != .close_tag)
            p.addErrorExpected(ast.Error.Tag.expected_semi, .semi, p.tok_i, p.tok_i, p.tok_i, 0);
        break :blk kw;
    };
    const lr = try p.addNodeList(decls.items);
    const extra = try p.addExtra(ClassConstComponents{
        .type = type_opt,
        .flags = visibility,
        .decls = .{ .start = lr.start, .end = lr.end },
        .semi = semi,
        .attrs = attrs,
    });
    const node = (try p.addNode(.{
        .tag = .stmt_class_const,
        .main_token = kw,
        .data = .{ .extra_and_opt_node = .{ extra, type_opt } },
    })) orelse unreachable;
    // typed class const（`const int X = 1`）为 8.3 引入；无类型形态是基础语法，同 tag
    // 承载两版本，故在解析点标注而非 `tagVersion` 表。
    if (type_opt != .none) {
        p.node_versions.items[@intFromEnum(node)] = PhpVersion.fromComponents(8, 3);
    }
    // 常量上的注解（含 #[\Deprecated]）为 8.5 引入（晚于 typed，覆盖上面的标注）
    if (attrs.start != attrs.end) {
        p.node_versions.items[@intFromEnum(node)] = PhpVersion.fromComponents(8, 5);
    }
    return node;
}

/// 解析 interface / trait / enum 声明；enum 体内部特判为枚举项，其余走类成员。
pub fn parseTypeDecl(p: *Parser, comptime tag: Node.Tag, attrs: SubRange) ast.ParseError!?Index {
    const kw = p.nextToken();
    // 名字位只接受 T_STRING（同 parseClass）：`interface static {}` 是语法错。
    if (reserved.isForbiddenDeclName(p.tokTag(), p.version)) {
        p.warnAtExpected(ast.Error.Tag.expected_token, p.tok_i, .name);
        return null;
    }
    const name_tok = p.nextToken();
    var backing: OptionalIndex = .none;
    if (tag == .stmt_enum and p.tokTag() == .colon) {
        _ = p.nextToken();
        const bt = (try types.parseType(p)) orelse return null;
        backing = OptionalIndex.fromIndex(bt);
    }
    // interface → extends 列表；enum → implements 列表；trait 两者皆无。
    var ext_impl: SubRange = p.emptySubRange();
    if (tag == .stmt_interface or tag == .stmt_enum) {
        var names: std.ArrayList(Index) = .empty;
        defer names.deinit(p.gpa);
        while (p.tokTag() == .kw_extends or p.tokTag() == .kw_implements) {
            _ = p.nextToken();
            const n = (try expr.parseName(p)) orelse return null;
            try names.append(p.gpa, n);
            // `interface I extends J, {}`：列表不许尾逗号（结束定界符 `{`），报
            // trailing_comma（recovery[17] 的 16:22）。
            while (p.eatListComma(false, &.{.lbrace})) {
                const more = (try expr.parseName(p)) orelse return null;
                try names.append(p.gpa, more);
            }
        }
        if (names.items.len > 0) {
            const nr = try p.addNodeList(names.items);
            ext_impl = .{ .start = nr.start, .end = nr.end };
        }
    }
    _ = p.expectToken(.lbrace);
    var stmts = try std.ArrayList(Index).initCapacity(p.gpa, 0);
    defer stmts.deinit(p.gpa);
    if (tag == .stmt_enum) {
        while (p.tokTag() != .rbrace and p.tokTag() != .eof) {
            const c = (try parseEnumCase(p)) orelse {
                try p.skipToNextStmt();
                if (p.tokTag() == .close_tag) _ = p.nextToken();
                continue;
            };
            try stmts.append(p.gpa, c);
            if (p.tokTag() == .close_tag) _ = p.nextToken();
        }
    } else {
        while (p.tokTag() != .rbrace and p.tokTag() != .eof) {
            const m = (try parseClassMember(p)) orelse {
                if (p.tokTag() == .rbrace or p.tokTag() == .eof) break;
                try p.skipToNextStmt();
                if (p.tokTag() == .close_tag) _ = p.nextToken();
                continue;
            };
            try stmts.append(p.gpa, m);
            if (p.tokTag() == .close_tag) _ = p.nextToken();
        }
    }
    _ = p.eatToken(.rbrace);
    const lr = try p.addNodeList(stmts.items);
    const extra = try p.addExtra(TypeDeclComponents{
        .name = name_tok,
        .attrs = attrs,
        .backing = backing,
        .ext_impl = ext_impl,
        .stmts = .{ .start = lr.start, .end = lr.end },
        .flags = 0,
    });
    return (try p.addNode(.{
        .tag = tag,
        .main_token = kw,
        .data = .{ .extra_and_opt_node = .{ extra, backing } },
    })) orelse unreachable;
}

/// 解析枚举项 `case NAME = value;`，逗号可连续分隔多个枚举项。
fn parseEnumCase(p: *Parser) ast.ParseError!?Index {
    var attrs = p.emptySubRange();
    if (p.tokTag() == .hash) attrs = try parseAttrGroups(p);
    const kw = p.nextToken();
    const name_tok = p.nextToken();
    var value: OptionalIndex = .none;
    if (p.tokTag() == .equals) {
        _ = p.nextToken();
        const v = (try expr.parseExpr(p)) orelse return null;
        value = OptionalIndex.fromIndex(v);
    }
    if (p.tokTag() == .comma) _ = p.nextToken();
    const semi = (p.eatToken(.semicolon)) orelse kw;
    const extra = try p.addExtra(CaseComponents{
        .name = name_tok,
        .value = value,
        .attrs = attrs,
        .semi = semi,
    });
    return (try p.addNode(.{
        .tag = .stmt_case,
        .main_token = kw,
        .data = .{ .extra_and_opt_node = .{ extra, value } },
    })) orelse unreachable;
}

/// 解析属性组（可连续多个 `#[...]`），每组打包为一个 attr_group 节点。
pub fn parseAttrGroups(p: *Parser) ast.ParseError!SubRange {
    var groups = try std.ArrayList(Index).initCapacity(p.gpa, 0);
    defer groups.deinit(p.gpa);
    while (p.tokTag() == .hash) {
        const hash_tok = p.nextToken();
        _ = p.expectToken(.lbracket);
        var attrs = try std.ArrayList(Index).initCapacity(p.gpa, 0);
        defer attrs.deinit(p.gpa);
        while (p.tokTag() != .rbracket and p.tokTag() != .eof) {
            const name = (try expr.parseName(p)) orelse {
                const e: ExtraIndex = @enumFromInt(p.extra_data.items.len);
                return .{ .start = e, .end = e };
            };
            var args: ListRange = p.emptyRange();
            if (p.tokTag() == .lparen) {
                args = try expr.parseArgs(p);
            }
            const extra = try p.addExtra(AttributeComponents{ .name = name, .args = .{ .start = args.start, .end = args.end } });
            const attr = (try p.addNode(.{
                .tag = .attribute,
                .main_token = p.nodeMainToken(name),
                .data = .{ .extra_and_node = .{ extra, name } },
            })) orelse unreachable;
            try attrs.append(p.gpa, attr);
            if (p.tokTag() == .comma) _ = p.nextToken();
        }
        _ = p.eatToken(.rbracket);
        // 把本组 `#[...]` 打包成一个 `attr_group` 节点（承载其属性列表）。
        const lr = try p.addNodeList(attrs.items);
        const group = (try p.addNode(.{
            .tag = .attr_group,
            .main_token = hash_tok,
            .data = .{ .extra_range = .{ .start = lr.start, .end = lr.end } },
        })) orelse unreachable;
        try groups.append(p.gpa, group);
    }
    if (groups.items.len == 0) {
        const e: ExtraIndex = @enumFromInt(p.extra_data.items.len);
        return .{ .start = e, .end = e };
    }
    const lr = try p.addNodeList(groups.items);
    return .{ .start = lr.start, .end = lr.end };
}

/// 解析 `( ... )` 参数列表，返回参数节点的区间（SubRange）。
pub fn parseParamList(p: *Parser) ast.ParseError!?SubRange {
    _ = p.expectToken(.lparen);
    var params = try std.ArrayList(Index).initCapacity(p.gpa, 0);
    defer params.deinit(p.gpa);
    while (p.tokTag() != .rparen and p.tokTag() != .eof) {
        // 参数间的注释/文档注释不建节点（typeVersions 等 fixture 的参数行尾有
        // `// PHP 7.0` 这类注解），跳过——否则被当参数起始报 expected_variable。
        while (p.tokTag() == .comment or p.tokTag() == .doc_comment) {
            _ = p.nextToken();
        }
        if (p.tokTag() == .rparen or p.tokTag() == .eof) break;
        const pr = (try parseParam(p)) orelse {
            // 单个参数解析失败（如缺变量名 `function foo(Type)`）：错误已在
            // parseParam 内报；跳过到 `,`/`)` 继续解析其余参数与整个声明——
            // 放弃整个函数会让调用方 skipToNextStmt 吞掉后续语句（漏报其错误）。
            while (p.tokTag() != .comma and p.tokTag() != .rparen and p.tokTag() != .eof) {
                _ = p.nextToken();
            }
            if (p.tokTag() == .comma) {
                _ = p.nextToken();
                continue;
            }
            break;
        };
        try params.append(p.gpa, pr);
        if (p.tokTag() == .comma) _ = p.nextToken();
    }
    _ = p.expectToken(.rparen);
    const lr = try p.addNodeList(params.items);
    return .{ .start = lr.start, .end = lr.end };
}

// ===========================================================================
// 测试：声明（函数 / 类 / 接口 / trait / 枚举 / 成员 / 参数）
// ===========================================================================

test "decl :: 参数缺变量 :: 每处缺名参数报一条，后续声明不被吞" {
    const gpa = std.testing.allocator;
    // 参数缺变量（`function foo(Type)` 等）：每处报 expected_variable；参数错误
    // 恢复后后续声明（class Bar 及其方法）仍被解析，不因首错被吞掉。
    var t = try ast.Ast.parse(gpa,
        \\<?php
        \\function foo(Type) {}
        \\function foo(Type1 $foo, Type2) {}
        \\class Bar {
        \\    function foo(Baz)
        \\}
    , testing.v85);
    defer t.deinit(gpa);
    // foo(Type) 的 Type、foo(Type1 $foo, Type2) 的 Type2、Bar::foo(Baz) 的 Baz
    // 三处缺变量名
    try std.testing.expectEqual(@as(usize, 3), testing.countError(&t, .expected_variable));
    try testing.expectTagCounts(t, .{ .stmt_class = 1, .stmt_method = 1 });
}

test "decl :: 属性/类常量缺收尾分号 :: 报 expected_semi（recovery[25] 形态）" {
    const gpa = std.testing.allocator;

    // 类成员后直接下个成员
    var a = try ast.Ast.parse(gpa, "<?php class B { private $foo public $bar }", testing.v85);
    defer a.deinit(gpa);
    try std.testing.expect(testing.countError(&a, .expected_semi) >= 1);

    // 类常量后直接类尾 `}`
    var b = try ast.Ast.parse(gpa, "<?php class B { const X = 1 }", testing.v85);
    defer b.deinit(gpa);
    try std.testing.expect(testing.countError(&b, .expected_semi) >= 1);

    // 合法写法无诊断（含带钩子属性以 `}` 收尾、其后无需分号）
    var c = try ast.Ast.parse(gpa, "<?php class B { private $foo; const X = 1; public $p { get { return 1; } } }", testing.v85);
    defer c.deinit(gpa);
    try testing.expectNoErrors(c);
}

test "decl :: PHP 8.5 :: 无修饰符 typed property 被拒绝（recovery[19] 形态）" {
    const gpa = std.testing.allocator;
    // 拼错可见性 → 无修饰符的 typed property：8.5 起非法并整条丢弃
    var t = try ast.Ast.parse(gpa, "<?php class Foo { public $bar1; publi $foo; public $bar; }", testing.v85);
    defer t.deinit(gpa);
    try std.testing.expect(t.errors.len > 0);

    // 8.4 及以下该形态合法（无修饰符 typed property 仍允许）
    var old = try ast.Ast.parse(gpa, "<?php class Foo { publi $foo; }", testing.v84);
    defer old.deinit(gpa);
    try testing.expectNoErrors(old);
}

test "decl :: 顶层函数 :: 参数与返回值成节点" {
    const gpa = std.testing.allocator;
    var tree = try ast.Ast.parse(gpa, "<?php function foo($a) { return $a; }", testing.v84);
    defer tree.deinit(gpa);
    try testing.expectNoErrors(tree);
    try testing.expectTagCounts(tree, .{ .stmt_function = 1, .param = 1 });
    try std.testing.expectEqual(@as(usize, 1), tree.rootStmts().len);
    try std.testing.expectEqual(.stmt_function, tree.nodeTag(tree.rootStmts()[0]));
}

test "decl :: 函数 :: 引用返回 function &foo 与 by-ref 参数 &...$x" {
    const gpa = std.testing.allocator;
    var tree = try ast.Ast.parse(gpa,
        \\<?php
        \\function &ref1($a) { return $a; }
        \\function ref2(&$a, Type &...$rest) { }
    , testing.v84);
    defer tree.deinit(gpa);
    try testing.expectNoErrors(tree);
    try testing.expectTagCounts(tree, .{ .stmt_function = 2, .param = 3 });
}

test "decl :: A3 G5 声明族回归 :: 多属性/typed const/promotion 钩子/表达式位属性组/匿名类" {
    const gpa = std.testing.allocator;
    var tree = try ast.Ast.parse(gpa,
        \\<?php
        \\class A extends B implements C, D {
        \\    public $a = 'b', $c = 'd';
        \\    const int TYPED = 1, TRAIT = 3, FINAL = 4;
        \\    use TraitA, TraitB {
        \\        TraitA::catch insteadof namespace\TraitB;
        \\        TraitB::throw as protected public;
        \\        A::
        \\            // comment
        \\        catch insteadof B;
        \\    }
        \\}
        \\class P {
        \\    public function __construct(
        \\        public float $x = 0.0,
        \\        public $h { set => $value; },
        \\        public $g = 1 { get => 2; },
        \\        final $i,
        \\    ) {}
        \\}
        \\$c = #[A1] function () {};
        \\$d = #[A2] static fn() => 0;
        \\$e = new #[A3] class(1) extends B {};
    , testing.v85);
    defer tree.deinit(gpa);
    try testing.expectNoErrors(tree);
    try testing.expectTagCounts(tree, .{
        .stmt_class = 3,
        .property_item = 2, // public $a, $c
        .stmt_class_const = 1,
        .const_decl = 3, // TYPED/TRAIT/FINAL
        .stmt_trait_use = 1,
        .trait_use_adaptation_precedence = 2, // namespace\TraitB + 跨行 B
        .trait_use_adaptation_alias = 1,
        .expr_closure = 1,
        .expr_arrow_function = 1,
        .attr_group = 3, // A1 A2 A3
    });
}

test "decl :: 声明名位关键字 :: 语法错且不产声明节点（readonly 版本敏感）" {
    const gpa = std.testing.allocator;
    // `class static {}` / `interface static {}`：名字位只接受 T_STRING，关键字即语法错
    var a = try ast.Ast.parse(gpa, "<?php class static {}", testing.v84);
    defer a.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 1), testing.countError(&a, .expected_token));
    try testing.expectTagCounts(a, .{ .stmt_class = 0 });

    var b = try ast.Ast.parse(gpa, "<?php interface static {}", testing.v84);
    defer b.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 1), testing.countError(&b, .expected_token));
    try testing.expectTagCounts(b, .{ .stmt_interface = 0 });

    // `class ReadOnly {}`：大小写不敏感关键字，8.0 起语法错、7.4 合法
    var c = try ast.Ast.parse(gpa, "<?php class ReadOnly {}", testing.v84);
    defer c.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 1), testing.countError(&c, .expected_token));
    try testing.expectTagCounts(c, .{ .stmt_class = 0 });

    var d = try ast.Ast.parse(gpa, "<?php class ReadOnly {}", testing.v74);
    defer d.deinit(gpa);
    try testing.expectNoErrors(d);
    try testing.expectTagCounts(d, .{ .stmt_class = 1 });

    // `use C as static;`：别名位同规则，整条 use 不产节点
    var e = try ast.Ast.parse(gpa, "<?php use C as static;", testing.v84);
    defer e.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 1), testing.countError(&e, .expected_token));

    // 半保留字（`self` 为 identifier）不在此列：仍产节点并交语义层报保留名
    var f = try ast.Ast.parse(gpa, "<?php class self {}", testing.v84);
    defer f.deinit(gpa);
    try testing.expectNoErrors(f);
    try testing.expectTagCounts(f, .{ .stmt_class = 1 });
}

test "decl :: 类 :: 继承与方法分别成节点" {
    const gpa = std.testing.allocator;
    var tree = try ast.Ast.parse(gpa,
        \\<?php
        \\class Foo extends Bar {
        \\    public function baz($x) { return $x; }
        \\}
    , testing.v84);
    defer tree.deinit(gpa);
    try testing.expectNoErrors(tree);
    try testing.expectTagCounts(tree, .{ .stmt_class = 1, .stmt_method = 1 });
}

test "decl :: 类方法 :: 与顶层函数区分（stmt_method 非 stmt_function）" {
    const gpa = std.testing.allocator;
    var tree = try ast.Ast.parse(gpa,
        \\<?php
        \\class C {
        \\    public static function f(): int { return 1; }
        \\}
    , testing.v84);
    defer tree.deinit(gpa);
    try testing.expectNoErrors(tree);
    try testing.expectTagCounts(tree, .{ .stmt_method = 1, .stmt_function = 0 });
}

test "decl :: 枚举 :: backing 与 case 成节点" {
    const gpa = std.testing.allocator;
    var tree = try ast.Ast.parse(gpa,
        \\<?php
        \\enum Suit: string {
        \\    case Hearts;
        \\    case Clubs = 'c';
        \\}
    , testing.v84);
    defer tree.deinit(gpa);
    try testing.expectNoErrors(tree);
    try testing.expectTagCounts(tree, .{ .stmt_enum = 1, .stmt_case = 2 });
}

test "decl :: 接口与 trait :: 分别成节点" {
    const gpa = std.testing.allocator;
    var tree = try ast.Ast.parse(gpa,
        \\<?php
        \\interface Shape {
        \\    public function area(): float;
        \\}
        \\trait Logger {
        \\    public function log($m) { echo $m; }
        \\}
    , testing.v84);
    defer tree.deinit(gpa);
    try testing.expectNoErrors(tree);
    try testing.expectTagCounts(tree, .{
        .stmt_interface = 1,
        .stmt_trait = 1,
        .stmt_method = 2,
    });
}

test "decl :: 属性组 :: 多个属性并列" {
    const gpa = std.testing.allocator;
    var tree = try ast.Ast.parse(gpa,
        \\<?php
        \\#[MyAttr(1), Other]
        \\class Foo {}
    , testing.v84);
    defer tree.deinit(gpa);
    try testing.expectNoErrors(tree);
    try testing.expectTagCounts(tree, .{ .attribute = 2, .attr_group = 1 });
}

test "decl :: 属性挂点 :: 函数/枚举 case/类常量" {
    const gpa = std.testing.allocator;
    var tree = try ast.Ast.parse(gpa,
        \\<?php
        \\#[Foo] function f(int $x) {}
        \\enum E { #[Bar] case A; }
        \\class C { #[Baz] const FOO = 1; }
    , testing.v85);
    defer tree.deinit(gpa);
    try testing.expectNoErrors(tree);
    try testing.expectTagCounts(tree, .{ .attr_group = 3, .attribute = 3, .param = 1 });
}

test "decl :: 属性钩子 :: get/set 各自成节点" {
    const gpa = std.testing.allocator;
    var tree = try ast.Ast.parse(gpa,
        \\<?php
        \\class Foo {
        \\    public string $bar {
        \\        get => $this->bar;
        \\        set(string $v) => $this->bar = $v;
        \\    }
        \\}
    , testing.v84);
    defer tree.deinit(gpa);
    try testing.expectNoErrors(tree);
    try testing.expectTagCounts(tree, .{ .stmt_property = 1, .property_hook = 2 });
}

test "decl :: 属性钩子上的属性 :: 挂到钩子节点" {
    const gpa = std.testing.allocator;
    var tree = try ast.Ast.parse(gpa,
        \\<?php
        \\class C { public string $x { #[Hook] get => $this->x; } }
    , testing.v85);
    defer tree.deinit(gpa);
    try testing.expectNoErrors(tree);
    try testing.expectTagCounts(tree, .{ .attr_group = 1, .property_hook = 1 });
}

test "decl :: 类常量与属性 :: 类型相同的成员区分节点" {
    const gpa = std.testing.allocator;
    var tree = try ast.Ast.parse(gpa,
        \\<?php
        \\class C {
        \\    public const FOO = 1;
        \\    public int $BAR = 2;
        \\}
    , testing.v84);
    defer tree.deinit(gpa);
    try testing.expectNoErrors(tree);
    try testing.expectTagCounts(tree, .{ .stmt_class_const = 1, .stmt_property = 1 });
}

test "decl :: 非对称可见性 (8.4) :: set 侧可见性被记录" {
    const gpa = std.testing.allocator;
    var tree = try ast.Ast.parse(gpa,
        \\<?php
        \\class Foo {
        \\    public private(set) string $bar;
        \\    public protected(set) int $baz;
        \\}
    , testing.v84);
    defer tree.deinit(gpa);
    try testing.expectNoErrors(tree);
    try testing.expectTagCounts(tree, .{ .stmt_property = 2 });
}

test "decl :: 参数 :: readonly 与提升修饰符任意顺序" {
    // 回归：此前只判一次 `promoted` 再判一次 `final`，未消费 `readonly`，
    // 导致 `public readonly int $x` 在 `$x` 处报 expected_variable。
    const gpa = std.testing.allocator;
    // `final` 提升为 8.5 引入，故含它的用例目标版本取 8.5
    const Case = struct { src: [:0]const u8, n: usize, ver: PhpVersion = testing.v84 };
    const cases = [_]Case{
        .{ .src = "<?php class C { function __construct(public readonly int $x) {} }", .n = 1 },
        .{ .src = "<?php class C { function __construct(readonly public int $x) {} }", .n = 1 },
        .{ .src = "<?php class C { function __construct(public final int $x) {} }", .n = 1, .ver = testing.v85 },
        .{ .src = "<?php class C { function __construct(public readonly int $x, protected string $y = 'd', private ?Foo $z = null) {} }", .n = 3 },
    };

    for (cases) |c| {
        var tree = try ast.Ast.parse(gpa, c.src, c.ver);
        defer tree.deinit(gpa);
        try testing.expectNoErrors(tree);
        try testing.expectTagCounts(tree, .{ .param = c.n });
    }
}

test "decl :: 参数 :: 提升/默认值/可变参数" {
    const gpa = std.testing.allocator;
    var tree = try ast.Ast.parse(gpa,
        \\<?php
        \\class C { function __construct(public int $x, private string $y = '') {} }
        \\function f(...$args) {}
    , testing.v84);
    defer tree.deinit(gpa);
    try testing.expectNoErrors(tree);
    // __construct 的 2 个提升参数 + f 的 1 个可变参数
    try testing.expectTagCounts(tree, .{ .param = 3 });
}

test "decl :: 构造器属性提升 :: 参数同时是属性" {
    const gpa = std.testing.allocator;
    var tree = try ast.Ast.parse(gpa,
        \\<?php
        \\class C { function __construct(public int $x, private string $y = '') {} }
    , testing.v84);
    defer tree.deinit(gpa);
    try testing.expectNoErrors(tree);
    try testing.expectTagCounts(tree, .{ .param = 2, .stmt_method = 1 });
}

test "decl :: 匿名类 :: 产出 stmt_class 与方法" {
    const gpa = std.testing.allocator;
    var tree = try ast.Ast.parse(gpa,
        \\<?php
        \\$x = new class { public function foo() {} };
    , testing.v84);
    defer tree.deinit(gpa);
    try testing.expectNoErrors(tree);
    try testing.expectTagCounts(tree, .{
        .expr_new = 1,
        .stmt_class = 1,
        .stmt_method = 1,
    });
}

test "decl :: 命名空间块 :: 包裹其内声明" {
    const gpa = std.testing.allocator;
    var tree = try ast.Ast.parse(gpa,
        \\<?php
        \\namespace Ns { function f() {} }
    , testing.v84);
    defer tree.deinit(gpa);
    try testing.expectNoErrors(tree);
    try testing.expectTagCounts(tree, .{ .stmt_namespace = 1, .stmt_function = 1 });
}

test "decl :: 全局命名空间块 :: 同样成节点" {
    const gpa = std.testing.allocator;
    var tree = try ast.Ast.parse(gpa,
        \\<?php
        \\namespace { function g() {} }
    , testing.v84);
    defer tree.deinit(gpa);
    try testing.expectNoErrors(tree);
    try testing.expectTagCounts(tree, .{ .stmt_namespace = 1 });
}

test "decl :: Deprecated 属性 :: 作为普通属性解析" {
    const gpa = std.testing.allocator;
    var tree = try ast.Ast.parse(gpa, "<?php #[Deprecated] function f() {}", testing.v84);
    defer tree.deinit(gpa);
    try testing.expectNoErrors(tree);
    try testing.expectTagCounts(tree, .{ .attribute = 1 });
}

test "decl :: 声明名位 :: 关键字作声明名是语法错（identifier_not_reserved 只接受 T_STRING）" {
    const gpa = std.testing.allocator;

    // 声明名位（类 / 接口 / trait / enum 名、`use ... as` 别名）全部关键字均禁，
    // 半保留集合（`static` / `list` 等）不豁免——此前只覆盖 `static` / `readonly`。
    const cases = [_][:0]const u8{
        "<?php class list {}",
        "<?php class if {}",
        "<?php interface list {}",
        "<?php trait static {}",
        "<?php use C as for;",
    };
    for (cases) |src| {
        var tree = try ast.Ast.parse(gpa, src, testing.v84);
        defer tree.deinit(gpa);
        try std.testing.expect(tree.errors.len > 0);
    }

    // `enum` / `readonly` 自 8.1 起才是关键字：8.0 目标下该位仍是普通标识符
    var t80 = try ast.Ast.parse(gpa, "<?php class readonly {}", testing.v80);
    defer t80.deinit(gpa);
    try testing.expectNoErrors(t80);

    var t81 = try ast.Ast.parse(gpa, "<?php class readonly {}", testing.v81);
    defer t81.deinit(gpa);
    try std.testing.expect(t81.errors.len > 0);
}

test "decl :: typed class const :: 前瞻区分类型位与常量名" {
    const gpa = std.testing.allocator;

    // 带类型（8.3）：类型位之后仍有常量名，故前瞻判定为 typed
    const typed = [_][:0]const u8{
        "<?php class C { const int X = 1; }",
        "<?php class C { const ?A B = 1; }",
        "<?php class C { const (A&B)|C D = 1; }",
        "<?php class C { const A\\B X = 1; }",
        "<?php class C { public const array L = []; }",
    };
    for (typed) |src| {
        var tree = try ast.Ast.parse(gpa, src, testing.v84);
        defer tree.deinit(gpa);
        try testing.expectNoErrors(tree);
        try testing.expectTagCounts(tree, .{ .stmt_class_const = 1, .const_decl = 1 });
    }

    // 无类型：首个名字后紧接 `=`，前瞻数不到第二个名字（多声明亦逐项如此）
    var plain = try ast.Ast.parse(gpa, "<?php class C { const A = 1, B = 2; }", testing.v84);
    defer plain.deinit(gpa);
    try testing.expectNoErrors(plain);
    try testing.expectTagCounts(plain, .{ .stmt_class_const = 1, .const_decl = 2 });

    // 版本：typed 形态为 8.3 引入（同 tag 的另一形态是基础语法，故不得整体门控）
    var v82 = try ast.Ast.parse(gpa, "<?php class C { const int X = 1; }", testing.v82);
    defer v82.deinit(gpa);
    try std.testing.expect(v82.errors.len > 0);

    var v83 = try ast.Ast.parse(gpa, "<?php class C { const int X = 1; }", testing.v83);
    defer v83.deinit(gpa);
    try testing.expectNoErrors(v83);

    var plain80 = try ast.Ast.parse(gpa, "<?php class C { const A = 1; }", testing.v80);
    defer plain80.deinit(gpa);
    try testing.expectNoErrors(plain80);
}

test "decl :: 名字位的关键字集合 :: 顶层函数名收窄到 fn_identifier" {
    const gpa = std.testing.allocator;

    // php.y `fn_identifier`：T_STRING 加 readonly / exit / die / clone / fn 特例
    const ok_fn = [_][:0]const u8{
        "<?php function readonly() {}",
        "<?php function exit() {}",
        "<?php function die() {}",
        "<?php function clone() {}",
        "<?php function fn() {}",
    };
    for (ok_fn) |src| {
        var tree = try ast.Ast.parse(gpa, src, testing.v84);
        defer tree.deinit(gpa);
        try testing.expectNoErrors(tree);
        try testing.expectTagCounts(tree, .{ .stmt_function = 1 });
    }

    // 其余关键字（含 semi_reserved 成员）作顶层函数名是语法错
    const bad_fn = [_][:0]const u8{
        "<?php function list() {}",
        "<?php function class() {}",
    };
    for (bad_fn) |src| {
        var tree = try ast.Ast.parse(gpa, src, testing.v84);
        defer tree.deinit(gpa);
        try std.testing.expect(tree.errors.len > 0);
    }

    // 方法名位（identifier_maybe_reserved）接受 semi_reserved——与上面的对照
    var m = try ast.Ast.parse(gpa, "<?php class C { public function list() {} }", testing.v84);
    defer m.deinit(gpa);
    try testing.expectNoErrors(m);
    try testing.expectTagCounts(m, .{ .stmt_method = 1 });
}

test "decl :: 属性 DNF 类型 :: 可见性后的 `(` 属类型位而非非对称可见性" {
    const gpa = std.testing.allocator;

    // 可见性后紧跟 `(`：该括号是 DNF 类型的交集括号。此前被 `(set)` 判定吞掉并回卷到
    // 可见性 token，使整条属性类型丢失（3 条误报）。
    var both = try ast.Ast.parse(gpa, "<?php class C { public (A&B)|(X&Y) $p; }", testing.v84);
    defer both.deinit(gpa);
    try testing.expectNoErrors(both);
    try testing.expectTagCounts(both, .{ .stmt_property = 1, .type_union = 1, .type_intersection = 2 });

    var right_name = try ast.Ast.parse(gpa, "<?php class C { public (A&B)|C $p; }", testing.v84);
    defer right_name.deinit(gpa);
    try testing.expectNoErrors(right_name);
    try testing.expectTagCounts(right_name, .{ .stmt_property = 1, .type_union = 1, .type_intersection = 1 });

    // 非对称可见性仍是 `(set)` 语义（不得因上面的放宽而失效）
    var av = try ast.Ast.parse(gpa, "<?php class C { public private(set) int $p; }", testing.v84);
    defer av.deinit(gpa);
    try testing.expectNoErrors(av);
    try testing.expectTagCounts(av, .{ .stmt_property = 1 });
    const prop = testing.firstNode(av, .stmt_property) orelse return error.TestUnexpectedResult;
    const av_extra = av.extraData(av.nodeData(prop).extra_and_opt_node[0], PropertyComponents);
    try std.testing.expectEqual(@as(u8, 2), @as(u8, @truncate(av_extra.visibility >> 8)));
}
