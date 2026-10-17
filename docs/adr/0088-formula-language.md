# ADR 0088 — The formula language

_Date: 2026-10-17_
_Status: accepted 2026-10-17_

_Implements: ADR 0086 phase 2_

## Context

Any number in rule JSON can be a formula string, for example
`"clamp(world.wind / 10, 0.1, 0.9)"`. `Formula` gives each string to
Godot's `Expression`. Nothing limits what `Expression` accepts:

- Every GDScript global function, for example `wrapf`, `fmod` and
  `str`.
- Constructors, for example `Vector2(1, 2)`.
- Method calls on a bound value.
- GDScript number rules.

The contract document says that a whitelist rejects unknown calls at
load time. No such whitelist exists.

ADR 0086 makes the JSON a host-neutral spec. A second interpreter can
copy the formula language only if the spec defines it. A probe of
Godot 4.6.1 on 2026-10-17 found these traps:

| Formula | Godot result | Why it is a trap |
|---|---|---|
| `5 / 2` | `2` | Integer division. JavaScript and Python give 2.5. |
| `world.tick / 60` | integer | `world.tick` is an integer in the engine. |
| `-7 / 2` | `-3` | Integer division truncates toward zero. |
| `true * 3` | error | Arithmetic on a boolean fails. |
| `7.5 % 2` | error | `%` works only on integers. |
| `a[1.7]` | `a[1]` | A float index truncates. |

The census of the same date read the 292 rule formulas in the demos.
They call 12 functions: `sin`, `cos`, `clamp`, `randf`, `pow`, `abs`,
`max`, `sqrt`, `floor`, `atan2`, `min` and `float`. They also use
subscripts, comparisons and parentheses. No formula uses `%`, a string
literal, a method call, a constructor or a bitwise operator. No
formula depends on integer division.

The owner approved two choices on 2026-10-17: every number is a float,
and a fixed list of 16 functions.

## Decision

### 1. Numbers

Every number in a formula is a float. This includes literals, bound
values and results.

- `5 / 2` gives `2.5`. `-7 / 2` gives `-3.5`.
- Division by zero follows IEEE 754: `1 / 0` gives infinity.
- A subscript index uses the integer part of its value. `a[1.7]` reads
  `a[1]`.

The Godot interpreter writes each integer literal as a float literal,
and it turns each integer input into a float before it evaluates.

### 2. Booleans

A comparison gives a boolean. `and`, `or` and `not` take booleans.
Arithmetic on a boolean is an error. `float(b)` gives `1.0` for true
and `0.0` for false. `true` and `false` are literals.

### 3. The grammar

```
formula  := or
or       := and ("or" and)*
and      := not ("and" not)*
not      := "not" not | compare
compare  := sum (("==" | "!=" | "<" | "<=" | ">" | ">=") sum)?
sum      := product (("+" | "-") product)*
product  := unary (("*" | "/") unary)*
unary    := "-" unary | "+" unary | atom
atom     := number | "true" | "false" | binding subscript*
          | function "(" args? ")" | "(" formula ")"
args     := formula ("," formula)*
binding  := root ("." field)+
```

- A `root` is a binding that the rule's trigger provides: `self`,
  `target`, `source`, `a`, `b`, `world` and the query's named roles.
  `validate_rules.py` check (1) owns this list.
- A missing field reads as `0`. This is the current behavior.
- A formula that is only a binding returns the bound value unchanged.
  It can return a string, for example `self.id`.

Not in the language: `%`, `**`, string literals, method calls,
constructors, array literals, `&&`, `||`, `!`, bitwise operators and
the ternary `a if cond else b`.

### 4. The functions

| Function | Result |
|---|---|
| `abs(x)` | absolute value |
| `floor(x)`, `ceil(x)`, `round(x)` | nearest whole number, as a float. `round` rounds a half away from zero. |
| `min(a, b)`, `max(a, b)` | the smaller or the larger value |
| `clamp(x, lo, hi)` | `x` limited to the range `lo` to `hi` |
| `lerp(a, b, t)` | `a + (b - a) * t` |
| `sqrt(x)`, `pow(x, y)` | square root and power |
| `sin(x)`, `cos(x)`, `tan(x)` | trigonometry in radians |
| `atan2(y, x)` | the angle of the point (x, y), in radians |
| `randf()` | a uniform random number from 0 to 1, without 1 |
| `float(x)` | a boolean as `1.0` or `0.0`, or a number unchanged |

A new function needs an ADR. The seed of `randf` stays ADR 0086 open
question 1.

### 5. Enforcement

- `const FUNCTIONS` in `formula.gd` is the one source of the function
  list.
- Before `Formula` gives a string to `Expression`, it reads the string
  token by token. It rejects a call to a name outside `FUNCTIONS` with
  `formula.unknown_function`. It rejects every other construct outside
  the grammar with `formula.parse_failed`.
- `validate_rules.py` check (12) reads `FUNCTIONS` from `formula.gd`
  and applies the same token rules to rule JSON before the game runs.
  It replaces the ternary-only check.
- `gen_api_manifest.py` reads `FUNCTIONS` for the manifest.
- The contract document gets the grammar and the function table, as
  ADR 0086 phase 5 permits.

## Consequences

- A formula has one meaning in every interpreter. An interpreter in
  JavaScript, Python or C# uses its native float type.
- The LLM cannot write integer division by accident.
- The contract document stops promising a whitelist that did not
  exist.
- Results that came out as integers before now come out as floats.
  JSON numbers load as floats in Godot, so state values do not change
  type. Engine integers such as `world.tick` now enter formulas as
  floats.
- `Formula.validate_syntax` had no callers. This ADR deletes it.
- Known gap: a binding can hold a vector, and Godot accepts arithmetic
  on vectors. The spec defines arithmetic on numbers only. The check
  reads tokens, not types, so it cannot reject vector arithmetic. No
  current formula does it.

## Alternatives considered

- **Keep the Godot number rules and write them down.** Each
  interpreter must then track integer and float types the way GDScript
  does. Most hosts do not have this split. The owner rejected it.
- **A larger function list (`sign`, `fmod`, `wrapf`).** Nothing uses
  them. A function can join later through an ADR.
- **Write a formula parser and stop using `Expression`.** This breaks
  ADR 0021 (expose, do not reimplement). The token check gives the
  same guarantee at a smaller cost.
