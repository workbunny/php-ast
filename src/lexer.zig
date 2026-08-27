const std = @import("std");
const Token = @import("token.zig").Token;

/// 手写词法分析器。
///
/// 为什么自己写而不复用现成 tokenizer：PHP 没有 Zig 那样可用的语言内
/// tokenizer，而本库要贴合 PHP 的边界语义（开/闭标签、heredoc、字符串插值等），
/// 因此手写一个显式、可读的扫描器，符合 Zig 禅「偏好读代码胜过写代码」。
///
/// 产出：一个 `Token.TokenList`，每个 token 只存 `tag + 起止偏移`（零拷贝，
/// 文本回源取得），并在末尾补一个 `eof` 哨兵。注释（含 docblock）作为 token
/// 保留，不丢弃——这是本库对「PHP 运行期语义」的刻意偏离（见 `Ast.docCommentBefore`）。
pub const Lexer = struct {
    /// 判断某个字符是否可组成标识符/PHP 变量名（字母、数字、下划线、横杠）。
    fn isIdentChar(c: u8) bool {
        return switch (c) {
            'a'...'z', 'A'...'Z', '0'...'9', '_' => true,
            else => false,
        };
    }

    /// 判断某个字符是否为十进制数字。
    fn isDigitChar(c: u8) bool {
        return c >= '0' and c <= '9';
    }

    /// 把关键字文本映射到对应的 `Tag`，非关键字返回 `null`。
    ///
    /// 单点维护 PHP 关键字表；8.x 新增关键字在此集中添加。
    fn keywordTag(t: []const u8) ?Token.Tag {
        const kw = struct {
            t: []const u8,
            tag: Token.Tag,
        };
        const list = [_]kw{
            .{ .t = "if", .tag = .kw_if },
            .{ .t = "else", .tag = .kw_else },
            .{ .t = "elseif", .tag = .kw_elseif },
            .{ .t = "while", .tag = .kw_while },
            .{ .t = "for", .tag = .kw_for },
            .{ .t = "foreach", .tag = .kw_foreach },
            .{ .t = "as", .tag = .kw_as },
            .{ .t = "function", .tag = .kw_function },
            .{ .t = "class", .tag = .kw_class },
            .{ .t = "extends", .tag = .kw_extends },
            .{ .t = "implements", .tag = .kw_implements },
            .{ .t = "return", .tag = .kw_return },
            .{ .t = "echo", .tag = .kw_echo },
            .{ .t = "namespace", .tag = .kw_namespace },
            .{ .t = "new", .tag = .kw_new },
            .{ .t = "true", .tag = .kw_true },
            .{ .t = "false", .tag = .kw_false },
            .{ .t = "null", .tag = .kw_null },
            .{ .t = "public", .tag = .kw_public },
            .{ .t = "protected", .tag = .kw_protected },
            .{ .t = "private", .tag = .kw_private },
            .{ .t = "static", .tag = .kw_static },
            .{ .t = "var", .tag = .kw_var },
            .{ .t = "const", .tag = .kw_const },
            .{ .t = "abstract", .tag = .kw_abstract },
            .{ .t = "final", .tag = .kw_final },
            .{ .t = "enum", .tag = .kw_enum },
            .{ .t = "interface", .tag = .kw_interface },
            .{ .t = "trait", .tag = .kw_trait },
            .{ .t = "match", .tag = .kw_match },
            .{ .t = "readonly", .tag = .kw_readonly },
            .{ .t = "default", .tag = .kw_default },
            .{ .t = "instanceof", .tag = .kw_instanceof },
            .{ .t = "and", .tag = .kw_and },
            .{ .t = "or", .tag = .kw_or },
            .{ .t = "xor", .tag = .kw_xor },
            .{ .t = "fn", .tag = .kw_fn },
            .{ .t = "clone", .tag = .kw_clone },
            .{ .t = "print", .tag = .kw_print },
            .{ .t = "yield", .tag = .kw_yield },
            .{ .t = "include", .tag = .kw_include },
            .{ .t = "include_once", .tag = .kw_include_once },
            .{ .t = "require", .tag = .kw_require },
            .{ .t = "require_once", .tag = .kw_require_once },
            .{ .t = "list", .tag = .kw_list },
            .{ .t = "isset", .tag = .kw_isset },
            .{ .t = "empty", .tag = .kw_empty },
            .{ .t = "eval", .tag = .kw_eval },
            .{ .t = "exit", .tag = .kw_exit },
            .{ .t = "die", .tag = .kw_die },
            .{ .t = "throw", .tag = .kw_throw },
            .{ .t = "use", .tag = .kw_use },
            .{ .t = "do", .tag = .kw_do },
            .{ .t = "break", .tag = .kw_break },
            .{ .t = "continue", .tag = .kw_continue },
            .{ .t = "switch", .tag = .kw_switch },
            .{ .t = "case", .tag = .kw_case },
            .{ .t = "try", .tag = .kw_try },
            .{ .t = "catch", .tag = .kw_catch },
            .{ .t = "finally", .tag = .kw_finally },
            .{ .t = "declare", .tag = .kw_declare },
            .{ .t = "goto", .tag = .kw_goto },
            .{ .t = "global", .tag = .kw_global },
            .{ .t = "unset", .tag = .kw_unset },
            .{ .t = "insteadof", .tag = .kw_insteadof },
            .{ .t = "halt_compiler", .tag = .kw_halt_compiler },
        };
        for (list) |k| {
            if (std.mem.eql(u8, k.t, t)) return k.tag;
        }
        return null;
    }

    /// 把运算符/标点文本映射到 `Tag`，无法识别返回 `null`。
    ///
    /// 注意多字符运算符优先于单字符（如 `==` 先于 `=`），因此先按长度从长到短尝试。
    fn opTag(t: []const u8) ?Token.Tag {
        const ops = [_]struct { t: []const u8, tag: Token.Tag }{
            .{ .t = "...", .tag = .ellipsis },
            .{ .t = "\\", .tag = .backslash },
            .{ .t = "===", .tag = .equal_equal_equal },
            .{ .t = "!==", .tag = .bang_equal_equal },
            .{ .t = "**=", .tag = .double_asterisk_equal },
            .{ .t = ">>=", .tag = .right_shift_equal },
            .{ .t = "<<=", .tag = .left_shift_equal },
            .{ .t = "??", .tag = .null_coalesce },
            .{ .t = "?->", .tag = .nullsafe_arrow },
            .{ .t = "<<", .tag = .left_shift },
            .{ .t = ">>", .tag = .right_shift },
            .{ .t = "^", .tag = .caret },
            .{ .t = "^=", .tag = .caret_equal },
            .{ .t = "==", .tag = .equal_equal },
            .{ .t = "!=", .tag = .bang_equal },
            .{ .t = ">=", .tag = .greater_equal },
            .{ .t = "<=", .tag = .less_equal },
            .{ .t = "&&", .tag = .bool_and },
            .{ .t = "||", .tag = .bool_or },
            .{ .t = "->", .tag = .arrow },
            .{ .t = "::", .tag = .double_colon },
            .{ .t = "=>", .tag = .double_arrow },
            .{ .t = "++", .tag = .double_plus },
            .{ .t = "--", .tag = .double_minus },
            .{ .t = "**", .tag = .double_asterisk },
            .{ .t = "+=", .tag = .plus_equal },
            .{ .t = "-=", .tag = .minus_equal },
            .{ .t = "*=", .tag = .asterisk_equal },
            .{ .t = "/=", .tag = .slash_equal },
            .{ .t = "%=", .tag = .percent_equal },
            .{ .t = ".=", .tag = .dot_equal },
            .{ .t = "&=", .tag = .ampersand_equal },
            .{ .t = "|=", .tag = .pipe_equal },
            .{ .t = "^=", .tag = .caret_equal },
            .{ .t = "=", .tag = .equals },
            .{ .t = "+", .tag = .plus },
            .{ .t = "-", .tag = .minus },
            .{ .t = "*", .tag = .asterisk },
            .{ .t = "/", .tag = .slash },
            .{ .t = "%", .tag = .percent },
            .{ .t = ".", .tag = .dot },
            .{ .t = "!", .tag = .bang },
            .{ .t = "~", .tag = .tilde },
            .{ .t = "&", .tag = .ampersand },
            .{ .t = "|", .tag = .pipe },
            .{ .t = "?", .tag = .question },
            .{ .t = "<", .tag = .less_than },
            .{ .t = ">", .tag = .greater_than },
            .{ .t = ",", .tag = .comma },
            .{ .t = ";", .tag = .semicolon },
            .{ .t = ":", .tag = .colon },
            .{ .t = "@", .tag = .at },
            .{ .t = "(", .tag = .lparen },
            .{ .t = ")", .tag = .rparen },
            .{ .t = "{", .tag = .lbrace },
            .{ .t = "}", .tag = .rbrace },
            .{ .t = "[", .tag = .lbracket },
            .{ .t = "]", .tag = .rbracket },
        };
        for (ops) |o| {
            if (std.mem.eql(u8, o.t, t)) return o.tag;
        }
        return null;
    }

    /// 判断标识符文本是否为 PHP 魔术常量（大小写不敏感）。
    fn isMagicConst(t: []const u8) bool {
        const names = [_][]const u8{
            "__line__", "__file__", "__dir__", "__function__",
            "__class__", "__method__", "__trait__", "__namespace__",
        };
        var lower: [64]u8 = undefined;
        if (t.len == 0 or t.len > lower.len) return false;
        for (t, 0..) |ch, k| {
            lower[k] = if (ch >= 'A' and ch <= 'Z') ch + 32 else ch;
        }
        for (names) |nm| {
            if (std.mem.eql(u8, lower[0..t.len], nm)) return true;
        }
        return false;
    }

    /// 执行词法分析，把识别出的 token 追加到 `out` 中。
    ///
    /// 关键处理（为何如此）：
    /// - 开标签 `<?php` 需精确匹配后接空白/换行；`<?=` 单独成开标签。不匹配的
    ///   `<?` 视为普通文本跳过（PHP 嵌入模式）。这里以最稳妥的显式判断实现。
    /// - 注释一律作为 token 保留（不丢弃），满足 PHP docblock 的语义需要。
    /// - 遇到无法归类的字符，产出 `.invalid` token 并继续，而非崩溃——遵循
    ///   「不静默吞错、但也不轻易中止」：错误由后续解析器收集上报。
    /// - 字符串插值：双引号与 heredoc 进入「字面量累积」模式，把普通文本切成
    ///   `string_part`，把 `$var` / `{$expr}` 等切成可被解析器还原为表达式的 token；
    ///   nowdoc 关闭插值。`string_start`/`string_end` 标记整段边界。
    pub fn tokenize(
        gpa: std.mem.Allocator,
        source: [:0]const u8,
        out: *Token.TokenList,
    ) std.mem.Allocator.Error!void {
        var i: usize = 0;
        const n = source.len;

        // 字符串插值状态机
        var in_string: bool = false; // 处于 "..." 或 heredoc 内部
        var is_heredoc: bool = false; // 当前是 heredoc/nowdoc（而非双引号）
        var string_interp: bool = true; // 是否启用插值（nowdoc 为 false）
        var interp_depth: usize = 0; // `{$...}` 花括号嵌套层数
        var bracket_depth: usize = 0; // 复杂变量 `$v[...]`/`$v(...)` 的括号层数
        var heredoc_label: []const u8 = ""; // heredoc 终止标签文本
        var part_start: ?usize = null; // 待刷出的字面量片段起点

        // 把累积的字面量片段刷出一个 string_part token。
        const flushPart = struct {
            fn run(ps: *?usize, end: usize, g: std.mem.Allocator, o: *Token.TokenList) !void {
                if (ps.*) |s| {
                    try o.append(g, .{ .tag = .string_part, .start = s, .end = end });
                    ps.* = null;
                }
            }
        };

        while (i < n) : (i += 1) {
            const c = source[i];
            const literal_mode = in_string and interp_depth == 0 and bracket_depth == 0;

            // 空白：字符串字面量模式下累积为片段，否则直接跳过。
            if (c == ' ' or c == '\t' or c == '\n' or c == '\r') {
                if (literal_mode and part_start == null) part_start = i;
                continue;
            }

            // ===== 字符串字面量累积模式 =====
            if (literal_mode) {
                // heredoc / nowdoc 终止行：行首出现 `LABEL`（后可接 `;`/空白/换行）。
                if (is_heredoc) {
                    const at_line_start = (i == 0 or source[i - 1] == '\n');
                    if (at_line_start) {
                        var k = i;
                        while (k < n and (source[k] == ' ' or source[k] == '\t')) : (k += 1) {}
                        if (k + heredoc_label.len <= n) {
                            const cand = source[k .. k + heredoc_label.len];
                            if (std.mem.eql(u8, cand, heredoc_label)) {
                                const term_end = k + heredoc_label.len;
                                const after = if (term_end < n) source[term_end] else '\n';
                                if (after == '\n' or after == '\r' or after == ';' or
                                    after == ' ' or after == '\t' or term_end == n)
                                {
                                    try flushPart.run(&part_start, k, gpa, out);
                                    try out.append(gpa, .{ .tag = .string_end, .start = k, .end = term_end });
                                    in_string = false;
                                    is_heredoc = false;
                                    i = term_end - 1;
                                    continue;
                                }
                            }
                        }
                    }
                }

                // 双引号结束
                if (!is_heredoc and c == '"') {
                    try flushPart.run(&part_start, i, gpa, out);
                    try out.append(gpa, .{ .tag = .string_end, .start = i, .end = i + 1 });
                    in_string = false;
                    continue;
                }

                // 转义：反斜杠及其后一字符整体作为字面量片段。
                if (c == '\\' and i + 1 < n) {
                    if (part_start == null) part_start = i;
                    i += 1;
                    continue;
                }

                // 简单变量插值 `$var`
                if (string_interp and c == '$' and i + 1 < n and isIdentChar(source[i + 1])) {
                    try flushPart.run(&part_start, i, gpa, out);
                    var e = i + 1;
                    while (e < n and isIdentChar(source[e])) : (e += 1) {}
                    try out.append(gpa, .{ .tag = .variable, .start = i, .end = e });
                    i = e - 1;
                    // 复杂变量后缀：$v->prop / $v::CONST / $v[...] / $v(...)
                    while (true) {
                        const nx = i + 1;
                        if (nx < n and source[nx] == '-' and nx + 1 < n and source[nx + 1] == '>') {
                            try out.append(gpa, .{ .tag = .arrow, .start = nx, .end = nx + 2 });
                            i = nx + 1;
                            var p = i + 1;
                            while (p < n and isIdentChar(source[p])) : (p += 1) {}
                            if (p > i + 1) {
                                try out.append(gpa, .{ .tag = .identifier, .start = i + 1, .end = p });
                                i = p - 1;
                            }
                            continue;
                        }
                        if (nx < n and nx + 1 < n and source[nx] == ':' and source[nx + 1] == ':') {
                            try out.append(gpa, .{ .tag = .double_colon, .start = nx, .end = nx + 2 });
                            i = nx + 1;
                            var p = i + 1;
                            while (p < n and isIdentChar(source[p])) : (p += 1) {}
                            if (p > i + 1) {
                                try out.append(gpa, .{ .tag = .identifier, .start = i + 1, .end = p });
                                i = p - 1;
                            }
                            continue;
                        }
                        if (nx < n and (source[nx] == '[' or source[nx] == '(')) {
                            i = nx - 1;
                            bracket_depth = 1;
                            break;
                        }
                        break;
                    }
                    continue;
                }

                // 花括号插值 {$expr} / {(expr)}
                if (string_interp and c == '{' and i + 1 < n and
                    (source[i + 1] == '$' or source[i + 1] == '('))
                {
                    try flushPart.run(&part_start, i, gpa, out);
                    try out.append(gpa, .{ .tag = .lbrace, .start = i, .end = i + 1 });
                    interp_depth = 1;
                    continue;
                }

                // 其余字符：累积为字面量片段
                if (part_start == null) part_start = i;
                continue;
            }

            // ===== 插值内部（花括号 / 括号区域）：正常分词 =====
            if (interp_depth > 0) {
                if (c == '{') {
                    try out.append(gpa, .{ .tag = .lbrace, .start = i, .end = i + 1 });
                    interp_depth += 1;
                    continue;
                }
                if (c == '}') {
                    interp_depth -= 1;
                    try out.append(gpa, .{ .tag = .rbrace, .start = i, .end = i + 1 });
                    continue;
                }
                // 落入下方正常分词
            }

            if (in_string and bracket_depth > 0) {
                if (c == '[') {
                    try out.append(gpa, .{ .tag = .lbracket, .start = i, .end = i + 1 });
                    bracket_depth += 1;
                    continue;
                }
                if (c == '(') {
                    try out.append(gpa, .{ .tag = .lparen, .start = i, .end = i + 1 });
                    bracket_depth += 1;
                    continue;
                }
                if (c == ']' or c == ')') {
                    const tag = if (c == ']') Token.Tag.rbracket else Token.Tag.rparen;
                    try out.append(gpa, .{ .tag = tag, .start = i, .end = i + 1 });
                    bracket_depth -= 1;
                    if (bracket_depth == 1) bracket_depth = 0;
                    continue;
                }
                // 落入下方正常分词
            }

            // ===== 正常分词（顶层，或插值/括号内部）=====

            // heredoc / nowdoc 起点：<<<LABEL（nowdoc 为 <<<'LABEL'）
            if (!in_string and c == '<' and i + 2 < n and source[i + 1] == '<' and source[i + 2] == '<') {
                var j = i + 3;
                var nowdoc = false;
                if (j < n and source[j] == '\'') {
                    nowdoc = true;
                    j += 1;
                }
                const ls = j;
                while (j < n and isIdentChar(source[j])) : (j += 1) {}
                if (j > ls) {
                    const label = source[ls..j];
                    var e = j;
                    while (e < n and source[e] != '\n') : (e += 1) {}
                    try out.append(gpa, .{ .tag = .string_start, .start = i, .end = i + 3 });
                    in_string = true;
                    is_heredoc = true;
                    string_interp = !nowdoc;
                    interp_depth = 0;
                    bracket_depth = 0;
                    heredoc_label = label;
                    part_start = null;
                    i = e;
                    continue;
                }
                // 非合法 heredoc：当作普通 `<` 继续（落入运算符扫描）
            }

            // 开标签 <?php 或 <?=
            if (c == '<' and i + 1 < n and source[i + 1] == '?') {
                const j = i + 2;
                if (j < n and source[j] == '=') {
                    try out.append(gpa, .{ .tag = .open_tag, .start = i, .end = j + 1 });
                    i = j;
                    continue;
                }
                // <?php 后必须接空白/换行/EOF，否则不是合法开标签。
                var k = j;
                while (k < n and isIdentChar(source[k])) : (k += 1) {}
                const after = if (k < n) source[k] else ' ';
                if (k > j and (after == ' ' or after == '\t' or after == '\n' or after == '\r')) {
                    try out.append(gpa, .{ .tag = .open_tag, .start = i, .end = k });
                    i = k - 1;
                    continue;
                }
                // 不匹配的 <? ：当作普通文本继续，交给后面按字符处理。
            }

            // 闭标签 ?> ：结束 PHP 模式。其后直到下一个开标签 `<?` 的文本内容作为
            // `inline_html` token 保留（供 `Stmt\InlineHTML`）；若文件至此结束则无 HTML。
            if (c == '?' and i + 1 < n and source[i + 1] == '>') {
                try out.append(gpa, .{ .tag = .close_tag, .start = i, .end = i + 2 });
                i += 1;
                // 扫描后续文本，遇下一个开标签 <? 之前整体作为 inline_html
                var j = i + 1;
                while (j + 1 < n) : (j += 1) {
                    if (source[j] == '<' and (source[j + 1] == '?' or (j + 2 < n and source[j + 1] == '=' and source[j + 2] == '>'))) {
                        break;
                    }
                }
                if (j > i + 1) {
                    try out.append(gpa, .{ .tag = .inline_html, .start = i + 1, .end = j });
                }
                i = j - 1;
                continue;
            }

            // 行注释 // 与 #，以及块注释 /* */
            if (c == '/' and i + 1 < n and source[i + 1] == '/') {
                var e = i + 2;
                while (e < n and source[e] != '\n') : (e += 1) {}
                const tag: Token.Tag = if (i + 3 < n and source[i + 2] == '/' and source[i + 3] == '/')
                    .doc_comment
                else
                    .comment;
                try out.append(gpa, .{ .tag = tag, .start = i, .end = e });
                i = e - 1;
                continue;
            }
            if (c == '#') {
                // `#[` 视为属性开符；其余 `#` 是行注释。
                if (i + 1 < n and source[i + 1] == '[') {
                    try out.append(gpa, .{ .tag = .hash, .start = i, .end = i + 1 });
                    continue;
                }
                var e = i + 1;
                while (e < n and source[e] != '\n') : (e += 1) {}
                try out.append(gpa, .{ .tag = .comment, .start = i, .end = e });
                i = e - 1;
                continue;
            }
            if (c == '/' and i + 1 < n and source[i + 1] == '*') {
                var e = i + 2;
                while (e + 1 < n and !(source[e] == '*' and source[e + 1] == '/')) : (e += 1) {}
                const tag: Token.Tag = if (i + 2 < n and source[i + 1] == '*' and source[i + 2] == '*')
                    .doc_comment
                else .comment;
                const end = if (e + 1 < n) e + 2 else e;
                try out.append(gpa, .{ .tag = tag, .start = i, .end = end });
                i = end - 1;
                continue;
            }

            // 单引号字符串：始终为字面量（不插值），产出 `string_literal`。
            if (c == '\'') {
                var e = i + 1;
                while (e < n) : (e += 1) {
                    if (source[e] == '\\' and e + 1 < n) {
                        e += 1;
                        continue;
                    }
                    if (source[e] == '\'') break;
                }
                const end = if (e < n) e + 1 else e;
                try out.append(gpa, .{ .tag = .string_literal, .start = i, .end = end });
                i = end - 1;
                continue;
            }
            // 双引号字符串：顶层才进入插值模式；否则当作普通字符落入运算符扫描。
            if (c == '"' and !in_string and interp_depth == 0 and bracket_depth == 0) {
                try out.append(gpa, .{ .tag = .string_start, .start = i, .end = i + 1 });
                in_string = true;
                is_heredoc = false;
                string_interp = true;
                interp_depth = 0;
                bracket_depth = 0;
                part_start = null;
                continue;
            }

            // 反引号（shell exec）：`...`
            if (c == '`') {
                var e = i + 1;
                while (e < n and source[e] != '`') : (e += 1) {}
                const content_end = e;
                const end = if (e < n) e + 1 else e;
                try out.append(gpa, .{ .tag = .backtick, .start = i, .end = i + 1 });
                try out.append(gpa, .{ .tag = .string_literal, .start = i + 1, .end = content_end });
                try out.append(gpa, .{ .tag = .backtick, .start = content_end, .end = end });
                i = end - 1;
                continue;
            }

            // 整型 / 浮点字面量
            if (isDigitChar(c)) {
                var e = i + 1;
                var is_float = false;
                while (e < n) : (e += 1) {
                    const ch = source[e];
                    if (isDigitChar(ch)) continue;
                    if (ch == '.' and !is_float) {
                        is_float = true;
                        continue;
                    }
                    break;
                }
                const tag: Token.Tag = if (is_float) .float_literal else .int_literal;
                try out.append(gpa, .{ .tag = tag, .start = i, .end = e });
                i = e - 1;
                continue;
            }

            // 变量名 $foo
            if (c == '$' and i + 1 < n and isIdentChar(source[i + 1])) {
                var e = i + 1;
                while (e < n and isIdentChar(source[e])) : (e += 1) {}
                try out.append(gpa, .{ .tag = .variable, .start = i, .end = e });
                i = e - 1;
                continue;
            }

            // 标识符 / 关键字 / 魔术常量
            if (isIdentChar(c)) {
                var e = i;
                while (e < n and isIdentChar(source[e])) : (e += 1) {}
                const text = source[i..e];
                const tag = blk: {
                    if (keywordTag(text)) |k| break :blk k;
                    if (isMagicConst(text)) break :blk .magic_const;
                    break :blk .identifier;
                };
                try out.append(gpa, .{ .tag = tag, .start = i, .end = e });
                i = e - 1;
                continue;
            }

            // 运算符 / 标点：从最长 3 字符开始尝试，匹配即产出。
            {
                var matched = false;
                const maxlen = if (n - i < 3) n - i else 3;
                var len = maxlen;
                while (len >= 1) : (len -= 1) {
                    if (opTag(source[i .. i + len])) |tag| {
                        try out.append(gpa, .{ .tag = tag, .start = i, .end = i + len });
                        i += len - 1;
                        matched = true;
                        break;
                    }
                }
                if (matched) continue;
            }

            // 兜底：无法归类的字符，记为 invalid 并继续（不崩溃、不静默丢弃）。
            try out.append(gpa, .{ .tag = .invalid, .start = i, .end = i + 1 });
        }

        // 末尾补 eof 哨兵，方便解析器用 `tok_i < n` 判定结束。
        try out.append(gpa, .{ .tag = .eof, .start = n, .end = n });
    }
};
