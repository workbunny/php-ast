# PHP-Parser 测试参照物（third_party）

本目录收录 [PHP-Parser](https://github.com/nikic/PHP-Parser) **5.8.0** 的测试与文法
参照物，作为本库一致性对照的基准（oracle）：`tools/parity_check.zig` 读取
`test/code/parser` 度量本库的接受面与诊断质量（`zig build check-parity`），并供人工
核对。

## 收录内容（最小子集）

- `test/code/` —— parser 与 name 解析器共 281 个 `.test` 对照 fixture
- `grammar/php.y` —— 权威语法规则（bison 文法）
- `LICENSE` —— 原库 BSD 3-Clause 许可证原文

## 版权与合规

- 上述文件为 **PHP-Parser 原样复制**，版权归原作者 Nikita Popov 及贡献者，
  依 **BSD 3-Clause** 协议随本库再分发，许可原文见 `LICENSE`。
- 本库 `src/` 内嵌测试与 `tests/golden/` 中**部分用例内容衍生自**上述 `.test`
  的 PHP 代码段（用于验证接受/拒绝与结构），同样保留原版权声明，特此注明。
