const std = @import("std");

/// php-ast：用 Zig 实现的 PHP 8.4+ 解析器，输出 SoA 形式的 AST。
/// 内存由调用方通过 `parse(gpa, ...)` 显式提供，统一经 `Ast.deinit` 释放。
/// 测试位于 `src/tests/*_test.zig`，运行 `zig build test` 逐个编译执行。
///
/// 各子模块以同名命名空间再导出，调用方写作 `php_ast.ast` / `.lexer` / `.token` / `.version`。
pub const token = @import("token.zig");
pub const ast = @import("ast.zig");
pub const lexer = @import("lexer.zig");
pub const version = @import("version.zig");
pub const walk = @import("walk.zig");

pub const Ast = @import("ast.zig").Ast;
pub const ParseError = @import("ast.zig").ParseError;
pub const Node = @import("ast.zig").Node;
pub const PhpVersion = @import("version.zig").PhpVersion;
pub const Token = @import("token.zig").Token;

/// 解析入口便捷别名（`Ast.parse` 的顶层再导出）。
pub const parse = @import("ast.zig").Ast.parse;
