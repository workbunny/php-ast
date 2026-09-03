//! php-parser 兼容 API 层：把本库 SoA 查询包装成与 php-parser 高频用法相近的形态。
//!
//! 设计意图（对齐 `doc/example.md` 口径）：结构可异、用法趋同——这些包装让
//! php-parser 用户以近似的调用形状拿到结果，而不必先理解 SoA 内部。
//! 全部实现为纯函数 / 旁表，不改变 AST、无分配（除 attributes 旁表显式持有）。
//!
//! 包含：类型名映射（B9）、位置便捷（B11）、doc comment（B12）、attributes 旁表（B10）。
const std = @import("std");
const ast = @import("ast.zig");
const Ast = ast.Ast;
const Index = ast.Index;
const TokenIndex = ast.TokenIndex;
const Node = ast.Node;

/// 把本库 tag 转成 php-parser 风格类型名（`Expr_New`、`Stmt_Expression`…）。
///
/// 前缀规则：`stmt_*` → `Stmt_`、`expr_*` → `Expr_`、`name_*` → `Name*`（转 Pascal）、
/// `type_*` → `Type_`、其余（param/attribute/root/attr_group）按语义映射。
/// 运算符类子类型（php-parser 的 BinaryOp\Plus 等）已折叠为统一 tag + 运算符 token，
/// 此处不展开（见 `doc/special.md` P1）。
pub fn phpParserType(tag: Node.Tag) []const u8 {
    return switch (tag) {
        // 语句
        .stmt_expression => "Stmt_Expression",
        .stmt_echo => "Stmt_Echo",
        .stmt_if => "Stmt_If",
        .stmt_while => "Stmt_While",
        .stmt_for => "Stmt_For",
        .stmt_foreach => "Stmt_Foreach",
        .stmt_function => "Stmt_Function",
        .stmt_class => "Stmt_Class",
        .stmt_enum => "Stmt_Enum",
        .stmt_interface => "Stmt_Interface",
        .stmt_trait => "Stmt_Trait",
        .stmt_case => "Stmt_Case",
        .stmt_property => "Stmt_Property",
        .property_hook => "Stmt_PropertyHook",
        .stmt_namespace => "Stmt_Namespace",
        .stmt_return => "Stmt_Return",
        .stmt_block => "Stmt_Block",
        .stmt_do => "Stmt_Do",
        .stmt_break => "Stmt_Break",
        .stmt_continue => "Stmt_Continue",
        .stmt_switch => "Stmt_Switch",
        .stmt_switch_case => "Stmt_SwitchCase",
        .stmt_default => "Stmt_Default",
        .stmt_throw => "Stmt_Throw",
        .stmt_try => "Stmt_TryCatch",
        .stmt_catch => "Stmt_Catch",
        .stmt_const => "Stmt_Const",
        .const_decl => "Stmt_Const_Const",
        .stmt_use => "Stmt_Use",
        .use_use => "Stmt_UseUse",
        .stmt_group_use => "Stmt_GroupUse",
        .stmt_trait_use => "Stmt_TraitUse",
        .trait_use_adaptation_alias => "Stmt_TraitUseAdaptation_Alias",
        .trait_use_adaptation_precedence => "Stmt_TraitUseAdaptation_Precedence",
        .stmt_declare => "Stmt_Declare",
        .declare_declare => "Stmt_Declare_Declare",
        .stmt_goto => "Stmt_Goto",
        .stmt_label => "Stmt_Label",
        .stmt_global => "Stmt_Global",
        .stmt_static => "Stmt_Static",
        .static_var => "Stmt_StaticVar",
        .stmt_unset => "Stmt_Unset",
        .stmt_halt => "Stmt_HaltCompiler",
        .inline_html => "Stmt_InlineHTML",
        .stmt_nop => "Stmt_Nop",
        .stmt_method => "Stmt_ClassMethod",
        .stmt_class_const => "Stmt_ClassConst",
        .stmt_error => "Expr_Error",

        // 表达式
        .expr_variable, .expr_variable_ref => "Expr_Variable", // 间接变量 $$a/${expr} 同归 Expr_Variable
        .expr_int => "Scalar_Int",
        .expr_float => "Scalar_Float",
        .expr_string => "Scalar_String",
        .expr_const_fetch => "Expr_ConstFetch",
        .expr_binary => "Expr_BinaryOp",
        .expr_assign => "Expr_Assign",
        .expr_assign_op => "Expr_AssignOp",
        .expr_assign_ref => "Expr_AssignRef",
        .expr_unary => "Expr_UnaryOp",
        .expr_array => "Expr_Array",
        .expr_array_item => "Expr_ArrayItem",
        .expr_array_dim_fetch => "Expr_ArrayDimFetch",
        .expr_func_call => "Expr_FuncCall",
        .expr_new => "Expr_New",
        .expr_property_fetch => "Expr_PropertyFetch",
        .expr_static_property_fetch => "Expr_StaticPropertyFetch",
        .expr_class_const_fetch => "Expr_ClassConstFetch",
        .expr_static_call => "Expr_StaticCall",
        .expr_method_call => "Expr_MethodCall",
        .expr_nullsafe_property_fetch => "Expr_NullsafePropertyFetch",
        .expr_nullsafe_method_call => "Expr_NullsafeMethodCall",
        .expr_match => "Expr_Match",
        .expr_match_arm => "Expr_MatchArm",
        .expr_first_class_callable => "Expr_FirstClassCallable",
        .expr_closure => "Expr_Closure",
        .expr_arrow_function => "Expr_ArrowFunction",
        .expr_clone => "Expr_Clone",
        .expr_pipe => "Expr_Pipe",
        .expr_isset => "Expr_Isset",
        .expr_empty => "Expr_Empty",
        .expr_eval => "Expr_Eval",
        .expr_exit => "Expr_Exit",
        .expr_include => "Expr_Include",
        .expr_instanceof => "Expr_Instanceof",
        .expr_list => "Expr_List",
        .expr_ternary => "Expr_Ternary",
        .expr_throw => "Expr_Throw",
        .expr_print => "Expr_Print",
        .expr_shell_exec => "Expr_ShellExec",
        .expr_yield => "Expr_Yield",
        .expr_yield_from => "Expr_YieldFrom",
        .expr_error_suppress => "Expr_ErrorSuppress",
        .expr_post_inc => "Expr_PostInc",
        .expr_post_dec => "Expr_PostDec",
        .expr_cast => "Expr_Cast",
        .expr_argument => "Arg",
        .expr_encapsed => "Scalar_Encapsed",
        .expr_string_part => "Scalar_EncapsedStringPart",
        .expr_magic_const => "Scalar_MagicConst",

        // 名字 / 类型 / 属性
        .name => "Name",
        .name_fully_qualified => "Name_FullyQualified",
        .name_relative => "Name_Relative",
        .name_var_like => "Expr_Variable",
        .param => "Param",
        .type_name => "Type_",
        .type_nullable => "NullableType",
        .type_union => "UnionType",
        .type_intersection => "IntersectionType",
        .type_self => "Name",
        .type_parent => "Name",
        .type_static => "Name",
        .type_array_of => "Type_Array",
        .type_generic => "Type_Generic",
        .attribute => "Attribute",
        .attr_group => "AttributeGroup",
        .root => "Stmt_",
    };
}

// ===========================================================================
// 位置便捷 API（对齐 php-parser getStartLine/getStartFilePos 等）
// ===========================================================================

/// 起始 token 下标（对齐 php-parser `startTokenPos` 索引语义）。
pub fn startTokenPos(tree: Ast, node: Index) TokenIndex {
    return tree.firstToken(node);
}

/// 结束 token 下标（含）。
pub fn endTokenPos(tree: Ast, node: Index) TokenIndex {
    return tree.lastToken(node);
}

/// 起始字节偏移（对齐 `startFilePos`）。
pub fn startFilePos(tree: Ast, node: Index) usize {
    return tree.tokenStart(tree.firstToken(node));
}

/// 结束字节偏移（对齐 `endFilePos`；php-parser 语义为「最后一个字节之后」）。
pub fn endFilePos(tree: Ast, node: Index) usize {
    const t = tree.lastToken(node);
    return tree.tokenEnd(t);
}

/// 起始行号（1 基）。
pub fn startLine(tree: Ast, node: Index) usize {
    const loc = tree.tokenLocation(0, tree.firstToken(node));
    return loc.line + 1;
}

/// 结束行号（1 基）。
pub fn endLine(tree: Ast, node: Index) usize {
    const loc = tree.tokenLocation(0, tree.lastToken(node));
    return loc.line + 1;
}

// ===========================================================================
// doc comment 便捷（对齐 php-parser getDocComment）
// ===========================================================================

/// 取紧贴节点之前的 docblock 文本（无则 null）。非 docblock 的普通注释不返回。
/// 返回的切片在 `gpa` 上分配，由调用方释放。
pub fn getDocComment(tree: Ast, gpa: std.mem.Allocator, node: Index) !?[]u8 {
    const t = tree.docCommentBefore(node) orelse return null;
    return try gpa.dupe(u8, tree.tokenSlice(t));
}

// ===========================================================================
// attributes 旁表（对齐 php-parser setAttribute/getAttribute）
// ===========================================================================

/// 节点 → 任意键值（字符串键）的旁表。php-parser 把 attribute 挂节点上；
/// SoA 节点定长无法挂 → 以旁表承载，键值在 `gpa` 上分配、统一释放。
pub const AttrMap = struct {
    gpa: std.mem.Allocator,
    map: std.AutoHashMap(Index, std.StringHashMap([]const u8)),

    pub fn init(gpa: std.mem.Allocator) AttrMap {
        return .{ .gpa = gpa, .map = std.AutoHashMap(Index, std.StringHashMap([]const u8)).init(gpa) };
    }

    pub fn deinit(self: *AttrMap) void {
        var it = self.map.iterator();
        while (it.next()) |kv| {
            var inner = kv.value_ptr.*;
            var iit = inner.iterator();
            while (iit.next()) |p| {
                self.gpa.free(p.key_ptr.*);
                self.gpa.free(p.value_ptr.*);
            }
            inner.deinit();
        }
        self.map.deinit();
        self.* = undefined;
    }

    /// 设置属性（拷贝 key/value 到 gpa）。已存在同名则覆盖旧值。
    pub fn set(self: *AttrMap, node: Index, key: []const u8, value: []const u8) !void {
        const gpa = self.gpa;
        const gop = try self.map.getOrPut(node);
        if (!gop.found_existing) {
            gop.value_ptr.* = std.StringHashMap([]const u8).init(gpa);
            errdefer {
                gop.value_ptr.*.deinit();
                _ = self.map.remove(node);
            }
        }
        const inner = &gop.value_ptr.*;
        if (inner.get(key)) |old| {
            // 覆盖：替换 value
            const v = try gpa.dupe(u8, value);
            gpa.free(old);
            try inner.put(key, v);
            return;
        }
        // 新增：key/value 都拷贝
        const k = try gpa.dupe(u8, key);
        errdefer gpa.free(k);
        const v = try gpa.dupe(u8, value);
        errdefer gpa.free(v);
        try inner.put(k, v);
    }

    /// 取属性；无返回 null。
    pub fn get(self: AttrMap, node: Index, key: []const u8) ?[]const u8 {
        const inner = self.map.get(node) orelse return null;
        return inner.get(key);
    }
};

// ===========================================================================
// 测试
// ===========================================================================

const testing = @import("testing.zig");

test "compat :: phpParserType :: 核心 tag 映射" {
    try std.testing.expectEqualStrings("Stmt_If", phpParserType(.stmt_if));
    try std.testing.expectEqualStrings("Expr_New", phpParserType(.expr_new));
    try std.testing.expectEqualStrings("Expr_FuncCall", phpParserType(.expr_func_call));
    try std.testing.expectEqualStrings("Scalar_Int", phpParserType(.expr_int));
    try std.testing.expectEqualStrings("Name_FullyQualified", phpParserType(.name_fully_qualified));
    try std.testing.expectEqualStrings("Stmt_ClassMethod", phpParserType(.stmt_method));
}

test "compat :: 位置 API :: 与 token 区间一致" {
    const gpa = std.testing.allocator;
    var tree = try ast.Ast.parse(gpa,
        "<?php\nfunction f() {\n    return 1;\n}\n", testing.v84);
    defer tree.deinit(gpa);
    try testing.expectNoErrors(tree);

    const fn_node = (try @import("node_finder.zig").findFirstTag(gpa, tree, tree.root, .stmt_function)) orelse return error.TestUnexpectedResult;
    // startLine 是 2（函数定义在源码第 2 行，1 基）
    try std.testing.expectEqual(@as(usize, 2), startLine(tree, fn_node));
    // endLine >= startLine
    try std.testing.expect(endLine(tree, fn_node) >= startLine(tree, fn_node));
    // filePos 与 tokenSlice 一致
    const sp = startFilePos(tree, fn_node);
    try std.testing.expectEqual(tree.tokenSlice(tree.firstToken(fn_node)), tree.source[sp .. sp + tree.tokenSlice(tree.firstToken(fn_node)).len]);
}

test "compat :: getDocComment :: 取回 docblock 文本" {
    const gpa = std.testing.allocator;
    var tree = try ast.Ast.parse(gpa,
        "<?php\n/**\n * 描述\n */\nfunction f() {}\n", testing.v84);
    defer tree.deinit(gpa);
    try testing.expectNoErrors(tree);

    const fn_node = (try @import("node_finder.zig").findFirstTag(gpa, tree, tree.root, .stmt_function)) orelse return error.TestUnexpectedResult;
    const doc = (try getDocComment(tree, gpa, fn_node)) orelse return error.TestUnexpectedResult;
    defer gpa.free(doc);
    try std.testing.expect(std.mem.indexOf(u8, doc, "描述") != null);
}

test "compat :: AttrMap :: set/get/覆盖/缺失" {
    const gpa = std.testing.allocator;
    var m = AttrMap.init(gpa);
    defer m.deinit();

    const n1: Index = @enumFromInt(1);
    try m.set(n1, "kind", "class");
    try m.set(n1, "line", "42");
    try std.testing.expectEqualStrings("class", m.get(n1, "kind").?);
    try std.testing.expectEqualStrings("42", m.get(n1, "line").?);
    // 覆盖
    try m.set(n1, "kind", "interface");
    try std.testing.expectEqualStrings("interface", m.get(n1, "kind").?);
    // 缺失
    const n2: Index = @enumFromInt(2);
    try std.testing.expect(m.get(n2, "kind") == null);
    try std.testing.expect(m.get(n1, "missing") == null);
}
