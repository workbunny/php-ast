<?php
while ($a) {
    do_something();
}

do {
    $n--;
} while ($n > 0);

for ($i = 0, $j = 1; $i < 10; $i++, $j--) {
    continue;
}

foreach ($list as $item) {
    echo $item;
}

foreach ($map as $key => $value) {
    break;
}

foreach ($gen as $k => &$v) {
    $v++;
}
