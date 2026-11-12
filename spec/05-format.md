# 05 — Formats {#format}

A unit and a quantity say what a number is ([03](03-units.md)); a **format** says how it is written for a person. macaw_data holds the format beside them, so every Macaw package writes a value one way: a stat tile and an axis tick over one field show it alike (macaw_data#251). `Macaw.Data.Format` is a port of visualize's `Visualize.Format`, whose number notation is d3-format's, and its output is visualize's byte for byte over visualize's own cases, which carry d3's.

## 1. A format is data {#format-data}

**A format is a struct with no function in it**, `%Macaw.Data.Format{}`, as a schema is ([02 §1.1](02-derived.md#derived-value)): it can be compared, digested and carried in a delivery, and a document holds the text it is written in. **`Macaw.Data.Format.parse(specifier, opts)`** reads a d3-format specifier (§2) once and answers `{:ok, format}`, or `{:error, faults}` ([00 §5](00-overview.md#data-errors)):
- a string that is no specifier is `{[], {:specifier, text}}`, and a term that is no string `{[], {:type, :specifier}}`;
- a width over 1,024 is `{[], {:width, 1024}}`. d3 bounds none, but a document is untrusted, and a width is the length of the string it writes;
- its one option is `locale:`, a `Macaw.Data.Format.Locale` (§3), English by default: another key is `{[key], :unknown_key}`, options that are no keyword list `{[], {:type, :keyword}}`, and a locale that is no `Locale` `{[:locale], {:type, :locale}}`.

`parse!/2` answers the format alone or raises `Macaw.Data.Error` with the faults in `format_error/1`'s words. A format keeps the text it was read from (`specifier`), each part of the grammar normalized as d3 normalizes it, and its locale, so two formats read from one text under one locale are equal.

**`Macaw.Data.Format.number(format, value)`** writes a value by a format, a string. Nothing the caller passes can fail: a value that is no number (`nil`, text, any other term) is written as the locale's not-a-number, `NaN` in English, with the format's padding and alignment, as d3 writes `NaN`; under the `c` type every value is written as text (§2).

```test:format-data-parse
parse/2 answers a format struct holding no function, equal for one text under one locale; a string that is no specifier, a term that is no string, a width past 1,024, an unknown option and a locale that is no Locale are faults; parse!/2 raises them worded; number/2 writes any term, a non-number as NaN
```

## 2. The notation {#format-notation}

A specifier is d3-format's: `[[fill]align][sign][symbol][0][width][,][.precision][~][type]`.
- **fill** is any one character, written only before an **align**: `>` right (the default), `<` left, `^` center, `=` after the sign and symbol, before the digits.
- **sign**: `-` a minus for a negative only (the default), `+` a plus or a minus, `(` parentheses around a negative, a space for a positive.
- **symbol**: `$` the locale's currency before and after (§3); `#` the `0b`, `0o` and `0x` prefixes of the `b`, `o`, `x` and `X` types.
- **`0`** is zero fill: fill `0` and align `=`, which `0=` also is.
- **width** is the least length written, in characters; **`,`** groups the integer digits by the locale's grouping (§3), and with zero fill the zeros are grouped too, the grouped digits kept within the width.
- **precision** is the digits after the point for `e`, `f` and `%`, the significant digits for `g`, `p`, `r` and `s`: a significant precision is held to 1 to 21, any other to 0 to 20, and an absent one is 6.
- **`~`** trims insignificant trailing zeros, and a point left with none after it.
- **type**: `e` exponent notation; `f` fixed point; `g` either, as JavaScript's `toPrecision`; `r` decimal rounded to significant digits; `s` decimal with an SI prefix (`y` to `Y`, `µ` for micro), the prefix of the value's thousands exponent; `%` multiplied by 100, fixed, then a percent sign; `p` multiplied by 100, rounded to significant digits, then a percent sign; `d` the integer rounded to; `b`, `o`, `x` and `X` the integer rounded to in base 2, 8 and 16 (`X` upper case); `c` the value as text; `n` is `,g`. No type, or a letter none of these, is `g` with `~`, its precision 12 unless one is written.

Any other text is no specifier: `..2f`, `q!`, a trailing newline.

**The digits are d3's.** Rounding to a precision picks, of the two nearest, the one farther from zero, on the double's exact value, as JavaScript's `toFixed`, `toExponential` and `toPrecision` do: `.1e` writes 0.125 as `1.3e-1` and `.2s` writes 125 as `130`, where a rounding to even would give `1.2e-1` and `120`. An exponent is written unpadded with its sign, `1.23e+3`. A negative that rounds to zero is written without its sign unless the sign is `+`, and so is negative zero: `.1f` writes −0.01 as `0.0`, and `+.1f` writes it `-0.0`. Below a yocto, `s` writes the digits that fit (`.2s` of 10⁻²⁵ is `0.1y`).

**Where this differs from d3, it says so.** An integer is written by `d`, `b`, `o`, `x` and `X` from its exact digits, and a float past 2⁵³ from the integer it holds exactly, where JavaScript's number would round both to 17 digits. An integer past a double's range, which JavaScript would read as infinity, is `Infinity` under the other types, signed as a number is. `f` and `%` write a value past 10²¹ in full, where JavaScript's `toFixed` switches to an exponent. A value written by `c` is written as `to_string/1` writes a string, a number or an atom, and as `NaN` for any other term.

```test:format-notation-conformance
every case of visualize's d3-format conformance set writes byte for byte what visualize writes: the types, fill and align, the signs, the symbols, zero fill with grouping inside the width, trimming, the clamped precisions, the SI prefixes past yocto, and NaN padded
```

```test:format-notation-digits
a tie rounds away from zero on the exact double, as JavaScript does; a negative that rounds to zero and negative zero lose their sign unless it is +; integers write their exact digits; an integer past a double's range is Infinity; c writes text, numbers and atoms and NaN for any other term
```

## 3. The locale {#format-locale}

**A locale is a d3-format locale definition**, `%Macaw.Data.Format.Locale{}`, data like the format that holds it:

| Field | English | What it is |
|---|---|---|
| `decimal` | `"."` | the decimal point |
| `thousands` | `","` | the group separator |
| `grouping` | `[3]` | the group sizes from the right, used in turn and then again from the first, as d3 does; `[]` groups nothing |
| `currency` | `{"$", ""}` | what the `$` symbol writes before and after the number |
| `minus` | `"-"` | the minus sign |
| `nan` | `"NaN"` | what a value that is no number is written as |
| `percent` | `"%"` | the percent sign of `%` and `p` |
| `symbols` | `USD` `$`, `EUR` `€`, `GBP` `£`, `JPY` `¥` | each ISO 4217 code ([03 §4](03-units.md#units-currency)) the locale writes by a symbol; any other is written by its code |

`Macaw.Data.Format.Locale.english/0` is the default. **Its minus is the hyphen-minus,** as visualize writes it, where d3's default is `−` (U+2212): text a reader copies into a field reads back as a number. `Macaw.Data.Format.Locale.new(fields)` builds a locale from a keyword list or a map of these fields, each one absent being English's, and answers `{:ok, locale}` or `{:error, faults}`: a key it does not take is `{[key], :unknown_key}`; a field of the wrong kind `{[key], {:type, kind}}` (`:text` for the strings, `:grouping` for a list of positive integers, `:currency` for a pair of strings, `:symbols` for a map); a symbol under a code not in the ISO table `{[:symbols, code], {:unknown_currency, code}}`; fields that are neither a keyword list nor a map, a list holding anything but pairs among them, `{[], {:type, :keyword}}`. `new!/1` raises them. A locale is the viewer's choice, as the unit system is ([03 §12](03-units.md#quantities-systems)): nothing is derived from it, and it never changes the data.

```test:format-locale-definition
english/0 is the table's English; new/1 takes a keyword list or a map over English, and writes d3's outputs for another locale's decimal, thousands, grouping, currency, minus, nan and percent; a key it does not take, a field of the wrong kind, a symbol under an unknown code and fields that are neither are faults, and new!/1 raises them
```

## 4. Cost {#format-cost}

**The common formats write through the BIFs** (macaw_data#253). A board writes hundreds of readouts a frame, so a format is not only correct but cheap. A format whose type is `f`, `%` or `d`, with no width, no `~` and the `-` sign, under any symbol, grouping and locale (`,.2f`, `.1f`, `.0%`, `d`, `,d`, `$,.2f`), writes a float, and under `d` an integer too, with one call of `:erlang.float_to_binary/2` or `Integer.to_string/1`: its digits are that call's answer, the integer digits grouped by slicing it, and the string is built once. Every other format, and every other value, takes §2's path. **The two write the same string** for every value and every such format, which a property holds against §2's path.

A BIF is charged a few reductions whatever its work, so a call's cost is stated in both: for 1,000 floats (integers for `d`, ratios for `.0%`), the median of 15 runs on a box at load 12, against visualize's port of the same formats and the bare BIF.

| Format | visualize's port | §2's path | This path | The BIF alone |
|---|---|---|---|---|
| `,.2f` | 155,384 r, 5.70 ms | 116,195 r, 2.57 ms | 13,300 r, 0.33 ms | 4,007 r, 0.060 ms |
| `d` | 64,304 r, 4.24 ms | 62,310 r, 1.26 ms | 10,314 r, 0.23 ms | 1,007 r, 0.058 ms |
| `.0%` | 61,721 r, 4.15 ms | 58,629 r, 1.91 ms | 12,008 r, 0.22 ms | 4,007 r, 0.060 ms |
| `$,.2f` | 161,211 r, 6.37 ms | 122,023 r, 3.26 ms | 13,301 r, 0.35 ms | 4,007 r, 0.060 ms |

So `d` and `.0%` cost under 4 times the bare BIF, and the grouped `,.2f` and `$,.2f` under 6. The other types keep §2's path: `.3s` and `.3~r` cost about 107,000 and 100,000 reductions and 3.6 ms per 1,000, against visualize's 7.5 and 10.0 ms.

The suite holds each of the four to a budget in reductions, which a busy box does not move.

```test:format-cost-identical
for generated floats and integers, signed zeros, values that round to zero and values past a double's range, every format of the common shapes, under English and locales of other separators and groupings, writes the string §2's path writes
```

```test:format-cost-budget
1,000 values written by ,.2f, d, .0% and $,.2f each cost at most their budget in reductions
```
