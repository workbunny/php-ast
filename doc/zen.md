# php-ast 设计哲学（Zen）

> 本库的取舍原则与「语法特征 → AST 结构」映射的完整记录。

## 一、总述：信息分层

AST 只承载**语义**，语法细节被降维。信息不是丢弃，而是**分层存放**：

| 层 | 存放内容 | 用途 |
|---|---|---|
| AST（结构/字段/token 槽） | 语义：树结构、节点 tag、运算符、修饰符、名字 | 语义消费型下游（transpiler、静态检查） |
| token 流 | 全部词法单元（含注释、含偏移） | 语法高亮、语法级 lint、保真重建 |
| 原文（`Ast.source` + 区间） | 源码本身 | 精确切片、代码改写、报告定位 |

**判定法则**：一个语法特征该不该建节点，看「删掉后语义信息是否仍完整」。

- 删掉后语义仍完整 → **不建节点**，下放给结构/字段/token（括号、修饰符、运算符子类型）
- 删掉后语义丢失 → **建节点**（`expr_pipe`、`type_intersection`、`expr_yield`）

这套取舍下，AST 层做减法、token 层做兜底，整体无损。与 rustc（AST 不存注释，rustfmt 靠 token 流）、go/parser（gofmt 靠 token）、PHP-Parser 一致；TypeScript 的完整保真 AST 是反例——保真度越高，语义层越脏。

## 二、特殊点总表

「语法特征不建节点、由结构/字段隐式承载」的全部体现：

| # | 语法特征 | AST 呈现 | 语义信息载体 | 还原方式 |
|---|---|---|---|---|
| 1 | 分组括号 `(a+b)*c` | 不建节点，优先级由树嵌套表达 | 树结构（`expr_binary` 的左右子） | 打印器按优先级自加括号 |
| 2 | 冗余括号 `((a))` | 直接塌缩，与 `(a)` 同树 | 无（无语义） | 无需还原 |
| 3 | 二元运算符 `+ - * ?? <=>` 等 | 统一 `expr_binary` | `main_token` | `tokenSlice(main_token)` |
| 4 | 复合赋值 `+= -= *=` 等 | 统一 `expr_assign_op` | `main_token` | 同上 |
| 5 | 一元 `- + ! ~` 前置 `++ --` | 统一 `expr_unary` | `main_token` | 同上 |
| 6 | 可见性 / static / abstract / final / readonly | 不建节点 | `flags` / `visibility` 数值字段 | 按位解读 |
| 7 | 非对称可见性 `public private(set)` | 不建节点 | `visibility` 高字节（set 侧） | `(visibility >> 8)` |
| 8 | `elseif` 分支 | 折叠为嵌套 `stmt_if` | 树结构（else 分支为 if） | 打印器识别「else 是 if」还原 |
| 9 | `die()` | 与 `exit` 统一 `expr_exit` | 词法期归一 | 无需区分 |
| 10 | `include / include_once / require / require_once` | 统一 `expr_include` | `main_token` | `tokenSlice(main_token)` |
| 11 | `$a ?: $b`（elvis） | `expr_ternary` 且 then 为空 | `OptionalIndex.none` | 打印器按 then 空还原 `?:` |
| 12 | `and / or / xor` | 与 `&&`/`||` 同 `expr_binary` | 优先级表（bindingPower） | 优先级不同，tag 相同 |
| 13 | 管道 `\|>` | 词法拆 `\|`+`>` 两 token，解析前瞻合并 `expr_pipe` | 独立 tag | 词法层拆分、解析层合并 |
| 14 | 字符串三态（双引号/heredoc/nowdoc） | 统一 `string_start/part/end` | 词法路径 | nowdoc 不产变量节点 |
| 15 | 注释 / docblock | 不当节点，留在 token 流 | token tag | `leadingComments` / `docCommentBefore` |
| 16 | 构造器属性提升 `__construct(public int $x)` | 一个 `param` 节点 | `promoted` 标记字段 | 不建双节点 |
| 17 | 表达式语句 | 统一包 `stmt_expression` | 子节点 | 不区分语句种类 |
| 18 | `yield` | `expr_yield`（表达式）包 `stmt_expression` | 结构 | 无独立「yield 语句」节点 |
| 19 | 限定名 `Foo\Bar` | 一个 `name` 节点 | `main_token`（首段）+ `data.token`（末段） | 区间含全部分段 |
| 20 | 类型后缀 `(A&B)[]` | `type_array_of` 主 token 指向 `[` | 树结构（嵌套） | 区间从 `[` 起 |
| 21 | `use / use function / use const` | 统一 `stmt_use` | `kind` 数值（0/1/2） | 按位解读 |
| 22 | 全局常量 `const A = 1, B = 2` | `stmt_const` 含多个 `const_decl` | 子节点列表 | 不建独立「多声明」节点 |

## 三、设计哲学条目

1. **语义进 AST，语法进 token，原文常驻。** 三者分层存放、各取所需，下游按需取层。
2. **能由结构表达的就不建节点。** 优先级、分组、嵌套即结构。
3. **能由字段表达的就不建节点。** 修饰符、可见性、kind 即字段。
4. **能由 token 表达的就不建节点。** 运算符、标点、注释即 token。
5. **AST 有损、整体无损。** 被折叠的语法从 token 流/原文可重建，不丢信息。
6. **节点语义纯净。** 每个节点都有独立语义贡献，无噪音节点，便于遍历与模式匹配。

## 四、适用性边界

| 下游类型 | 适用度 | 说明 |
|---|---|---|
| transpiler（语义翻译） | 高 | 消费结构/tag/字段，被折叠语法翻译时本不需要 |
| 静态检查 / 语义分析 | 高 | 结构即语义，节点少、模式简单 |
| IDE（符号/跳转/折叠/重构） | 基本适用 | 需配合 token 流 + 区间 + `nameToken`；作用域/符号表是下游自建 |
| 语法级 lint（禁 `elseif` 写法等） | 部分 | 用 token 流/原文兜底，不进 AST |
| 格式化器 / 保风格转换 | 低 | 需 token 层之上单独建保真模块，不污染 AST |

## 五、与 PHP-Parser 的对照

本库约 110 个 AST `Tag`，PHP-Parser 约 170+ 节点类。差距主要来自：

- 运算符子类型折叠：PHP-Parser 的 `BinaryOp\Plus` 等几十个类 → 本库一个 `expr_binary` + `main_token`
- 修饰符/可见性：PHP-Parser 的 flags 位 → 本库同样用 flags 位，不建节点
- 语法糖归一：elseif / die / include 系列 → 统一节点
