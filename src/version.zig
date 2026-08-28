/// PHP 语言版本。版本号以 `major * 10000 + minor * 100` 编码，便于比较。
///
/// 本库**不做版本门控**（是否接受某语法交给下游决定）：我们只在 AST 上逐节点记录
/// 「引入版本」（`Ast.nodeVersion`），供调用方自行判断兼容性。`PhpVersion` 仅作为
/// 版本数值的载体与比较工具。
///
/// ```zig
/// const php84 = PhpVersion.fromComponents(8, 4);
/// const php81 = PhpVersion.fromComponents(8, 1);
/// try std.testing.expect(php84.newerOrEqual(php81));
/// ```
pub const PhpVersion = struct {
    id: u32,

    /// 由主、次版本号构造，`fromComponents(8, 4)` 表示 PHP 8.4。
    pub fn fromComponents(major: u16, minor: u16) PhpVersion {
        return .{ .id = @as(u32, major) * 10000 + @as(u32, minor) * 100 };
    }

    /// 判断 `self` 是否不早于 `other`（同版本或更新）。
    pub fn newerOrEqual(self: PhpVersion, other: PhpVersion) bool {
        return self.id >= other.id;
    }
};

/// 哨兵：表示「基础语法」或「无版本信息」（对应 PHP 8.1 以前的构造）。
/// 与 `PhpVersion` 的合法版本（id >= 80000）区分。
pub const BASE_VERSION: PhpVersion = .{ .id = 0 };

