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

/// 声明名位（类 / 接口 / trait / enum 名与 `use ... as` 别名）**不接受**的关键字。
///
/// 依据 php.y：该位置只归约 `T_STRING`，关键字进入即语法错（`class static {}`、
/// `use C as static;`），**不产出声明节点**。`readonly` 自 PHP 8.0 起才是关键字，
/// 7.x 允许作类名（`readonlyAsClassName`）。
///
/// 按**文本**判定（忽略大小写）：词法器保持源码原样切片，`ReadOnly` 仍是 identifier
/// tag，需回判文本才能与 php-parser 的 `T_READONLY` 对齐。
///
/// 覆盖范围：目前只包含声明名位实际会遇到的保留关键字——`static` 与 8.0+ 的
/// `readonly`。其余关键字（`class` / `if` …）在该位同样是语法错，但本库尚未对齐；
/// 若需扩展，应改为「`Token.keywords` 全集减去半保留集合（semi_reserved）」统一推导，
/// 而不是逐个追加。
pub fn isForbiddenDeclName(tag: Token.Tag, text: []const u8, version: PhpVersion) bool {
    if (tag == .kw_static) return true;
    if (tag == .kw_readonly) return version.id >= 80000;
    if (tag == .identifier) {
        if (std.ascii.eqlIgnoreCase(text, "static")) return true;
        if (version.id >= 80000 and std.ascii.eqlIgnoreCase(text, "readonly")) return true;
    }
    return false;
}

test "reserved :: 保留名与禁用声明名判定（大小写不敏感）" {
    const v74 = PhpVersion{ .id = 70400 };
    const v80 = PhpVersion{ .id = 80000 };
    const v84 = PhpVersion{ .id = 80400 };

    try std.testing.expect(isReservedClassName("self"));
    try std.testing.expect(isReservedClassName("PARENT"));
    try std.testing.expect(isReservedClassName("Static"));
    try std.testing.expect(!isReservedClassName("A"));

    try std.testing.expect(isReservedConstName("NULL"));
    try std.testing.expect(isReservedConstName("True"));
    try std.testing.expect(!isReservedConstName("nil"));

    // `static` 恒禁；`readonly` 仅 8.0 起为关键字
    try std.testing.expect(isForbiddenDeclName(.kw_static, "static", v74));
    try std.testing.expect(isForbiddenDeclName(.kw_readonly, "readonly", v80));
    try std.testing.expect(!isForbiddenDeclName(.kw_readonly, "readonly", v74));
    try std.testing.expect(isForbiddenDeclName(.identifier, "ReadOnly", v84));
    try std.testing.expect(!isForbiddenDeclName(.identifier, "List", v84));
}
