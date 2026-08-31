//! AST 定义与查询入口。布局参照 `std.zig.Ast`（SoA + 索引平板）：
//! - `nodes` 为扁平 `Node` 数组，节点间以 `Index` 互相引用而非指针；每个节点仅 3 字段。
//! - 超过 2 个直接子节点的负载序列化进 `extra_data`（`u32` 大板），节点 `data` 仅存 `ExtraIndex`。
//! - `tokens` 与 `nodes` 分离存储。
//!
//! 内存由调用方经 `parse(gpa, ...)` 提供，统一用 `deinit` 释放；位置信息不冗余存储，
//! 行/列经 `tokenLocation` 按需从 `main_token` 派生。
const std = @import("std");
const Token = @import("token.zig").Token;
const PhpVersion = @import("version.zig").PhpVersion;
const BASE_VERSION = @import("version.zig").BASE_VERSION;
const Lexer = @import("lexer.zig").Lexer;
const parser = @import("parser.zig");
// 各 parser 子模块：取其定义的 `Components`（`extra_data` 的解码布局）。
// 这些模块反向导入本文件，构成 Zig 允许的循环导入；此处仅引用其类型，
// 不存在 comptime 求值环，可安全解析。
const stmt = @import("parser_stmt.zig");
const decl = @import("parser_decl.zig");
const expr = @import("parser_expr.zig");
const types = @import("parser_type.zig");
const testing = @import("testing.zig");

/// 解析失败仅可能是内存不足；语法错误不在此列，而是收集进 `Ast.errors`。
pub const ParseError = std.mem.Allocator.Error;

/// 源码内的字节偏移。
pub const ByteOffset = u32;

/// `tokens` 数组中的下标。词法结果以 `Token.TokenList.Slice` 持有。
pub const TokenIndex = u32;

/// 可选 token 下标，用哨兵值 `none`（最大 u32）编码「无」，
/// 避免 `?TokenIndex` 作为联合字段撑大 `Node`。读取用 `unwrap`。
pub const OptionalTokenIndex = enum(u32) {
    none = std.math.maxInt(u32),
    _,
    pub fn unwrap(self: OptionalTokenIndex) ?TokenIndex {
        return if (self == .none) null else @intFromEnum(self);
    }
    pub fn fromToken(ti: TokenIndex) OptionalTokenIndex {
        return @enumFromInt(ti);
    }
};

/// `extra_data` 大板中的下标，指向某段序列化负载的起点。
pub const ExtraIndex = enum(u32) {
    zero = 0,
    _,
};

/// 节点句柄，即 `nodes` 数组下标。树中节点相互引用，`root` 为根节点下标。
pub const Index = enum(u32) {
    root = 0,
    _,
};

/// 可选节点下标，哨兵值 `none`（最大 u32）编码「无」。
pub const OptionalIndex = enum(u32) {
    none = std.math.maxInt(u32),
    _,
    pub fn unwrap(self: OptionalIndex) ?Index {
        return if (self == .none) null else @enumFromInt(@intFromEnum(self));
    }
    pub fn fromIndex(n: Index) OptionalIndex {
        return @enumFromInt(@intFromEnum(n));
    }
};

/// 一段可选节点下标区间，用于在 `extra_data` 中表示「无节点」（空区间）。
pub const SubRange = struct {
    start: ExtraIndex,
    end: ExtraIndex,
};

/// 一段节点下标区间，连续存放于 `extra_data`（通常为某个子节点列表）。
pub const ListRange = struct {
    start: ExtraIndex,
    end: ExtraIndex,
};

/// 一条诊断信息（解析错误）。错误不立即中止解析，而是累计后随 AST 一并返回
/// （多错误收集，便于编辑器/lint 一次取得全部诊断）。
pub const Error = struct {
    tag: Error.Tag,
    token: TokenIndex,
    /// 仅 `unsupported_version` 使用：该节点语法要求的 PHP 版本；
    /// 其余错误恒为 `BASE_VERSION`(id=0)，读取无意义。
    required: PhpVersion,

    /// 把错误渲染成可读文案。对 `unsupported_version` 写明「该语法要求的版本」
    /// 与「parse 时指定的目标版本」，下游据此即可定位用错了哪一版语法；
    /// 其余错误仅给出其 `Tag` 名。`buf` 由调用方提供，返回其有效切片。
    pub fn format(self: Error, tree: *const Ast, buf: []u8) []const u8 {
        if (self.tag == .unsupported_version) {
            const r = self.required;
            const t = tree.version;
            return std.fmt.bufPrint(buf,
                "node syntax requires PHP {}.{} but target is {}.{}",
                .{
                    r.id / 10000,
                    (r.id % 10000) / 100,
                    t.id / 10000,
                    (t.id % 10000) / 100,
                },
            ) catch "unsupported version";
        }
        return std.fmt.bufPrint(buf, "{s}", .{@tagName(self.tag)}) catch "parse error";
    }

    /// 错误种类枚举。每个变体对应一种具体的语法期望失败。
    pub const Tag = enum {
        expected_token,
        expected_semi,
        expected_expr,
        expected_variable,
        expected_identifier,
        expected_lbrace,
        expected_rbrace,
        expected_rparen,
        expected_lbracket,
        unexpected_eof,
        lex_error,
        /// 语法构造的引入版本高于 `parse` 指定的目标版本（版本门控）。
        unsupported_version,
    };
};

/// 一个 AST 节点：扁平结构，`tag` 决定种类，`main_token` 为代表性 token（派生位置），
/// `data` 为小联合，最多承载 2 个直接子引用；更长负载存放于 `extra_data`。
pub const Node = struct {
    tag: Tag,
    main_token: TokenIndex,
    data: Data,

    /// 全部节点种类。每条 PHP 语法构造对应一个 `Tag`，遍历时用于 `switch` 穷举。
    pub const Tag = enum {
        root,

        // 语句
        stmt_expression,
        stmt_echo,
        stmt_if,
        stmt_while,
        stmt_for,
        stmt_foreach,
        stmt_function,
        stmt_class,
        stmt_enum,
        stmt_interface,
        stmt_trait,
        stmt_case,
        stmt_property,
        property_hook,
        stmt_namespace,
        stmt_return,
        stmt_block,
        stmt_do,
        stmt_break,
        stmt_continue,
        stmt_switch,
        stmt_switch_case,
        stmt_default,
        stmt_throw,
        stmt_try,
        stmt_catch,
        stmt_const,
        const_decl,
        stmt_use,
        use_use,
        stmt_group_use,
        stmt_trait_use,
        trait_use_adaptation_alias,
        trait_use_adaptation_precedence,
        stmt_declare,
        declare_declare,
        stmt_goto,
        stmt_label,
        stmt_global,
        stmt_static,
        static_var,
        stmt_unset,
        stmt_halt,
        inline_html,
        stmt_nop,
        stmt_method,
        stmt_class_const,
        stmt_error,

        // 表达式
        expr_variable,
        expr_int,
        expr_float,
        expr_string,
        expr_const_fetch,
        expr_binary,
        expr_assign,
        expr_assign_op,
        expr_assign_ref,
        expr_unary,
        expr_array,
        expr_array_item,
        expr_array_dim_fetch,
        expr_func_call,
        expr_new,
        expr_property_fetch,
        expr_static_property_fetch,
        expr_class_const_fetch,
        expr_static_call,
        expr_method_call,
        expr_nullsafe_property_fetch,
        expr_nullsafe_method_call,
        expr_match,
        expr_match_arm,
        expr_first_class_callable,
        expr_closure,
        expr_arrow_function,
        expr_clone,
        expr_pipe,
        expr_isset,
        expr_empty,
        expr_eval,
        expr_exit,
        expr_include,
        expr_instanceof,
        expr_list,
        expr_ternary,
        expr_throw,
        expr_print,
        expr_shell_exec,
        expr_yield,
        expr_yield_from,
        expr_error_suppress,
        expr_post_inc,
        expr_post_dec,
        expr_cast,
        expr_argument,
        expr_encapsed,
        expr_string_part,
        expr_magic_const,

        // 杂项
        name,
        name_fully_qualified,
        name_relative,
        name_var_like,
        param,
        type_name,
        type_nullable,
        type_union,
        type_intersection,
        type_self,
        type_parent,
        type_static,
        type_array_of,
        type_generic,
        attribute,
        attr_group,
    };

    /// 小联合：节点的直接子引用（0–2 个），字段均为索引或 token 下标，故 `Node` 定长。
    /// 命名：`node` 必含子节点；`opt_node` 可选；`token` 主 token 以外的次要 token；
    /// `extra`/`extra_range` 指向 `extra_data` 的负载/区间。
    pub const Data = union {
        node: Index,
        opt_node: OptionalIndex,
        token: TokenIndex,
        node_and_node: struct { Index, Index },
        opt_node_and_opt_node: struct { OptionalIndex, OptionalIndex },
        node_and_opt_node: struct { Index, OptionalIndex },
        opt_node_and_node: struct { OptionalIndex, Index },
        node_and_extra: struct { Index, ExtraIndex },
        node_and_range: struct { node: Index, range: SubRange },
        extra_and_node: struct { ExtraIndex, Index },
        extra_and_opt_node: struct { ExtraIndex, OptionalIndex },
        node_and_token: struct { Index, TokenIndex },
        token_and_node: struct { TokenIndex, Index },
        token_and_token: struct { TokenIndex, TokenIndex },
        opt_node_and_token: struct { OptionalIndex, TokenIndex },
        opt_token_and_node: struct { OptionalTokenIndex, Index },
        opt_token_and_opt_node: struct { OptionalTokenIndex, OptionalIndex },
        opt_token_and_opt_token: struct { OptionalTokenIndex, OptionalTokenIndex },
        extra_range: SubRange,
        extra: ExtraIndex,
    };
};

/// 节点数组（结构数组），`Node` 按 `Index` 顺序存放。
pub const NodeList = std.MultiArrayList(Node);

/// 源码中某位置的诊断信息（行/列），供错误渲染使用。
pub const Location = struct {
    line: usize,
    column: usize,
    line_start: usize,
    line_end: usize,
};

/// 返回某节点种类的「引入版本」。基础语法（≤ PHP 8.0）返回 `BASE_VERSION`(id=0)，
/// 表示不携带版本信息；8.1 及以后引入的节点类型记录对应版本。
///
/// 与「节点结构无关」的版本差异（如 `new` 的无括号形式，PHP 8.4）无法由 tag 区分，
/// 由解析点在 `addNode` 之后按需覆盖（见 parser_expr.zig 的 `expr_new`）。
pub fn tagVersion(tag: Node.Tag) PhpVersion {
    return switch (tag) {
        // 8.1 引入的新节点类型
        .stmt_enum, .stmt_case => PhpVersion.fromComponents(8, 1),
        .expr_first_class_callable => PhpVersion.fromComponents(8, 1),
        .type_intersection => PhpVersion.fromComponents(8, 1),
        // 属性钩子节点本身即 8.4 引入
        .property_hook => PhpVersion.fromComponents(8, 4),
        // 管道运算符为 8.5 引入（无括号 new 的 8.4 覆盖在解析点处理）
        .expr_pipe => PhpVersion.fromComponents(8, 5),
        // 其余节点默认基础语法；其 8.x 特例形式在解析点覆盖（如 expr_new 无括号=8.4）
        else => BASE_VERSION,
    };
}

/// `forEachChild` 的区间型重载：把 `extra_data` 中的节点索引区间逐个子节点发出。
fn emitRange(
    tree: Ast,
    range: SubRange,
    ctx: anytype,
    comptime onChild: fn (@TypeOf(ctx), Index) anyerror!void,
) !void {
    for (tree.extraDataSlice(range, Index)) |n| try onChild(ctx, n);
}

/// `forEachChild` 的可选节点重载：存在则发出，否则跳过。
fn emitOpt(
    opt: OptionalIndex,
    ctx: anytype,
    comptime onChild: fn (@TypeOf(ctx), Index) anyerror!void,
) !void {
    if (opt.unwrap()) |n| try onChild(ctx, n);
}

/// 沿子节点递归，把遇到的最小 token 下标写入 `first`。
/// 每个节点自身的主 token 也参与比较——子节点的主 token 可能小于父节点
/// （如 `expr_assign` 的主 token 是 `=`，而左值 `$a` 在它之前）。
fn scanFirstToken(tree: Ast, node: Index, first: *TokenIndex) void {
    const mt = tree.nodeMainToken(node);
    if (mt < first.*) first.* = mt;

    const Ctx = struct {
        tree: Ast,
        first: *TokenIndex,
        fn onChild(self: @This(), child: Index) !void {
            scanFirstToken(self.tree, child, self.first);
        }
    };
    tree.forEachChild(node, Ctx{ .tree = tree, .first = first }, Ctx.onChild) catch {};
}

/// 沿子节点递归，把遇到的最大 token 下标写入 `last`（逻辑同 `scanFirstToken`）。
/// 尾部定界符不是任何节点的子节点，故每层都要单独并入，否则含块的复合语句
/// 会在 `}` 之前截断。
fn scanLastToken(tree: Ast, node: Index, last: *TokenIndex) void {
    const mt = tree.nodeMainToken(node);
    if (mt > last.*) last.* = mt;
    if (tree.trailingDelimiter(node)) |t| {
        if (t > last.*) last.* = t;
    }

    const Ctx = struct {
        tree: Ast,
        last: *TokenIndex,
        fn onChild(self: @This(), child: Index) !void {
            scanLastToken(self.tree, child, self.last);
        }
    };
    tree.forEachChild(node, Ctx{ .tree = tree, .last = last }, Ctx.onChild) catch {};
}

/// 解析结果：一棵完整的 PHP AST，持有 `tokens`/`nodes`/`extra_data`/`errors`，
/// 以及 `version` 与根节点 `root`。用毕调用 `deinit(gpa)` 释放。
pub const Ast = struct {
    source: [:0]const u8,
    tokens: Token.TokenList.Slice,
    nodes: NodeList.Slice,
    extra_data: []u32,
    errors: []const Error,
    /// 与 `nodes` 等长：按节点顺序记录「引入版本」；`BASE_VERSION`(id=0) 表示基础语法。
    node_versions: []PhpVersion,
    version: PhpVersion,
    root: Index,

    /// 取某 token 的种类。
    pub fn tokenTag(tree: *const Ast, token_index: TokenIndex) Token.Tag {
        return tree.tokens.items(.tag)[token_index];
    }

    /// 取某 token 的起始字节偏移。
    pub fn tokenStart(tree: *const Ast, token_index: TokenIndex) ByteOffset {
        return @intCast(tree.tokens.items(.start)[@intCast(token_index)]);
    }

    /// 取某 token 的结束字节偏移（开区间）。
    pub fn tokenEnd(tree: *const Ast, token_index: TokenIndex) ByteOffset {
        return @intCast(tree.tokens.items(.end)[@intCast(token_index)]);
    }

    /// 取某节点的种类。
    pub fn nodeTag(tree: *const Ast, node: Index) Node.Tag {
        return tree.nodes.items(.tag)[@intFromEnum(node)];
    }

    /// 取某节点的主 token 下标。
    pub fn nodeMainToken(tree: *const Ast, node: Index) TokenIndex {
        return tree.nodes.items(.main_token)[@intFromEnum(node)];
    }

    /// 取某节点的 `data` 联合（直接子引用）。
    pub fn nodeData(tree: *const Ast, node: Index) Node.Data {
        return tree.nodes.items(.data)[@intFromEnum(node)];
    }

    /// 取某节点的「引入版本」。`id == 0`（`BASE_VERSION`）表示基础语法，未单独记录版本。
    /// 用于下游自行做兼容性判断，本库不做门控。
    pub fn nodeVersion(tree: *const Ast, node: Index) PhpVersion {
        return tree.node_versions[@intFromEnum(node)];
    }

    /// 从 `extra_data[index]` 按字段顺序反序列化一段 `Components` 负载。
    /// 各字段按其类型原样存为 `u32`（枚举/下标取枚举值，`bool` 取 0/1），
    /// 读取时按同序还原，调用方无需手写偏移。
    pub fn extraData(tree: Ast, index: ExtraIndex, comptime T: type) T {
        var result: T = undefined;
        var slot: usize = @intFromEnum(index);
        inline for (std.meta.fields(T)) |field| {
            @field(result, field.name) = switch (field.type) {
                Index,
                OptionalIndex,
                OptionalTokenIndex,
                ExtraIndex,
                => @enumFromInt(tree.extra_data[slot]),
                u32,
                => tree.extra_data[slot],
                bool => tree.extra_data[slot] != 0,
                SubRange => .{
                    .start = @enumFromInt(tree.extra_data[slot]),
                    .end = @enumFromInt(tree.extra_data[slot + 1]),
                },
                else => @compileError("unsupported extra field type: " ++ @typeName(field.type)),
            };
            slot += switch (field.type) {
                SubRange => 2,
                else => 1,
            };
        }
        return result;
    }

    /// 把 `extra_data` 中的一段区间按类型 `T` 重解释为切片（元素均为 `u32` 大小，
    /// 可直接按 4 字节步长重解释，无需逐元素转换）。
    pub fn extraDataSlice(tree: Ast, range: SubRange, comptime T: type) []const T {
        return @ptrCast(tree.extra_data[@intFromEnum(range.start)..@intFromEnum(range.end)]);
    }

    /// `listSlice` 的便捷包装：把 `ListRange` 当成 `SubRange` 处理。
    pub fn listSlice(tree: Ast, range: ListRange, comptime T: type) []const T {
        return tree.extraDataSlice(.{ .start = range.start, .end = range.end }, T);
    }

    /// 取根节点下的顶层语句列表。
    pub fn rootStmts(tree: Ast) []const Index {
        const range = tree.nodeData(tree.root).extra_range;
        return tree.extraDataSlice(range, Index);
    }

    /// 遍历 `node` 的全部直接子节点，逐个交给 `onChild(ctx, child)`。
    ///
    /// 这是「某节点的直接子引用有哪些」的唯一事实来源：`walk`、`firstToken`、
    /// `lastToken` 均构建于其上。采用访问者而非返回切片，是为了**零分配**——
    /// 子节点最多数十个，走栈即可，无需为此申请内存。
    ///
    /// 叶子（字面量、名字、伪类型等仅含主 token 的节点）不产生任何子节点。
    pub fn forEachChild(
        tree: Ast,
        node: Index,
        ctx: anytype,
        comptime onChild: fn (@TypeOf(ctx), Index) anyerror!void,
    ) !void {
        const data = tree.nodeData(node);
        switch (tree.nodeTag(node)) {
            // 区间型子节点（列表 / 多表达式节点）
            .root,
            .expr_array,
            .expr_isset,
            .expr_empty,
            .expr_list,
            .expr_encapsed,
            .attr_group,
            => try emitRange(tree, data.extra_range, ctx, onChild),

            // 单一可选子表达式
            .expr_exit => try emitOpt(data.opt_node, ctx, onChild),
            .stmt_return, .stmt_break, .stmt_continue => try emitOpt(data.opt_node_and_token[0], ctx, onChild),

            // 语句块：定界符存于 Components，仅语句列表为子节点
            .stmt_block => {
                const c = tree.extraData(data.extra, stmt.BlockComponents);
                try emitRange(tree, c.stmts, ctx, onChild);
            },

            // 单子表达式（operand 承载在 data.node）
            .expr_const_fetch,
            .expr_unary,
            .expr_eval,
            .expr_include,
            .expr_throw,
            .expr_print,
            .expr_error_suppress,
            .expr_post_inc,
            .expr_post_dec,
            .expr_cast,
            .expr_first_class_callable,
            .expr_yield_from,
            .type_name,
            .type_nullable,
            .type_array_of,
            => try onChild(ctx, data.node),

            // 控制流：拆分 Components 取子
            .stmt_if => {
                const c = tree.extraData(data.extra_and_opt_node[0], stmt.IfComponents);
                try onChild(ctx, c.cond);
                try onChild(ctx, c.then_body);
                try emitOpt(c.else_body, ctx, onChild);
            },
            .stmt_while => {
                const c = tree.extraData(data.extra_and_node[0], stmt.WhileComponents);
                try onChild(ctx, c.cond);
                try onChild(ctx, c.body);
            },
            .stmt_for => {
                const c = tree.extraData(data.extra_and_node[0], stmt.ForComponents);
                try emitOpt(c.init, ctx, onChild);
                try emitOpt(c.cond, ctx, onChild);
                try emitOpt(c.inc, ctx, onChild);
                try onChild(ctx, c.body);
            },
            .stmt_foreach => {
                const c = tree.extraData(data.extra_and_node[0], stmt.ForeachComponents);
                try onChild(ctx, c.expr);
                try emitOpt(c.key, ctx, onChild);
                try onChild(ctx, c.value);
                try onChild(ctx, c.body);
            },
            .stmt_namespace => {
                const c = tree.extraData(data.extra_and_opt_node[0], stmt.NamespaceComponents);
                try emitOpt(data.extra_and_opt_node[1], ctx, onChild);
                try emitRange(tree, c.stmts, ctx, onChild);
            },

            // 声明
            .stmt_function => {
                const c = tree.extraData(data.extra_and_opt_node[0], decl.FunctionComponents);
                try emitRange(tree, c.attrs, ctx, onChild);
                try emitRange(tree, c.params, ctx, onChild);
                try emitOpt(c.ret, ctx, onChild);
                try emitOpt(c.body, ctx, onChild);
            },
            .stmt_method => {
                const c = tree.extraData(data.extra_and_opt_node[0], decl.MethodComponents);
                try emitRange(tree, c.attrs, ctx, onChild);
                try emitRange(tree, c.params, ctx, onChild);
                try emitOpt(c.ret, ctx, onChild);
                try emitOpt(c.body, ctx, onChild);
            },
            .stmt_class => {
                const c = tree.extraData(data.extra_and_opt_node[0], decl.ClassComponents);
                try emitRange(tree, c.attrs, ctx, onChild);
                try emitOpt(c.extends, ctx, onChild);
                try emitOpt(c.implements, ctx, onChild);
                try emitRange(tree, c.stmts, ctx, onChild);
            },
            .stmt_interface, .stmt_trait, .stmt_enum => {
                const c = tree.extraData(data.extra_and_opt_node[0], decl.TypeDeclComponents);
                try emitRange(tree, c.attrs, ctx, onChild);
                try emitOpt(c.backing, ctx, onChild);
                try emitRange(tree, c.stmts, ctx, onChild);
            },
            .stmt_property => {
                const c = tree.extraData(data.extra_and_opt_node[0], decl.PropertyComponents);
                try emitOpt(c.type, ctx, onChild);
                try emitOpt(c.default, ctx, onChild);
                try emitRange(tree, c.hooks, ctx, onChild);
                try emitRange(tree, c.attrs, ctx, onChild);
            },
            .stmt_case => {
                const c = tree.extraData(data.extra_and_opt_node[0], decl.CaseComponents);
                try emitOpt(c.value, ctx, onChild);
                try emitRange(tree, c.attrs, ctx, onChild);
            },
            .stmt_class_const => {
                const c = tree.extraData(data.extra_and_opt_node[0], decl.ClassConstComponents);
                try emitOpt(c.type, ctx, onChild);
                try emitOpt(data.extra_and_opt_node[1], ctx, onChild);
                try emitRange(tree, c.attrs, ctx, onChild);
            },

            // 语句
            .stmt_do => {
                const c = tree.extraData(data.extra, stmt.DoComponents);
                try onChild(ctx, c.body);
                try onChild(ctx, c.cond);
            },
            .stmt_switch => {
                const c = tree.extraData(data.extra_and_node[0], stmt.SwitchComponents);
                try onChild(ctx, data.extra_and_node[1]); // cond
                try emitRange(tree, c.cases, ctx, onChild);
            },
            .stmt_switch_case => {
                const c = tree.extraData(data.extra_and_opt_node[0], stmt.CaseStmtComponents);
                try emitOpt(data.extra_and_opt_node[1], ctx, onChild); // value
                try emitRange(tree, c.stmts, ctx, onChild);
            },
            .stmt_default => try emitRange(tree, data.extra_range, ctx, onChild),
            .stmt_expression, .stmt_throw => try onChild(ctx, data.node_and_token[0]),
            // 列表型语句：列表经 Components 承载（尾部分号亦在其中）
            .stmt_echo => try emitRange(tree, tree.extraData(data.extra, stmt.EchoComponents).exprs, ctx, onChild),
            .stmt_const => try emitRange(tree, tree.extraData(data.extra, stmt.ConstComponents).decls, ctx, onChild),
            .stmt_global => try emitRange(tree, tree.extraData(data.extra, stmt.GlobalComponents).vars, ctx, onChild),
            .stmt_static => try emitRange(tree, tree.extraData(data.extra, stmt.StaticComponents).vars, ctx, onChild),
            .stmt_unset => try emitRange(tree, tree.extraData(data.extra, stmt.UnsetComponents).vars, ctx, onChild),
            .stmt_try => {
                const c = tree.extraData(data.extra_and_node[0], stmt.TryComponents);
                try onChild(ctx, data.extra_and_node[1]); // body
                try emitRange(tree, c.catches, ctx, onChild);
                try emitOpt(c.finally, ctx, onChild);
            },
            .stmt_catch => {
                const c = tree.extraData(data.extra_and_node[0], stmt.CatchComponents);
                try emitRange(tree, c.types, ctx, onChild);
                try onChild(ctx, data.extra_and_node[1]); // body
            },
            .const_decl => try onChild(ctx, data.node_and_token[0]), // value
            .stmt_use => {
                const c = tree.extraData(data.extra, stmt.UseComponents);
                try emitRange(tree, c.uses, ctx, onChild);
            },
            .use_use => try onChild(ctx, data.extra_and_node[1]), // name
            .stmt_group_use => {
                const c = tree.extraData(data.extra_and_node[0], stmt.GroupUseComponents);
                try onChild(ctx, data.extra_and_node[1]); // prefix
                try emitRange(tree, c.uses, ctx, onChild);
            },
            .stmt_trait_use => {
                const c = tree.extraData(data.extra, stmt.TraitUseComponents);
                try emitRange(tree, c.traits, ctx, onChild);
                try emitRange(tree, c.adaptations, ctx, onChild);
            },
            .trait_use_adaptation_alias, .trait_use_adaptation_precedence => {
                try emitOpt(data.extra_and_opt_node[1], ctx, onChild);
            },
            .stmt_declare => {
                const c = tree.extraData(data.extra_and_opt_node[0], stmt.DeclareComponents);
                try emitOpt(data.extra_and_opt_node[1], ctx, onChild); // stmts
                try emitRange(tree, c.declares, ctx, onChild);
            },
            .declare_declare => try onChild(ctx, data.node_and_token[0]), // value
            .stmt_goto, .stmt_label, .stmt_halt, .inline_html, .stmt_nop, .stmt_error => {},
            .static_var => try emitOpt(tree.extraData(data.extra, stmt.StaticVarComponents).default, ctx, onChild),
            .property_hook => {
                const c = tree.extraData(data.extra_and_node[0], decl.PropertyHookComponents);
                try onChild(ctx, data.extra_and_node[1]);
                try emitRange(tree, c.params, ctx, onChild);
                try emitRange(tree, c.attrs, ctx, onChild);
            },

            // 类型
            .type_union, .type_intersection => {
                try onChild(ctx, data.node_and_node[0]);
                try onChild(ctx, data.node_and_node[1]);
            },
            .type_generic => {
                const g = tree.extraData(data.extra_and_node[0], types.GenericTypeComponents);
                try onChild(ctx, data.extra_and_node[1]);
                try emitRange(tree, g.args, ctx, onChild);
            },
            .type_self, .type_parent, .type_static => {},

            // 名字（叶子）
            .name, .name_fully_qualified, .name_relative, .name_var_like => {},

            // 参数
            .param => {
                const c = tree.extraData(data.extra_and_opt_node[0], decl.ParamComponents);
                try emitOpt(c.type, ctx, onChild);
                try emitOpt(c.default, ctx, onChild);
                try emitRange(tree, c.attrs, ctx, onChild);
            },

            // 属性
            .attribute => {
                const c = tree.extraData(data.extra_and_node[0], decl.AttributeComponents);
                try onChild(ctx, data.extra_and_node[1]);
                try emitRange(tree, c.args, ctx, onChild);
            },

            // 一元 / 字面量叶子
            .expr_variable,
            .expr_int,
            .expr_float,
            .expr_string,
            .expr_string_part,
            .expr_magic_const,
            .expr_shell_exec,
            => {},

            // 调用类（callee + 参数列表）
            .expr_func_call,
            .expr_method_call,
            .expr_nullsafe_method_call,
            => {
                try onChild(ctx, data.node_and_range.node);
                try emitRange(tree, data.node_and_range.range, ctx, onChild);
            },
            .expr_static_call => {
                const c = tree.extraData(data.node_and_extra[1], expr.StaticCallComponents);
                try onChild(ctx, data.node_and_extra[0]);
                try emitRange(tree, c.args, ctx, onChild);
            },
            .expr_new => {
                const c = tree.extraData(data.extra_and_node[0], expr.NewComponents);
                try onChild(ctx, data.extra_and_node[1]);
                try emitRange(tree, c.args, ctx, onChild);
            },

            // 数组 / 列表 / 项 / 实参
            .expr_argument => try onChild(ctx, data.node_and_extra[0]),
            .expr_array_item => {
                const c = tree.extraData(data.node_and_extra[1], expr.ArrayItemComponents);
                try onChild(ctx, data.node_and_extra[0]);
                try emitOpt(c.key, ctx, onChild);
            },
            .expr_clone => {
                try onChild(ctx, data.node_and_opt_node[0]);
                try emitOpt(data.node_and_opt_node[1], ctx, onChild);
            },

            // 双目 / 赋值 / 访问类（node_and_node）
            .expr_binary,
            .expr_pipe,
            .expr_assign,
            .expr_assign_op,
            .expr_assign_ref,
            .expr_property_fetch,
            .expr_static_property_fetch,
            .expr_nullsafe_property_fetch,
            .expr_class_const_fetch,
            .expr_instanceof,
            => {
                try onChild(ctx, data.node_and_node[0]);
                try onChild(ctx, data.node_and_node[1]);
            },
            .expr_array_dim_fetch => {
                try onChild(ctx, data.node_and_opt_node[0]);
                try emitOpt(data.node_and_opt_node[1], ctx, onChild);
            },

            // match
            .expr_match => {
                const c = tree.extraData(data.extra_and_node[0], expr.MatchComponents);
                try onChild(ctx, data.extra_and_node[1]);
                try emitRange(tree, c.arms, ctx, onChild);
            },
            .expr_match_arm => {
                const c = tree.extraData(data.extra_and_node[0], expr.MatchArmComponents);
                try onChild(ctx, data.extra_and_node[1]);
                try emitRange(tree, c.exprs, ctx, onChild);
            },
            .expr_ternary => {
                const c = tree.extraData(data.node_and_extra[1], expr.TernaryComponents);
                try onChild(ctx, data.node_and_extra[0]);
                try emitOpt(c.then, ctx, onChild);
                try onChild(ctx, c.else_b);
            },

            // yield / 闭包
            .expr_yield => {
                const c = tree.extraData(data.extra, expr.YieldComponents);
                try emitOpt(c.key, ctx, onChild);
                try emitOpt(c.value, ctx, onChild);
            },
            .expr_closure => {
                const c = tree.extraData(data.extra, expr.ClosureComponents);
                try emitRange(tree, c.params, ctx, onChild);
                try emitOpt(c.ret, ctx, onChild);
                try onChild(ctx, c.body);
            },
            .expr_arrow_function => {
                const c = tree.extraData(data.extra, expr.ArrowFunctionComponents);
                try emitRange(tree, c.params, ctx, onChild);
                try emitOpt(c.ret, ctx, onChild);
                try onChild(ctx, c.body);
            },
        }
    }

    /// 取某节点覆盖的首个 token 下标（含其全部后代）。
    ///
    /// `main_token` 只是节点的**代表性** token（如二元运算的运算符），并非起始位置；
    /// 本函数沿子节点递归取最小值，得到真正的区间左端。
    pub fn firstToken(tree: Ast, node: Index) TokenIndex {
        if (tree.nodeTag(node) == .root) {
            const s = tree.rootStmts();
            if (s.len == 0) return 0;
            return tree.firstToken(s[0]);
        }
        var first = tree.nodeMainToken(node);
        scanFirstToken(tree, node, &first);
        return first;
    }

    /// 取某节点覆盖的末个 token 下标（含其全部后代），逻辑同 `firstToken`。
    ///
    /// 二者合用即得节点的完整源码区间 `[firstToken, lastToken]`，可用于区间高亮、
    /// 代码改写等场景。
    pub fn lastToken(tree: Ast, node: Index) TokenIndex {
        if (tree.nodeTag(node) == .root) {
            const s = tree.rootStmts();
            if (s.len == 0) return 0;
            return tree.lastToken(s[s.len - 1]);
        }
        var last = tree.nodeMainToken(node);
        scanLastToken(tree, node, &last);
        return last;
    }

    /// 取节点的**名字 token**（函数名、类名、常量名、属性名、case 名等），无则 `null`。
    ///
    /// 名字是 token 而非子节点，故不出现在 `forEachChild` 里；但它是节点的核心信息，
    /// 检索与断点定位都需要。声明类节点的 `main_token` 往往是关键字（`function`、
    /// `class`），只靠它取不到名字。
    pub fn nameToken(tree: Ast, node: Index) ?TokenIndex {
        const data = tree.nodeData(node);
        return switch (tree.nodeTag(node)) {
            .stmt_function => tree.extraData(data.extra_and_opt_node[0], decl.FunctionComponents).name,
            .stmt_method => tree.extraData(data.extra_and_opt_node[0], decl.MethodComponents).name,
            .stmt_class => tree.extraData(data.extra_and_opt_node[0], decl.ClassComponents).name,
            .stmt_interface,
            .stmt_trait,
            .stmt_enum,
            => tree.extraData(data.extra_and_opt_node[0], decl.TypeDeclComponents).name,
            .stmt_property => tree.extraData(data.extra_and_opt_node[0], decl.PropertyComponents).name,
            .stmt_class_const => tree.extraData(data.extra_and_opt_node[0], decl.ClassConstComponents).name,
            .stmt_case => tree.extraData(data.extra_and_opt_node[0], decl.CaseComponents).name,
            .const_decl, .declare_declare => data.node_and_token[1],
            .static_var => tree.extraData(data.extra, stmt.StaticVarComponents).name,
            .trait_use_adaptation_alias => tree.extraData(data.extra_and_opt_node[0], stmt.TraitAdaptAliasComponents).method,
            .trait_use_adaptation_precedence => tree.extraData(data.extra_and_opt_node[0], stmt.TraitAdaptPrecComponents).method,
            .param => tree.extraData(data.extra_and_opt_node[0], decl.ParamComponents).name,
            else => null,
        };
    }

    /// 取节点的尾部定界符 token（分号、右花括号等），无则 `null`。
    ///
    /// 定界符不是任何节点的子节点，故不计入 `forEachChild`；但要让 `lastToken`
    /// 覆盖完整源码区间就必须单独取回。未列出者（叶子表达式、`switch` 的
    /// `case`/`default` 等以冒号收尾的构造）返回 `null`。
    pub fn trailingDelimiter(tree: Ast, node: Index) ?TokenIndex {
        const data = tree.nodeData(node);
        return switch (tree.nodeTag(node)) {
            // 定界符记在 Components 内
            .stmt_block => tree.extraData(data.extra, stmt.BlockComponents).rbrace,
            .stmt_do => tree.extraData(data.extra, stmt.DoComponents).semi,
            .stmt_use => tree.extraData(data.extra, stmt.UseComponents).semi,
            .stmt_group_use => tree.extraData(data.extra_and_node[0], stmt.GroupUseComponents).semi,
            .stmt_trait_use => tree.extraData(data.extra, stmt.TraitUseComponents).semi,
            .stmt_declare => tree.extraData(data.extra_and_opt_node[0], stmt.DeclareComponents).semi,
            .stmt_namespace => tree.extraData(data.extra_and_opt_node[0], stmt.NamespaceComponents).close,
            .stmt_echo => tree.extraData(data.extra, stmt.EchoComponents).semi,
            .stmt_const => tree.extraData(data.extra, stmt.ConstComponents).semi,
            .stmt_global => tree.extraData(data.extra, stmt.GlobalComponents).semi,
            .stmt_static => tree.extraData(data.extra, stmt.StaticComponents).semi,
            .stmt_unset => tree.extraData(data.extra, stmt.UnsetComponents).semi,
            .stmt_property => tree.extraData(data.extra_and_opt_node[0], decl.PropertyComponents).semi,
            .stmt_class_const => tree.extraData(data.extra_and_opt_node[0], decl.ClassConstComponents).semi,
            .stmt_case => tree.extraData(data.extra_and_opt_node[0], decl.CaseComponents).semi,

            // 限定名的 `data.token` 是末段（如 `Foo\Bar` 的 `Bar`），必须计入区间，
            // 否则名字只覆盖到首段，下游按区间取名字文本会得到 `Foo`。
            .name, .name_fully_qualified, .name_relative, .name_var_like => data.token,

            // 定界符记在 data 的 token 槽位
            .stmt_expression, .stmt_throw, .const_decl, .declare_declare => data.node_and_token[1],
            .stmt_return, .stmt_break, .stmt_continue => data.opt_node_and_token[1],
            .stmt_goto, .stmt_halt => data.token_and_token[1],

            else => null,
        };
    }

    /// 计算某 token 在源码中的行列位置。从 `start_offset` 起扫描换行定位所在行，
    /// 再算出列号与行起止偏移。位置现算，不冗余存储。
    pub fn tokenLocation(tree: Ast, start_offset: ByteOffset, token_index: TokenIndex) Location {
        var loc = Location{
            .line = 0,
            .column = 0,
            .line_start = start_offset,
            .line_end = tree.source.len,
        };
        const token_start = tree.tokenStart(token_index);

        while (std.mem.findScalarPos(u8, tree.source, loc.line_start, '\n')) |i| {
            if (i >= token_start) break;
            loc.line += 1;
            loc.line_start = i + 1;
        }

        const offset = loc.line_start;
        for (tree.source[offset..], 0..) |c, i| {
            if (i + offset == token_start) {
                loc.line_end = i + offset;
                while (loc.line_end < tree.source.len and tree.source[loc.line_end] != '\n') {
                    loc.line_end += 1;
                }
                return loc;
            }
            if (c == '\n') {
                loc.line += 1;
                loc.column = 0;
                loc.line_start = i + 1;
            } else {
                loc.column += 1;
            }
        }
        return loc;
    }

    /// 取某 token 对应的源码切片（零拷贝）。
    pub fn tokenSlice(tree: Ast, token_index: TokenIndex) []const u8 {
        const start = tree.tokenStart(token_index);
        const end = tree.tokenEnd(token_index);
        return tree.source[start..end];
    }

    /// 取紧贴 `node` 之前、仅被注释隔开的 docblock token 下标（若有）。
    /// 注释始终作为 token 保留，下游按需向前扫描取回，节点结构保持清爽。
    pub fn docCommentBefore(tree: Ast, node: Index) ?TokenIndex {
        const ft = tree.firstToken(node);
        if (ft == 0) return null;
        var i = ft;
        while (i > 0) {
            i -= 1;
            const tg = tree.tokenTag(i);
            if (tg == .doc_comment) return i;
            if (tg == .comment) continue;
            break;
        }
        return null;
    }

    /// 释放整棵树占用的全部内存。调用方必须在 `parse` 返回的 `Ast` 使用完毕后
    /// 显式调用，传入与 `parse` 相同的 `gpa`。
    pub fn deinit(tree: *Ast, gpa: std.mem.Allocator) void {
        tree.tokens.deinit(gpa);
        tree.nodes.deinit(gpa);
        gpa.free(tree.extra_data);
        gpa.free(tree.errors);
        gpa.free(tree.node_versions);
        tree.* = undefined;
    }

    /// 解析入口。调用方经 `gpa` 提供分配器，`version` 控制 8.x 语法开关；
    /// 失败仅因内存不足（`ParseError == Allocator.Error`）。用毕调用 `deinit`。
    ///
    /// ```zig
    /// const tree = try php_ast.parse(gpa, "<?php $a = 1;", .{ .id = 80400 });
    /// defer tree.deinit(gpa);
    /// for (tree.rootStmts()) |stmt| {
    ///     std.debug.print("顶层语句种类: {}\n", .{tree.nodeTag(stmt)});
    /// }
    /// ```
    pub fn parse(gpa: std.mem.Allocator, source: [:0]const u8, version: PhpVersion) ParseError!Ast {
        // 先词法：结果暂存在 `Token.TokenList` 里。
        var tokens = Token.TokenList{};
        defer tokens.deinit(gpa);

        try Lexer.tokenize(gpa, source, &tokens);

        // 词法结果转为拥有所有权的切片交给解析器；失败由 errdefer 释放。
        var tokens_slice = tokens.toOwnedSlice();
        errdefer tokens_slice.deinit(gpa);

        return parseTokens(gpa, source, tokens_slice, version);
    }
};

/// 在已有 token 切片上执行递归下降解析（私有，外部走 `parse`）。
/// `tokens` 移入返回的 `Ast`；临时 `nodes`/`extra_data`/`errors` 由 `defer` 释放，
/// 失败时 `errdefer` 兜底。
fn parseTokens(
    gpa: std.mem.Allocator,
    source: [:0]const u8,
    tokens: Token.TokenList.Slice,
    version: PhpVersion,
) ParseError!Ast {
    var p: parser.Parser = .{
        .gpa = gpa,
        .source = source,
        .tokens = tokens,
        .nodes = NodeList{},
        .extra_data = try std.ArrayList(u32).initCapacity(gpa, 0),
        .errors = try std.ArrayList(Error).initCapacity(gpa, 0),
        .node_versions = try std.ArrayList(PhpVersion).initCapacity(gpa, 0),
        .tok_i = 0,
    };
    defer p.nodes.deinit(gpa);
    defer p.extra_data.deinit(gpa);
    defer p.errors.deinit(gpa);
    defer p.node_versions.deinit(gpa);

    const root = try p.parseRoot();

    // 版本门控：把引入版本高于目标版本的节点上报为专用错误，交给调用方决定放行或拒绝。
    var i: usize = 0;
    while (i < p.node_versions.items.len) : (i += 1) {
        const nv = p.node_versions.items[i];
        if (nv.id != 0 and nv.id > version.id) {
            try p.errors.append(gpa, .{
                .tag = .unsupported_version,
                .token = p.nodes.items(.main_token)[i],
                .required = nv,
            });
        }
    }

    const extra_data = try p.extra_data.toOwnedSlice(gpa);
    errdefer gpa.free(extra_data);
    const errors = try p.errors.toOwnedSlice(gpa);
    errdefer gpa.free(errors);
    const node_versions = try p.node_versions.toOwnedSlice(gpa);
    errdefer gpa.free(node_versions);

    return Ast{
        .source = source,
        .tokens = tokens,
        .nodes = p.nodes.toOwnedSlice(),
        .extra_data = extra_data,
        .errors = errors,
        .node_versions = node_versions,
        .version = version,
        .root = root,
    };
}

// ===========================================================================
// 测试：AST 入口、版本门控与源码溯源
// ===========================================================================

test "ast :: root 与语句列表 :: 顶层语句按顺序挂到 root" {
    const gpa = std.testing.allocator;
    var tree = try Ast.parse(gpa, "<?php $a = 1; $b = 2;", testing.v84);
    defer tree.deinit(gpa);
    try testing.expectNoErrors(tree);

    try std.testing.expectEqual(.root, tree.nodeTag(tree.root));
    try std.testing.expectEqual(@as(usize, 2), tree.rootStmts().len);
}

test "ast :: node_versions :: 与 nodes 等长" {
    const gpa = std.testing.allocator;
    var tree = try Ast.parse(gpa, "<?php enum E { case A; }", testing.v84);
    defer tree.deinit(gpa);
    try testing.expectNoErrors(tree);
    try std.testing.expectEqual(tree.nodes.len, tree.node_versions.len);
}

test "ast :: nodeVersion :: 标记节点引入版本" {
    const gpa = std.testing.allocator;
    var tree = try Ast.parse(gpa,
        \\<?php
        \\enum E { case A; }
        \\$x = new Foo;
    , testing.v84);
    defer tree.deinit(gpa);
    try testing.expectNoErrors(tree);

    for (tree.nodes.items(.tag), 0..) |tag, i| {
        const v = tree.node_versions[i];
        if (tag == .stmt_enum or tag == .stmt_case) {
            try std.testing.expectEqual(@as(u32, 80100), v.id); // enum/case 为 8.1
        }
        if (tag == .expr_new) {
            try std.testing.expectEqual(@as(u32, 80400), v.id); // 无括号 new 为 8.4
        }
    }
}

test "ast :: 版本门控 :: 目标低于引入版本时上报" {
    const gpa = std.testing.allocator;
    var tree = try Ast.parse(gpa, "<?php enum E { case A; }", testing.v80);
    defer tree.deinit(gpa);

    var gate: usize = 0;
    var buf: [128]u8 = undefined;
    for (tree.errors) |e| {
        if (e.tag == .unsupported_version) {
            gate += 1;
            try std.testing.expectEqual(@as(u32, 80100), e.required.id);
            const msg = e.format(&tree, &buf);
            try std.testing.expect(std.mem.indexOf(u8, msg, "8.1") != null);
            try std.testing.expect(std.mem.indexOf(u8, msg, "8.0") != null);
        }
    }
    // stmt_enum 与 stmt_case 均为 8.1 引入
    try std.testing.expectEqual(@as(usize, 2), gate);
}

test "ast :: 版本门控 :: 目标不低于引入版本时静默" {
    const gpa = std.testing.allocator;
    var tree = try Ast.parse(gpa, "<?php enum E { case A; }", testing.v84);
    defer tree.deinit(gpa);
    for (tree.errors) |e| try std.testing.expect(e.tag != .unsupported_version);
}

test "ast :: 非版本错误 :: required 恒为 BASE_VERSION" {
    const gpa = std.testing.allocator;
    var tree = try Ast.parse(gpa, "<?php $a = ;", testing.v84);
    defer tree.deinit(gpa);
    try std.testing.expect(tree.errors.len > 0);
    for (tree.errors) |e| {
        if (e.tag != .unsupported_version) {
            try std.testing.expectEqual(@as(u32, 0), e.required.id);
        }
    }
}

test "ast :: 8.5 语法 :: 表驱动验证版本门控" {
    const gpa = std.testing.allocator;
    const Case = struct { src: [:0]const u8, n: usize };
    const cases = [_]Case{
        .{ .src = "<?php $x |> strlen;", .n = 1 },
        .{ .src = "<?php (void) foo();", .n = 1 },
        .{ .src = "<?php clone($o, withProperties: ['a' => 1]);", .n = 1 },
        .{ .src = "<?php class C { #[A] const X = 1; }", .n = 1 },
        .{ .src = "<?php #[A] const X = 1;", .n = 1 },
        .{ .src = "<?php class C { public protected(set) static int $x; }", .n = 1 },
        .{ .src = "<?php class C { public function __construct(public final int $x) {} }", .n = 1 },
    };

    for (cases) |c| {
        // 目标 8.4 低于 8.5：应报 required=8.5 的门控错误
        var low = try Ast.parse(gpa, c.src, testing.v84);
        defer low.deinit(gpa);
        var gate: usize = 0;
        for (low.errors) |e| {
            if (e.tag == .unsupported_version and e.required.id == 80500) gate += 1;
        }
        try std.testing.expectEqual(c.n, gate);

        // 目标 8.5：不应再报版本错误
        var ok = try Ast.parse(gpa, c.src, testing.v85);
        defer ok.deinit(gpa);
        for (ok.errors) |e| try std.testing.expect(e.tag != .unsupported_version);
    }
}

test "ast :: tokenSlice :: 节点主 token 可回切源码原文" {
    const gpa = std.testing.allocator;
    var tree = try Ast.parse(gpa, "<?php $answer = 42;", testing.v84);
    defer tree.deinit(gpa);
    try testing.expectNoErrors(tree);

    const lit = testing.firstNode(tree,.expr_int) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("42", tree.tokenSlice(tree.nodeMainToken(lit)));
}

test "ast :: firstToken/lastToken :: 覆盖节点的完整 token 区间" {
    const gpa = std.testing.allocator;
    var tree = try Ast.parse(gpa, "<?php $a = 1 + 2;", testing.v84);
    defer tree.deinit(gpa);
    try testing.expectNoErrors(tree);

    // 二元表达式应覆盖 `1 + 2` 三个 token，而非仅主 token（运算符 `+`）
    const bin = testing.firstNode(tree, .expr_binary) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("1", tree.tokenSlice(tree.firstToken(bin)));
    try std.testing.expectEqualStrings("2", tree.tokenSlice(tree.lastToken(bin)));

    // 赋值表达式覆盖 `$a = 1 + 2` 五个 token
    const asg = testing.firstNode(tree, .expr_assign) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("$a", tree.tokenSlice(tree.firstToken(asg)));
    try std.testing.expectEqualStrings("2", tree.tokenSlice(tree.lastToken(asg)));
}

test "ast :: firstToken/lastToken :: 复合语句含定界符" {
    const gpa = std.testing.allocator;
    var tree = try Ast.parse(gpa, "<?php if ($a) { echo 1; }", testing.v84);
    defer tree.deinit(gpa);
    try testing.expectNoErrors(tree);

    // 整个 if 语句应覆盖到结尾的 `}`
    const if_node = testing.firstNode(tree, .stmt_if) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("if", tree.tokenSlice(tree.firstToken(if_node)));
    try std.testing.expectEqualStrings("}", tree.tokenSlice(tree.lastToken(if_node)));
}

test "ast :: 限定名 :: 区间覆盖全部分段" {
    // 分段名存于 `data.token`（末段），若 lastToken 忽略它，区间会停在首段，
    // 下游按区间取名字文本将得到 `Foo` 而非 `Foo\Bar`。
    const gpa = std.testing.allocator;
    var tree = try Ast.parse(gpa, "<?php use Foo\\Bar;", testing.v84);
    defer tree.deinit(gpa);
    try testing.expectNoErrors(tree);

    const n = testing.firstNode(tree, .name) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("Foo", tree.tokenSlice(tree.firstToken(n)));
    try std.testing.expectEqualStrings("Bar", tree.tokenSlice(tree.lastToken(n)));
}

test "ast :: nameToken :: 取回声明的名字而非关键字" {
    const gpa = std.testing.allocator;
    var tree = try Ast.parse(gpa,
        \\<?php
        \\function foo() {}
        \\class Bar { public int $prop; const C = 1; public function m() {} }
        \\enum Suit: string { case Hearts; }
    , testing.v84);
    defer tree.deinit(gpa);
    try testing.expectNoErrors(tree);

    // main_token 是关键字（function/class/enum），名字只能经 nameToken 取得
    const fn_node = testing.firstNode(tree, .stmt_function) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("function", tree.tokenSlice(tree.nodeMainToken(fn_node)));
    try std.testing.expectEqualStrings("foo", tree.tokenSlice(tree.nameToken(fn_node).?));

    const m = testing.firstNode(tree, .stmt_method) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("m", tree.tokenSlice(tree.nameToken(m).?));

    // 属性名的 token 含 `$` 前缀，与 PHP 源码一致
    const p = testing.firstNode(tree, .stmt_property) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("$prop", tree.tokenSlice(tree.nameToken(p).?));

    const c = testing.firstNode(tree, .stmt_class_const) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("C", tree.tokenSlice(tree.nameToken(c).?));

    const e = testing.firstNode(tree, .stmt_enum) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("Suit", tree.tokenSlice(tree.nameToken(e).?));

    const case_node = testing.firstNode(tree, .stmt_case) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("Hearts", tree.tokenSlice(tree.nameToken(case_node).?));
}

test "ast :: lastToken :: 各类语句的区间含尾部分号" {
    const gpa = std.testing.allocator;
    // 每行均为「一个语句 + 分号」；断言该语句的 lastToken 就是分号。
    const srcs = [_][:0]const u8{
        "<?php $a = 1;",
        "<?php echo 1;",
        "<?php return 1;",
        "<?php throw $e;",
        "<?php const A = 1;",
        "<?php global $a;",
        "<?php static $a;",
        "<?php unset($a);",
        "<?php use A;",
        "<?php use A\\{B};",
        "<?php declare(strict_types=1);",
        "<?php goto a;",
        "<?php do {} while ($a);",
        "<?php while ($a) { break; }",
        "<?php while ($a) { continue; }",
        "<?php namespace N;",
        "<?php class C { use T; }",
        "<?php class C { public int $x; }",
        "<?php class C { const A = 1; }",
        "<?php enum E { case A; }",
    };

    for (srcs) |src| {
        var tree = try Ast.parse(gpa, src, testing.v84);
        defer tree.deinit(gpa);
        try testing.expectNoErrors(tree);

        // 取首条顶层语句；类成员则取类体内首条
        const stmts = tree.rootStmts();
        if (stmts.len == 0) return error.TestUnexpectedResult;
        var target = stmts[0];
        // 类成员语句需下钻一层；类与枚举的负载类型不同，分别取
        const members: []const Index = switch (tree.nodeTag(target)) {
            .stmt_class => blk: {
                const c = tree.extraData(tree.nodeData(target).extra_and_opt_node[0], decl.ClassComponents);
                break :blk tree.extraDataSlice(c.stmts, Index);
            },
            .stmt_enum => blk: {
                const c = tree.extraData(tree.nodeData(target).extra_and_opt_node[0], decl.TypeDeclComponents);
                break :blk tree.extraDataSlice(c.stmts, Index);
            },
            else => &.{},
        };
        if (members.len > 0) target = members[0];
        if (tree.nodeTag(target) == .stmt_while) {
            // while 的 break/continue 在循环体内
            try std.testing.expectEqualStrings(
                "}",
                tree.tokenSlice(tree.lastToken(target)),
            );
            continue;
        }

        const last = tree.tokenSlice(tree.lastToken(target));
        if (!std.mem.eql(u8, ";", last)) {
            std.debug.print("\n语句区间不含分号: {s}\n  实际末 token = `{s}`\n", .{ src, last });
            try std.testing.expect(false);
        }
    }
}

test "ast :: lastToken :: 块形式命名空间与 declare 以 } 结尾" {
    const gpa = std.testing.allocator;
    var tree = try Ast.parse(gpa,
        \\<?php
        \\namespace N { function f() {} }
        \\declare(strict_types=1) { $a = 1; }
    , testing.v84);
    defer tree.deinit(gpa);
    try testing.expectNoErrors(tree);

    for (tree.rootStmts()) |s| {
        try std.testing.expectEqualStrings("}", tree.tokenSlice(tree.lastToken(s)));
    }
}

test "ast :: forEachChild :: 各节点均能无异常枚举子节点" {
    // data 是 untagged union，读写两侧若用了不同变体会触发安全检查报错甚至越界。
    // 覆盖矩阵已保证每个 tag 都有用例，这里对全树逐节点枚举一次即可暴露不一致。
    const gpa = std.testing.allocator;
    const srcs = [_][:0]const u8{
        "<?php $a = 1 + 2;",
        "<?php if ($a) { echo 1; } else { echo 2; }",
        "<?php while ($a) { break; }",
        "<?php for ($i = 0; $i < 3; $i++) {}",
        "<?php foreach ($a as $k => $v) {}",
        "<?php do {} while ($a);",
        "<?php switch ($a) { case 1: break; default: }",
        "<?php try {} catch (E $e) {} finally {}",
        "<?php function f(int $x): int { return $x; }",
        "<?php class C extends B implements I { public int $x; const A = 1; use T; }",
        "<?php interface I { public function m(); }",
        "<?php trait T { public function m() {} }",
        "<?php enum E: string { case A = 'a'; }",
        "<?php namespace N { function f() {} }",
        "<?php use A\\{B, C as D};",
        "<?php declare(strict_types=1) { $a = 1; }",
        "<?php match ($a) { 1, 2 => 'x', default => 'y' };",
        "<?php $f = function ($p) use ($y): int { return $p; };",
        "<?php $g = fn ($p) => $p;",
        "<?php #[Attr(1)] class D {}",
        "<?php $x = new class { public $p; };",
        "<?php $a?->b()->c[0]::$d;",
        "<?php (int)$v . (string)$w;",
        "<?php `ls -l`; print $a; eval('1'); exit;",
        "<?php global $a; static $b; unset($c);",
        "<?php goto lb; lb:",
        "<?php __halt_compiler();",
    };

    const Ctx = struct {
        tree: Ast,
        n: usize = 0,
        fn onChild(self: *@This(), child: Index) !void {
            self.n += 1;
            // 子节点下标必须合法
            _ = self.tree.nodeTag(child);
        }
    };

    for (srcs) |src| {
        var tree = try Ast.parse(gpa, src, testing.v84);
        defer tree.deinit(gpa);
        for (tree.nodes.items(.tag), 0..) |_, i| {
            var ctx = Ctx{ .tree = tree };
            try tree.forEachChild(@enumFromInt(i), &ctx, Ctx.onChild);
        }
    }
}

test "ast :: lastToken :: root 委托到首末条顶层语句" {
    const gpa = std.testing.allocator;
    var tree = try Ast.parse(gpa, "<?php $a = 1;", testing.v84);
    defer tree.deinit(gpa);
    try testing.expectNoErrors(tree);

    try std.testing.expectEqualStrings("$a", tree.tokenSlice(tree.firstToken(tree.root)));
    try std.testing.expectEqualStrings(";", tree.tokenSlice(tree.lastToken(tree.root)));
}

test "ast :: tokenLocation :: 计算行列位置" {
    const gpa = std.testing.allocator;
    var tree = try Ast.parse(gpa,
        \\<?php
        \\$a = 1;
        \\$b = 2;
    , testing.v84);
    defer tree.deinit(gpa);
    try testing.expectNoErrors(tree);

    const lit = testing.firstNode(tree,.expr_int) orelse return error.TestUnexpectedResult;
    const loc = tree.tokenLocation(0, tree.nodeMainToken(lit));
    // 第 2 行（0 起算），即源码中的 `$a = 1;`
    try std.testing.expectEqual(@as(usize, 1), loc.line);
}

test "ast :: docCommentBefore :: 取回声明前的 docblock" {
    const gpa = std.testing.allocator;
    var tree = try Ast.parse(gpa,
        \\<?php
        \\/** doc */
        \\function f() {}
    , testing.v84);
    defer tree.deinit(gpa);
    try testing.expectNoErrors(tree);

    const fn_node = testing.firstNode(tree,.stmt_function) orelse return error.TestUnexpectedResult;
    const doc = tree.docCommentBefore(fn_node) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(.doc_comment, tree.tokenTag(doc));
}

test "ast :: tagVersion :: 基础语法返回 BASE_VERSION" {
    try std.testing.expectEqual(@as(u32, 0), tagVersion(.root).id);
    try std.testing.expectEqual(@as(u32, 0), tagVersion(.expr_assign).id);
    try std.testing.expectEqual(@as(u32, 80100), tagVersion(.stmt_enum).id);
    try std.testing.expectEqual(@as(u32, 80400), tagVersion(.property_hook).id);
    try std.testing.expectEqual(@as(u32, 80500), tagVersion(.expr_pipe).id);
}


