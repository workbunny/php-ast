<?php
$a = 1 + 2 * 3 - 4 / 5 % 6;
$b = -$a ** 2;
$c = $a == 1 and $b != 2 or $c === 3 xor $d !== 4;
$d = $a < 1 && $b > 2 || !$c;
$e = $a & $b | $c ^ ~$d;
$f = $a << 1 >> 2;
$g = $a instanceof Foo;
$h = @foo();
$i = `ls -l`;
$j = print $a;
$k = (int)$a . (string)$b;
$l = $a <=> $b;
$m = -5;
$n = +$a;
