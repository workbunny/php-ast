const std = @import("std");
const ast = @import("ast.zig");
const expr = @import("parser_expr.zig");
const stmt = @import("parser_stmt.zig");
const decl = @import("parser_decl.zig");
const types = @import("parser_type.zig");

const Index = ast.Index;
const SubRange = ast.SubRange;
const TokenIndex = ast.TokenIndex;

/// 把 `range` 指向的节点列表逐个追加到 `out`，用于遍历时展开区间型子节点。
fn appendRange(gpa: std.mem.Allocator, tree: ast.Ast, range: SubRange, out: *std.ArrayList(Index)) !void {
    for (tree.extraDataSlice(range, Index)) |n| try out.append(gpa, n);
}

fn appendOpt(gpa: std.mem.Allocator, out: *std.ArrayList(Index), opt: ast.OptionalIndex) !void {
    if (opt.unwrap()) |n| try out.append(gpa, n);
}

/// 枚举某节点的全部直接子节点（节点下标），追加到 `out`。
///
/// 这是树遍历（`walk`）与「full 视图」重装的基石：每个节点的所有直接子引用都在此
/// 显式给出。叶子（仅含主 token，如字面量、名字、伪类型）不产生子节点。
pub fn childNodes(gpa: std.mem.Allocator, tree: ast.Ast, node: Index, out: *std.ArrayList(Index)) !void {
    const data = tree.nodeData(node);
    switch (tree.nodeTag(node)) {
        // 区间型子节点（语句块 / 列表 / 多表达式节点）
        .root,
        .stmt_echo,
        .stmt_block,
        .expr_array,
        .expr_isset,
        .expr_empty,
        .expr_list,
        .expr_encapsed,
        .attr_group,
        => try appendRange(gpa, tree, data.extra_range, out),

        // 单一可选子表达式
        .stmt_return,
        .expr_exit,
        => try appendOpt(gpa, out, data.opt_node),

        // 单子表达式（operand 承载在 data.node）
        .stmt_expression,
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
        => try out.append(gpa, data.node),

        // 控制流：拆分 Components 取子
        .stmt_if => {
            const c = tree.extraData(data.extra_and_opt_node[0], stmt.IfComponents);
            try out.append(gpa, c.cond);
            try out.append(gpa, c.then_body);
            try appendOpt(gpa, out, c.else_body);
        },
        .stmt_while => {
            const c = tree.extraData(data.extra_and_node[0], stmt.WhileComponents);
            try out.append(gpa, c.cond);
            try out.append(gpa, c.body);
        },
        .stmt_for => {
            const c = tree.extraData(data.extra_and_node[0], stmt.ForComponents);
            try out.append(gpa, c.init);
            try out.append(gpa, c.cond);
            try out.append(gpa, c.inc);
            try out.append(gpa, c.body);
        },
        .stmt_foreach => {
            const c = tree.extraData(data.extra_and_node[0], stmt.ForeachComponents);
            try out.append(gpa, c.expr);
            try appendOpt(gpa, out, c.key);
            try out.append(gpa, c.value);
            try out.append(gpa, c.body);
        },
        .stmt_namespace => {
            const c = tree.extraData(data.extra_and_opt_node[0], stmt.NamespaceComponents);
            try appendOpt(gpa, out, data.extra_and_opt_node[1]);
            try appendRange(gpa, tree, c.stmts, out);
        },

        // 声明
        .stmt_function => {
            const c = tree.extraData(data.extra_and_opt_node[0], decl.FunctionComponents);
            try appendRange(gpa, tree, c.attrs, out);
            try appendRange(gpa, tree, c.params, out);
            try appendOpt(gpa, out, c.ret);
            try appendOpt(gpa, out, c.body);
        },
        .stmt_method => {
            const c = tree.extraData(data.extra_and_opt_node[0], decl.MethodComponents);
            try appendRange(gpa, tree, c.attrs, out);
            try appendRange(gpa, tree, c.params, out);
            try appendOpt(gpa, out, c.ret);
            try appendOpt(gpa, out, c.body);
        },
        .stmt_class => {
            const c = tree.extraData(data.extra_and_opt_node[0], decl.ClassComponents);
            try appendRange(gpa, tree, c.attrs, out);
            try appendOpt(gpa, out, c.extends);
            try appendOpt(gpa, out, c.implements);
            try appendRange(gpa, tree, c.stmts, out);
        },
        .stmt_interface, .stmt_trait, .stmt_enum => {
            const c = tree.extraData(data.extra, decl.TypeDeclComponents);
            try appendRange(gpa, tree, c.attrs, out);
            try appendOpt(gpa, out, c.backing);
            try appendRange(gpa, tree, c.stmts, out);
        },
        .stmt_property => {
            const c = tree.extraData(data.extra_and_opt_node[0], decl.PropertyComponents);
            try appendOpt(gpa, out, c.type);
            try appendOpt(gpa, out, c.default);
            try appendRange(gpa, tree, c.hooks, out);
            try appendRange(gpa, tree, c.attrs, out);
        },
        .stmt_case => {
            const c = tree.extraData(data.extra_and_opt_node[0], decl.CaseComponents);
            try appendOpt(gpa, out, c.value);
            try appendRange(gpa, tree, c.attrs, out);
        },
        .stmt_class_const => {
            const c = tree.extraData(data.extra_and_opt_node[0], decl.ClassConstComponents);
            try appendOpt(gpa, out, c.type);
            try appendOpt(gpa, out, data.extra_and_opt_node[1]);
            try appendRange(gpa, tree, c.attrs, out);
        },

        // 新增语句节点
        .stmt_do => {
            try out.append(gpa, data.node_and_node[0]); // body
            try out.append(gpa, data.node_and_node[1]); // cond
        },
        .stmt_break, .stmt_continue => {
            try appendOpt(gpa, out, data.opt_node);
        },
        .stmt_switch => {
            const c = tree.extraData(data.extra_and_node[0], stmt.SwitchComponents);
            try out.append(gpa, data.extra_and_node[1]); // cond
            try appendRange(gpa, tree, c.cases, out);
        },
        .stmt_switch_case => {
            const c = tree.extraData(data.extra_and_opt_node[0], stmt.CaseStmtComponents);
            try appendOpt(gpa, out, data.extra_and_opt_node[1]); // value
            try appendRange(gpa, tree, c.stmts, out);
        },
        .stmt_default => {
            try appendRange(gpa, tree, data.extra_range, out);
        },
        .stmt_throw => {
            try out.append(gpa, data.node);
        },
        .stmt_try => {
            const c = tree.extraData(data.extra_and_node[0], stmt.TryComponents);
            try out.append(gpa, data.extra_and_node[1]); // body
            try appendRange(gpa, tree, c.catches, out);
            try appendOpt(gpa, out, c.finally);
        },
        .stmt_catch => {
            const c = tree.extraData(data.extra_and_node[0], stmt.CatchComponents);
            try appendRange(gpa, tree, c.types, out);
            try out.append(gpa, data.extra_and_node[1]); // body
        },
        .stmt_const => {
            try appendRange(gpa, tree, data.extra_range, out);
        },
        .const_decl => {
            try out.append(gpa, data.node_and_token[0]); // value
        },
        .stmt_use => {
            const c = tree.extraData(data.extra, stmt.UseComponents);
            try appendRange(gpa, tree, c.uses, out);
        },
        .use_use => {
            try out.append(gpa, data.extra_and_node[1]); // name
        },
        .stmt_group_use => {
            const c = tree.extraData(data.extra_and_node[0], stmt.GroupUseComponents);
            try out.append(gpa, data.extra_and_node[1]); // prefix
            try appendRange(gpa, tree, c.uses, out);
        },
        .stmt_trait_use => {
            const c = tree.extraData(data.extra, stmt.TraitUseComponents);
            try appendRange(gpa, tree, c.traits, out);
            try appendRange(gpa, tree, c.adaptations, out);
        },
        .trait_use_adaptation_alias, .trait_use_adaptation_precedence => {
            const trait = data.extra_and_opt_node[1];
            try appendOpt(gpa, out, trait);
        },
        .stmt_declare => {
            const c = tree.extraData(data.extra_and_opt_node[0], stmt.DeclareComponents);
            try appendOpt(gpa, out, data.extra_and_opt_node[1]); // stmts
            try appendRange(gpa, tree, c.declares, out);
        },
        .declare_declare => {
            try out.append(gpa, data.node_and_token[0]); // value
        },
        .stmt_goto, .stmt_label, .stmt_halt, .inline_html, .stmt_nop, .stmt_error => {},
        .stmt_global, .stmt_static, .stmt_unset => {
            try appendRange(gpa, tree, data.extra_range, out);
        },
        .static_var => {
            try appendOpt(gpa, out, tree.extraData(data.extra, stmt.StaticVarComponents).default);
        },
        .property_hook => {
            const c = tree.extraData(data.extra_and_node[0], decl.PropertyHookComponents);
            try out.append(gpa, data.extra_and_node[1]);
            try appendRange(gpa, tree, c.params, out);
            try appendRange(gpa, tree, c.attrs, out);
        },

        // 类型
        .type_union, .type_intersection => {
            try out.append(gpa, data.node_and_node[0]);
            try out.append(gpa, data.node_and_node[1]);
        },
        .type_generic => {
            const g = tree.extraData(data.extra_and_node[0], types.GenericTypeComponents);
            try out.append(gpa, data.extra_and_node[1]);
            try appendRange(gpa, tree, g.args, out);
        },
        .type_self, .type_parent, .type_static => {},

        // 名字（叶子）
        .name, .name_fully_qualified, .name_relative, .name_var_like => {},

        // 参数
        .param => {
            const c = tree.extraData(data.extra_and_opt_node[0], decl.ParamComponents);
            try appendOpt(gpa, out, c.type);
            try appendOpt(gpa, out, c.default);
            try appendRange(gpa, tree, c.attrs, out);
        },

        // 属性
        .attribute => {
            const c = tree.extraData(data.extra_and_node[0], decl.AttributeComponents);
            try out.append(gpa, data.extra_and_node[1]);
            try appendRange(gpa, tree, c.args, out);
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
            try out.append(gpa, data.node_and_range.node);
            try appendRange(gpa, tree, data.node_and_range.range, out);
        },
        .expr_static_call => {
            const c = tree.extraData(data.node_and_extra[1], expr.StaticCallComponents);
            try out.append(gpa, data.node_and_extra[0]);
            try appendRange(gpa, tree, c.args, out);
        },
        .expr_new => {
            const c = tree.extraData(data.extra_and_node[0], expr.NewComponents);
            try out.append(gpa, data.extra_and_node[1]);
            try appendRange(gpa, tree, c.args, out);
        },

        // 数组 / 列表 / 项 / 实参
        .expr_argument => try out.append(gpa, data.node_and_extra[0]),
        .expr_array_item => {
            const c = tree.extraData(data.node_and_extra[1], expr.ArrayItemComponents);
            try out.append(gpa, data.node_and_extra[0]);
            try appendOpt(gpa, out, c.key);
        },

        .expr_clone => {
            try out.append(gpa, data.node_and_opt_node[0]);
            try appendOpt(gpa, out, data.node_and_opt_node[1]);
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
            try out.append(gpa, data.node_and_node[0]);
            try out.append(gpa, data.node_and_node[1]);
        },
        .expr_array_dim_fetch => {
            try out.append(gpa, data.node_and_opt_node[0]);
            try appendOpt(gpa, out, data.node_and_opt_node[1]);
        },

        // match
        .expr_match => {
            const c = tree.extraData(data.extra_and_node[0], expr.MatchComponents);
            try out.append(gpa, data.extra_and_node[1]);
            try appendRange(gpa, tree, c.arms, out);
        },
        .expr_match_arm => {
            const c = tree.extraData(data.extra_and_node[0], expr.MatchArmComponents);
            try out.append(gpa, data.extra_and_node[1]);
            try appendRange(gpa, tree, c.exprs, out);
        },
        .expr_ternary => {
            const c = tree.extraData(data.node_and_extra[1], expr.TernaryComponents);
            try out.append(gpa, data.node_and_extra[0]);
            try appendOpt(gpa, out, c.then);
            try out.append(gpa, c.else_b);
        },

        // yield / 闭包
        .expr_yield => {
            const c = tree.extraData(data.extra, expr.YieldComponents);
            try appendOpt(gpa, out, c.key);
            try appendOpt(gpa, out, c.value);
        },
        .expr_closure => {
            const c = tree.extraData(data.extra, expr.ClosureComponents);
            try appendRange(gpa, tree, c.params, out);
            try appendOpt(gpa, out, c.ret);
            try out.append(gpa, c.body);
        },
        .expr_arrow_function => {
            const c = tree.extraData(data.extra, expr.ArrowFunctionComponents);
            try appendRange(gpa, tree, c.params, out);
            try appendOpt(gpa, out, c.ret);
            try out.append(gpa, c.body);
        },
    }
}

/// 深度优先遍历整棵树：从 `start` 出发，对每个访问到的节点调用 `visit(ctx, tree, node)`。
/// 顺序为前序（先节点本身，再其子节点）。`allocator` 仅用于遍历期间的临时栈。
///
/// ```zig
/// var count: usize = 0;
/// try php_ast.walk.walk(tree, tree.root, gpa, &count, struct {
///     fn f(c: *usize, _: php_ast.Ast, _: php_ast.Index) !void { c.* += 1; }
/// }.f);
/// ```
pub fn walk(
    tree: ast.Ast,
    start: Index,
    allocator: std.mem.Allocator,
    ctx: anytype,
    comptime visit: fn (@TypeOf(ctx), ast.Ast, Index) anyerror!void,
) !void {
    var stack = try std.ArrayList(Index).initCapacity(allocator, 0);
    defer stack.deinit(allocator);
    try stack.append(allocator, start);
    while (stack.pop()) |node| {
        try visit(ctx, tree, node);
        var children = try std.ArrayList(Index).initCapacity(allocator, 0);
        defer children.deinit(allocator);
        try childNodes(allocator, tree, node, &children);
        // 逆序压栈以保持前序遍历顺序
        var i: usize = children.items.len;
        while (i > 0) : (i -= 1) try stack.append(allocator, children.items[i - 1]);
    }
}

/// 可复用的遍历状态：预先持有「栈」与「子节点 scratch 缓冲」，使一次遍历只分配
/// 一次（预热后零分配），而非像 `walk` 那样每个节点都新建一份子节点缓冲。
///
/// 适合在同一进程里反复遍历多棵树、或对单棵大树做多次遍历的场景（如统计 + 改写两轮）。
pub const WalkState = struct {
    allocator: std.mem.Allocator,
    stack: std.ArrayList(Index),
    children: std.ArrayList(Index),

    /// 分配底层缓冲（容量从 0 起步，首次遍历时按需增长到能容纳最深节点的子节点数后稳定）。
    pub fn init(allocator: std.mem.Allocator) !WalkState {
        return .{
            .allocator = allocator,
            .stack = try std.ArrayList(Index).initCapacity(allocator, 0),
            .children = try std.ArrayList(Index).initCapacity(allocator, 0),
        };
    }

    pub fn deinit(self: *WalkState) void {
        self.stack.deinit(self.allocator);
        self.children.deinit(self.allocator);
    }
};

/// 深度优先前序遍历的「零每节点分配」变体：复用 `state` 持有的栈与子节点缓冲，
/// 不产生 `walk` 那样的每节点 `ArrayList` 分配。语义与 `walk` 完全一致（前序、栈内逆序压栈）。
///
/// ```zig
/// var ws = try php_ast.walk.WalkState.init(gpa);
/// defer ws.deinit();
/// var count: usize = 0;
/// try php_ast.walk.walkStack(tree, tree.root, &ws, &count, struct {
///     fn f(c: *usize, _: php_ast.Ast, _: php_ast.Index) !void { c.* += 1; }
/// }.f);
/// ```
pub fn walkStack(
    tree: ast.Ast,
    start: Index,
    state: *WalkState,
    ctx: anytype,
    comptime visit: fn (@TypeOf(ctx), ast.Ast, Index) anyerror!void,
) !void {
    state.stack.clearRetainingCapacity();
    try state.stack.append(state.allocator, start);
    while (state.stack.pop()) |node| {
        try visit(ctx, tree, node);
        state.children.clearRetainingCapacity();
        try childNodes(state.allocator, tree, node, &state.children);
        // 逆序压栈以保持前序遍历顺序
        var i: usize = state.children.items.len;
        while (i > 0) : (i -= 1) try state.stack.append(state.allocator, state.children.items[i - 1]);
    }
}

/// 取紧贴 `node` 之前、仅被注释/文档注释隔开的注释 token 列表（按源码顺序）。
/// 注释始终作为 token 保留，本函数按需向前扫描还原 `leading_comments`。
pub fn leadingComments(gpa: std.mem.Allocator, tree: ast.Ast, node: Index, out: *std.ArrayList(TokenIndex)) !void {
    const ft = tree.firstToken(node);
    if (ft == 0) return;
    var i = ft;
    while (i > 0) {
        i -= 1;
        const tg = tree.tokenTag(i);
        if (tg == .comment or tg == .doc_comment) {
            try out.append(gpa, i);
        } else break;
    }
    std.mem.reverse(TokenIndex, out.items);
}

/// 取紧贴 `node` 之后、仅被注释/文档注释隔开的注释 token 列表（按源码顺序）。
pub fn trailingComments(gpa: std.mem.Allocator, tree: ast.Ast, node: Index, out: *std.ArrayList(TokenIndex)) !void {
    const lt = tree.lastToken(node);
    var i = lt + 1;
    while (i < tree.tokens.len) : (i += 1) {
        const tg = tree.tokenTag(i);
        if (tg == .comment or tg == .doc_comment) {
            try out.append(gpa, i);
        } else break;
    }
}
