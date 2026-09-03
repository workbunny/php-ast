# php-ast 设计哲学（Zen）

> 本库的取舍原则与「语法特征 → AST 结构」映射的完整记录。多轮实现迭代中新增的
> 归一决策（变量统一化、引用语义、间接变量、flexible heredoc 等）已并入下表。

## 一、总述：信息分层

AST 只承载**语义**，语法细节被降维。信息不是丢弃，而是**分层存放**：

| 层                          | 存放内容                                     | 用途                              |
|-----------------------------|----------------------------------------------|-----------------------------------|
| AST（结构/字段/token 槽）   | 语义：树结构、节点 tag、运算符、修饰符、名字 | 语义消费型下游（transpiler、静态检查） |
| token 流                    | 全部词法单元（含注释、含偏移）               | 语法高亮、语法级 lint、保真重建  |
| 原文（`Ast.source` + 区间） | 源码本身                                     | 精确切片、代码改写、报告定位     |

**判定法则**：一个语法特征该不该建节点，看「删掉后语义信息是否仍完整」：

- 删掉后语义仍完整 → **不建节点**，下放给结构/字段/token（括号、修饰符、运算符子类型）
- 删掉后语义丢失 → **建节点**（`expr_pipe`、`type_intersection`、`expr_variable_ref`）

这套取舍下 AST 层做减法、token 层做兜底、整体无损。与 rustc、go/parser、PHP-Parser
一致；TypeScript 的完整保真 AST 是反例——保真度越高，语义层越脏。

## 二、特殊点总表

「语法特征不建节点、由结构/字段隐式承载」以及「tag 归一」的全部体现：

| # | 语法特征 | AST 呈现 | 语义信息载体 | 还原方式 |
|---|----------|----------|--------------|----------|
| 1 | 分组括号 `(a+b)*c` | 不建节点，优先级由树嵌套表达 | 树结构 | 打印器按优先级自加括号 |
| 2 | 冗余括号 `((a))` | 直接塌缩，与 `(a)` 同树 | 无（无语义） | 无需还原 |
| 3 | 二元运算符 `+ - * ?? <=>` 等 | 统一 `expr_binary` | `main_token` | `tokenSlice(main_token)` |
| 4 | 复合赋值 `+= -=` 及 `<<= >>= ??=` | 统一 `expr_assign_op` | `main_token` | 同上 |
| 5 | 一元 `- + ! ~ @`、前置 `++ --` | 统一 `expr_unary`（`@` 亦如此） | `main_token` | 同上 |
| 6 | 后缀 `++ --` | `expr_post_inc` / `expr_post_dec` | `main_token` | 同上 |
| 7 | 可见性 / static / abstract / final / readonly | 不建节点 | `flags` 数值字段 | 按位解读 |
| 8 | 非对称可见性 `public private(set)` | 不建节点 | `visibility` 高字节（set 侧） | `(visibility >> 8)` |
| 9 | `elseif` / `else if` 分支 | 折叠为嵌套 `stmt_if` | 树结构 | 打印器识别「else 是 if」还原 |
| 10 | `die()` | 词法期与 `exit` 归一为 `expr_exit` | 词法路径 | 无需区分 |
| 11 | `include / include_once / require / require_once` | 统一 `expr_include` | `main_token` | `tokenSlice(main_token)` |
| 12 | `$a ?: $b`（elvis） | `expr_ternary` 且 then 为空 | `OptionalIndex.none` | 打印器按 then 空还原 `?:` |
| 13 | `and / or / xor` | 与 `&&` / `\|\|` / `^^` 同 `expr_binary` | `main_token` | 优先级表（bindingPower）不同，tag 相同 |
| 14 | 管道 `\|>`（8.5） | 词法拆 `\|`+`>` 两 token，解析前瞻合并 | 独立 tag `expr_pipe` | 词法层拆分、解析层合并 |
| 15 | 字符串三态（双引号 / heredoc / nowdoc） | 统一 `string_start/part/end` token | 词法路径 | nowdoc 关闭插值、不产变量节点 |
| 16 | 注释 / docblock | 不当节点，留在 token 流 | token tag | `walk.leadingComments` / `docCommentBefore` |
| 17 | 构造器属性提升 `__construct(public int $x)` | 一个 `param` 节点 | `promoted` 标记字段 | 不建双节点 |
| 18 | 表达式语句 / `yield` / `throw` / `print` | 统一包 `stmt_expression` | 子节点 | 不区分语句种类 |
| 19 | 限定名 `Foo\Bar` | 一个 `name` 节点 | `main_token`（首段）+ 末段 token | 区间含全部分段 |
| 20 | 名字段含关键字（`fn\use`、`namespace static`） | 关键字可作名字段（semi_reserved） | 段 token | 与普通标识符段同构 |
| 21 | 变量形态：`$a` / `$$a` / `$$$a` / `${expr}` | 简单 `$a` = `expr_variable`（token 叶）；间接 `$$a`/`${expr}` = `expr_variable_ref`（name 为子节点，递归表达嵌套） | 结构 | `phpParserType` 两者同归 `Expr_Variable` |
| 22 | 引用语义：返回引用 `&`、参数 `&$x`、`&...$x`、数组/list 元素、call-time 实参 `f(&$x)`、foreach 值 `as &$v`、闭包 use `&$x` | 各组件 `by_ref` 语义字段（`ForeachComponents.value_by_ref`） | 组件字段 | 打印时前缀 `&` |
| 23 | 类型后缀 `(A&B)[]` | `type_array_of` 主 token 指向 `[` | 树结构（嵌套） | 区间从 `[` 起 |
| 24 | `use / use function / use const` 与 group use | `stmt_use`（kind 0/1/2）+ 独立 `stmt_group_use` | kind 数值 / tag | 按位解读 |
| 25 | 全局常量 `const A = 1, B = 2` 与类常量 `const A = 1, B = 2` | `stmt_const` / `stmt_class_const` 含多个 `const_decl` 子节点 | 子节点列表 | 不建独立「多声明」节点 |
| 26 | `for` 三段各含逗号列表（`for ($i=0,$j=1; ...; $i++,$j--)`） | `ForComponents.init/cond/inc` 为表达式列表 | 子节点列表 | 空段 = 空列表 |
| 27 | `foreach` 值引用 | `ForeachComponents.value_by_ref` | 字段 | 打印前缀 `&` |
| 28 | 类常量 / 全局常量名可含关键字（`const TRAIT`） | 名字 token 直接取关键字 | 段 token | 与标识符同构 |

## 三、设计哲学条目

1. **语义进 AST，语法进 token，原文常驻。** 三者分层存放、各取所需，下游按需取层。
2. **能由结构表达的就不建节点。** 优先级、分组、嵌套即结构。
3. **能由字段表达的就不建节点。** 修饰符、可见性、kind、引用语义即字段。
4. **能由 token 表达的就不建节点。** 运算符、标点、注释即 token。
5. **AST 有损、整体无损。** 被折叠的语法从 token 流/原文可重建，不丢信息。
6. **节点语义纯净。** 每个节点都有独立语义贡献，无噪音节点，便于遍历与模式匹配。
7. **tag 归一不等于语义丢失。** 归一发生在「下游消费时可经字段/token 区分」的粒度
   （`expr_binary`+运算符、`expr_exit` 含 die）；仅在无法区分或引入歧义处保留独立 tag
   （`expr_variable_ref` 因 name 是子节点、形状不同而独立）。
8. **失败不消费、错误收集不中断。** 解析失败返回 null 须回卷游标；错误进
   `ast.errors` 继续解析，语句级无法恢复处产 `stmt_error` 节点兜底（见
   `doc/special.md` P6 错误模型）。

## 四、适用性边界

| 下游类型                      | 适用度   | 说明                                                        |
|-------------------------------|----------|-------------------------------------------------------------|
| transpiler（语义翻译）        | 高       | 消费结构/tag/字段，被折叠语法翻译时本不需要                 |
| 静态检查 / 语义分析           | 高       | 结构即语义，节点少、模式简单                                |
| IDE（符号/跳转/折叠/重构）    | 基本适用 | 需配合 token 流 + 区间 + `nameToken`；作用域/符号表是下游自建 |
| 语法级 lint（禁 `elseif` 写法）| 部分     | 用 token 流/原文兜底，不进 AST                              |
| 格式化器 / 保风格转换         | 低       | 需 token 层之上单独建保真模块（B5 打印子系统），不污染 AST   |

## 五、与 PHP-Parser 的对照

本库 118 个 AST `Tag`（含 `root`），PHP-Parser 约 170+ 节点类。差距主要来自：

- 运算符子类型折叠：`BinaryOp\Plus` 等几十个类 → 一个 `expr_binary` + `main_token`
- 修饰符/可见性：flags 位承载，不建节点
- 语法糖归一：elseif / die / include 系列 → 统一节点
- 名字形态归一：`Name`/`FullyQualified`/`Relative`/`VarLikeIdentifier` 各有 tag
  （php-parser 是四个类），但 `$$a`/`${expr}` 不另立 `VariableVariable`——与
  php-parser 同归 `Expr\Variable`，以 `expr_variable_ref` 表达"name 是子节点"的差异

反向（php-parser 没有、本库新增）：
- `expr_pipe` 等 8.5 前沿语法（php-parser 5.8 未含管道）
- `expr_variable_ref` 仅内部 tag 差异，`phpParserType` 对外仍报 `Expr_Variable`
- 版本门控 `tagVersion`（php-parser 的 lexer emulation 只在旧版本上模拟新 token）
