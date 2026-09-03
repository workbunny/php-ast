# 用法对齐示例

"用法趋同"的定义：**php-parser 用户能完成的操作，本库必须能完成，且获取成本同级**——
php-parser 若干行解决的问题，本库不应要求更多行或更绕的路径（绕路意味着损失性能与体验）。

本库内部结构与 php-parser 不同（保真对象树 vs 语义 SoA），但面向使用者的操作应收敛到
同等表达力。本文档逐例给出两边写法，作为对齐验收：

- 结果一致（两侧判定同一事物）；
- 行数/复杂度同级（php-ast 明显更长 = API 缺陷，应优化至同级）；
- 本库额外能做的（php-parser 做不到的）一并示例。

判例口径见 `todo.md`「用法趋同的定义」；结构差异根源见 `doc/special.md`。

---

## 例 1：判断节点是否为"静态属性取类名"

判断一个表达式节点是否为 `Foo::$bar`（static property fetch）。

```php
// php-parser：类型判断
use PhpParser\Node\Expr;
if ($node instanceof Expr\StaticPropertyFetch) {
    // 子项：$node->class / $node->name
}
```

```zig
// php-ast：tag 判断
if (node.tag == .expr_static_property_fetch) {
    // 子项：.node_and_node（class, name）
}
```

**结论**：同级。`instanceof 判类` 与 `tag 判枚举` 一一对应（根源见 special.md P1/P3）。

---

## 例 2：识别 `new` 的类名形态

`new` 的类名可以是名字（`Foo`）、变量（`$cls`）、带后缀表达式（`$arr['c']`、
`Foo::$bar`）或括号任意表达式（PHP 8.0+）。识别"名字 vs 表达式"：

```php
// php-parser：New_ 的 class 字段统一是 Name 或 Expr
$class = $node->class;
if ($class instanceof Name) { /* 名字类名 */ }
else { /* 表达式类名：Variable / ArrayDimFetch / StaticPropertyFetch ... */ }
```

```zig
// php-ast：名字形态降维为 name* tag；后缀形态升为表达式 tag
switch (node.tag) {
    .name, .name_fully_qualified, .name_relative, .name_var_like => { /* 名字类名 */ },
    .expr_array_dim_fetch, .expr_property_fetch, .expr_static_property_fetch,
    .expr_nullsafe_property_fetch, ... => { /* 表达式类名 */ },
}
```

**结论**：结果一致。差异在纯变量 `new $cls`：php-parser 记为 `Expr_Variable`，
本库降维为 `name_var_like`——因为类名位置的纯变量在语义上就是"待解析的名字"
（zen：信息分层）。判断"是否名字"请用 4 个 `name*` tag 的并集（对应 php-parser
`instanceof Name` 命中 Name/FullyQualified/Relative）。

---

## 例 3：本库额外能做的——名字的单一谓词判定

php-parser 的名字是继承体系（`Name` / `FullyQualified` / `Relative` 三个类），
"是否名字"要 `instanceof Name`（命中全部子类）；本库 4 个名字 tag 语义上共用一个
"名字"角色，可提供单一谓词一次判定，无需枚举 tag（规划中：`isNameTag()`）。

---

## 例 4：名字解析（use 别名 → 完全限定名）的结果取用

对 `namespace App; use Vendor\Foo as V; new V();` 求出 `V` 的 FQN（`Vendor\Foo`）。

```php
// php-parser：NameResolver 原地改写节点 + 挂属性
$traverser->addVisitor(new NameResolver());
$traverser->traverse($stmts);
$fqn = $nameNode->getAttribute('resolvedName');   // 或 $nameNode->name 已是 FQN
```

```zig
// php-ast：token 流固定无法原地改写 → 旁表查询
var res = try php_ast.name_resolver.resolve(tree, gpa, true);
defer res.deinit();
const fqn = res.lookup(name_node);                // ?[]const u8 = "Vendor\Foo"
```

**结论**：结果一致。实现差异：php-parser 允许改写名字节点（挂 `resolvedName` 属性），
本库 token 区间表达名字、token 流固定，改为产出旁表（`Resolution`），一次遍历建索引、
`lookup(node)` 取 FQN。`Resolution.deinit` 统一释放，多次查询零额外分配。

---

## 例 5：按类型收集节点

收集全树所有函数声明：

```php
// php-parser：NodeFinder 按类过滤
$finder = new NodeFinder;
$fns = $finder->findInstanceOf($stmts, Stmt\Function_::class);
```

```zig
// php-ast：按 tag 过滤
var out: std.ArrayList(ast.Index) = .empty;
defer out.deinit(gpa);
try php_ast.node_finder.findTag(gpa, tree, tree.root, .stmt_function, &out);
```

**结论**：同级。类过滤与 tag 过滤语义等价——php-parser 的 `X::class` 传入即类对象，
本库直接传 tag 枚举。

---

## 例 6：找第一个匹配节点（短路）

```php
// php-parser
$fn = $finder->findFirstInstanceOf($stmts, Stmt\Function_::class);
```

```zig
// php-ast：findFirst 命中即返回，不遍历剩余树
const fn_node = try php_ast.node_finder.findFirstTag(gpa, tree, tree.root, .stmt_function);
```

**结论**：同级且本库为真短路。php-parser 的 first-finding 依赖 visitor 机制提前终止；
本库 `findFirst*` 手写显式栈，命中即 `return`，剩余子树完全不访问。

---

## 例 7：父链访问

给定任一节点，沿父链走到根：

```php
// php-parser：ParentConnectingVisitor 把 parent 挂到节点属性
$traverser->addVisitor(new ParentConnectingVisitor);
$traverser->traverse($stmts);
for ($n = $node; $n; $n = $n->getAttribute('parent')) { /* ... */ }
```

```zig
// php-ast：一次构建旁表，按需查询
var map = try php_ast.parent_map.build(gpa, tree, tree.root);
defer map.deinit();
var chain: std.ArrayList(ast.Index) = .empty;
defer chain.deinit(gpa);
try map.chainToRoot(node, &chain);   // node → parent → ... → root
const parent = map.parentOf(node);   // ?ast.Index
```

**结论**：结果一致。php-parser 将 parent 写入节点属性（需每次遍历重建）；本库以旁表
`ParentMap` 承载，`build` 一次、查询任意次，适合"先建索引再多次反查"的分析场景。

---

## 例 8：节点类型名与位置（日志 / 调试对齐）

打印节点的 php-parser 风格类型名与行列位置：

```php
// php-parser：类型名与位置是节点内置属性
$type = $node->getType();          // 'Stmt_If'
$line = $node->getStartLine();     // 2（1 基）
$pos  = $node->getStartFilePos();  // 字节偏移
```

```zig
// php-ast：compat 层同名函数（tag 全量映射 + main_token 现算）
const type = php_ast.compat.phpParserType(node.tag);   // "Stmt_If"
const line = php_ast.compat.startLine(tree, node);     // 2（1 基）
const pos  = php_ast.compat.startFilePos(tree, node);  // 字节偏移
```

**结论**：同级。php-parser 把类型名与位置作为节点属性内嵌；本库由 tag 映射与
`main_token` 派生，纯函数无状态，六个位置函数（Line/FilePos/TokenPos × start/end）
齐全且语义对齐（`endFilePos` 为末字节之后）。

---

## 例 9：doc comment 与自定义元数据

读取前置 docblock、为节点挂任意键值元数据（如分析阶段的标注）：

```php
// php-parser：comment 与 attribute 都挂在节点上
$doc  = $node->getDocComment();    // ?Comment\Doc
$node->setAttribute('kind', 'class');
$kind = $node->getAttribute('kind');
```

```zig
// php-ast：token 流固定 → doc comment 拷贝返回；节点定长 → attributes 用旁表
const doc = try php_ast.compat.getDocComment(tree, gpa, node);   // ?[]u8，调用方释放
var attrs = php_ast.compat.AttrMap.init(gpa);
defer attrs.deinit();
try attrs.set(node, "kind", "class");
const kind = attrs.get(node, "kind");                            // ?[]const u8
```

**结论**：结果一致。php-parser 的 attribute 随节点对象携带；本库以 `AttrMap` 旁表显式
持有——键值拷贝到 `gpa` 并统一释放，覆盖同名键仅替换 value 不泄漏。`getDocComment`
只返回 docblock（普通注释不返回），与 php-parser 语义一致。

---

## 对照写法约定（回顾）

- 结果一致：两侧操作落在同一语义结果上；
- 复杂度同级：php-ast 版本不应显著更长/更绕，否则视为 API 缺陷回炉；
- 已覆盖项见上（含 compat 层：类型名字符串、位置、doc comment、attributes，实现于
  `src/compat.zig`）；未覆盖项（树变换、源码打印，todo.md 第四批 B2/B5）在对应
  todo 项完成后补例，口径不变。
