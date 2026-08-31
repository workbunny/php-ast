<p align="center">
  <img width="260px" src="https://chaz6chez.cn/images/workbunny-logo.png" alt="workbunny">
</p>

<h1 align="center">workbunny/php-ast</h1>

<p align="center">
  🐇PHP Abstract Syntax Tree (AST) library implemented in Zig. 🐇
</p>

# php-ast

## 简介

php-ast 是一个用 Zig 实现的 PHP 源码解析库，将 PHP 源码解析为内存中的抽象语法树（AST），并逐节点标注其「引入版本」。
库不依赖 PHP 运行时，纯 Zig 实现，输出为结构数组（SoA）形式的 AST，供 Zig 生态中需要处理 PHP 代码的工具使用。

### 设计理念

- 显式内存来源：分配器由调用方传入，AST 不含隐藏的运行时分配；`deinit` 一次性释放全部内存。
- 结构数组而非指针树：节点存于连续数组，节点间以索引互相引用，避免逐节点堆分配与指针跳转。
- 多错误收集：词法与语法错误尽量继续解析并累计，调用方一次获得全部诊断。
- 版本信息 + 门控：解析结果在 `Ast.nodeVersion(node)` 上提供逐节点的「引入版本」（基础语法记 `BASE_VERSION`/`id=0`）；同时，`parse` 的 `version` 参数作为目标版本，任何引入版本高于目标的节点会在 `ast.errors` 中记为 `unsupported_version` 错误，交由调用方决定放行或拒绝。
- 信息分层：AST 只承载语义，语法细节（括号、修饰符、运算符子类型等）由结构/字段/token 隐式承载，原文与 token 流常驻可溯源。详见 [doc/zen.md](doc/zen.md)。

## 文档

- [doc/zen.md](doc/zen.md) — 设计哲学、特殊点总表、适用性边界
- [doc/api.md](doc/api.md) — 公开 API 手册

## 设计

### 架构

```
源码 [:0]const u8
      │
      ▼
   Lexer  ──►  Token 流（含注释 token，以 eof 哨兵结尾）
      │
      ▼
   Parser（手写递归下降）
      │
      ▼
   Ast（结构数组：tokens / nodes / extra_data / errors）
      │
      ▼
   消费方：自行 switch(nodeTag) 遍历（反向生成源码的 Render 为规划功能，当前未实现）
```

### 架构思路

- 解析器采用手写递归下降，每个函数对应一条语法产生式，便于对照 PHP 官方语法。相较 PHP-Parser 的 LALR 表驱动，自动生成的大量动作表与转移表难以阅读，与偏好可读代码的原则相悖。
- AST 内存布局与访问方式以 `std.zig.Ast` 为范本，对 Zig 开发者而言是地道用法。节点为定长扁平结构（`tag` + `main_token` + 小型 `data` 联合），超出两个直接子节点的负载序列化进 `extra_data` 大板，节点 `data` 仅保留指向该段的 `ExtraIndex`。
- 注释在 PHP 中具有运行期语义（反射、PHPDoc、Attribute、静态分析）。所有注释作为 token 保留于 `tokens`，声明类节点可经 `docCommentBefore` 取回前置 docblock；普通表达式节点不携带注释字段，零开销。
- 位置信息不冗余存储：节点仅存 `main_token`（代表性 token，如二元运算的运算符），首尾 token 经
  `firstToken`/`lastToken` 沿子节点递归派生，行列号由 `tokenLocation` 按需现算。尾部定界符
  （`;` `}`）不是子节点，另由 `trailingDelimiter` 并入区间。
- 词法、语法层面的非法输入通过错误集合返回，而非静默产出错误的 AST。

## 快速开始

库以命名模块 `php_ast` 暴露，根 `src/root.zig` 再导出了 `ast` / `lexer` / `token` / `version`
四个子模块，并提供了 `parse` / `Ast` 等顶层便捷别名。

```zig
const std = @import("std");
const php_ast = @import("php_ast");

pub fn main() !void {
    var gpa = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer gpa.deinit();

    const source =
        \\<?php
        \\function add(int $a, int $b): int {
        \\    return $a + $b;
        \\}
    ;

    // 解析入口：显式传入分配器、源码与目标 PHP 版本
    // .id = 80400 即 PHP 8.4（也可用 PhpVersion.fromComponents(8, 4)）
    var tree = try php_ast.parse(gpa.allocator(), source, .{ .id = 80400 });
    defer tree.deinit(gpa.allocator());

    // errors 为空表示解析无错误；否则逐个报告诊断
    // e.format 会把版本门控错误渲染成可读文案（含「要求版本」与「目标版本」）
    var errbuf: [128]u8 = undefined;
    for (tree.errors) |e| {
        std.debug.print("parse error: {s} @ '{s}'\n", .{
            e.format(&tree, &errbuf),
            tree.tokenSlice(e.token),
        });
    }

    // 树为扁平 SoA：遍历 nodes 数组，按 tag 自行分类或递归展开
    const tags = tree.nodes.items(.tag);
    for (tags) |tag| {
        // switch (tag) { ... }
    }

    // 节点间以 Index 互引，位置由 main_token 派生：
    //   const main = tree.nodeMainToken(some_index);
    //   const text = tree.tokenSlice(main);
    _ = tags;
}
```

运行测试（测试就近写在各被测源文件底部，遵循 Zig 惯例）：

```bash
zig build test
```

可在容器内执行：`zig build test --cache-dir /tmp/zig-cache --summary all`。

### 测试组织

`test` 块就近写在被测源文件底部（Zig 标准库与生态的主流做法），而非集中于独立
`tests/` 目录。这样测试与实现同处一文件、便于对照阅读，且能覆盖文件内的私有函数。
收集是自动的：`build.zig` 里 `b.addTest(.{ .root_module = lib_mod })` 会递归扫描依赖
树中的全部 `test` 块，新增测试文件时**无需**改动 `build.zig`。

| 机制               | 说明                                                                                                               |
|--------------------|--------------------------------------------------------------------------------------------------------------------|
| `src/testing.zig`  | 共享断言工具：`expectNoErrors`/`expectTagCounts`/`countTag`/`firstNode`/`expectSourceSlice` 与版本常量 `v80`–`v85` |
| `src/coverage.zig` | 覆盖矩阵：为每个 `Node.Tag` / `Token.Tag` 固定一条最小用例，由 `comptime` 强制完整性                               |
| `src/dump.zig`     | 把 AST 渲染为缩进文本，供调试与黄金快照使用                                                                        |
| `tests/golden/`    | 黄金快照：`*.php` 与其期望的树形 `*.txt` 逐字节比对                                                                |
| 命名规范           | `test "<模块> :: <场景> :: <预期>"`，如 `test "expr :: 赋值 :: 普通/复合/引用三种形式"`                            |

**覆盖闸门（`src/coverage.zig`）**：矩阵按声明顺序逐条列出最小用例，`comptime` 校验
条目数与顺序。新增节点/词法种类却忘记补用例时，**编译直接失败**并给出中文错误信息，
而非等到运行时才发现覆盖率下降。运行时逐条执行矩阵，确认用例仍能产出对应种类。

词法一侧的用例由 `Token.keywords` / `Token.operators` 反查生成——新增关键字只改
`token.zig` 一处，测试自动覆盖，无需同步维护两份表。

**黄金快照**：`tests/golden/**/*.php` 的解析结果与同名 `.txt` 比对，一条断言锁住整棵树
的结构。新增语法时补一个 fixture 即可，不必手写大量断言。快照同时记录诊断，因此
「引入新错误」也会被比出来。解析行为有意变更后更新快照：

```bash
zig build test -Dupdate-golden   # 重新生成快照
git diff tests/golden            # 必须复核，确认改动符合预期
```

未复核就更新，会让快照退化为「把错误结果固化下来」。

## 源码结构

解析器自 `parser.zig` 的 `parseRoot` 单一入口驱动，按语法层级拆分到子模块，所有
`parse*` 均为接收 `*Parser` 的自由函数，共享 core 的 SoA 机件：

| 文件                  | 职责                                                                                                         |
|-----------------------|--------------------------------------------------------------------------------------------------------------|
| `src/root.zig`        | 库根，对外再导出 `ast`/`lexer`/`token`/`version` 与 `parse`/`Ast` 便捷别名                                   |
| `src/ast.zig`         | `Ast` SoA 结构、`Node`/`Tag` 枚举、全部 Components、`extra_data` 编解码、`parse` 入口                        |
| `src/token.zig`       | `Token.Tag` 枚举与对应 lexeme 文本                                                                           |
| `src/lexer.zig`       | 手写词法器，输出含注释 token 的 token 流（以 `eof` 哨兵结尾）                                                |
| `src/version.zig`     | `PhpVersion` 版本载体与比较工具（`fromComponents`/`newerOrEqual`）                                           |
| `src/parser.zig`      | `Parser` core：`addNode`/`addExtra`/`addNodeList`/`expectToken`/`eatToken`/`tokTag` 等共享机件 + `parseRoot` |
| `src/parser_stmt.zig` | 语句级 `parse*` 与 Components（if/while/foreach/return/echo/block…）                                         |
| `src/parser_decl.zig` | 声明级 `parse*`（类/接口/trait/enum、函数、成员、属性钩子…）                                                 |
| `src/parser_expr.zig` | 表达式级 `parse*` 与运算符优先级表（含静态/动态访问后缀、闭包、箭头函数…）                                   |
| `src/parser_type.zig` | 类型级 `parse*`（可空/联合/交集/DNF/标识符/伪类型/泛型/数组后缀…）                                           |
| `src/walk.zig`        | 遍历与注释：`childNodes`/`walk`/`walkStack`/`leadingComments`/`trailingComments`（子节点关系在 `ast.zig`）   |
| `src/testing.zig`     | 共享测试断言工具（对应 `std.testing` 的项目级等价物）                                                        |
| `src/coverage.zig`    | 覆盖矩阵，编译期强制每个 `Node.Tag` / `Token.Tag` 都有用例                                                   |
| `src/dump.zig`        | AST 文本渲染，用于调试与黄金快照                                                                             |
| `src/golden.zig`      | 黄金快照比对（`tests/golden/**`），`-Dupdate-golden` 可重新生成                                              |

## 说明

### 节点覆盖

节点分类以 PHP-Parser 5.8.0 为基准（约 170 个节点类（本库以约 110 个 AST `Tag` 表达，运算符子类型已折叠））。下表逐项列出支持情况。

##### 对比差异

- 解析器为手写递归下降，而非 PHP-Parser 的 LALR 表驱动。
- 注释与文档块在 AST 中可经声明节点取用，而非如 Zig 那样在解析期丢弃。
- 节点表示差异：
    - `Stmt\Else_` / `Stmt\ElseIf_`：不生成独立节点，折叠进 `stmt_if`（`else_clause` 指向块/else/elseif 子节点）。
    - `Stmt\Finally_`：不生成独立节点，复用块节点（`stmt_block`）作为 `finally` 子句。
    - `Expr\PreInc` / `Expr\PreDec`：前缀 `++`/`--` 不生成独立节点，统一用 `expr_unary`（main_token 为 `double_plus` / `double_minus`）；后缀 `++`/`--` 为 `expr_post_inc` / `expr_post_dec`。
    - `Expr\BitwiseNot` / `Expr\BooleanNot` / `Expr\UnaryMinus` / `Expr\UnaryPlus`：均折叠进 `expr_unary`。
    - `ClosureUse` / `DeclareDeclare` / `PropertyProperty` / `UseUse` 等：折叠进所属父节点（`expr_closure` / `stmt_declare` / `stmt_property` / `stmt_use`）。
    - `Expr\Error`：PHP-Parser 用该节点承载表达式级解析错误；本库不在 AST 中生成错误表达式节点，而是将错误记入 `ast.errors`（语句级错误恢复仍产出 `stmt_error` 节点）。



**注：版本标记：`-` 表示基础语法（PHP 8 之前即存在）；具体版本号（如 `8.1`）表示自该版本引入；
`8.4+` 表示 8.4 起并随主干持续演进。状态 `✓` 已实现；`×` 未实现（指库附加便捷特性，不属于语法节点覆盖）；
`✓*` 已实现但保真度有损（见备注）。**

#### 词法 Lexer

| 节点 / 能力                                  | PHP 版本 | 状态 | 备注                                                                                             |
|----------------------------------------------|----------|------|--------------------------------------------------------------------------------------------------|
| 开/闭标签、行/块/文档注释                    | -        | ✓   |                                                                                                  |
| 单引号字符串                                 | -        | ✓   | 词法器已处理 `'...'`（含 `\'` `\\`）                                                             |
| 双引号字符串（整段字面量）                   | -        | ✓   | 转义字符被整体保留，未拆分                                                                       |
| 内插字符串 `"...{$x}..."` / heredoc / nowdoc | -        | ✓   | 词法切分为 `string_start`/`string_part`/`string_end`；解析出 `expr_encapsed`，插值段还原为表达式 |
| 整型 / 浮点字面量                            | -        | ✓   |                                                                                                  |
| 变量、标识符、关键字、运算符/标点            | -        | ✓   |                                                                                                  |
| 无效字符兜底、eof 哨兵                       | -        | ✓   |                                                                                                  |

#### 语句 Stmt

| 节点（PHP-Parser）                       | PHP 版本 | 状态 | 备注                                                            |
|------------------------------------------|----------|------|-----------------------------------------------------------------|
| `Stmt\Expression` 表达式语句             | -        | ✓   |                                                                 |
| `Stmt\Echo_`                             | -        | ✓   |                                                                 |
| `Stmt\If_` / `Else_` / `ElseIf_`         | -        | ✓   |                                                                 |
| `Stmt\While_`                            | -        | ✓   |                                                                 |
| `Stmt\Do_` do-while                      | -        | ✓   |                                                                 |
| `Stmt\For_`                              | -        | ✓   |                                                                 |
| `Stmt\Foreach_`                          | -        | ✓   |                                                                 |
| `Stmt\Break_` / `Continue_`              | -        | ✓   | 可选层级表达式                                                  |
| `Stmt\Switch_` / `Case_` / `Default_`    | -        | ✓   | `Switch_` 含条件与 case 列表；`Case_` 可选值经 opt_node         |
| `Stmt\Return_`                           | -        | ✓   |                                                                 |
| `Stmt\Throw_`（语句）                    | -        | ✓   | 经 `stmt_throw` 承载（区别于表达式 `Expr\Throw_`）              |
| `Stmt\TryCatch` / `Catch_` / `Finally_`  | -        | ✓   | `Catch_` 含类型列表与捕获变量；`Finally_` 复用块节点            |
| `Stmt\Function_` 函数声明                | -        | ✓   |                                                                 |
| `Stmt\Class_` / `ClassMethod`            | -        | ✓   | 修饰符 abstract/final/static/readonly 已记录                    |
| `Stmt\Property` / `PropertyProperty`     | -        | ✓   | 含钩子、非对称可见性                                            |
| `Stmt\ClassConst` 类常量                 | -        | ✓   | 独立 `stmt_class_const` 节点，类型与可见性已细分                |
| `Stmt\Const_` 全局常量                   | -        | ✓   | 各常量经 `const_decl` 承载（`Name = 值`）                       |
| `Stmt\Interface_`                        | -        | ✓   |                                                                 |
| `Stmt\Trait_`                            | 5.4      | ✓   | 类体成员与横向 `use` 复用均实现                                 |
| `Stmt\Enum_`                             | 8.1      | ✓   |                                                                 |
| `Stmt\EnumCase`                          | 8.1      | ✓   |                                                                 |
| `Stmt\Namespace_`                        | 5.3      | ✓   | 支持 `Name;` / `Name { }` / `{ }` 三种形式                      |
| `Stmt\Use_` / `UseUse` 导入              | 5.3      | ✓   | 普通/函数/常量导入；别名经 `as` 承载                            |
| `Stmt\GroupUse` 分组导入                 | 7.0      | ✓   | `use A\B\{C, D as E};` 前缀 + 分组列表                          |
| `Stmt\TraitUse` 横向复用                 | 5.4      | ✓   | 成员经 `stmt_trait_use` 承载                                    |
| `Stmt\TraitUseAdaptation`（别名/优先级） | 5.4      | ✓   | 别名 `A::foo as bar` / 优先级 `A::foo insteadof B`              |
| `Stmt\Declare_` / `DeclareDeclare`       | -        | ✓   | `declare(ticks=1)` 与带块形式                                   |
| `Stmt\Goto_` / `Label`                   | 5.3      | ✓   | 标签经 `identifier :` 前瞻识别                                  |
| `Stmt\Global_` 全局变量                  | -        | ✓   |                                                                 |
| `Stmt\Static_` 静态变量                  | -        | ✓   | 含可选默认值的 `static_var` 节点                                |
| `Stmt\Unset_`                            | -        | ✓   |                                                                 |
| `Stmt\HaltCompiler` / `InlineHTML`       | -        | ✓   | `__halt_compiler()` 停止解析；闭标签后文本为 `inline_html` 节点 |
| `Stmt\Block` 语句块                      | -        | ✓   |                                                                 |

#### 表达式 Expr

| 节点（PHP-Parser）                                  | PHP 版本 | 状态 | 备注                                                                                       |
|-----------------------------------------------------|----------|------|--------------------------------------------------------------------------------------------|
| `Expr\Variable`                                     | -        | ✓   |                                                                                            |
| `Expr\Assign`（含复合赋值）                         | -        | ✓   | 普通赋值 `=`                                                                               |
| `Expr\AssignRef` 引用赋值 `=&`                      | -        | ✓   |                                                                                            |
| `Expr\AssignOp\*` 复合赋值算子                      | -        | ✓   | 运算符经 `main_token` 还原（`+=` `-=` 等）                                                 |
| `Expr\BinaryOp\*` 二元运算                          | -        | ✓   | 运算符经 `main_token` 还原；已支持 `&` `\|` `^` `<<` `>>` `??` `and`/`or`/`xor` 及比较运算 |
| `Expr\BitwiseNot` / `BooleanNot`                    | -        | ✓   |                                                                                            |
| `Expr\UnaryPlus` / `UnaryMinus`                     | -        | ✓   |                                                                                            |
| `Expr\PreInc` / `PreDec` 前缀 ++/--                 | -        | ✓   |                                                                                            |
| `Expr\PostInc` / `PostDec` 后缀 ++/--               | -        | ✓   |                                                                                            |
| `Expr\ErrorSuppress` `@`                            | -        | ✓   |                                                                                            |
| `Expr\Cast\*` 类型强转                              | -        | ✓   | `(int)` `(string)` 等（按强转类型名识别）                                                  |
| `Expr\ClassConstFetch`                              | -        | ✓   | 与静态属性/静态调用拆分为独立节点                                                          |
| `Expr\Clone_`                                       | -        | ✓   |                                                                                            |
| `Expr\Closure` / `ClosureUse` 闭包                  | 5.3      | ✓   | 匿名函数，含 `use (...)` 捕获                                                              |
| `Expr\ConstFetch`                                   | -        | ✓   |                                                                                            |
| `Expr\Empty_` / `Isset_`                            | -        | ✓   |                                                                                            |
| `Expr\Eval_`                                        | -        | ✓   |                                                                                            |
| `Expr\Exit_`                                        | -        | ✓   | `exit`/`die`，可选实参                                                                     |
| `Expr\FuncCall`                                     | -        | ✓   |                                                                                            |
| `Expr\Include_`                                     | -        | ✓   | `include`/`include_once`/`require`/`require_once`                                          |
| `Expr\Instanceof_`                                  | -        | ✓   |                                                                                            |
| `Expr\List_` 解构                                   | -        | ✓   | `list($a, $b)`                                                                             |
| `Expr\Match_`                                       | 8.0      | ✓   |                                                                                            |
| `Expr\MethodCall`                                   | -        | ✓   | `->` 调用/属性                                                                             |
| `Expr\New_`                                         | -        | ✓   | 含 8.4 无括号形式                                                                          |
| `Expr\NullsafeMethodCall` / `NullsafePropertyFetch` | 8.0      | ✓   | `?->`                                                                                      |
| `Expr\Array_`                                       | -        | ✓   | 元素键经 `expr_array_item` 承载                                                            |
| `Expr\ArrayDimFetch` 数组访问 `$a[0]`               | -        | ✓   |                                                                                            |
| `Expr\ArrayItem` 数组元素（键）                     | -        | ✓   | 含键与 `...$x` 解包                                                                        |
| `Expr\ArrowFunction` 箭头函数                       | 7.4      | ✓   | `fn (...) => ...`                                                                          |
| `Expr\PropertyFetch`                                | -        | ✓   |                                                                                            |
| `Expr\StaticCall` / `StaticPropertyFetch`           | -        | ✓   | 已与类常量拆分为独立节点                                                                   |
| `Expr\Ternary` 三元 `?:`                            | -        | ✓   | 含 elvis `?:`                                                                              |
| `Expr\Throw_`（表达式）                             | 8.0      | ✓   |                                                                                            |
| `Expr\Print_`                                       | -        | ✓   |                                                                                            |
| `Expr\ShellExec` 反引号                             | -        | ✓   | `` `...` ``                                                                                |
| `Expr\Yield_` / `YieldFrom`                         | 5.5      | ✓   | `yield` / `yield from`                                                                     |
| `Expr\FirstClassCallable` 一等可调用                | 8.1      | ✓   | `name(...)` 占位符形式                                                                     |
| `Expr\Argument`（命名/解包参数）                    | -        | ✓   | 命名 `f(a:1)` 与解包 `f(...$x)` 经 `expr_argument` 承载                                    |
| 括号分组 `(expr)`                                   | -        | ✓   |                                                                                            |

#### 标量 Scalar

| 节点（PHP-Parser）                            | PHP 版本 | 状态 | 备注                                                    |
|-----------------------------------------------|----------|------|---------------------------------------------------------|
| `Scalar\LNumber` / `Int_` 整型                | -        | ✓   |                                                         |
| `Scalar\DNumber` / `Float_` 浮点              | -        | ✓   |                                                         |
| `Scalar\String_` 字符串                       | -        | ✓   |                                                         |
| `Scalar\Encapsed` / `InterpolatedString` 内插 | -        | ✓   | 双引号/heredoc 经 `expr_encapsed` 承载；nowdoc 关闭插值 |
| `Scalar\EncapsedStringPart` 内插片段          | -        | ✓   | 经 `expr_string_part` 承载                              |
| `Scalar\MagicConst` 魔术常量                  | -        | ✓   | 经 `expr_magic_const` 承载（8 个魔术常量大小写不敏感）  |

#### 类型 Type

| 节点（PHP-Parser）                             | PHP 版本 | 状态 | 备注                                                                                           |
|------------------------------------------------|----------|------|------------------------------------------------------------------------------------------------|
| `Name` 名字 `Foo\Bar`                          | -        | ✓   | 经 `name` 承载                                                                                 |
| `Name\FullyQualified`                          | -        | ✓   | 首 token 为 `\` 时经 `name_fully_qualified` 承载                                               |
| `Name\Relative`                                | -        | ✓   | 首 token 为 `namespace` 时经 `name_relative` 承载                                              |
| `VarLikeIdentifier` 变量名                     | -        | ✓   | 首 token 为 `$` 时经 `name_var_like` 承载                                                      |
| `NullableType` 可空 `?T`                       | 7.1      | ✓   |                                                                                                |
| `UnionType` 联合 `A\|B`                        | 8.0      | ✓   |                                                                                                |
| `IntersectionType` 交集 `A&B`                  | 8.1      | ✓   |                                                                                                |
| DNF 类型 `(A&B)\|C`                            | 8.2      | ✓   | 括号分组解析为含 `IntersectionType` 成员的 `UnionType`，与 PHP-Parser 一致（括号不单独成节点） |
| `Identifier` 关键字类型 `never`/`true`/`false` | 8.1/8.2  | ✓   | 经 `type_name` 承载                                                                            |
| `Self_`/`Parent_`/`Static_` 伪类型             | -        | ✓   | `self`/`parent`/`static` 经 `type_self`/`type_parent`/`type_static` 承载                       |
| 泛型 `Foo<int>` / 数组后缀 `T[]`               | -        | ✓   | 经 `type_generic`/`type_array_of` 承载（`list<int>` 等亦支持）                                 |

#### 属性 Attribute（8.0+）

| 节点（PHP-Parser）          | PHP 版本 | 状态 | 备注                                                                                                         |
|-----------------------------|----------|------|--------------------------------------------------------------------------------------------------------------|
| `Attribute`                 | 8.0      | ✓   | `#[Deprecated]` 等天然支持                                                                                   |
| `AttributeGroup` 属性组节点 | 8.0      | ✓   | 每个 `#[...]` 生成 `attr_group`，组内 `Attribute` 以 `SubRange` 承载；参数/枚举 case/类常量/属性钩子均挂属性 |

#### 8.4 语法

| 能力                                   | PHP 版本 | 状态 | 备注         |
|----------------------------------------|----------|------|--------------|
| 属性钩子 `get`/`set`（`PropertyHook`） | 8.4      | ✓   |              |
| 非对称可见性 `public private(set)`     | 8.4      | ✓   |              |
| 无括号 `new`                           | 8.4      | ✓   |              |
| `#[Deprecated]`                        | 8.0      | ✓   | 即 Attribute |

#### 8.5 语法

| 能力                                                   | PHP 版本 | 状态 | 备注                                                                     |
|--------------------------------------------------------|----------|------|--------------------------------------------------------------------------|
| 管道运算符 `\|>`（`Expr\Pipe`）                        | 8.5      | ✓   | 独立 `expr_pipe` 节点；词法把 `\|` 与 `>` 拆成两个 token，解析时前瞻合并 |
| `(void)` 强转                                          | 8.5      | ✓   | 复用 `expr_cast` 节点，仅当强转类型为 `void` 时标注 8.5                  |
| `clone($obj, withProperties: [...])`                   | 8.5      | ✓   | `expr_clone` 节点新增可选的 `withProperties` 子节点                      |
| 常量上的注解（类常量 / 全局常量）                      | 8.5      | ✓   | `stmt_class_const` / `const_decl` 带属性组时标注 8.5                     |
| 构造器属性提升 + `final`（`public final int $x`）      | 8.5      | ✓   | `param` 节点在「提升且含 final 修饰」时标注 8.5                          |
| 静态属性非对称可见性（`public protected(set) static`） | 8.5      | ✓   | 非对称可见性（8.4）现已解析识别（set 侧可见性 != 3）；静态叠加即 8.5     |

#### 遍历与注释

| 能力                                                 | PHP 版本 | 状态 | 备注                                                                    |
|------------------------------------------------------|----------|------|-------------------------------------------------------------------------|
| `switch(nodeTag)` 自行遍历                           | -        | ✓   |                                                                         |
| `walk.childNodes` 枚举直接子节点                     | -        | ✓   | 给定节点返回其直接子节点索引数组                                        |
| `walk.walk` 深度优先遍历                             | -        | ✓   | 自根节点递归遍历全部节点，回调可中断                                    |
| `walk.leadingComments` / `trailingComments` 取回注释 | -        | ✓   | 沿 `firstToken`/`lastToken` 向前/向后扫描 `comment`/`doc_comment` token |
| docblock 经声明节点取用 `docCommentBefore`           | -        | ✓   | 取紧贴声明前的首个 `doc_comment` token                                  |
| `Ast.full.X` 再组装视图                              | -        | ×    |                                                                         |
| `Components` 内 `leading_comments`                   | -        | ×    | 由 `walk.leadingComments` 替代                                          |