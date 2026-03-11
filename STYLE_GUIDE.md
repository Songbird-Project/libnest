# Style Guide

This document should be followed when making contributions to `libnest`.
Only the style of the code is documented here.

## Indentation

Indents should be tabs not spaces, each level uses 1 tab.

## Functions

Function arguments should be split across lines when the number of arguments is
greater than or equal to 3.

```zig
fn (foo: usize, bar: usize) ...
fn (
    foo: usize,
    bar: usize,
    baz: usize,
) ...
```
