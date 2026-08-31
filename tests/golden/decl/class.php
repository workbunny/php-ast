<?php
class Foo extends Bar implements Baz {
    public const NAME = 'x';
    public int $n = 1;
    public string $s {
        get => $this->s;
        set(string $v) => $this->s = $v;
    }
    public function __construct(public int $x, private string $y = '') {}
    public static function make(): static { return new static(); }
}
