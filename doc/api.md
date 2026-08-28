# php-ast 公开 API 手册

本库以单模块 `php_ast` 暴露，调用方统一写作：

```zig
const php_ast = @import("php_ast");
```

各子模块以同名命名空间再导出，可按 `php_ast.ast` / `php_ast.walk` / `php_ast.token`
/ `php_ast.lexer` / `php_ast.version` 访问。`root.zig` 同时再导出顶层便捷别名
`php_ast.parse`、`php_ast.Ast`、`php_ast.PhpVersion`、`php_ast.Token`、`php_ast.Node`、`php_ast.Index`。

---

## 目录

1. [类型别名与核心结构](#1-类型别名与核心结构)
2. [顶层入口：parse](#2-顶层入口-parse)
3. [Ast：解析结果与访问 API](#3-ast-解析结果与访问-api)
4. [walk：树遍历与注释](#4-walk-树遍历与注释)
5. [token：词法单元](#5-token-词法单元)
6. [lexer：词法分析](#6-lexer-词法分析)
7. [version：PHP 版本谓词](#7-version-php-版本谓词)

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
| `php_ast.ByteOffset` | `u32` | 源码内绝对字节偏移。 |
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

**简介**：取某节点覆盖的**首/末 token 下标**。`root` 递归到首/末条语句；其余节点即其 `main_token`。
节点无需冗余存储首尾偏移，位置现算。

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

**简介**：枚举某节点的**全部直接子节点**，追加到 `out`。这是树遍历与「full 视图」重装的基石——
每个节点的所有直接子引用都在此显式给出（区间型子节点展开为列表，可选子节点含 `none` 判定）。
叶子节点（仅含主 token）不产生子节点。

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

## 5. token：词法单元

```zig
const php_ast.token = @import("token.zig");
```

### 类型

- `Token.Tag`：所有词法种类的扁平枚举（`eof` / `int_literal` / `kw_if` / `arrow` / `open_tag` …），与 PHP 官方 `zend_language_scanner` 对应。
- `Token.TokenList`：`std.MultiArrayList`，SoA 存 `tag`/`start`/`end` 三列。
- `Token.ByteOffset`：`usize`，源码绝对字节偏移。

### `Token.lexeme`

```zig
pub fn lexeme(tag: Tag) ?[]const u8
```

**简介**：返回某词法种类固定对应的字面文本（如 `Token.lexeme(.arrow) == "->"`）。仅对标点/运算符有效；
标识符、字面量需经 `Ast.tokenSlice` 从源码切片取得，故返回 `null`。

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

## 7. version：PHP 版本信息（非门控）

```zig
const php_ast.version = @import("version.zig");
```

> 本库在 AST 上记录每个节点的「引入版本」；并在 `parse` 时以 `version` 参数为目标版本，对引入版本更高的节点在 `ast.errors` 中追加 `unsupported_version` 错误（门控由调用方决定放/拒）。

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
