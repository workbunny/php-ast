//! 名字解析：把 `use` 别名与当前命名空间应用到名字引用，解析为完全限定名。
//!
//! 语义对齐 php-parser `NameContext` / `NodeVisitor\NameResolver`
//! （见 `reference/PHP-Parser-full-5.8.0/lib/PhpParser/`）。落在 SoA 上的形态：
//! - 名字文本由 token 区间表达、token 流固定，无法原地改写 → 产出**旁表**
//!   （`Resolution`：名字节点下标 → FQN 文本），下游经 `lookup` 查询；
//! - 别名三类（class/function/constant），键小写（类/函数不区分大小写，常量区分）；
//! - 仅解析 `.name`（相对名）。`name_fully_qualified` 已 FQ、`name_relative`
//!   （`namespace\Foo`）语义固定、`name_var_like`（`$var`）非名字——均不解析。
//!
//! 解析规则（对齐 `getResolvedName`）：
//! - 特殊类名 `self`/`parent`/`static`、常量 `true`/`false`/`null`：保留，不解析；
//! - 别名命中：替换首段（qualified 名）或整体（unqualified 名）；
//! - 无别名：拼当前命名空间前缀 → `Ns\Name`；
//! - 函数/常量 unqualified 且处于命名空间内：运行时可能 fallback 到全局——
//!   静态不可定（`strict` 为 true 时不产解析结果，同 php-parser 返回 null）。
//!
//! 解析覆盖的名字引用位置：类型声明（`type_name`）、函数调用名、常量取用、
//! `new`/`static` 调用/静态属性/类常量/`instanceof` 的类名、`catch` 类型、
//! `use Trait`、类/接口/枚举的 `extends`/`implements` 继承名。**声明处名字
//! （`class Foo` 等定义名）**不解析——定义名是 Components.name（token），非 `.name`
//! 节点，不会进入遍历。
const std = @import("std");
const ast = @import("ast.zig");
const Ast = ast.Ast;
const Index = ast.Index;
const TokenIndex = ast.TokenIndex;
const stmt = @import("parser_stmt.zig");
const walk = @import("walk.zig");

/// use/别名的类别，对应 php-parser `Stmt\Use_::TYPE_*`。
pub const Kind = enum(u8) { class, function, constant };

fn kindIdx(kind: Kind) usize {
    return @intFromEnum(kind);
}

fn kindFromUse(kind: u32) Kind {
    return switch (kind) {
        1 => .function,
        2 => .constant,
        else => .class,
    };
}

/// 名字解析旁表项：被解析的名字节点 + FQN 文本（无前导 `\`）。
pub const ResolvedEntry = struct {
    node: Index,
    resolved: []const u8,
};

/// 一次整树名字解析的产物：旁表 + 快速查询。
pub const Resolution = struct {
    gpa: std.mem.Allocator,
    resolved: []ResolvedEntry,
    index: std.AutoHashMap(Index, []const u8),

    pub fn deinit(self: *Resolution) void {
        for (self.resolved) |e| self.gpa.free(e.resolved);
        self.gpa.free(self.resolved);
        self.index.deinit();
        self.* = undefined;
    }

    /// 查某名字节点解析出的 FQN（无前导 `\`）；未解析返回 null。
    pub fn lookup(self: Resolution, node: Index) ?[]const u8 {
        return self.index.get(node);
    }
};

/// 解析上下文：当前命名空间 + 三类别名表（对齐 `NameContext`）。
const Ctx = struct {
    gpa: std.mem.Allocator,
    namespace: ?[]const u8,
    aliases: [3]std.StringHashMap([]const u8),

    fn init(gpa: std.mem.Allocator) Ctx {
        return .{
            .gpa = gpa,
            .namespace = null,
            .aliases = .{
                std.StringHashMap([]const u8).init(gpa),
                std.StringHashMap([]const u8).init(gpa),
                std.StringHashMap([]const u8).init(gpa),
            },
        };
    }

    fn deinit(self: *Ctx) void {
        self.clearAliases();
        for (&self.aliases) |*m| m.deinit();
        if (self.namespace) |ns| self.gpa.free(ns);
        self.* = undefined;
    }

    /// 释放全部别名的 key 与 value（key/value 均为此处 gpa 分配）。
    fn clearAliases(self: *Ctx) void {
        for (&self.aliases) |*m| {
            var it = m.iterator();
            while (it.next()) |kv| {
                self.gpa.free(kv.key_ptr.*);
                self.gpa.free(kv.value_ptr.*);
            }
            m.clearRetainingCapacity();
        }
    }

    /// 进入新命名空间（null = 全局），重置别名表（对齐 `startNamespace`）。
    fn startNamespace(self: *Ctx, ns: ?[]const u8) !void {
        if (self.namespace) |old| self.gpa.free(old);
        self.namespace = if (ns) |n| try self.gpa.dupe(u8, n) else null;
        self.clearAliases();
    }

    fn lower(self: *Ctx, s: []const u8) ![]const u8 {
        const out = try self.gpa.alloc(u8, s.len);
        for (s, 0..) |c, i| out[i] = if (c >= 'A' and c <= 'Z') c + 32 else c;
        return out;
    }

    /// 注册别名：`use Foo\Bar as Baz;` → key=`Baz`（类/函数转小写），value=`Foo\Bar`。
    /// key 与 value 均拷贝到 `gpa`（由 `clearAliases` 统一释放）。
    fn addAlias(self: *Ctx, kind: Kind, alias: []const u8, target: []const u8) !void {
        const gpa = self.gpa;
        const key = if (kind == .constant) try gpa.dupe(u8, alias) else try self.lower(alias);
        const val = try gpa.dupe(u8, target);
        const m = &self.aliases[kindIdx(kind)];
        if (m.get(key)) |old| {
            // 重复别名：php-parser 报错（Cannot use ... as ... because the name is
            // already in use）。此处覆盖并释放旧值。
            gpa.free(old);
        }
        try m.put(key, val);
    }

    /// 解析单个名字文本 → FQN（gpa 上分配）。
    /// `error.NoResolved` = 静态不可解析（函数/常量 unqualified 且处于命名空间内、
    /// strict=true——运行时可能 fallback 全局）。
    fn implResolve(self: *Ctx, kind: Kind, text: []const u8, strict: bool) ![]const u8 {
        const gpa = self.gpa;
        if (kind == .class) {
            if (std.mem.eql(u8, text, "self") or std.mem.eql(u8, text, "parent") or std.mem.eql(u8, text, "static")) {
                return gpa.dupe(u8, text);
            }
        }
        if (kind == .constant) {
            if (std.mem.eql(u8, text, "true") or std.mem.eql(u8, text, "false") or std.mem.eql(u8, text, "null")) {
                return gpa.dupe(u8, text);
            }
        }

        const m = &self.aliases[kindIdx(kind)];
        const sep = std.mem.indexOfScalar(u8, text, '\\');
        if (sep) |s| {
            const first = text[0..s];
            const key = if (kind == .constant) first else try self.lower(first);
            defer if (kind != .constant) gpa.free(key);
            if (m.get(key)) |target| {
                return std.fmt.allocPrint(gpa, "{s}{s}", .{ target, text[s..] });
            }
        } else {
            const key = if (kind == .constant) text else try self.lower(text);
            defer if (kind != .constant) gpa.free(key);
            if (m.get(key)) |target| {
                return gpa.dupe(u8, target);
            }
        }

        if (self.namespace) |ns| {
            const is_qualified = sep != null;
            if ((kind == .function or kind == .constant) and !is_qualified and strict) return error.NoResolved;
            return std.fmt.allocPrint(gpa, "{s}\\{s}", .{ ns, text });
        }
        return gpa.dupe(u8, text);
    }

    fn getResolvedName(self: *Ctx, kind: Kind, text: []const u8, strict: bool) !?[]const u8 {
        return self.implResolve(kind, text, strict) catch |e| switch (e) {
            error.NoResolved => null,
            else => e,
        };
    }
};

/// 取名字节点文本（token 区间 main..=data.token 逐 token 拼；多段名含 `\`）。
/// 名字内 token 连续无空白，故直接拼接。返回字符串在 `gpa` 上分配。
fn nameText(tree: Ast, name: Index, gpa: std.mem.Allocator) ![]const u8 {
    const first = tree.nodeMainToken(name);
    const last = tree.nodeData(name).token;
    if (first == last) return gpa.dupe(u8, tree.tokenSlice(first));
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    var t = first;
    while (true) {
        try buf.appendSlice(gpa, tree.tokenSlice(t));
        if (t == last) break;
        t += 1;
    }
    return buf.toOwnedSlice(gpa);
}

/// 引用父节点 tag → 该父下名字引用的类别；非引用父返回 null。
/// 调用方须先确认该 name 节点是 `.name`（相对名）。
/// `stmt_class`/`stmt_interface`/`stmt_enum` 的类名本身是 token（Components.name），
/// 故其下 `.name` 子节点必是 extends/implements 引用，可安全归 class。
fn kindOfParent(tag: ast.Node.Tag) ?Kind {
    return switch (tag) {
        .type_name, .expr_new, .expr_instanceof, .expr_static_call,
        .expr_static_property_fetch, .expr_class_const_fetch,
        .stmt_catch, .stmt_trait_use,
        .stmt_class, .stmt_interface, .stmt_enum,
        => .class,
        .expr_func_call => .function,
        .expr_const_fetch => .constant,
        else => null,
    };
}

/// 收集 use 项区间，注册别名。
/// `uses` 是存于 extra_data 的 use_use **节点索引**区间；`group_kind` 为整条
/// use 语句/组的类别（`use function ...` 组），单项自身 kind 非 0 时覆盖
/// （`use function A\b;` 的单项 kind=1）。
fn collectUses(tree: Ast, ctx: *Ctx, uses: ast.SubRange, group_kind: Kind) !void {
    for (tree.extraDataSlice(uses, Index)) |use_node| {
        if (tree.nodeTag(use_node) != .use_use) continue;
        const u = tree.nodeData(use_node);
        const uc = tree.extraData(u.extra_and_node[0], stmt.UseUseComponents);
        const name_node = u.extra_and_node[1];
        const kind = if (uc.kind != 0) kindFromUse(uc.kind) else group_kind;

        const target = try nameText(tree, name_node, ctx.gpa);
        defer ctx.gpa.free(target);

        // 别名：as 后的 token；无 as 时默认取名字末段
        if (uc.alias != 0) {
            try ctx.addAlias(kind, tree.tokenSlice(uc.alias), target);
        } else {
            const alias = tree.tokenSlice(tree.nodeData(name_node).token);
            try ctx.addAlias(kind, alias, target);
        }
    }
}

/// 整树名字解析主入口。
///
/// `strict`：函数/常量 unqualified 且处于命名空间内时，不产解析结果（对齐
/// php-parser "cannot resolve statically"）。false 时给命名空间前缀版本。
pub fn resolve(tree: Ast, gpa: std.mem.Allocator, strict: bool) !Resolution {
    var ctx = Ctx.init(gpa);
    defer ctx.deinit();

    var out: std.ArrayList(ResolvedEntry) = .empty;
    defer out.deinit(gpa);
    var index = std.AutoHashMap(Index, []const u8).init(gpa);
    errdefer index.deinit();

    var stack: std.ArrayList(Index) = .empty;
    defer stack.deinit(gpa);
    var parent_stack: std.ArrayList(?Index) = .empty;
    defer parent_stack.deinit(gpa);
    var children: std.ArrayList(Index) = .empty;
    defer children.deinit(gpa);

    try stack.append(gpa, tree.root);
    try parent_stack.append(gpa, null);
    while (stack.pop()) |node| {
        const parent = parent_stack.pop().?;
        try resolveVisit(tree, &ctx, &out, &index, strict, node, parent);

        children.clearRetainingCapacity();
        try walk.childNodes(gpa, tree, node, &children);
        var i: usize = children.items.len;
        while (i > 0) : (i -= 1) {
            try stack.append(gpa, children.items[i - 1]);
            try parent_stack.append(gpa, node);
        }
    }

    return .{
        .gpa = gpa,
        .resolved = try out.toOwnedSlice(gpa),
        .index = index,
    };
}

fn resolveVisit(
    tree: Ast,
    ctx: *Ctx,
    out: *std.ArrayList(ResolvedEntry),
    index: *std.AutoHashMap(Index, []const u8),
    strict: bool,
    node: Index,
    parent: ?Index,
) !void {
    const gpa = ctx.gpa;
    const tag = tree.nodeTag(node);
    switch (tag) {
        .stmt_namespace => {
            const c = tree.extraData(tree.nodeData(node).extra_and_opt_node[0], stmt.NamespaceComponents);
            var ns: ?[]const u8 = null;
            if (c.name.unwrap()) |n| ns = try nameText(tree, n, gpa);
            try ctx.startNamespace(ns);
            if (ns) |s| gpa.free(s);
            return;
        },
        .stmt_use => {
            const c = tree.extraData(tree.nodeData(node).extra, stmt.UseComponents);
            try collectUses(tree, ctx, c.uses, .class);
            return;
        },
        .stmt_group_use => {
            const data = tree.nodeData(node);
            const c = tree.extraData(data.extra_and_node[0], stmt.GroupUseComponents);
            const kind = kindFromUse(c.kind);
            // group 前缀拼到各项目标：prefix\name（如 `use Foo\ { Bar, Baz }`）
            const prefix = try nameText(tree, data.extra_and_node[1], gpa);
            defer gpa.free(prefix);
            try collectUsesWithPrefix(tree, ctx, c.uses, kind, prefix);
            return;
        },
        else => {},
    }

    if (tag != .name) return;
    const ptag = tree.nodeTag(parent orelse return);
    const kind = kindOfParent(ptag) orelse return;
    const text = try nameText(tree, node, gpa);
    defer gpa.free(text);
    const resolved = (try ctx.getResolvedName(kind, text, strict)) orelse return;
    try out.append(gpa, .{ .node = node, .resolved = resolved });
    try index.put(node, resolved);
}

/// group use 变体：目标 = prefix\name。
fn collectUsesWithPrefix(
    tree: Ast,
    ctx: *Ctx,
    uses: ast.SubRange,
    group_kind: Kind,
    prefix: []const u8,
) !void {
    for (tree.extraDataSlice(uses, Index)) |use_node| {
        if (tree.nodeTag(use_node) != .use_use) continue;
        const u = tree.nodeData(use_node);
        const uc = tree.extraData(u.extra_and_node[0], stmt.UseUseComponents);
        const name_node = u.extra_and_node[1];
        const kind = if (uc.kind != 0) kindFromUse(uc.kind) else group_kind;
        const name = try nameText(tree, name_node, ctx.gpa);
        defer ctx.gpa.free(name);
        const target = try std.fmt.allocPrint(ctx.gpa, "{s}\\{s}", .{ prefix, name });
        defer ctx.gpa.free(target);
        if (uc.alias != 0) {
            try ctx.addAlias(kind, tree.tokenSlice(uc.alias), target);
        } else {
            const alias = tree.tokenSlice(tree.nodeData(name_node).token);
            try ctx.addAlias(kind, alias, target);
        }
    }
}

// ===========================================================================
// 测试
// ===========================================================================

const testing = @import("testing.zig");

fn parseSrc(gpa: std.mem.Allocator, src: [:0]const u8) !Ast {
    var tree = try ast.Ast.parse(gpa, src, testing.v84);
    errdefer tree.deinit(gpa);
    return tree;
}

/// 收集树上全部 `.name` 节点（顺序 = 前序），供测试逐一定位。
fn collectNames(gpa: std.mem.Allocator, tree: Ast) !std.ArrayList(Index) {
    var names: std.ArrayList(Index) = .empty;
    var ws = try walk.WalkState.init(gpa);
    defer ws.deinit();
    const Collect = struct {
        gpa: std.mem.Allocator,
        list: *std.ArrayList(Index),
        fn visit(self: *@This(), t: Ast, node: Index) !void {
            if (t.nodeTag(node) == .name) try self.list.append(self.gpa, node);
        }
    };
    var c = Collect{ .gpa = gpa, .list = &names };
    try walk.walkStack(tree, tree.root, &ws, &c, Collect.visit);
    return names;
}

test "names :: 命名空间 + use 别名（类/函数/常量）解析" {
    const gpa = std.testing.allocator;
    var tree = try parseSrc(gpa,
        \\<?php
        \\namespace App\Lib;
        \\use Vendor\Package\Foo as AliasFoo;
        \\use function Vendor\funcs\len as my_len;
        \\use const Vendor\Cfg\LIMIT;
        \\$a = new AliasFoo;
        \\$c = new Foo;
        \\$d = my_len('x');
        \\$e = LIMIT;
        \\$f = self::X;
    );
    defer tree.deinit(gpa);

    var res = try resolve(tree, gpa, true);
    defer res.deinit();

    // 直接遍历名字引用并按 lookup 断言
    var found_alias = false;
    var found_ns = false;
    var found_func: ?[]const u8 = null;
    var found_const: ?[]const u8 = null;
    var names = try collectNames(gpa, tree);
    defer names.deinit(gpa);
    // 按源码顺序，名字引用依次为：Foo(use) AliasFoo Foo my_len LIMIT self
    // use 目标名不解析；故引用位应是 AliasFoo / Foo / my_len / LIMIT / self
    // 借助 tokenSlice 定位
    for (names.items) |n| {
        const text = tree.tokenSlice(tree.nodeMainToken(n));
        const r = res.lookup(n) orelse continue;
        if (std.mem.eql(u8, text, "AliasFoo")) {
            try std.testing.expectEqualStrings("Vendor\\Package\\Foo", r);
            found_alias = true;
        }
        if (std.mem.eql(u8, text, "Foo")) {
            try std.testing.expectEqualStrings("App\\Lib\\Foo", r);
            found_ns = true;
        }
        if (std.mem.eql(u8, text, "my_len")) {
            try std.testing.expectEqualStrings("Vendor\\funcs\\len", r);
            found_func = r;
        }
        if (std.mem.eql(u8, text, "LIMIT")) {
            try std.testing.expectEqualStrings("Vendor\\Cfg\\LIMIT", r);
            found_const = r;
        }
    }
    try std.testing.expect(found_alias);
    try std.testing.expect(found_ns);
    try std.testing.expect(found_func != null);
    try std.testing.expect(found_const != null);
}

test "names :: 全局命名空间：无别名即全局 FQN" {
    const gpa = std.testing.allocator;
    var tree = try parseSrc(gpa, "<?php $a = new DateTime; $b = strlen('x');");
    defer tree.deinit(gpa);
    var res = try resolve(tree, gpa, true);
    defer res.deinit();

    var found = false;
    var names = try collectNames(gpa, tree);
    defer names.deinit(gpa);
    for (names.items) |n| {
        const text = tree.tokenSlice(tree.nodeMainToken(n));
        const r = res.lookup(n) orelse continue;
        if (std.mem.eql(u8, text, "DateTime")) {
            try std.testing.expectEqualStrings("DateTime", r);
            found = true;
        }
    }
    try std.testing.expect(found);
}

test "names :: extends/implements 继承名解析（多实现/多继承/别名）" {
    const gpa = std.testing.allocator;
    var tree = try parseSrc(gpa,
        \\<?php
        \\namespace App;
        \\use Vendor\A\Base as VBase;
        \\use Vendor\B\{One, Two as T2};
        \\class C extends VBase implements One, T2 {}
        \\interface I extends One, \Global\G2 {}
        \\enum E implements One { case X; }
    );
    defer tree.deinit(gpa);
    try testing.expectNoErrors(tree);
    var res = try resolve(tree, gpa, true);
    defer res.deinit();

    var names = try collectNames(gpa, tree);
    defer names.deinit(gpa);
    var n_vbase = false;
    var n_one: usize = 0;
    var n_two = false;
    for (names.items) |n| {
        const text = tree.tokenSlice(tree.nodeMainToken(n));
        const r = res.lookup(n) orelse continue;
        if (std.mem.eql(u8, text, "VBase")) {
            try std.testing.expectEqualStrings("Vendor\\A\\Base", r);
            n_vbase = true;
        }
        if (std.mem.eql(u8, text, "One")) {
            try std.testing.expectEqualStrings("Vendor\\B\\One", r);
            n_one += 1;
        }
        if (std.mem.eql(u8, text, "T2")) {
            try std.testing.expectEqualStrings("Vendor\\B\\Two", r);
            n_two = true;
        }
    }
    // One 出现 3 次：implements(One)、interface extends(One)、enum implements(One)
    try std.testing.expect(n_vbase);
    try std.testing.expectEqual(@as(usize, 3), n_one);
    try std.testing.expect(n_two);
}

test "names :: FQ / var_like / 类型内类名" {
    const gpa = std.testing.allocator;
    var tree = try parseSrc(gpa,
        \\<?php
        \\namespace App;
        \\function f(\Global\G $x): \Global\R { return new \Global\R(); }
        \\class A { public function m(): static {} }
    );
    defer tree.deinit(gpa);
    var res = try resolve(tree, gpa, true);
    defer res.deinit();
    // FQ 名不解析（tag 非 .name）；type_name 内的相对名才解析——上面全 FQ，应无输出
    try std.testing.expectEqual(@as(usize, 0), res.resolved.len);
}
