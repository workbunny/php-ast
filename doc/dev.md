# php-ast 开发者手册

本文档面向在 php-ast 上做日常开发的工程师：说明代码库布局、测试体系（种类 /
触发方式 / 常见问题 / 调试方法）、开发流程与注意事项。配套阅读：

- `README.md`：项目总览、架构、快速开始
- `doc/zen.md`：设计哲学——哪些语法建节点、哪些折叠（改动 AST 前必读）
- `doc/api.md`：公开 API 手册
- `doc/example.md`：与 PHP-Parser 的用法对照示例
- `doc/special.md`：与 PHP-Parser 的结构差异清单

## 1. 代码库布局

| 路径                            | 内容                                                            |
|---------------------------------|-----------------------------------------------------------------|
| `src/`                          | 库实现。每个源文件**尾部**内嵌该文件的单元测试                  |
| `src/coverage.zig`              | 覆盖矩阵：编译期校验每个节点/词法种类都有用例                   |
| `src/golden.zig`                | 黄金快照比对逻辑（数据在 `tests/golden`）                       |
| `tests/golden/`                 | 黄金快照：`*.php` 源码与同名 `*.txt`（AST dump）成对            |
| `tests/third_party/php-parser/` | PHP-Parser 5.8.0 测试子集（BSD 3-Clause，含 `LICENSE`），供对照 |
| `tools/`                        | 开发工具（不随库编译，见 §2.4）                                 |

约定：`third_party/` 内容原样保留，不增删不改；需要基于其样例扩展时，另存文件并注明
来源。

## 2. 测试体系

| 种类       | 位置                             | 触发                                                   | 锁什么                                   |
|------------|----------------------------------|--------------------------------------------------------|------------------------------------------|
| 单元测试   | `src/*.zig` 尾部 `test "..."` 块 | `zig build test`                                       | 单条特性行为（解析结果 / 遍历 / API）    |
| 覆盖矩阵   | `src/coverage.zig`               | 同上（**编译期**校验）                                 | 每个 `Node.Tag`/`Token.Tag` 都有最小用例 |
| 黄金快照   | `tests/golden/**`                | `zig build test`（自动比对）；`-Dupdate-golden` 重生成 | 整棵树结构（含诊断）逐字节锁定           |
| 一致性对照 | `tools/parity_check.zig`          | `zig build check-parity`                               | 与 PHP-Parser 测试子集的接受面与诊断质量  |

### 2.1 单元测试

**运行**：`zig build test --summary all`。

**只跑某个用例**：`zig build` 不透传 `--test-filter`，用单文件方式：

```sh
zig test src/root.zig --test-filter "expr :: 赋值"
```

`--test-filter` 取测试名任意片段。测试命名约定 `<域> :: <特性> :: <场景>`，例如
`test "expr :: 变量变量 :: 间接变量与花括号名全形态"`。

**常见问题**

- `All 0 tests passed`：含 `test` 的新模块没有在 `src/root.zig` 末尾的登记块里
  `_ = @import(...)`。Zig 对 import 惰性分析，re-export 不会强制收集测试。
- 断言失败只显示 tag 计数不符：改用结构视角排查——对同一段源码打印完整 AST
  （见 §3.3），对照你预期的树形。
- 解析类测试"没报错但结构不对"：收集式错误模型下，无错误 ≠ 正确。语法残留常构成
  另一条合法解析路径（例：限定名只吃前导 `\` 后，残留段被误当函数调用）。**断言
  用 tag 计数 / 结构关系，不要用"无错误"**。

### 2.2 覆盖矩阵

新增 `Node.Tag` 或词法种类后，忘记补用例会得到**编译期错误**（中文提示指明缺失的
种类）。规则：

- 矩阵条目顺序必须与 `Tag` 枚举声明顺序一致（编译期校验）。
- 新 tag 尽量用最小源码（一个 `expr_array_dim_fetch` 用 `$a['b'];` 而非大段代码）。

### 2.3 黄金快照

**机制**：`tests/golden/**/*.php` 解析后与同名 `*.txt` 逐字节比对；诊断也会写入快照，
所以"引入了新错误"同样会被比出来。

**何时更新**：解析行为有意变更（新增语法、修 bug 改变结构）后，快照会失败。此时：

```sh
zig build test -Dupdate-golden   # 重新生成
git diff tests/golden            # 复核：只应含预期的结构变化
```

**纪律**：不复核就更新，会让快照退化为"把错误结果固化下来"。若 diff 出现与本次改动
无关的大段变化，先查是不是解析器引入了意外行为。

**新增 fixture**：在 `tests/golden` 相应子目录放 `*.php`，跑一次 `-Dupdate-golden`
生成 `*.txt`，提交成对文件。

### 2.4 一致性对照（tools/parity_check）

`parity_check` 是独立于常规测试的**开发工具**（`zig build test` 不包含它）：以
PHP-Parser 的测试子集为基准（oracle），把代码段逐个喂给本解析器，度量两边是否一致。
术语与判定口径见工具头部注释；这里给使用工作流。

#### 2.4.1 数据与格式

- **数据源**：`tests/third_party/php-parser/test/code/parser`（178 个 `.test`，
  目录结构与上游一致；内容勿改，见 §1）。
- **`.test` 格式**：首行标题，之后以 `-----` 分隔的 (代码段, 期望段) 交替对。
  期望段以 `array(` 开头 = PHP-Parser 接受该代码；以错误说明开头 = 应报错。
  期望段首行的 `!!version=X.Y` 是版本 mode（该段在指定版本下解析），其余 mode 忽略。
- 代码段中的 `@@{expr}@@` 是 PHP-Parser 测试宏（eval 注入内容），工具会先展开再
  解析，读报告时无需理会。

#### 2.4.2 运行与输出

在**仓库根目录**运行（工具用相对路径读写数据源与报告）：

```sh
zig build check-parity --summary all        # 默认基准（库内 tests/third_party）
zig build check-parity -- <基准目录>        # 指定基准（某处 php-parser 的
                                             # test/code/parser 目录）
```

- 默认：基准 = 随库收录的 `tests/third_party/php-parser/test/code/parser`，报告写在
  **仓库根**（`acceptance_report.txt` / `diagnostic_report.txt`）。
- 指定基准目录：对照该目录（如对自定义/更新的 php-parser clone），报告写进**该目录**，
  便于与基准同处对照；用毕清理（勿把报告留在 `tests/third_party` 对照源里）。

工具本身恒通过（只报告不判定）。产物两份：

- `acceptance_report.txt` —— 接受面：头部统计后按两类列出差距：
  1. **误拒**（期望接受却有诊断）：本库该接受却没接受，逐条列出 `路径[段号]` +
     首个诊断。这是**要修**的清单。
  2. **漏报**（期望报错却无诊断）：PHP-Parser 报错但本库没报。这是**要人工核对**
     的清单——两种去向：属收集式错误模型的有意宽松（在 `doc/special.md` 错误模型节
     注明即可），或确属拒绝漏报（修复）。
- `tests/diagnostic_report.txt` —— 诊断质量：两边都报的段里，按 条数/文本/位置
  逐条比对的一致度与差异明细（每条附源码行、期望、实际），供逐条校准。

#### 2.4.3 从报告到修复

1. 打开 `tests/acceptance_report.txt`，先看头部统计确认没有整体漂移（如 `.test` 数
   不符，多半是数据源路径/拷贝问题）。
2. 取一条：`路径[段号]` 对应 `tests/third_party/php-parser/test/code/parser/路径`
   文件里的第 `段号` 个代码段（0 基）。**段号 ×2 +1** 即该段的期望段（可确认
   PHP-Parser 期望什么结构）。
3. 把该代码段复制成最小用例（拆到一两句），在 `src/` 建临时文件复现根因。修复后
   在该文件尾部补正式单元测试，并检查是否需要扩 golden（§2.3）。
4. **清理临时文件**：`dbg_*.zig` 等探针是调试手段，不属于库产物，改完即删。
5. 复跑 `zig build check-parity` 确认该条消失、没有新增同类别条目。
6. 诊断质量的差异逐条校准到全等（或登记为有意差异，见 §2.4.4）。

> 提示：修复要防"贪快"。逐点打补丁会让同类差距散落多处——先看若干条是否同一
> 根因（如某 token 未识别、某状态机漏状态），在底层一次性修，再复扫验证。

#### 2.4.4 与 PHP-Parser 的已知差异一览

对照 fixture 时，若同一代码段的 EXPECT 结构（PHP-Parser 的 dump）与我们的树不一致，
多数不是缺口，而是**有意的归一/布局差异**——接受/拒绝判定一致，只是表示方式不同。
下表速查这些差异；逐模式的完整说明见 `doc/special.md`。

| 差异点 | PHP-Parser | php-ast |
|---|---|---|
| 运算符 / 复合赋值 / 一元子类型 | 每运算符一个子类（`BinaryOp\Plus`、`AssignOp\Coalesce`…） | 统一 `expr_binary` / `expr_assign_op` / `expr_unary` / `expr_post_inc|dec`，运算符由 `main_token` 记录 |
| `elseif`/`else if`、`finally` | `ElseIf_`/`Else_`/`Finally_` 独立节点 | else 分支折叠为嵌套 `stmt_if`；`finally` 为普通语句块（PHP-Parser 的 `ElseIf_` 节点不产生） |
| `die()`、`include` 家族 | `Exit_`（die/exit 区分词）、`Include_`（kind 记四种） | `expr_exit` / `expr_include`，变体由 token 记录 |
| `exit(...)`、`clone(...)` 的括号形态（8.5） | 单参归 `Exit_`/`Clone_`，多参/命名归 `FuncCall` | 统一归一为 `FuncCall`（名字即 exit/clone）——接受一致，结构不同 |
| 名字 | `Name`/`FullyQualified`/`Relative`/`VarLikeIdentifier` 四类 | `name_*` 四 tag；关键字可作名字段（semi_reserved，PHP 同源文法） |
| `$$a` / `${expr}` | `Variable(name: expr)`（无独立类） | `expr_variable_ref`（name 为子节点）；`phpParserType` 同报 `Expr_Variable` |
| 修饰符 / 可见性 | 独立属性（`public`/`static`/`readonly`…），常量与 Zend 引擎对齐 | 紧凑 `flags` 位字段；非对称可见性 `public private(set)` 存高低字节 |
| 位置 / 注释 | 节点属性（`startLine`/`endLine`/`comments`…） | `main_token` 派生（compat 提供同名便捷函数）；注释驻 token 流，`getDocComment`/`leadingComments` 取回 |
| 错误 | 抛 `PhpParser\Error`，遇错即停（可选 recovery） | `tree.errors` 收集 + 尽力恢复——接受面报告的「漏报」多源于此 |
| 语言版本 | 无版本维度（lexer emulation 仅为在旧 PHP 上跑新语法） | 解析携带目标版本 + `tagVersion` 门控（8.5 管道 `expr_pipe` 等超前于 5.8，为独有语法） |
| 首类可调用 `...` | 整表占位 `FirstClassCallable`；实参内占位 `VariadicPlaceholder` | 前者 `expr_first_class_callable`，后者 `expr_variadic_placeholder`（叶） |
| 解构空槽 `[$a, , $b]` | `ArrayItem.value = null` | `expr_array_hole` 叶（槽位计数） |
| 替代语法 `if (x): … endif;` | `If_` 的 stmts 是普通 `Stmt_Block`（无 `{}` 语义差异） | 同样 `stmt_block`，借 `lbrace/rbrace` 槽存 `:`/end 关键字（打印器据此还原） |
| 标量 / 魔术常量 | 各字面量类 + `MagicConst*` 族 | `expr_int`/`float`/`string` 叶 + `expr_magic_const`（token 记种类） |

> 对照时的判断顺序：结构不同先查本表（命中 = 归一，非缺口）→ 未命中再当误拒
> 处理。注意本表是"表示差异"，与接受/拒绝无关；**拒绝面的差异**（本库该报错却没报）
> 归入接受面报告的「漏报」节核对，不在上表。

## 3. 调试方法

### 3.1 收集式错误定位

解析不抛异常：错误收集在 `tree.errors`。定位首个错误：

```zig
var buf: [128]u8 = undefined;
for (tree.errors) |e| {
    std.debug.print("@'{s}' {s}\n", .{ tree.tokenSlice(e.token), e.format(&tree, &buf) });
}
```

`e.token` 指向肇事 token，`tokenSlice` 可看该 token 文本。错误往往发生在"期望 X 却在
Y"的 Y 上，向前看几个 token 通常能还原现场。

### 3.2 解析器不变量（排查崩溃/卡死时先核对）

- **失败不消费**：解析函数失败返回 `null` 时，token 游标应回到进入时位置（必要时
  显式回卷）。残留游标会让上层错误恢复基于错误状态继续。
- **eof 是终点**：`nextToken` 在 eof 哨兵处停驻，任何"越 eof"的推进都是 bug 的
  症状（越界 panic 常见于此）。
- 修复同类问题时，先在底层找公共防线，而不是逐点打补丁。

### 3.3 看 AST 结构

`src/dump.zig` 提供树形文本渲染（缩进 + 主 token 文本），用于对比预期结构：

```zig
var buf: std.Io.Writer.Allocating = .init(gpa);
defer buf.deinit();
try dump.dumpTree(gpa, tree, &buf.writer);
std.debug.print("{s}", .{buf.written()});
```

### 3.4 最小复现

大 fixture 一次给出多个错误时，把输入逐段减到最小单句，逐个确认哪句触发。对照
`tests/third_party/php-parser/test/code/` 下同名 `.test` 的期望段，能确认"该不该接受"
与"接受后长什么样"。

## 4. 开发流程

### 4.1 常规改动

1. 弄清归属层：语义进 AST、语法降 token/字段（判据见 `doc/zen.md`）。新语法先查
   `doc/special.md`——能沿用既有归一（如 `die` 并入 `expr_exit`）就不要建新形态。
2. 实现 + 写单元测试（放被测文件尾部）。
3. `zig build test --summary all` 全绿；golden 受影响则更新并 `git diff` 复核。
4. 结构变化同步 `doc/zen.md`（特殊点表）与 `doc/special.md`（差异表）。

### 4.2 新增一个节点形态的核对清单

| 项                                              | 文件                             |
|-------------------------------------------------|----------------------------------|
| `Node.Tag` 枚举                                 | `src/ast.zig`                    |
| 有子节点则登记 `forEachChild`（叶子进"叶子组"） | `src/ast.zig`                    |
| 引入版本（非基础语法）                          | `src/ast.zig` `tagVersion`       |
| php-parser 风格类型名                           | `src/compat.zig` `phpParserType` |
| 覆盖矩阵用例（顺序同枚举）                      | `src/coverage.zig`               |
| 单元测试（文件尾部）                            | 对应 `src/*.zig`                 |
| golden（新语句族则扩 fixture）                  | `tests/golden/`                  |
| 折叠决策                                        | `doc/zen.md` 特殊点表            |
| 与 PHP-Parser 的差异                            | `doc/special.md`                 |

### 4.3 测试与注释风格

- 测试块**固定在源文件尾部**：文件末尾非空内容应是测试块的 `}`。
- 测试只断言必要性质；断言值若来自特殊构成（"变量共 3 个：左值 + 2 处插值"），
  注释写明，避免后人误改。
- 注释写"为什么"（取舍、隐含契约、踩过的坑），不写 What；仓库语言为中文。
