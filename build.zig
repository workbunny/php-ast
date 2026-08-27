const std = @import("std");

/// 构建脚本：提供 `test` 步骤，逐个编译并执行分离的单元测试。
///
/// 库本身以命名模块 `php_ast`（根 `src/root.zig`）暴露，测试文件位于 `src/tests/`，
/// 各自按名 `@import("php_ast")` 引用被测模块。这样测试文件可独立作为模块根编译，
/// 其内部 `test` 块被直接收集，而库模块保持纯净、不含任何 `test` 块。新增测试时，
/// 在 `src/tests/` 新建文件并在下方 `test_files` 追加一行即可。
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // 库模块：对外暴露为 "php_ast"，供测试文件按名导入。
    const lib_mod = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const test_files = [_][]const u8{
        "src/tests/lexer_test.zig",
        "src/tests/ast_test.zig",
    };

    const test_step = b.step("test", "运行 php-ast 单元测试");
    for (test_files) |file| {
        // 每个测试文件单独建模块，挂上 php_ast 依赖，编译为独立测试可执行。
        const mod = b.createModule(.{
            .root_source_file = b.path(file),
            .target = target,
            .optimize = optimize,
        });
        mod.addImport("php_ast", lib_mod);
        const tests = b.addTest(.{ .root_module = mod });
        const run = b.addRunArtifact(tests);
        test_step.dependOn(&run.step);
    }
}
