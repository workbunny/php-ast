<?php
function f(
    int|string $u,
    ?Foo\Bar $n,
    A&B $i,
    (Countable&ArrayAccess)[] $dnf,
    list<int> $g,
    self $s,
    static $st,
    callable $c,
    mixed $m
): A&B|null {
    return null;
}
