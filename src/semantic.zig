//! 旁路语义校验层：对已解析的 AST 做引擎级语义检查（拒绝面判据）。
//!
//! 定位（与 `doc/special.md` P6 的分层一致）：php-parser 的 parse 带语义检查
//! （grammar 动作里即报），本项目把检查与 parse **解耦**——`Ast.parse` 默认宽松，
//! 只报语法层诊断；需要严格模式（IDE 即时提示、门禁）的调用方对同一棵树再跑
//! `semantic.check`，得到第二份诊断列表（错误 tag 同 `ast.Error.Tag` 的
//! `semantic_*` 家族）。合法代码在两层都不产生诊断。
//!
//! 另一部分引擎级语义诊断（修饰符重复 / const 非法修饰符 / 方法 readonly）在
//! **解析期就地**收集（见 `parser_decl.zig` `parsePropertyModifiers`）：那些事实在
//! 修饰符收集循环中被消费后不可恢复，无法事后判定，且 php-parser 同样在语法期
//! recover 处理。
//!
//! 用法：
//! ```zig
//! var tree = try ast.Ast.parse(gpa, src, version);   // parse 宽松
//! defer tree.deinit(gpa);
//! var ck = semantic.Checker.init(gpa);               // 可选语义校验
//! defer ck.deinit();
//! try ck.run(&tree);
//! for (ck.errors.items) |e| { ... }
//! ```

const std = @import("std");
const ast = @import("ast.zig");
const Token = @import("token.zig").Token;
const version = @import("version.zig");
const BASE_VERSION = version.BASE_VERSION;
const stmt = @import("parser_stmt.zig");
const decl = @import("parser_decl.zig");
const parent_map = @import("parent_map.zig");
const testing = @import("testing.zig");

const Node = ast.Node;
const Index = ast.Index;
const TokenIndex = ast.TokenIndex;

/// 语义校验器：`run(tree)` 向 `errors` 追加全部语义诊断（不修改树）。
pub const Checker = struct {
    gpa: std.mem.Allocator,
    errors: std.ArrayList(ast.Error),

    pub fn init(gpa: std.mem.Allocator) Checker {
        return .{ .gpa = gpa, .errors = .empty };
    }

    pub fn deinit(self: *Checker) void {
        self.errors.deinit(self.gpa);
        self.* = undefined;
    }

    /// 记录一条语义诊断。诊断区间默认单 token；消息需引用具体文本（保留名、
    /// 修饰符名等）时把该 token 作为 `aux` 传入。
    fn add(self: *Checker, tag: ast.Error.Tag, token: TokenIndex) void {
        self.addRange(tag, token, token, token, 0);
    }

    fn addRange(
        self: *Checker,
        tag: ast.Error.Tag,
        start: TokenIndex,
        end: TokenIndex,
        aux: TokenIndex,
        data: u32,
    ) void {
        self.errors.append(self.gpa, .{
            .tag = tag,
            .token = start,
            .token_end = end,
            .aux = aux,
            .data = data,
            .required = BASE_VERSION,
        }) catch {};
    }

    /// 对整树执行全部语义判据。诊断追加到 `self.errors`，调用方用毕 `deinit`。
    pub fn run(self: *Checker, tree: *const ast.Ast) !void {
        var pm = try parent_map.build(self.gpa, tree.*, tree.root);
        defer pm.deinit();

        // 判据一：逐节点局部检查（保留名 / 魔法方法 / 参数 / 钩子 / try 等）。
        var i: usize = 0;
        while (i < tree.nodes.len) : (i += 1) {
            try checkNode(self, tree, &pm, @enumFromInt(i));
        }
        // 判据二：namespace 顶层状态机（跨语句序列，独立递归）。
        try checkTopLevel(self, tree, tree.rootStmts());
    }

    /// 便捷入口：直接返回错误数组（调用方 `gpa.free`）。
    pub fn check(gpa: std.mem.Allocator, tree: *const ast.Ast) ![]ast.Error {
        var ck = Checker.init(gpa);
        defer ck.deinit();
        try ck.run(tree);
        return ck.errors.toOwnedSlice(gpa);
    }
};

// ---------------------------------------------------------------------------
// 判据一：逐节点
// ---------------------------------------------------------------------------

fn checkNode(self: *Checker, tree: *const ast.Ast, pm: *const parent_map.ParentMap, node: Index) !void {
    const data = tree.nodeData(node);
    switch (tree.nodeTag(node)) {
        // __HALT_COMPILER() 只能在最外层作用域：父链上出现任何块/控制流/函数体即非法。
        .stmt_halt => {
            if (isInsideBlock(tree, pm, node)) {
                self.add(.halt_not_outermost, tree.nodeMainToken(node));
            }
        },
        // 类 / 接口 / 枚举 / trait 的保留名检查。php-parser 的消息词按**槽位**而非
        // 节点类型（fixture 反推）：
        //   - 声明名（含 interface 名）与 class 的 extends → `class name`
        //   - implements 与 interface 的 extends → `interface name`
        .stmt_class => {
            const c = tree.extraData(data.extra_and_opt_node[0], decl.ClassComponents);
            checkReservedDeclName(self, tree, .reserved_class_name, c.name);
            if (c.extends.unwrap()) |e| checkReservedNameNode(self, tree, .reserved_class_name, e);
            try checkReservedList(self, tree, .reserved_interface_name, c.implements);
        },
        .stmt_interface, .stmt_enum, .stmt_trait => {
            const c = tree.extraData(data.extra_and_opt_node[0], decl.TypeDeclComponents);
            // 声明名恒用 class 消息（interface self 亦报 class name——php-parser 如此）；
            // extends/implements 槽位用 interface 消息。
            checkReservedDeclName(self, tree, .reserved_class_name, c.name);
            try checkReservedList(self, tree, .reserved_interface_name, c.ext_impl);
        },
        // 魔法方法不能 static（__construct / __destruct / __clone，大小写不敏感）。
        .stmt_method => {
            const c = tree.extraData(data.extra_and_opt_node[0], decl.MethodComponents);
            if ((c.flags & 4) != 0) {
                const name = tree.tokenSlice(c.name);
                if (std.ascii.eqlIgnoreCase(name, "__construct")) {
                    // 区间为 `static` 修饰符本身（php-parser 报在修饰符上）
                    self.addRange(.static_constructor, c.mod_start, c.mod_start, c.name, 0);
                } else if (std.ascii.eqlIgnoreCase(name, "__destruct")) {
                    self.addRange(.static_destructor, c.mod_start, c.mod_start, c.name, 0);
                } else if (std.ascii.eqlIgnoreCase(name, "__clone")) {
                    self.addRange(.static_clone, c.mod_start, c.mod_start, c.name, 0);
                }
            }
        },
        // 参数：void 类型非法；变参不能带默认值。
        .param => {
            const c = tree.extraData(data.extra_and_opt_node[0], decl.ParamComponents);
            if (c.variadic and c.default.unwrap() != null) {
                // 区间为默认值表达式本身（不含 `=`），与 php-parser 一致
                const d = c.default.unwrap().?;
                self.addRange(.variadic_default, tree.firstToken(d), tree.lastToken(d), c.name, 0);
            }
            // 提升属性（8.4 构造器属性提升）的钩子块同样适用钩子规则：
            // 空钩子块 `__construct(public $p {})` 非法。
            if (c.has_hook_block and c.hooks.start == c.hooks.end) {
                const lb = if (c.hook_lbrace != 0) c.hook_lbrace else tree.nodeMainToken(node);
                self.add(.hook_empty, lb);
            }
            // void 类型自 7.1 引入并禁止作参数类型；7.0 下 void 仍是普通名字。
            if (tree.version.id >= 70100) {
                if (c.type.unwrap()) |ty| {
                    if (tree.nodeTag(ty) == .type_name) {
                        const tname = tree.tokenSlice(tree.nodeMainToken(ty));
                        if (std.mem.eql(u8, tname, "void")) {
                            // 区间为参数类型（`void`），非参数名
                            self.addRange(.void_parameter, tree.firstToken(ty), tree.lastToken(ty), c.name, 0);
                        }
                    }
                }
            }
        },
        // try 必须有 catch 或 finally。
        .stmt_try => {
            const c = tree.extraData(data.extra_and_node[0], stmt.TryComponents);
            if (c.catches.start == c.catches.end and c.finally.unwrap() == null) {
                // 区间为整个 try 语句（`try { ... }`）
                self.addRange(.try_without_catch, tree.firstToken(node), tree.lastToken(node), tree.firstToken(node), 0);
            }
        },
        // 属性：空钩子块 `$a { }` / 多属性带钩子。
        .stmt_property => {
            const c = tree.extraData(data.extra_and_opt_node[0], decl.PropertyComponents);
            // 空钩子块 `$p { }`：定位在 `{` 上；与「多属性带钩子」各自独立判定——
            // `public $foo, $bar { }` 两者同时成立，php-parser 报两条。
            const lb = if (c.hook_lbrace != 0) c.hook_lbrace else tree.nodeMainToken(node);
            // 顺序：先「多属性带钩子」再「空钩子块」（`public $foo, $bar { }` 两者
            // 同时成立，php-parser 按此顺序报两条）。
            if (c.has_hook_block and rangeLen(c.props) > 1) {
                self.add(.hook_multi_property, lb);
            }
            if (c.has_hook_block and c.hooks.start == c.hooks.end) {
                self.add(.hook_empty, lb);
            }
        },
        // get 钩子不能带参数表（`get()` / `get($x)`）。
        .property_hook => {
            const c = tree.extraData(data.extra_and_opt_node[0], decl.PropertyHookComponents);
            const name = tree.tokenSlice(c.name);
            if (std.ascii.eqlIgnoreCase(name, "get") and c.has_param_list) {
                // 定位在参数表的 `(` 上（php-parser 同），区间为该单个 token
                const lp = if (c.lparen != 0) c.lparen else c.name;
                self.add(.hook_get_params, lp);
            }
        },
        // 一条声明内的多个常量带注解：注解只能挂在首个常量上。
        .stmt_const => {
            const c = tree.extraData(data.extra, stmt.ConstComponents);
            if (c.attrs.start != c.attrs.end and rangeLen(c.decls) > 1) {
                // 区间为整条 const 声明（含属性组与末尾 `;`）
                self.addRange(.const_attr_multi, tree.firstToken(node), tree.lastToken(node), tree.firstToken(node), 0);
            }
        },
        .stmt_class_const => {
            const c = tree.extraData(data.extra_and_opt_node[0], decl.ClassConstComponents);
            if (c.attrs.start != c.attrs.end and rangeLen(c.decls) > 1) {
                self.addRange(.const_attr_multi, tree.firstToken(node), tree.lastToken(node), tree.firstToken(node), 0);
            }
        },
        // use ... as self/parent/static：保留类名不能作别名。
        .use_use => {
            const c = tree.extraData(data.extra_and_node[0], stmt.UseUseComponents);
            if (c.alias != 0 and isReservedWordText(tree, c.alias)) {
                // 消息含被导入原名（`token`）与别名（`aux`）：`Cannot use A as self
                // because 'self' is a special class name`
                // 区间为别名 token；`data` 携带被导入原名 token 供消息引用
                const name_node = data.extra_and_node[1];
                self.addRange(.special_class_name_alias, c.alias, c.alias, c.alias, tree.firstToken(name_node));
            }
        },
        // `$a =& new B` 自 PHP 7.0 起禁止（5.6 合法）。
        .expr_assign_ref => {
            const right = data.node_and_node[1];
            if (tree.nodeTag(right) == .expr_new and tree.version.id >= 70000) {
                // 区间覆盖整个 `$a =& new B`（左值首 token → 右值末 token），
                // 与 php-parser 的 `from 2:1 to 2:11` 一致
                self.addRange(.assign_new_by_ref, tree.firstToken(node), tree.lastToken(node), tree.firstToken(node), 0);
            }
        },
        // 数组字面量空槽 `[1, , 2]` 自 PHP 8.0 起禁止（php-parser 报错后以
        // Expr_Error 占位）。解构上下文（赋值左值 `[$a, , $b] = `、foreach 值
        // `foreach ($x as [$a, , $b])`）空槽仍合法——需父角色判定。
        .expr_array => {
            if (tree.version.id >= 80000 and !isDestructureTarget(tree, pm, node)) {
                const items = tree.extraDataSlice(data.extra_and_token[0], Index);
                for (items) |it| {
                    if (tree.nodeTag(it) == .expr_array_hole) {
                        self.add(.array_empty_element, tree.nodeMainToken(it));
                        break;
                    }
                }
            }
        },
        // `|>` 右侧的箭头函数必须加括号（8.5）。php.y 在 pipe 归约时检查右侧是否
        // 为「整括号包裹的 arrow」：括号产生式把整体包裹的 ArrowFunction 记入集合，
        // 未记录则报错。树中括号不产生节点，需从 arrow 首 token 前查分组左括号。
        .expr_pipe => {
            // 管道链：只在链首（父不是 pipe）统一处理——php-parser 按归约顺序
            // 先报内层（右侧）再报外层，逐节点遍历会顺序颠倒。
            if (pm.parentOf(node)) |par| {
                if (tree.nodeTag(par) == .expr_pipe) return;
            }
            try checkPipeChain(self, tree, node);
        },
        else => {},
    }
}

/// 父链上是否出现「作用域块」（halt 判据）。namespace 的伪作用域不算。
fn isInsideBlock(tree: *const ast.Ast, pm: *const parent_map.ParentMap, node: Index) bool {
    var cur = pm.parentOf(node);
    while (cur) |n| {
        switch (tree.nodeTag(n)) {
            .stmt_block, .stmt_if, .stmt_while, .stmt_for, .stmt_foreach, .stmt_do,
            .stmt_switch, .stmt_switch_case, .stmt_try, .stmt_catch, .stmt_function,
            .stmt_method, .expr_closure, .expr_arrow_function, .stmt_declare,
            => return true,
            else => {},
        }
        cur = pm.parentOf(n);
    }
    return false;
}

/// 声明名（类 / 接口 / 枚举 / trait 的名字 token）是否为保留字。
fn checkReservedDeclName(self: *Checker, tree: *const ast.Ast, tag: ast.Error.Tag, name_tok: TokenIndex) void {
    if (isReservedWordText(tree, name_tok)) {
        self.add(tag, name_tok);
    }
}

/// 名字节点（extends / implements / interface extends 的子名）是否为保留字。
fn checkReservedNameNode(self: *Checker, tree: *const ast.Ast, tag: ast.Error.Tag, name_node: Index) void {
    const text = tree.tokenSlice(tree.nodeMainToken(name_node));
    if (isReservedText(text)) {
        self.add(tag, tree.nodeMainToken(name_node));
    }
}

fn checkReservedList(self: *Checker, tree: *const ast.Ast, tag: ast.Error.Tag, range: ast.SubRange) !void {
    for (tree.extraDataSlice(range, Index)) |n| checkReservedNameNode(self, tree, tag, n);
}

/// SubRange 的元素数（start/end 为 `ExtraIndex` 枚举，需数值转换）。
fn rangeLen(r: ast.SubRange) usize {
    return @intFromEnum(r.end) - @intFromEnum(r.start);
}

/// 管道链（`a |> f |> g`）的箭头函数括号判据：由内层向外层依次报（php-parser
/// 的归约顺序——右侧 pipe 先归约，故其诊断先产出）。
fn checkPipeChain(self: *Checker, tree: *const ast.Ast, node: Index) !void {
    const rhs = tree.nodeData(node).node_and_node[1];
    // 内层先归约、先报（php-parser 顺序）：`a |> (X |> Y)` 右结合。
    if (tree.nodeTag(rhs) == .expr_pipe) try checkPipeChain(self, tree, rhs);
    if (tree.version.id < 80500) return;
    // 右操作数必须「整体括号包裹」——未包裹即报，区间为整个右操作数。
    // （右操作数是箭头函数或嵌套管道链均适用。）
    const is_rhs_operand = tree.nodeTag(rhs) == .expr_arrow_function or tree.nodeTag(rhs) == .expr_pipe;
    if (is_rhs_operand and !isParenthesizedOperand(tree, rhs)) {
        self.addRange(.pipe_arrow_unparenthesized, tree.firstToken(rhs), tree.lastToken(rhs), tree.firstToken(rhs), 0);
    }
}

/// expr_array 是否处于解构上下文（赋值左值 / foreach 值）——空槽仅在此合法。
/// 解构可嵌套（`[[$a, , $x], $b] = $c`），沿 expr_array_item / expr_array /
/// expr_list 容器链上溯到最外层容器，其父若是赋值左值或 foreach 值即豁免。
fn isDestructureTarget(tree: *const ast.Ast, pm: *const parent_map.ParentMap, arr: Index) bool {
    var cur = arr;
    while (pm.parentOf(cur)) |p| {
        switch (tree.nodeTag(p)) {
            .expr_array_item, .expr_array, .expr_list => {
                cur = p;
            },
            else => {
                const pd = tree.nodeData(p);
                switch (tree.nodeTag(p)) {
                    .expr_assign, .expr_assign_ref, .expr_assign_op => return pd.node_and_node[0] == cur,
                    .stmt_foreach => return pd.extra_and_node[1] == cur, // ForEachComponents.value
                    else => return false,
                }
            },
        }
    }
    return false;
}

/// 表达式是否整体被括号包裹：其首个 token 之前（跳过注释）是分组左括号。
/// 括号在 AST 中不产生节点，只能从 token 序列还原此事实（php.y 以
/// `parenthesizedArrowFunctions` 集合登记同一事实）。括号内只包一个表达式时，
/// 其前一个有效 token 即分组 `(`。
fn isParenthesizedOperand(tree: *const ast.Ast, node: Index) bool {
    var i = tree.firstToken(node);
    if (i == 0) return false;
    while (i > 0) {
        i -= 1;
        switch (tree.tokenTag(i)) {
            .comment, .doc_comment => continue,
            else => return tree.tokenTag(i) == .lparen,
        }
    }
    return false;
}

/// 单个名字是否保留（self / parent / static，大小写不敏感）。
fn isReservedText(text: []const u8) bool {
    return std.ascii.eqlIgnoreCase(text, "self") or
        std.ascii.eqlIgnoreCase(text, "parent") or
        std.ascii.eqlIgnoreCase(text, "static");
}

/// 声明名 token 是否为保留字：除 self/parent/static 外，`readonly` 自 PHP 8.0
/// 起成为关键字、不可再作类名（7.x 下 `class ReadOnly` 合法）。
fn isReservedWordText(tree: *const ast.Ast, tok: TokenIndex) bool {
    const text = tree.tokenSlice(tok);
    if (isReservedText(text)) return true;
    return std.ascii.eqlIgnoreCase(text, "readonly") and tree.version.id >= 80000;
}

// ---------------------------------------------------------------------------
// 判据二：namespace 顶层状态机
// ---------------------------------------------------------------------------

/// bracketed 形式：结束定界符是 `}`（NamespaceComponents.close）。
fn isBracketedNs(tree: *const ast.Ast, ns: Index) bool {
    const c = tree.extraData(tree.nodeData(ns).extra_and_opt_node[0], stmt.NamespaceComponents);
    return tree.tokenTag(c.close) == .rbrace;
}

fn nsStmts(tree: *const ast.Ast, ns: Index) []const Index {
    const c = tree.extraData(tree.nodeData(ns).extra_and_opt_node[0], stmt.NamespaceComponents);
    return tree.extraDataSlice(c.stmts, Index);
}

/// 递归检查单个 namespace 声明内部嵌套的 namespace。php-parser 接受**连续**
/// unbracketed namespace（后一个把前一个的收集范围切开）；本库 parse 的
/// unbracketed namespace 会把后续代码连同后续 namespace 声明一并吞进自身 stmts
/// （嵌套形态），此处按形态换算回声明序列语义：
/// - 外层 bracketed、内嵌任意 namespace → nested（bracketed 体内不允许 namespace）；
/// - 外层 unbracketed、内嵌 bracketed → mixed（unbracketed 后不得再用 bracketed）；
/// - 外层 unbracketed、内嵌 unbracketed → 连续声明，合法（继续向内递归）。
fn checkNestedNs(self: *Checker, tree: *const ast.Ast, ns: Index) !void {
    const outer_bracketed = isBracketedNs(tree, ns);
    for (nsStmts(tree, ns)) |s| {
        if (tree.nodeTag(s) != .stmt_namespace) continue;
        if (outer_bracketed) {
            // 区间为整个内嵌 namespace 声明
            self.addRange(.namespace_nested, tree.firstToken(s), tree.lastToken(s), tree.firstToken(s), 0);
        } else if (!isBracketedNs(tree, s)) {
            // 外层 unbracketed、内嵌 unbracketed：连续声明，合法。
        } else {
            // 混用：php-parser 定位在后一个 `namespace` 关键字上
            self.addRange(.namespace_mixed, tree.nodeMainToken(s), tree.nodeMainToken(s), tree.nodeMainToken(s), 0);
        }
        try checkNestedNs(self, tree, s);
    }
}

/// 顶层声明序列状态机（rootStmts）。
///
/// PHP 规则：unbracketed namespace 必须是脚本首个语句（其前只允许 declare/
/// 空语句等非代码语句）；出现 bracketed namespace 后，脚本其余部分除
/// `__HALT_COMPILER()` 收尾外不得再有代码；bracketed 与 unbracketed 混用报错。
fn checkTopLevel(self: *Checker, tree: *const ast.Ast, stmts: []const Index) !void {
    var seen_bracketed = false;
    var prefix_bracketed = false; // 当前语句前出现过 bracketed namespace
    var prefix_code = false; // 当前语句前出现过不可忽略的普通语句
    var outside_reported = false; // 越界代码只报第一条（php-parser 同）
    // 若 bracketed namespace 之后既有代码又出现 unbracketed namespace，php-parser
    // 只报 Cannot mix（状态机在遇到 namespace 时优先判混用），故先预扫判定。
    const has_mix = detectMixAfterCode(tree, stmts);
    for (stmts) |s| {
        if (tree.nodeTag(s) == .stmt_namespace) {
            try checkNestedNs(self, tree, s);
            if (isBracketedNs(tree, s)) {
                seen_bracketed = true;
                prefix_bracketed = true;
            } else {
                // unbracketed：吞掉其后全部代码，正常应位于 rootStmts 末尾。
                // 二者均定位在 `namespace` 关键字上（php-parser 用关键字 token 报）
                const nsk = tree.nodeMainToken(s);
                if (prefix_bracketed) self.addRange(.namespace_mixed, nsk, nsk, nsk, 0)
                else if (prefix_code) self.addRange(.namespace_not_first, nsk, nsk, nsk, 0);
            }
            continue;
        }
        // bracketed namespace 之后只允许 __HALT_COMPILER() 收尾（php-parser
        // outsideStmt 用例：declare + bracketed + halt 合法）与注释/空语句
        // （commentAfterNamespace：`namespace Foo {}` 后行注释产 stmt_nop 合法）。
        // 区间为整条越界语句（含末尾 `;`）；只报第一条（php-parser 在首个越界处
        // 报错后即停止该状态检查）。存在 mix 情形时不报越界（php-parser 只报 mix）。
        if (seen_bracketed and !has_mix and !outside_reported and
            tree.nodeTag(s) != .stmt_halt and tree.nodeTag(s) != .stmt_nop)
        {
            self.addRange(.namespace_code_outside, tree.firstToken(s), tree.lastToken(s), tree.firstToken(s), 0);
            outside_reported = true;
        }
        if (!isIgnorablePrefixStmt(tree, s)) prefix_code = true;
    }
}

/// 预扫：bracketed namespace 之后是否既有普通代码、又出现 unbracketed namespace
/// （`namespace A {} echo 1; namespace B;`）——php-parser 此种只报 Cannot mix。
fn detectMixAfterCode(tree: *const ast.Ast, stmts: []const Index) bool {
    var bracketed = false;
    var code = false;
    for (stmts) |s| {
        if (tree.nodeTag(s) == .stmt_namespace) {
            if (isBracketedNs(tree, s)) {
                bracketed = true;
            } else if (bracketed and code) {
                return true;
            }
            continue;
        }
        if (bracketed and tree.nodeTag(s) != .stmt_halt and tree.nodeTag(s) != .stmt_nop) code = true;
    }
    return false;
}

/// unbracketed namespace 前的可忽略语句：declare（任意编译指示）与空语句 `;`。
fn isIgnorablePrefixStmt(tree: *const ast.Ast, s: Index) bool {
    return tree.nodeTag(s) == .stmt_declare or tree.nodeTag(s) == .stmt_nop;
}

// ===========================================================================
// 测试：语义校验层
// ===========================================================================

fn countErr(errs: []const ast.Error, tag: ast.Error.Tag) usize {
    var n: usize = 0;
    for (errs) |e| {
        if (e.tag == tag) n += 1;
    }
    return n;
}

fn expectSemanticErrors(gpa: std.mem.Allocator, src: [:0]const u8, want: []const ast.Error.Tag) !void {
    var tree = try ast.Ast.parse(gpa, src, testing.v85);
    defer tree.deinit(gpa);
    try testing.expectNoErrors(tree); // parse 宽松：语法层必须干净
    var ck = Checker.init(gpa);
    defer ck.deinit();
    try ck.run(&tree);
    for (want) |expected_tag| {
        if (countErr(ck.errors.items, expected_tag) == 0) {
            std.debug.print("\n[semantic] 期望诊断 {s}，实际: ", .{@tagName(expected_tag)});
            var buf: [128]u8 = undefined;
            for (ck.errors.items) |e| std.debug.print("{s} ", .{e.format(&tree, &buf)});
            std.debug.print("\n", .{});
            return error.TestUnexpectedResult;
        }
    }
}

test "semantic :: magic 方法 :: static __construct/__destruct/__clone 非法（大小写不敏感）" {
    const gpa = std.testing.allocator;
    try expectSemanticErrors(gpa, "<?php class A { static function __construct() {} }", &.{.static_constructor});
    try expectSemanticErrors(gpa, "<?php class A { static function __CLONE() {} }", &.{.static_clone});
    try expectSemanticErrors(gpa, "<?php class A { static function __destruct() {} }", &.{.static_destructor});
    // 非魔法方法 static 合法
    try expectSemanticErrors(gpa, "<?php class A { static function foo() {} }", &.{});
}

test "semantic :: 参数 :: void 类型与变参默认值" {
    const gpa = std.testing.allocator;
    try expectSemanticErrors(gpa, "<?php function foo(void $foo) {}", &.{.void_parameter});
    try expectSemanticErrors(gpa, "<?php function foo(...$foo = []) {}", &.{.variadic_default});
    try expectSemanticErrors(gpa, "<?php function foo(string $s, ...$rest) {}", &.{});
    // void 类型 7.1 引入：7.0 下 void 仍是普通名字、可作参数类型
    var tree = try ast.Ast.parse(gpa, "<?php function foo(void $foo) {}", .{ .id = 70000 });
    defer tree.deinit(gpa);
    var ck = Checker.init(gpa);
    defer ck.deinit();
    try ck.run(&tree);
    try std.testing.expectEqual(@as(usize, 0), countErr(ck.errors.items, .void_parameter));
}

test "semantic :: try :: 无 catch 与 finally" {
    const gpa = std.testing.allocator;
    try expectSemanticErrors(gpa, "<?php try { foo(); }", &.{.try_without_catch});
    try expectSemanticErrors(gpa, "<?php try { foo(); } catch (E $e) {}", &.{});
    try expectSemanticErrors(gpa, "<?php try { foo(); } finally {}", &.{});
}

test "semantic :: 属性钩子 :: 空列表 / get 带参数 / 多属性" {
    const gpa = std.testing.allocator;
    try expectSemanticErrors(gpa, "<?php class T { public $p {} }", &.{.hook_empty});
    try expectSemanticErrors(gpa, "<?php class T { public $p { get() => 1; } }", &.{.hook_get_params});
    try expectSemanticErrors(gpa, "<?php class T { public $p, $q { get { return 1; } } }", &.{.hook_multi_property});
    // 合法钩子
    try expectSemanticErrors(gpa, "<?php class T { public $p { get { return 1; } set { } } }", &.{});
}

test "semantic :: 常量注解 :: 一条声明多个常量" {
    const gpa = std.testing.allocator;
    try expectSemanticErrors(gpa,
        \\<?php
        \\#[Example]
        \\const A = 1, B = 2;
    , &.{.const_attr_multi});
    try expectSemanticErrors(gpa,
        \\<?php
        \\class C {
        \\    #[Example]
        \\    const A = 1, B = 2;
        \\}
    , &.{.const_attr_multi});
}

test "semantic :: 保留名 :: 类/接口名与继承/实现/别名" {
    const gpa = std.testing.allocator;
    try expectSemanticErrors(gpa, "<?php class self {}", &.{.reserved_class_name});
    try expectSemanticErrors(gpa, "<?php class PARENT {}", &.{.reserved_class_name});
    try expectSemanticErrors(gpa, "<?php class A extends self {}", &.{.reserved_class_name});
    try expectSemanticErrors(gpa, "<?php class A implements static {}", &.{.reserved_interface_name});
    try expectSemanticErrors(gpa, "<?php interface A extends PARENT {}", &.{.reserved_interface_name});
    try expectSemanticErrors(gpa, "<?php use A as self;", &.{.special_class_name_alias});
    // readonly 作类名：8.0+ 保留
    try expectSemanticErrors(gpa, "<?php class ReadOnly {}", &.{.reserved_class_name});
}

test "semantic :: halt :: 非最外层作用域" {
    const gpa = std.testing.allocator;
    try expectSemanticErrors(gpa, "<?php if (true) { __halt_compiler(); }", &.{.halt_not_outermost});
    try expectSemanticErrors(gpa, "<?php __halt_compiler();", &.{});
}

test "semantic :: namespace :: 嵌套 / 混用 / 越界代码 / 非首语句" {
    const gpa = std.testing.allocator;
    try expectSemanticErrors(gpa,
        "<?php namespace A { namespace B { } }",
        &.{.namespace_nested});
    try expectSemanticErrors(gpa,
        "<?php namespace A; echo 1; namespace B { }",
        &.{.namespace_mixed});
    try expectSemanticErrors(gpa,
        "<?php namespace A {} namespace B;",
        &.{.namespace_mixed});
    try expectSemanticErrors(gpa,
        "<?php echo 1; namespace A;",
        &.{.namespace_not_first});
    try expectSemanticErrors(gpa,
        "<?php namespace A {} echo 1;",
        &.{.namespace_code_outside});
    try expectSemanticErrors(gpa,
        "<?php namespace A; echo 1;",
        &.{});
    // 连续 unbracketed namespace / nop 前导 / bracketed 后 halt 均合法
    try expectSemanticErrors(gpa,
        "<?php namespace Foo\\Bar; foo; namespace Bar; bar;",
        &.{});
    try expectSemanticErrors(gpa,
        "<?php ; namespace Foo;",
        &.{});
    try expectSemanticErrors(gpa,
        "<?php declare(A='B'); namespace B {} __halt_compiler();",
        &.{});
}

test "semantic :: 遍历冒烟 :: 一元/结构节点 forEachChild 不崩（覆盖 expr_clone 等）" {
    const gpa = std.testing.allocator;
    const src =
        \\<?php
        \\clone $a;
        \\$b = @foo();
        \\throw new E();
        \\print 1;
        \\${'x'} = 1;
    ;
    var tree = try ast.Ast.parse(gpa, src, testing.v85);
    defer tree.deinit(gpa);
    var ck = Checker.init(gpa);
    defer ck.deinit();
    try ck.run(&tree); // 全节点遍历 + parent_map 构建
}

test "semantic :: 管道 :: 右侧箭头函数必须加括号（8.5）" {
    const gpa = std.testing.allocator;
    try expectSemanticErrors(gpa, "<?php $a |> fn($x) => $x;", &.{.pipe_arrow_unparenthesized});
    // 链式未括号：外层 pipe 与 fn 体内 pipe 各一处
    try expectSemanticErrors(gpa, "<?php $a |> fn($x) => $x |> fn($y) => $y;", &.{ .pipe_arrow_unparenthesized, .pipe_arrow_unparenthesized });
    // 括号包裹合法
    try expectSemanticErrors(gpa, "<?php $a |> (fn($x) => $x);", &.{});
    try expectSemanticErrors(gpa, "<?php $a |> (fn($x) => $x) |> (fn($y) => $y);", &.{});
    // 非箭头右侧合法
    try expectSemanticErrors(gpa, "<?php $a |> strlen;", &.{});
}

test "semantic :: 数组空槽 :: 8.0+ 字面量禁止、解构左值豁免" {
    const gpa = std.testing.allocator;
    try expectSemanticErrors(gpa, "<?php [1, , 2];", &.{.array_empty_element});
    try expectSemanticErrors(gpa, "<?php array(1, , 2);", &.{.array_empty_element});
    // 解构上下文合法：赋值左值 / foreach 值
    try expectSemanticErrors(gpa, "<?php [$a, , $b] = $c;", &.{});
    try expectSemanticErrors(gpa, "<?php foreach ($x as [$a, , $b]) {}", &.{});
    // 7.x 字面量空槽合法（PHP 8.0 才移除）
    var tree = try ast.Ast.parse(gpa, "<?php [1, , 2];", .{ .id = 70400 });
    defer tree.deinit(gpa);
    var ck = Checker.init(gpa);
    defer ck.deinit();
    try ck.run(&tree);
    try std.testing.expectEqual(@as(usize, 0), countErr(ck.errors.items, .array_empty_element));
}

test "semantic :: 引用赋值 new :: 仅 PHP 7.0 起禁止" {
    const gpa = std.testing.allocator;
    var tree = try ast.Ast.parse(gpa, "<?php $a =& new B;", testing.v85);
    defer tree.deinit(gpa);
    try testing.expectNoErrors(tree);
    var ck = Checker.init(gpa);
    defer ck.deinit();
    try ck.run(&tree);
    try std.testing.expectEqual(@as(usize, 1), countErr(ck.errors.items, .assign_new_by_ref));

    var tree56 = try ast.Ast.parse(gpa, "<?php $a =& new B;", .{ .id = 50600 });
    defer tree56.deinit(gpa);
    var ck56 = Checker.init(gpa);
    defer ck56.deinit();
    try ck56.run(&tree56);
    try std.testing.expectEqual(@as(usize, 0), countErr(ck56.errors.items, .assign_new_by_ref));
}
