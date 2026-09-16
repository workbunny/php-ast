//! PHP 语言层面的**保留名 / 禁用名**判定，定义集中一处，供语义层（`semantic.zig`）、
//! 名字解析层（`name_resolver.zig`）与语法声明名位（`parser_decl.zig` /
//! `parser_stmt.zig`）共用——同一语言事实在多处各写一份必然漂移。
//!
//! 判定一律**忽略大小写**：PHP 的关键字与保留名大小写不敏感，而本库词法器为保持
//! 「切片即源码」的零拷贝语义按原样切分，故 `Self` / `PARENT` / `TRUE` 同样命中。

const std = @import("std");
const Token = @import("token.zig").Token;
const PhpVersion = @import("version.zig").PhpVersion;

/// 保留类名：`self` / `parent` / `static`。
///
/// 不可作类 / 接口 / trait / enum 名，也不可作 `use ... as` 的别名；但它们被词法归为
/// identifier，故由语义层报「保留名」并**照常产出节点**（区别于下面的语法错形态）。
pub fn isReservedClassName(text: []const u8) bool {
    return std.ascii.eqlIgnoreCase(text, "self") or
        std.ascii.eqlIgnoreCase(text, "parent") or
        std.ascii.eqlIgnoreCase(text, "static");
}

/// 保留常量名：`true` / `false` / `null`（不可作常量名/常量引用别名）。
pub fn isReservedConstName(text: []const u8) bool {
    return std.ascii.eqlIgnoreCase(text, "true") or
        std.ascii.eqlIgnoreCase(text, "false") or
        std.ascii.eqlIgnoreCase(text, "null");
}

/// 该 token 在目标版本下能否作**名字**（标识符 / 类名 / 类型名 / 标签 / 名字段）。
///
/// 词法器按关键字全集切 tag、不感知版本（`ReadOnly` 与 `readonly` 同样切成 `kw_readonly`），
/// 故「目标版本尚未生效的关键字」在此放行：8.0 目标下 `readonly` / `enum` 仍可作名字，
/// 8.1 起才是关键字（生效版本见 `Token.keywordSince`）。
pub fn isNameToken(tag: Token.Tag, version: PhpVersion) bool {
    if (tag == .identifier) return true;
    if (!tag.isKeyword()) return false;
    return version.id < Token.keywordSince(tag);
}

/// 顶层函数 / 闭包声明名位（php.y `fn_identifier`）能否接受该 token。
///
/// 该位是 `identifier_not_reserved`（仅 `T_STRING`）外加三个特例
/// `readonly` / `exit` / `clone`——它们不可作类名等其他名字位，但可作函数名
/// （`function readonly() {}` 合法）。方法名位用更宽的 `identifier_maybe_reserved`，
/// 故 `function list() {}`（顶层）是语法错、`public function list() {}`（方法）合法。
pub fn isFnIdentifier(tag: Token.Tag, version: PhpVersion) bool {
    if (isNameToken(tag, version)) return true;
    return switch (tag) {
        // php.y `fn_identifier` 的显式特例（`die` 在本库是独立 tag，PHP 词法里与
        // `exit` 同归 T_EXIT）。
        .kw_readonly, .kw_exit, .kw_die, .kw_clone => true,
        // `fn` 亦被参照实现接受作函数名（`function fn() {}`，php-parser 5.8 实测接受）。
        .kw_fn => true,
        else => false,
    };
}

/// 声明名位（类 / 接口 / trait / enum 名与 `use ... as` 别名）**不接受**的关键字。
///
/// 依据 php.y：这些位只归约 `identifier_not_reserved`，而其定义仅 `T_STRING`——
/// 半保留集合（`semi_reserved`）只对 `identifier_maybe_reserved` 位合法（方法名、
/// 函数名、常量名等），故**全部关键字**在声明名位都是语法错且不产出声明节点
/// （`class static {}`、`class list {}`、`use C as if;`）。
///
/// 例外是目标版本尚未生效的关键字：`enum` / `readonly` 自 PHP 8.1 起才是关键字
/// （生效版本记在 `Token.keywords` 的 `since` 字段），在此之前该位仍可作名字。
/// 判定经 `Token.keywordSince` 单一来源推导，不再逐个追加关键字。
///
/// 判定只按 `tag`：词法器已按忽略大小写切关键字（`ReadOnly` 与 `readonly` 同类）。
pub fn isForbiddenDeclName(tag: Token.Tag, version: PhpVersion) bool {
    return tag.isKeyword() and !isNameToken(tag, version);
}

test "reserved :: 名字判定 :: 目标版本未生效的关键字可作名字" {
    const v80 = PhpVersion{ .id = 80000 };
    const v81 = PhpVersion{ .id = 80100 };
    const v84 = PhpVersion{ .id = 80400 };

    try std.testing.expect(isNameToken(.identifier, v84));
    try std.testing.expect(!isNameToken(.kw_class, v84));
    try std.testing.expect(!isNameToken(.kw_static, v84));
    try std.testing.expect(!isNameToken(.int_literal, v84));

    // `enum` / `readonly` 自 8.1 起才是关键字
    try std.testing.expect(isNameToken(.kw_enum, v80));
    try std.testing.expect(!isNameToken(.kw_enum, v81));
    try std.testing.expect(isNameToken(.kw_readonly, v80));
    try std.testing.expect(!isNameToken(.kw_readonly, v81));
}

test "reserved :: 保留名与禁用声明名判定" {
    const v80 = PhpVersion{ .id = 80000 };
    const v81 = PhpVersion{ .id = 80100 };
    const v84 = PhpVersion{ .id = 80400 };

    try std.testing.expect(isReservedClassName("self"));
    try std.testing.expect(isReservedClassName("PARENT"));
    try std.testing.expect(isReservedClassName("Static"));
    try std.testing.expect(!isReservedClassName("A"));

    try std.testing.expect(isReservedConstName("NULL"));
    try std.testing.expect(isReservedConstName("True"));
    try std.testing.expect(!isReservedConstName("nil"));

    // 声明名位不接受任何关键字（php.y 的 `identifier_not_reserved` 只归约 T_STRING），
    // 含 semi_reserved 成员（`static` / `list`）
    try std.testing.expect(isForbiddenDeclName(.kw_static, v80));
    try std.testing.expect(isForbiddenDeclName(.kw_class, v80));
    try std.testing.expect(isForbiddenDeclName(.kw_if, v80));
    try std.testing.expect(isForbiddenDeclName(.kw_list, v84));

    // 目标版本尚未生效的关键字在该位仍可作名字
    try std.testing.expect(!isForbiddenDeclName(.kw_enum, v80));
    try std.testing.expect(isForbiddenDeclName(.kw_enum, v81));
    try std.testing.expect(!isForbiddenDeclName(.kw_readonly, v80));
    try std.testing.expect(isForbiddenDeclName(.kw_readonly, v81));

    // 普通标识符合法（大小写归一由词法器承担，此处只看 tag）
    try std.testing.expect(!isForbiddenDeclName(.identifier, v84));
}
