const std = @import("std");
const ast = @import("ast.zig");
const Token = @import("token.zig").Token;
const PhpVersion = @import("version.zig").PhpVersion;
const Parser = @import("parser.zig").Parser;
const decl = @import("parser_decl.zig");
const stmt = @import("parser_stmt.zig");
const types = @import("parser_type.zig");
const testing = @import("testing.zig");

const Node = ast.Node;
const Index = ast.Index;
const OptionalIndex = ast.OptionalIndex;
const OptionalTokenIndex = ast.OptionalTokenIndex;
const SubRange = ast.SubRange;
const ListRange = ast.ListRange;
const ExtraIndex = ast.ExtraIndex;
const TokenIndex = ast.TokenIndex;

pub const MatchComponents = struct {
    cond: Index,
    arms: SubRange,
};

pub const MatchArmComponents = struct {
    exprs: SubRange,
    body: Index,
    is_default: bool,
};

pub const NewComponents = struct {
    name: Index,
    args: SubRange,
};

pub const ArgumentComponents = struct {
    key: OptionalTokenIndex,
    unpack: bool,
    /// call-time 引用传参 `f(&$a)`（PHP 5.4 起语法保留，对齐 php-parser Arg.byRef）。
    by_ref: bool,
};

pub const ArrayItemComponents = struct {
    key: OptionalIndex,
    unpack: bool,
    /// 引用元素：`[&$v]`、`['k' => &$v]`、`list(&$v)`（ArrayItem.byRef）。
    by_ref: bool,
};

pub const TernaryComponents = struct {
    then: OptionalIndex,
    else_b: Index,
};

pub const ArrowFunctionComponents = struct {
    params: SubRange,
    ret: OptionalIndex,
    body: Index,
    /// 箭头函数引用返回 `fn&($x) => ...`（ArrowFunction.byRef）。
    by_ref: bool,
    /// 静态箭头 `static fn(...) => ...`（ArrowFunction.static）。
    is_static: bool,
    /// 属性组 `#[A] fn(...)`（闭包/箭头可带 attributes）。
    attrs: SubRange,
};

pub const ClosureComponents = struct {
    params: SubRange,
    uses: SubRange,
    ret: OptionalIndex,
    body: Index,
    /// 闭包引用返回 `function &(...) { }`（Closure.byRef）。
    by_ref: bool,
    /// 属性组 `#[A] function () {}`（闭包可带 attributes）。
    attrs: SubRange,
};

pub const ClosureUseComponents = struct {
    name: TokenIndex,
    by_ref: bool,
};

pub const StaticCallComponents = struct {
    name: Index,
    args: SubRange,
};

pub const YieldComponents = struct {
    key: OptionalIndex,
    value: OptionalIndex,
};

fn tokenTagAt(p: *const Parser, idx: TokenIndex) Token.Tag {
    return p.tokens.items(.tag)[idx];
}

/// `(int)` / `(string)` 等类型强转：紧跟在 `(` 之后的标识符必须是已知的强转类型名，
/// 且其后紧跟 `)`，才视为强转而非分组。
fn isCastKeyword(p: *const Parser) bool {
    // cast 名多为 identifier（int/real/void…），但 `array`/`unset` 是关键字，
    // 也须识别：`(array)$a` / `(unset)$a`。按文本判定，不看 token 类别。
    const tag = p.tokTag();
    if (tag != .identifier and !tag.isKeyword()) return false;
    const s = p.tokSlice();
    const casts = [_][]const u8{
        "int", "integer", "float", "double", "real", "string",
        "binary", "array", "object", "bool", "boolean", "unset", "void",
    };
    // PHP cast 名大小写不敏感（`(VOID)` / `(Int)` 合法）。
    for (casts) |c| {
        if (std.ascii.eqlIgnoreCase(c, s)) return true;
    }
    return false;
}

/// yield value/操作数是否能起始表达式的 token 粗判：语句/定界与二元运算符起始
/// （`; , ) ] } * / % ** = . ? : & | ^ < >`）不可作 value 起始；其余（一元/字面量/
/// 名字/变量等）可。粗判覆盖 fixture 场景，精确性由表达式解析继续保证。
pub fn isValueStart(tag: Token.Tag) bool {
    return switch (tag) {
        .semicolon, .eof, .comma, .rparen, .rbracket, .rbrace,
        .asterisk, .slash, .percent, .double_asterisk,
        .ampersand, .pipe, .caret, .dot, .dot_equal,
        .equals, .double_arrow, .colon, .question,
        .less_than, .greater_than, .ampersand_equal, .pipe_equal, .caret_equal,
        .left_shift, .right_shift,
        => false,
        else => true,
    };
}

/// 名字链段的合法 token：标识符、变量式名字（`$name` 经 name_var_like）、以及关键字
/// （php.y `identifier → T_STRING | semi_reserved`——关键字在名字内任意位置均可作段：
/// `fn\use` / `private\public` / `namespace static`）。仅限制"该 token 是名字段形状"，
/// 具体语境（声明名 vs 调用名）由调用方与表达式起始分派另行约束。
pub fn isNamePart(tag: Token.Tag) bool {
    return tag == .identifier or tag == .variable or tag.isKeyword();
}

/// `::` 后成员名的终止边界集合：出现这些 token 说明 `::` 后缺成员名（残缺，
/// recovery 场景 `Bar::)` 在此报错恢复），而非继续解析其它构造。
fn isMemberBoundary(tag: Token.Tag) bool {
    return switch (tag) {
        .rparen, .rbracket, .rbrace, .semicolon, .comma, .colon, .eof => true,
        else => false,
    };
}

/// `::` 后解析不出成员名时的错误恢复：残缺边界 token（`)`/`,`/`;`/EOF 等，如
/// recovery[19] 的 `foo(Bar::)`）就地诊断并放弃该表达式（返回 null 由上层恢复）。
fn handleDanglingStaticMember(p: *Parser) ?Index {
    if (isMemberBoundary(p.tokTag())) p.warn(ast.Error.Tag.expected_token);
    return null;
}

/// `::$`（间接静态成员）解析失败的恢复：`parseVariableName` 已就地报
/// `expected_variable`（如 `Foo::$` 到 EOF），不再补报 `expected_token`——
/// 否则同一 token 出现两条（php-parser 只报一条）。
fn handleDanglingDollarMember(p: *Parser) ?Index {
    _ = p;
    return null;
}

/// `->` / `?->` 后成员名解析失败的恢复：就地报 `unexpected <X>, expecting
/// T_STRING or T_VARIABLE or '{' or '$'`（php-parser 成员名位的期望集合，
/// recovery[8] 的 `$foo->;` 与 recovery[9] 的 `$bar->}`）。
fn handleDanglingArrowMember(p: *Parser) ?Index {
    p.warnAtExpected(ast.Error.Tag.expected_token, p.tok_i, .member_name);
    return null;
}

/// `->` / `?->` / `::` 后的成员名：标识符/关键字名字（`->b`）、变量式
/// （`->$b`），或花括号动态名 `{expr}`（`->{'b'}`、`::{$name}`，php.y
/// `member_name → identifier | '{' expr '}'`）。花括号名返回括号内表达式节点。
fn parseMemberName(p: *Parser) ast.ParseError!?Index {
    switch (p.tokTag()) {
        .lbrace => {
            _ = p.nextToken();
            const e = (try parseExpr(p)) orelse return null;
            _ = p.expectToken(.rbrace) orelse return null;
            return e;
        },
        .dollar => {
            // `::$` / `->` 后以 `$` 开头的间接形态（php.y `'$' simple_variable`）：
            // `A::$$b`（静态属性名是变量 b）、`A::${'b'}`（花括号表达式名）等。
            // 吃掉成员访问的 `$` 标记后按 simple_variable 链解析变量名部分。
            _ = p.nextToken();
            return (try parseVariableName(p)) orelse return null;
        },
        else => {
            // 先判「能否作名字段」，不可则**不消费** token 直接失败——`parseName`
            // 会无条件吃掉首 token，若让其消费 `;`/`}`/`)` 等边界符，调用方（成员名
            // 恢复）的诊断位置就会落到下一个 token 上（recovery[8] 的 `$foo->;` /
            // recovery[18] 的 `Bar::)` 由此错位到 `;`）。
            if (!isNamePart(p.tokTag())) return null;
            return (try parseName(p)) orelse return null;
        },
    }
}

pub fn parseName(p: *Parser) ast.ParseError!?Index {
    const first_tag = p.tokTag();
    const first = p.nextToken();
    var last = first;
    // FQ 名（\Foo\Bar）：前导 `\` 之后要先吃首名字段，再进入 `\段` 链。
    // （旧实现只吃前导 `\`，导致 `new \Foo\Bar()` 的 `Foo\Bar` 残留被误当函数调用——
    // 语法合法故弱断言不报错，属隐蔽 bug。）
    if (first_tag == .backslash) {
        if (isNamePart(p.tokTag())) {
            last = p.nextToken();
        }
    }
    while (p.tokTag() == .backslash) {
        _ = p.nextToken();
        if (!isNamePart(p.tokTag())) {
            // 孤立 `\`（后随 `{`、`;` 等非名字）不属于本名：回退，让调用方
            // （分组 use 判定、错误恢复）看到 `\`。例：`use Foo\{Bar}` 的组前缀
            // 解析到 Foo 即止，`\` 留给 use 的 group 判定。
            p.tok_i -= 1;
            break;
        }
        last = p.nextToken();
    }
    // 依首 token 区分名称的限定性，与 PHP-Parser 的 Name / FullyQualified / Relative 对齐。
    const tag: Node.Tag = switch (first_tag) {
        .backslash => .name_fully_qualified,
        .kw_namespace => .name_relative,
        .variable => .name_var_like,
        else => .name,
    };
    return (try p.addNode(.{
        .tag = tag,
        .main_token = first,
        .data = .{ .token = last },
    })) orelse unreachable;
}

/// 解析 `new` 后的类名引用：名字形态（`class_name`）或变量形态（`new_variable`）。
/// 对齐 PHP 语法 `class_name_reference → class_name | new_variable | '(' expr ')'`。
///
/// 名字形态：`Foo` / `\Foo\Bar` / `namespace\Foo`（交给 `parseName`）；名字后若接
/// `::$`（`Foo::$bar` 静态属性取类名）则进入 new_variable 后缀链。
/// 变量形态：纯变量 `$cls` 归约到 `parseName` 产出 `name_var_like`（既有语义：
/// 变量被视作"变量式名字"）；带后缀（`[]`/`->`/`?->`/`::$`）走变量表达式路径
/// （`name_var_like` 表达不了后缀链）。`(expr)`（PHP 8.0 任意表达式）由
/// `parsePrimary` 的括号分支自然消化。
/// 不消费 `(`——`new` 的构造参数括号由 `kw_new` 分支统一解析。
fn parseClassNameReference(p: *Parser) ast.ParseError!?Index {
    switch (p.tokTag()) {
        .identifier, .backslash, .kw_namespace, .kw_static => {
            // 名字形态：`new Foo` / `new \Foo\Bar` / `new namespace\Foo` / `new static()` /
            // `new parent()`（self/parent 为上下文关键字，lexer 归为 identifier）。
            // 这些必须走 `parseName` 归约为 name 节点——若落 parsePrimary，`kw_static`
            // 会被 `parsePostfixContinue` 消费 `()`（把 `new static()` 的构造参数当
            // 函数调用吃掉）。
            const name = (try parseName(p)) orelse return null;
            if (p.tokTag() == .double_colon) {
                // `Foo::$bar`：名字作 class 的静态属性取类名（new_variable 链）。
                return (try parseNewVariableSuffix(p, name)) orelse return null;
            }
            return name;
        },
        .variable => {
            // 预看下一 token：带后缀（[]/->/?->/::$）才走变量表达式路径，否则保持
            // 纯变量的 `name_var_like` 归约（兼容既有 AST 与黄金快照）。
            const save = p.tok_i;
            _ = p.nextToken();
            const has_suffix: bool = switch (p.tokTag()) {
                .lbracket, .arrow, .nullsafe_arrow, .double_colon => true,
                else => false,
            };
            p.tok_i = save;
            if (has_suffix) {
                const base = (try parsePrimary(p)) orelse return null;
                return (try parseNewVariableSuffix(p, base)) orelse return null;
            }
            return (try parseName(p)) orelse return null;
        },
        else => {
            // 括号表达式 / 函数调用结果等（`(expr)`、`foo()` 作类名）
            const base = (try parsePrimary(p)) orelse return null;
            return (try parseNewVariableSuffix(p, base)) orelse return null;
        },
    }
}

/// 在基表达式上继续解析 `new_variable` 允许的后缀：`[]` 下标、`->`/`?->` 属性、
/// `::$` 静态属性（php.y new_variable 右递归链，不含 `()`）。
///
/// 与 `parsePostfixContinue` 的区别：不消费 `()`（那是 `new` 的构造参数），也把
/// `?->` 限定为属性形态（php.y new_variable 的 `?-> property_name`，不接方法调用）。
/// 遇其他 token 返回基节点（后续由调用方按上下文处理）。
/// 解析 simple_variable（php.y）：`$a` | `$$a`/`$$$a`（间接嵌套）| `${expr}`。
/// 供需要"仅简单变量、不含后缀链"的语境使用（`global` 列表等）。
pub fn parseSimpleVariable(p: *Parser) ast.ParseError!?Index {
    return switch (p.tokTag()) {
        .variable => blk: {
            const t = p.nextToken();
            break :blk (try p.addNode(.{
                .tag = .expr_variable,
                .main_token = t,
                .data = .{ .token = t },
            })) orelse unreachable;
        },
        .dollar => blk: {
            const d = p.nextToken();
            const name = (try parseVariableName(p)) orelse return null;
            break :blk (try p.addNode(.{
                .tag = .expr_variable_ref,
                .main_token = d,
                .data = .{ .node = name },
            })) orelse unreachable;
        },
        else => null,
    };
}

/// 解析 `$` 之后的"动态变量名"部分（php.y `simple_variable` 的花括号/嵌套形态）：
/// - `.variable`（`$a`）→ 简单变量叶子（名字即 token）；
/// - `.dollar`（再一个 `$`，`$$a`/`$$$a`）→ 递归，外层 expr_variable 的 name 是
///   内层 expr_variable（间接引用嵌套）；
/// - `.lbrace`（`${expr}`）→ 括号内任意表达式作名字（`${foo()}` 等）。
/// 返回名字节点（变量叶子或表达式节点）。
fn parseVariableName(p: *Parser) ast.ParseError!?Index {
    return switch (p.tokTag()) {
        .variable => blk: {
            const t = p.nextToken();
            break :blk (try p.addNode(.{
                .tag = .expr_variable,
                .main_token = t,
                .data = .{ .token = t },
            })) orelse unreachable;
        },
        .dollar => blk: {
            const d = p.nextToken();
            const inner = (try parseVariableName(p)) orelse return null;
            break :blk (try p.addNode(.{
                .tag = .expr_variable_ref,
                .main_token = d,
                .data = .{ .node = inner },
            })) orelse unreachable;
        },
        .lbrace => {
            _ = p.nextToken();
            const e = (try parseExpr(p)) orelse return null;
            _ = p.expectToken(.rbrace) orelse return null;
            return e;
        },
        else => {
            p.warn(ast.Error.Tag.expected_variable);
            return null;
        },
    };
}

fn parseNewVariableSuffix(p: *Parser, base: Index) ast.ParseError!?Index {
    var e = base;
    while (true) {
        switch (p.tokTag()) {
            .lbracket => {
                _ = p.nextToken();
                var dim: OptionalIndex = .none;
                if (p.tokTag() != .rbracket) {
                    const d = (try parseExpr(p)) orelse return null;
                    dim = OptionalIndex.fromIndex(d);
                }
                _ = p.expectToken(.rbracket);
                e = (try p.addNode(.{
                    .tag = .expr_array_dim_fetch,
                    .main_token = p.nodeMainToken(e),
                    .data = .{ .node_and_opt_node = .{ e, dim } },
                })) orelse unreachable;
            },
            // 花括号下标（`new $a{'c'}`，PHP 7.4 前写法）：同 `[` 归 dim_fetch；
            // 同样按版本门控（8.0+ 不消费）。
            .lbrace => {
                if (p.version.id >= 80000) return e;
                _ = p.nextToken();
                var dim: OptionalIndex = .none;
                if (p.tokTag() != .rbrace) {
                    const d = (try parseExpr(p)) orelse return null;
                    dim = OptionalIndex.fromIndex(d);
                }
                _ = p.expectToken(.rbrace);
                e = (try p.addNode(.{
                    .tag = .expr_array_dim_fetch,
                    .main_token = p.nodeMainToken(e),
                    .data = .{ .node_and_opt_node = .{ e, dim } },
                })) orelse unreachable;
            },
            .arrow => {
                _ = p.nextToken();
                const name = (try parseMemberName(p)) orelse return handleDanglingArrowMember(p);
                e = (try p.addNode(.{
                    .tag = .expr_property_fetch,
                    .main_token = p.nodeMainToken(e),
                    .data = .{ .node_and_node = .{ e, name } },
                })) orelse unreachable;
            },
            .nullsafe_arrow => {
                // `new $a?->b`：空安全属性取类名（8.0）。只到属性，不消费 `()`。
                _ = p.nextToken();
                const name = (try parseMemberName(p)) orelse return handleDanglingArrowMember(p);
                e = (try p.addNode(.{
                    .tag = .expr_nullsafe_property_fetch,
                    .main_token = p.nodeMainToken(e),
                    .data = .{ .node_and_node = .{ e, name } },
                })) orelse unreachable;
            },
            .double_colon => {
                // `Foo::$bar` / `$a::$b` / `...::$c`：静态属性取类名。链可继续
                // （`A::$A::$b`）。php.y 区分：`::$`（后随 $ 标记）→ 静态属性
                // （static_member_prop_name = simple_variable）；`::` 后名字/花括号
                // → 类常量。`::` 后以 $ 起即为静态属性（含 `$$b`/`${'b'}` 间接形态）。
                _ = p.nextToken();
                const dollar_member = p.tokTag() == .dollar;
                // `Bar::)` 等残缺：`::` 后不是合法成员名且到成员边界——就地诊断恢复。
                // `::$` 形态失败（如 `Foo::$` 到 EOF）已由 parseVariableName 报过，
                // 不再补报。
                const name = (try parseMemberName(p)) orelse
                    return if (dollar_member) handleDanglingDollarMember(p) else handleDanglingStaticMember(p);
                const name_main = p.nodeMainToken(name);
                if (dollar_member or tokenTagAt(p, name_main) == .variable) {
                    e = (try p.addNode(.{
                        .tag = .expr_static_property_fetch,
                        .main_token = p.nodeMainToken(e),
                        .data = .{ .node_and_node = .{ e, name } },
                    })) orelse unreachable;
                } else {
                    e = (try p.addNode(.{
                        .tag = .expr_class_const_fetch,
                        .main_token = p.nodeMainToken(e),
                        .data = .{ .node_and_node = .{ e, name } },
                    })) orelse unreachable;
                }
            },
            else => return e,
        }
    }
}

pub fn parseExpr(p: *Parser) ast.ParseError!?Index {
    return parseBinary(p, 0);
}

pub fn parseBinary(p: *Parser, min_prec: u8) ast.ParseError!?Index {
    var lhs = (try parseUnary(p)) orelse return null;
    while (true) {
        const t = p.tokTag();

        // 三元 `?:` / elvis `?:`
        if (t == .question) {
            _ = p.nextToken();
            var then_b: OptionalIndex = .none;
            if (p.tokTag() != .colon) {
                const tb = (try parseExpr(p)) orelse return null;
                then_b = OptionalIndex.fromIndex(tb);
            }
            _ = p.expectToken(.colon);
            const eb = (try parseExpr(p)) orelse return null;
            const extra = try p.addExtra(TernaryComponents{ .then = then_b, .else_b = eb });
            lhs = (try p.addNode(.{
                .tag = .expr_ternary,
                .main_token = p.nodeMainToken(lhs),
                .data = .{ .node_and_extra = .{ lhs, extra } },
            })) orelse unreachable;
            continue;
        }

        // instanceof（非结合，比比较运算更高）
        if (t == .kw_instanceof) {
            _ = p.nextToken();
            const cls = (try parsePrimary(p)) orelse return null;
            lhs = (try p.addNode(.{
                .tag = .expr_instanceof,
                .main_token = p.nodeMainToken(lhs),
                .data = .{ .node_and_node = .{ lhs, cls } },
            })) orelse unreachable;
            continue;
        }

        // 赋值（含复合赋值、引用赋值），右结合。
        //
        // 优先级仅高于 `and`/`xor`/`or`：右值必须能吸收 `??` 及以上的全部运算，
        // 否则 `$a = 1 + 2` 会被解析成 `($a = 1) + 2`，语义完全错误。
        if (isAssignmentOp(t)) {
            const op = p.nextToken();
            var tag: Node.Tag = if (t == .equals) .expr_assign else .expr_assign_op;
            if (t == .equals and p.tokTag() == .ampersand) {
                _ = p.nextToken();
                tag = .expr_assign_ref;
            }
            const rhs = (try parseBinary(p, MIN_PREC_OF_ASSIGN_RHS)) orelse return null;
            lhs = (try p.addNode(.{
                .tag = tag,
                .main_token = op,
                .data = .{ .node_and_node = .{ lhs, rhs } },
            })) orelse unreachable;
            continue;
        }

        const bp = bindingPower(t);
        if (bp[0] == 0 or bp[0] < min_prec) break;
        const op = p.nextToken();
        const next_min = if (t == .double_asterisk) bp[0] else bp[0] + 1;
        // 管道运算符 `|>`：PHP 词法把 `|` 与 `>` 拆成两个 token，需前瞻合并
        if (t == .pipe and p.tokTag() == .greater_than) {
            _ = p.nextToken(); // 吞掉 `>`
            const rhs = (try parseBinary(p, next_min)) orelse return null;
            lhs = (try p.addNode(.{
                .tag = .expr_pipe,
                .main_token = op,
                .data = .{ .node_and_node = .{ lhs, rhs } },
            })) orelse unreachable;
            continue;
        }
        const rhs = (try parseBinary(p, next_min)) orelse return null;
        lhs = (try p.addNode(.{
            .tag = .expr_binary,
            .main_token = op,
            .data = .{ .node_and_node = .{ lhs, rhs } },
        })) orelse unreachable;
    }
    return lhs;
}

pub fn parseUnary(p: *Parser) ast.ParseError!?Index {
    const t = p.tokTag();

    // 类型强转 `(T)`
    if (t == .lparen) {
        const save = p.tok_i;
        _ = p.nextToken();
        if (isCastKeyword(p)) {
            const cast_tok = p.tok_i;
            const cast_name = p.tokSlice();
            _ = p.nextToken();
            if (p.tokTag() == .rparen) {
                _ = p.nextToken();
                const operand = (try parseUnary(p)) orelse return null;
                const idx = (try p.addNode(.{
                    .tag = .expr_cast,
                    .main_token = cast_tok,
                    .data = .{ .node = operand },
                })) orelse unreachable;
                // `(void)` 强转为 8.5 引入（关键字名大小写不敏感）
                if (std.ascii.eqlIgnoreCase("void", cast_name)) {
                    p.node_versions.items[@intFromEnum(idx)] = PhpVersion.fromComponents(8, 5);
                }
                return idx;
            }
        }
        p.tok_i = save;
    }

    switch (t) {
        .minus, .plus => {
            const op = p.nextToken();
            // `**` 优先级高于一元 `-`/`+`：`-$a ** 2` 应为 `-($a ** 2)`，
            // 故操作数从幂运算的左优先级（见 bindingPower）开始解析。
            const operand = (try parseBinary(p, 17)) orelse return null;
            return (try p.addNode(.{
                .tag = .expr_unary,
                .main_token = op,
                .data = .{ .node = operand },
            })) orelse unreachable;
        },
        .bang, .tilde, .double_plus, .double_minus => {
            const op = p.nextToken();
            const operand = (try parseUnary(p)) orelse return null;
            return (try p.addNode(.{
                .tag = .expr_unary,
                .main_token = op,
                .data = .{ .node = operand },
            })) orelse unreachable;
        },
        .at => {
            const op = p.nextToken();
            const operand = (try parseUnary(p)) orelse return null;
            return (try p.addNode(.{
                .tag = .expr_error_suppress,
                .main_token = op,
                .data = .{ .node = operand },
            })) orelse unreachable;
        },
        .kw_clone => {
            // `clone($x, withProperties: [...])` / `clone(object: $x)` 等**括号式 clone-with**
            // （8.5）与语言构造 `clone $x`（一元）区分：括号式参数表与普通调用同构
            // （命名/展开/尾逗号），php-parser 对单参 `clone($x)` 亦归 Clone，多参/命名
            // 归 FuncCall(name: clone)。为接受判定与结构清晰，此处统一走名字调用路径
            // 产出 FuncCall——语义等价（差异见 doc/special.md）；`clone $x` 一元不变。
            if (p.tokTag() == .kw_clone and tokenTagAt(p, p.tok_i + 1) == .lparen) {
                return parseIdentifierLike(p);
            }
            const op = p.nextToken();
            const operand = (try parseUnary(p)) orelse return null;
            return (try p.addNode(.{
                .tag = .expr_clone,
                .main_token = op,
                .data = .{ .node = operand },
            })) orelse unreachable;
        },
        .kw_print => {
            const op = p.nextToken();
            const operand = (try parseUnary(p)) orelse return null;
            return (try p.addNode(.{
                .tag = .expr_print,
                .main_token = op,
                .data = .{ .node = operand },
            })) orelse unreachable;
        },
        .kw_throw => {
            const op = p.nextToken();
            const operand = (try parseUnary(p)) orelse return null;
            return (try p.addNode(.{
                .tag = .expr_throw,
                .main_token = op,
                .data = .{ .node = operand },
            })) orelse unreachable;
        },
        .kw_yield => return parseYield(p),
        else => return parsePostfix(p),
    }
}

pub fn parsePostfix(p: *Parser) ast.ParseError!?Index {
    const e = (try parsePrimary(p)) orelse return null;
    return (try parsePostfixContinue(p, e)) orelse return null;
}

/// 在已有基表达式 `base` 上继续解析后缀（`()`, `->`, `::`, `[]`, `++` 等）。
///
/// 从 `parsePostfix` 抽出，供需要先构造基表达式（如 `static` 作为类名）的调用方复用。
/// 返回后缀应用完毕后的最终节点。
fn parsePostfixContinue(p: *Parser, base: Index) ast.ParseError!?Index {
    var e = base;
    while (true) {
        switch (p.tokTag()) {
            .lparen => {
                const args = try parseArgs(p);
                // `$o->m()` 的前缀已由 `.arrow` 分支产出 expr_property_fetch，此处
                // 归约为方法调用；其余（`f()`、`$f()` 等）均为函数调用。
                const callee_tag = p.nodes.items(.tag)[@intFromEnum(e)];
                const tag: Node.Tag = if (callee_tag == .expr_property_fetch)
                    .expr_method_call
                else
                    .expr_func_call;
                e = (try p.addNode(.{
                    .tag = tag,
                    .main_token = p.nodeMainToken(e),
                    .data = .{ .node_and_range = .{ .node = e, .range = .{ .start = args.start, .end = args.end } } },
                })) orelse unreachable;
            },
            .arrow => {
                _ = p.nextToken();
                const name = (try parseMemberName(p)) orelse return handleDanglingArrowMember(p);
                e = (try p.addNode(.{
                    .tag = .expr_property_fetch,
                    .main_token = p.nodeMainToken(e),
                    .data = .{ .node_and_node = .{ e, name } },
                })) orelse unreachable;
            },
            .nullsafe_arrow => {
                _ = p.nextToken();
                const name = (try parseMemberName(p)) orelse return handleDanglingArrowMember(p);
                if (p.tokTag() == .lparen) {
                    const args = try parseArgs(p);
                    e = (try p.addNode(.{
                        .tag = .expr_nullsafe_method_call,
                        .main_token = p.nodeMainToken(e),
                        .data = .{ .node_and_range = .{ .node = e, .range = .{ .start = args.start, .end = args.end } } },
                    })) orelse unreachable;
                } else {
                    e = (try p.addNode(.{
                        .tag = .expr_nullsafe_property_fetch,
                        .main_token = p.nodeMainToken(e),
                        .data = .{ .node_and_node = .{ e, name } },
                    })) orelse unreachable;
                }
            },
            .double_colon => {
                _ = p.nextToken();
                const dollar_member = p.tokTag() == .dollar;
                const name = (try parseMemberName(p)) orelse
                    return if (dollar_member) handleDanglingDollarMember(p) else handleDanglingStaticMember(p);
                const name_main = p.nodeMainToken(name);
                if (p.tokTag() == .lparen) {
                    const args = try parseArgs(p);
                    const extra = try p.addExtra(StaticCallComponents{
                        .name = name,
                        .args = .{ .start = args.start, .end = args.end },
                    });
                    e = (try p.addNode(.{
                        .tag = .expr_static_call,
                        .main_token = p.nodeMainToken(e),
                        .data = .{ .node_and_extra = .{ e, extra } },
                    })) orelse unreachable;
                } else if (dollar_member or tokenTagAt(p, name_main) == .variable) {
                    e = (try p.addNode(.{
                        .tag = .expr_static_property_fetch,
                        .main_token = p.nodeMainToken(e),
                        .data = .{ .node_and_node = .{ e, name } },
                    })) orelse unreachable;
                } else {
                    e = (try p.addNode(.{
                        .tag = .expr_class_const_fetch,
                        .main_token = p.nodeMainToken(e),
                        .data = .{ .node_and_node = .{ e, name } },
                    })) orelse unreachable;
                }
            },
            .lbracket => {
                _ = p.nextToken();
                var dim: OptionalIndex = .none;
                if (p.tokTag() != .rbracket) {
                    const d = (try parseExpr(p)) orelse return null;
                    dim = OptionalIndex.fromIndex(d);
                }
                _ = p.expectToken(.rbracket);
                e = (try p.addNode(.{
                    .tag = .expr_array_dim_fetch,
                    .main_token = p.nodeMainToken(e),
                    .data = .{ .node_and_opt_node = .{ e, dim } },
                })) orelse unreachable;
            },
            // 花括号数组下标 `$a{'b'}`（PHP 7.4 前写法，8.0 起废弃）：仅目标版本
            // < 8.0 时 `{` 才是下标；8.0+ 的 `{` 属块/钩子等其它语境，不得消费
            // （否则 `1 { ... }` 属性钩子被误当下标）。
            .lbrace => {
                if (p.version.id >= 80000) return e;
                _ = p.nextToken();
                var dim: OptionalIndex = .none;
                if (p.tokTag() != .rbrace) {
                    const d = (try parseExpr(p)) orelse return null;
                    dim = OptionalIndex.fromIndex(d);
                }
                _ = p.expectToken(.rbrace);
                e = (try p.addNode(.{
                    .tag = .expr_array_dim_fetch,
                    .main_token = p.nodeMainToken(e),
                    .data = .{ .node_and_opt_node = .{ e, dim } },
                })) orelse unreachable;
            },
            .double_plus => {
                const op = p.nextToken();
                e = (try p.addNode(.{
                    .tag = .expr_post_inc,
                    .main_token = op,
                    .data = .{ .node = e },
                })) orelse unreachable;
            },
            .double_minus => {
                const op = p.nextToken();
                e = (try p.addNode(.{
                    .tag = .expr_post_dec,
                    .main_token = op,
                    .data = .{ .node = e },
                })) orelse unreachable;
            },
            else => return e,
        }
    }
}

/// 解析插值字符串：消费 `string_start`…`string_end`，把字面片段记为 `expr_string_part`，
/// 把 `$var` / `{$expr}` 等插值记为对应表达式节点，整体包成 `expr_encapsed`。
pub fn parseEncapsed(p: *Parser) ast.ParseError!?Index {
    const start = p.expectToken(.string_start) orelse return null;
    var parts = try std.ArrayList(Index).initCapacity(p.gpa, 0);
    defer parts.deinit(p.gpa);
    while (p.tokTag() != .string_end and p.tokTag() != .eof) {
        switch (p.tokTag()) {
            .string_part => {
                const t = p.nextToken();
                const node = (try p.addNode(.{
                    .tag = .expr_string_part,
                    .main_token = t,
                    .data = .{ .token = t },
                })) orelse unreachable;
                try parts.append(p.gpa, node);
            },
            .variable => {
                const v = (try parseExpr(p)) orelse return null;
                try parts.append(p.gpa, v);
            },
            .lbrace => {
                _ = p.nextToken();
                const e = (try parseExpr(p)) orelse return null;
                _ = p.expectToken(.rbrace);
                try parts.append(p.gpa, e);
            },
            else => {
                // 复杂变量残留的 `->`/`[`/`(` 等 token，在插值串内一律视作字面片段。
                const t = p.nextToken();
                const node = (try p.addNode(.{
                    .tag = .expr_string_part,
                    .main_token = t,
                    .data = .{ .token = t },
                })) orelse unreachable;
                try parts.append(p.gpa, node);
            },
        }
    }
    _ = p.expectToken(.string_end);
    const range = try p.addNodeList(parts.items);
    return (try p.addNode(.{
        .tag = .expr_encapsed,
        .main_token = start,
        .data = .{ .extra_range = .{ .start = range.start, .end = range.end } },
    })) orelse unreachable;
}

pub fn parsePrimary(p: *Parser) ast.ParseError!?Index {
    switch (p.tokTag()) {
        .int_literal => {
            const t = p.nextToken();
            return (try p.addNode(.{ .tag = .expr_int, .main_token = t, .data = .{ .token = t } })) orelse unreachable;
        },
        .float_literal => {
            const t = p.nextToken();
            return (try p.addNode(.{ .tag = .expr_float, .main_token = t, .data = .{ .token = t } })) orelse unreachable;
        },
        .string_literal => {
            const t = p.nextToken();
            return (try p.addNode(.{ .tag = .expr_string, .main_token = t, .data = .{ .token = t } })) orelse unreachable;
        },
        .variable => {
            const t = p.nextToken();
            return (try p.addNode(.{ .tag = .expr_variable, .main_token = t, .data = .{ .token = t } })) orelse unreachable;
        },
        // 复杂/间接变量：`$$a`、`$$$a`、`${'a'}`、`${foo()}`、`${$a}`。
        // lexer 已把首个落单 `$` 产为 dollar token，名字部分按 php.y
        // `simple_variable → '$' '{' expr '}' | '$' simple_variable` 递归。
        // AST 形态：`expr_variable_ref`，name 为子节点，对齐 php-parser
        // `Expr\Variable` 的 name 可为表达式（tag 差异见 doc/special.md 归一表）。
        .dollar => {
            const d = p.nextToken();
            const name = (try parseVariableName(p)) orelse return null;
            return (try p.addNode(.{
                .tag = .expr_variable_ref,
                .main_token = d,
                .data = .{ .node = name },
            })) orelse unreachable;
        },
        .kw_true, .kw_false, .kw_null => {
            const t = p.nextToken();
            const name = (try p.addNode(.{ .tag = .name, .main_token = t, .data = .{ .token = t } })) orelse unreachable;
            return (try p.addNode(.{ .tag = .expr_const_fetch, .main_token = t, .data = .{ .node = name } })) orelse unreachable;
        },
        .backtick => {
            const open = p.nextToken();
            // 内容与 encapsed 同构（lexer 以同一插值状态机分词）：字面片段 →
            // expr_string_part；`$var` 与 `{$expr}` 花括号插值 → 对应表达式节点；
            // 复杂变量残留 token（`->`/`[`/`(`）视作字面片段。整体 expr_shell_exec(parts)。
            var parts = try std.ArrayList(Index).initCapacity(p.gpa, 0);
            defer parts.deinit(p.gpa);
            while (p.tokTag() != .backtick and p.tokTag() != .eof) {
                switch (p.tokTag()) {
                    .string_part => {
                        const t = p.nextToken();
                        const node = (try p.addNode(.{
                            .tag = .expr_string_part,
                            .main_token = t,
                            .data = .{ .token = t },
                        })) orelse unreachable;
                        try parts.append(p.gpa, node);
                    },
                    .variable => {
                        const v = (try parseExpr(p)) orelse return null;
                        try parts.append(p.gpa, v);
                    },
                    .lbrace => {
                        // `{$x}` 花括号插值：吃 lbrace，内为表达式，收 rbrace
                        _ = p.nextToken();
                        const e = (try parseExpr(p)) orelse return null;
                        _ = p.expectToken(.rbrace);
                        try parts.append(p.gpa, e);
                    },
                    else => {
                        // 残留 token（插值内复杂变量的 `->` 等）：作字面片段保真
                        const t = p.nextToken();
                        const node = (try p.addNode(.{
                            .tag = .expr_string_part,
                            .main_token = t,
                            .data = .{ .token = t },
                        })) orelse unreachable;
                        try parts.append(p.gpa, node);
                    },
                }
            }
            _ = p.expectToken(.backtick);
            const range = try p.addNodeList(parts.items);
            return (try p.addNode(.{
                .tag = .expr_shell_exec,
                .main_token = open,
                .data = .{ .extra_range = .{ .start = range.start, .end = range.end } },
            })) orelse unreachable;
        },
        .string_start => {
            return parseEncapsed(p);
        },
        .magic_const => {
            const t = p.nextToken();
            return (try p.addNode(.{
                .tag = .expr_magic_const,
                .main_token = t,
                .data = .{ .token = t },
            })) orelse unreachable;
        },
        .identifier => return parseIdentifierLike(p),
        // 完全限定名起始的表达式：`\Foo\Bar()` 调用 / `\Foo` 常量引用。
        .backslash => return parseIdentifierLike(p),
        .kw_new => {

            // 先记游标再消费 `new`：类名缺失（缺类名直接 eof/`;`）时须回溯到 `new`
            // 前返回 null，维持「parseExpr 失败不消费 token」的不变量——否则上层
            // 错误恢复会把 eof 当可消费 token 越界推进。
            const save = p.tok_i;
            const t = p.nextToken();
            var name: Index = undefined;
            var args: ListRange = p.emptyRange();
            if (p.tokTag() == .kw_class or
                (p.tokTag() == .kw_readonly and tokenTagAt(p, p.tok_i + 1) == .kw_class) or
                (p.tokTag() == .hash))
            {
                // 匿名类：`new [attrs] [readonly] class(args) [extends] [implements] { }`
                // （8.0 起匿名类可带 attributes）。attrs 先吃（类节点承载）；readonly
                // 前缀再吃（flags=readonly）；args 随结果返回。
                var aattrs = p.emptySubRange();
                if (p.tokTag() == .hash) aattrs = try decl.parseAttrGroups(p);
                const ro: u32 = if (p.tokTag() == .kw_readonly) blk: {
                    _ = p.nextToken();
                    break :blk 8;
                } else 0;
                if (p.tokTag() != .kw_class) {
                    p.tok_i = save;
                    return null;
                }
                const ac = (try decl.parseAnonymousClass(p, aattrs, ro)) orelse {
                    p.tok_i = save;
                    return null;
                };
                name = ac.node;
                args = ac.args;
            } else {
                // 类名引用：名字形态（parseName）或 new_variable 形态（$cls / $arr['c'] /
                // $obj->prop）。此前只调 parseName，导致 `new $arr['c']()` 被错误解作
                // `(new $arr)['c']()`。对齐 PHP 语法 class_name_reference → class_name | new_variable。
                name = (try parseClassNameReference(p)) orelse {
                    p.tok_i = save;
                    return null;
                };
                if (p.tokTag() == .lparen) {
                    args = try parseArgs(p);
                }
            }
            const extra = try p.addExtra(NewComponents{ .name = name, .args = .{ .start = args.start, .end = args.end } });
            const idx = (try p.addNode(.{
                .tag = .expr_new,
               
 .main_token = t,
                .data = .{ .extra_and_node = .{ extra, name } },
            })) orelse unreachable;
            // 无括号 `new` 的**链式后续**（`new X->method()` / `new X[0]` / `new X::$p`）
            // 是 PHP 8.4 引入（此前须 `(new X)->method()`）；无括号 `new X;` 本身是基础
            // 语法，不可误标 8.4（否则 5.x/7.x 目标下的普通 new 全被拒）。同 tag 多版本，
            // 无法由 tag 区分，故在此按「无 args 且 new 表达式后紧跟链 token」覆盖。
            if (args.start == args.end and isNewChainNext(p.tokTag())) {
                p.node_versions.items[@intFromEnum(idx)] = PhpVersion.fromComponents(8, 4);
            }
            return idx;
        },
        .lbracket => {
            const t = p.nextToken();
            const lr = try parseArrayElements(p, .rbracket);
            const close = (p.eatToken(.rbracket)) orelse t;
            return (try p.addNode(.{
                .tag = .expr_array,
                .main_token = t,
                .data = .{ .extra_and_token = .{ .{ .start = lr.start, .end = lr.end }, close } },
            })) orelse unreachable;
        },
        // `array(...)` 长语法：与短数组 `[...]` 同构（php.y array_pair 全形态）。
        .kw_array => {
            const kw = p.nextToken();
            _ = p.expectToken(.lparen);
            const lr = try parseArrayElements(p, .rparen);
            const close = (p.eatToken(.rparen)) orelse kw;
            return (try p.addNode(.{
                .tag = .expr_array,
                .main_token = kw,
                .data = .{ .extra_and_token = .{ .{ .start = lr.start, .end = lr.end }, close } },
            })) orelse unreachable;
        },
        .lparen => {
            _ = p.nextToken();
            const e = (try parseExpr(p)) orelse return null;
            _ = p.expectToken(.rparen);
            return e;
        },
        .kw_match => return parseMatch(p),
        .kw_fn => {
            // `fn` 后跟 `(` 或 `&(` 是箭头函数；否则 `fn` 是半保留字作名字链首段
            // （`fn\use()` 关键字名调用）。前瞻不消费。
            const save = p.tok_i;
            _ = p.nextToken();
            var is_arrow = p.tokTag() == .lparen;
            if (!is_arrow and p.tokTag() == .ampersand) {
                _ = p.nextToken();
                is_arrow = p.tokTag() == .lparen;
            }
            p.tok_i = save;
            if (is_arrow) return parseArrowFunction(p, false, p.emptySubRange());
            return parseIdentifierLike(p);
        },
        .kw_function => return parseClosure(p, p.emptySubRange()),
        // 表达式位属性组（8.0 起闭包/箭头可带 attributes）：`#[A] function () {}`、
        // `#[A] fn() => 0`、`#[A] static function () {}`、`#[A] static fn() => 0`。
        .hash => return parseAttributedClosure(p),
        .kw_static => {
            // `static function () {}` 静态匿名函数；`static fn(...) => ...` 静态箭头；
            // 否则 `static` 作为类名走后缀（`static::method()`、`static::$prop` 等）。
            const save = p.tok_i;
            _ = p.nextToken();
            if (p.tokTag() == .kw_function) {
                return parseClosure(p, p.emptySubRange());
            }
            if (p.tokTag() == .kw_fn) {
                // 静态箭头：static 已吃，判断 fn 后是否为箭头参数表
                const save2 = p.tok_i;
                _ = p.nextToken();
                var is_arrow = p.tokTag() == .lparen;
                if (!is_arrow and p.tokTag() == .ampersand) {
                    _ = p.nextToken();
                    is_arrow = p.tokTag() == .lparen;
                }
                p.tok_i = save2;
                if (is_arrow) return parseArrowFunction(p, true, p.emptySubRange());
            }
            p.tok_i = save;
            const t = p.nextToken();
            const name = (try p.addNode(.{ .tag = .name, .main_token = t, .data = .{ .token = t } })) orelse unreachable;
            return (try parsePostfixContinue(p, name)) orelse unreachable;
        },
        .kw_include, .kw_include_once, .kw_require, .kw_require_once => {
            const kw = p.nextToken();
            const operand = (try parseUnary(p)) orelse return null;
            return (try p.addNode(.{
                .tag = .expr_include,
                .main_token = kw,
                .data = .{ .node = operand },
            })) orelse unreachable;
        },
        .kw_eval => {
            const kw = p.nextToken();
            _ = p.expectToken(.lparen);
            const operand = (try parseExpr(p)) orelse return null;
            _ = p.expectToken(.rparen);
            return (try p.addNode(.{
                .tag = .expr_eval,
                .main_token = kw,
                .data = .{ .node = operand },
            })) orelse unreachable;
        },
        .kw_exit, .kw_die => {
            // 老式语言构造 `exit;` / `die;`（无括号）→ expr_exit（无操作数）。
            // 自 PHP 8.5 起 `exit(...)` 的括号形态语义等同函数调用（支持命名参数 /
            // 展开 / 多参数 / FCC：`exit(status: 42)`、`exit(...$args)`、`exit($a,$b)`、
            // `exit(...)`），php-parser 亦归 FuncCall(name: exit)；`\exit($a)` FQ 前缀
            // 同理。这里凡 `(` 一律走名字调用路径（exit/die 是关键字名字）——老式
            // `exit('msg')` 亦归一为 FuncCall（结构差异见 doc/special.md，接受判定一致）。
            if (tokenTagAt(p, p.tok_i + 1) == .lparen) {
                return parseIdentifierLike(p);
            }
            const kw = p.nextToken();
            return (try p.addNode(.{
                .tag = .expr_exit,
                .main_token = kw,
                .data = .{ .opt_node = .none },
            })) orelse unreachable;
        },
        .kw_empty => {
            const kw = p.nextToken();
            _ = p.expectToken(.lparen);
            const operand = (try parseExpr(p)) orelse return null;
            _ = p.expectToken(.rparen);
            return (try p.addNode(.{
                .tag = .expr_empty,
                .main_token = kw,
                .data = .{ .node = operand },
            })) orelse unreachable;
        },
        .kw_isset => {
            const kw = p.nextToken();
            _ = p.expectToken(.lparen);
            var list = try std.ArrayList(Index).initCapacity(p.gpa, 0);
            defer list.deinit(p.gpa);
            while (true) {
                // 尾逗号 `isset($a, $b,)` 直接遇 `)`
                if (p.tokTag() == .rparen) break;
                const e = (try parseExpr(p)) orelse return null;
                try list.append(p.gpa, e);
                if (p.tokTag() == .comma) {
                    _ = p.nextToken();
                    continue;
                }
                break;
            }
            _ = p.expectToken(.rparen);
            const lr = try p.addNodeList(list.items);
            return (try p.addNode(.{
                .tag = .expr_isset,
                .main_token = kw,
                .data = .{ .extra_range = .{ .start = lr.start, .end = lr.end } },
            })) orelse unreachable;
        },
        .kw_list => {
            const kw = p.nextToken();
            _ = p.expectToken(.lparen);
            // list() 是解构语法，元素与短数组 `[...]` 同构（展开/引用/键/空槽——
            // 空槽产 expr_array_hole，与 `[$a, , $b]` 解构一致）。复用 parseArrayElements。
            const lr = try parseArrayElements(p, .rparen);
            const close = (p.eatToken(.rparen)) orelse kw;
            return (try p.addNode(.{
                .tag = .expr_list,
                .main_token = kw,
                .data = .{ .extra_and_token = .{ .{ .start = lr.start, .end = lr.end }, close } },
            })) orelse unreachable;
        },
        else => {
            // 非法字符：lexer 已报 `unexpected_character` / `unexpected_null_byte`
            // （php-parser 由宿主词法报错后不再额外产出语法错误），此处只跳过该
            // token，不重复报 expected_expr。
            if (p.tokTag() == .invalid) {
                _ = p.nextToken();
                return null;
            }
            // 半保留字作名字起始（php.y `identifier → semi_reserved`）：`private\protected()
            // `fn\use()` 等关键字链调用/常量引用。能到 parsePrimary 的语境均合法。
            if (p.tokTag().isKeyword()) return parseIdentifierLike(p);
            p.warn(ast.Error.Tag.expected_expr);
            return null;
        },
    }
}

/// 表达式位属性组修饰的闭包/箭头：attrs 解析后按后续关键字分派（static 可再接
/// function/fn）。返回闭包/箭头节点。
fn parseAttributedClosure(p: *Parser) ast.ParseError!?Index {
    const attrs = try decl.parseAttrGroups(p);
    return switch (p.tokTag()) {
        .kw_function => parseClosure(p, attrs),
        .kw_fn => parseArrowFunction(p, false, attrs),
        .kw_static => blk: {
            // `#[A] static function () {}` / `#[A] static fn() => 0`：吃 static 后分派
            // （箭头 is_static=true；闭包静态由 static 修饰隐式成立）。
            _ = p.nextToken(); // static
            switch (p.tokTag()) {
                .kw_function => return parseClosure(p, attrs),
                .kw_fn => return parseArrowFunction(p, true, attrs),
                else => {},
            }
            p.warn(ast.Error.Tag.expected_token);
            break :blk null;
        },
        else => blk: {
            p.warn(ast.Error.Tag.expected_token);
            break :blk null;
        },
    };
}

/// 无括号 new 后是否紧跟链式 token（8.4 语义判据）。
fn isNewChainNext(tag: Token.Tag) bool {
    return switch (tag) {
        .arrow, .nullsafe_arrow, .lbracket, .double_colon => true,
        else => false,
    };
}

/// 数组元素列表：`[` 短数组与 `array(` 长语法共用（定界符分别为 `]`/`)`）。
/// 每项支持展开 `...`、引用 `&`、键 `=>`（键前 `&` 属非法输入不归属）；元素间逗号，
/// 尾逗号（定界符前直接停）。空元素（空槽）仅解构语境合法，此处不产。
fn parseArrayElements(p: *Parser, term: Token.Tag) ast.ParseError!ListRange {
    var items = try std.ArrayList(Index).initCapacity(p.gpa, 0);
    defer items.deinit(p.gpa);
    while (p.tokTag() != term and p.tokTag() != .eof) {
        // 空槽（解构）：`[$a, , $b] = ...` / `list($a, , $b)` —— 项位置无表达式，
        // 逗号即槽位分隔（php-parser ArrayItem.value=null；此处以独立叶占位，
        // 槽位数=跳过的解构位置）。仅解构左侧合法；字面量数组的空槽属语法错误，
        // 但为接受判定与占位统一，此处一律按槽处理，诊断交给语义层。
        if (p.tokTag() == .comma) {
            const hole_tok = p.nextToken();
            const hole = (try p.addNode(.{
                .tag = .expr_array_hole,
                .main_token = hole_tok,
                .data = .{ .token = hole_tok },
            })) orelse unreachable;
            try items.append(p.gpa, hole);
            continue;
        }
        var unpack = false;
        if (p.tokTag() == .ellipsis) {
            _ = p.nextToken();
            unpack = true;
        }
        // 引用元素 `[&$v]`/`array(&$v)`：`&` 可出现在元素首（无键）或 `=>` 后。
        var by_ref = false;
        if (!unpack and p.tokTag() == .ampersand) {
            _ = p.nextToken();
            by_ref = true;
        }
        const val0 = (try parseExpr(p)) orelse return p.emptyRange();
        var key: OptionalIndex = .none;
        var val: Index = val0;
        if (!unpack and p.tokTag() == .double_arrow) {
            _ = p.nextToken();
            by_ref = false; // 键前的 `&`（非法输入）不归属 item
            if (p.tokTag() == .ampersand) {
                _ = p.nextToken();
                by_ref = true;
            }
            const v2 = (try parseExpr(p)) orelse return p.emptyRange();
            key = OptionalIndex.fromIndex(val0);
            val = v2;
        }
        const extra = try p.addExtra(ArrayItemComponents{ .key = key, .unpack = unpack, .by_ref = by_ref });
        const item = (try p.addNode(.{
            .tag = .expr_array_item,
            .main_token = p.nodeMainToken(val),
            .data = .{ .node_and_extra = .{ val, extra } },
        })) orelse unreachable;
        try items.append(p.gpa, item);
        if (p.tokTag() == .comma) {
            _ = p.nextToken();
            continue;
        }
        // 项后只能接 `,`（下一项）或列表结束符 `]` / `)`；否则报列表期望集合
        // （php-parser：`unexpected T_VARIABLE, expecting ',' or ']' or ')'`，
        // recovery[22] 的索引位与 recovery[24] 的数组字面量），并推进到结束符
        // **之前**停止——把夹杂的 token 交给列表收尾消化，既不连锁多报，也不
        // 泄漏到外层被当新语句（结束符留给调用方正常消费）。
        if (p.tokTag() != term) {
            // 项后只能接 `,`（下一项）或列表结束符；否则报列表期望集合
            // （php-parser：`unexpected X, expecting ',' or ']' or ')'`），并按括号
            // 配对消化残余 token 与结束符（`skipBalancedTo` 的通用恢复）。
            p.warnAtExpected(ast.Error.Tag.expected_token, p.tok_i, .comma_list);
            _ = p.skipBalancedTo(term, true);
        }
        break;
    }
    const lr = try p.addNodeList(items.items);
    return .{ .start = lr.start, .end = lr.end };
}

/// 名字起始的表达式：`Foo` / `A\B\C` / `\FQN` 及其调用/首类可调用形态。
/// identifier 与半保留关键字（作名字起始）共用此逻辑——差异只在 parseName 的分派。
fn parseIdentifierLike(p: *Parser) ast.ParseError!?Index {
    const name = (try parseName(p)) orelse return null;
    const t = p.nodeMainToken(name);
    if (p.tokTag() == .lparen) {
        const save = p.tok_i;
        _ = p.nextToken();
        if (p.tokTag() == .ellipsis) {
            _ = p.nextToken();
            if (p.tokTag() == .rparen) {
                _ = p.nextToken();
                return (try p.addNode(.{
                    .tag = .expr_first_class_callable,
                    .main_token = t,
                    .data = .{ .node = name },
                })) orelse unreachable;
            }
        }
        p.tok_i = save;
        const args = try parseArgs(p);
        return (try p.addNode(.{
            .tag = .expr_func_call,
            .main_token = t,
            .data = .{ .node_and_range = .{ .node = name, .range = .{ .start = args.start, .end = args.end } } },
        })) orelse unreachable;
    }
    return (try p.addNode(.{
        .tag = .expr_const_fetch,
        .main_token = t,
        .data = .{ .node = name },
    })) orelse unreachable;
}

pub fn parseArgs(p: *Parser) ast.ParseError!ListRange {
    _ = p.expectToken(.lparen);
    var args = p.emptyRange();
    if (p.tokTag() == .rparen) {
        _ = p.nextToken();
        return args;
    }
    var list = try std.ArrayList(Index).initCapacity(p.gpa, 0);
    defer list.deinit(p.gpa);
    while (true) {
        // 尾逗号 `f($a, $b,)`：列表结束直接 `)`，无下一实参。
        if (p.tokTag() == .rparen) break;
        // first-class callable 占位 `f(...)`：方法/静态调用与 `new` 的参数表里，
        // 省略号直接配 `)`——占位是独立参数（对齐 php-parser VariadicPlaceholder）。
        // 函数名直调形态 `foo(...)` 已在 parseIdentifierLike 特判为 expr_first_class_callable。
        if (p.tokTag() == .ellipsis) {
            const ell = p.nextToken();
            if (p.tokTag() == .rparen) {
                // 占位独占整个参数表：吃 `)` 后直接返回（不能再走循环后的
                // expectToken(.rparen)，否则双吃）。
                _ = p.nextToken();
                const ph = (try p.addNode(.{
                    .tag = .expr_variadic_placeholder,
                    .main_token = ell,
                    .data = .{ .token = ell },
                })) orelse unreachable;
                try list.append(p.gpa, ph);
                const lr = try p.addNodeList(list.items);
                return .{ .start = lr.start, .end = lr.end };
            }
            // 非占位：`...` 是展开（回到 unpack 正常路径），把已吃的省略号回卷
            p.tok_i = ell;
        }
        var unpack = false;
        if (p.tokTag() == .ellipsis) {
            _ = p.nextToken();
            unpack = true;
        }
        // call-time 引用实参 `f(&$a)`：实参位置首个 token 为 `&` 必是引用
        // （按位与左操作数不能在实参首出现），且与展开互斥。
        var by_ref = false;
        if (!unpack and p.tokTag() == .ampersand) {
            _ = p.nextToken();
            by_ref = true;
        }
        var val = (try parseExpr(p)) orelse {
            // 实参解析失败（如 `Bar::` 残缺）：诊断已由表达式层就地报出，此处按括号
            // 配对消化到参数表结束的 `)` 并消费，避免残余 token 泄漏到外层被当新语句。
            _ = p.skipBalancedTo(.rparen, true);
            args = try p.addNodeList(list.items);
            return args;
        };
        var key: OptionalTokenIndex = .none;
        if (!unpack and p.tokTag() == .colon) {
            // 命名参数名：标识符或关键字均可（`bar(class: 0)`，php.y name 含 semi_reserved）。
            const t0 = p.nodeMainToken(val);
            const tag0 = tokenTagAt(p, t0);
            if (tag0 == .identifier or tag0.isKeyword()) {
                key = OptionalTokenIndex.fromToken(t0);
                _ = p.nextToken();
                val = (try parseExpr(p)) orelse return args;
            }
        }
        const extra = try p.addExtra(ArgumentComponents{ .key = key, .unpack = unpack, .by_ref = by_ref });
        const arg = (try p.addNode(.{
            .tag = .expr_argument,
            .main_token = if (key.unwrap()) |k| k else p.nodeMainToken(val),
            .data = .{ .node_and_extra = .{ val, extra } },
        })) orelse unreachable;
        try list.append(p.gpa, arg);
        if (p.tokTag() == .comma) {
            _ = p.nextToken();
            continue;
        }
        break;
    }
    _ = p.expectToken(.rparen);
    args = try p.addNodeList(list.items);
    return args;
}

pub fn parseMatch(p: *Parser) ast.ParseError!?Index {
    const kw = p.nextToken();
    _ = p.expectToken(.lparen);
    const cond = (try parseExpr(p)) orelse return null;
    _ = p.expectToken(.rparen);
    _ = p.expectToken(.lbrace);
    var arms = try std.ArrayList(Index).initCapacity(p.gpa, 0);
    defer arms.deinit(p.gpa);
    while (p.tokTag() != .rbrace and p.tokTag() != .eof) {
        // arm 前的注释不建节点（注释驻 token 流），跳过——否则 `// list of conditions`
        // 整行注释被当条件表达式解析（match.test 的 arm 注释）。
        while (p.tokTag() == .comment or p.tokTag() == .doc_comment) {
            _ = p.nextToken();
        }
        var is_default = false;
        var first_tok: TokenIndex = 0;
        var exprs: ListRange = p.emptyRange();
        if (p.tokTag() == .kw_default) {
            _ = p.nextToken();
            is_default = true;
            // `default, =>`：default 后允许尾逗号再 `=>`（php.y 宽松形态）。
            _ = p.eatToken(.comma);
        } else {
            var list = try std.ArrayList(Index).initCapacity(p.gpa, 0);
            defer list.deinit(p.gpa);
            while (true) {
                // 条件列表尾逗号 `0, 1, =>`：列表结束直接遇 `=>`。
                if (p.tokTag() == .double_arrow or p.tokTag() == .rbrace) break;
                const e = (try parseExpr(p)) orelse return null;
                if (list.items.len == 0) first_tok = p.nodeMainToken(e);
                try list.append(p.gpa, e);
                if (p.tokTag() == .comma) {
                    _ = p.nextToken();
                    continue;
                }
                break;
            }
            exprs = try p.addNodeList(list.items);
        }
        _ = p.expectToken(.double_arrow);
        const body = (try parseExpr(p)) orelse return null;
        _ = p.eatToken(.comma);
        const extra = try p.addExtra(MatchArmComponents{
            .exprs = .{ .start = exprs.start, .end = exprs.end },
            .body = body,
            .is_default = is_default,
        });
        const mt = if (is_default) p.nodeMainToken(body) else first_tok;
        const arm = (try p.addNode(.{
            .tag = .expr_match_arm,
            .main_token = mt,
            .data = .{ .extra_and_node = .{ extra, body } },
        })) orelse unreachable;
        try arms.append(p.gpa, arm);
    }
    _ = p.eatToken(.rbrace);
    const lr = try p.addNodeList(arms.items);
    const extra = try p.addExtra(MatchComponents{ .cond = cond, .arms = .{ .start = lr.start, .end = lr.end } });
    return (try p.addNode(.{
        .tag = .expr_match,
        .main_token = kw,
        .data = .{ .extra_and_node = .{ extra, cond } },
    })) orelse unreachable;
}

fn parseYield(p: *Parser) ast.ParseError!?Index {
    const kw = p.nextToken();
    if (p.tokTag() == .identifier and std.mem.eql(u8, "from", p.tokSlice())) {
        _ = p.nextToken();
        const operand = (try parseUnary(p)) orelse return null;
        return (try p.addNode(.{
            .tag = .expr_yield_from,
            .main_token = kw,
            .data = .{ .node = operand },
        })) orelse unreachable;
    }
    // 空值判定：`yield;`/`yield,` 及**二元运算符起始**（`yield * -1` = `(yield) * (-1)`，
    // `*` 不能作 value 的表达式起始，yield 空值后由上层二元接续）都产无 value 的 yield。
    if (isValueStart(p.tokTag()) == false) {
        const extra = try p.addExtra(YieldComponents{ .key = .none, .value = .none });
        return (try p.addNode(.{
            .tag = .expr_yield,
            .main_token = kw,
            .data = .{ .extra = extra },
        })) orelse unreachable;
    }
    const first = (try parseUnary(p)) orelse return null;
    var key: OptionalIndex = .none;
    var value: OptionalIndex = OptionalIndex.fromIndex(first);
    if (p.tokTag() == .double_arrow) {
        _ = p.nextToken();
        const v = (try parseUnary(p)) orelse return null;
        key = OptionalIndex.fromIndex(first);
        value = OptionalIndex.fromIndex(v);
    }
    const extra = try p.addExtra(YieldComponents{ .key = key, .value = value });
    return (try p.addNode(.{
        .tag = .expr_yield,
        .main_token = kw,
        .data = .{ .extra = extra },
    })) orelse unreachable;
}

fn parseArrowFunction(p: *Parser, is_static: bool, attrs: SubRange) ast.ParseError!?Index {
    const kw = p.nextToken();
    // 引用返回 `fn&(...)`：fn 与参数表之间允许 `&`
    var by_ref = false;
    if (p.tokTag() == .ampersand) {
        _ = p.nextToken();
        by_ref = true;
    }
    const pl = try decl.parseParamList(p);
    const params = pl orelse p.emptySubRange();
    var ret: OptionalIndex = .none;
    if (p.tokTag() == .colon) {
        _ = p.nextToken();
        const ty = (try types.parseType(p)) orelse return null;
        ret = OptionalIndex.fromIndex(ty);
    }
    _ = p.expectToken(.double_arrow);
    const body = (try parseExpr(p)) orelse return null;
    const extra = try p.addExtra(ArrowFunctionComponents{ .params = params, .ret = ret, .body = body, .by_ref = by_ref, .is_static = is_static, .attrs = attrs });
    return (try p.addNode(.{
        .tag = .expr_arrow_function,
        .main_token = kw,
        .data = .{ .extra = extra },
    })) orelse unreachable;
}

fn parseClosure(p: *Parser, attrs: SubRange) ast.ParseError!?Index {
    const kw = p.nextToken();
    // 引用返回 `function &(...) { }`：function 与参数表之间允许 `&`
    var by_ref = false;
    if (p.tokTag() == .ampersand) {
        _ = p.nextToken();
        by_ref = true;
    }
    const pl = try decl.parseParamList(p);
    const params = pl orelse p.emptySubRange();
    var uses: SubRange = p.emptySubRange();
    if (p.tokTag() == .kw_use) {
        _ = p.nextToken();
        _ = p.expectToken(.lparen);
        var ulist = try std.ArrayList(ExtraIndex).initCapacity(p.gpa, 0);
        defer ulist.deinit(p.gpa);
        while (p.tokTag() != .rparen and p.tokTag() != .eof) {
            var use_by_ref = false;
            if (p.tokTag() == .ampersand) {
                _ = p.nextToken();
                use_by_ref = true;
            }
            const name_tok = p.expectToken(.variable) orelse break;
            const extra = try p.addExtra(ClosureUseComponents{ .name = name_tok, .by_ref = use_by_ref });
            try ulist.append(p.gpa, extra);
            if (p.tokTag() == .comma) {
                _ = p.nextToken();
                continue;
            }
            break;
        }
        _ = p.expectToken(.rparen);
        if (ulist.items.len > 0) {
            const start_e = p.extra_data.items.len;
            for (ulist.items) |ei| {
                try p.extra_data.append(p.gpa, @intFromEnum(ei));
            }
            uses = .{ .start = @enumFromInt(start_e), .end = @enumFromInt(p.extra_data.items.len) };
        }
    }
    var ret: OptionalIndex = .none;
    if (p.tokTag() == .colon) {
        _ = p.nextToken();
        const ty = (try types.parseType(p)) orelse return null;
        ret = OptionalIndex.fromIndex(ty);
    }
    const body = (try stmt.parseBlock(p)) orelse return null;
    const extra = try p.addExtra(ClosureComponents{ .params = params, .uses = uses, .ret = ret, .body = body, .by_ref = by_ref, .attrs = attrs });
    return (try p.addNode(.{
        .tag = .expr_closure,
        .main_token = kw,
        .data = .{ .extra = extra },
    })) orelse unreachable;
}

fn isAssignmentOp(t: Token.Tag) bool {
    return switch (t) {
        .equals, .plus_equal, .minus_equal, .asterisk_equal, .slash_equal, .percent_equal,
        .dot_equal, .ampersand_equal, .pipe_equal, .caret_equal, .double_asterisk_equal,
        .left_shift_equal, .right_shift_equal, .null_coalesce_equal => true,
        else => false,
    };
}

/// 解析赋值右值时传入的最小优先级。
///
/// 赋值在 PHP 中优先级仅高于 `and`/`xor`/`or`，故右值要吸收 `??`（下界 6）及
/// 以上的全部运算。取值必须与下方 `bindingPower` 中 `.null_coalesce` 的下界一致。
const MIN_PREC_OF_ASSIGN_RHS: u8 = 6;

fn bindingPower(t: Token.Tag) [2]u8 {
    return switch (t) {
        .comma => .{ 0, 0 },
        .kw_or => .{ 1, 1 },
        .kw_xor => .{ 2, 2 },
        .kw_and => .{ 3, 3 },
        .bool_or => .{ 4, 5 },
        .bool_and => .{ 5, 6 },
        .null_coalesce => .{ 6, 7 },
        .pipe => .{ 8, 9 },
        .caret => .{ 9, 10 },
        .ampersand => .{ 10, 11 },
        .equal_equal, .bang_equal, .equal_equal_equal, .bang_equal_equal, .spaceship => .{ 11, 12 },
        .less_than, .greater_than, .less_equal, .greater_equal => .{ 12, 13 },
        .kw_instanceof => .{ 13, 13 },
        .left_shift, .right_shift => .{ 14, 15 },
        .plus, .minus, .dot => .{ 15, 16 },
        .asterisk, .slash, .percent => .{ 16, 17 },
        .double_asterisk => .{ 17, 18 },
        else => .{ 0, 0 },
    };
}

// ===========================================================================
// 测试：表达式
// ===========================================================================

test "expr :: 引用形态 :: 数组/list 元素、call-time 实参、闭包/箭头返回与 use" {
    const gpa = std.testing.allocator;
    var tree = try ast.Ast.parse(gpa,
        \\<?php
        \\$a = [&$b, 'k' => &$c];
        \\list($x, &$y) = $src;
        \\consume(&$z);
        \\$f = function &() use (&$out) { return $out; };
        \\$g = fn&($n) => $n;
        \\$h = static function &() { };
    , testing.v85);
    defer tree.deinit(gpa);
    try testing.expectNoErrors(tree);
    try testing.expectTagCounts(tree, .{
        .expr_array_item = 4, // 数组字面量 2 项 + list 解构 2 项
        .expr_list = 1,
        .expr_func_call = 1,
        .expr_closure = 2,
        .expr_arrow_function = 1,
    });
}

test "expr :: 变量变量 :: 间接变量与花括号名全形态（对齐 variable/funcCall.test）" {
    const gpa = std.testing.allocator;
    var tree = try ast.Ast.parse(gpa,
        \\<?php
        \\${'a'};
        \\${foo()};
        \\$$a;
        \\$$$a;
        \\$$a['b'];
        \\${'a'}();
        \\$$a();
    , testing.v85);
    defer tree.deinit(gpa);
    try testing.expectNoErrors(tree);
    // ref：${'a'}、${foo()}、$$a、$$$a×2、$$a['b']、${'a'}()、$$a() = 8
    // simple variable：$$a、$$$a 内层、$$a['b']、$$a() = 4（${'a'} 名字是 string）
    try testing.expectTagCounts(tree, .{
        .expr_variable_ref = 8,
        .expr_variable = 4,
        .expr_func_call = 3, // ${foo()} + ${'a'}() + $$a()
        .expr_array_dim_fetch = 1,
    });
}

test "expr :: global :: 简单/间接变量均可（对齐 specialVars.test）" {
    const gpa = std.testing.allocator;
    var tree = try ast.Ast.parse(gpa,
        \\<?php
        \\function a() {
        \\    global $a, ${'b'}, $$c;
        \\    static $c, $d = 'e';
        \\}
    , testing.v84);
    defer tree.deinit(gpa);
    try testing.expectNoErrors(tree);
    try testing.expectTagCounts(tree, .{
        .stmt_global = 1,
        .expr_variable = 2, // $a 与 $$c 的内层 $c（${'b'} 名字是 string）
        .expr_variable_ref = 2, // ${'b'} + $$c
        .static_var = 2,
    });
}

test "expr :: 关键字名字 :: 名字链/调用/命名空间（对齐 keywordsInNamespacedName.test）" {
    const gpa = std.testing.allocator;
    var tree = try ast.Ast.parse(gpa,
        \\<?php
        \\namespace fn;
        \\namespace fn\use;
        \\namespace self;
        \\namespace parent;
        \\namespace static {
        \\    fn\use();
        \\    \fn\use();
        \\    namespace\fn\use();
        \\    private\protected\public\static\abstract\final();
        \\    fn\foo();
        \\}
    , testing.v85);
    defer tree.deinit(gpa);
    try testing.expectNoErrors(tree);
    try testing.expectTagCounts(tree, .{
        .stmt_namespace = 5,
        .name = 8, // 5 声明名 + fn\use/fn\foo/chain 三个调用名（链段整链一个 name）
        .name_fully_qualified = 1, // \fn\use
        .name_relative = 1, // namespace\fn\use
        .expr_func_call = 5,
    });
}

test "expr :: 类常量 :: 关键字名与多常量（对齐 semiReserved.test）" {
    const gpa = std.testing.allocator;
    var tree = try ast.Ast.parse(gpa,
        \\<?php
        \\class Test {
        \\    const TRAIT = 3, FINAL = 4;
        \\    public const LIST = 5, STATIC = 6;
        \\}
    , testing.v84);
    defer tree.deinit(gpa);
    try testing.expectNoErrors(tree);
    try testing.expectTagCounts(tree, .{ .stmt_class_const = 2, .const_decl = 4 });
}

test "expr :: A3 G5 回归 :: 占位/尾逗号/match 多条件/array()/shell 插值/static fn" {
    const gpa = std.testing.allocator;
    var tree = try ast.Ast.parse(gpa,
        \\<?php
        \\foo($a, $b,);
        \\foo(...);
        \\unset($a, $b,);
        \\isset($a, $b,);
        \\$o->foo(...);
        \\A::foo(...);
        \\new Foo(...);
        \\array('a', 'c' => 'd', &$e);
        \\$v = match (1) {
        \\    // conditions
        \\    0, 1, => 'F',
        \\    default, => 'D',
        \\};
        \\`ls $dir`;
        \\static fn($x) => $x;
        \\$o->{'m'}();
        \\A::{'s'}();
        \\bar(class: 1);
        \\0.5;
    , testing.v85);
    defer tree.deinit(gpa);
    try testing.expectNoErrors(tree);
    try testing.expectTagCounts(tree, .{
        .expr_variadic_placeholder = 3, // $o->foo(...) + A::foo(...) + new Foo(...)
        .expr_first_class_callable = 1, // foo(...) 直调形态
        .expr_array = 1, // array() 长语法
        .expr_match = 1,
        .expr_match_arm = 2,
        .expr_shell_exec = 1,
        .expr_arrow_function = 1, // static fn
        .expr_method_call = 2, // $o->foo(...) + $o->{'m'}()
        .expr_static_call = 2, // A::foo(...) + A::{'s'}()
        .stmt_unset = 1,
        .expr_isset = 1,
        .expr_func_call = 2, // foo($a, $b,) + bar(class: 1)
    });
}

test "expr :: 复合赋值 :: 移位与空合并 <<= >>= ??=" {
    const gpa = std.testing.allocator;
    var tree = try ast.Ast.parse(gpa, "<?php $a <<= 1; $b >>= 2; $c ??= 3;", testing.v84);
    defer tree.deinit(gpa);
    try testing.expectNoErrors(tree);
    try testing.expectTagCounts(tree, .{ .expr_assign_op = 3 });
}

test "expr :: 错误恢复 :: 残缺 new/后缀到 eof 不越界（对齐 errorHandling fixture）" {
    const gpa = std.testing.allocator;
    // `new` 后缺类名直达 eof：kw_new 消费后失败须回溯，错误恢复不得把 eof 越界推进
    var a = try ast.Ast.parse(gpa, "<?php\nnew\n", testing.v85);
    defer a.deinit(gpa);
    try std.testing.expect(a.errors.len >= 1);
    // `Foo::` 残缺静态访问直达 eof：后缀消费 `::` 后失败停在 eof，不越界
    var b = try ast.Ast.parse(gpa, "<?php\nFoo::\n", testing.v85);
    defer b.deinit(gpa);
    _ = b.root;
}

test "expr :: new :: 类名缺失有诊断而非静默产出空节点" {
    const gpa = std.testing.allocator;
    var tree = try ast.Ast.parse(gpa, "<?php new ;", testing.v85);
    defer tree.deinit(gpa);
    try std.testing.expect(tree.errors.len >= 1);
    try std.testing.expectEqual(@as(usize, 0), testing.countTag(tree, .expr_new));
}

test "expr :: 字面量 :: int/float/string 各自成节点" {
    const gpa = std.testing.allocator;
    var tree = try ast.Ast.parse(gpa,
        \\<?php
        \\$a = 1;
        \\$b = 1.5;
        \\$c = 'str';
    , testing.v84);
    defer tree.deinit(gpa);
    try testing.expectNoErrors(tree);
    try testing.expectTagCounts(tree, .{
        .expr_int = 1,
        .expr_float = 1,
        .expr_string = 1,
        .expr_assign = 3,
    });
}

test "expr :: 赋值 :: 普通/复合/引用三种形式分别成节点" {
    const gpa = std.testing.allocator;
    var tree = try ast.Ast.parse(gpa,
        \\<?php
        \\$a = 1;
        \\$a += 1;
        \\$a = &$b;
    , testing.v84);
    defer tree.deinit(gpa);
    try testing.expectNoErrors(tree);
    try testing.expectTagCounts(tree, .{
        .expr_assign = 1,
        .expr_assign_op = 1,
        .expr_assign_ref = 1,
    });
}

test "expr :: 二元运算 :: 算术与比较均归为 expr_binary" {
    const gpa = std.testing.allocator;
    var tree = try ast.Ast.parse(gpa, "<?php $a + $b; $c < $d;", testing.v84);
    defer tree.deinit(gpa);
    try testing.expectNoErrors(tree);
    try testing.expectTagCounts(tree, .{ .expr_binary = 2, .expr_variable = 4 });
}

test "expr :: 赋值优先级 :: 右值吸收算术运算" {
    const gpa = std.testing.allocator;
    // 赋值优先级低于 `+`：必须解析为 `$a = (1 + 2)`，
    // 而非 `($a = 1) + 2`（后者语义完全不同）。
    var tree = try ast.Ast.parse(gpa, "<?php $a = 1 + 2;", testing.v84);
    defer tree.deinit(gpa);
    try testing.expectNoErrors(tree);

    const asg = testing.firstNode(tree, .expr_assign) orelse return error.TestUnexpectedResult;
    const bin = testing.firstNode(tree, .expr_binary) orelse return error.TestUnexpectedResult;
    // binary 应是 assign 的右值，而非 assign 是 binary 的左值
    const rhs = tree.nodeData(asg).node_and_node[1];
    try std.testing.expectEqual(bin, rhs);
    // assign 覆盖 `$a = 1 + 2`，binary 覆盖 `1 + 2`
    try std.testing.expectEqualStrings("$a", tree.tokenSlice(tree.firstToken(asg)));
    try std.testing.expectEqualStrings("1", tree.tokenSlice(tree.firstToken(bin)));
}

test "expr :: 赋值优先级 :: and/or 仍低于赋值" {
    const gpa = std.testing.allocator;
    // `$a = 1 and 2` 应解析为 `($a = 1) and 2`
    var tree = try ast.Ast.parse(gpa, "<?php $a = 1 and 2;", testing.v84);
    defer tree.deinit(gpa);
    try testing.expectNoErrors(tree);

    const bin = testing.firstNode(tree, .expr_binary) orelse return error.TestUnexpectedResult;
    const lhs = tree.nodeData(bin).node_and_node[0];
    try std.testing.expectEqual(.expr_assign, tree.nodeTag(lhs));
    try std.testing.expectEqualStrings("and", tree.tokenSlice(tree.nodeMainToken(bin)));
}

test "expr :: 赋值优先级 :: 右结合且右值含 null 合并" {
    const gpa = std.testing.allocator;
    var tree = try ast.Ast.parse(gpa, "<?php $a = $b ?? $c;", testing.v84);
    defer tree.deinit(gpa);
    try testing.expectNoErrors(tree);

    const asg = testing.firstNode(tree, .expr_assign) orelse return error.TestUnexpectedResult;
    const rhs = tree.nodeData(asg).node_and_node[1];
    try std.testing.expectEqual(.expr_binary, tree.nodeTag(rhs));
}

test "expr :: 一元运算 :: 负号与取反" {
    const gpa = std.testing.allocator;
    var tree = try ast.Ast.parse(gpa, "<?php -$a; !$b;", testing.v84);
    defer tree.deinit(gpa);
    try testing.expectNoErrors(tree);
    try testing.expectTagCounts(tree, .{ .expr_unary = 2 });
}

test "expr :: 函数调用 :: 实参与命名实参产出 expr_argument" {
    const gpa = std.testing.allocator;
    var tree = try ast.Ast.parse(gpa, "<?php f(1); g(a: 2);", testing.v84);
    defer tree.deinit(gpa);
    try testing.expectNoErrors(tree);
    try testing.expectTagCounts(tree, .{ .expr_func_call = 2, .expr_argument = 2 });
}

test "expr :: 属性访问与方法调用 :: -> 的两种形态" {
    const gpa = std.testing.allocator;
    var tree = try ast.Ast.parse(gpa, "<?php $o->p; $o->m();", testing.v84);
    defer tree.deinit(gpa);
    try testing.expectNoErrors(tree);
    // `$o->m()` 的 callee 本身也是一次属性取回，故 expr_property_fetch 为 2
    // （与 PHP-Parser 的 MethodCall.var 为 PropertyFetch 一致）。
    try testing.expectTagCounts(tree, .{
        .expr_property_fetch = 2,
        .expr_method_call = 1,
    });
}

test "expr :: 常量取值 :: 裸标识符产出 expr_const_fetch" {
    const gpa = std.testing.allocator;
    var tree = try ast.Ast.parse(gpa, "<?php FOO;", testing.v84);
    defer tree.deinit(gpa);
    try testing.expectNoErrors(tree);
    try testing.expectTagCounts(tree, .{ .expr_const_fetch = 1, .name = 1 });
}

test "expr :: 数组字面量 :: 每项包裹为 expr_array_item" {
    const gpa = std.testing.allocator;
    var tree = try ast.Ast.parse(gpa, "<?php [1, 2, 'k' => 3];", testing.v84);
    defer tree.deinit(gpa);
    try testing.expectNoErrors(tree);
    try testing.expectTagCounts(tree, .{ .expr_array = 1, .expr_array_item = 3 });
}

test "expr :: 错误抑制 :: @ 前缀产出 expr_error_suppress" {
    const gpa = std.testing.allocator;
    var tree = try ast.Ast.parse(gpa, "<?php @f();", testing.v84);
    defer tree.deinit(gpa);
    try testing.expectNoErrors(tree);
    try testing.expectTagCounts(tree, .{
        .expr_error_suppress = 1,
        .expr_func_call = 1,
    });
}

test "expr :: exit/die :: 无括号归 expr_exit；括号形态作名字调用" {
    const gpa = std.testing.allocator;
    // `exit;`/`die;` 无括号 → expr_exit；`exit(status:42)`/`die(1)` 括号形态 → FuncCall
    var tree = try ast.Ast.parse(gpa, "<?php exit; die; exit(status: 42); die(1); \\exit($x);", testing.v85);
    defer tree.deinit(gpa);
    try testing.expectNoErrors(tree);
    try testing.expectTagCounts(tree, .{ .expr_exit = 2, .expr_func_call = 3 });
}

test "expr :: eval :: 产出 expr_eval" {
    const gpa = std.testing.allocator;
    var tree = try ast.Ast.parse(gpa, "<?php eval('1');", testing.v84);
    defer tree.deinit(gpa);
    try testing.expectNoErrors(tree);
    try testing.expectTagCounts(tree, .{ .expr_eval = 1 });
}

test "expr :: print :: 产出 expr_print" {
    const gpa = std.testing.allocator;
    var tree = try ast.Ast.parse(gpa, "<?php print $a;", testing.v84);
    defer tree.deinit(gpa);
    try testing.expectNoErrors(tree);
    try testing.expectTagCounts(tree, .{ .expr_print = 1 });
}

test "expr :: shell_exec :: 反引号产出 expr_shell_exec" {
    const gpa = std.testing.allocator;
    var tree = try ast.Ast.parse(gpa, "<?php `ls -l`;", testing.v84);
    defer tree.deinit(gpa);
    try testing.expectNoErrors(tree);
    try testing.expectTagCounts(tree, .{ .expr_shell_exec = 1 });
}

test "expr :: yield from :: 产出 expr_yield_from" {
    const gpa = std.testing.allocator;
    var tree = try ast.Ast.parse(gpa,
        \\<?php
        \\function g() { yield from $it; }
    , testing.v84);
    defer tree.deinit(gpa);
    try testing.expectNoErrors(tree);
    try testing.expectTagCounts(tree, .{ .expr_yield_from = 1 });
}

test "expr :: 管道运算符 (8.5) :: 目标 8.5 下产出 expr_pipe" {
    const gpa = std.testing.allocator;
    var tree = try ast.Ast.parse(gpa, "<?php $x |> strlen;", testing.v85);
    defer tree.deinit(gpa);
    try testing.expectNoErrors(tree);
    try testing.expectTagCounts(tree, .{ .expr_pipe = 1 });
}

test "expr :: match :: 条件与分支臂成节点" {
    const gpa = std.testing.allocator;
    var tree = try ast.Ast.parse(gpa,
        \\<?php
        \\match ($x) {
        \\    1, 2 => 'a',
        \\    default => 'b',
        \\};
    , testing.v84);
    defer tree.deinit(gpa);
    try testing.expectNoErrors(tree);
    try testing.expectTagCounts(tree, .{ .expr_match = 1, .expr_match_arm = 2 });
}

test "expr :: 一等可调用 :: strlen(...) 成节点" {
    const gpa = std.testing.allocator;
    var tree = try ast.Ast.parse(gpa, "<?php strlen(...);", testing.v84);
    defer tree.deinit(gpa);
    try testing.expectNoErrors(tree);
    try testing.expectTagCounts(tree, .{ .expr_first_class_callable = 1 });
}

test "expr :: new :: 有括号/无括号/动态类名" {
    const gpa = std.testing.allocator;
    var tree = try ast.Ast.parse(gpa,
        \\<?php
        \\$x = new Foo;
        \\$y = new Foo(1);
        \\$z = new $cls;
    , testing.v84);
    defer tree.deinit(gpa);
    try testing.expectNoErrors(tree);
    try testing.expectTagCounts(tree, .{ .expr_new = 3 });
}

test "expr :: new :: new_variable 类名（变量/下标/属性形态）" {
    // 回归：`new $arr['c']()` 曾被错解为 `(new $arr)['c']()`。
    // 类名引用应为整体 `$arr['c']`（PHP: class_name_reference → new_variable）。
    const gpa = std.testing.allocator;
    var tree = try ast.Ast.parse(gpa,
        \\<?php
        \\$a = new $cls;
        \\$b = new $arr['c'];
        \\$c = new $obj->prop;
        \\$d = new $dict[$key]();
    , testing.v84);
    defer tree.deinit(gpa);
    try testing.expectNoErrors(tree);
    // 4 个 new；变量下标 2 处（$arr['c']、$dict[$key]）；属性形态 1 处
    try testing.expectTagCounts(tree, .{
        .expr_new = 4,
        .expr_array_dim_fetch = 2,
        .expr_property_fetch = 1,
    });
}

test "expr :: new :: new_variable 静态属性类名（对齐 uvs/new.test）" {
    const gpa = std.testing.allocator;
    var tree = try ast.Ast.parse(gpa,
        \\<?php
        \\$a = new Test::$className;
        \\$b = new $test::$className;
        \\$c = new $weird[0]->foo::$className;
        \\$d = new A::$A::$b;
    , testing.v84);
    defer tree.deinit(gpa);
    try testing.expectNoErrors(tree);
    // 4 个 static_property_fetch；链式 A::$A::$b 是嵌套（各计 1）
    try testing.expectTagCounts(tree, .{
        .expr_new = 4,
        .expr_static_property_fetch = 5,
        .expr_array_dim_fetch = 1,
        .expr_property_fetch = 1,
    });
}

test "uvs :: 变量语法统一化（字符串/常量/链式调用解引用，对齐 php-parser uvs）" {
    const gpa = std.testing.allocator;
    var tree = try ast.Ast.parse(gpa,
        \\<?php
        \\"string"->length();
        \\"foo{$bar}"[0];
        \\A::B[0];
        \\A::B::$c;
        \\A[0];
        \\id('var_dump')(1);
        \\'id'('var_dump');
        \\('i' . 'd')();
        \\isset(([0, 1] + [])[0]);
        \\isset(['a' => 'b']->a);
        \\isset("str"->a);
        \\'A'::$b;
        \\('A' . '')::$b;
        \\A::$A::$b;
        \\$x instanceof ('Foo' . $bar);
        \\__FUNCTION__[0];
    , testing.v84);
    defer tree.deinit(gpa);
    try testing.expectNoErrors(tree);
}

test "uvs :: global 非简单变量报错（对齐 uvs/globalNonSimpleVarError）" {
    const gpa = std.testing.allocator;
    var tree = try ast.Ast.parse(gpa, "<?php global $$foo->bar;", testing.v84);
    defer tree.deinit(gpa);
    // `global` 只接受简单变量；`$$foo->bar` 应被拒绝（收集式模型：errors 非空）
    try std.testing.expect(tree.errors.len > 0);
}

test "expr :: new :: new_variable nullsafe 属性与括号表达式（8.0+）" {
    const gpa = std.testing.allocator;
    var tree = try ast.Ast.parse(gpa,
        \\<?php
        \\$a = new $obj?->cls;
        \\$b = new ('Foo' . $bar);
        \\$c = new ('Foo' . $bar)($arg);
    , testing.v84);
    defer tree.deinit(gpa);
    try testing.expectNoErrors(tree);
    // ?-> 属性 1、括号内 concat 2、new 3
    try testing.expectTagCounts(tree, .{
        .expr_new = 3,
        .expr_nullsafe_property_fetch = 1,
        .expr_binary = 2,
    });
}

test "expr :: 三元 :: 完整形式与省略形式" {
    const gpa = std.testing.allocator;
    var tree = try ast.Ast.parse(gpa, "<?php $b ? $a : $c; $b ?: $c;", testing.v84);
    defer tree.deinit(gpa);
    try testing.expectNoErrors(tree);
    try testing.expectTagCounts(tree, .{ .expr_ternary = 2 });
}

test "expr :: null 合并 :: ?? 归为二元运算" {
    const gpa = std.testing.allocator;
    var tree = try ast.Ast.parse(gpa, "<?php $a ?? $b;", testing.v84);
    defer tree.deinit(gpa);
    try testing.expectNoErrors(tree);
    try testing.expectTagCounts(tree, .{ .expr_binary = 1 });
}

test "expr :: instanceof :: 产出专用节点" {
    const gpa = std.testing.allocator;
    var tree = try ast.Ast.parse(gpa, "<?php $x instanceof Foo;", testing.v84);
    defer tree.deinit(gpa);
    try testing.expectNoErrors(tree);
    try testing.expectTagCounts(tree, .{ .expr_instanceof = 1 });
}

test "expr :: 箭头函数与闭包 :: 两种匿名函数分别成节点" {
    const gpa = std.testing.allocator;
    var tree = try ast.Ast.parse(gpa,
        \\<?php
        \\function f($y) {
        \\    $fn = fn($p) => $p + 1;
        \\    $cl = function($p) use ($y) { return $p; };
        \\}
    , testing.v84);
    defer tree.deinit(gpa);
    try testing.expectNoErrors(tree);
    try testing.expectTagCounts(tree, .{
        .expr_arrow_function = 1,
        .expr_closure = 1,
    });
}

test "expr :: 静态成员 :: 常量/属性/方法三种访问" {
    const gpa = std.testing.allocator;
    var tree = try ast.Ast.parse(gpa,
        \\<?php
        \\Foo::BAR;
        \\Foo::$prop;
        \\Foo::method();
    , testing.v84);
    defer tree.deinit(gpa);
    try testing.expectNoErrors(tree);
    try testing.expectTagCounts(tree, .{
        .expr_class_const_fetch = 1,
        .expr_static_property_fetch = 1,
        .expr_static_call = 1,
    });
}

test "expr :: 静态成员名 :: 间接形态 `::$$b` / `::${'b'}` 归静态属性（截断族修复）" {
    const gpa = std.testing.allocator;
    // php.y static_member_prop_name = simple_variable：`A::$$b` 名字是变量 b，
    // `A::${'b'}` 名字是花括号表达式——二者均为静态属性、非类常量。
    var t = try ast.Ast.parse(gpa, "<?php A::$$b; A::${'b'};", testing.v84);
    defer t.deinit(gpa);
    try testing.expectNoErrors(t);
    try testing.expectTagCounts(t, .{
        .expr_static_property_fetch = 2,
        .expr_class_const_fetch = 0,
    });
    // 名形态：`$$b` 归为 expr_variable（变量链），`${'b'}` 归为花括号内的表达式
    try testing.expectTagCounts(t, .{ .expr_variable = 1 });
}

test "expr :: `::$` 到 EOF :: 只报一条（recovery[14] 形态，不双报）" {
    const gpa = std.testing.allocator;
    var t = try ast.Ast.parse(gpa, "<?php Foo::$", testing.v85);
    defer t.deinit(gpa);
    // parseVariableName 报 expected_variable 后不再补报 expected_token（同 token）
    try std.testing.expectEqual(@as(usize, 1), testing.countError(&t, .expected_variable));
    try std.testing.expectEqual(@as(usize, 0), testing.countError(&t, .expected_token));
}

test "expr :: `::` 后缺成员名 :: 报诊断并恢复（recovery[19] 形态）" {
    const gpa = std.testing.allocator;
    var t = try ast.Ast.parse(gpa, "<?php foo(Bar::);", testing.v85);
    defer t.deinit(gpa);
    try std.testing.expect(t.errors.len > 0);
}

test "expr :: cast :: 关键字名大小写不敏感（`( VOID )` 合法，8.5 引入）" {
    const gpa = std.testing.allocator;
    var t = try ast.Ast.parse(gpa, "<?php (void)foo(); ( VOID ) foo(); (Int)$a;", testing.v85);
    defer t.deinit(gpa);
    try testing.expectNoErrors(t);
    try testing.expectTagCounts(t, .{ .expr_cast = 3 });
}

test "expr :: nullsafe :: 方法调用与属性访问" {
    const gpa = std.testing.allocator;
    var tree = try ast.Ast.parse(gpa, "<?php $obj?->m(); Foo?->prop;", testing.v84);
    defer tree.deinit(gpa);
    try testing.expectNoErrors(tree);
    try testing.expectTagCounts(tree, .{
        .expr_nullsafe_method_call = 1,
        .expr_nullsafe_property_fetch = 1,
    });
}

test "expr :: isset/empty :: 各成节点并承载变量列表" {
    const gpa = std.testing.allocator;
    var tree = try ast.Ast.parse(gpa, "<?php isset($a, $b); empty($c);", testing.v84);
    defer tree.deinit(gpa);
    try testing.expectNoErrors(tree);
    try testing.expectTagCounts(tree, .{ .expr_isset = 1, .expr_empty = 1 });
}

test "expr :: list 解构 :: 与数组字面量同时出现" {
    const gpa = std.testing.allocator;
    var tree = try ast.Ast.parse(gpa, "<?php list($m, $n) = [1, 2];", testing.v84);
    defer tree.deinit(gpa);
    try testing.expectNoErrors(tree);
    try testing.expectTagCounts(tree, .{ .expr_list = 1, .expr_array = 1 });
}

test "expr :: clone :: 产出 expr_clone" {
    const gpa = std.testing.allocator;
    var tree = try ast.Ast.parse(gpa, "<?php clone $obj;", testing.v84);
    defer tree.deinit(gpa);
    try testing.expectNoErrors(tree);
    try testing.expectTagCounts(tree, .{ .expr_clone = 1 });
}

test "expr :: yield :: 带键值产出 expr_yield" {
    const gpa = std.testing.allocator;
    var tree = try ast.Ast.parse(gpa,
        \\<?php
        \\function g() { yield $k => $v; }
    , testing.v84);
    defer tree.deinit(gpa);
    try testing.expectNoErrors(tree);
    try testing.expectTagCounts(tree, .{ .expr_yield = 1 });
}

test "expr :: include/require :: 四种形式均归 expr_include" {
    const gpa = std.testing.allocator;
    var tree = try ast.Ast.parse(gpa,
        \\<?php
        \\include 'a.php';
        \\include_once 'b.php';
        \\require 'c.php';
        \\require_once 'd.php';
    , testing.v84);
    defer tree.deinit(gpa);
    try testing.expectNoErrors(tree);
    try testing.expectTagCounts(tree, .{ .expr_include = 4 });
}

test "expr :: 类型转换 :: (int)$v 产出 expr_cast" {
    const gpa = std.testing.allocator;
    var tree = try ast.Ast.parse(gpa, "<?php (int)$v;", testing.v84);
    defer tree.deinit(gpa);
    try testing.expectNoErrors(tree);
    try testing.expectTagCounts(tree, .{ .expr_cast = 1 });
}

test "expr :: 自增自减 :: 后置形式分别成节点" {
    const gpa = std.testing.allocator;
    var tree = try ast.Ast.parse(gpa, "<?php $i++; $j--;", testing.v84);
    defer tree.deinit(gpa);
    try testing.expectNoErrors(tree);
    try testing.expectTagCounts(tree, .{ .expr_post_inc = 1, .expr_post_dec = 1 });
}

test "expr :: 逻辑运算符 :: and/or/xor 归为二元" {
    const gpa = std.testing.allocator;
    var tree = try ast.Ast.parse(gpa, "<?php $t = true and false or true xor false;", testing.v84);
    defer tree.deinit(gpa);
    try testing.expectNoErrors(tree);
    // and / or / xor 三个运算符均产出 expr_binary
    try testing.expectTagCounts(tree, .{ .expr_binary = 3 });
}

test "expr :: spaceship :: <=> 归为二元" {
    // 回归：`<=>` 此前完全未实现，`$a <=> $b` 产生 stmt_error。
    const gpa = std.testing.allocator;
    var tree = try ast.Ast.parse(gpa, "<?php $a <=> $b;", testing.v84);
    defer tree.deinit(gpa);
    try testing.expectNoErrors(tree);
    try testing.expectTagCounts(tree, .{ .expr_binary = 1 });

    const bin = testing.firstNode(tree, .expr_binary) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("<=>", tree.tokenSlice(tree.nodeMainToken(bin)));
}

test "expr :: 幂优先于一元负号 :: -$a ** 2 为 -($a ** 2)" {
    // 回归：此前 `-$a ** 2` 被解析为 `(-$a) ** 2`，与 PHP 语义相反
    //（PHP 中 `**` 优先级高于一元 `-`，`-2 ** 2` 为 `-4`）。
    const gpa = std.testing.allocator;
    var tree = try ast.Ast.parse(gpa, "<?php -$a ** 2;", testing.v84);
    defer tree.deinit(gpa);
    try testing.expectNoErrors(tree);

    const unary = testing.firstNode(tree, .expr_unary) orelse return error.TestUnexpectedResult;
    const pow = tree.nodeData(unary).node;
    try std.testing.expectEqual(.expr_binary, tree.nodeTag(pow));
    try std.testing.expectEqualStrings("**", tree.tokenSlice(tree.nodeMainToken(pow)));
}

test "expr :: static 匿名函数 :: 与 static:: 区分" {
    // 回归：`$f = static function () {};` 此前解析失败（stmt_error + 误当函数声明）。
    const gpa = std.testing.allocator;
    var tree = try ast.Ast.parse(gpa,
        \\<?php
        \\$f = static function () {};
        \\$g = static::class;
    , testing.v84);
    defer tree.deinit(gpa);
    try testing.expectNoErrors(tree);
    try testing.expectTagCounts(tree, .{
        .expr_closure = 1,
        .expr_class_const_fetch = 1,
        .stmt_error = 0,
    });
}

test "expr :: 移位运算 :: 归为二元" {
    const gpa = std.testing.allocator;
    var tree = try ast.Ast.parse(gpa, "<?php $s = 1 << 2;", testing.v84);
    defer tree.deinit(gpa);
    try testing.expectNoErrors(tree);
    try testing.expectTagCounts(tree, .{ .expr_binary = 1 });
}

test "expr :: 魔术常量 :: __LINE__ 等归为 expr_magic_const" {
    const gpa = std.testing.allocator;
    var tree = try ast.Ast.parse(gpa,
        \\<?php
        \\$a = __LINE__;
        \\$b = __DIR__;
        \\$c = __FUNCTION__;
    , testing.v84);
    defer tree.deinit(gpa);
    try testing.expectNoErrors(tree);
    try testing.expectTagCounts(tree, .{ .expr_magic_const = 3 });
}

test "expr :: 插值字符串 :: 双引号含变量与花括号表达式" {
    const gpa = std.testing.allocator;
    var tree = try ast.Ast.parse(gpa,
        \\<?php
        \\$name = "hi $x and {$y->z}";
    , testing.v84);
    defer tree.deinit(gpa);
    try testing.expectNoErrors(tree);
    try testing.expectTagCounts(tree, .{
        .expr_encapsed = 1,
        // $name（赋值左侧）、$x（简单插值）、$y（{$y->z} 的变量部分）共 3 个
        .expr_variable = 3,
    });
    // 字面片段被插值点切分为多段
    try std.testing.expect(testing.countTag(tree, .expr_string_part) >= 2);
}

test "expr :: heredoc :: flexible 缩进结束符与数组元素（对齐 flexibleDocString.test）" {
    const gpa = std.testing.allocator;
    var tree = try ast.Ast.parse(gpa,
        \\<?php
        \\$ary = [
        \\    <<<FOO
        \\Test
        \\FOO,
        \\    <<<'BAR'
        \\    Test
        \\    BAR,
        \\];
        \\<<<'END'
        \\ END;
        \\<<<END
        \\
        \\  END;
    , testing.v85);
    defer tree.deinit(gpa);
    try testing.expectNoErrors(tree);
    try testing.expectTagCounts(tree, .{ .expr_encapsed = 4 });
}

test "expr :: encapsed :: 变量偏移全形态（对齐 encapsedString/encapsedNegVarOffset.test）" {
    const gpa = std.testing.allocator;
    var tree = try ast.Ast.parse(gpa,
        \\<?php
        \\"$A[0x0]";
        \\"$A[0b0]";
        \\"$A[000]";
        \\"$A[1234]";
        \\"$A[$B]";
        \\"{$$A}[B]";
        \\b"$A";
    , testing.v85);
    defer tree.deinit(gpa);
    try testing.expectNoErrors(tree);
    try testing.expectTagCounts(tree, .{ .expr_encapsed = 7, .expr_array_dim_fetch = 5 });
}

test "expr :: heredoc :: 启用插值" {
    const gpa = std.testing.allocator;
    var tree = try ast.Ast.parse(gpa,
        \\<?php
        \\$s = <<<EOT
        \\text $v end
        \\EOT;
    , testing.v84);
    defer tree.deinit(gpa);
    try testing.expectNoErrors(tree);
    // $s（赋值左侧）与 $v（插值）共 2 个
    try testing.expectTagCounts(tree, .{ .expr_encapsed = 1, .expr_variable = 2 });
}

test "expr :: nowdoc :: 关闭插值且不含变量节点" {
    const gpa = std.testing.allocator;
    // 用函数包住，避免领先的 `$s` 被计入变量
    var tree = try ast.Ast.parse(gpa,
        \\<?php
        \\function f() {
        \\    return <<<'EOT'
        \\text $v end
        \\EOT;
        \\}
    , testing.v84);
    defer tree.deinit(gpa);
    try testing.expectNoErrors(tree);
    try testing.expectTagCounts(tree, .{
        .expr_encapsed = 1,
        .expr_string_part = 1,
        .expr_variable = 0,
    });
}

test "expr :: 限定名 :: 完全限定形式" {
    const gpa = std.testing.allocator;
    var tree = try ast.Ast.parse(gpa, "<?php new \\Foo\\Bar();", testing.v84);
    defer tree.deinit(gpa);
    try testing.expectNoErrors(tree);
    try testing.expectTagCounts(tree, .{
        .name_fully_qualified = 1,
        // 回归：FQ 名曾只吃前导 `\`，Foo\Bar 残留被误当函数调用（func_call>0 即失败）
        .expr_func_call = 0,
    });
}

test "expr :: 限定名 :: 相对形式 namespace\\Foo" {
    const gpa = std.testing.allocator;
    var tree = try ast.Ast.parse(gpa, "<?php new namespace\\Foo\\Bar();", testing.v84);
    defer tree.deinit(gpa);
    try testing.expectNoErrors(tree);
    try testing.expectTagCounts(tree, .{ .name_relative = 1 });
}

test "expr :: 限定名 :: 变量形式（动态类名）" {
    const gpa = std.testing.allocator;
    var tree = try ast.Ast.parse(gpa, "<?php new $cls();", testing.v84);
    defer tree.deinit(gpa);
    try testing.expectNoErrors(tree);
    try testing.expectTagCounts(tree, .{ .name_var_like = 1 });
}
