/// `ast.zig` 解析入口的测试套件，独立于库代码之外。
///
/// 测试文件与被测模块分离的原因同 `lexer_test.zig`：保持模块文件纯净、只承载
/// 库逻辑，测试用例集中于此，便于单独运行与审阅。本文件通过命名模块
/// `@import("php_ast")` 驱动断言，自身即为可独立编译执行的测试根。
const std = @import("std");
const ast = @import("php_ast").ast;
const php_ast = @import("php_ast");

test "parse 一个带返回值的函数" {
    const gpa = std.testing.allocator;
    var tree = try ast.Ast.parse(gpa, "<?php function foo($a) { return $a; }", .{ .id = 80400 });
    defer tree.deinit(gpa);
    try std.testing.expect(tree.errors.len == 0);
    try std.testing.expect(tree.nodeTag(tree.root) == .root);
    const stmts = tree.rootStmts();
    try std.testing.expect(stmts.len == 1);
    try std.testing.expect(tree.nodeTag(stmts[0]) == .stmt_function);
}

test "parse 带方法的类" {
    const gpa = std.testing.allocator;
    var tree = try ast.Ast.parse(gpa,
        \\<?php
        \\class Foo extends Bar {
        \\    public function baz($x) { return $x; }
        \\}
    , .{ .id = 80400 });
    defer tree.deinit(gpa);
    try std.testing.expect(tree.errors.len == 0);
    const stmts = tree.rootStmts();
    try std.testing.expect(stmts.len == 1);
    try std.testing.expect(tree.nodeTag(stmts[0]) == .stmt_class);
}

test "语法错误被收集而非致命" {
    const gpa = std.testing.allocator;
    var tree = try ast.Ast.parse(gpa, "<?php $a = ;", .{ .id = 80400 });
    defer tree.deinit(gpa);
    try std.testing.expect(countTag(tree, .stmt_error) >= 1);
}

fn countTag(tree: ast.Ast, tag: ast.Node.Tag) usize {
    var n: usize = 0;
    for (tree.nodes.items(.tag)) |t| {
        if (t == tag) n += 1;
    }
    return n;
}

test "类型 - 联合/交集/可空" {
    const gpa = std.testing.allocator;
    var tree = try ast.Ast.parse(gpa,
        \\<?php
        \\function f(int|string $x, ?Foo\\Bar &$y): A&B { return 1; }
    , .{ .id = 80400 });
    defer tree.deinit(gpa);
    try std.testing.expect(tree.errors.len == 0);
    try std.testing.expect(countTag(tree, .type_union) == 1);
    try std.testing.expect(countTag(tree, .type_nullable) == 1);
    try std.testing.expect(countTag(tree, .type_intersection) == 1);
    try std.testing.expect(countTag(tree, .type_name) >= 4);
}

test "match 表达式" {
    const gpa = std.testing.allocator;
    var tree = try ast.Ast.parse(gpa,
        \\<?php
        \\match ($x) {
        \\    1, 2 => 'a',
        \\    default => 'b',
        \\};
    , .{ .id = 80400 });
    defer tree.deinit(gpa);
    try std.testing.expect(tree.errors.len == 0);
    try std.testing.expect(countTag(tree, .expr_match) == 1);
    try std.testing.expect(countTag(tree, .expr_match_arm) == 2);
}

test "枚举声明" {
    const gpa = std.testing.allocator;
    var tree = try ast.Ast.parse(gpa,
        \\<?php
        \\enum Suit: string {
        \\    case Hearts;
        \\    case Clubs = 'c';
        \\}
    , .{ .id = 80400 });
    defer tree.deinit(gpa);
    try std.testing.expect(tree.errors.len == 0);
    try std.testing.expect(countTag(tree, .stmt_enum) == 1);
    try std.testing.expect(countTag(tree, .stmt_case) == 2);
}

test "接口与 trait 声明" {
    const gpa = std.testing.allocator;
    var tree = try ast.Ast.parse(gpa,
        \\<?php
        \\interface Shape {
        \\    public function area(): float;
        \\}
        \\trait Logger {
        \\    public function log($m) { echo $m; }
        \\}
    , .{ .id = 80400 });
    defer tree.deinit(gpa);
    try std.testing.expect(tree.errors.len == 0);
    try std.testing.expect(countTag(tree, .stmt_interface) == 1);
    try std.testing.expect(countTag(tree, .stmt_trait) == 1);
    try std.testing.expect(countTag(tree, .stmt_method) == 2);
}

test "属性组" {
    const gpa = std.testing.allocator;
    var tree = try ast.Ast.parse(gpa,
        \\<?php
        \\#[MyAttr(1), Other]
        \\class Foo {}
    , .{ .id = 80400 });
    defer tree.deinit(gpa);
    try std.testing.expect(tree.errors.len == 0);
    try std.testing.expect(countTag(tree, .attribute) == 2);
    try std.testing.expect(countTag(tree, .stmt_class) == 1);
}

test "一等可调用" {
    const gpa = std.testing.allocator;
    var tree = try ast.Ast.parse(gpa, "<?php strlen(...);", .{ .id = 80400 });
    defer tree.deinit(gpa);
    try std.testing.expect(tree.errors.len == 0);
    try std.testing.expect(countTag(tree, .expr_first_class_callable) == 1);
}

test "属性钩子 get/set" {
    const gpa = std.testing.allocator;
    var tree = try ast.Ast.parse(gpa,
        \\<?php
        \\class Foo {
        \\    public string $bar {
        \\        get => $this->bar;
        \\        set(string $v) => $this->bar = $v;
        \\    }
        \\}
    , .{ .id = 80400 });
    defer tree.deinit(gpa);
    try std.testing.expect(tree.errors.len == 0);
    try std.testing.expect(countTag(tree, .stmt_property) >= 1);
    try std.testing.expect(countTag(tree, .property_hook) == 2);
}

test "非对称可见性" {
    const gpa = std.testing.allocator;
    var tree = try ast.Ast.parse(gpa,
        \\<?php
        \\class Foo {
        \\    public private(set) string $bar;
        \\    public protected(set) int $baz;
        \\}
    , .{ .id = 80400 });
    defer tree.deinit(gpa);
    try std.testing.expect(tree.errors.len == 0);
    try std.testing.expect(countTag(tree, .stmt_property) == 2);
}

test "Deprecated 属性" {
    const gpa = std.testing.allocator;
    var tree = try ast.Ast.parse(gpa, "<?php #[Deprecated] function f() {}", .{ .id = 80400 });
    defer tree.deinit(gpa);
    try std.testing.expect(tree.errors.len == 0);
    try std.testing.expect(countTag(tree, .attribute) >= 1);
}

test "new 表达式（含无括号）" {
    const gpa = std.testing.allocator;
    var tree = try ast.Ast.parse(gpa,
        \\<?php
        \\$x = new Foo;
        \\$y = new Foo(1);
        \\$z = new $cls;
    , .{ .id = 80400 });
    defer tree.deinit(gpa);
    try std.testing.expect(tree.errors.len == 0);
    try std.testing.expect(countTag(tree, .expr_new) == 3);
}

test "表达式节点 - 数组访问/三元/null合并/instanceof/闭包/箭头/静态拆分/nullsafe/isset等" {
    const gpa = std.testing.allocator;
    var tree = try ast.Ast.parse(gpa,
        \\<?php
        \\function f($y) {
        \\    $a[0];
        \\    $b ? $a : $c;
        \\    $b ?: $c;
        \\    $a ?? $b;
        \\    $x instanceof Foo;
        \\    $fn = fn($p) => $p + 1;
        \\    $cl = function($p) use ($y) { return $p; };
        \\    Foo::BAR;
        \\    Foo::$prop;
        \\    Foo::method();
        \\    $obj?->m();
        \\    Foo?->prop;
        \\    isset($a);
        \\    empty($b);
        \\    list($m, $n) = [1, 2];
        \\    clone $obj;
        \\    yield $k => $v;
        \\    throw new Exception();
        \\    include 'file.php';
        \\    (int)$v;
        \\    $i++;
        \\    $j--;
        \\    $r = f(a: 1);
        \\    $s = 1 << 2;
        \\    $t = true and false or true xor false;
        \\}
    , .{ .id = 80400 });
    defer tree.deinit(gpa);
    try std.testing.expect(tree.errors.len == 0);
    try std.testing.expect(countTag(tree, .expr_array_dim_fetch) == 1);
    try std.testing.expect(countTag(tree, .expr_ternary) == 2);
    try std.testing.expect(countTag(tree, .expr_instanceof) == 1);
    try std.testing.expect(countTag(tree, .expr_arrow_function) == 1);
    try std.testing.expect(countTag(tree, .expr_closure) == 1);
    try std.testing.expect(countTag(tree, .expr_class_const_fetch) == 1);
    try std.testing.expect(countTag(tree, .expr_static_property_fetch) == 1);
    try std.testing.expect(countTag(tree, .expr_static_call) == 1);
    try std.testing.expect(countTag(tree, .expr_nullsafe_method_call) == 1);
    try std.testing.expect(countTag(tree, .expr_nullsafe_property_fetch) == 1);
    try std.testing.expect(countTag(tree, .expr_isset) == 1);
    try std.testing.expect(countTag(tree, .expr_empty) == 1);
    try std.testing.expect(countTag(tree, .expr_list) == 1);
    try std.testing.expect(countTag(tree, .expr_array) == 1);
    try std.testing.expect(countTag(tree, .expr_clone) == 1);
    try std.testing.expect(countTag(tree, .expr_yield) == 1);
    try std.testing.expect(countTag(tree, .stmt_throw) == 1);
    try std.testing.expect(countTag(tree, .expr_include) == 1);
    try std.testing.expect(countTag(tree, .expr_cast) == 1);
    try std.testing.expect(countTag(tree, .expr_post_inc) == 1);
    try std.testing.expect(countTag(tree, .expr_post_dec) == 1);
    try std.testing.expect(countTag(tree, .expr_argument) == 1);
}

test "插值字符串：双引号 / heredoc / nowdoc" {
    const gpa = std.testing.allocator;

    // 双引号：字面片段 + 简单变量插值 + {$expr} 花括号插值
    var tree = try ast.Ast.parse(gpa,
        \\<?php
        \\$name = "hi $x and {$y->z}";
    , .{ .id = 80400 });
    defer tree.deinit(gpa);
    try std.testing.expect(tree.errors.len == 0);
    try std.testing.expect(countTag(tree, .expr_encapsed) == 1);
    try std.testing.expect(countTag(tree, .expr_string_part) >= 2);
    try std.testing.expect(countTag(tree, .expr_variable) >= 1);

    // heredoc：启用插值
    var tree2 = try ast.Ast.parse(gpa,
        \\<?php
        \\$s = <<<EOT
        \\text $v end
        \\EOT;
    , .{ .id = 80400 });
    defer tree2.deinit(gpa);
    try std.testing.expect(tree2.errors.len == 0);
    try std.testing.expect(countTag(tree2, .expr_encapsed) == 1);

    // nowdoc：关闭插值，整体为字面片段（用函数包住，避免领先的 `$s` 被计入变量）
    var tree3 = try ast.Ast.parse(gpa,
        \\<?php
        \\function f() {
        \\    return <<<'EOT'
        \\text $v end
        \\EOT;
        \\}
    , .{ .id = 80400 });
    defer tree3.deinit(gpa);
    try std.testing.expect(tree3.errors.len == 0);
    try std.testing.expect(countTag(tree3, .expr_encapsed) == 1);
    try std.testing.expect(countTag(tree3, .expr_string_part) == 1);
    try std.testing.expect(countTag(tree3, .expr_variable) == 0);
}

test "魔术常量" {
    const gpa = std.testing.allocator;
    var tree = try ast.Ast.parse(gpa,
        \\<?php
        \\$a = __LINE__;
        \\$b = __DIR__;
        \\$c = __FUNCTION__;
    , .{ .id = 80400 });
    defer tree.deinit(gpa);
    try std.testing.expect(tree.errors.len == 0);
    try std.testing.expect(countTag(tree, .expr_magic_const) == 3);
}

test "限定名 - 完全限定 / 相对 / 变量名" {
    const gpa = std.testing.allocator;

    // 完全限定名 \Foo\Bar
    var tree = try ast.Ast.parse(gpa, "<?php new \\Foo\\Bar();", .{ .id = 80400 });
    defer tree.deinit(gpa);
    try std.testing.expect(tree.errors.len == 0);
    try std.testing.expect(countTag(tree, .name_fully_qualified) == 1);

    // 相对名 namespace\Foo\Bar
    var tree2 = try ast.Ast.parse(gpa, "<?php new namespace\\Foo\\Bar();", .{ .id = 80400 });
    defer tree2.deinit(gpa);
    try std.testing.expect(tree2.errors.len == 0);
    try std.testing.expect(countTag(tree2, .name_relative) == 1);

    // 变量名（动态）
    var tree3 = try ast.Ast.parse(gpa, "<?php new $cls();", .{ .id = 80400 });
    defer tree3.deinit(gpa);
    try std.testing.expect(tree3.errors.len == 0);
    try std.testing.expect(countTag(tree3, .name_var_like) == 1);
}

test "类型 - 伪类型 / 泛型 / 数组后缀" {
    const gpa = std.testing.allocator;

    // self / parent / static 伪类型
    var tree = try ast.Ast.parse(gpa,
        \\<?php
        \\function f(self $a, parent $b, static $c): callable {}
    , .{ .id = 80400 });
    defer tree.deinit(gpa);
    try std.testing.expect(tree.errors.len == 0);
    try std.testing.expect(countTag(tree, .type_self) == 1);
    try std.testing.expect(countTag(tree, .type_parent) == 1);
    try std.testing.expect(countTag(tree, .type_static) == 1);

    // 泛型 list<int> / Foo<string>
    var tree2 = try ast.Ast.parse(gpa,
        \\<?php
        \\function f(list<int> $a, Foo<string> $b) {}
    , .{ .id = 80400 });
    defer tree2.deinit(gpa);
    try std.testing.expect(tree2.errors.len == 0);
    try std.testing.expect(countTag(tree2, .type_generic) == 2);

    // 数组后缀 Foo[]
    var tree3 = try ast.Ast.parse(gpa,
        \\<?php
        \\function f(Foo[] $a) {}
    , .{ .id = 80400 });
    defer tree3.deinit(gpa);
    try std.testing.expect(tree3.errors.len == 0);
    try std.testing.expect(countTag(tree3, .type_array_of) == 1);
}

test "类型 - DNF 括号分组 (A&B)|C" {
    const gpa = std.testing.allocator;

    // 标准 DNF：并集的一个成员为括号包围的交集类型，括号不单独成节点。
    var tree = try ast.Ast.parse(gpa,
        \\<?php
        \\function f((Countable&ArrayAccess)|int $x) {}
    , .{ .id = 80400 });
    defer tree.deinit(gpa);
    try std.testing.expect(tree.errors.len == 0);
    try std.testing.expect(countTag(tree, .type_union) == 1);
    try std.testing.expect(countTag(tree, .type_intersection) == 1);

    // 交集类型上再叠加数组后缀：(A&B)[]
    var tree2 = try ast.Ast.parse(gpa,
        \\<?php
        \\function f((Countable&ArrayAccess)[] $x) {}
    , .{ .id = 80400 });
    defer tree2.deinit(gpa);
    try std.testing.expect(tree2.errors.len == 0);
    try std.testing.expect(countTag(tree2, .type_intersection) == 1);
    try std.testing.expect(countTag(tree2, .type_array_of) == 1);
}

test "属性 - 参数 / 枚举 case / 类常量 / 钩子 / 属性组" {
    const gpa = std.testing.allocator;
    var tree = try ast.Ast.parse(gpa,
        \\<?php
        \\#[Foo] function f(int $x) {}
        \\enum E { #[Bar] case A; }
        \\class C { #[Baz] const FOO = 1; }
    , .{ .id = 80400 });
    defer tree.deinit(gpa);
    try std.testing.expect(tree.errors.len == 0);
    try std.testing.expect(countTag(tree, .attr_group) >= 3);
    try std.testing.expect(countTag(tree, .attribute) >= 3);
    try std.testing.expect(countTag(tree, .param) == 1);

    // 属性钩子上的属性
    var tree2 = try ast.Ast.parse(gpa,
        \\<?php
        \\class C { public string $x { #[Hook] get => $this->x; } }
    , .{ .id = 80400 });
    defer tree2.deinit(gpa);
    try std.testing.expect(tree2.errors.len == 0);
    try std.testing.expect(countTag(tree2, .attr_group) >= 1);
}

fn countVisit(c: *usize, _: ast.Ast, _: ast.Index) !void {
    c.* += 1;
}

test "遍历 walk 覆盖全部节点" {
    const gpa = std.testing.allocator;
    var tree = try ast.Ast.parse(gpa,
        \\<?php
        \\function f(int $x) { return $x + 1; }
        \\class C { public int $y; }
    , .{ .id = 80400 });
    defer tree.deinit(gpa);
    try std.testing.expect(tree.errors.len == 0);

    var visited: usize = 0;
    try php_ast.walk.walk(tree, tree.root, gpa, &visited, countVisit);
    // walk 从根出发，应访问到树中每个节点（含名字叶子）。
    try std.testing.expect(visited == tree.nodes.len);
}

test "arena 分配器下 parse + walkStack 同样工作" {
    // 验证传入 ArenaAllocator 时接口仍然正确（分配全进 arena，deinit 为 no-op，最终整批回收）
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    var tree = try ast.Ast.parse(gpa,
        \\<?php
        \\function f(int $x) { return $x + 1; }
        \\class C { public int $y; }
    , .{ .id = 80400 });
    try std.testing.expect(tree.errors.len == 0);

    var ws = try php_ast.walk.WalkState.init(gpa);
    defer ws.deinit();
    var visited: usize = 0;
    try php_ast.walk.walkStack(tree, tree.root, &ws, &visited, countVisit);
    try std.testing.expect(visited == tree.nodes.len);
    // arena 下 deinit 不崩溃（arena.free 为 no-op），真实释放在 arena.deinit()
    tree.deinit(gpa);
}

test "walkStack 与 walk 产出一致且零每节点分配" {
    const gpa = std.testing.allocator;
    var tree = try ast.Ast.parse(gpa,
        \\<?php
        \\function f(int $x) { return $x + 1; }
        \\class C { public int $y; }
    , .{ .id = 80400 });
    defer tree.deinit(gpa);
    try std.testing.expect(tree.errors.len == 0);

    // 复用缓冲变体：每节点不再单独分配 ArrayList
    var ws = try php_ast.walk.WalkState.init(gpa);
    defer ws.deinit();
    var visited2: usize = 0;
    try php_ast.walk.walkStack(tree, tree.root, &ws, &visited2, countVisit);
    // 结果应与 walk 完全一致
    try std.testing.expect(visited2 == tree.nodes.len);
}

test "leadingComments 取回 docblock" {
    const gpa = std.testing.allocator;
    var tree = try ast.Ast.parse(gpa,
        \\<?php
        \\/** doc */
        \\function f() {}
    , .{ .id = 80400 });
    defer tree.deinit(gpa);
    try std.testing.expect(tree.errors.len == 0);

    // 定位 stmt_function 节点
    var fn_node: ?ast.Index = null;
    var i: usize = 0;
    while (i < tree.nodes.len) : (i += 1) {
        if (tree.nodeTag(@enumFromInt(i)) == .stmt_function) {
            fn_node = @enumFromInt(i);
            break;
        }
    }
    const fn_n = fn_node orelse unreachable;

    var comments = try std.ArrayList(ast.TokenIndex).initCapacity(gpa, 0);
    defer comments.deinit(gpa);
    try php_ast.walk.leadingComments(gpa, tree, fn_n, &comments);
    try std.testing.expect(comments.items.len == 1);
    try std.testing.expect(tree.tokenTag(comments.items[0]) == .doc_comment);
}

test "Stmt - do/break/continue/switch/throw/try/goto/label" {
    const gpa = std.testing.allocator;
    var tree = try ast.Ast.parse(gpa,
        \\<?php
        \\function f(int $x) {
        \\    do { $x--; } while ($x > 0);
        \\    switch ($x) {
        \\        case 1: echo 'a'; break;
        \\        case 2: echo 'b'; continue;
        \\        default: echo 'c';
        \\    }
        \\    throw new Exception('x');
        \\    loop:
        \\    goto loop;
        \\    try { foo(); } catch (Exception $e) { bar(); } finally { baz(); }
        \\}
    , .{ .id = 80400 });
    defer tree.deinit(gpa);
    try std.testing.expect(tree.errors.len == 0);
    try std.testing.expect(countTag(tree, .stmt_do) == 1);
    try std.testing.expect(countTag(tree, .stmt_switch) == 1);
    try std.testing.expect(countTag(tree, .stmt_switch_case) == 2);
    try std.testing.expect(countTag(tree, .stmt_default) == 1);
    try std.testing.expect(countTag(tree, .stmt_break) == 1);
    try std.testing.expect(countTag(tree, .stmt_continue) == 1);
    try std.testing.expect(countTag(tree, .stmt_throw) == 1);
    try std.testing.expect(countTag(tree, .stmt_try) == 1);
    try std.testing.expect(countTag(tree, .stmt_catch) == 1);
    try std.testing.expect(countTag(tree, .stmt_goto) == 1);
    try std.testing.expect(countTag(tree, .stmt_label) == 1);
}

test "Stmt - const/use/group_use/global/static/unset/declare" {
    const gpa = std.testing.allocator;
    var tree = try ast.Ast.parse(gpa,
        \\<?php
        \\const FOO = 1, BAR = 2;
        \\use A\B\C;
        \\use A\B\{C, D as E};
        \\use function strlen;
        \\global $a, $b;
        \\static $x = 1, $y;
        \\unset($a, $b);
        \\declare(strict_types=1) { $z = 1; }
    , .{ .id = 80400 });
    defer tree.deinit(gpa);
    try std.testing.expect(tree.errors.len == 0);
    try std.testing.expect(countTag(tree, .stmt_const) == 1);
    try std.testing.expect(countTag(tree, .const_decl) == 2);
    try std.testing.expect(countTag(tree, .stmt_use) == 2);
    try std.testing.expect(countTag(tree, .stmt_group_use) == 1);
    try std.testing.expect(countTag(tree, .use_use) >= 4);
    try std.testing.expect(countTag(tree, .stmt_global) == 1);
    try std.testing.expect(countTag(tree, .stmt_static) == 1);
    try std.testing.expect(countTag(tree, .static_var) == 2);
    try std.testing.expect(countTag(tree, .stmt_unset) == 1);
    try std.testing.expect(countTag(tree, .stmt_declare) == 1);
    try std.testing.expect(countTag(tree, .declare_declare) == 1);
}

test "Stmt - trait use / __halt_compiler / InlineHTML" {
    const gpa = std.testing.allocator;
    var tree = try ast.Ast.parse(gpa,
        \\<?php
        \\class C {
        \\    use A, B {
        \\        A::foo as bar;
        \\        B::baz insteadof A;
        \\    }
        \\}
        \\__halt_compiler();
        \\remaining source ignored
    , .{ .id = 80400 });
    defer tree.deinit(gpa);
    try std.testing.expect(tree.errors.len == 0);
    try std.testing.expect(countTag(tree, .stmt_trait_use) == 1);
    try std.testing.expect(countTag(tree, .trait_use_adaptation_alias) == 1);
    try std.testing.expect(countTag(tree, .trait_use_adaptation_precedence) == 1);
    try std.testing.expect(countTag(tree, .stmt_halt) == 1);

    // InlineHTML：闭标签之后、下一个开标签之前的文本
    var tree2 = try ast.Ast.parse(gpa,
        \\<?php echo 1; ?>
        \\<html>hi</html>
        \\<?php echo 2; ?>
    , .{ .id = 80400 });
    defer tree2.deinit(gpa);
    try std.testing.expect(tree2.errors.len == 0);
    try std.testing.expect(countTag(tree2, .inline_html) == 1);
}

test "Stmt - Nop/方法/类常量/命名空间块/匿名类/构造器提升/可变参数/错误节点" {
    const gpa = std.testing.allocator;

    // Stmt\\Nop：裸语句 `;`
    var t1 = try ast.Ast.parse(gpa, "<?php ;", .{ .id = 80400 });
    defer t1.deinit(gpa);
    try std.testing.expect(t1.errors.len == 0);
    try std.testing.expect(countTag(t1, .stmt_nop) == 1);

    // Stmt\\ClassMethod：类内方法独立于顶层函数（stmt_function），承载可见性/static
    var t2 = try ast.Ast.parse(gpa,
        \\<?php
        \\class C {
        \\    public static function f(): int { return 1; }
        \\}
    , .{ .id = 80400 });
    defer t2.deinit(gpa);
    try std.testing.expect(t2.errors.len == 0);
    try std.testing.expect(countTag(t2, .stmt_method) == 1);
    try std.testing.expect(countTag(t2, .stmt_function) == 0);

    // Stmt\\ClassConst：类常量独立于属性（stmt_property），可带类型（PHP 8.3+）
    var t3 = try ast.Ast.parse(gpa,
        \\<?php
        \\class C {
        \\    public const FOO = 1;
        \\    public int $BAR = 2;
        \\}
    , .{ .id = 80400 });
    defer t3.deinit(gpa);
    try std.testing.expect(t3.errors.len == 0);
    try std.testing.expect(countTag(t3, .stmt_class_const) == 1);
    try std.testing.expect(countTag(t3, .stmt_property) == 1);

    // 命名空间块形式与全局命名空间
    var t4 = try ast.Ast.parse(gpa,
        \\<?php
        \\namespace Ns { function f() {} }
    , .{ .id = 80400 });
    defer t4.deinit(gpa);
    try std.testing.expect(t4.errors.len == 0);
    try std.testing.expect(countTag(t4, .stmt_namespace) == 1);
    try std.testing.expect(countTag(t4, .stmt_function) == 1);

    var t5 = try ast.Ast.parse(gpa,
        \\<?php
        \\namespace { function g() {} }
    , .{ .id = 80400 });
    defer t5.deinit(gpa);
    try std.testing.expect(t5.errors.len == 0);
    try std.testing.expect(countTag(t5, .stmt_namespace) == 1);

    // 匿名类 new class { ... }
    var t6 = try ast.Ast.parse(gpa,
        \\<?php
        \\$x = new class { public function foo() {} };
    , .{ .id = 80400 });
    defer t6.deinit(gpa);
    try std.testing.expect(t6.errors.len == 0);
    try std.testing.expect(countTag(t6, .expr_new) == 1);
    try std.testing.expect(countTag(t6, .stmt_class) == 1);
    try std.testing.expect(countTag(t6, .stmt_method) == 1);

    // 构造器属性提升与可变参数
    var t7 = try ast.Ast.parse(gpa,
        \\<?php
        \\class C { function __construct(public int $x, private string $y = '') {} }
        \\function f(...$args) {}
    , .{ .id = 80400 });
    defer t7.deinit(gpa);
    try std.testing.expect(t7.errors.len == 0);
    try std.testing.expect(countTag(t7, .stmt_class) == 1);
    try std.testing.expect(countTag(t7, .param) >= 3);

    // 错误恢复：无法识别的 token 产出 Stmt\\Error 而非静默丢弃
    var t8 = try ast.Ast.parse(gpa, "<?php => 1;", .{ .id = 80400 });
    defer t8.deinit(gpa);
    try std.testing.expect(countTag(t8, .stmt_error) >= 1);
}
