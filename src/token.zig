const std = @import("std");

/// 词法单元（token）。`Token` 只存种类与起止字节偏移，不复制源码文本；
/// 文本经 `tree.tokenSlice(index)` 按偏移回源取得，词法阶段对字面量零拷贝。
/// 偏移均为源码内的绝对字节下标（`ByteOffset`）。
pub const Token = struct {
    /// 源码内的字节偏移类型。词法阶段直接以下标赋值，故用 `usize`。
    pub const ByteOffset = usize;

    /// 所有词法种类的扁平枚举，与 PHP 官方 `zend_language_scanner` 对应。
    /// 单点定义，解析器与 AST 只引用、不重复。
    pub const Tag = enum {
        eof,
        invalid,

        // 字面量
        int_literal,
        float_literal,
        string_literal,

        // 字符串插值（双引号 / heredoc 的内部分词）
        string_start,
        string_end,
        string_part,

        // 名称
        identifier,
        variable,
        magic_const,

        // 标记（tag）
        open_tag,
        close_tag,
        comment,
        doc_comment,

        // 标点
        comma,
        semicolon,
        colon,
        at,
        arrow,
        double_colon,
        lparen,
        rparen,
        lbrace,
        rbrace,
        lbracket,
        rbracket,
        hash,
        ellipsis,
        backslash,

        // 运算符
        equals,
        plus,
        minus,
        asterisk,
        slash,
        percent,
        dot,
        bang,
        tilde,
        ampersand,
        pipe,
        double_arrow,
        question,
        double_plus,
        double_minus,
        double_asterisk,
        equal_equal,
        bang_equal,
        equal_equal_equal,
        bang_equal_equal,
        spaceship,
        less_than,
        greater_than,
        less_equal,
        greater_equal,
        bool_and,
        bool_or,
        plus_equal,
        minus_equal,
        asterisk_equal,
        slash_equal,
        percent_equal,
        dot_equal,
        double_asterisk_equal,
        ampersand_equal,
        pipe_equal,
        left_shift,
        right_shift,
        left_shift_equal,
        right_shift_equal,
        null_coalesce,
        nullsafe_arrow,
        caret,
        caret_equal,
        backtick,

        // 关键字
        kw_if,
        kw_else,
        kw_elseif,
        kw_while,
        kw_for,
        kw_foreach,
        kw_as,
        kw_function,
        kw_class,
        kw_extends,
        kw_implements,
        kw_return,
        kw_echo,
        kw_namespace,
        kw_new,
        kw_true,
        kw_false,
        kw_null,
        kw_public,
        kw_protected,
        kw_private,
        kw_static,
        kw_var,
        kw_const,
        kw_abstract,
        kw_final,
        kw_enum,
        kw_interface,
        kw_trait,
        kw_match,
        kw_readonly,
        kw_default,
        kw_instanceof,
        kw_and,
        kw_or,
        kw_xor,
        kw_fn,
        kw_clone,
        kw_print,
        kw_yield,
        kw_include,
        kw_include_once,
        kw_require,
        kw_require_once,
        kw_list,
        kw_isset,
        kw_empty,
        kw_eval,
        kw_exit,
        kw_die,
        kw_throw,
        kw_use,
        kw_do,
        kw_break,
        kw_continue,
        kw_switch,
        kw_case,
        kw_try,
        kw_catch,
        kw_finally,
        kw_declare,
        kw_goto,
        kw_global,
        kw_unset,
        kw_insteadof,
        kw_halt_compiler,
        inline_html,
    };

    /// 关键字表：文本到 `Tag` 的完整映射，单点维护。
    ///
    /// 词法器与词法覆盖矩阵均读此表：新增关键字只需改这一处，测试自动覆盖。
    /// 8.x 新增关键字在此集中添加。
    pub const keywords = [_]Mapping{
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

    /// 运算符/标点表：按文本长度从长到短排列。
    ///
    /// 顺序有语义：多字符运算符必须优先于单字符（如 `==` 先于 `=`），词法器按此
    /// 顺序首次匹配即用。`lexeme` 亦由此表反查，避免两处各写一份。
    pub const operators = [_]Mapping{
        .{ .t = "...", .tag = .ellipsis },
        .{ .t = "===", .tag = .equal_equal_equal },
        .{ .t = "!==", .tag = .bang_equal_equal },
        .{ .t = "**=", .tag = .double_asterisk_equal },
        .{ .t = ">>=", .tag = .right_shift_equal },
        .{ .t = "<<=", .tag = .left_shift_equal },
        .{ .t = "\\", .tag = .backslash },
        .{ .t = "<=>", .tag = .spaceship },
        .{ .t = "??", .tag = .null_coalesce },
        .{ .t = "?->", .tag = .nullsafe_arrow },
        .{ .t = "<<", .tag = .left_shift },
        .{ .t = ">>", .tag = .right_shift },
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
        .{ .t = "^", .tag = .caret },
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
        .{ .t = "#", .tag = .hash },
        .{ .t = "`", .tag = .backtick },
    };

    /// `keywords` / `operators` 的表项类型。
    pub const Mapping = struct {
        t: []const u8,
        tag: Tag,
    };

    /// 把关键字文本映射到 `Tag`，非关键字返回 `null`。
    pub fn keywordTag(t: []const u8) ?Tag {
        for (keywords) |k| {
            if (std.mem.eql(u8, k.t, t)) return k.tag;
        }
        return null;
    }

    /// 把运算符/标点文本映射到 `Tag`，无法识别返回 `null`。
    ///
    /// 按 `operators` 顺序匹配，该表已按长度降序，故多字符运算符自然优先。
    pub fn opTag(t: []const u8) ?Tag {
        for (operators) |o| {
            if (std.mem.eql(u8, o.t, t)) return o.tag;
        }
        return null;
    }

    /// 词法序列的存储结构。`MultiArrayList` 把 `tag`/`start`/`end` 分列存放（SoA）。
    pub const TokenList = std.MultiArrayList(struct {
        tag: Tag,
        start: ByteOffset,
        end: ByteOffset,
    });

    /// 返回某个词法种类固定对应的字面文本（如 `;` → `";"`）。
    /// 仅对标点/运算符有效；标识符、字面量等需经源码切片取得，故返回 `null`。
    ///
    /// ```zig
    /// try std.testing.expect(std.meta.eql(Token.lexeme(.arrow).?, "->"));
    /// ```
    ///
    /// 由 `operators` 反查，不另存一份映射——否则新增运算符要改两处。
    pub fn lexeme(tag: Tag) ?[]const u8 {
        for (operators) |o| {
            if (o.tag == tag) return o.t;
        }
        return null;
    }

    /// 判断词法种类是否为注释。注释不进节点，但作为 token 保留在 `Ast.tokens`，
    /// 下游经 `Ast.docCommentBefore` 取回 docblock。
    pub fn isComment(tag: Tag) bool {
        return tag == .comment or tag == .doc_comment;
    }
};
