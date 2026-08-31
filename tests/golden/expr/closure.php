<?php
$fn = fn ($p) => $p + 1;
$closure = function ($p) use ($y): int {
    return $p;
};
$static = static function () {};
$byRef = function (&$p) {};
$variadic = function (...$args) {};
$nullable = function (): ?int { return null; };
$arrowTyped = fn (int $x): string => (string)$x;
