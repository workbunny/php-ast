<?php
if ($a) { echo 1; } elseif ($b) { echo 2; } else { echo 3; }
while ($c) { break; }
for ($i = 0; $i < 3; $i++) { continue; }
for (;;) { break; }
foreach ($xs as $k => $v) {}
do { $n--; } while ($n > 0);
switch ($s) {
    case 1:
        break;
    default:
        echo 2;
}
