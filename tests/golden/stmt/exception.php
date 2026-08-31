<?php
try {
    foo();
} catch (FooException | BarException $e) {
    throw new RuntimeException('x', 0, $e);
} finally {
    cleanup();
}

function gen() {
    yield 1;
    yield $k => $v;
    yield from $it;
}
