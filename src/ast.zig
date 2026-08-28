const std = @import("std");
const Token = @import("token.zig").Token;
const PhpVersion = @import("version.zig").PhpVersion;
const BASE_VERSION = @import("version.zig").BASE_VERSION;
const Lexer = @import("lexer.zig").Lexer;
const parser = @import("parser.zig");

/// PHP 抽象语法树（AST），布局参照 `std.zig.Ast`（SoA + 索引平板）：
/// - `nodes` 为扁平 `Node` 数组，节点间以 `Index` 互相引用而非指针；每个节点仅 3 字段。
/// - 超过 2 个直接子节点的负载序列化进 `extra_data`（`u32` 大板），节点 `data` 仅存 `ExtraIndex`。
/// - `tokens` 与 `nodes` 分离存储。
///
/// 内存由调用方经 `parse(gpa, ...)` 提供，统一用 `deinit` 释放；位置信息不冗余存储，
/// 行/列经 `tokenLocation` 按需从 `main_token` 派生。
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

    /// 取某节点覆盖的首个 token 下标。`root` 递归到首条语句；其余节点即其 `main_token`，
    /// 故节点无需冗余存储首尾偏移。
    pub fn firstToken(tree: Ast, node: Index) TokenIndex {
        if (tree.nodeTag(node) == .root) {
            const s = tree.rootStmts();
            if (s.len == 0) return 0;
            return tree.firstToken(s[0]);
        }
        return tree.nodeMainToken(node);
    }

    /// 取某节点覆盖的末个 token 下标（逻辑同 `firstToken`）。
    pub fn lastToken(tree: Ast, node: Index) TokenIndex {
        if (tree.nodeTag(node) == .root) {
            const s = tree.rootStmts();
            if (s.len == 0) return 0;
            return tree.lastToken(s[s.len - 1]);
        }
        return tree.nodeMainToken(node);
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


