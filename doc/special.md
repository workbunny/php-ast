# 与 php-parser 的差异清单

> 本文档对照 php-parser 5.8.0（`reference/PHP-Parser-full-5.8.0/`），逐模式列出 php-ast 与它的差异。
> 原则：**结构可异，用法趋同**——AST 的内部形态允许不同，但对使用者的操作方式尽量贴合，
> 让 php-parser 用户能低迁移成本转向本项目。
> 逐节点的覆盖映射见 README「节点覆盖」章节；本文档聚焦"差异本身"。

## 一、定位差异（一切差异的根源）

| | php-parser | php-ast |
|---|---|---|
| AST 定位 | **保真 AST**：尽量保留源码结构 | **语义 AST**：语法细节降维（见 `doc/zen.md` 信息分层） |
| 形态 | 对象树（OO 节点类，~170+） | 结构数组（SoA：`Node{tag, main_token, data}` 定长 + `extra_data`） |
| 判据 | 语法产生式一一对应 | 「删掉后语义是否完整」——完整则降维，不建节点 |

定位差异体现在下文每个模式中：**php-parser 用"类层次"表达子类型，php-ast 用"tag + token/字段"表达同一信息**。

## 二、差异模式总览

| # | 模式 | php-parser | php-ast | 本质 |
|---|---|---|---|---|
| P1 | 运算符子类型 | `BinaryOp\Plus`…、`AssignOp\*`、`UnaryOp\*` 等子类（~40 类） | `expr_binary`/`expr_assign_op`/`expr_unary` + `main_token` 记录运算符 | 类层次 → tag + token |
| P2 | 语句归一 | `ElseIf_`/`Else_`/`Finally_`/`DeclareItem` 独立节点 | 折叠：elseif 递归嵌套 `stmt_if`；finally 复用 `stmt_block`；declare 项折叠 | 语法结构 → 语义结构 |
| P3 | 名字体系 | `Name`/`FullyQualified`/`Relative`（OO 继承） | `name`/`name_fully_qualified`/`name_relative`/`name_var_like` | 继承 → tag 区分 |
| P4 | 标量与魔术常量 | `Scalar\Int_`…、`MagicConst\Line`…（~12 类） | `expr_int`/`expr_float`/`expr_string`…、`expr_magic_const` + token | 子类 → token 区分 |
| P5 | 位置与注释 | 每节点 `getAttributes()` 含 start/end 行列、comments | `main_token` 派生位置；注释存 token 流（`leadingComments`/`trailingComments`） | 节点内嵌 → 索引派生 |
| P6 | 错误模型 | 默认抛 `PhpParser\Error`（fail-fast）；可选 error recovery 产 `Expr\Error` | 尽力解析 + `errors` 数组（按 `Error.Tag` 分类）；`stmt_error` 节点 | 异常 → 收集 |
| P7 | 版本门控 | 无（按语法版本建 parser，节点不记录引入版本） | `parse(version)` 逐节点门控；`tagVersion` + `unsupported_version` 错误 | php-parser 无此维度 |
| P8 | 修饰符 | `flags` 属性对齐 PHP 内核（`PUBLIC=1 PROTECTED=2 PRIVATE=4 STATIC=16 ABSTRACT=32 FINAL=64 READONLY=128`） | Components 内 `flags` 位（`abstract=1 final=2 static=4 readonly=8`）+ `visibility` 0/1/2 | 位布局不同 |
| P9 | 遍历/查询 | `getSubNodeNames()`/`NodeFinder`/`NodeTraverser` | `forEachChild`/`walk`/`childNodes` + `Index` | OO 导航 → 索引遍历 |
| P10 | 新语法形态 | 8.4 属性钩子/非对称可见性、8.5 管道等各自成节点 | 同功能但降维（见 P2 模式） | 同 P1/P2 |

## 三、逐模式详述

### P1 运算符子类型折叠

```php
$a + $b;   $a ** $b;   $a ?? $b;   ++$c;   !$d;
```

php-parser：每个运算符一个子类节点——`Expr\BinaryOp\Plus`、`Expr\BinaryOp\Pow`、
`Expr\BinaryOp\Coalesce`、`Expr\PreInc`、`Expr\BooleanNot`……共约 40 个类，靠继承关系分组。

php-ast：折叠为统一 tag + 运算符 token：

| php-parser | php-ast | 区分依据 |
|---|---|---|
| `BinaryOp\*`（20+） | `expr_binary` | `main_token` 指向 `+`/`**`/`??` 等 token |
| `AssignOp\*`（14） | `expr_assign_op` | 同上（`+=`/`**=`/`??=`） |
| `UnaryOp\Plus/Minus`、`BooleanNot`、`BitwiseNot` | `expr_unary` | `main_token` 指向 `+`/`-`/`!`/`~` |
| `PreInc`/`PreDec`/`PostInc`/`PostDec` | `expr_post_inc`/`expr_post_dec` | 前后缀经额外 token 或 `main_token` 位置区分 |

**取舍**：运算符子类型是"语法细节"——`+` 与 `-` 的差异已由 token 完整表达，删掉子类
节点语义不丢失，故降维。php-parser 受 OO 表达所限必须建类。

**对用户**：`if ($node instanceof BinaryOp\Plus)` → `node.tag == .expr_binary and
tokenTag(main_token) == .plus`。

### P2 语句归一

```php
if ($a) { } elseif ($b) { } else { }
```

php-parser：`If_` 含 `cond`、`stmts`、`elseifs: []ElseIf_`、`else: ?Else_`——扁平结构，
elseif/else 是独立节点类。

php-ast：`elseif` 分支**递归解析为嵌套 `stmt_if`**——`else_body` 若指向另一 `stmt_if`
即隐含 elseif。`else { if ... }` 与 `elseif` 语义等价（PHP 语言如此），故可降维不区分。

```php
try { } catch (E $e) { } finally { }
```

php-parser：`Finally_` 独立节点类。
php-ast：`finally` 体复用 `stmt_block`（子句容器，无独立 tag）。

```php
declare(ticks=1);
```

php-parser：`Declare_` + `DeclareItem`（key/value 项）。
php-ast：`declare_declare` tag 保留（key 是 token、value 是表达式），未叠一层数组。

**取舍**：归一是"语义等价则合并"的体现——`elseif` 与 `else { if }` 行为无差别、finally
体与普通块无差别，建独立节点是保真而非必需。

### P3 名字体系

| php-parser | php-ast |
|---|---|
| `Name`（相对名） | `name` |
| `FullyQualified`（`\Foo`，Name 子类） | `name_fully_qualified` |
| `Relative`（`namespace\Foo`，Name 子类） | `name_relative` |
| `VarLikeIdentifier`（名字位置可放 `$var`） | `name_var_like` |

**差异点（新语法类名）**：php-parser 在 `new $cls` 处解析为 `Expr_Variable`（类名位置
统一 Name/Expr）；php-ast 视"new 的类名"语义上是名字，纯变量 `$cls` 降维为
`name_var_like`。带后缀（`$arr['c']`/`$obj->p`/`X::$p`）则双方都升为完整表达式——
名字结构表达不了下标/属性链。

### P4 标量与魔术常量

| php-parser | php-ast |
|---|---|
| `Scalar\Int_`/`Float_`/`String_` | `expr_int`/`expr_float`/`expr_string` |
| `Scalar\Encapsed`/`EncapsedStringPart` | `expr_encapsed`/`expr_string_part` |
| `Scalar\MagicConst\Line/File/…`（~10 类） | `expr_magic_const`（`main_token` 指向 `__LINE__` 等） |

**取舍**：哪个魔术常量已由 token 完整表达，子类折叠为 `expr_magic_const` + token。

### P5 位置与注释

php-parser：每节点 `getAttributes()` 返回 `startLine/endLine/startFilePos/endFilePos/
comments`——位置与注释内嵌节点。

php-ast：位置由 `main_token` 派生（`tokenSlice`/`Location` 换算行列）；注释常驻 token 流，
经 `walk.leadingComments`/`trailingComments` 取。

**取舍**：逐节点内嵌位置会放大 SoA 体积（每节点多个 usize）；语义 AST 只保留
`main_token`，需要区间再派生。注释不是语义，归 token 侧（信息分层：原文常驻可溯源）。

### P6 错误模型

| | php-parser | php-ast |
|---|---|---|
| 默认行为 | 解析失败抛 `PhpParser\Error`（含第一错误位置） | 尽力解析，全部错误收进 `errors` 数组 |
| 恢复 | 可选 `withErrorHandler` 产 `Expr\Error`/`Stmt\Error` 节点 | 始终尝试恢复，`stmt_error` 节点 |
| 错误信息 | 消息字符串 | `Error.Tag` 枚举（`expected_token`/`unsupported_version` 等）+ token 定位 |

**取舍**：收集模型利于"批量分析全部语法问题"（编辑器/CI 场景），fail-fast 利于"一错即停"
（单文件工具）。php-ast 选收集。

### P7 版本门控

php-parser：按语法版本实例化 parser（`PhpVersion::fromString`），但**节点不携带引入版本**。

php-ast：`parse(gpa, source, version)`——目标版本作为参数，逐节点 `tagVersion()` 门控，
高于目标版本的构造记入 `errors` 的 `unsupported_version`。这是 php-ast 独有的信息维度
（服务于"翻译器的版本感知"需求，见 `doc/translate-php.md`）。

### P8 修饰符

| | php-parser | php-ast |
|---|---|---|
| 位置 | 节点属性 `flags` | extra_data 的 `XxxComponents.flags` |
| public/protected/private | `flags` 位 1/2/4 | `visibility` 字段 0/1/2（单独） |
| abstract/final/static/readonly | `flags` 位 32/64/16/128 | `flags` 位 1/2/4/8 |
| 对齐对象 | PHP 内核 `MODIFIER_*` | 自定紧凑布局 |

**差异**：位布局与 php-parser 不同（php-parser 对齐 Zend 内核，我们紧凑排列）。迁移者
需经项目提供的 flags 常量读取，勿直接按 php-parser 位值判。

### P9 遍历/查询形态

| php-parser | php-ast |
|---|---|
| `$node->getType()`（如 `'Expr_BinaryOp_Plus'`） | `node.tag`（枚举，`@intFromEnum`/`tagName`） |
| `$node->expr`（属性访问） | `data` 联合按 tag 取子索引，再 `tree.nodeAt` |
| `NodeFinder::findInstanceOf(X)` | `walk` + tag 过滤 |
| `NodeTraverser`/`NodeVisitor` | `walk`（回调节点路径） |
| 根 | `Parser::parse` 返回 `Stmt[]` | `Ast`（root 节点 + 数组）+ `rootStmts()` |

**结构可异的核心**：php-parser 的属性访问 `$node->expr` 是 OO 便捷；php-ast 的 `data`
联合 + `Index` 是 SoA 代价。**用法趋同的落点**是提供与语义对应的查询函数（见下节）。

### P10 新语法形态（8.4 / 8.5）

| PHP 特性 | php-parser | php-ast |
|---|---|---|
| 属性钩子（8.4） | `PropertyHook` 节点挂 `Property` | `property_hook` tag 挂 `stmt_property` |
| 非对称可见性（8.4） | `setVisibility` 修饰符 | `PropertyComponents.visibility` 记录 set 侧 |
| 管道 `\|>`（8.5） | `Expr\Pipe` | `expr_pipe` |
| `(void)` 强转（8.5） | `Cast\Void_` 之类 | `expr_cast` + token 区分 |
| `clone withProperties`（8.5） | `Clone_` 扩展字段 | `expr_clone` + extra 字段 |
| 常量注解（8.5） | `Attribute` 可挂 const | `attribute` 可挂 const |
| 构造器提升 + `final`（8.5） | `final` 并入提升参数 flags | `ParamComponents.flags` |

## 四、用法差异与对齐（迁移对照）

目标：php-parser 用户按"意图"查找对应操作，不感知内部 SoA。

| php-parser 惯用法 | php-ast 等价用法 |
|---|---|
| `$node instanceof Stmt\If_` | `node.tag == .stmt_if` |
| `$node instanceof Expr\BinaryOp\Plus` | `node.tag == .expr_binary and tokenTagOf(main_token) == .plus` |
| `$node->expr` | `tree.childByRole(node, .left)` 之类按语义取子（tag 决定角色） |
| `$parser->parse($code)` | `parse(gpa, source, version)` |
| `catch (PhpParser\Error $e)` | 遍历 `tree.errors`（数组，可继续用树） |
| `$node->getStartLine()` | `tree.locationOf(node)`（行/列/区间） |
| `$node->getComments()` | `walk.leadingComments(gpa, tree, node, &list)` |
| `NodeFinder::findInstanceOf(Stmt\Function_)` | `walk` + `tag == .stmt_function` 过滤 |
| `NodeVisitor::enterNode` | `walk` 回调（携带节点路径） |
| `$node->getType()` | `@tagName(node.tag)`（内部名）或 `compat.phpParserType(tag)`（php-parser 风格名，见下） |

**已提供的对齐**（`src/compat.zig`，对照写法见 `doc/example.md`）：
- php-parser 风格类型名字符串：`phpParserType(tag)` → `'Stmt_If'`/`'Expr_New'`（零分配）；
- 位置 API：`startLine/endLine/startFilePos/endFilePos/startTokenPos/endTokenPos`（由 main_token 派生）；
- doc comment：`getDocComment(tree, gpa, node)`；attributes：`AttrMap`（node → 键值旁表）。

**尚未提供的对齐**（规划中）：
- 角色化子访问器（`cond`/`then`/`else` 等按语义命名，隐藏 data 布局）。

## 五、覆盖对照

逐节点支持状态见 README「节点覆盖」章节（按 Stmt/Expr/Scalar/Type/Attribute/8.4/8.5
分节）。本文档 P1–P10 是那些映射背后的**差异模式**——任何节点差异都可归入其一。

## 六、维护

- php-parser 参考版本固定在 `reference/PHP-Parser-full-5.8.0/`（含 grammar/php.y 权威
  规则与 test/code fixture）。升级参照物时同步更新 grammar 差异结论。
- 新增解析能力时，先在 uvs 类 fixture（`test/code/parser/expr/uvs/`）核对"不寻常语法"
  覆盖，再落 hand-write 测试。
