const std = @import("std");

/// php-ast：用 Zig 实现的 PHP 8.4+ 解析器，输出 SoA 形式的 AST。
/// 内存由调用方通过 `parse(gpa, ...)` 显式提供，统一经 `Ast.deinit` 释放。
/// 测试就近写在各被测源文件底部的 `test` 块中，运行 `zig build test` 收集执行。
///
/// 各子模块以同名命名空间再导出，调用方写作 `php_ast.ast` / `.lexer` / `.token` / `.version`。
pub const token = @import("token.zig");
pub const ast = @import("ast.zig");
pub const lexer = @import("lexer.zig");
pub const version = @import("version.zig");
pub const walk = @import("walk.zig");
pub const dump = @import("dump.zig");
pub const project = @import("project.zig");

pub const Ast = @import("ast.zig").Ast;
pub const ParseError = @import("ast.zig").ParseError;
pub const Node = @import("ast.zig").Node;
pub const PhpVersion = @import("version.zig").PhpVersion;
pub const Token = @import("token.zig").Token;
pub const ProjectAst = @import("project.zig").ProjectAst;

/// 解析入口便捷别名（`Ast.parse` 的顶层再导出）。
pub const parse = @import("ast.zig").Ast.parse;

/// 目录加载便捷别名（`project.loadDir` 的顶层再导出）。
pub const loadDir = @import("project.zig").loadDir;

// 单元测试入口：强制引用各模块，使其内部的 `test` 块被 test runner 收集。
//
// Zig 对 `@import` 采用惰性分析——像上面那样把模块 re-export 出去，并不会
// 强制分析整个文件，文件内的 `test` 块也就不会被收集（`zig test src/root.zig`
// 会报 `All 0 tests passed`）。逐个 `_ = @import(...)` 强制分析，是 Zig 生态
// 收集「分散在各源文件中测试」的标准做法。
//
// **新增含 `test` 的模块时，必须在此登记**，否则其测试会被静默跳过。
//
// 注：匿名 test 块不可附着 `///` 文档注释（Zig 0.16 限制），故此处用普通注释。
test {
    _ = @import("token.zig");
    _ = @import("ast.zig");
    _ = @import("lexer.zig");
    _ = @import("version.zig");
    _ = @import("parser.zig");
    _ = @import("parser_stmt.zig");
    _ = @import("parser_decl.zig");
    _ = @import("parser_expr.zig");
    _ = @import("parser_type.zig");
    _ = @import("walk.zig");
    _ = @import("project.zig");
    // 覆盖矩阵：编译期强制每个 Node.Tag 都有用例（新增节点忘补即编译失败）
    _ = @import("coverage.zig");
    _ = @import("dump.zig");
    _ = @import("golden.zig");
}
