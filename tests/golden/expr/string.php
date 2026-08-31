<?php
$s1 = 'single';
$s2 = "double $v";
$s3 = "{$obj->prop} and {$arr['k']}";
$s4 = <<<EOT
heredoc $v text
EOT;
$s5 = <<<'EOT'
nowdoc $v text
EOT;
