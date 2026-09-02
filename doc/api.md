# php-ast 公开 API 手册

本库以单模块 `php_ast` 暴露，调用方统一写作：

```zig
const php_ast = @import("php_ast");
```

各子模块以同名命名空间再导出，可按 `php_ast.ast` / `php_ast.walk` / `php_ast.project`
/ `php_ast.token` / `php_ast.lexer` / `php_ast.version` / `php_ast.dump` 访问。
`root.zig` 同时再导出顶层便捷别名 `php_ast.parse`、`php_ast.loadDir`、`php_ast.Ast`、
`php_ast.ProjectAst`、`php_ast.ParseError`、`php_ast.Node`、`php_ast.PhpVersion`、
`php_ast.Token`。其余类型（如 `Index`、`ByteOffset`）经 `php_ast.ast.Index` 等子模块路径访问。

---

## 目录

1. [类型别名与核心结构](#1-类型别名与核心结构)
2. [顶层入口：parse](#2-顶层入口-parse)
3. [Ast：解析结果与访问 API](#3-ast-解析结果与访问-api)
4. [walk：树遍历与注释](#4-walk-树遍历与注释)
5. [project：目录加载](#5-project-目录加载)
6. [token：词法单元](#6-token-词法单元)
7. [lexer：词法分析](#7-lexer-词法分析)
8. [version：PHP 版本谓词](#8-version-php-版本信息与门控)
9. [dump：AST 文本渲染](#9-dump-ast-文本渲染)

---

## 1. 类型别名与核心结构

| 类型 | 定义 | 说明 |
|---|---|---|
| `php_ast.Index` | `enum(u32)` | 节点句柄，即 `nodes` 数组下标；`root = 0` 为根。 |
| `php_ast.TokenIndex` | `u32` | token 在 `tokens` 中的下标。 |
| `php_ast.ExtraIndex` | `enum(u32)` | `extra_data` 大板中的下标，指向一段序列化负载起点。 |
| `php_ast.OptionalIndex` | `enum(u32)` | 可选节点下标，哨兵 `none`（最大 u32）表示「无」；`unwrap()` 得 `?Index`。 |
| `php_ast.OptionalTokenIndex` | `enum(u32)` | 可选 token 下标，同上；`unwrap()` 得 `?TokenIndex`。 |
| `php_ast.SubRange` | `{ start: ExtraIndex, end: ExtraIndex }` | `extra_data` 中的可选区间（可空）。 |
| `php_ast.ListRange` | `{ start: ExtraIndex, end: ExtraIndex }` | `extra_data` 中的节点列表区间。 |
| `php_ast.ast.ByteOffset` | `u32` | 源码内绝对字节偏移（token 起止用，见 token 章节的 `Token.ByteOffset = usize` 之差异）。 |
| `php_ast.Node` | struct | 单个 AST 节点：`{ tag, main_token, data }`，`tag` 由 `Node.Tag` 枚举穷举。 |
| `php_ast.Error` | struct | 一条诊断：`{ tag: Error.Tag, token: TokenIndex, required: PhpVersion }`。`required` 仅 `unsupported_version` 有意义，为该节点语法要求的 PHP 版本。 |
| `php_ast.Ast` | struct | 整棵解析结果（见第 3 节）。 |
| `php_ast.Location` | struct | `tokenLocation` 的返回：`{ line, column, line_start, line_end }`。 |

**可选下标的读取模式**：

```zig
const opt = tree.nodeData(node).opt_node;     // OptionalIndex
if (opt.unwrap()) |child| {
    // child 是 php_ast.Index
}
```

---

## 2. 顶层入口：parse

```zig
pub fn parse(
    gpa: std.mem.Allocator,
    source: [:0]const u8,
    version: PhpVersion,
) ParseError!Ast
```

**简介**：解析入口。内部依次执行词法（`Lexer.tokenize`）与递归下降解析，返回拥有所有权的
`Ast`。`gpa` 由调用方提供，`version` 为目标版本：解析时若某节点引入版本高于 `version`，会在 `ast.errors` 中追加 `unsupported_version` 错误（下游可据此拒绝或容忍）。
`ParseError == std.mem.Allocator.Error`，仅在内存不足时失败。用毕务必调用 `Ast.deinit`。

**示例**：

```zig
const php_ast = @import("php_ast");
const std = @import("std");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    const tree = try php_ast.parse(alloc, "<?php $a = 1;", .{ .id = 80400 });
    defer tree.deinit(alloc);

    for (tree.rootStmts()) |stmt| {
        std.debug.print("顶层语句: {}\n", .{tree.nodeTag(stmt)});
    }
}
```

> 版本也可写作 `php_ast.PhpVersion.fromComponents(8, 4)`（见第 7 节），语义等价。

---

## 3. Ast：解析结果与访问 API

`Ast` 是 SoA（结构体数组）扁平布局：`tokens` 与 `nodes` 分离存，节点间用 `Index` 互相引用，
超过 2 个直接子节点的负载序列化进 `extra_data`。所有位置信息现算，不冗余存储。

### 3.1 生命周期

#### `deinit`

```zig
pub fn deinit(tree: *Ast, gpa: std.mem.Allocator) void
```

**简介**：释放 `tokens`、`nodes`、`extra_data`、`errors` 占用内存。必须传入与 `parse` 相同的 `gpa`，
调用后 `tree` 置为 `undefined`。

```zig
defer tree.deinit(alloc); // 与 parse 的 alloc 一致
```

### 3.2 Token 访问

#### `tokenTag` / `tokenStart` / `tokenEnd`

```zig
pub fn tokenTag(tree: *const Ast, token_index: TokenIndex) Token.Tag
pub fn tokenStart(tree: *const Ast, token_index: TokenIndex) ByteOffset
pub fn tokenEnd(tree: *const Ast, token_index: TokenIndex) ByteOffset
```

**简介**：分别取某个 token 的**种类**、**起始字节偏移**、**结束字节偏移（开区间）**。

#### `tokenSlice`

```zig
pub fn tokenSlice(tree: Ast, token_index: TokenIndex) []const u8
```

**简介**：零拷贝取该 token 对应的源码文本（由 `tokenStart`/`tokenEnd` 回源切片）。

```zig
const tk = tree.nodeMainToken(node);
std.debug.print("主 token 文本: '{s}'\n", .{tree.tokenSlice(tk)});
```

#### `tokenLocation`

```zig
pub fn tokenLocation(tree: Ast, start_offset: ByteOffset, token_index: TokenIndex) Location
```

**简介**：计算某 token 在源码中的**行/列位置**。从 `start_offset` 起扫描换行定位行号与行起止，
再算出列号。位置按需派生，不冗余存储。

```zig
const loc = tree.tokenLocation(0, tree.nodeMainToken(node));
std.debug.print("第 {} 行, 第 {} 列\n", .{loc.line + 1, loc.column + 1});
```

### 3.3 节点访问

#### `nodeTag` / `nodeMainToken` / `nodeData`

```zig
pub fn nodeTag(tree: *const Ast, node: Index) Node.Tag
pub fn nodeMainToken(tree: *const Ast, node: Index) TokenIndex
pub fn nodeData(tree: *const Ast, node: Index) Node.Data
```

**简介**：取节点的**种类**、**主 token 下标**（派生位置）、**data 小联合**（最多承载 2 个直接子引用）。
`nodeData` 返回 `Node.Data`，按节点种类用 `.node_and_node` / `.opt_node` / `.extra_range` 等字段取出子引用。

#### `extraData` / `extraDataSlice` / `listSlice`

```zig
pub fn extraData(tree: Ast, index: ExtraIndex, comptime T: type) T
pub fn extraDataSlice(tree: Ast, range: SubRange, comptime T: type) []const T
pub fn listSlice(tree: Ast, range: ListRange, comptime T: type) []const T
```

**简介**：
- `extraData`：按字段顺序从 `extra_data[index]` 反序列化一段 `Components` 负载（如 `ClassConstComponents`），
  字段类型为 `Index/OptionalIndex/Token/ExtraIndex/u32/bool/SubRange`，调用方**无需手写偏移**。
- `extraDataSlice` / `listSlice`：把 `extra_data` 的一段区间重解释为 `T` 切片（元素均为 `u32` 大小）。

```zig
// 取函数声明体的子节点（Components 模式，伪代码示意真实字段名）
const c = tree.extraData(tree.nodeData(func).extra_and_opt_node[0], FunctionComponents);
for (tree.listSlice(c.params, Index)) |param| { /* ... */ }

// 取根节点下的全部顶层语句
const stmts = tree.rootStmts(); // 等价于 extraDataSlice(nodeData(root).extra_range, Index)
```

#### `rootStmts`

```zig
pub fn rootStmts(tree: Ast) []const Index
```

**简介**：取根节点下的**顶层语句列表**（直接遍历入口）。

#### `firstToken` / `lastToken`

```zig
pub fn firstToken(tree: Ast, node: Index) TokenIndex
pub fn lastToken(tree: Ast, node: Index) TokenIndex
```

**简介**：取某节点覆盖的**首/末 token 下标**（含其全部后代），`root` 委托到首/末条顶层语句。
注意 `main_token` 只是节点的**代表性** token（如二元运算的运算符），并非起始位置；本组函数
沿子节点递归取最小/最大值，得到真正的区间：

```zig
// <?php $a = 1 + 2;
const bin = /* expr_binary 节点 */;
tree.tokenSlice(tree.firstToken(bin)); // "1" —— 非主 token "+"
tree.tokenSlice(tree.lastToken(bin));  // "2"
```

尾部定界符（`;`、`}`）不是任何节点的子节点，由 `trailingDelimiter` 单独并入，因此各类
语句的区间都含其结尾分号。未收录者（叶子表达式、以冒号收尾的 `case`/`default`/标签）返回 `null`。

#### `forEachChild`

```zig
pub fn forEachChild(
    tree: Ast,
    node: Index,
    ctx: anytype,
    comptime onChild: fn (@TypeOf(ctx), Index) anyerror!void,
) !void
```

**简介**：遍历 `node` 的全部直接子节点，逐个交给 `onChild`。这是「某节点的直接子引用有哪些」
的唯一事实来源（`walk`、`firstToken`、`lastToken` 均构建于其上）。采用访问者而非返回切片，
以做到**零分配**。叶子节点不产生任何子节点。

#### `trailingDelimiter`

```zig
pub fn trailingDelimiter(tree: Ast, node: Index) ?TokenIndex
```

**简介**：取节点的尾部定界符 token（分号、右花括号等），无则 `null`。定界符不是子节点，
故不计入 `forEachChild`；要让 `lastToken` 覆盖完整源码区间必须单独取回。

#### `nameToken`

```zig
pub fn nameToken(tree: Ast, node: Index) ?TokenIndex
```

**简介**：取节点的**名字 token**（函数名、类名、属性名、常量名、case 名、参数名、被适配的方法名等），
无则 `null`。名字是 token 而非子节点，故不出现在 `forEachChild` 里。

注意声明类节点的 `main_token` 往往是关键字（`function`/`class`/`enum`），只靠它取不到名字：
`nameToken` 才返回真正的名字。属性的名字 token 含 `$` 前缀（与源码一致）。

```zig
const f = /* stmt_function 节点 */;
tree.tokenSlice(tree.nodeMainToken(f)); // "function"
tree.tokenSlice(tree.nameToken(f).?);   // "foo"
```

### 3.4 注释与 docblock

#### `docCommentBefore`

```zig
pub fn docCommentBefore(tree: Ast, node: Index) ?TokenIndex
```

**简介**：取紧贴 `node` 之前、仅被注释隔开的 **docblock token 下标**（若有）。注释始终作为 token 保留，
下游按需向前扫描取回，节点结构保持清爽。

```zig
if (tree.docCommentBefore(node)) |doc| {
    std.debug.print("文档注释: {s}\n", .{tree.tokenSlice(doc)});
}
```

### 3.5 错误诊断

`Ast.errors` 字段是 `[]const Error`，收集解析期间的全部诊断（多错误收集，不立即中止）。
`Error.Tag` 枚举涵盖 `expected_token` / `expected_semi` / `expected_expr` / `unexpected_eof` / `lex_error` / `unsupported_version` 等。

`Error` 自带 `format(tree, buf)` 方法，把错误渲染成可读文案：对 `unsupported_version`
会写明「该语法要求的版本」与「`parse` 指定的目标版本」，下游据此即可定位用错了哪一版语法；
其余错误仅给出 `Tag` 名。`buf` 由调用方提供，返回其有效切片。

```zig
if (tree.errors.len > 0) {
    var buf: [128]u8 = undefined;
    for (tree.errors) |e| {
        const msg = e.format(&tree, &buf);
        std.debug.print("解析错误 {s}\n", .{msg});
    }
}
```

---

## 4. walk：树遍历与注释

### `childNodes`

```zig
pub fn childNodes(
    gpa: std.mem.Allocator,
    tree: ast.Ast,
    node: Index,
    out: *std.ArrayList(Index),
) !void
```

**简介**：枚举某节点的**全部直接子节点**，追加到 `out`。子节点关系定义在 `Ast.forEachChild`，
此处仅适配为「收集到 ArrayList」的形态，供需要物化子节点列表的场合使用；不需物化时直接用
`forEachChild` 可免分配。叶子节点（仅含主 token）不产生子节点。

### `walk`

```zig
pub fn walk(
    tree: ast.Ast,
    start: Index,
    allocator: std.mem.Allocator,
    ctx: anytype,
    comptime visit: fn (@TypeOf(ctx), ast.Ast, Index) anyerror!void,
) !void
```

**简介**：从 `start` 出发**深度优先前序遍历**整棵树，对每个访问到的节点调用 `visit(ctx, tree, node)`。
`allocator` 仅用于遍历期间的临时栈。`ctx` 为任意上下文（计数器、收集器等），`visit` 为 comptime 函数。

```zig
var count: usize = 0;
try php_ast.walk.walk(tree, tree.root, alloc, &count, struct {
    fn f(c: *usize, _: php_ast.Ast, _: php_ast.Index) !void { c.* += 1; }
}.f);
std.debug.print("节点总数: {}\n", .{count});
```

### `WalkState` / `walkStack`（复用缓冲变体）

`walk` 简洁但**每个节点都会新建一份子节点 `ArrayList`**，整树遍历即产生 O(N) 次分配、触发分配器压力。
若需对同一进程中的多棵树反复遍历，或对单棵大树做多轮遍历（如先统计再改写），应使用复用缓冲的变体：

```zig
pub const WalkState = struct {
    fn init(allocator: std.mem.Allocator) !WalkState
    fn deinit(self: *WalkState) void
};

pub fn walkStack(
    tree: ast.Ast,
    start: Index,
    state: *WalkState,
    ctx: anytype,
    comptime visit: fn (@TypeOf(ctx), ast.Ast, Index) anyerror!void,
) !void
```

**简介**：`WalkState` 预先持有「栈」与「子节点 scratch 缓冲」，整次遍历只分配一次（预热后零分配）。
`walkStack` 语义与 `walk` **完全一致**（前序、栈内逆序压栈），仅把缓冲持有权交给调用方。

```zig
var ws = try php_ast.walk.WalkState.init(alloc);
defer ws.deinit();
var count: usize = 0;
try php_ast.walk.walkStack(tree, tree.root, &ws, &count, struct {
    fn f(c: *usize, _: php_ast.Ast, _: php_ast.Index) !void { c.* += 1; }
}.f);
// 同一 ws 可继续用于下一棵树 / 下一轮遍历，缓冲被复用，不再每节点分配
```

> 何时选哪个：`walk` 适合一次性、偶尔的遍历（代码最短）；`walkStack` 适合热路径、批量遍历或性能敏感场景。

### `leadingComments` / `trailingComments`

```zig
pub fn leadingComments(gpa: std.mem.Allocator, tree: ast.Ast, node: Index, out: *std.ArrayList(TokenIndex)) !void
pub fn trailingComments(gpa: std.mem.Allocator, tree: ast.Ast, node: Index, out: *std.ArrayList(TokenIndex)) !void
```

**简介**：取紧贴 `node` **之前/之后**、仅被注释或文档注释隔开的 token 列表（按源码顺序）。
用于在遍历时还原 `leading_comments` / `trailing_comments`（节点本身不冗余存储）。

```zig
var comments: std.ArrayList(php_ast.TokenIndex) = .empty;
try php_ast.walk.leadingComments(alloc, tree, node, &comments);
for (comments.items) |c| { /* tree.tokenSlice(c) */ }
```

---

## 5. project：目录加载

```zig
const php_ast.project = @import("project.zig");
```

### `loadDir`

```zig
pub fn loadDir(
    gpa: std.mem.Allocator,
    io: std.Io,
    dir_path: []const u8,
    version: PhpVersion,
) !ProjectAst
```

**简介**：扫描 `dir_path` 目录（递归），解析其中全部 `.php` 文件（跳过其他类型），
返回多文件 AST 森林 `ProjectAst`。`version` 统一应用于全部文件。

`io` 为 Zig 0.16 显式 I/O 上下文：测试传 `std.testing.io`；生产代码经
`std.Io.Threaded.init(...).io()` 等获得。失败仅因 IO（目录不存在/读文件失败）或内存不足；
单个文件的**语法**错误不中断，收集进对应 `Ast.errors`。用毕务必调用 `ProjectAst.deinit`。

**设计要点**：
- **森林而非大树**：每文件一棵 `Ast`，文件边界天然保留（不合并节点索引，避免
  对全部 `data` 引用做索引重映射）。
- **文件排序**：按路径字典序解析存储，输出确定、可复现。
- **源码自有**：`loadDir` 从文件读出源码（`[:0]const u8`），`ProjectAst` 拥有每文件
  源码与路径，`deinit` 统一释放。

```zig
var project = try php_ast.loadDir(gpa, std.testing.io, "src/", php_ast.PhpVersion.fromComponents(8, 5));
defer project.deinit(gpa);
for (project.rootStmts()) |top| {
    // top.file 为文件下标，top.stmt 为该文件内顶层语句节点
}
```

### `ProjectAst`

多文件 AST 森林 + 跨文件顶层语句视图。

```zig
pub fn deinit(self: *ProjectAst, gpa: std.mem.Allocator) void  // 释放全部文件与视图
pub fn fileCount(self: ProjectAst) usize                      // 文件数
pub fn fileAt(self: ProjectAst, i: usize) ProjectFile         // 取文件（path/source/ast）
pub fn filePath(self: ProjectAst, i: usize) []const u8         // 相对 root_path 的路径
pub fn fileAst(self: ProjectAst, i: usize) *const Ast          // 取文件 AST
pub fn rootStmts(self: ProjectAst) []const TopStmt             // 跨文件顶层语句视图
```

`TopStmt` 为 `{ file: usize, stmt: ast.Index }`：`file` 定位文件，`stmt` 为该文件内顶层
语句节点。配合 `fileAst` 即可在整包分析中按文件定位任意节点。

---

## 6. token：词法单元

```zig
const php_ast.token = @import("token.zig");
```

### 类型

- `Token.Tag`：所有词法种类的扁平枚举（`eof` / `int_literal` / `kw_if` / `arrow` / `open_tag` …），与 PHP 官方 `zend_language_scanner` 对应。
- `Token.TokenList`：`std.MultiArrayList`，SoA 存 `tag`/`start`/`end` 三列。
- `Token.ByteOffset`：`usize`，源码绝对字节偏移。注意与 `ast.ByteOffset`（`u32`）的区别：
  `Token.ByteOffset` 用于 token 流自身的下标换算（`MultiArrayList` 存取），`ast.ByteOffset`
  用于 `Ast.tokenStart`/`tokenEnd` 的返回类型。

### `Token.keywords` / `Token.operators`（表）

```zig
pub const keywords: [N]Mapping   // 关键字文本 → Tag，如 "if" → .kw_if
pub const operators: [M]Mapping  // 运算符/标点文本 → Tag，如 "===" → .equal_equal_equal
```

**简介**：关键字与运算符的**单点维护表**。词法器、`keywordTag`/`opTag`、`lexeme`、以及测试的
词法覆盖矩阵均读这两张表——新增关键字或运算符只改这一处，其余自动生效。

`operators` 按文本长度从长到短排列（顺序有语义：多字符运算符必须优先于单字符，如 `==` 先于 `=`）。

#### `keywordTag` / `opTag`

```zig
pub fn keywordTag(t: []const u8) ?Tag
pub fn opTag(t: []const u8) ?Tag
```

**简介**：把文本映射到对应 `Tag`，无法识别返回 `null`。`opTag` 按 `operators` 顺序匹配，
多字符自然优先。供词法器与需要「文本 ↔ 种类」互查的下游使用。

### `Token.lexeme`

```zig
pub fn lexeme(tag: Tag) ?[]const u8
```

**简介**：返回某词法种类固定对应的字面文本（如 `Token.lexeme(.arrow) == "->"`）。仅对标点/运算符有效；
标识符、字面量需经 `Ast.tokenSlice` 从源码切片取得，故返回 `null`。由 `operators` 反查，不另存一份映射。

```zig
try std.testing.expect(std.mem.eql(u8, php_ast.token.Token.lexeme(.double_colon).?, "::"));
```

### `Token.isComment`

```zig
pub fn isComment(tag: Tag) bool
```

**简介**：判断某种类是否为注释（`.comment` 或 `.doc_comment`）。注释不进节点，但作为 token 保留在 `Ast.tokens`。

```zig
if (php_ast.token.Token.isComment(tree.tokenTag(i))) { /* 是注释 */ }
```

---

## 6. lexer：词法分析

```zig
const php_ast.lexer = @import("lexer.zig");
```

### `Lexer.tokenize`

```zig
pub fn tokenize(
    gpa: std.mem.Allocator,
    source: [:0]const u8,
    out: *Token.TokenList,
) std.mem.Allocator.Error!void
```

**简介**：手写扫描器，把源码分词并追加到 `out`。要点：
- 开标签 `<?php` 需精确匹配后接空白/换行；`<?=` 单独成开标签；不匹配的 `<?` 视为普通文本跳过。
- 注释（含 docblock）一律作为 token 保留，不丢弃。
- 字符串插值：双引号与 heredoc 进入字面量累积模式，把 `$var` / `{$expr}` 切成可被解析器还原为表达式的 token；nowdoc 关闭插值。
- 无法归类的字符产出 `.invalid` token 并继续，错误交由解析器收集上报，不崩溃。
- 末尾补 `.eof` 哨兵。

> 通常无需直接调用——`parse` 已内部包含词法。仅在需要单独分析 token 流时调用。

```zig
var tokens = php_ast.token.Token.TokenList{};
try php_ast.lexer.Lexer.tokenize(alloc, "<?php $a;", &tokens);
defer tokens.deinit(alloc);
for (tokens.items(.tag)) |tag| { /* ... */ }
```

---

## 7. version：PHP 版本信息与门控

```zig
const php_ast.version = @import("version.zig");
```

> 本库在 AST 上记录每个节点的「引入版本」；并在 `parse` 时以 `version` 参数为目标版本，对引入版本更高的节点在 `ast.errors` 中追加 `unsupported_version` 错误（放行或拒绝由调用方决定）。

### `PhpVersion`

```zig
pub const PhpVersion = struct { id: u32 };
pub const BASE_VERSION: PhpVersion = .{ .id = 0 }; // 基础语法 / 无版本信息
```

版本号以 `major * 10000 + minor * 100` 编码（如 8.4 → `80400`），便于比较。`BASE_VERSION`（id=0）表示基础语法（PHP 8.1 以前）。

#### `fromComponents`

```zig
pub fn fromComponents(major: u16, minor: u16) PhpVersion
```

**简介**：由主、次版本号构造，如 `fromComponents(8, 4)` 表示 PHP 8.4。

#### `newerOrEqual`

```zig
pub fn newerOrEqual(self: PhpVersion, other: PhpVersion) bool
```

**简介**：判断 `self` 是否不早于 `other`（同版本或更新）。

### `Ast.nodeVersion`（逐节点版本信息）

```zig
pub fn nodeVersion(tree: *const Ast, node: Index) PhpVersion
```

**简介**：返回 `node` 的「引入版本」。`id == 0`（`BASE_VERSION`）表示基础语法、未单独记录；8.1 及以后引入的节点记录对应版本。与「节点结构无关」的差异（如 `new` 的无括号形式 8.4、`(void)` 强转 / `clone` 函数式 / 常量注解 / `final` 属性提升等 8.5 项）已在解析点覆盖。

```zig
for (tree.nodes.items(.tag), 0..) |tag, i| {
    const v = tree.nodeVersion(@enumFromInt(i));
    // v.id == 0 为基础语法；否则为引入版本号（如 80100 = 8.1）
}
```

> `parse` 的 `version` 参数作为目标版本：解析时若某节点引入版本高于 `version`，会在 `ast.errors` 中追加 `unsupported_version` 错误（错误携带 `required` 字段与 `format` 文案，由调用方决定放/拒）；是否真正拒绝由调用方结合 `nodeVersion` 完成。

### `tagVersion`（节点种类 → 引入版本）

```zig
pub fn tagVersion(tag: Node.Tag) PhpVersion
```

**简介**：查某节点**种类**的「引入版本」——即该语法首次出现的 PHP 版本（基础语法返回
`BASE_VERSION`/id=0）。与 `Ast.nodeVersion`（逐节点实例）的区别：本函数只按种类查，不需要
解析结果，适合在 AST 之外做静态判定。

```zig
php_ast.ast.tagVersion(.stmt_enum).id   // 80100（enum 为 8.1 引入）
php_ast.ast.tagVersion(.expr_pipe).id   // 80500（管道为 8.5 引入）
```

---

## 最小可运行示例（汇总）

```zig
const php_ast = @import("php_ast");
const std = @import("std");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    const src = "<?php\n/** 文档注释 */\nfunction add($a, $b) { return $a + $b; }";
    const tree = try php_ast.parse(alloc, src, php_ast.PhpVersion.fromComponents(8, 4));
    defer tree.deinit(alloc);

    // 报告解析错误（format 会为版本门控错误给出可读文案）
    var buf: [128]u8 = undefined;
    for (tree.errors) |e| std.debug.print("ERR {s}\n", .{e.format(&tree, &buf)});

    // 遍历所有节点
    var n: usize = 0;
    try php_ast.walk.walk(tree, tree.root, alloc, &n, struct {
        fn f(c: *usize, _: php_ast.Ast, _: php_ast.Index) !void { c.* += 1; }
    }.f);
    std.debug.print("共 {} 个节点\n", .{n});

    // 取 docblock
    const first = tree.rootStmts()[0];
    if (tree.docCommentBefore(first)) |doc| {
        std.debug.print("doc: {s}\n", .{tree.tokenSlice(doc)});
    }
}
```

---

## 8. dump：AST 文本渲染

```zig
const php_ast.dump = @import("dump.zig");
```

把 AST 渲染为可读的缩进文本，用于**调试**与**黄金快照比对**（`tests/golden/`）。

```text
(root `<?php`
  (stmt_expression `=`
    (expr_assign `=`
      (expr_variable `$a`)
      (expr_int `1`)
    )
  )
)
```

每个节点一行，缩进表示深度，反引号内是该节点覆盖的源码文本（限定名取完整区间如
`Foo\Bar`，其余取主 token；声明节点额外打印 `name=` 名字）。特殊字符（换行等）被转义，
保证「一节点一行」。

#### `dumpTree`

```zig
pub fn dumpTree(gpa: std.mem.Allocator, tree: ast.Ast, w: anytype) !void
```

**简介**：从 `tree.root` 渲染整棵树到 writer `w`。

#### `dumpNode`

```zig
pub fn dumpNode(gpa: std.mem.Allocator, tree: ast.Ast, node: Index, depth: usize, w: anytype) !void
```

**简介**：渲染以 `node` 为根的子树，`depth` 为起始缩进层级。

```zig
var buf: std.Io.Writer.Allocating = .init(alloc);
defer buf.deinit();
try php_ast.dump.dumpTree(alloc, tree, &buf.writer);
std.debug.print("{s}", .{buf.written()});
```
