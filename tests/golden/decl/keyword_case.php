<?php
// 关键字作名字的接受面：词法器按忽略大小写切关键字 tag，而各名字位的关键字集合不同
// （php.y）。本样例钉住这些边界，防止后续调整名字判定时无意放宽/收窄：
//   · 声明名位 identifier_not_reserved = 仅 T_STRING       → `class List {}` 语法错
//   · 方法名   identifier_maybe_reserved = T_STRING | semi_reserved → `function list() {}` 合法
//   · 顶层函数名 fn_identifier = T_STRING | readonly/exit/die/clone/fn → `function list()` 语法错
//   · 成员名 / 类常量名 / 命名参数名同样接受 semi_reserved
class Foo
{
    const TRAIT = 3;
    public function list()
    {
    }
    public function readonly()
    {
    }
}
function fn()
{
}
$o->list();
$o->class;
bar(class: 1);

// 以下为语法错形态（诊断一并写入快照）
class ReadOnly
{
}
function list()
{
}
new ReadOnly();
ReadOnly::FOO;
