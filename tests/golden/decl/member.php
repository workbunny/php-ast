<?php
abstract class Base implements Iface {
    public const A = 1;
    protected readonly string $ro;
    private static ?int $counter = null;
    public array $list = [1, 2, 3];

    public function __construct(
        public readonly int $x,
        protected string $y = 'default',
        private ?Foo $z = null,
    ) {}

    abstract public function mustImplement(): void;

    final public static function create(): static {
        return new static();
    }

    public function __get(string $name): mixed {
        return $this->$name ?? null;
    }
}
