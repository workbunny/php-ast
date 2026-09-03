//! 覆盖矩阵：为每个「种类」固定一条能产出它的最小用例，由编译期强制完整性。
//!
//! 这是本库的防回归闸门，作用域与专用测试不同：
//!
//! - **专用测试**（各模块 test 块）回答「这个语法解析得对不对」；
//! - **本矩阵**回答「每个种类都还有人管吗」，且由**编译期**强制完整性。
//!
//! 新增种类时若忘了补用例，**编译直接失败**，而非等到覆盖率报表才发现。这对应
//! Zig Zen 的 *Compile errors are better than runtime crashes*。
//!
//! 共两道矩阵：
//! - `nodeCases`：`Node.Tag` 逐个列出（须与声明顺序一致）；
//! - `tokenCases`：`Token.Tag` 逐个列出。凡 `Token.keywords` / `Token.operators`
//!   中登记过的，源码由表反查生成，无需手写——新增关键字只改 `token.zig` 一处，
//!   测试自动覆盖。
const std = @import("std");
const ast = @import("ast.zig");
const Token = @import("token.zig").Token;
const Lexer = @import("lexer.zig").Lexer;
const PhpVersion = @import("version.zig").PhpVersion;
const testing = @import("testing.zig");

const Case = struct {
    tag: ast.Node.Tag,
    /// 能产出该节点的最短源码。
    src: [:0]const u8,
    /// 目标版本；默认 8.4，8.5 语法需显式抬高。
    ver: PhpVersion = .{ .id = 80400 },
    /// 该节点在树中的期望出现次数。
    count: usize = 1,
    /// 是否允许解析产生诊断（`stmt_error` 等畸形输入用例需要）。
    allow_errors: bool = false,
};

// 矩阵条目：顺序必须与 `Node.Tag` 声明顺序严格一致。
const cases = [_]Case{
    // ---- root ----
    .{ .tag = .root, .src = "<?php $a = 1;" },
    // ---- 语句 ----
    .{ .tag = .stmt_expression, .src = "<?php $a;" },
    .{ .tag = .stmt_echo, .src = "<?php echo 1;" },
    .{ .tag = .stmt_if, .src = "<?php if ($a) {}" },
    .{ .tag = .stmt_while, .src = "<?php while ($a) {}" },
    .{ .tag = .stmt_for, .src = "<?php for ($i = 0; $i < 1; $i++) {}" },
    .{ .tag = .stmt_foreach, .src = "<?php foreach ($a as $v) {}" },
    .{ .tag = .stmt_function, .src = "<?php function f() {}" },
    .{ .tag = .stmt_class, .src = "<?php class C {}" },
    .{ .tag = .stmt_enum, .src = "<?php enum E {}" },
    .{ .tag = .stmt_interface, .src = "<?php interface I {}" },
    .{ .tag = .stmt_trait, .src = "<?php trait T {}" },
    .{ .tag = .stmt_case, .src = "<?php enum E { case A; }" },
    .{ .tag = .stmt_property, .src = "<?php class C { public int $x; }" },
    .{ .tag = .property_hook, .src = "<?php class C { public int $x { get => 1; } }" },
    .{ .tag = .stmt_namespace, .src = "<?php namespace N {}" },
    .{ .tag = .stmt_return, .src = "<?php function f() { return 1; }" },
    .{ .tag = .stmt_block, .src = "<?php {}" },
    .{ .tag = .stmt_do, .src = "<?php do {} while ($a);" },
    .{ .tag = .stmt_break, .src = "<?php while ($a) { break; }" },
    .{ .tag = .stmt_continue, .src = "<?php while ($a) { continue; }" },
    .{ .tag = .stmt_switch, .src = "<?php switch ($a) {}" },
    .{ .tag = .stmt_switch_case, .src = "<?php switch ($a) { case 1: }" },
    .{ .tag = .stmt_default, .src = "<?php switch ($a) { default: }" },
    .{ .tag = .stmt_throw, .src = "<?php throw $e;" },
    .{ .tag = .stmt_try, .src = "<?php try {}" },
    .{ .tag = .stmt_catch, .src = "<?php try {} catch (E $e) {}" },
    .{ .tag = .stmt_const, .src = "<?php const A = 1;" },
    .{ .tag = .const_decl, .src = "<?php const A = 1;" },
    .{ .tag = .stmt_use, .src = "<?php use A;" },
    .{ .tag = .use_use, .src = "<?php use A;" },
    .{ .tag = .stmt_group_use, .src = "<?php use A\\{B};" },
    .{ .tag = .stmt_trait_use, .src = "<?php class C { use T; }" },
    .{ .tag = .trait_use_adaptation_alias, .src = "<?php class C { use T { T::a as b; } }" },
    .{ .tag = .trait_use_adaptation_precedence, .src = "<?php class C { use T { T::a insteadof U; } }" },
    .{ .tag = .stmt_declare, .src = "<?php declare(strict_types=1);" },
    .{ .tag = .declare_declare, .src = "<?php declare(strict_types=1);" },
    .{ .tag = .stmt_goto, .src = "<?php goto a;" },
    .{ .tag = .stmt_label, .src = "<?php a:" },
    .{ .tag = .stmt_global, .src = "<?php global $a;" },
    .{ .tag = .stmt_static, .src = "<?php static $a;" },
    .{ .tag = .static_var, .src = "<?php static $a;" },
    .{ .tag = .stmt_unset, .src = "<?php unset($a);" },
    .{ .tag = .stmt_halt, .src = "<?php __halt_compiler();" },
    .{ .tag = .inline_html, .src = "<?php ?>text<?php " },
    .{ .tag = .stmt_nop, .src = "<?php ;" },
    .{ .tag = .stmt_method, .src = "<?php class C { function m() {} }" },
    .{ .tag = .stmt_class_const, .src = "<?php class C { const A = 1; }" },
    .{ .tag = .stmt_error, .src = "<?php => 1;", .allow_errors = true },
    // ---- 表达式 ----
    .{ .tag = .expr_variable, .src = "<?php $a;" },
    .{ .tag = .expr_variable_ref, .src = "<?php $$a;" },
    .{ .tag = .expr_int, .src = "<?php 1;" },
    .{ .tag = .expr_float, .src = "<?php 1.5;" },
    .{ .tag = .expr_string, .src = "<?php 'a';" },
    .{ .tag = .expr_const_fetch, .src = "<?php FOO;" },
    .{ .tag = .expr_binary, .src = "<?php $a + $b;" },
    .{ .tag = .expr_assign, .src = "<?php $a = 1;" },
    .{ .tag = .expr_assign_op, .src = "<?php $a += 1;" },
    .{ .tag = .expr_assign_ref, .src = "<?php $a = &$b;" },
    .{ .tag = .expr_unary, .src = "<?php -$a;" },
    .{ .tag = .expr_array, .src = "<?php [1];" },
    .{ .tag = .expr_array_item, .src = "<?php [1];" },
    .{ .tag = .expr_array_dim_fetch, .src = "<?php $a[0];" },
    .{ .tag = .expr_func_call, .src = "<?php f();" },
    .{ .tag = .expr_new, .src = "<?php new A();" },
    .{ .tag = .expr_property_fetch, .src = "<?php $a->b;" },
    .{ .tag = .expr_static_property_fetch, .src = "<?php A::$b;" },
    .{ .tag = .expr_class_const_fetch, .src = "<?php A::B;" },
    .{ .tag = .expr_static_call, .src = "<?php A::b();" },
    .{ .tag = .expr_method_call, .src = "<?php $a->b();" },
    .{ .tag = .expr_nullsafe_property_fetch, .src = "<?php $a?->b;" },
    .{ .tag = .expr_nullsafe_method_call, .src = "<?php $a?->b();" },
    .{ .tag = .expr_match, .src = "<?php match ($a) { default => 1 };" },
    .{ .tag = .expr_match_arm, .src = "<?php match ($a) { default => 1 };" },
    .{ .tag = .expr_first_class_callable, .src = "<?php f(...);" },
    // 匿名函数须位于表达式位置：顶层的 `function` 会被当作命名函数声明。
    .{ .tag = .expr_closure, .src = "<?php $f = function () {};" },
    .{ .tag = .expr_arrow_function, .src = "<?php fn () => 1;" },
    .{ .tag = .expr_clone, .src = "<?php clone $a;" },
    .{ .tag = .expr_pipe, .src = "<?php $a |> f;", .ver = .{ .id = 80500 } },
    .{ .tag = .expr_isset, .src = "<?php isset($a);" },
    .{ .tag = .expr_empty, .src = "<?php empty($a);" },
    .{ .tag = .expr_eval, .src = "<?php eval('1');" },
    .{ .tag = .expr_exit, .src = "<?php exit;" },
    .{ .tag = .expr_include, .src = "<?php include 'a';" },
    .{ .tag = .expr_instanceof, .src = "<?php $a instanceof B;" },
    .{ .tag = .expr_list, .src = "<?php list($a) = [1];" },
    .{ .tag = .expr_ternary, .src = "<?php $a ? 1 : 2;" },
    .{ .tag = .expr_throw, .src = "<?php $f = fn () => throw new E();" },
    .{ .tag = .expr_print, .src = "<?php print $a;" },
    .{ .tag = .expr_shell_exec, .src = "<?php `ls`;" },
    .{ .tag = .expr_yield, .src = "<?php function g() { yield 1; }" },
    .{ .tag = .expr_yield_from, .src = "<?php function g() { yield from $a; }" },
    .{ .tag = .expr_error_suppress, .src = "<?php @f();" },
    .{ .tag = .expr_post_inc, .src = "<?php $a++;" },
    .{ .tag = .expr_post_dec, .src = "<?php $a--;" },
    .{ .tag = .expr_cast, .src = "<?php (int)$a;" },
    .{ .tag = .expr_argument, .src = "<?php f(1);" },
    .{ .tag = .expr_encapsed, .src = "<?php \"$a\";" },
    // 需含字面文本段：纯 "$a" 不产生 expr_string_part。
    .{ .tag = .expr_string_part, .src = "<?php \"a$a\";" },
    .{ .tag = .expr_magic_const, .src = "<?php __LINE__;" },
    // ---- 杂项 ----
    .{ .tag = .name, .src = "<?php new A();" },
    .{ .tag = .name_fully_qualified, .src = "<?php new \\A();" },
    .{ .tag = .name_relative, .src = "<?php new namespace\\A();" },
    .{ .tag = .name_var_like, .src = "<?php new $a();" },
    .{ .tag = .param, .src = "<?php function f($a) {}" },
    .{ .tag = .type_name, .src = "<?php function f(A $a) {}" },
    .{ .tag = .type_nullable, .src = "<?php function f(?A $a) {}" },
    .{ .tag = .type_union, .src = "<?php function f(A|B $a) {}" },
    .{ .tag = .type_intersection, .src = "<?php function f(A&B $a) {}" },
    .{ .tag = .type_self, .src = "<?php class C { function f(self $a) {} }" },
    .{ .tag = .type_parent, .src = "<?php class C { function f(parent $a) {} }" },
    .{ .tag = .type_static, .src = "<?php class C { function f(): static {} }" },
    .{ .tag = .type_array_of, .src = "<?php function f(A[] $a) {}" },
    .{ .tag = .type_generic, .src = "<?php function f(A<B> $a) {}" },
    .{ .tag = .attribute, .src = "<?php #[A] function f() {}" },
    .{ .tag = .attr_group, .src = "<?php #[A] function f() {}" },
};

// 编译期闸门：矩阵必须覆盖全部 Node.Tag 且顺序一致。
comptime {
    const fields = @typeInfo(ast.Node.Tag).@"enum".fields;
    if (fields.len != cases.len) {
        @compileError("覆盖矩阵条目数与 Node.Tag 总数不符，请为新增节点补充用例");
    }
    for (fields, 0..) |f, i| {
        if (@intFromEnum(cases[i].tag) != i) {
            @compileError("覆盖矩阵顺序与 Node.Tag 声明不一致，断点位于: " ++ f.name);
        }
    }
}

// ===========================================================================
// 词法矩阵
// ===========================================================================

const TokenCase = struct {
    tag: Token.Tag,
    /// 能词法出该种类的最短源码；`null` 表示由 keywords/operators 表反查生成。
    src: ?[:0]const u8 = null,
    /// 期望出现次数。关键字表中 `==` 与 `=` 等互为前缀，故部分条目会多计。
    count: usize = 1,
};

/// 由 `Token.keywords` / `Token.operators` 反查某 tag 的文本。
fn textOf(tag: Token.Tag) ?[]const u8 {
    for (Token.keywords) |k| {
        if (k.tag == tag) return k.t;
    }
    for (Token.operators) |o| {
        if (o.tag == tag) return o.t;
    }
    return null;
}

test "coverage :: keywords 与 operators 无交集" {
    // 二者各有一张表，重叠会导致词法歧义。顺带验证 `lexeme` 与 `operators` 一致。
    for (Token.keywords) |k| {
        if (Token.lexeme(k.tag) != null) {
            std.debug.print("\nkeywords 与 operators 冲突: {s}\n", .{k.t});
            return error.TestUnexpectedResult;
        }
    }
    for (Token.operators) |o| {
        if (Token.lexeme(o.tag) == null) {
            std.debug.print("\noperators 表项缺失 lexeme: {s}\n", .{o.t});
            return error.TestUnexpectedResult;
        }
    }
}

/// 按 `Token.Tag` 声明顺序生成全部条目：凡 `keywords`/`operators` 中登记过的，
/// 源码由表反查（无需手写）；其余取 `manualSrc` 里登记的，缺失则留待编译期报错。
///
/// 矩阵顺序必须与 `Tag` 声明一致，故此处按枚举序号遍历，而非按两张表的顺序。
fn buildTokenCases() [std.meta.fields(Token.Tag).len]TokenCase {
    var arr: [std.meta.fields(Token.Tag).len]TokenCase = undefined;
    for (std.meta.fields(Token.Tag), 0..) |_, i| {
        const tag: Token.Tag = @enumFromInt(i);
        arr[i] = .{ .tag = tag, .src = manualSrc(tag) };
    }
    return arr;
}

/// 无法由表反查的 token，在此登记其最短源码。
fn manualSrc(tag: Token.Tag) ?[:0]const u8 {
    return switch (tag) {
        .eof => "",
        .invalid => "<?php \x01",
        .int_literal => "<?php 1",
        .float_literal => "<?php 1.5",
        .string_literal => "<?php ''",
        .string_start, .string_end, .string_part => "<?php \"a\"",
        .identifier => "<?php FOO",
        .variable => "<?php $a",
        .magic_const => "<?php __LINE__",
        .open_tag => "<?php ",
        .close_tag => "<?php ?>",
        .comment => "<?php // c",
        .doc_comment => "<?php /** d */",
        .inline_html => "<?php ?>text",
        // 需上下文才能成立，不能只放裸符号：
        // `#` 单独出现是行注释起始，只有 `#[` 才是属性语法（hash）。
        .hash => "<?php #[A]",
        else => null,
    };
}

const tokenCases = buildTokenCases();

// 编译期闸门：每个 Token.Tag 都必须能取得一条源码。表反查不到、且 `manualSrc`
// 也未登记的，编译即失败——新增 token 时不会悄悄漏测。
comptime {
    @setEvalBranchQuota(100000);
    for (tokenCases) |c| {
        if (c.src == null and textOf(c.tag) == null) {
            @compileError("词法用例缺源码，请在 manualSrc 中补一条: " ++ @tagName(c.tag));
        }
    }
    const fields = @typeInfo(Token.Tag).@"enum".fields;
    for (fields, 0..) |f, i| {
        if (@intFromEnum(tokenCases[i].tag) != i) {
            @compileError("词法矩阵顺序与 Token.Tag 声明不一致，断点位于: " ++ f.name);
        }
    }
}

test "coverage :: 每个 Token.Tag 的最小用例均能词法出该种类" {
    const gpa = std.testing.allocator;

    for (tokenCases) |c| {
        // 未手写源码的，由 keywords/operators 表反查；`.` 单独出现会与浮点字面量
        // 冲突，故统一包一层括号无关的上下文。
        var buf: [64]u8 = undefined;
        const src: [:0]const u8 = if (c.src) |s| s else blk: {
            const t = textOf(c.tag) orelse {
                std.debug.print("\n词法用例缺源码: {s}\n", .{@tagName(c.tag)});
                return error.TestUnexpectedResult;
            };
            const full = std.fmt.bufPrintZ(&buf, "<?php {s}", .{t}) catch {
                std.debug.print("\n词法用例源码过长: {s}\n", .{@tagName(c.tag)});
                return error.TestUnexpectedResult;
            };
            break :blk full;
        };

        var toks = Token.TokenList{};
        defer toks.deinit(gpa);
        try Lexer.tokenize(gpa, src, &toks);
        var slice = toks.toOwnedSlice();
        defer slice.deinit(gpa);

        var got: usize = 0;
        for (slice.items(.tag)) |t| {
            if (t == c.tag) got += 1;
        }
        if (got < c.count) {
            std.debug.print(
                "\n词法用例失效: {s}\n  源码: {s}\n  期望至少 {d} 个，实际 {d} 个\n",
                .{ @tagName(c.tag), src, c.count, got },
            );
            try std.testing.expect(got >= c.count);
        }
    }
}

test "coverage :: operators 表内多字符运算符优先于单字符" {
    // 表按长度降序排列，此用例锁住该约定——顺序错了会导致 `===` 被切成 `=` `=` `=`。
    const gpa = std.testing.allocator;
    var toks = Token.TokenList{};
    defer toks.deinit(gpa);
    try Lexer.tokenize(gpa, "<?php === !== **= <<= >>=", &toks);
    var slice = toks.toOwnedSlice();
    defer slice.deinit(gpa);

    const want = [_]Token.Tag{
        .open_tag, .equal_equal_equal, .bang_equal_equal,
        .double_asterisk_equal, .left_shift_equal, .right_shift_equal, .eof,
    };
    try std.testing.expectEqual(want.len, slice.items(.tag).len);
    for (want, slice.items(.tag)) |w, got| {
        try std.testing.expectEqual(w, got);
    }
}

test "coverage :: 每个 Node.Tag 的最小用例均能产出该节点" {
    const gpa = std.testing.allocator;
    for (cases) |c| {
        var tree = try ast.Ast.parse(gpa, c.src, c.ver);
        defer tree.deinit(gpa);

        // 自带上下文的失败信息：矩阵条目众多，出错时必须能立刻定位到是哪一条。
        if (!c.allow_errors and tree.errors.len > 0) {
            var buf: [256]u8 = undefined;
            std.debug.print("\n覆盖用例产生非预期诊断: {s}\n  源码: {s}\n", .{ @tagName(c.tag), c.src });
            for (tree.errors) |e| {
                std.debug.print("    {s}\n", .{e.format(&tree, &buf)});
            }
            return error.TestUnexpectedResult;
        }

        const got = testing.countTag(tree, c.tag);
        if (got != c.count) {
            std.debug.print(
                "\n覆盖用例失效: {s}\n  源码: {s}\n  期望 {d} 个，实际 {d} 个\n",
                .{ @tagName(c.tag), c.src, c.count, got },
            );
            try std.testing.expectEqual(c.count, got);
        }
    }
}
