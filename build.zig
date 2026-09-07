const std = @import("std");

/// 构建脚本：提供 `test` 步骤，编译并执行库内全部单元测试。
///
/// 库以公开模块 `php_ast`（根 `src/root.zig`）暴露——`addModule` 会把模块注册到
/// `b.modules` 表，下游经 `b.dependency(...).module("php_ast")` 取用（`createModule`
/// 只建私有模块，下游拿不到）。测试遵循 Zig 惯例：`test` 块就近写在被测源文件
/// 底部，而非集中于独立 `tests/` 目录。这样测试与实现同处一文件、可读性强，
/// 且能覆盖文件内私有的辅助函数。
///
/// Zig 对 `@import` 惰性分析，测试收集靠 `src/root.zig` 末尾的登记 `test { }` 强制
/// `_ = @import(...)` 各模块——新增含 `test` 的模块**必须**在 root.zig 登记，否则其
/// 测试被静默跳过（`zig test src/root.zig` 会报 "All 0 tests passed"）。本文件无需
/// 因新增模块而改动（模块须先挂到 `lib_mod` 的 import 表）。
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // `zig build test -Dupdate-golden` 重新生成黄金快照。默认 false（只比对不写入）。
    const update_golden = b.option(bool, "update-golden", "重新生成 tests/golden 下的快照文件") orelse false;

    // 库模块：公开注册为 "php_ast"，供下游 `b.dependency(...).module("php_ast")` 获取，
    // 同时充当测试入口（test 块即在此模块树内）。
    const lib_mod = b.addModule("php_ast", .{
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

    // 一致性对照工具（tools/parity_check.zig）：以 php-parser 测试子集为基准度量
    // 本库接受面与诊断质量，产出 acceptance_report.txt 与 diagnostic_report.txt。
    // 可执行（非 test）以支持命令行参数：`zig build check-parity -- <基准目录>`
    // 用指定目录作基准并把报告写到该目录；无参数用库内 tests/third_party 基准、
    // 报告写到仓库根。库经 `ast` 模块暴露给工具（addExecutable 无 `../` 越界限制）。
    const parity_exe = b.addExecutable(.{
        .name = "parity_check",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/parity_check.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{ .{ .name = "ast", .module = lib_mod } },
        }),
    });
    const run_parity = b.addRunArtifact(parity_exe);
    if (b.args) |args| {
        for (args) |a| run_parity.addArg(a);
    }
    const parity_step = b.step("check-parity", "与 php-parser 测试子集做一致性对照（接受面 + 诊断质量）");
    parity_step.dependOn(&run_parity.step);
}
