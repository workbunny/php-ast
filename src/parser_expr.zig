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
};

pub const ArrayItemComponents = struct {
    key: OptionalIndex,
    unpack: bool,
};

pub const TernaryComponents = struct {
    then: OptionalIndex,
    else_b: Index,
};

pub const ArrowFunctionComponents = struct {
    params: SubRange,
    ret: OptionalIndex,
    body: Index,
};

pub const ClosureComponents = struct {
    params: SubRange,
    uses: SubRange,
    ret: OptionalIndex,
    body: Index,
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
    if (p.tokTag() != .identifier) return false;
    const s = p.tokSlice();
    const casts = [_][]const u8{
        "int", "integer", "float", "double", "real", "string",
        "binary", "array", "object", "bool", "boolean", "unset", "void",
    };
    for (casts) |c| {
        if (std.mem.eql(u8, c, s)) return true;
    }
    return false;
}

pub fn parseName(p: *Parser) ast.ParseError!?Index {
    const first_tag = p.tokTag();
    const first = p.nextToken();
    var last = first;
    while (p.tokTag() == .backslash) {
        _ = p.nextToken();
        if (p.tokTag() == .identifier or p.tokTag() == .variable) {
            last = p.nextToken();
        }
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
                // `(void)` 强转为 8.5 引入
                if (std.mem.eql(u8, "void", cast_name)) {
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
            const op = p.nextToken();
            const operand = (try parseUnary(p)) orelse return null;
            // 8.5 起 `clone` 可作为函数，支持 `clone($obj, withProperties: [...])` 重设（只读）属性
            var with_props: OptionalIndex = .none;
            if (p.tokTag() == .comma) {
                _ = p.nextToken();
                if (!p.isSoftKw("withProperties")) p.warn(.expected_identifier);
                _ = p.nextToken();
                _ = p.eatToken(.colon);
                const wp = (try parseUnary(p)) orelse return null;
                with_props = OptionalIndex.fromIndex(wp);
            }
            const idx = (try p.addNode(.{
                .tag = .expr_clone,
                .main_token = op,
                .data = .{ .node_and_opt_node = .{ operand, with_props } },
            })) orelse unreachable;
            if (with_props != .none) {
                p.node_versions.items[@intFromEnum(idx)] = PhpVersion.fromComponents(8, 5);
            }
            return idx;
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
                const name = (try parseName(p)) orelse return null;
                e = (try p.addNode(.{
                    .tag = .expr_property_fetch,
                    .main_token = p.nodeMainToken(e),
                    .data = .{ .node_and_node = .{ e, name } },
                })) orelse unreachable;
            },
            .nullsafe_arrow => {
                _ = p.nextToken();
                const name = (try parseName(p)) orelse return null;
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
                const name = (try parseName(p)) orelse return null;
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
                } else if (tokenTagAt(p, name_main) == .variable) {
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
        .kw_true, .kw_false, .kw_null => {
            const t = p.nextToken();
            const name = (try p.addNode(.{ .tag = .name, .main_token = t, .data = .{ .token = t } })) orelse unreachable;
            return (try p.addNode(.{ .tag = .expr_const_fetch, .main_token = t, .data = .{ .node = name } })) orelse unreachable;
        },
        .backtick => {
            const open = p.nextToken();
            const content = p.expectToken(.string_literal) orelse return null;
            _ = p.expectToken(.backtick);
            return (try p.addNode(.{
                .tag = .expr_shell_exec,
                .main_token = open,
                .data = .{ .token = content },
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
        .identifier => {
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
        },
        .kw_new => {
            const t = p.nextToken();
            var name: Index = undefined;
            if (p.tokTag() == .kw_class) {
                // 匿名类：`new class(...) [extends X] [implements Y] { ... }`
                name = (try decl.parseAnonymousClass(p, p.emptySubRange())) orelse return null;
            } else {
                name = (try parseName(p)) orelse return null;
            }
            var args: ListRange = p.emptyRange();
            if (p.tokTag() == .lparen) {
                args = try parseArgs(p);
            }
            const extra = try p.addExtra(NewComponents{ .name = name, .args = .{ .start = args.start, .end = args.end } });
            const idx = (try p.addNode(.{
                .tag = .expr_new,
               
 .main_token = t,
                .data = .{ .extra_and_node = .{ extra, name } },
            })) orelse unreachable;
            // 无括号 `new`（如 `new X->method()`）是 PHP 8.4 引入；有括号形式是基础语法。
            // 同 tag 多版本，无法由 tag 区分，故在此覆盖。
            if (args.start == args.end) {
                p.node_versions.items[@intFromEnum(idx)] = PhpVersion.fromComponents(8, 4);
            }
            return idx;
        },
        .lbracket => {
            const t = p.nextToken();
            var items = try std.ArrayList(Index).initCapacity(p.gpa, 0);
            defer items.deinit(p.gpa);
            while (p.tokTag() != .rbracket and p.tokTag() != .eof) {
                var unpack = false;
                if (p.tokTag() == .ellipsis) {
                    _ = p.nextToken();
                    unpack = true;
                }
                const val0 = (try parseExpr(p)) orelse return null;
                var key: OptionalIndex = .none;
                var val: Index = val0;
                if (!unpack and p.tokTag() == .double_arrow) {
                    _ = p.nextToken();
                    const v2 = (try parseExpr(p)) orelse return null;
                    key = OptionalIndex.fromIndex(val0);
                    val = v2;
                }
                const extra = try p.addExtra(ArrayItemComponents{ .key = key, .unpack = unpack });
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
                break;
            }
            _ = p.expectToken(.rbracket);
            const lr = try p.addNodeList(items.items);
            return (try p.addNode(.{
                .tag = .expr_array,
                .main_token = t,
                .data = .{ .extra_range = .{ .start = lr.start, .end = lr.end } },
            })) orelse unreachable;
        },
        .lparen => {
            _ = p.nextToken();
            const e = (try parseExpr(p)) orelse return null;
            _ = p.expectToken(.rparen);
            return e;
        },
        .kw_match => return parseMatch(p),
        .kw_fn => return parseArrowFunction(p),
        .kw_function => return parseClosure(p),
        .kw_static => {
            // `static function () {}` 静态匿名函数；否则 `static` 作为类名走后缀
            // （`static::method()`、`static::$prop` 等）。
            const save = p.tok_i;
            _ = p.nextToken();
            if (p.tokTag() == .kw_function) {
                return parseClosure(p);
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
            const kw = p.nextToken();
            var operand: OptionalIndex = .none;
            if (p.tokTag() == .lparen) {
                _ = p.nextToken();
                if (p.tokTag() != .rparen) {
                    const o = (try parseExpr(p)) orelse return null;
                    operand = OptionalIndex.fromIndex(o);
                }
                _ = p.expectToken(.rparen);
            }
            return (try p.addNode(.{
                .tag = .expr_exit,
                .main_token = kw,
                .data = .{ .opt_node = operand },
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
            while (p.tokTag() != .rparen and p.tokTag() != .eof) {
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
            var list = try std.ArrayList(Index).initCapacity(p.gpa, 0);
            defer list.deinit(p.gpa);
            while (p.tokTag() != .rparen and p.tokTag() != .eof) {
                if (p.tokTag() == .comma) {
                    _ = p.nextToken();
                    continue;
                }
                var unpack = false;
                if (p.tokTag() == .ellipsis) {
                    _ = p.nextToken();
                    unpack = true;
                }
                const val0 = (try parseExpr(p)) orelse return null;
                var key: OptionalIndex = .none;
                var val: Index = val0;
                if (!unpack and p.tokTag() == .double_arrow) {
                    _ = p.nextToken();
                    const v2 = (try parseExpr(p)) orelse return null;
                    key = OptionalIndex.fromIndex(val0);
                    val = v2;
                }
                const extra = try p.addExtra(ArrayItemComponents{ .key = key, .unpack = unpack });
                const item = (try p.addNode(.{
                    .tag = .expr_array_item,
                    .main_token = p.nodeMainToken(val),
                    .data = .{ .node_and_extra = .{ val, extra } },
                })) orelse unreachable;
                try list.append(p.gpa, item);
                if (p.tokTag() == .comma) {
                    _ = p.nextToken();
                    continue;
                }
                break;
            }
            _ = p.expectToken(.rparen);
            const lr = try p.addNodeList(list.items);
            return (try p.addNode(.{
                .tag = .expr_list,
                .main_token = kw,
                .data = .{ .extra_range = .{ .start = lr.start, .end = lr.end } },
            })) orelse unreachable;
        },
        else => {
            p.warn(ast.Error.Tag.expected_expr);
            return null;
        },
    }
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
        var unpack = false;
        if (p.tokTag() == .ellipsis) {
            _ = p.nextToken();
            unpack = true;
        }
        var val = (try parseExpr(p)) orelse return args;
        var key: OptionalTokenIndex = .none;
        if (!unpack and p.tokTag() == .colon) {
            if (tokenTagAt(p, p.nodeMainToken(val)) == .identifier) {
                key = OptionalTokenIndex.fromToken(p.nodeMainToken(val));
                _ = p.nextToken();
                val = (try parseExpr(p)) orelse return args;
            }
        }
        const extra = try p.addExtra(ArgumentComponents{ .key = key, .unpack = unpack });
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
        var is_default = false;
        var first_tok: TokenIndex = 0;
        var exprs: ListRange = p.emptyRange();
        if (p.tokTag() == .kw_default) {
            _ = p.nextToken();
            is_default = true;
        } else {
            var list = try std.ArrayList(Index).initCapacity(p.gpa, 0);
            defer list.deinit(p.gpa);
            while (true) {
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
    if (p.tokTag() == .semicolon or p.tokTag() == .eof or p.tokTag() == .comma or p.tokTag() == .rparen) {
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

fn parseArrowFunction(p: *Parser) ast.ParseError!?Index {
    const kw = p.nextToken();
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
    const extra = try p.addExtra(ArrowFunctionComponents{ .params = params, .ret = ret, .body = body });
    return (try p.addNode(.{
        .tag = .expr_arrow_function,
        .main_token = kw,
        .data = .{ .extra = extra },
    })) orelse unreachable;
}

fn parseClosure(p: *Parser) ast.ParseError!?Index {
    const kw = p.nextToken();
    const pl = try decl.parseParamList(p);
    const params = pl orelse p.emptySubRange();
    var uses: SubRange = p.emptySubRange();
    if (p.tokTag() == .kw_use) {
        _ = p.nextToken();
        _ = p.expectToken(.lparen);
        var ulist = try std.ArrayList(ExtraIndex).initCapacity(p.gpa, 0);
        defer ulist.deinit(p.gpa);
        while (p.tokTag() != .rparen and p.tokTag() != .eof) {
            var by_ref = false;
            if (p.tokTag() == .ampersand) {
                _ = p.nextToken();
                by_ref = true;
            }
            const name_tok = p.expectToken(.variable) orelse break;
            const extra = try p.addExtra(ClosureUseComponents{ .name = name_tok, .by_ref = by_ref });
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
    const extra = try p.addExtra(ClosureComponents{ .params = params, .uses = uses, .ret = ret, .body = body });
    return (try p.addNode(.{
        .tag = .expr_closure,
        .main_token = kw,
        .data = .{ .extra = extra },
    })) orelse unreachable;
}

fn isAssignmentOp(t: Token.Tag) bool {
    return switch (t) {
        .equals, .plus_equal, .minus_equal, .asterisk_equal, .slash_equal, .percent_equal,
        .dot_equal, .ampersand_equal, .pipe_equal, .caret_equal, .double_asterisk_equal => true,
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
    // 注意：`$o->m()` 的 callee 本身也是一次属性取回，故 expr_property_fetch 为 2
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

test "expr :: exit/die :: 两种关键字均归为 expr_exit" {
    const gpa = std.testing.allocator;
    var tree = try ast.Ast.parse(gpa, "<?php exit; die(1);", testing.v84);
    defer tree.deinit(gpa);
    try testing.expectNoErrors(tree);
    try testing.expectTagCounts(tree, .{ .expr_exit = 2 });
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
    try testing.expectTagCounts(tree, .{ .name_fully_qualified = 1 });
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
