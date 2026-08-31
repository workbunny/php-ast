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
    stmts: SubRange,
    flags: u32,
};

pub const PropertyComponents = struct {
    name: TokenIndex,
    type: OptionalIndex,
    flags: u32,
    visibility: u32,
    default: OptionalIndex,
    hooks: SubRange,
    attrs: SubRange,
    /// 声明结尾的 `;`。
    semi: TokenIndex,
};

pub const PropertyHookComponents = struct {
    name: TokenIndex,
    flags: u32,
    params: SubRange,
    attrs: SubRange,
};

pub const ClassComponents = struct {
    name: TokenIndex,
    attrs: SubRange,
    extends: OptionalIndex,
    implements: OptionalIndex,
    stmts: SubRange,
    flags: u32,
};

pub const FunctionComponents = struct {
    name: TokenIndex,
    attrs: SubRange,
    params: SubRange,
    ret: OptionalIndex,
    body: OptionalIndex,
};

pub const ParamComponents = struct {
    name: TokenIndex,
    flags: u32,
    promoted: u32, // 构造器属性提升可见性：0=非提升 1=public 2=protected 3=private
    variadic: bool, // 可变参数 `...$x`
    type: OptionalIndex,
    default: OptionalIndex,
    attrs: SubRange,
};

pub const PropertyMods = struct {
    flags: u32,
    visibility: u32,
};

/// 类方法（Stmt\ClassMethod）：含可见性 / static / abstract / final / byRef 等修饰符。
pub const MethodComponents = struct {
    name: TokenIndex,
    attrs: SubRange,
    params: SubRange,
    ret: OptionalIndex,
    body: OptionalIndex,
    flags: u32, // 位标志：1=abstract 2=final 4=static 8=readonly
    visibility: u32, // 0=public 1=protected 2=private
    by_ref: bool,
};

/// 类常量（Stmt\ClassConst）：可见性、类型（PHP 8.3 起支持）与初值。
pub const ClassConstComponents = struct {
    name: TokenIndex,
    type: OptionalIndex,
    flags: u32, // 可见性：0=public 1=protected 2=private
    value: OptionalIndex,
    attrs: SubRange,
    /// 声明结尾的 `;`。
    semi: TokenIndex,
};

/// 解析函数声明（顶层或类内方法）：`function name(params): ret { body }`，
/// 无体时以 `;` 结束（前向声明 / 接口方法）。
pub fn parseFunction(p: *Parser, attrs: SubRange) ast.ParseError!?Index {
    const kw = p.nextToken();
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
    } else {
        const b = (try stmt.parseBlock(p)) orelse return null;
        body = OptionalIndex.fromIndex(b);
    }
    const extra = try p.addExtra(FunctionComponents{
        .name = name_tok,
        .attrs = attrs,
        .params = plr,
        .ret = ret,
        .body = body,
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
            .kw_public => { promoted = 1; _ = p.nextToken(); },
            .kw_protected => { promoted = 2; _ = p.nextToken(); },
            .kw_private => { promoted = 3; _ = p.nextToken(); },
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
    var variadic = false;
    if (p.tokTag() == .ellipsis) {
        _ = p.nextToken();
        variadic = true;
    }
    if (p.tokTag() == .ampersand) {
        flags |= 16;
        _ = p.nextToken();
    }
    if (p.tokTag() != .variable) {
        p.warn(ast.Error.Tag.expected_variable);
        return null;
    }
    const var_tok = p.nextToken();
    var def: OptionalIndex = .none;
    if (p.tokTag() == .equals) {
        _ = p.nextToken();
        const d = (try expr.parseExpr(p)) orelse return null;
        def = OptionalIndex.fromIndex(d);
    }
    const extra = try p.addExtra(ParamComponents{ .name = var_tok, .flags = flags, .promoted = promoted, .variadic = variadic, .type = type_opt, .default = def, .attrs = attrs });
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
    const name_tok = p.nextToken();
    var extends: OptionalIndex = .none;
    if (p.tokTag() == .kw_extends) {
        _ = p.nextToken();
        const en = (try expr.parseName(p)) orelse return null;
        extends = OptionalIndex.fromIndex(en);
    }
    var impl: OptionalIndex = .none;
    if (p.tokTag() == .kw_implements) {
        _ = p.nextToken();
        const im = (try expr.parseName(p)) orelse return null;
        impl = OptionalIndex.fromIndex(im);
        while (p.tokTag() == .comma) {
            _ = p.nextToken();
            _ = (try expr.parseName(p)) orelse return null;
        }
    }
    _ = p.expectToken(.lbrace);
    var stmts = try std.ArrayList(Index).initCapacity(p.gpa, 0);
    defer stmts.deinit(p.gpa);
    while (p.tokTag() != .rbrace and p.tokTag() != .eof) {
        const m = (try parseClassMember(p)) orelse {
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
    const kw = p.nextToken();
    var by_ref = false;
    if (p.tokTag() == .ampersand) {
        _ = p.nextToken();
        by_ref = true;
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

/// 解析匿名类 `new class(...) [extends X] [implements Y] { ... }`，复用类节点（stmt_class），名字为空。
pub fn parseAnonymousClass(p: *Parser, attrs: SubRange) ast.ParseError!?Index {
    const kw = p.nextToken();
    var extends: OptionalIndex = .none;
    if (p.tokTag() == .kw_extends) {
        _ = p.nextToken();
        const e = (try expr.parseName(p)) orelse return null;
        extends = OptionalIndex.fromIndex(e);
    }
    var impl: OptionalIndex = .none;
    if (p.tokTag() == .kw_implements) {
        _ = p.nextToken();
        const im = (try expr.parseName(p)) orelse return null;
        impl = OptionalIndex.fromIndex(im);
        while (p.tokTag() == .comma) {
            _ = p.nextToken();
            _ = (try expr.parseName(p)) orelse return null;
        }
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
        .flags = 0,
    });
    return (try p.addNode(.{
        .tag = .stmt_class,
        .main_token = kw,
        .data = .{ .extra_and_opt_node = .{ extra, extends } },
    })) orelse unreachable;
}

/// 解析类体成员：按首 token 分流到 trait use / 方法 / 常量 / 属性。
pub fn parseClassMember(p: *Parser) ast.ParseError!?Index {
    var attrs = p.emptySubRange();
    if (p.tokTag() == .hash) attrs = try parseAttrGroups(p);
    const mods = parsePropertyModifiers(p);
    if (p.tokTag() == .kw_use) return stmt.parseTraitUse(p);
    if (p.tokTag() == .kw_function) return parseMethod(p, attrs, mods);
    if (p.tokTag() == .kw_const) return parseClassConst(p, attrs, mods.visibility);
    return parseProperty(p, attrs, mods);
}

/// 收集类/方法修饰符（abstract/final/static/readonly），累积为位标志返回。
fn parseModifiers(p: *Parser) u32 {
    var flags: u32 = 0;
    while (true) {
        switch (p.tokTag()) {
            .kw_abstract => { flags |= 1; _ = p.nextToken(); },
            .kw_final => { flags |= 2; _ = p.nextToken(); },
            .kw_static => { flags |= 4; _ = p.nextToken(); },
            .kw_readonly => { flags |= 8; _ = p.nextToken(); },
            .kw_public, .kw_protected, .kw_private, .kw_var, .kw_const => _ = p.nextToken(),
            else => return flags,
        }
    }
}

/// 收集属性修饰符与可见性，支持 PHP 8.4 非对称可见性 `public(private)`。
fn parsePropertyModifiers(p: *Parser) PropertyMods {
    var res = PropertyMods{ .flags = 0, .visibility = 0 };
    res.visibility |= 3 << 8;
    var vis_count: u8 = 0;
    while (true) {
        switch (p.tokTag()) {
            .kw_abstract => { res.flags |= 1; _ = p.nextToken(); },
            .kw_final => { res.flags |= 2; _ = p.nextToken(); },
            .kw_static => { res.flags |= 4; _ = p.nextToken(); },
            .kw_readonly => { res.flags |= 8; _ = p.nextToken(); },
            .kw_public, .kw_protected, .kw_private, .kw_var => {
                const v: u8 = switch (p.tokTag()) {
                    .kw_public => 0,
                    .kw_protected => 1,
                    .kw_private => 2,
                    .kw_var => 0,
                    else => 0,
                };
                if (vis_count == 0) {
                    res.visibility |= v;
                    _ = p.nextToken();
                } else {
                    _ = p.nextToken();
                    if (p.tokTag() == .lparen) {
                        _ = p.nextToken();
                        if (p.isSoftKw("set")) _ = p.nextToken() else p.warn(ast.Error.Tag.expected_token);
                        _ = p.eatToken(.rparen);
                        // 非对称可见性：高字节写入 set 侧可见性（覆盖默认 3），
                        // 使「无 set/有 set」可区分（读取时 set_vis != 3 即表示非对称）。
                        res.visibility = (res.visibility & 0xFF) | (@as(u32, v) << 8);
                    }
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
    }
    if (p.tokTag() != .variable) {
        p.warn(ast.Error.Tag.expected_variable);
        return null;
    }
    const name_tok = p.nextToken();
    var def: OptionalIndex = .none;
    var hooks: SubRange = p.emptySubRange();
    var semi: TokenIndex = name_tok;
    if (p.tokTag() == .equals) {
        _ = p.nextToken();
        const d = (try expr.parseExpr(p)) orelse return null;
        def = OptionalIndex.fromIndex(d);
        semi = (p.eatToken(.semicolon)) orelse name_tok;
    } else if (p.tokTag() == .lbrace) {
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
        semi = (p.eatToken(.rbrace)) orelse name_tok;
        const lr = try p.addNodeList(list.items);
        hooks = .{ .start = lr.start, .end = lr.end };
    } else {
        semi = (p.eatToken(.semicolon)) orelse name_tok;
    }
    const extra = try p.addExtra(PropertyComponents{
        .name = name_tok,
        .type = type_opt,
        .flags = mods.flags,
        .visibility = mods.visibility,
        .default = def,
        .hooks = hooks,
        .attrs = attrs,
        .semi = semi,
    });
    const node = (try p.addNode(.{
        .tag = .stmt_property,
        .main_token = name_tok,
        .data = .{ .extra_and_opt_node = .{ extra, def } },
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
    if (p.tokTag() != .identifier) {
        p.warn(ast.Error.Tag.expected_token);
        return null;
    }
    const is_set = p.isSoftKw("set");
    const is_get = p.isSoftKw("get");
    if (!is_set and !is_get) {
        p.warn(ast.Error.Tag.expected_token);
        return null;
    }
    const name_tok = p.nextToken();
    var params: SubRange = p.emptySubRange();
    if (p.tokTag() == .lparen) {
        params = (try parseParamList(p)) orelse return null;
    }
    var flags: u32 = 0;
    if (is_set) flags |= 1;
    if (p.tokTag() == .double_arrow) {
        _ = p.nextToken();
        const body = (try expr.parseExpr(p)) orelse return null;
        _ = p.eatToken(.semicolon);
        const extra = try p.addExtra(PropertyHookComponents{ .name = name_tok, .flags = flags, .params = params, .attrs = attrs });
        return (try p.addNode(.{
            .tag = .property_hook,
            .main_token = name_tok,
            .data = .{ .extra_and_node = .{ extra, body } },
        })) orelse unreachable;
    } else if (p.tokTag() == .lbrace) {
        const body = (try stmt.parseBlock(p)) orelse return null;
        const extra = try p.addExtra(PropertyHookComponents{ .name = name_tok, .flags = flags, .params = params, .attrs = attrs });
        return (try p.addNode(.{
            .tag = .property_hook,
            .main_token = name_tok,
            .data = .{ .extra_and_node = .{ extra, body } },
        })) orelse unreachable;
    } else {
        p.warn(ast.Error.Tag.expected_token);
        return null;
    }
}

/// 解析类常量（Stmt\ClassConst）：`[可见性] const NAME[: type] = value;`，支持 PHP 8.3 类型。
/// 与属性节点（stmt_property）区分，对齐 php-parser 的 `Stmt\ClassConst`。
pub fn parseClassConst(p: *Parser, attrs: SubRange, visibility: u32) ast.ParseError!?Index {
    const kw = p.nextToken();
    const name_tok = p.nextToken();
    var type_opt: OptionalIndex = .none;
    if (p.tokTag() == .colon) {
        _ = p.nextToken();
        const ty = (try types.parseType(p)) orelse return null;
        type_opt = OptionalIndex.fromIndex(ty);
    }
    if (p.tokTag() != .equals) {
        p.warn(ast.Error.Tag.expected_token);
        return null;
    }
    _ = p.nextToken();
    const value = (try expr.parseExpr(p)) orelse return null;
    const semi = (p.eatToken(.semicolon)) orelse name_tok;
    const extra = try p.addExtra(ClassConstComponents{
        .name = name_tok,
        .type = type_opt,
        .flags = visibility,
        .value = OptionalIndex.fromIndex(value),
        .semi = semi,
        .attrs = attrs,
    });
    const node = (try p.addNode(.{
        .tag = .stmt_class_const,
        .main_token = kw,
        .data = .{ .extra_and_opt_node = .{ extra, OptionalIndex.fromIndex(value) } },
    })) orelse unreachable;
    // 常量上的注解（含 #[\Deprecated]）为 8.5 引入
    if (attrs.start != attrs.end) {
        p.node_versions.items[@intFromEnum(node)] = PhpVersion.fromComponents(8, 5);
    }
    return node;
}

/// 解析 interface / trait / enum 声明；enum 体内部特判为枚举项，其余走类成员。
pub fn parseTypeDecl(p: *Parser, comptime tag: Node.Tag, attrs: SubRange) ast.ParseError!?Index {
    const kw = p.nextToken();
    const name_tok = p.nextToken();
    var backing: OptionalIndex = .none;
    if (tag == .stmt_enum and p.tokTag() == .colon) {
        _ = p.nextToken();
        const bt = (try types.parseType(p)) orelse return null;
        backing = OptionalIndex.fromIndex(bt);
    }
    while (p.tokTag() == .kw_extends or p.tokTag() == .kw_implements) {
        _ = p.nextToken();
        _ = (try expr.parseName(p)) orelse return null;
        while (p.tokTag() == .comma) {
            _ = p.nextToken();
            _ = (try expr.parseName(p)) orelse return null;
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
        const pr = (try parseParam(p)) orelse return null;
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

test "decl :: 顶层函数 :: 参数与返回值成节点" {
    const gpa = std.testing.allocator;
    var tree = try ast.Ast.parse(gpa, "<?php function foo($a) { return $a; }", testing.v84);
    defer tree.deinit(gpa);
    try testing.expectNoErrors(tree);
    try testing.expectTagCounts(tree, .{ .stmt_function = 1, .param = 1 });
    try std.testing.expectEqual(@as(usize, 1), tree.rootStmts().len);
    try std.testing.expectEqual(.stmt_function, tree.nodeTag(tree.rootStmts()[0]));
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
