const std = @import("std");

/// 构建脚本：提供 `test` 步骤，编译并执行库内全部单元测试。
///
/// 库以命名模块 `php_ast`（根 `src/root.zig`）暴露。测试遵循 Zig 惯例：
/// `test` 块就近写在被测源文件底部，而非集中于独立 `tests/` 目录。这样
/// 测试与实现同处一文件、可读性强，且能覆盖文件内私有的辅助函数。
///
/// 收集是自动的：`b.addTest(.{ .root_module = lib_mod })` 会递归扫描 `lib_mod`
/// 及其全部传递依赖（token/ast/lexer/parser*/walk/version）中的 `test` 块，
/// 新增测试文件时**无需**改动本文件。
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // `zig build test -Dupdate-golden` 重新生成黄金快照。默认 false（只比对不写入）。
    const update_golden = b.option(bool, "update-golden", "重新生成 tests/golden 下的快照文件") orelse false;

    // 库模块：对外暴露为 "php_ast"，同时充当测试入口（test 块即在此模块树内）。
    const lib_mod = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const golden_opts = b.addOptions();
    golden_opts.addOption(bool, "update_golden", update_golden);
    lib_mod.addOptions("golden_options", golden_opts);

    // 共享测试断言工具 `src/testing.zig` 由各源文件的 test 块以相对路径
    // `@import("testing.zig")` 引入，随 `lib_mod` 一并编译，无需注册为独立模块
    // （若注册，会因该文件同时归属 `root` 模块而报 "file exists in modules" 冲突）。
    const tests = b.addTest(.{
        .root_module = lib_mod,
    });

    const run_tests = b.addRunArtifact(tests);

    const test_step = b.step("test", "运行 php-ast 单元测试");
    test_step.dependOn(&run_tests.step);
}
