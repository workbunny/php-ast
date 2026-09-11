# 第三方内容声明

本仓库对第三方来源内容保留其原许可与版权声明，清单如下。

## PHP-Parser

- 项目：PHP-Parser（5.8.0），https://github.com/nikic/PHP-Parser
- 版权：Copyright (c) 2011, Nikita Popov
- 许可：BSD 3-Clause，全文见 [`LICENSES/php-parser.txt`](LICENSES/php-parser.txt)
- 涉及内容：`tests/golden/parser/**` 下的 PHP 源码及其解析快照 `*.txt`，衍生自
  PHP-Parser 的测试用例（`test/code/parser/**`）。

PHP-Parser 在本项目中仅作为开发期的行为对照基准（`zig build conformance`）与
快照来源（`zig build golden-gen`）；本库不包含其运行时代码。其项目名与版权人
仅用于客观标注出处，不代表对本库的认可或背书。
