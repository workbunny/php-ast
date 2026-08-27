/// 词法器测试套件，独立于库代码。库以命名模块 `php_ast` 导入，避免 `../` 越过模块根。
const std = @import("std");
const Token = @import("php_ast").token.Token;
const Lexer = @import("php_ast").lexer.Lexer;

test "tokenize 产出 token 流" {
    const gpa = std.testing.allocator;
    var toks = Token.TokenList{};
    defer toks.deinit(gpa);
    try Lexer.tokenize(gpa, "<?php echo \"hi\";", &toks);
    var s = toks.toOwnedSlice();
    defer s.deinit(gpa);
    try std.testing.expect(s.len >= 6);
    try std.testing.expect(s.items(.tag)[0] == .open_tag);
    try std.testing.expect(s.items(.tag)[1] == .kw_echo);
    try std.testing.expect(s.items(.tag)[2] == .string_start);
    try std.testing.expect(s.items(.tag)[3] == .string_part);
    try std.testing.expect(s.items(.tag)[4] == .string_end);
    try std.testing.expect(s.items(.tag)[5] == .semicolon);
}
