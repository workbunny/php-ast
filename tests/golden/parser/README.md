# parser 快照

本目录的 `*.php` 由 `zig build golden-gen` 从 PHP-Parser 的测试用例
（`test/code/parser/**`）导出，同名 `*.txt` 是解析结果快照（含诊断），
由 `zig build test -Dupdate-golden` 生成并逐字节比对。

- 来源与许可见仓库根 [`NOTICE.md`](../../../NOTICE.md) 与
  [`LICENSES/php-parser.txt`](../../../LICENSES/php-parser.txt)（BSD 3-Clause）。
- 不要手工编辑 `*.php`：重新运行 `golden-gen` 会覆盖。
- `*.txt` 的更新必须复核 `git diff`，确认结构变化符合预期。
