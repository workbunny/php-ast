<?php
declare(strict_types=1);

namespace App\Service;

use Foo\Bar;
use Foo\{Baz, Qux as Q};
use function strlen;
use const PHP_EOL;

const A = 1, B = 2;

interface Shape {
    public function area(): float;
}

trait Logger {
    use Other { Other::log as write; }
}

enum Suit: string {
    case Hearts;
    case Clubs = 'c';
}
