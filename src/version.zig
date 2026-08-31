const std = @import("std");

/// PHP 语言版本。版本号以 `major * 10000 + minor * 100` 编码，便于比较。
///
/// 本文件仅提供版本数值载体。版本门控（是否接受某语法）由 `Ast.parse` 在解析后
/// 统一执行：AST 上逐节点记录「引入版本」（`node_versions`），若其高于 `parse`
/// 指定的目标版本，则上报 `unsupported_version` 诊断。
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

// ===========================================================================
// 测试：版本数值
// ===========================================================================

test "version :: fromComponents :: 编码为 major*10000+minor*100" {
    try std.testing.expectEqual(@as(u32, 80000), PhpVersion.fromComponents(8, 0).id);
    try std.testing.expectEqual(@as(u32, 80400), PhpVersion.fromComponents(8, 4).id);
    try std.testing.expectEqual(@as(u32, 80500), PhpVersion.fromComponents(8, 5).id);
}

test "version :: newerOrEqual :: 同版本与更新版本均成立" {
    const v84 = PhpVersion.fromComponents(8, 4);
    const v81 = PhpVersion.fromComponents(8, 1);
    try std.testing.expect(v84.newerOrEqual(v81));
    try std.testing.expect(!v81.newerOrEqual(v84));
    try std.testing.expect(v84.newerOrEqual(v84));
}

test "version :: BASE_VERSION :: id 为 0 且小于任何合法版本" {
    try std.testing.expectEqual(@as(u32, 0), BASE_VERSION.id);
    try std.testing.expect(!BASE_VERSION.newerOrEqual(PhpVersion.fromComponents(8, 0)));
}

