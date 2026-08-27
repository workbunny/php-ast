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

const expr = @import("parser_expr.zig");

/// 泛型类型 `Foo<int>` / `list<int>` / `array<int, int>`：承载基础类型与类型实参列表。
pub const GenericTypeComponents = struct {
    base: Index,
    args: SubRange,
};

pub fn isTypeStart(p: *Parser) bool {
    return switch (p.tokTag()) {
        .question, .lparen, .backslash, .kw_namespace, .identifier, .kw_true, .kw_false, .kw_null, .kw_static, .kw_list => true,
        else => false,
    };
}

pub fn parseType(p: *Parser) ast.ParseError!?Index {
    if (p.tokTag() == .question) {
        const q = p.nextToken();
        const inner = (try parseTypeUnion(p)) orelse return null;
        return (try p.addNode(.{ .tag = .type_nullable, .main_token = q, .data = .{ .node = inner } })) orelse unreachable;
    }
    return parseTypeUnion(p);
}

pub fn parseTypeUnion(p: *Parser) ast.ParseError!?Index {
    var left = (try parseTypeIntersect(p)) orelse return null;
    while (p.tokTag() == .pipe) {
        const op = p.nextToken();
        const right = (try parseTypeUnion(p)) orelse return null;
        left = (try p.addNode(.{ .tag = .type_union, .main_token = op, .data = .{ .node_and_node = .{ left, right } } })) orelse unreachable;
    }
    return left;
}

pub fn parseTypeIntersect(p: *Parser) ast.ParseError!?Index {
    var left = (try parseTypeAtom(p)) orelse return null;
    while (p.tokTag() == .ampersand) {
        const save = p.tok_i;
        _ = p.nextToken();
        if (!isTypeStart(p)) {
            p.tok_i = save;
            break;
        }
        const right = (try parseTypeAtom(p)) orelse {
            p.tok_i = save;
            break;
        };
        left = (try p.addNode(.{ .tag = .type_intersection, .main_token = save, .data = .{ .node_and_node = .{ left, right } } })) orelse unreachable;
    }
    return left;
}

pub fn parseTypeAtom(p: *Parser) ast.ParseError!?Index {
    var base: Index = undefined;
    // 括号分组仅出现于 DNF，用于包围交集类型 `(A&B)`；php-ast 不引入独立节点，
    // 与 PHP-Parser 行为一致——括号仅改变优先级，类型节点直接复用内部类型。
    if (p.tokTag() == .lparen) {
        _ = p.nextToken();
        const inner = (try parseTypeUnion(p)) orelse {
            p.warn(ast.Error.Tag.expected_token);
            return null;
        };
        _ = p.eatToken(.rparen);
        base = inner;
    } else {
        base = (try parseTypeBase(p)) orelse return null;
    }
    var result = base;

    // 泛型后缀：`Foo<int>` / `list<int>` / `array<int, int>`
    if (p.tokTag() == .less_than) {
        const args = try parseTypeArgs(p) orelse return null;
        const extra = try p.addExtra(GenericTypeComponents{
            .base = base,
            .args = .{ .start = args.start, .end = args.end },
        });
        result = (try p.addNode(.{
            .tag = .type_generic,
            .main_token = p.nodeMainToken(base),
            .data = .{ .extra_and_node = .{ extra, base } },
        })) orelse unreachable;
    }

    // 数组后缀：`T[]` / `T[][]`（php-ast 的 `Type\Array_`）
    while (p.tokTag() == .lbracket) {
        _ = p.nextToken();
        _ = p.eatToken(.rbracket);
        result = (try p.addNode(.{
            .tag = .type_array_of,
            .main_token = p.nodeMainToken(result),
            .data = .{ .node = result },
        })) orelse unreachable;
    }
    return result;
}

/// 解析单一「原子」类型：伪类型、关键字类型、名字类型（不含泛型/数组后缀）。
fn parseTypeBase(p: *Parser) ast.ParseError!?Index {
    const t = p.tokTag();
    if (t == .kw_static) {
        const tok = p.nextToken();
        return (try p.addNode(.{ .tag = .type_static, .main_token = tok, .data = .{ .token = tok } })) orelse unreachable;
    }
    if (t == .kw_true or t == .kw_false or t == .kw_null) {
        const tok = p.nextToken();
        const name = (try p.addNode(.{ .tag = .name, .main_token = tok, .data = .{ .token = tok } })) orelse unreachable;
        return (try p.addNode(.{ .tag = .type_name, .main_token = tok, .data = .{ .node = name } })) orelse unreachable;
    }
    if (t == .identifier or t == .backslash or t == .kw_namespace or t == .kw_list) {
        // 伪类型 self / parent：直接记为专用节点，与 PHP-Parser 的 Type\Self_/Parent_ 对齐。
        if (t == .identifier) {
            if (p.isSoftKw("self")) {
                const tok = p.nextToken();
                return (try p.addNode(.{ .tag = .type_self, .main_token = tok, .data = .{ .token = tok } })) orelse unreachable;
            }
            if (p.isSoftKw("parent")) {
                const tok = p.nextToken();
                return (try p.addNode(.{ .tag = .type_parent, .main_token = tok, .data = .{ .token = tok } })) orelse unreachable;
            }
        }
        // 其余（callable/iterable/void/never/mixed/object/resource/list/array/class 等）按名字类型承载。
        const name = (try expr.parseName(p)) orelse return null;
        return (try p.addNode(.{ .tag = .type_name, .main_token = p.nodeMainToken(name), .data = .{ .node = name } })) orelse unreachable;
    }
    p.warn(ast.Error.Tag.expected_token);
    return null;
}

/// 解析泛型实参列表 `<T1, T2, ...>`，返回实参的 `ListRange`。
fn parseTypeArgs(p: *Parser) ast.ParseError!?ListRange {
    _ = p.nextToken(); // 消费 `<`
    var args = try std.ArrayList(Index).initCapacity(p.gpa, 0);
    defer args.deinit(p.gpa);
    while (p.tokTag() != .greater_than and p.tokTag() != .eof) {
        const tp = (try parseType(p)) orelse return null;
        try args.append(p.gpa, tp);
        if (p.tokTag() == .comma) _ = p.nextToken();
        if (p.tokTag() == .question) _ = p.nextToken(); // 容错：`Foo<?T>`
    }
    _ = p.eatToken(.greater_than);
    return try p.addNodeList(args.items);
}
