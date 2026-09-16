# Changelog

php-ast 的显著变更记录。格式参考 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)，
版本号遵循 `MAJOR.MINOR.PATCH`；0.x 阶段 z / y 的承诺见 [`doc/compat.md`](doc/compat.md)。

## [Unreleased]

## [0.6.2] - 2026-09-16

### 新增

- `doc/dev.md` 第 5 节「`extra_data` 契约」：写/读两侧的接口一览（签名与适用范围）、六条契约、
  覆盖纪律（按**路径**而非 tag 判定）与禁止项（不得为某个 tag 假设槽数或子节点数）。
- `doc/api.md` 的下游取用纪律：区间左闭右开、空区间语义、`T` 须与产生该段的 `Components`
  一致，并说明写入侧不在导出面内。

### 变更

- `extra_data` 的字段类型白名单收敛为**单一来源**：`ast.encodeExtraField` / `ast.decodeExtraField`
  / `ast.extraFieldSlots`，`Parser.addExtra` 与 `Ast.extraData` 共用一处（原先写读各有一份同构分派）。
- 新增通用写入口 `Parser.addIndexList`（元素为 `u32` 宽句柄枚举），`addNodeList` 转发给它；
  闭包 `use` 列表改经它写入，不再手写大板下标。
- 绕过封装直接读写 `extra_data` 下标的位置全部收敛到统一入口（写侧 3 处、读侧 2 处）。
- 单元测试补充：属性组空组 `#[]` 的零长列表区间构造路径。

### 破坏性变更

无。`ast` 命名空间下新增的三个字段编解码函数与 `Parser.addIndexList` 均为纯新增；
解析输出与既有快照逐字节一致，用例数 230 → 231 全绿。

## [0.6.1] - 2026-09-16

### 新增

- 内存 / 分配测量工具 `tools/measure.zig`，经 `zig build measure` 运行：报告每个输入的
  分配次数、累计分配字节、峰值驻留与解析后驻留（`峰值 − 驻留 ≈ 解析期临时缓冲`）。
- CI 流水线 `.github/workflows/ci.yml`：格式校验、单元测试 + 黄金快照、符合性门禁三个
  job；Zig 由 `.github/actions/setup-zig` 以官方发行包 + sha256 校验安装。
- `.gitattributes`：行尾钉死 LF（`* text=auto eol=lf`，优先级高于 `core.autocrlf`），
  消除平台检出与 `zig fmt` 之间的行尾差异。
- 手写黄金快照 `tests/golden/decl/keyword_case.*`（关键字在各名字位的接受面）与
  `tests/golden/stmt/recovery.*`（列表型恢复的边界形态）。
- `Token.keywordSince` 与 `Token.Mapping.since`：关键字的生效版本。新增字段带默认值
  （`since: u32 = 0`），既有的结构体构造写法不受影响。
- `doc/compat.md`：版本兼容性承诺，含 0.x 阶段 z / y 的语义与破坏性变更的记录方式。

### 修复

- 声明名位的保留关键字判定改为按 `Token.keywords` 全集（减去目标版本尚未生效者）统一
  推导，原先只覆盖 `static` 与 `readonly`；`class list {}`、`use C as if;` 等现在正确报错。
- 关键字大小写不敏感改在词法阶段落实：`ReadOnly` 与 `readonly` 切成同一 tag，诊断显示名
  不再回判源码文本。
- `enum` / `readonly` 的生效版本（PHP 8.1）计入判定，目标版本为 8.0 时它们仍可作名字。
- `.gitattributes` 为 `tests/golden/**` 补 `-text`：语料是逐字节契约，`scalar/docStringNewlines`
  等 fixture 故意混用 CRLF/LF，此前被 `* text=auto eol=lf` 在检出时归一化，导致 CI 快照不匹配。

### 变更

- 全库经 `zig fmt` 格式化；CI 以 `zig fmt --check` 强制校验，格式化仍在本地执行。
- `tools/known_diffs.txt` 的白名单条目与成因说明、`baseline` 随诊断变化同步维护。
- 文档同步：`README.md` 补 CI 徽章与 `tools/` 工具说明，`doc/dev.md` 补内存测量章节，
  `doc/example.md` 随格式化与示例口径更新。

### 破坏性变更

无。公开导出面（`src/root.zig`）未变，`Node.Tag` / `Token.Tag` 成员数不变，唯一签名变化
的内部函数不在导出面内。

## 归档

本文件自 0.6.1 起建立，更早版本只保留版本号与日期，未逐条记录：

| 版本 | 日期 | 说明 |
|---|---|---|
| 0.6.0 | 2026-09-11 | 最近一次发布 |
| 0.6.0 之前 | 2026-08-27 ~ 2026-09-07 | 开发期提交，未标注版本号 |
