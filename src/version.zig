/// PHP 语言版本。版本号以 `major * 10000 + minor * 100` 编码，便于比较。
/// 解析器据此决定哪些 8.x 语法可用（声明式版本谓词，对标 PHP-Parser 的 `PhpVersion`）。
///
/// ```zig
/// const php84 = PhpVersion.fromComponents(8, 4);
/// if (php84.supportsPropertyHooks()) {
///     // 允许解析 property hooks（get/set）
/// }
/// ```
pub const PhpVersion = struct {
    id: u32,

    /// 由主、次版本号构造，`fromComponents(8, 4)` 表示 PHP 8.4。
    pub fn fromComponents(major: u16, minor: u16) PhpVersion {
        return .{ .id = @as(u32, major) * 10000 + @as(u32, minor) * 100 };
    }

    /// 判断 `self` 是否不早于 `other`（同版本或更新）。
    ///
    /// ```zig
    /// const php81 = PhpVersion.fromComponents(8, 1);
    /// const php84 = PhpVersion.fromComponents(8, 4);
    /// try std.testing.expect(php84.newerOrEqual(php81));
    /// ```
    pub fn newerOrEqual(self: PhpVersion, other: PhpVersion) bool {
        return self.id >= other.id;
    }

    /// 是否支持 property hooks（`get`/`set`，PHP 8.4 引入）。
    pub fn supportsPropertyHooks(self: PhpVersion) bool {
        return self.id >= 80400;
    }

    /// 是否支持非对称可见性（`public private(set)`，PHP 8.4 引入）。
    pub fn supportsAsymmetricVisibility(self: PhpVersion) bool {
        return self.id >= 80400;
    }
};
