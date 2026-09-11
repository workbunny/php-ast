//! AST 定义与查询入口。布局参照 `std.zig.Ast`（SoA + 索引平板）：
//! - `nodes` 为扁平 `Node` 数组，节点间以 `Index` 互相引用而非指针；每个节点仅 3 字段。
//! - 超过 2 个直接子节点的负载序列化进 `extra_data`（`u32` 大板），节点 `data` 仅存 `ExtraIndex`。
//! - `tokens` 与 `nodes` 分离存储。
//!
//! 内存由调用方经 `parse(gpa, ...)` 提供，统一用 `deinit` 释放；位置信息不冗余存储，
//! 行/列经 `tokenLocation` 按需从 `main_token` 派生。
const std = @import("std");
const Token = @import("token.zig").Token;
const PhpVersion = @import("version.zig").PhpVersion;
const BASE_VERSION = @import("version.zig").BASE_VERSION;
const Lexer = @import("lexer.zig").Lexer;
const parser = @import("parser.zig");
// 各 parser 子模块：取其定义的 `Components`（`extra_data` 的解码布局）。
// 这些模块反向导入本文件，构成 Zig 允许的循环导入；此处仅引用其类型，
// 不存在 comptime 求值环，可安全解析。
const stmt = @import("parser_stmt.zig");
const decl = @import("parser_decl.zig");
const expr = @import("parser_expr.zig");
const types = @import("parser_type.zig");
const testing = @import("testing.zig");

/// 解析失败仅可能是内存不足；语法错误不在此列，而是收集进 `Ast.errors`。
pub const ParseError = std.mem.Allocator.Error;

/// 源码内的字节偏移。
pub const ByteOffset = u32;

/// `tokens` 数组中的下标。词法结果以 `Token.TokenList.Slice` 持有。
pub const TokenIndex = u32;

/// 可选 token 下标，用哨兵值 `none`（最大 u32）编码「无」，
/// 避免 `?TokenIndex` 作为联合字段撑大 `Node`。读取用 `unwrap`。
pub const OptionalTokenIndex = enum(u32) {
    none = std.math.maxInt(u32),
    _,
    pub fn unwrap(self: OptionalTokenIndex) ?TokenIndex {
        return if (self == .none) null else @intFromEnum(self);
    }
    pub fn fromToken(ti: TokenIndex) OptionalTokenIndex {
        return @enumFromInt(ti);
    }
};

/// `extra_data` 大板中的下标，指向某段序列化负载的起点。
pub const ExtraIndex = enum(u32) {
    zero = 0,
    _,
};

/// 节点句柄，即 `nodes` 数组下标。树中节点相互引用，`root` 为根节点下标。
pub const Index = enum(u32) {
    root = 0,
    _,
};

/// 可选节点下标，哨兵值 `none`（最大 u32）编码「无」。
pub const OptionalIndex = enum(u32) {
    none = std.math.maxInt(u32),
    _,
    pub fn unwrap(self: OptionalIndex) ?Index {
        return if (self == .none) null else @enumFromInt(@intFromEnum(self));
    }
    pub fn fromIndex(n: Index) OptionalIndex {
        return @enumFromInt(@intFromEnum(n));
    }
};

/// 一段可选节点下标区间，用于在 `extra_data` 中表示「无节点」（空区间）。
pub const SubRange = struct {
    start: ExtraIndex,
    end: ExtraIndex,
};

/// 一段节点下标区间，连续存放于 `extra_data`（通常为某个子节点列表）。
pub const ListRange = struct {
    start: ExtraIndex,
    end: ExtraIndex,
};

/// 一条诊断信息（解析错误）。错误不立即中止解析，而是累计后随 AST 一并返回
/// （多错误收集，便于编辑器/lint 一次取得全部诊断）。
pub const Error = struct {
    tag: Error.Tag,
    /// 诊断区间起点 token（含）。
    token: TokenIndex,
    /// 诊断区间终点 token（含）。单 token 诊断时与 `token` 相同。
    token_end: TokenIndex,
    /// 附加 token：消息需引用具体文本时指向它（保留名、修饰符名、钩子名、方法名等）。
    /// 不需要时与 `token` 相同。
    aux: TokenIndex,
    /// 数值参数（如非法字符的 ASCII 码、期望缩进级别）；不使用恒为 0。
    data: u32,
    /// 仅 `unsupported_version` 使用：该节点语法要求的 PHP 版本；
    /// 其余错误恒为 `BASE_VERSION`(id=0)，读取无意义。
    required: PhpVersion,
    /// 语法错误的「期望集合」：渲染为 `, expecting <集合>` 后缀。php-parser 的
    /// 期望集合由 LALR 状态决定（同一判据在不同语法位置期望不同），故由各报点
    /// 显式指定，而非按 tag 统一推断。非语法错误恒为 `.none`。
    expected: Expected = .none,

    /// `Syntax error, unexpected X, expecting <集合>` 的 `<集合>` 取值。
    /// 每条对应 php-parser 一个具体状态的期望列表（见 `expectingText`）。
    pub const Expected = enum {
        /// 不渲染 expecting 后缀（php-parser 该状态下期望集合为空/未列）。
        none,
        /// `';'`
        semi,
        /// `';' or '{'`
        semi_or_lbrace,
        /// `'('`
        lparen,
        /// 列表项之后：`',' or ']' or ')'`
        comma_list,
        /// `T_STRING`（声明名/别名位）
        name,
        /// group use 前缀名字位
        use_name,
        /// 类成员名位
        member_name,
        /// 变量名位（`$` 之后，允许 `$x` / `${...}` / `$$x`）
        var_name,
        /// 参数名位：只接受变量本身，不含 `$` / `{` 起始（php-parser 该状态
        /// 期望集合仅 `T_VARIABLE`）
        variable,

        fn expectingText(e: Expected) []const u8 {
            return switch (e) {
                .none => "",
                .semi => "';'",
                .semi_or_lbrace => "';' or '{'",
                .lparen => "'('",
                .comma_list => "',' or ']' or ')'",
                .name => "T_STRING",
                .use_name => "T_STRING or T_FUNCTION or T_CONST or T_NAME_QUALIFIED",
                .member_name => "T_STRING or T_VARIABLE or '{' or '$'",
                .var_name => "T_VARIABLE or '{' or '$'",
                .variable => "T_VARIABLE",
            };
        }
    };

    /// 渲染时实际采用的期望集合：显式指定的优先；`expected_variable` 的语义恒为
    /// 「变量名位」（`simple_variable` 只接受 `$x`/`${...}`/`$$x`），其报点不逐一
    /// 标注 `expected`，在此兜底为 `.var_name`。
    pub fn effectiveExpected(self: Error) Expected {
        if (self.expected != .none) return self.expected;
        return switch (self.tag) {
            .expected_variable => .var_name,
            else => .none,
        };
    }

    /// token 的 php-parser 显示名：`Syntax error, unexpected <X>` 的 `<X>`。
    ///
    /// 规则：EOF 显 `EOF`；标识符显 `T_STRING`、变量显 `T_VARIABLE`；关键字显
    /// `T_<大写文本>`（PHP token 名即「T_ + 关键字大写」，除个别特例下表单独处理）；
    /// 运算符特判（`->` 为 T_OBJECT_OPERATOR 等）；其余符号显 `'<原文>'`。
    /// `out` 由调用方提供，返回其有效切片。
    pub fn tokenDisplayName(tree: *const Ast, tok: TokenIndex, out: []u8) []const u8 {
        const tag = tree.tokenTag(tok);
        const text = tree.tokenSlice(tok);
        return switch (tag) {
            .eof => "EOF",
            // 词法器按源码原样切片（大小写敏感），但 PHP 关键字大小写不敏感：
            // `ReadOnly` / `Static` 在 php-parser 是 T_READONLY / T_STATIC 而非
            // T_STRING，故此处回判——文本命中关键字则按关键字名显示。
            .identifier => if (Token.keywordTagIgnoreCase(text)) |k|
                (keywordDisplayName(k, out) orelse "T_STRING")
            else
                "T_STRING",
            .variable => "T_VARIABLE",
            // 完全限定名的前导 `\`：php-parser 把 `\Foo\Bar` 整体作一个
            // T_NAME_FULLY_QUALIFIED token，故显示名按名类给出（本库词法把 `\`
            // 与名字段分开切，诊断区间由报点自行覆盖整名）。
            .backslash => "T_NAME_FULLY_QUALIFIED",
            .arrow => "T_OBJECT_OPERATOR",
            .double_colon => "T_PAAMAYIM_NEKUDOTAYIM",
            .nullsafe_arrow => "T_NULLSAFE_OBJECT_OPERATOR",
            // `&` 的 php-parser token 名分两态，由**后随 token** 决定：后随变量或
            // `...`（引用形参 / 引用实参 / 引用解构）为 FOLLOWED，其余为 NOT_FOLLOWED。
            .ampersand => if (tok + 1 < @as(TokenIndex, @intCast(tree.tokens.len)) and
                (tree.tokenTag(tok + 1) == .variable or tree.tokenTag(tok + 1) == .ellipsis))
                "T_AMPERSAND_FOLLOWED_BY_VAR_OR_VARARG"
            else
                "T_AMPERSAND_NOT_FOLLOWED_BY_VAR_OR_VARARG",
            .ellipsis => "T_ELLIPSIS",
            else => if (tag.isKeyword()) blk: {
                // 源码可能带大小写（`Break`），统一按关键字表的小写文本大写输出。
                if (keywordDisplayName(tag, out)) |n| return n;
                break :blk "'{s}'";
            } else std.fmt.bufPrint(out, "'{s}'", .{text}) catch "'?'",
        };
    }

    /// 关键字 tag → php-parser token 名（`T_` + 关键字表文本的大写）。
    /// 表内查不到该 tag 时返回 `null`（调用方退回引号原文形式）。
    fn keywordDisplayName(tag: Token.Tag, out: []u8) ?[]const u8 {
        var lower: ?[]const u8 = null;
        for (Token.keywords) |k| {
            if (k.tag == tag) {
                lower = k.t;
                break;
            }
        }
        const kw_text = lower orelse return null;
        var tmp: [64]u8 = undefined;
        if (kw_text.len >= tmp.len) return null;
        for (kw_text, 0..) |ch, i| tmp[i] = std.ascii.toUpper(ch);
        return std.fmt.bufPrint(out, "T_{s}", .{tmp[0..kw_text.len]}) catch "T_";
    }

    /// 把错误渲染成 php-parser 风格文案：
    /// `"<消息> from <起行>:<起列> to <止行>:<止列>"`（对齐
    /// `Error::getMessageWithColumnInfo()`，行列均 1 基、列为字节偏移）。
    /// `unsupported_version` 单独写明「语法要求版本」与「目标版本」；
    /// `buf` 由调用方提供，返回其有效切片。
    pub fn format(self: Error, tree: *const Ast, buf: []u8) []const u8 {
        if (self.tag == .unsupported_version) {
            const r = self.required;
            const t = tree.version;
            return std.fmt.bufPrint(buf,
                "node syntax requires PHP {}.{} but target is {}.{}",
                .{
                    r.id / 10000,
                    (r.id % 10000) / 100,
                    t.id / 10000,
                    (t.id % 10000) / 100,
                },
            ) catch "unsupported version";
        }
        // 自含位置的消息（php-parser 原样文案）不带 `from..to` 后缀——判定集中在
        // `Tag.discardsLocationSuffix`，文案本体只在 `rawMessage` 里写一份。
        if (self.tag.discardsLocationSuffix()) return self.rawMessage(tree, buf);
        const sl = tree.tokenLocation(0, self.token);
        const el = tree.tokenLocation(0, self.token_end);
        // 结束列：php-parser 的 `endFilePos` 是「最后一个字符所在偏移」（含），
        // 故列 = 末字符偏移 - 行首。零宽 token（如 EOF，end == start）取其后一位，
        // 否则未终止注释等延伸到文件尾的诊断会少算一列。
        const te = tree.tokenEnd(self.token_end);
        const ts = tree.tokenStart(self.token_end);
        const end_col = (if (te > ts) te else ts + 1) - el.line_start;
        // 消息正文先渲染进独立缓冲：`rawMessage` 与最终 `bufPrint` 不可共用缓冲
        // （否则写入目标与读取源重叠）。
        var mbuf: [256]u8 = undefined;
        const msg = self.rawMessage(tree, &mbuf);
        return std.fmt.bufPrint(buf, "{s} from {d}:{d} to {d}:{d}", .{
            msg,
            sl.line + 1,
            sl.column + 1,
            el.line + 1,
            end_col,
        }) catch "parse error";
    }

    /// 消息正文（不含位置后缀）。语义/词法类为固定文案，需引用源码文本的经
    /// `aux`/`data` 取用；语法类为 `Syntax error, unexpected <token>`。
    /// `buf` 由调用方提供，返回其有效切片。
    pub fn rawMessage(self: Error, tree: *const Ast, buf: []u8) []const u8 {
        const text = tree.tokenSlice(self.aux);
        return switch (self.tag) {
            // ---- 语法类：`Syntax error, unexpected <token>`（php-parser 报在意外
            // token 上；`self.token` 即该 token）。----
            .expected_token, .expected_semi, .expected_expr, .expected_variable,
            .expected_identifier, .expected_lbrace, .expected_rbrace, .expected_rparen,
            .expected_lbracket, .unexpected_eof,
            => blk: {
                // token 显示名先用独立缓冲渲染（不能与 bufPrint 的目标共用 buf）
                var nbuf: [64]u8 = undefined;
                const name = tokenDisplayName(tree, self.token, &nbuf);
                const exp = self.effectiveExpected();
                if (exp == .none) {
                    break :blk std.fmt.bufPrint(buf, "Syntax error, unexpected {s}", .{name}) catch "Syntax error";
                }
                break :blk std.fmt.bufPrint(
                    buf,
                    "Syntax error, unexpected {s}, expecting {s}",
                    .{ name, exp.expectingText() },
                ) catch "Syntax error";
            },

            // 语义：修饰符
            .multiple_access_modifiers => "Multiple access type modifiers are not allowed",
            .multiple_readonly_modifiers => "Multiple readonly modifiers are not allowed",
            .multiple_abstract_modifiers => "Multiple abstract modifiers are not allowed",
            .multiple_static_modifiers => "Multiple static modifiers are not allowed",
            .multiple_final_modifiers => "Multiple final modifiers are not allowed",
            .final_on_abstract_class => "Cannot use the final modifier on an abstract class",
            .final_on_abstract_member => "Cannot use the final modifier on an abstract class member",
            .invalid_const_modifier => std.fmt.bufPrint(buf, "Cannot use '{s}' as constant modifier", .{text}) catch "Invalid constant modifier",
            .readonly_method => std.fmt.bufPrint(buf, "Method {s}() cannot be readonly", .{text}) catch "Methods cannot be readonly",
            .hook_modifier => std.fmt.bufPrint(buf, "Cannot use the {s} modifier on a property hook", .{text}) catch "Invalid hook modifier",
            .unknown_hook => std.fmt.bufPrint(buf, "Unknown hook \"{s}\", expected \"get\" or \"set\"", .{text}) catch "Unknown hook",
            // 语义：魔法方法 static
            .static_constructor => std.fmt.bufPrint(buf, "Constructor {s}() cannot be static", .{text}) catch "Constructor cannot be static",
            .static_destructor => std.fmt.bufPrint(buf, "Destructor {s}() cannot be static", .{text}) catch "Destructor cannot be static",
            .static_clone => std.fmt.bufPrint(buf, "Clone method {s}() cannot be static", .{text}) catch "Clone method cannot be static",
            // 语义：参数与常量
            .void_parameter => "void cannot be used as a parameter type",
            .variadic_default => "Variadic parameter cannot have a default value",
            .const_attr_multi => "Cannot use attributes on multiple constants at once",
            .trailing_comma => "A trailing comma is not allowed here",
            // 语义：属性钩子
            .hook_empty => "Property hook list cannot be empty",
            .hook_get_params => "get hook must not have a parameter list",
            .hook_multi_property => "Cannot use hooks when declaring multiple properties",
            // 语义：名字
            .reserved_class_name => std.fmt.bufPrint(buf, "Cannot use '{s}' as class name as it is reserved", .{text}) catch "Reserved class name",
            .reserved_interface_name => std.fmt.bufPrint(buf, "Cannot use '{s}' as interface name as it is reserved", .{text}) catch "Reserved interface name",
            .special_class_name_alias => std.fmt.bufPrint(buf, "Cannot use {s} as {s} because '{s}' is a special class name", .{ tree.tokenSlice(self.data), text, text }) catch "Special class name alias",
            // 语义：语句与作用域
            .try_without_catch => "Cannot use try without catch or finally",
            .halt_not_outermost => "__HALT_COMPILER() can only be used from the outermost scope",
            .namespace_nested => "Namespace declarations cannot be nested",
            .namespace_mixed => "Cannot mix bracketed namespace declarations with unbracketed namespace declarations",
            .namespace_not_first => "Namespace declaration statement has to be the very first statement in the script",
            .namespace_code_outside => "No code may exist outside of namespace {}",
            .assign_new_by_ref => "Cannot assign new by reference",
            .array_empty_element => "Cannot use empty array elements in arrays",
            .pipe_arrow_unparenthesized => "Arrow functions on the right hand side of |> must be parenthesized",
            .non_simple_variable => "Non-simple variables are forbidden in PHP 7",
            // 词法/解码
            .unterminated_comment => "Unterminated comment",
            .unexpected_character => std.fmt.bufPrint(buf, "Unexpected character \"{s}\" (ASCII {d})", .{ text, self.data }) catch "Unexpected character",
            .unexpected_null_byte => "Unexpected null byte",
            .invalid_numeric_literal => "Invalid numeric literal",
            .invalid_numeric_separator => "Invalid numeric separator",
            .invalid_indentation_mixed => "Invalid indentation - tabs and spaces cannot be mixed",
            .invalid_indentation_level => std.fmt.bufPrint(buf, "Invalid body indentation level (expecting an indentation level of at least {d})", .{self.data}) catch "Invalid body indentation level",
            .short_echo_identifier => "Cannot use \"<?=\" as an identifier",
            .invalid_utf8_codepoint => blk: {
                // 该消息自含位置（`on line N`），`rawMessage` 即完整句
                // （`format` 对同 tag 不再追加 from..to 后缀）。
                const loc = tree.tokenLocation(0, self.token);
                break :blk std.fmt.bufPrint(
                    buf,
                    "Invalid UTF-8 codepoint escape sequence: Codepoint too large on line {d}",
                    .{loc.line + 1},
                ) catch "Invalid UTF-8 codepoint escape sequence";
            },
            // 语法类（`Syntax error, unexpected <token>`）由 `unexpected_token` 系列
            // 表达，消息待补 token 名表；此处先按 tag 名兜底。
            else => @tagName(self.tag),
        };
    }

    /// 错误种类枚举。每个变体对应一种具体的语法期望失败。
    pub const Tag = enum {
        expected_token,
        expected_semi,
        expected_expr,
        expected_variable,
        expected_identifier,
        expected_lbrace,
        expected_rbrace,
        expected_rparen,
        expected_lbracket,
        unexpected_eof,
        lex_error,
        /// 语法构造的引入版本高于 `parse` 指定的目标版本（版本门控）。
        unsupported_version,

        // ---- 引擎级语义诊断（拒绝面，不属语法缺口）----
        // 每个变体对应一条 php-parser 消息（`rawMessage` 内一一映射），故按消息族
        // 细分：同一类违规但文案不同（如「重复可见性」与「重复 static」）是不同 Tag。
        //
        // 解析期就地（信息在修饰符收集循环中被丢弃，无法事后恢复；php-parser 同样
        // 在语法期 recover 处理）：见 `parsePropertyModifiers`/`parseMethod` 等修饰符
        // 入口。合法代码永不触发。
        /// 重复可见性修饰符（`public public $a`）。
        multiple_access_modifiers,
        /// 重复 `readonly`。
        multiple_readonly_modifiers,
        /// 重复 `abstract`。
        multiple_abstract_modifiers,
        /// 重复 `static`。
        multiple_static_modifiers,
        /// 重复 `final`。
        multiple_final_modifiers,
        /// `abstract` 类上的 `final`。
        final_on_abstract_class,
        /// `abstract` 类成员上的 `final`。
        final_on_abstract_member,
        /// 类常量上的非法修饰符（`static const` 等，`aux` 指向该修饰符）。
        invalid_const_modifier,
        /// 方法不能为 readonly（仅属性可为 readonly），`aux` 指向方法名。
        readonly_method,
        /// 属性钩子上的非法修饰符（`aux` 指向该修饰符）。
        hook_modifier,
        /// 未知钩子名（`aux` 指向钩子名）。
        unknown_hook,
        // 以下由旁路校验层 `semantic.check`（`src/semantic.zig`）报告——默认 parse
        // 不执行（parse 宽松），调用方按需开启。判据需整树/上下文/版本。
        /// `__construct` 不能 static。
        static_constructor,
        /// `__destruct` 不能 static。
        static_destructor,
        /// `__clone` 不能 static。
        static_clone,
        /// void 不能作参数类型。
        void_parameter,
        /// 变参（`...$x`）不能带默认值。
        variadic_default,
        /// try 块必须带 catch 或 finally。
        try_without_catch,
        /// 属性钩子列表 `{ }` 不能为空。
        hook_empty,
        /// get 钩子不能带参数表。
        hook_get_params,
        /// 声明多个属性时不能带钩子。
        hook_multi_property,
        /// 一条声明内的多个常量带注解（注解只能用于首个）。
        const_attr_multi,
        /// 保留名作类名（`aux` 指向该名字）。
        reserved_class_name,
        /// 保留名作接口名（`aux` 指向该名字）。
        reserved_interface_name,
        /// `use ... as self` 等特殊类名别名（`aux` 指向别名）。
        special_class_name_alias,
        /// __HALT_COMPILER() 只能在最外层作用域。
        halt_not_outermost,
        /// namespace 声明不能嵌套。
        namespace_nested,
        /// bracketed 与 unbracketed namespace 声明不能混用。
        namespace_mixed,
        /// unbracketed namespace 必须是脚本首个语句（declare(strict_types) 除外）。
        namespace_not_first,
        /// 出现 bracketed namespace 后，脚本其余部分不得再有代码。
        namespace_code_outside,
        /// `$a =& new B` 自 PHP 7.0 起禁止。
        assign_new_by_ref,
        /// 数组字面量空槽 `[1, , 2]` 自 PHP 8.0 起禁止（解构上下文合法）。
        array_empty_element,
        /// `|>` 右侧的箭头函数必须加括号（8.5）。
        pipe_arrow_unparenthesized,
        /// 尾随逗号不被允许（`[1,]` 等不接受尾逗号的位置）。
        trailing_comma,
        /// 非简单变量（`${expr}` 形态）在 PHP 7 起被禁止。
        non_simple_variable,

        // ---- 词法/解码诊断（`lexScanDiag`，解析前扫 token 流原文）----
        /// 未终止块注释。
        unterminated_comment,
        /// 非法字符（`data` 存 ASCII 码，`aux` 指向该字符 token）。
        unexpected_character,
        /// 空字节。
        unexpected_null_byte,
        /// 非法数字字面量（前导零含 8/9 等）。
        invalid_numeric_literal,
        /// 非法数字分隔符 `_`。
        invalid_numeric_separator,
        /// heredoc 缩进混用 tab 与空格。
        invalid_indentation_mixed,
        /// heredoc body 缩进不足（`data` 为最低要求级别）。
        invalid_indentation_level,
        /// `<?=` 被当标识符使用。
        short_echo_identifier,
        /// `\u{...}` 码点越界。
        invalid_utf8_codepoint,

        /// 该 tag 的消息**自含位置**（如 `on line N`），渲染时不追加
        /// ` from L:C to L:C` 后缀。判定集中在此，避免 `format` 与 `rawMessage`
        /// 各写一份自含位置的清单。
        pub fn discardsLocationSuffix(t: Tag) bool {
            return t == .invalid_utf8_codepoint;
        }
    };
};

/// 一个 AST 节点：扁平结构，`tag` 决定种类，`main_token` 为代表性 token（派生位置），
/// `data` 为小联合，最多承载 2 个直接子引用；更长负载存放于 `extra_data`。
pub const Node = struct {
    tag: Tag,
    main_token: TokenIndex,
    data: Data,

    /// 全部节点种类。每条 PHP 语法构造对应一个 `Tag`，遍历时用于 `switch` 穷举。
    pub const Tag = enum {
        root,

        // 语句
        stmt_expression,
        stmt_echo,
        stmt_if,
        stmt_while,
        stmt_for,
        stmt_foreach,
        stmt_function,
        stmt_class,
        stmt_enum,
        stmt_interface,
        stmt_trait,
        stmt_case,
        stmt_property,
        property_item, // 属性声明项：name token + optional default（多属性 `$a=1,$b=2` 各一项）
        property_hook,
        stmt_namespace,
        stmt_return,
        stmt_block,
        stmt_do,
        stmt_break,
        stmt_continue,
        stmt_switch,
        stmt_switch_case,
        stmt_default,
        stmt_throw,
        stmt_try,
        stmt_catch,
        stmt_const,
        const_decl,
        stmt_use,
        use_use,
        stmt_group_use,
        stmt_trait_use,
        trait_use_adaptation_alias,
        trait_use_adaptation_precedence,
        stmt_declare,
        declare_declare,
        stmt_goto,
        stmt_label,
        stmt_global,
        stmt_static,
        static_var,
        stmt_unset,
        stmt_halt,
        inline_html,
        stmt_nop,
        stmt_method,
        stmt_class_const,
        stmt_error,

        // 表达式
        expr_variable,
        expr_variable_ref, // 间接变量 $$a / ${expr}：name 为子节点（对齐 php-parser Expr_Variable）
        expr_int,
        expr_float,
        expr_string,
        expr_const_fetch,
        expr_binary,
        expr_assign,
        expr_assign_op,
        expr_assign_ref,
        expr_unary,
        expr_array,
        expr_array_item,
        expr_array_dim_fetch,
        expr_func_call,
        expr_new,
        expr_property_fetch,
        expr_static_property_fetch,
        expr_class_const_fetch,
        expr_static_call,
        expr_method_call,
        expr_nullsafe_property_fetch,
        expr_nullsafe_method_call,
        expr_match,
        expr_match_arm,
        expr_first_class_callable,
        expr_variadic_placeholder, // first-class callable 的 `...` 占位（方法/静态调用/new 的 args 元素）
        expr_array_hole, // 解构空槽 `[ , $a]`（list/数组赋值左侧，php-parser ArrayItem value=null）
        expr_closure,
        expr_arrow_function,
        expr_clone,
        expr_pipe,
        expr_isset,
        expr_empty,
        expr_eval,
        expr_exit,
        expr_include,
        expr_instanceof,
        expr_list,
        expr_ternary,
        expr_throw,
        expr_print,
        expr_shell_exec,
        expr_yield,
        expr_yield_from,
        expr_error_suppress,
        expr_post_inc,
        expr_post_dec,
        expr_cast,
        expr_argument,
        expr_encapsed,
        expr_string_part,
        expr_magic_const,

        // 杂项
        name,
        name_fully_qualified,
        name_relative,
        name_var_like,
        param,
        type_name,
        type_nullable,
        type_union,
        type_intersection,
        type_self,
        type_parent,
        type_static,
        type_array_of,
        type_generic,
        attribute,
        attr_group,
    };

    /// 小联合：节点的直接子引用（0–2 个），字段均为索引或 token 下标，故 `Node` 定长。
    /// 命名：`node` 必含子节点；`opt_node` 可选；`token` 主 token 以外的次要 token；
    /// `extra`/`extra_range` 指向 `extra_data` 的负载/区间。
    pub const Data = union {
        node: Index,
        opt_node: OptionalIndex,
        token: TokenIndex,
        node_and_node: struct { Index, Index },
        opt_node_and_opt_node: struct { OptionalIndex, OptionalIndex },
        node_and_opt_node: struct { Index, OptionalIndex },
        opt_node_and_node: struct { OptionalIndex, Index },
        node_and_extra: struct { Index, ExtraIndex },
        node_and_range: struct { node: Index, range: SubRange },
        extra_and_node: struct { ExtraIndex, Index },
        extra_and_opt_node: struct { ExtraIndex, OptionalIndex },
        /// 区间 + 尾部定界符 token：用于「列表 + 闭合符」的节点（数组字面量
        /// `[...]`/`array(...)`、`list(...)`），闭合符供 `lastToken` 取全区间。
        extra_and_token: struct { SubRange, TokenIndex },
        node_and_token: struct { Index, TokenIndex },
        token_and_node: struct { TokenIndex, Index },
        token_and_token: struct { TokenIndex, TokenIndex },
        opt_node_and_token: struct { OptionalIndex, TokenIndex },
        opt_token_and_node: struct { OptionalTokenIndex, Index },
        opt_token_and_opt_node: struct { OptionalTokenIndex, OptionalIndex },
        opt_token_and_opt_token: struct { OptionalTokenIndex, OptionalTokenIndex },
        extra_range: SubRange,
        extra: ExtraIndex,
    };
};

/// 节点数组（结构数组），`Node` 按 `Index` 顺序存放。
pub const NodeList = std.MultiArrayList(Node);

/// 源码中某位置的诊断信息（行/列），供错误渲染使用。
pub const Location = struct {
    line: usize,
    column: usize,
    line_start: usize,
    line_end: usize,
};

/// 返回某节点种类的「引入版本」。基础语法（≤ PHP 8.0）返回 `BASE_VERSION`(id=0)，
/// 表示不携带版本信息；8.1 及以后引入的节点类型记录对应版本。
///
/// 与「节点结构无关」的版本差异（如 `new` 的无括号形式，PHP 8.4）无法由 tag 区分，
/// 由解析点在 `addNode` 之后按需覆盖（见 parser_expr.zig 的 `expr_new`）。
pub fn tagVersion(tag: Node.Tag) PhpVersion {
    return switch (tag) {
        // 8.1 引入的新节点类型
        .stmt_enum, .stmt_case => PhpVersion.fromComponents(8, 1),
        .expr_first_class_callable, .expr_variadic_placeholder => PhpVersion.fromComponents(8, 1),
        .type_intersection => PhpVersion.fromComponents(8, 1),
        // 属性钩子节点本身即 8.4 引入
        .property_hook => PhpVersion.fromComponents(8, 4),
        // 管道运算符为 8.5 引入（无括号 new 的 8.4 覆盖在解析点处理）
        .expr_pipe => PhpVersion.fromComponents(8, 5),
        // 其余节点默认基础语法；其 8.x 特例形式在解析点覆盖（如 expr_new 无括号=8.4）
        else => BASE_VERSION,
    };
}

/// `forEachChild` 的区间型重载：把 `extra_data` 中的节点索引区间逐个子节点发出。
fn emitRange(
    tree: Ast,
    range: SubRange,
    ctx: anytype,
    comptime onChild: fn (@TypeOf(ctx), Index) anyerror!void,
) !void {
    for (tree.extraDataSlice(range, Index)) |n| try onChild(ctx, n);
}

/// `forEachChild` 的可选节点重载：存在则发出，否则跳过。
fn emitOpt(
    opt: OptionalIndex,
    ctx: anytype,
    comptime onChild: fn (@TypeOf(ctx), Index) anyerror!void,
) !void {
    if (opt.unwrap()) |n| try onChild(ctx, n);
}

/// 沿子节点递归，把遇到的最小 token 下标写入 `first`。
/// 每个节点自身的主 token 也参与比较——子节点的主 token 可能小于父节点
/// （如 `expr_assign` 的主 token 是 `=`，而左值 `$a` 在它之前）。
fn scanFirstToken(tree: Ast, node: Index, first: *TokenIndex) void {
    const mt = tree.nodeMainToken(node);
    if (mt < first.*) first.* = mt;

    const Ctx = struct {
        tree: Ast,
        first: *TokenIndex,
        fn onChild(self: @This(), child: Index) !void {
            scanFirstToken(self.tree, child, self.first);
        }
    };
    tree.forEachChild(node, Ctx{ .tree = tree, .first = first }, Ctx.onChild) catch {};
}

/// 沿子节点递归，把遇到的最大 token 下标写入 `last`（逻辑同 `scanFirstToken`）。
/// 尾部定界符不是任何节点的子节点，故每层都要单独并入，否则含块的复合语句
/// 会在 `}` 之前截断。
fn scanLastToken(tree: Ast, node: Index, last: *TokenIndex) void {
    const mt = tree.nodeMainToken(node);
    if (mt > last.*) last.* = mt;
    if (tree.trailingDelimiter(node)) |t| {
        if (t > last.*) last.* = t;
    }

    const Ctx = struct {
        tree: Ast,
        last: *TokenIndex,
        fn onChild(self: @This(), child: Index) !void {
            scanLastToken(self.tree, child, self.last);
        }
    };
    tree.forEachChild(node, Ctx{ .tree = tree, .last = last }, Ctx.onChild) catch {};
}

/// 解析结果：一棵完整的 PHP AST，持有 `tokens`/`nodes`/`extra_data`/`errors`，
/// 以及 `version` 与根节点 `root`。用毕调用 `deinit(gpa)` 释放。
pub const Ast = struct {
    source: [:0]const u8,
    tokens: Token.TokenList.Slice,
    nodes: NodeList.Slice,
    extra_data: []u32,
    errors: []const Error,
    /// 与 `nodes` 等长：按节点顺序记录「引入版本」；`BASE_VERSION`(id=0) 表示基础语法。
    node_versions: []PhpVersion,
    version: PhpVersion,
    root: Index,

    /// 取某 token 的种类。
    pub fn tokenTag(tree: *const Ast, token_index: TokenIndex) Token.Tag {
        return tree.tokens.items(.tag)[token_index];
    }

    /// 取某 token 的起始字节偏移。
    pub fn tokenStart(tree: *const Ast, token_index: TokenIndex) ByteOffset {
        return @intCast(tree.tokens.items(.start)[@intCast(token_index)]);
    }

    /// 取某 token 的结束字节偏移（开区间）。
    pub fn tokenEnd(tree: *const Ast, token_index: TokenIndex) ByteOffset {
        return @intCast(tree.tokens.items(.end)[@intCast(token_index)]);
    }

    /// 取某节点的种类。
    pub fn nodeTag(tree: *const Ast, node: Index) Node.Tag {
        return tree.nodes.items(.tag)[@intFromEnum(node)];
    }

    /// 取某节点的主 token 下标。
    pub fn nodeMainToken(tree: *const Ast, node: Index) TokenIndex {
        return tree.nodes.items(.main_token)[@intFromEnum(node)];
    }

    /// 取某节点的 `data` 联合（直接子引用）。
    pub fn nodeData(tree: *const Ast, node: Index) Node.Data {
        return tree.nodes.items(.data)[@intFromEnum(node)];
    }

    /// 取某节点的「引入版本」。`id == 0`（`BASE_VERSION`）表示基础语法，未单独记录版本。
    /// 用于下游自行做兼容性判断，本库不做门控。
    pub fn nodeVersion(tree: *const Ast, node: Index) PhpVersion {
        return tree.node_versions[@intFromEnum(node)];
    }

    /// 从 `extra_data[index]` 按字段顺序反序列化一段 `Components` 负载。
    /// 各字段按其类型原样存为 `u32`（枚举/下标取枚举值，`bool` 取 0/1），
    /// 读取时按同序还原，调用方无需手写偏移。
    pub fn extraData(tree: Ast, index: ExtraIndex, comptime T: type) T {
        var result: T = undefined;
        var slot: usize = @intFromEnum(index);
        inline for (std.meta.fields(T)) |field| {
            @field(result, field.name) = switch (field.type) {
                Index,
                OptionalIndex,
                OptionalTokenIndex,
                ExtraIndex,
                => @enumFromInt(tree.extra_data[slot]),
                u32,
                => tree.extra_data[slot],
                bool => tree.extra_data[slot] != 0,
                SubRange => .{
                    .start = @enumFromInt(tree.extra_data[slot]),
                    .end = @enumFromInt(tree.extra_data[slot + 1]),
                },
                else => @compileError("unsupported extra field type: " ++ @typeName(field.type)),
            };
            slot += switch (field.type) {
                SubRange => 2,
                else => 1,
            };
        }
        return result;
    }

    /// 把 `extra_data` 中的一段区间按类型 `T` 重解释为切片（元素均为 `u32` 大小，
    /// 可直接按 4 字节步长重解释，无需逐元素转换）。
    pub fn extraDataSlice(tree: Ast, range: SubRange, comptime T: type) []const T {
        return @ptrCast(tree.extra_data[@intFromEnum(range.start)..@intFromEnum(range.end)]);
    }

    /// `listSlice` 的便捷包装：把 `ListRange` 当成 `SubRange` 处理。
    pub fn listSlice(tree: Ast, range: ListRange, comptime T: type) []const T {
        return tree.extraDataSlice(.{ .start = range.start, .end = range.end }, T);
    }

    /// 取根节点下的顶层语句列表。
    pub fn rootStmts(tree: Ast) []const Index {
        const range = tree.nodeData(tree.root).extra_range;
        return tree.extraDataSlice(range, Index);
    }

    /// 遍历 `node` 的全部直接子节点，逐个交给 `onChild(ctx, child)`。
    ///
    /// 这是「某节点的直接子引用有哪些」的唯一事实来源：`walk`、`firstToken`、
    /// `lastToken` 均构建于其上。采用访问者而非返回切片，是为了**零分配**——
    /// 子节点最多数十个，走栈即可，无需为此申请内存。
    ///
    /// 叶子（字面量、名字、伪类型等仅含主 token 的节点）不产生任何子节点。
    pub fn forEachChild(
        tree: Ast,
        node: Index,
        ctx: anytype,
        comptime onChild: fn (@TypeOf(ctx), Index) anyerror!void,
    ) !void {
        const data = tree.nodeData(node);
        switch (tree.nodeTag(node)) {
            // 区间型子节点（列表 / 多表达式节点）
            .root,
            .expr_isset,
            .expr_encapsed,
            .expr_shell_exec,
            .attr_group,
            => try emitRange(tree, data.extra_range, ctx, onChild),
            // 数组字面量与 list 解构：区间 + 闭合符（`]`/`)`），闭合符供
            // `lastToken` 覆盖完整源码区间用（见 `trailingDelimiter`）。
            .expr_array, .expr_list => try emitRange(tree, data.extra_and_token[0], ctx, onChild),
            .expr_empty => {
                // `empty($x)` 单一操作数（与 expr_isset 的多元素列表不同）。
                try onChild(ctx, data.node);
            },

            // 单一可选子表达式
            .expr_exit => try emitOpt(data.opt_node, ctx, onChild),
            .stmt_return, .stmt_break, .stmt_continue => try emitOpt(data.opt_node_and_token[0], ctx, onChild),

            // 语句块：定界符存于 Components，仅语句列表为子节点
            .stmt_block => {
                const c = tree.extraData(data.extra, stmt.BlockComponents);
                try emitRange(tree, c.stmts, ctx, onChild);
            },

            // 单子表达式（operand 承载在 data.node）
            .expr_const_fetch,
            .expr_unary,
            .expr_eval,
            .expr_include,
            .expr_throw,
            .expr_print,
            .expr_error_suppress,
            .expr_post_inc,
            .expr_post_dec,
            .expr_cast,
            .expr_first_class_callable,
            .expr_yield_from,
            .type_name,
            .type_nullable,
            .type_array_of,
            => try onChild(ctx, data.node),

            // 控制流：拆分 Components 取子
            .stmt_if => {
                const c = tree.extraData(data.extra_and_opt_node[0], stmt.IfComponents);
                try onChild(ctx, c.cond);
                try onChild(ctx, c.then_body);
                try emitOpt(c.else_body, ctx, onChild);
            },
            .stmt_while => {
                const c = tree.extraData(data.extra_and_node[0], stmt.WhileComponents);
                try onChild(ctx, c.cond);
                try onChild(ctx, c.body);
            },
            .stmt_for => {
                const c = tree.extraData(data.extra_and_node[0], stmt.ForComponents);
                try emitRange(tree, c.init, ctx, onChild);
                try emitRange(tree, c.cond, ctx, onChild);
                try emitRange(tree, c.inc, ctx, onChild);
                try onChild(ctx, c.body);
            },
            .stmt_foreach => {
                const c = tree.extraData(data.extra_and_node[0], stmt.ForeachComponents);
                try onChild(ctx, c.expr);
                try emitOpt(c.key, ctx, onChild);
                try onChild(ctx, c.value);
                try onChild(ctx, c.body);
            },
            .stmt_namespace => {
                const c = tree.extraData(data.extra_and_opt_node[0], stmt.NamespaceComponents);
                try emitOpt(data.extra_and_opt_node[1], ctx, onChild);
                try emitRange(tree, c.stmts, ctx, onChild);
            },

            // 声明
            .stmt_function => {
                const c = tree.extraData(data.extra_and_opt_node[0], decl.FunctionComponents);
                try emitRange(tree, c.attrs, ctx, onChild);
                try emitRange(tree, c.params, ctx, onChild);
                try emitOpt(c.ret, ctx, onChild);
                try emitOpt(c.body, ctx, onChild);
            },
            .stmt_method => {
                const c = tree.extraData(data.extra_and_opt_node[0], decl.MethodComponents);
                try emitRange(tree, c.attrs, ctx, onChild);
                try emitRange(tree, c.params, ctx, onChild);
                try emitOpt(c.ret, ctx, onChild);
                try emitOpt(c.body, ctx, onChild);
            },
            .stmt_class => {
                const c = tree.extraData(data.extra_and_opt_node[0], decl.ClassComponents);
                try emitRange(tree, c.attrs, ctx, onChild);
                try emitOpt(c.extends, ctx, onChild);
                try emitRange(tree, c.implements, ctx, onChild);
                try emitRange(tree, c.stmts, ctx, onChild);
            },
            .stmt_interface, .stmt_trait, .stmt_enum => {
                const c = tree.extraData(data.extra_and_opt_node[0], decl.TypeDeclComponents);
                try emitRange(tree, c.attrs, ctx, onChild);
                try emitOpt(c.backing, ctx, onChild);
                try emitRange(tree, c.ext_impl, ctx, onChild);
                try emitRange(tree, c.stmts, ctx, onChild);
            },
            .stmt_property => {
                const c = tree.extraData(data.extra_and_opt_node[0], decl.PropertyComponents);
                try emitOpt(c.type, ctx, onChild);
                try emitRange(tree, c.props, ctx, onChild);
                try emitRange(tree, c.hooks, ctx, onChild);
                try emitRange(tree, c.attrs, ctx, onChild);
            },
            .property_item => try emitOpt(data.opt_node_and_token[0], ctx, onChild),
            .stmt_case => {
                const c = tree.extraData(data.extra_and_opt_node[0], decl.CaseComponents);
                try emitOpt(c.value, ctx, onChild);
                try emitRange(tree, c.attrs, ctx, onChild);
            },
            .stmt_class_const => {
                const c = tree.extraData(data.extra_and_opt_node[0], decl.ClassConstComponents);
                try emitOpt(c.type, ctx, onChild);
                try emitRange(tree, c.decls, ctx, onChild);
                try emitRange(tree, c.attrs, ctx, onChild);
            },

            // 语句
            .stmt_do => {
                const c = tree.extraData(data.extra, stmt.DoComponents);
                try onChild(ctx, c.body);
                try onChild(ctx, c.cond);
            },
            .stmt_switch => {
                const c = tree.extraData(data.extra_and_node[0], stmt.SwitchComponents);
                try onChild(ctx, data.extra_and_node[1]); // cond
                try emitRange(tree, c.cases, ctx, onChild);
            },
            .stmt_switch_case => {
                const c = tree.extraData(data.extra_and_opt_node[0], stmt.CaseStmtComponents);
                try emitOpt(data.extra_and_opt_node[1], ctx, onChild); // value
                try emitRange(tree, c.stmts, ctx, onChild);
            },
            .stmt_default => try emitRange(tree, data.extra_range, ctx, onChild),
            .stmt_expression, .stmt_throw => try onChild(ctx, data.node_and_token[0]),
            // 列表型语句：列表经 Components 承载（尾部分号亦在其中）
            .stmt_echo => try emitRange(tree, tree.extraData(data.extra, stmt.EchoComponents).exprs, ctx, onChild),
            .stmt_const => {
                const c = tree.extraData(data.extra, stmt.ConstComponents);
                try emitRange(tree, c.attrs, ctx, onChild);
                try emitRange(tree, c.decls, ctx, onChild);
            },
            .stmt_global => try emitRange(tree, tree.extraData(data.extra, stmt.GlobalComponents).vars, ctx, onChild),
            .stmt_static => try emitRange(tree, tree.extraData(data.extra, stmt.StaticComponents).vars, ctx, onChild),
            .stmt_unset => try emitRange(tree, tree.extraData(data.extra, stmt.UnsetComponents).vars, ctx, onChild),
            .stmt_try => {
                const c = tree.extraData(data.extra_and_node[0], stmt.TryComponents);
                try onChild(ctx, data.extra_and_node[1]); // body
                try emitRange(tree, c.catches, ctx, onChild);
                try emitOpt(c.finally, ctx, onChild);
            },
            .stmt_catch => {
                const c = tree.extraData(data.extra_and_node[0], stmt.CatchComponents);
                try emitRange(tree, c.types, ctx, onChild);
                try onChild(ctx, data.extra_and_node[1]); // body
            },
            .const_decl => try onChild(ctx, data.node_and_token[0]), // value
            .stmt_use => {
                const c = tree.extraData(data.extra, stmt.UseComponents);
                try emitRange(tree, c.uses, ctx, onChild);
            },
            .use_use => try onChild(ctx, data.extra_and_node[1]), // name
            .stmt_group_use => {
                const c = tree.extraData(data.extra_and_node[0], stmt.GroupUseComponents);
                try onChild(ctx, data.extra_and_node[1]); // prefix
                try emitRange(tree, c.uses, ctx, onChild);
            },
            .stmt_trait_use => {
                const c = tree.extraData(data.extra, stmt.TraitUseComponents);
                try emitRange(tree, c.traits, ctx, onChild);
                try emitRange(tree, c.adaptations, ctx, onChild);
            },
            .trait_use_adaptation_alias, .trait_use_adaptation_precedence => {
                try emitOpt(data.extra_and_opt_node[1], ctx, onChild);
            },
            .stmt_declare => {
                const c = tree.extraData(data.extra_and_opt_node[0], stmt.DeclareComponents);
                try emitOpt(data.extra_and_opt_node[1], ctx, onChild); // stmts
                try emitRange(tree, c.declares, ctx, onChild);
            },
            .declare_declare => try onChild(ctx, data.node_and_token[0]), // value
            .stmt_goto, .stmt_label, .stmt_halt, .inline_html, .stmt_nop, .stmt_error => {},
            .static_var => try emitOpt(tree.extraData(data.extra, stmt.StaticVarComponents).default, ctx, onChild),
            .property_hook => {
                const c = tree.extraData(data.extra_and_opt_node[0], decl.PropertyHookComponents);
                try emitOpt(data.extra_and_opt_node[1], ctx, onChild); // 体（abstract 钩子为空）
                try emitRange(tree, c.params, ctx, onChild);
                try emitRange(tree, c.attrs, ctx, onChild);
            },

            // 类型
            .type_union, .type_intersection => {
                try onChild(ctx, data.node_and_node[0]);
                try onChild(ctx, data.node_and_node[1]);
            },
            .type_generic => {
                const g = tree.extraData(data.extra_and_node[0], types.GenericTypeComponents);
                try onChild(ctx, data.extra_and_node[1]);
                try emitRange(tree, g.args, ctx, onChild);
            },
            .type_self, .type_parent, .type_static => {},

            // 名字（叶子）
            .name, .name_fully_qualified, .name_relative, .name_var_like => {},

            // 参数
            .param => {
                const c = tree.extraData(data.extra_and_opt_node[0], decl.ParamComponents);
                try emitOpt(c.type, ctx, onChild);
                try emitOpt(c.default, ctx, onChild);
                try emitRange(tree, c.hooks, ctx, onChild);
                try emitRange(tree, c.attrs, ctx, onChild);
            },

            // 属性
            .attribute => {
                const c = tree.extraData(data.extra_and_node[0], decl.AttributeComponents);
                try onChild(ctx, data.extra_and_node[1]);
                try emitRange(tree, c.args, ctx, onChild);
            },

            // 间接变量 `$$a`/`${expr}`（php-parser 同归 Expr_Variable）：name 是子节点，
            // 递归表达嵌套（`$$$a` → ref(ref(variable))）。简单 `$a` 见下方叶子组。
            .expr_variable_ref => try onChild(ctx, data.node),

            // 一元 / 字面量叶子（简单 `$a` 名字即 token，无子节点）
            .expr_variable,
            .expr_int,
            .expr_float,
            .expr_string,
            .expr_string_part,
            .expr_magic_const,
            .expr_variadic_placeholder,
            .expr_array_hole,
            => {},

            // 调用类（callee + 参数列表）
            .expr_func_call,
            .expr_method_call,
            .expr_nullsafe_method_call,
            => {
                try onChild(ctx, data.node_and_range.node);
                try emitRange(tree, data.node_and_range.range, ctx, onChild);
            },
            .expr_static_call => {
                const c = tree.extraData(data.node_and_extra[1], expr.StaticCallComponents);
                try onChild(ctx, data.node_and_extra[0]);
                try emitRange(tree, c.args, ctx, onChild);
            },
            .expr_new => {
                const c = tree.extraData(data.extra_and_node[0], expr.NewComponents);
                try onChild(ctx, data.extra_and_node[1]);
                try emitRange(tree, c.args, ctx, onChild);
            },

            // 数组 / 列表 / 项 / 实参
            .expr_argument => try onChild(ctx, data.node_and_extra[0]),
            .expr_array_item => {
                const c = tree.extraData(data.node_and_extra[1], expr.ArrayItemComponents);
                try onChild(ctx, data.node_and_extra[0]);
                try emitOpt(c.key, ctx, onChild);
            },
            .expr_clone => {
                // `clone $x` 一元：子节点即操作数。8.5 括号式 `clone($x, withProperties:)`
                // 走 FuncCall 路径（见 parser_expr.zig kw_clone），不会产出 expr_clone。
                try onChild(ctx, data.node);
            },

            // 双目 / 赋值 / 访问类（node_and_node）
            .expr_binary,
            .expr_pipe,
            .expr_assign,
            .expr_assign_op,
            .expr_assign_ref,
            .expr_property_fetch,
            .expr_static_property_fetch,
            .expr_nullsafe_property_fetch,
            .expr_class_const_fetch,
            .expr_instanceof,
            => {
                try onChild(ctx, data.node_and_node[0]);
                try onChild(ctx, data.node_and_node[1]);
            },
            .expr_array_dim_fetch => {
                try onChild(ctx, data.node_and_opt_node[0]);
                try emitOpt(data.node_and_opt_node[1], ctx, onChild);
            },

            // match
            .expr_match => {
                const c = tree.extraData(data.extra_and_node[0], expr.MatchComponents);
                try onChild(ctx, data.extra_and_node[1]);
                try emitRange(tree, c.arms, ctx, onChild);
            },
            .expr_match_arm => {
                const c = tree.extraData(data.extra_and_node[0], expr.MatchArmComponents);
                try onChild(ctx, data.extra_and_node[1]);
                try emitRange(tree, c.exprs, ctx, onChild);
            },
            .expr_ternary => {
                const c = tree.extraData(data.node_and_extra[1], expr.TernaryComponents);
                try onChild(ctx, data.node_and_extra[0]);
                try emitOpt(c.then, ctx, onChild);
                try onChild(ctx, c.else_b);
            },

            // yield / 闭包
            .expr_yield => {
                const c = tree.extraData(data.extra, expr.YieldComponents);
                try emitOpt(c.key, ctx, onChild);
                try emitOpt(c.value, ctx, onChild);
            },
            .expr_closure => {
                const c = tree.extraData(data.extra, expr.ClosureComponents);
                try emitRange(tree, c.params, ctx, onChild);
                try emitOpt(c.ret, ctx, onChild);
                try onChild(ctx, c.body);
                try emitRange(tree, c.attrs, ctx, onChild);
            },
            .expr_arrow_function => {
                const c = tree.extraData(data.extra, expr.ArrowFunctionComponents);
                try emitRange(tree, c.params, ctx, onChild);
                try emitOpt(c.ret, ctx, onChild);
                try onChild(ctx, c.body);
                try emitRange(tree, c.attrs, ctx, onChild);
            },
        }
    }

    /// 取某节点覆盖的首个 token 下标（含其全部后代）。
    ///
    /// `main_token` 只是节点的**代表性** token（如二元运算的运算符），并非起始位置；
    /// 本函数沿子节点递归取最小值，得到真正的区间左端。
    pub fn firstToken(tree: Ast, node: Index) TokenIndex {
        if (tree.nodeTag(node) == .root) {
            const s = tree.rootStmts();
            if (s.len == 0) return 0;
            return tree.firstToken(s[0]);
        }
        var first = tree.nodeMainToken(node);
        scanFirstToken(tree, node, &first);
        return first;
    }

    /// 取某节点覆盖的末个 token 下标（含其全部后代），逻辑同 `firstToken`。
    ///
    /// 二者合用即得节点的完整源码区间 `[firstToken, lastToken]`，可用于区间高亮、
    /// 代码改写等场景。
    pub fn lastToken(tree: Ast, node: Index) TokenIndex {
        if (tree.nodeTag(node) == .root) {
            const s = tree.rootStmts();
            if (s.len == 0) return 0;
            return tree.lastToken(s[s.len - 1]);
        }
        var last = tree.nodeMainToken(node);
        scanLastToken(tree, node, &last);
        return last;
    }

    /// 取节点的**名字 token**（函数名、类名、常量名、属性名、case 名等），无则 `null`。
    ///
    /// 名字是 token 而非子节点，故不出现在 `forEachChild` 里；但它是节点的核心信息，
    /// 检索与断点定位都需要。声明类节点的 `main_token` 往往是关键字（`function`、
    /// `class`），只靠它取不到名字。
    pub fn nameToken(tree: Ast, node: Index) ?TokenIndex {
        const data = tree.nodeData(node);
        return switch (tree.nodeTag(node)) {
            .stmt_function => tree.extraData(data.extra_and_opt_node[0], decl.FunctionComponents).name,
            .stmt_method => tree.extraData(data.extra_and_opt_node[0], decl.MethodComponents).name,
            .stmt_class => tree.extraData(data.extra_and_opt_node[0], decl.ClassComponents).name,
            .stmt_interface,
            .stmt_trait,
            .stmt_enum,
            => tree.extraData(data.extra_and_opt_node[0], decl.TypeDeclComponents).name,
            .stmt_property => blk: {
                const c = tree.extraData(data.extra_and_opt_node[0], decl.PropertyComponents);
                if (c.props.start == c.props.end) break :blk null;
                // props 为 addNodeList 连续节点，首项即 property_item：名字在其 opt_node_and_token[1]
                const first_item: Index = @enumFromInt(tree.extra_data[@intFromEnum(c.props.start)]);
                break :blk tree.nodeData(first_item).opt_node_and_token[1];
            },
            .property_item => data.opt_node_and_token[1],
            .stmt_class_const => blk: {
                const c = tree.extraData(data.extra_and_opt_node[0], decl.ClassConstComponents);
                if (c.decls.start == c.decls.end) break :blk null;
                // decls 区间内存的是节点下标（addNodeList 连续写入），首项即 const_decl。
                const first_item: Index = @enumFromInt(tree.extra_data[@intFromEnum(c.decls.start)]);
                break :blk tree.nodeData(first_item).node_and_token[1];
            },
            .stmt_case => tree.extraData(data.extra_and_opt_node[0], decl.CaseComponents).name,
            .const_decl, .declare_declare => data.node_and_token[1],
            .static_var => tree.extraData(data.extra, stmt.StaticVarComponents).name,
            .trait_use_adaptation_alias => tree.extraData(data.extra_and_opt_node[0], stmt.TraitAdaptAliasComponents).method,
            .trait_use_adaptation_precedence => tree.extraData(data.extra_and_opt_node[0], stmt.TraitAdaptPrecComponents).method,
            .param => tree.extraData(data.extra_and_opt_node[0], decl.ParamComponents).name,
            else => null,
        };
    }

    /// 取节点的尾部定界符 token（分号、右花括号等），无则 `null`。
    ///
    /// 定界符不是任何节点的子节点，故不计入 `forEachChild`；但要让 `lastToken`
    /// 覆盖完整源码区间就必须单独取回。未列出者（叶子表达式、`switch` 的
    /// `case`/`default` 等以冒号收尾的构造）返回 `null`。
    pub fn trailingDelimiter(tree: Ast, node: Index) ?TokenIndex {
        const data = tree.nodeData(node);
        return switch (tree.nodeTag(node)) {
            // 定界符记在 Components 内
            .stmt_block => tree.extraData(data.extra, stmt.BlockComponents).rbrace,
            .stmt_do => tree.extraData(data.extra, stmt.DoComponents).semi,
            .stmt_use => tree.extraData(data.extra, stmt.UseComponents).semi,
            .stmt_group_use => tree.extraData(data.extra_and_node[0], stmt.GroupUseComponents).semi,
            .stmt_trait_use => tree.extraData(data.extra, stmt.TraitUseComponents).semi,
            .stmt_declare => tree.extraData(data.extra_and_opt_node[0], stmt.DeclareComponents).semi,
            .stmt_namespace => tree.extraData(data.extra_and_opt_node[0], stmt.NamespaceComponents).close,
            .stmt_echo => tree.extraData(data.extra, stmt.EchoComponents).semi,
            .stmt_const => tree.extraData(data.extra, stmt.ConstComponents).semi,
            .stmt_global => tree.extraData(data.extra, stmt.GlobalComponents).semi,
            .stmt_static => tree.extraData(data.extra, stmt.StaticComponents).semi,
            .stmt_unset => tree.extraData(data.extra, stmt.UnsetComponents).semi,
            .stmt_property => tree.extraData(data.extra_and_opt_node[0], decl.PropertyComponents).semi,
            .stmt_class_const => tree.extraData(data.extra_and_opt_node[0], decl.ClassConstComponents).semi,
            .stmt_case => tree.extraData(data.extra_and_opt_node[0], decl.CaseComponents).semi,

            // 数组字面量 `[...]` / `array(...)` / `list(...)` 的闭合符
            .expr_array, .expr_list => data.extra_and_token[1],

            // 限定名的 `data.token` 是末段（如 `Foo\Bar` 的 `Bar`），必须计入区间，
            // 否则名字只覆盖到首段，下游按区间取名字文本会得到 `Foo`。
            .name, .name_fully_qualified, .name_relative, .name_var_like => data.token,

            // 定界符记在 data 的 token 槽位
            .stmt_expression, .stmt_throw, .const_decl, .declare_declare => data.node_and_token[1],
            .stmt_return, .stmt_break, .stmt_continue => data.opt_node_and_token[1],
            .stmt_goto, .stmt_halt => data.token_and_token[1],

            else => null,
        };
    }

    /// 计算某 token 在源码中的行列位置。从 `start_offset` 起扫描换行定位所在行，
    /// 再算出列号与行起止偏移。位置现算，不冗余存储。
    pub fn tokenLocation(tree: Ast, start_offset: ByteOffset, token_index: TokenIndex) Location {
        var loc = Location{
            .line = 0,
            .column = 0,
            .line_start = start_offset,
            .line_end = tree.source.len,
        };
        const token_start = tree.tokenStart(token_index);

        while (std.mem.findScalarPos(u8, tree.source, loc.line_start, '\n')) |i| {
            if (i >= token_start) break;
            loc.line += 1;
            loc.line_start = i + 1;
        }

        const offset = loc.line_start;
        for (tree.source[offset..], 0..) |c, i| {
            if (i + offset == token_start) {
                loc.line_end = i + offset;
                while (loc.line_end < tree.source.len and tree.source[loc.line_end] != '\n') {
                    loc.line_end += 1;
                }
                return loc;
            }
            if (c == '\n') {
                loc.line += 1;
                loc.column = 0;
                loc.line_start = i + 1;
            } else {
                loc.column += 1;
            }
        }
        return loc;
    }

    /// 取某 token 对应的源码切片（零拷贝）。
    pub fn tokenSlice(tree: Ast, token_index: TokenIndex) []const u8 {
        const start = tree.tokenStart(token_index);
        const end = tree.tokenEnd(token_index);
        return tree.source[start..end];
    }

    /// 取紧贴 `node` 之前、仅被注释隔开的 docblock token 下标（若有）。
    /// 注释始终作为 token 保留，下游按需向前扫描取回，节点结构保持清爽。
    pub fn docCommentBefore(tree: Ast, node: Index) ?TokenIndex {
        const ft = tree.firstToken(node);
        if (ft == 0) return null;
        var i = ft;
        while (i > 0) {
            i -= 1;
            const tg = tree.tokenTag(i);
            if (tg == .doc_comment) return i;
            if (tg == .comment) continue;
            break;
        }
        return null;
    }

    /// 释放整棵树占用的全部内存。调用方必须在 `parse` 返回的 `Ast` 使用完毕后
    /// 显式调用，传入与 `parse` 相同的 `gpa`。
    pub fn deinit(tree: *Ast, gpa: std.mem.Allocator) void {
        tree.tokens.deinit(gpa);
        tree.nodes.deinit(gpa);
        gpa.free(tree.extra_data);
        gpa.free(tree.errors);
        gpa.free(tree.node_versions);
        tree.* = undefined;
    }

    /// 解析入口。调用方经 `gpa` 提供分配器，`version` 控制 8.x 语法开关；
    /// 失败仅因内存不足（`ParseError == Allocator.Error`）。用毕调用 `deinit`。
    ///
    /// ```zig
    /// const tree = try php_ast.parse(gpa, "<?php $a = 1;", .{ .id = 80400 });
    /// defer tree.deinit(gpa);
    /// for (tree.rootStmts()) |stmt| {
    ///     std.debug.print("顶层语句种类: {}\n", .{tree.nodeTag(stmt)});
    /// }
    /// ```
    pub fn parse(gpa: std.mem.Allocator, source: [:0]const u8, version: PhpVersion) ParseError!Ast {
        // 先词法：结果暂存在 `Token.TokenList` 里。
        var tokens = Token.TokenList{};
        defer tokens.deinit(gpa);

        try Lexer.tokenize(gpa, source, &tokens);

        // 词法结果转为拥有所有权的切片交给解析器；失败由 errdefer 释放。
        var tokens_slice = tokens.toOwnedSlice();
        errdefer tokens_slice.deinit(gpa);

        return parseTokens(gpa, source, tokens_slice, version);
    }
};

/// 追加一条词法诊断（`lex_error`，单 token 区间）。
fn addLexError(gpa: std.mem.Allocator, errors: *std.ArrayList(Error), token: TokenIndex) !void {
    try addLexErrorEx(gpa, errors, .lex_error, token, token, token, 0);
}

/// 追加一条词法/解码诊断（可指定消息族、区间、附加 token 与数值参数）。
fn addLexErrorEx(
    gpa: std.mem.Allocator,
    errors: *std.ArrayList(Error),
    tag: Error.Tag,
    start: TokenIndex,
    end: TokenIndex,
    aux: TokenIndex,
    data: u32,
) !void {
    try errors.append(gpa, .{
        .tag = tag,
        .token = start,
        .token_end = end,
        .aux = aux,
        .data = data,
        .required = BASE_VERSION,
    });
}

/// 词法后置诊断：一次扫描 token 流，把「需看原文才能判定」的词法错误收集为
/// `lex_error`。判定项：
/// - `.invalid` token：lexer 无法归类的字符（控制字符 / 非 UTF-8 字节等）；
/// - `.comment` / `.doc_comment` 以 `/*` 开头但原文不含 `*/`：未终止注释；
/// - 数字字面量：前导零十进制（`0787`）、非法 `_` 分隔（连续/首尾）；
/// - 转义串（双引号 / heredoc / 反引号，nowdoc 除外）内 `\u{...}` 码点越界
///   （PHP 7.0 起，> 0x10FFFF 报 Invalid UTF-8 codepoint）；
/// - heredoc / nowdoc（PHP 7.3 flexible）body 缩进违规：行首 tab/space 混用，
///   行首缩进少于结束标签缩进。
/// 不修改 token 流，不中断解析（收集式模型）。
fn lexScanDiag(
    gpa: std.mem.Allocator,
    source: [:0]const u8,
    tokens: Token.TokenList.Slice,
    version: PhpVersion,
    errors: *std.ArrayList(Error),
) !void {
    const starts = tokens.items(.start);
    const ends = tokens.items(.end);
    const tags = tokens.items(.tag);

    // 当前打开的字符串语境（无嵌套，单一状态跟踪即可）：
    // - .dq：双引号 / b" / 反引号——内容做 \u{} 转义（v7.0+）；
    // - .heredoc：插值 heredoc——内容做 \u{} 转义 + flexible 缩进校验（v7.3+）；
    // - .nowdoc：内容原样——既不转义也不移除缩进，但 flexible 缩进校验照做；
    // - .none：字符串之外。
    const StrCtx = enum { none, dq, heredoc, nowdoc };
    var ctx: StrCtx = .none;
    var heredoc_body_start: usize = 0; // heredoc body 首行行首偏移（结束标签行换行后）

    var i: usize = 0;
    while (i < starts.len and tags[i] != .eof) : (i += 1) {
        const s = source[starts[i]..ends[i]];
        const ti: TokenIndex = @intCast(i);
        switch (tags[i]) {
            .invalid => blk: {
                // 非法字符：消息含字符原文与 ASCII 码（空字节另归一类）
                const b = if (s.len > 0) s[0] else 0;
                const tag: Error.Tag = if (b == 0) .unexpected_null_byte else .unexpected_character;
                try addLexErrorEx(gpa, errors, tag, ti, ti, ti, b);
                break :blk;
            },
            .comment, .doc_comment => {
                // 块注释未终止：以 /* 开头（含 /**）且全段无 */。行注释（// #）无闭合
                // 概念，不在此列。
                const is_block = std.mem.startsWith(u8, s, "/*") or std.mem.startsWith(u8, s, "/**");
                if (is_block and std.mem.indexOf(u8, s, "*/") == null) {
                    // 未终止注释延伸到文件尾（php-parser 报至 EOF）。其后是否补报
                    // `unexpected EOF` 取决于是否存在未闭合结构——那是语法层的事，
                    // 由 `parseBlock` 等在 EOF 处判定（见 `.unexpected_eof`）。
                    const last: TokenIndex = @intCast(starts.len - 1);
                    try addLexErrorEx(gpa, errors, .unterminated_comment, ti, last, ti, 0);
                }
            },
            .int_literal, .float_literal => {
                // 字面量内的 `_` 合法性不需在此判定：词法器只把「两侧都是数字」的 `_`
                // 并入字面量（`1_000`），其余（`100_`、`1__1`、`1._0`）在 `_` 处结束
                // 字面量，`_` 归标识符并由语法层报 unexpected T_STRING——与 php-parser
                // 的切分一致（其无「非法数字分隔符」专用消息）。
                // 非法前导零整数（PHP 7.0 起）：`0` 开头、无 0x/0b/0o 前缀的整数字面量
                // 中含 8/9 即报 invalid numeric literal（`0787`、`089`）；`000`/`0777`
                // 是合法八进制。对齐 php-parser（依赖宿主 PHP 词法）：0 前缀含 8/9 的
                // 数字按十进制读，若十进制值溢出 u64（如 `0177777777777777777777787`）
                // host 归为浮点 token（DNUMBER）、走 Float 解析不报；不溢出（LNUMBER）
                // 才报。8 出现与否对十进制溢出判定无影响，仅作为是否可能报错的标记。
                if (tags[i] == .int_literal and s.len >= 2 and s[0] == '0' and version.id >= 70000) {
                    const pfx = s[1] == 'x' or s[1] == 'X' or s[1] == 'b' or s[1] == 'B' or
                        s[1] == 'o' or s[1] == 'O';
                    if (!pfx) {
                        var acc: u64 = 0;
                        var overflow = false;
                        var has_89 = false;
                        for (s[1..]) |ch| {
                            if (ch == '_') continue;
                            if (ch == '8' or ch == '9') has_89 = true;
                            if (!overflow) {
                                acc = std.math.mul(u64, acc, 10) catch blk: {
                                    overflow = true;
                                    break :blk acc;
                                };
                                acc = std.math.add(u64, acc, ch - '0') catch blk: {
                                    overflow = true;
                                    break :blk acc;
                                };
                            }
                        }
                        if (has_89 and !overflow) {
                            try addLexErrorEx(gpa, errors, .invalid_numeric_literal, ti, ti, ti, 0);
                        }
                    }
                }
            },
            .string_start => {
                if (std.mem.startsWith(u8, s, "<<<")) {
                    // heredoc / nowdoc：`<<<'LABEL'` 是 nowdoc（引号紧跟 <<<）。
                    ctx = if (starts[i] + 3 < source.len and source[starts[i] + 3] == '\'')
                        .nowdoc
                    else
                        .heredoc;
                    // body 起点：结束标签行（label）的换行之后。
                    var e = ends[i];
                    while (e < source.len and source[e] != '\n') : (e += 1) {}
                    heredoc_body_start = if (e < source.len) e + 1 else e;
                } else {
                    ctx = .dq; // 双引号 / b" 前缀
                }
            },
            .string_end => {
                // flexible heredoc 缩进校验：回扫 body 原文（body 首行 → 结束标签行首）。
                if ((ctx == .heredoc or ctx == .nowdoc) and version.id >= 70300) {
                    try checkHeredocIndent(gpa, source, ti, starts[i], heredoc_body_start, errors);
                }
                ctx = .none;
            },
            .backtick => {
                if (ctx == .none) {
                    ctx = .dq; // 反引号 shell exec 开启（可转义）
                } else {
                    // 串内结束反引号：lexer 以 .backtick 收尾 shell exec
                    ctx = .none;
                }
            },
            .string_part => {
                // `\u{...}` 码点越界（PHP 7.0 起；nowdoc 不转义、5.6 下 \u 原样）。
                if (ctx != .none and ctx != .nowdoc and version.id >= 70000) {
                    try checkUnicodeEscape(gpa, s, ti, errors);
                }
            },
            else => {},
        }
    }
}

/// 扫描字符串字面片段中的 `\u{...}` 转义，码点 > 0x10FFFF 报 `lex_error`
/// （对齐 php-parser / PHP 7.0 的 Invalid UTF-8 codepoint escape sequence）。
fn checkUnicodeEscape(
    gpa: std.mem.Allocator,
    part: []const u8,
    token: TokenIndex,
    errors: *std.ArrayList(Error),
) !void {
    var pos: usize = 0;
    while (pos + 3 < part.len) : (pos += 1) {
        if (!std.mem.eql(u8, part[pos .. pos + 2], "\\u") or part[pos + 2] != '{') continue;
        const hex_start = pos + 3;
        var hex_end = hex_start;
        while (hex_end < part.len and part[hex_end] != '}') : (hex_end += 1) {}
        if (hex_end >= part.len) break; // 无闭合（php 报另一类错，暂不判）
        const digits = part[hex_start..hex_end];
        if (digits.len == 0 or digits.len > 16) {
            pos = hex_end;
            continue; // 空 / 超长：php 报 invalid sequence，暂只处理可解析的越界
        }
        var cp: u64 = 0;
        var valid = true;
        for (digits) |ch| {
            cp *|= 16;
            cp +|= switch (ch) {
                '0'...'9' => ch - '0',
                'a'...'f' => ch - 'a' + 10,
                'A'...'F' => ch - 'A' + 10,
                else => {
                    valid = false;
                    break;
                },
            };
        }
        if (valid and cp > 0x10FFFF) {
            try addLexErrorEx(gpa, errors, .invalid_utf8_codepoint, token, token, token, 0);
            return;
        }
        pos = hex_end;
    }
}

/// PHP 7.3 flexible heredoc / nowdoc 缩进校验（body 首行 → 结束标签行首）：
/// - 行首缩进 tab 与空格混用 → 报错；
/// - 行首缩进少于结束标签缩进 → 报错。
/// 空行（除空白外无内容）不校验。每个 heredoc 至多报一条（mixed 优先于缩进不足，
/// 对齐 php-parser 对整段产一条错误的语义）；错误定位取结束标签 token。
fn checkHeredocIndent(
    gpa: std.mem.Allocator,
    source: []const u8,
    tok: TokenIndex,
    label_start: usize,
    body_start: usize,
    errors: *std.ArrayList(Error),
) !void {
    if (body_start >= source.len) return;
    // 结束标签行缩进前缀作为基准（lexer 的 string_end token 起点在 label 文本处，
    // 前导缩进并入前一个 string_part，故 label 行行首到 string_end.start 是前缀）。
    var b0 = label_start;
    while (b0 > 0 and source[b0 - 1] != '\n') : (b0 -= 1) {}
    const prefix = source[b0..label_start]; // 全空白，base = prefix.len
    const base = prefix.len;
    var mixed = false;
    var under = false;
    var line = body_start;
    while (line < label_start) {
        var e = line;
        while (e < source.len and source[e] != '\n') : (e += 1) {}
        const row_end = @min(e, label_start);
        const row = source[line..row_end];
        // 行首缩进前缀
        var plen: usize = 0;
        var has_tab = false;
        var has_sp = false;
        while (plen < row.len and (row[plen] == ' ' or row[plen] == '\t')) : (plen += 1) {
            if (row[plen] == '\t') has_tab = true else has_sp = true;
        }
        // 空行（无内容）不校验。有内容时按 PHP flexible 规则：行首空白必须「以
        // label 前缀逐字符开头」；长度不足或前 base 字符类型不符都算违规（前缀
        // 内 tab/space 混用归类 mixed，长度不足归类缩进不足）。
        if (plen < row.len) {
            if (plen < base) {
                under = true;
            } else if (!std.mem.eql(u8, row[0..base], prefix)) {
                if (has_tab and has_sp) {
                    mixed = true;
                } else {
                    under = true;
                }
            }
        }
        if (e >= source.len) break;
        line = e + 1;
    }
    if (mixed) {
        try addLexErrorEx(gpa, errors, .invalid_indentation_mixed, tok, tok, tok, 0);
    } else if (under) {
        try addLexErrorEx(gpa, errors, .invalid_indentation_level, tok, tok, tok, @intCast(base));
    }
}


/// 在已有 token 切片上执行递归下降解析（私有，外部走 `parse`）。
/// `tokens` 移入返回的 `Ast`；临时 `nodes`/`extra_data`/`errors` 由 `defer` 释放，
/// 失败时 `errdefer` 兜底。
fn parseTokens(
    gpa: std.mem.Allocator,
    source: [:0]const u8,
    tokens: Token.TokenList.Slice,
    version: PhpVersion,
) ParseError!Ast {
    var p: parser.Parser = .{
        .gpa = gpa,
        .source = source,
        .tokens = tokens,
        .nodes = NodeList{},
        .extra_data = try std.ArrayList(u32).initCapacity(gpa, 0),
        .errors = try std.ArrayList(Error).initCapacity(gpa, 0),
        .node_versions = try std.ArrayList(PhpVersion).initCapacity(gpa, 0),
        .version = version,
        .tok_i = 0,
    };
    defer p.nodes.deinit(gpa);
    defer p.extra_data.deinit(gpa);
    defer p.errors.deinit(gpa);
    defer p.node_versions.deinit(gpa);

    // 词法后置诊断（解析前，一次扫描 token 流）：非法字符（lexer 记为 `.invalid`）、
    // 未终止注释、非法数字字面量——lexer 词法分析本身不中断、仅产出 token，这些
    // 需「扫描原文」才能判定的错误在此统一收集（`lex_error`）。不动 token 流，
    // 错误随收集式模型继续。
    try lexScanDiag(gpa, source, tokens, version, &p.errors);

    const root = try p.parseRoot();

    // 版本门控：把引入版本高于目标版本的节点上报为专用错误，交给调用方决定放行或拒绝。
    var i: usize = 0;
    while (i < p.node_versions.items.len) : (i += 1) {
        const nv = p.node_versions.items[i];
        if (nv.id != 0 and nv.id > version.id) {
            const mt = p.nodes.items(.main_token)[i];
            try p.errors.append(gpa, .{
                .tag = .unsupported_version,
                .token = mt,
                .token_end = mt,
                .aux = mt,
                .data = 0,
                .required = nv,
            });
        }
    }

    const extra_data = try p.extra_data.toOwnedSlice(gpa);
    errdefer gpa.free(extra_data);
    const errors = try p.errors.toOwnedSlice(gpa);
    errdefer gpa.free(errors);
    const node_versions = try p.node_versions.toOwnedSlice(gpa);
    errdefer gpa.free(node_versions);

    return Ast{
        .source = source,
        .tokens = tokens,
        .nodes = p.nodes.toOwnedSlice(),
        .extra_data = extra_data,
        .errors = errors,
        .node_versions = node_versions,
        .version = version,
        .root = root,
    };
}

// ===========================================================================
// 测试：AST 入口、版本门控与源码溯源
// ===========================================================================

test "ast :: root 与语句列表 :: 顶层语句按顺序挂到 root" {
    const gpa = std.testing.allocator;
    var tree = try Ast.parse(gpa, "<?php $a = 1; $b = 2;", testing.v84);
    defer tree.deinit(gpa);
    try testing.expectNoErrors(tree);

    try std.testing.expectEqual(.root, tree.nodeTag(tree.root));
    try std.testing.expectEqual(@as(usize, 2), tree.rootStmts().len);
}

test "ast :: node_versions :: 与 nodes 等长" {
    const gpa = std.testing.allocator;
    var tree = try Ast.parse(gpa, "<?php enum E { case A; }", testing.v84);
    defer tree.deinit(gpa);
    try testing.expectNoErrors(tree);
    try std.testing.expectEqual(tree.nodes.len, tree.node_versions.len);
}

/// 断言某 tag 的首个节点（按声明顺序）的引入版本为 `want`（0 = 基础语法）。
fn expectFirstNodeVersion(tree: Ast, tag: Node.Tag, want: u32) !void {
    for (tree.nodes.items(.tag), 0..) |t, i| {
        if (t == tag) {
            try std.testing.expectEqual(want, tree.node_versions[i].id);
            return;
        }
    }
    std.debug.print("\n节点未出现: {s}\n", .{@tagName(tag)});
    try std.testing.expect(false);
}

test "ast :: nodeVersion :: 标记节点引入版本" {
    const gpa = std.testing.allocator;
    // enum 与 enum case 为 8.1
    {
        var t = try Ast.parse(gpa, "<?php enum E { case A; }", testing.v84);
        defer t.deinit(gpa);
        try testing.expectNoErrors(t);
        try expectFirstNodeVersion(t, .stmt_enum, 80100);
        try expectFirstNodeVersion(t, .stmt_case, 80100);
    }
    // 无括号 new 本身是基础语法；8.4 只标记「无括号 new 后接链 token」的形态
    {
        var t = try Ast.parse(gpa, "<?php $x = new Foo;", testing.v84);
        defer t.deinit(gpa);
        try testing.expectNoErrors(t);
        try expectFirstNodeVersion(t, .expr_new, 0);
    }
    {
        var t = try Ast.parse(gpa, "<?php $y = new Bar->m();", testing.v84);
        defer t.deinit(gpa);
        try testing.expectNoErrors(t);
        try expectFirstNodeVersion(t, .expr_new, 80400);
    }
}

/// 词法/解码诊断条数（`lexScanDiag` 产出的那些 tag）。
fn countLexErrors(tree: Ast) usize {
    var n: usize = 0;
    for (tree.errors) |e| {
        switch (e.tag) {
            .lex_error, .unterminated_comment, .unexpected_character,
            .unexpected_null_byte, .invalid_numeric_literal, .invalid_numeric_separator,
            .invalid_indentation_mixed, .invalid_indentation_level,
            .short_echo_identifier, .invalid_utf8_codepoint => n += 1,
            else => {},
        }
    }
    return n;
}

test "lex :: 非法字符 :: 只报一条词法诊断，不附带 expected_expr" {
    const gpa = std.testing.allocator;
    // php-parser 由宿主词法报错后不再额外产出语法错误：非法字符处应恰好一条
    // 诊断（消息含字符原文与 ASCII 码）。
    var t = try Ast.parse(gpa, "<?php \x01 ;", .{ .id = 80500 });
    defer t.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 1), countLexErrors(t));
    var n_expr: usize = 0;
    for (t.errors) |e| {
        if (e.tag == .expected_expr) n_expr += 1;
    }
    try std.testing.expectEqual(@as(usize, 0), n_expr);
}

test "lex :: 前导零整数 8/9 :: 7.0 起报、5.6 合法、八进制合法" {
    const gpa = std.testing.allocator;
    var t7 = try Ast.parse(gpa, "<?php 0787;", .{ .id = 70000 });
    defer t7.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 1), countLexErrors(t7));

    var t85 = try Ast.parse(gpa, "<?php 089;", .{ .id = 80500 });
    defer t85.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 1), countLexErrors(t85));

    var t56 = try Ast.parse(gpa, "<?php 0787;", .{ .id = 50600 });
    defer t56.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 0), countLexErrors(t56));

    var ok = try Ast.parse(gpa, "<?php 0777; 0; 0x78; 0o12;", .{ .id = 80500 });
    defer ok.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 0), countLexErrors(ok));
}

test "lex :: 转义串 \\u{} 码点越界 :: 7.0 起报、nowdoc 与 5.6 不转义" {
    const gpa = std.testing.allocator;
    var t = try Ast.parse(gpa, "<?php \"\\u{FFFFFFFFFFFFFFFF}\";", .{ .id = 80500 });
    defer t.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 1), countLexErrors(t));

    var ok = try Ast.parse(gpa, "<?php \"\\u{1F602}\"; \"\\u{0}\";", .{ .id = 80500 });
    defer ok.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 0), countLexErrors(ok));

    // nowdoc 不转义：内容原样保留，码点文本不校验
    var nd = try Ast.parse(gpa, "<?php <<<'A'\n\\u{FFFFFFFFFFFFFFFF}\nA;\n", .{ .id = 80500 });
    defer nd.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 0), countLexErrors(nd));

    // 5.6 无 \u{} 转义语义，不报
    var t56 = try Ast.parse(gpa, "<?php \"\\u{FFFFFFFFFFFFFFFF}\";", .{ .id = 50600 });
    defer t56.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 0), countLexErrors(t56));
}

test "lex :: flexible heredoc 缩进 :: 混用/不足报错、合法缩进与空行放行" {
    const gpa = std.testing.allocator;
    // tab 与空格混用（结束标签 2 tab；body 行前缀前 2 字符 tab+空格 ≠ tab+tab）
    var mixed = try Ast.parse(gpa, "<?php echo <<<END\n\t   X\n\t\tEND;\n", .{ .id = 80500 });
    defer mixed.deinit(gpa);
    try std.testing.expect(countLexErrors(mixed) >= 1);

    // body 缩进少于结束标签（结束标签 5 空格，末行内容仅 4 空格）
    var under = try Ast.parse(gpa, "<?php echo <<<END\n      a\n     b\n    c\n     END;\n", .{ .id = 80500 });
    defer under.deinit(gpa);
    try std.testing.expect(countLexErrors(under) >= 1);

    // 合法：缩进一致、空行自由
    var ok = try Ast.parse(gpa, "<?php echo <<<END\n  a\n\n  b\n  END;\n", .{ .id = 80500 });
    defer ok.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 0), countLexErrors(ok));

    // 5.6 老式 heredoc：无 flexible 缩进语义，缩进不足不报（结束标签必须顶格，此处顶格）
    var old = try Ast.parse(gpa, "<?php echo <<<END\nFoo\nEND;\n", .{ .id = 50600 });
    defer old.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 0), countLexErrors(old));
}

test "ast :: 版本门控 :: 目标低于引入版本时上报" {
    const gpa = std.testing.allocator;
    var tree = try Ast.parse(gpa, "<?php enum E { case A; }", testing.v80);
    defer tree.deinit(gpa);

    var gate: usize = 0;
    var buf: [128]u8 = undefined;
    for (tree.errors) |e| {
        if (e.tag == .unsupported_version) {
            gate += 1;
            try std.testing.expectEqual(@as(u32, 80100), e.required.id);
            const msg = e.format(&tree, &buf);
            try std.testing.expect(std.mem.indexOf(u8, msg, "8.1") != null);
            try std.testing.expect(std.mem.indexOf(u8, msg, "8.0") != null);
        }
    }
    // stmt_enum 与 stmt_case 均为 8.1 引入
    try std.testing.expectEqual(@as(usize, 2), gate);
}

test "ast :: 版本门控 :: 目标不低于引入版本时静默" {
    const gpa = std.testing.allocator;
    var tree = try Ast.parse(gpa, "<?php enum E { case A; }", testing.v84);
    defer tree.deinit(gpa);
    for (tree.errors) |e| try std.testing.expect(e.tag != .unsupported_version);
}

test "ast :: 非版本错误 :: required 恒为 BASE_VERSION" {
    const gpa = std.testing.allocator;
    var tree = try Ast.parse(gpa, "<?php $a = ;", testing.v84);
    defer tree.deinit(gpa);
    try std.testing.expect(tree.errors.len > 0);
    for (tree.errors) |e| {
        if (e.tag != .unsupported_version) {
            try std.testing.expectEqual(@as(u32, 0), e.required.id);
        }
    }
}

test "ast :: 8.5 语法 :: 表驱动验证版本门控" {
    const gpa = std.testing.allocator;
    const Case = struct { src: [:0]const u8, n: usize };
    const cases = [_]Case{
        .{ .src = "<?php $x |> strlen;", .n = 1 },
        .{ .src = "<?php (void) foo();", .n = 1 },
        .{ .src = "<?php class C { #[A] const X = 1; }", .n = 1 },
        .{ .src = "<?php #[A] const X = 1;", .n = 1 },
        .{ .src = "<?php class C { public protected(set) static int $x; }", .n = 1 },
        .{ .src = "<?php class C { public function __construct(public final int $x) {} }", .n = 1 },
    };

    for (cases) |c| {
        // 目标 8.4 低于 8.5：应报 required=8.5 的门控错误
        var low = try Ast.parse(gpa, c.src, testing.v84);
        defer low.deinit(gpa);
        var gate: usize = 0;
        for (low.errors) |e| {
            if (e.tag == .unsupported_version and e.required.id == 80500) gate += 1;
        }
        try std.testing.expectEqual(c.n, gate);

        // 目标 8.5：不应再报版本错误
        var ok = try Ast.parse(gpa, c.src, testing.v85);
        defer ok.deinit(gpa);
        for (ok.errors) |e| try std.testing.expect(e.tag != .unsupported_version);
    }
}

test "ast :: tokenSlice :: 节点主 token 可回切源码原文" {
    const gpa = std.testing.allocator;
    var tree = try Ast.parse(gpa, "<?php $answer = 42;", testing.v84);
    defer tree.deinit(gpa);
    try testing.expectNoErrors(tree);

    const lit = testing.firstNode(tree,.expr_int) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("42", tree.tokenSlice(tree.nodeMainToken(lit)));
}

test "ast :: firstToken/lastToken :: 覆盖节点的完整 token 区间" {
    const gpa = std.testing.allocator;
    var tree = try Ast.parse(gpa, "<?php $a = 1 + 2;", testing.v84);
    defer tree.deinit(gpa);
    try testing.expectNoErrors(tree);

    // 二元表达式应覆盖 `1 + 2` 三个 token，而非仅主 token（运算符 `+`）
    const bin = testing.firstNode(tree, .expr_binary) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("1", tree.tokenSlice(tree.firstToken(bin)));
    try std.testing.expectEqualStrings("2", tree.tokenSlice(tree.lastToken(bin)));

    // 赋值表达式覆盖 `$a = 1 + 2` 五个 token
    const asg = testing.firstNode(tree, .expr_assign) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("$a", tree.tokenSlice(tree.firstToken(asg)));
    try std.testing.expectEqualStrings("2", tree.tokenSlice(tree.lastToken(asg)));
}

test "ast :: firstToken/lastToken :: 复合语句含定界符" {
    const gpa = std.testing.allocator;
    var tree = try Ast.parse(gpa, "<?php if ($a) { echo 1; }", testing.v84);
    defer tree.deinit(gpa);
    try testing.expectNoErrors(tree);

    // 整个 if 语句应覆盖到结尾的 `}`
    const if_node = testing.firstNode(tree, .stmt_if) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("if", tree.tokenSlice(tree.firstToken(if_node)));
    try std.testing.expectEqualStrings("}", tree.tokenSlice(tree.lastToken(if_node)));
}

test "ast :: 限定名 :: 区间覆盖全部分段" {
    // 分段名存于 `data.token`（末段），若 lastToken 忽略它，区间会停在首段，
    // 下游按区间取名字文本将得到 `Foo` 而非 `Foo\Bar`。
    const gpa = std.testing.allocator;
    var tree = try Ast.parse(gpa, "<?php use Foo\\Bar;", testing.v84);
    defer tree.deinit(gpa);
    try testing.expectNoErrors(tree);

    const n = testing.firstNode(tree, .name) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("Foo", tree.tokenSlice(tree.firstToken(n)));
    try std.testing.expectEqualStrings("Bar", tree.tokenSlice(tree.lastToken(n)));
}

test "ast :: nameToken :: 取回声明的名字而非关键字" {
    const gpa = std.testing.allocator;
    var tree = try Ast.parse(gpa,
        \\<?php
        \\function foo() {}
        \\class Bar { public int $prop; const C = 1; public function m() {} }
        \\enum Suit: string { case Hearts; }
    , testing.v84);
    defer tree.deinit(gpa);
    try testing.expectNoErrors(tree);

    // main_token 是关键字（function/class/enum），名字只能经 nameToken 取得
    const fn_node = testing.firstNode(tree, .stmt_function) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("function", tree.tokenSlice(tree.nodeMainToken(fn_node)));
    try std.testing.expectEqualStrings("foo", tree.tokenSlice(tree.nameToken(fn_node).?));

    const m = testing.firstNode(tree, .stmt_method) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("m", tree.tokenSlice(tree.nameToken(m).?));

    // 属性名的 token 含 `$` 前缀，与 PHP 源码一致
    const p = testing.firstNode(tree, .stmt_property) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("$prop", tree.tokenSlice(tree.nameToken(p).?));

    const c = testing.firstNode(tree, .stmt_class_const) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("C", tree.tokenSlice(tree.nameToken(c).?));

    const e = testing.firstNode(tree, .stmt_enum) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("Suit", tree.tokenSlice(tree.nameToken(e).?));

    const case_node = testing.firstNode(tree, .stmt_case) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("Hearts", tree.tokenSlice(tree.nameToken(case_node).?));
}

test "ast :: lastToken :: 各类语句的区间含尾部分号" {
    const gpa = std.testing.allocator;
    // 每行均为「一个语句 + 分号」；断言该语句的 lastToken 就是分号。
    const srcs = [_][:0]const u8{
        "<?php $a = 1;",
        "<?php echo 1;",
        "<?php return 1;",
        "<?php throw $e;",
        "<?php const A = 1;",
        "<?php global $a;",
        "<?php static $a;",
        "<?php unset($a);",
        "<?php use A;",
        "<?php use A\\{B};",
        "<?php declare(strict_types=1);",
        "<?php goto a;",
        "<?php do {} while ($a);",
        "<?php while ($a) { break; }",
        "<?php while ($a) { continue; }",
        "<?php namespace N;",
        "<?php class C { use T; }",
        "<?php class C { public int $x; }",
        "<?php class C { const A = 1; }",
        "<?php enum E { case A; }",
    };

    for (srcs) |src| {
        var tree = try Ast.parse(gpa, src, testing.v84);
        defer tree.deinit(gpa);
        try testing.expectNoErrors(tree);

        // 取首条顶层语句；类成员则取类体内首条
        const stmts = tree.rootStmts();
        if (stmts.len == 0) return error.TestUnexpectedResult;
        var target = stmts[0];
        // 类成员语句需下钻一层；类与枚举的负载类型不同，分别取
        const members: []const Index = switch (tree.nodeTag(target)) {
            .stmt_class => blk: {
                const c = tree.extraData(tree.nodeData(target).extra_and_opt_node[0], decl.ClassComponents);
                break :blk tree.extraDataSlice(c.stmts, Index);
            },
            .stmt_enum => blk: {
                const c = tree.extraData(tree.nodeData(target).extra_and_opt_node[0], decl.TypeDeclComponents);
                break :blk tree.extraDataSlice(c.stmts, Index);
            },
            else => &.{},
        };
        if (members.len > 0) target = members[0];
        // 语句区间必须以**收尾符**结束：表达式类语句为 `;`，块/循环类语句为 `}`
        // （`while` / `if` / 函数体等同理，无需逐类特判）。
        const last = tree.tokenSlice(tree.lastToken(target));
        if (!std.mem.eql(u8, ";", last) and !std.mem.eql(u8, "}", last)) {
            std.debug.print("\n语句区间不含收尾符: {s}\n  实际末 token = `{s}`\n", .{ src, last });
            try std.testing.expect(false);
        }
    }
}

test "ast :: lastToken :: 块形式命名空间与 declare 以 } 结尾" {
    const gpa = std.testing.allocator;
    var tree = try Ast.parse(gpa,
        \\<?php
        \\namespace N { function f() {} }
        \\declare(strict_types=1) { $a = 1; }
    , testing.v84);
    defer tree.deinit(gpa);
    try testing.expectNoErrors(tree);

    for (tree.rootStmts()) |s| {
        try std.testing.expectEqualStrings("}", tree.tokenSlice(tree.lastToken(s)));
    }
}

test "ast :: forEachChild :: 各节点均能无异常枚举子节点" {
    // data 是 untagged union，读写两侧若用了不同变体会触发安全检查报错甚至越界。
    // 覆盖矩阵已保证每个 tag 都有用例，这里对全树逐节点枚举一次即可暴露不一致。
    const gpa = std.testing.allocator;
    const srcs = [_][:0]const u8{
        "<?php $a = 1 + 2;",
        "<?php if ($a) { echo 1; } else { echo 2; }",
        "<?php while ($a) { break; }",
        "<?php for ($i = 0; $i < 3; $i++) {}",
        "<?php foreach ($a as $k => $v) {}",
        "<?php do {} while ($a);",
        "<?php switch ($a) { case 1: break; default: }",
        "<?php try {} catch (E $e) {} finally {}",
        "<?php function f(int $x): int { return $x; }",
        "<?php class C extends B implements I { public int $x; const A = 1; use T; }",
        "<?php interface I { public function m(); }",
        "<?php trait T { public function m() {} }",
        "<?php enum E: string { case A = 'a'; }",
        "<?php namespace N { function f() {} }",
        "<?php use A\\{B, C as D};",
        "<?php declare(strict_types=1) { $a = 1; }",
        "<?php match ($a) { 1, 2 => 'x', default => 'y' };",
        "<?php $f = function ($p) use ($y): int { return $p; };",
        "<?php $g = fn ($p) => $p;",
        "<?php #[Attr(1)] class D {}",
        "<?php $x = new class { public $p; };",
        "<?php $a?->b()->c[0]::$d;",
        "<?php (int)$v . (string)$w;",
        "<?php `ls -l`; print $a; eval('1'); exit;",
        "<?php global $a; static $b; unset($c);",
        "<?php goto lb; lb:",
        "<?php __halt_compiler();",
    };

    const Ctx = struct {
        tree: Ast,
        n: usize = 0,
        fn onChild(self: *@This(), child: Index) !void {
            self.n += 1;
            // 子节点下标必须合法
            _ = self.tree.nodeTag(child);
        }
    };

    for (srcs) |src| {
        var tree = try Ast.parse(gpa, src, testing.v84);
        defer tree.deinit(gpa);
        for (tree.nodes.items(.tag), 0..) |_, i| {
            var ctx = Ctx{ .tree = tree };
            try tree.forEachChild(@enumFromInt(i), &ctx, Ctx.onChild);
        }
    }
}

test "ast :: lastToken :: root 委托到首末条顶层语句" {
    const gpa = std.testing.allocator;
    var tree = try Ast.parse(gpa, "<?php $a = 1;", testing.v84);
    defer tree.deinit(gpa);
    try testing.expectNoErrors(tree);

    try std.testing.expectEqualStrings("$a", tree.tokenSlice(tree.firstToken(tree.root)));
    try std.testing.expectEqualStrings(";", tree.tokenSlice(tree.lastToken(tree.root)));
}

test "ast :: tokenLocation :: 计算行列位置" {
    const gpa = std.testing.allocator;
    var tree = try Ast.parse(gpa,
        \\<?php
        \\$a = 1;
        \\$b = 2;
    , testing.v84);
    defer tree.deinit(gpa);
    try testing.expectNoErrors(tree);

    const lit = testing.firstNode(tree,.expr_int) orelse return error.TestUnexpectedResult;
    const loc = tree.tokenLocation(0, tree.nodeMainToken(lit));
    // 第 2 行（0 起算），即源码中的 `$a = 1;`
    try std.testing.expectEqual(@as(usize, 1), loc.line);
}

test "ast :: docCommentBefore :: 取回声明前的 docblock" {
    const gpa = std.testing.allocator;
    var tree = try Ast.parse(gpa,
        \\<?php
        \\/** doc */
        \\function f() {}
    , testing.v84);
    defer tree.deinit(gpa);
    try testing.expectNoErrors(tree);

    const fn_node = testing.firstNode(tree,.stmt_function) orelse return error.TestUnexpectedResult;
    const doc = tree.docCommentBefore(fn_node) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(.doc_comment, tree.tokenTag(doc));
}

test "ast :: tagVersion :: 基础语法返回 BASE_VERSION" {
    try std.testing.expectEqual(@as(u32, 0), tagVersion(.root).id);
    try std.testing.expectEqual(@as(u32, 0), tagVersion(.expr_assign).id);
    try std.testing.expectEqual(@as(u32, 80100), tagVersion(.stmt_enum).id);
    try std.testing.expectEqual(@as(u32, 80400), tagVersion(.property_hook).id);
    try std.testing.expectEqual(@as(u32, 80500), tagVersion(.expr_pipe).id);
}


