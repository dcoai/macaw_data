# 03 — Units and quantities {#units}

<!-- surfex: class orientation -->

**Units and quantities come from one vocabulary,** so nothing translates between two ([01 §1](01-sources.md#sources-data); metresis.md C1). A field's schema names its unit and its quantity from this vocabulary, and visualize, metresis and Macaw's components all read it. It is visualize's vocabulary (its spec/05 §4), moved here so every adopter shares it: `Macaw.Data.Unit` and `Macaw.Data.Quantity`. How a value is drawn in its unit (the display unit an axis picks, its tick formats, a value written in a locale) stays with the drawing library, visualize's `Visualize.Quantity`, built on this vocabulary.

## 1. Units are UCUM codes {#units-codes}

A unit is named by its code in the **Unified Code for Units of Measure** (UCUM, <https://ucum.org/ucum>, Regenstrief Institute; the atoms and prefixes below are checked against its essence table, version 2.2 of 2024-06-17): case-sensitive, unambiguous codes built for exchange between machines and the ones OpenTelemetry's semantic conventions use. One name per unit is the point (visualize#536, D-138, D-155): a source that says `"s"` and one that says `"sec"` must not draw two labels, so a code is checked, never guessed at. `Macaw.Data.Unit` reads the subset of UCUM's grammar (§2.1 of UCUM's specification, *Syntax rules*) that measurement data uses, over a fixed table of atoms and prefixes, strict enough to refuse a typo and permissive enough for the codes real sources send:

```
code       = "/" term | term
term       = component { ("." | "/") component }      left-associative, as UCUM §2.1.3
component  = annotation
           | unit [exponent] [annotation]
           | factor [annotation]
unit       = [prefix] atom                             a prefix only on a metric atom
exponent   = ["+" | "-"] digit { digit }
factor     = digit { digit }                           a positive integer, "1" the unity
annotation = "{" char { char } "}"                     ASCII 33–126 except "{" and "}"
```

A unit's symbol is a run of letters, `%` and bracketed parts — `[` up to the next `]` — so `[ft_i]`, `m[Hg]`, `mm[Hg]`, `B[SPL]` and `dB[SPL]` are each one symbol, as UCUM writes them; an exponent or an annotation ends it (`[ft_i]2`, `By{heap}`).

| Prefix | `da` | `h` | `k` | `M` | `G` | `T` | `d` | `c` | `m` | `u` | `n` | `p` | `Ki` | `Mi` | `Gi` | `Ti` |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| Factor | 10¹ | 10² | 10³ | 10⁶ | 10⁹ | 10¹² | 10⁻¹ | 10⁻² | 10⁻³ | 10⁻⁶ | 10⁻⁹ | 10⁻¹² | 2¹⁰ | 2²⁰ | 2³⁰ | 2⁴⁰ |

The atoms, each with UCUM's definition (the *Factor* column is to the base of its dimension, below):

| Atom | Name | Metric | Dimension | Factor to the base | UCUM's definition | Symbol |
|---|---|---|---|---|---|---|
| `s` | second | yes | time | 1 | base | `s` |
| `min` | minute | no | time | 60 | 60 `s` | `min` |
| `h` | hour | no | time | 3,600 | 60 `min` | `h` |
| `d` | day | no | time | 86,400 | 24 `h` | `d` |
| `By` | byte | yes | information | 1 | 8 `bit` | `B` |
| `bit` | bit | yes | information | 1/8 | `1` | `bit` |
| `%` | percent | no | none | 1/100 | 10⁻² | `%` |
| `[ppm]` | parts per million | no | none | 10⁻⁶ | 10⁻⁶ | `ppm` |
| `[ppb]` | parts per billion | no | none | 10⁻⁹ | 10⁻⁹ | `ppb` |
| `mol` | mole | yes | none | 6.02214076 × 10²³ | 6.02214076 × 10²³ | `mol` |
| `Hz` | hertz | yes | time⁻¹ | 1 | `s-1` | `Hz` |
| `Cel` | degree Celsius | yes | temperature | — (affine) | `cel(1 K)` | `°C` |
| `[degF]` | degree Fahrenheit | no | temperature | — (affine) | `degf(5 K/9)` | `°F` |
| `K` | kelvin | yes | temperature | 1 | base | `K` |
| `m` | meter | yes | length | 1 | base | `m` |
| `[in_i]` | inch | no | length | 127/5,000 | 2.54 `cm` | `in` |
| `[ft_i]` | foot | no | length | 381/1,250 | 12 `[in_i]` | `ft` |
| `[yd_i]` | yard | no | length | 1,143/1,250 | 3 `[ft_i]` | `yd` |
| `[mi_i]` | mile | no | length | 201,168/125 | 5,280 `[ft_i]` | `mi` |
| `[nmi_i]` | nautical mile | no | length | 1,852 | 1,852 `m` | `nmi` |
| `ar` | are | yes | length² | 100 | 100 `m2` | `a` |
| `[acr_us]` | acre (US survey) | no | length² | 62,726,400,000/15,499,969 | 160 `[rd_us]2`, the rod 16.5 survey feet of 1,200/3,937 `m` | `ac` |
| `l`, `L` | liter | yes | length³ | 1/1,000 | `dm3` | `l`, `L` |
| `[foz_us]` | US fluid ounce | no | length³ | 473,176,473/16 × 10⁻¹² | `[gal_us]`/128 | `fl oz` |
| `[pt_us]` | US pint | no | length³ | 473,176,473 × 10⁻¹² | `[gal_us]`/8 | `pt` |
| `[gal_us]` | US gallon | no | length³ | 473,176,473/125 × 10⁻⁹ | 231 `[in_i]3` | `gal` |
| `[foz_br]` | imperial fluid ounce | no | length³ | 454,609/16 × 10⁻⁹ | `[gal_br]`/160 | `fl oz` |
| `[pt_br]` | imperial pint | no | length³ | 454,609/8 × 10⁻⁸ | `[gal_br]`/8 | `pt` |
| `[gal_br]` | imperial gallon | no | length³ | 454,609 × 10⁻⁸ | 4.54609 `l` | `gal` |
| `g` | gram | yes | mass | 1 | base | `g` |
| `t` | tonne | yes | mass | 10⁶ | 10³ `kg` | `t` |
| `[oz_av]` | ounce (avoirdupois) | no | mass | 45,359,237/1,600,000 | `[lb_av]`/16 | `oz` |
| `[lb_av]` | pound (avoirdupois) | no | mass | 45,359,237/100,000 | 7,000 grains of 64.79891 `mg` | `lb` |
| `[stone_av]` | stone | no | mass | 317,514,659/50,000 | 14 `[lb_av]` | `st` |
| `[kn_i]` | knot | no | length·time⁻¹ | 463/900 | `[nmi_i]/h` | `kn` |
| `W` | watt | yes | mass·length²·time⁻³ | 1,000 | `J/s` | `W` |
| `[HP]` | horsepower | no | mass·length²·time⁻³ | 37,284,993,579,113,511/(5 × 10¹⁰) | 550 `[ft_i].[lbf_av]/s` | `hp` |
| `J` | joule | yes | mass·length²·time⁻² | 1,000 | `N.m` | `J` |
| `cal` | calorie (thermochemical) | yes | mass·length²·time⁻² | 4,184 | `cal_th`, 4.184 `J` | `cal` |
| `[Cal]` | nutrition-label Calorie | no | mass·length²·time⁻² | 4,184,000 | `kcal_th` | `Cal` |
| `Pa` | pascal | yes | mass·length⁻¹·time⁻² | 1,000 | `N/m2` | `Pa` |
| `bar` | bar | yes | mass·length⁻¹·time⁻² | 10⁸ | 10⁵ `Pa` | `bar` |
| `[psi]` | pound per square inch | no | mass·length⁻¹·time⁻² | 8,896,443,230,521/1,290,320 | `[lbf_av]/[in_i]2` | `psi` |
| `m[Hg]` | meter of mercury | yes | mass·length⁻¹·time⁻² | 133,322,000 | 133.3220 `kPa` | `mHg` |
| `[in_i'Hg]` | inch of mercury | no | mass·length⁻¹·time⁻² | 16,931,894/5 | `m[Hg].[in_i]/m` | `inHg` |
| `rad` | radian | yes | angle | 1 | base | `rad` |
| `deg` | degree | no | angle | π/180 | `[pi].rad/360` × 2 | `°` |
| `C` | coulomb | yes | charge | 1 | base | `C` |
| `A` | ampere | yes | charge·time⁻¹ | 1 | `C/s` | `A` |
| `V` | volt | yes | mass·length²·time⁻²·charge⁻¹ | 1,000 | `J/C` | `V` |
| `lx` | lux | yes | luminous intensity·angle²·length⁻² | 1 | `lm/m2`, the lumen `cd.sr`, the steradian `rad2` | `lx` |
| `B` | bel | yes | level | 1 (logarithmic) | `lg(1 1)` | `B` |
| `B[SPL]` | bel sound pressure | yes | sound pressure level | 1 (logarithmic) | `2lg(2 10*-5.Pa)` | `B(SPL)` |

The bases are the second, the byte, the meter, the gram, the kelvin, the radian and the coulomb, so a watt is 1,000 g·m²·s⁻³, and the pound-force of `[HP]` and `[psi]` is `[lb_av]` times the standard acceleration of free fall, 9.80665 `m/s2`. A **symbol is matched whole before it is split**: `min` is the minute and `m` the meter, never a milli-`in` or a milli-nothing; `h` is the hour, `d` the day, `t` the tonne, `cal` the calorie and `bar` the bar, and only a symbol that is not an atom is read as a prefix and a metric atom, longest prefix first (`MiBy` is `Mi`·`By`, `dam` is `da`·`m`, `ms` is `m`·`s`, `kW` is `k`·`W`, `hPa` is `h`·`Pa`, `har` is `h`·`ar`, the hectare, `mm[Hg]` is `m`·`m[Hg]`, `dB` is `d`·`B`). So `s`, `ms`, `us`, `ns`, `min`, `h`, `d`, `By`, `kBy`, `MBy`, `GBy`, `TBy`, `KiBy`, `MiBy`, `GiBy`, `TiBy`, `bit`, `kbit`, `Mbit`, `%`, `[ppm]`, `Hz`, `kHz`, `Cel`, `[degF]`, `K`, `m`, `mm`, `cm`, `km`, `[in_i]`, `[ft_i]2`, `[mi_i]/h`, `[kn_i]`, `m2`, `har`, `[acr_us]`, `ml`, `dl`, `l`, `L`, `m3`, `[gal_us]`, `[pt_br]`, `g`, `kg`, `t`, `[lb_av]`, `[stone_av]`, `m/s`, `km/h`, `min/km`, `s-1`, `W`, `kW`, `[HP]`, `J`, `kJ`, `kW.h`, `cal`, `kcal`, `[Cal]`, `Pa`, `hPa`, `kPa`, `bar`, `mbar`, `[psi]`, `mm[Hg]`, `[in_i'Hg]`, `deg`, `rad`, `V`, `mA`, `mA.h`, `lx`, `ug/m3`, `mg/dl`, `mmol/l`, `B`, `dB`, `dB[SPL]`, `1`, `{request}`, `{request}/s`, `{beat}/min`, `/s` and `By{heap}` are codes; `sec`, `kmin` (the minute is not metric), `k[in_i]` (nor is the inch), `ft` (the foot is `[ft_i]`), `{x` (an unclosed annotation), `[in_i` (an unclosed bracket), `m//s`, `.s`, `s^2` and `""` are not. `B`, `kB` and `MB` are codes, but they are the bel, the kilobel and the megabel: a person's `MB` is read by `parse_alias/1` (below), never by `parse/1`. An annotation means the unity (UCUM §2.1.5): `{request}/s` is the dimension of `/s`, named. Parentheses, `10*`-style powers of ten, arcminutes and arcseconds, and the rest of UCUM's atoms are not read; the table grows by proposal.

`Macaw.Data.Unit.parse/1` returns `{:ok, components}` for a code, each component `%{prefix: String.t() | nil, atom: String.t() | nil, factor: pos_integer() | nil, annotation: String.t() | nil, exponent: integer()}`, a quotient's exponent negated; or `{:error, reason}`: `:empty`, `{:syntax, rest}` at the first character that does not read, `{:unknown_atom, symbol}`, `{:not_metric, prefix, atom}`, or `{:unknown_currency, code}` for an `{iso4217:…}` annotation whose code is not in the table (§4). `valid?/1` is whether a string is a code.

```test:units-grammar
every code §1 lists parses, and every one it lists as no code is refused with its reason; a symbol is matched whole before a prefix is split from it; a quotient negates its exponents left-associatively, and an annotation stands alone or follows a unit or a factor
```

```test:units-atoms
each atom's factor and dimension is UCUM's definition, exactly, the acre and the degree included; every prefix reads on a metric atom and is refused on a customary one
```

## 2. Dimension, factor and kind {#units-dimension}

A code has a **dimension** — the sum of its components' dimensions, each times its exponent, a quotient's negated — and a **factor**, the product of each component's factor (its prefix's times its atom's, or the integer) raised to its exponent, kept exact: a rational, times an integer power of π when the code holds `deg` (`factor/1` answers `{n, d}`, or `{n, d, k}` for n/d·πᵏ with k ≠ 0). The dimensions are `:time`, `:information`, `:length`, `:mass`, `:temperature`, `:angle`, `:charge` and `:luminous_intensity`, as UCUM's base units are, two **level** dimensions, and one `{:currency, code}` per currency (below). The mole is UCUM's number, so `mol` is dimensionless and `mmol/l` has the dimension of `/l`.

**Special units.** `Cel` and `[degF]` are UCUM's *affine* special units, scales with an offset: they have a dimension but no factor, and so does any code that holds one; they convert by their offsets (below). `B` and `B[SPL]` are UCUM's *logarithmic* units. UCUM gives a logarithmic unit the dimension of its argument; macaw_data gives each logarithmic reference a **level dimension** of its own instead — `:level` for `B`, the level of a bare ratio, and `:sound_pressure_level` for `B[SPL]` — so a level never meets the linear unit it is a logarithm of, and `dB[SPL]` is not a pressure (D-155). Within its level a logarithmic unit scales by its prefix like any other — a decibel is a tenth of a bel — so it has a factor; `Macaw.Data.Unit.kind/1` says which kind a code is: `:linear`, `:affine` (it holds `Cel` or `[degF]`) or `:logarithmic` (it holds `B` or `B[SPL]`).

```test:units-dimension-factor
a code's dimension sums its components' and its factor is exact, π kept as a power; a level has its own dimension per reference; kind/1 tells linear, affine and logarithmic codes apart; a string that is not a code raises
```

## 3. Aliases {#units-aliases}

`Macaw.Data.Unit.parse_alias/1` reads the symbols people type and metresis stored (D-155) — `°C`, `°F`, `lb`, `st`, `mph`, `kn`, `inHg`, `mmHg`, `psi`, `kWh`, `B`, `KiB`, `ha`, `ac` — to codes, `{:ok, code}`, and **refuses an ambiguous one, naming its choices**: `{:error, {:ambiguous, alias, choices}}`, `choices` a list of `{code, meaning}`:

| Alias | Choices |
|---|---|
| `KB`, `kB` | `kBy` (1,000 bytes), `KiBy` (1,024 bytes) |
| `MB`, `GB`, `TB` | `MBy`/`MiBy`, `GBy`/`GiBy`, `TBy`/`TiBy` likewise |
| `gal`, `pt`, `floz`, `fl oz` | `[gal_us]` (US gallon), `[gal_br]` (imperial gallon); the pint and the fluid ounce (`floz`, `fl oz`) likewise |
| `oz` | `[oz_av]` (ounce, mass), `[foz_us]` (US fluid ounce), `[foz_br]` (imperial fluid ounce) |
| `cal` | `cal` (calorie), `[Cal]` (food Calorie, a kilocalorie) |
| `C` | `Cel` (degree Celsius), `C` (coulomb) |
| `dB` | `dB` (a level ratio), `dB[SPL]` (sound pressure level) |
| `kt` | `[kn_i]` (knot), `kt` (kilotonne) |
| `$` | `{iso4217:USD}`, `{iso4217:CAD}`, `{iso4217:AUD}`, `{iso4217:NZD}`, `{iso4217:HKD}`, `{iso4217:SGD}` |
| `¥` | `{iso4217:JPY}` (yen), `{iso4217:CNY}` (yuan) |

A code of the ISO 4217 table typed alone, in capitals (`USD`, `CHF`), is its currency, `{iso4217:USD}`; `€` is `{iso4217:EUR}` and `£` `{iso4217:GBP}`.

The alias table is read first, so an alias wins over a UCUM reading of the same spelling — a person who types `B` means a byte, and gets `By`. A string the table does not hold is read by `parse/1`: a valid code is its own alias (`{:ok, "kPa"}`), and any other is `{:error, {:unknown_alias, string}}`. Surrounding whitespace is ignored. `Macaw.Data.Unit.format_error/1` words a refusal for a person: `"KB" is ambiguous: kBy (1,000 bytes) or KiBy (1,024 bytes)`.

```test:units-alias-read
every alias reads as a code and every choice of an ambiguous one is a code; a symbol the table lacks is read by parse/1 or refused; an ambiguous one is refused naming every choice, worded for a person
```

## 4. Currency, an extension beyond UCUM {#units-currency}

UCUM has no currency, and a plain annotation (`{USD}`) is UCUM's unity, so `{USD}` and `{EUR}` would read as one unit and as a count. macaw_data recognizes one namespaced annotation, **`{iso4217:XXX}`**, `XXX` a code of the ISO 4217 table (list one, published 2026-09-17: 178 codes, each with its **minor units**, the decimals an amount is written to — `USD` 2, `JPY` 0, `BHD` 3, `CLF` 4, none for `XAU`), and gives **each code a dimension of its own**, `{:currency, "USD"}`:

- `{iso4217:USD}` and `{iso4217:EUR}` are different dimensions, so they never convert and never pair (`{:currency, from, to}` from `conversion/2`, below), as `kg` and `Cel` do not;
- a code composes like any unit: `{iso4217:USD}/h` is an hourly rate, `{iso4217:EUR}/kW/h` an energy price (UCUM's `/` is left-associative, so a price per kilowatt-hour divides twice: `{iso4217:EUR}/kW.h` would be euro-hours per kilowatt), `{iso4217:EUR}/{iso4217:USD}` an exchange rate, which is data like any other;
- its factor is the unity, so a currency scales only by the units around it;
- a code not in the table is refused by `parse/1`, `{:error, {:unknown_currency, code}}`, the extension being macaw_data's to check;
- its display symbol is the code (`{iso4217:USD}/h` → `USD/h`), and how it is written in a locale is the drawing library's.

**To any other UCUM reader, `{iso4217:USD}` and `{iso4217:EUR}` are both the dimensionless unit `1`, and so equal.** The annotation is valid UCUM syntax, so another reader degrades to "a count" rather than failing, but it cannot tell two currencies apart. macaw_data therefore never hands a currency code to a UCUM consumer — a telemetry export, an OpenTelemetry unit — without that caveat; within Macaw and visualize, and between hosts that use them, the code is the currency. `Macaw.Data.Unit.currency/1` is the ISO code a code holds alone (`"USD"` for `{iso4217:USD}`, `nil` for `{iso4217:USD}/h` and for any code that is not a currency), and `Macaw.Data.Unit.minor_units/1` a code's minor units (`nil` for none).

```test:units-currency-code
the ISO 4217 table holds 178 codes with their minor units; each code is a dimension of its own, composes like a unit, never converts to another, is refused when not in the table, and is the currency alone only when it stands alone
```

## 5. The display symbol {#units-symbol}

`Macaw.Data.Unit.symbol/2` writes a code as a reader reads it: each atom by the table's symbol, the prefix `u` as `µ`; a positive exponent above one as superscript digits (`m2` → `m²`); the components with a positive exponent joined by `·`, then `/` and those with a negative one by their magnitude, in parentheses when there are two or more (`kW.h` → `kW·h`, `By/s` → `B/s`, `Pa` stays `Pa`, `g/(m·s2)` → `g/(m·s²)`, `s-1` → `/s`, `[ft_i]2` → `ft²`, `[mi_i]/h` → `mi/h`, `har` → `ha`, `mm[Hg]` → `mmHg`, `dB[SPL]` → `dB(SPL)`, `deg` → `°`); the factor `1` and an annotation are dropped, so `1` and `{request}` are `""` and `{request}/s` is `/s` — but a currency annotation standing alone is written as its code (`{iso4217:USD}` → `USD`, `{iso4217:EUR}/kW/h` → `EUR/(kW·h)`). With `annotations: true` an annotation that stands alone as a component is written as its text without braces — `{request}/s` → `request/s`, `{request}` → `request` — and one attached to a unit is dropped even then, the unit saying more than its note (`By{heap}` → `B`).

```test:units-symbol-written
each code is written as a reader reads it, by the table's symbols, superscripts and · and /; annotations: true writes a lone annotation's text and never one on a unit; every atom's symbol reads back as its code or names it among its choices
```

## 6. Conversion {#units-conversion}

Conversion (D-155) is in scope and exact. `Macaw.Data.Unit.conversion(from, to)` answers `{:ok, {scale, offset}}`, so that a value in `from` is `value × scale + offset` in `to`, with `scale` an exact factor (`{n, d}`, or `{n, d, k}` for n/d·πᵏ) and `offset` an exact signed rational `{n, d}`; or `{:error, reason}`:

- **Two codes of one dimension with factors** convert by the ratio of their factors, offset `{0, 1}`: `[lb_av]` to `kg` is `{45359237, 100000000}`, `deg` to `rad` is `{1, 180, 1}`, `[mi_i]/h` to `km/h` is `{25146, 15625}`. That is also display scaling — 1,500 `ms` is 1.5 `s`.
- **The affine units** convert with their offsets, standing alone: UCUM defines `Cel` as `K` less 273.15 and `[degF]` as 5/9 `K` from 459.67 below its zero, so `Cel` to `[degF]` is exactly `{{9, 5}, {32, 1}}` and `[degF]` to `K` is `{{5, 9}, {45967, 180}}`; a prefixed one scales with its prefix (`mCel`). An affine unit inside a term (`Cel/h`, `[degF].m`) is not a temperature and has no offset to convert by: `{:affine_in_term, code}`, unless the two codes are the same.
- **Logarithmic units convert only to their own level** (§2): `B` to `dB` is `{10, 1}`, `dB[SPL]` to `B[SPL]` is `{1, 10}`; a level to or from a linear unit, or to another level, is `{:logarithmic, from, to}`.
- **Currency never converts**: an exchange rate is data, not a fact about a unit. Two codes holding different `{iso4217:…}` annotations are `{:currency, from, to}`, whatever else they hold; the same currency over different units of the rest converts as the rest does (`{iso4217:USD}/h` to `{iso4217:USD}/min` is `{1, 60}`).
- **Any other pair of dimensions** is `{:dimension, from, to}`.

A code that does not read is `{:error, reason}` of `parse/1`. `Macaw.Data.Unit.convert(value, from, to)` is `value × scale + offset` as a float, the scale and offset exact and the arithmetic rounded once for an integer value, and raises `ArgumentError` with the reason worded by `format_error/1` for a pair `conversion/2` refuses. So 100 `Cel` is 212.0 `[degF]`, −40 `Cel` is −40.0 `[degF]`, 0 `K` is −273.15 `Cel`, 180 `deg` is π `rad`, and 30 `dB` is 3.0 `B`.

```test:units-convert
codes of one dimension convert by their factors exactly; the affine units by their offsets, alone; a level only to its own level; two currencies never; other dimensions are refused with the reason; a value converts there and back to itself, and conversions compose exactly
```

## 7. `Telemetry.Metrics` units {#units-telemetry}

`Macaw.Data.Unit.from_telemetry/1` maps the unit atom a `Telemetry.Metrics` definition carries — or the `to` of its `{from, to}` conversion — to a code. macaw_data does not depend on `telemetry_metrics`; this is a table of atoms:

| Atom | Code |
|---|---|
| `:second` | `s` |
| `:millisecond` | `ms` |
| `:microsecond` | `us` |
| `:nanosecond` | `ns` |
| `:minute` | `min` |
| `:hour` | `h` |
| `:day` | `d` |
| `:byte` | `By` |
| `:kilobyte` | `kBy` |
| `:megabyte` | `MBy` |
| `:gigabyte` | `GBy` |
| `:kibibyte` | `KiBy` |
| `:mebibyte` | `MiBy` |
| `:gibibyte` | `GiBy` |
| `:bit` | `bit` |
| `:kilobit` | `kbit` |
| `:megabit` | `Mbit` |
| `:percent` | `%` |
| `:unit` | `1` |
| `:hertz` | `Hz` |
| `:celsius` | `Cel` |
| `:fahrenheit` | `[degF]` |
| `:kelvin` | `K` |
| `:meter`, `:metre` <!-- spelling: allow --> | `m` |
| `:watt` | `W` |
| `:kilowatt` | `kW` |
| `:joule` | `J` |
| `:pascal` | `Pa` |

It returns `{:ok, code}`, `{:error, :native}` for `:native` — a measurement in the VM's native time unit has no fixed size, and a definition converts it first (`unit: {:native, :millisecond}`) — and `{:error, {:unknown, atom}}` for any other atom, so a misspelled unit is refused rather than turned into an annotation. `:unit` is `Telemetry.Metrics`' own default, the dimensionless `1`. (`Telemetry.Metrics` converts `:kilobyte` by 1,000, which is UCUM's `kBy`.)

```test:units-telemetry-map
every Telemetry.Metrics unit atom of the table maps to its code, a {from, to} pair to its target, and :native and an unknown atom are refused
```

```test:units-metresis-parity
every unit of metresis's vocabulary, transcribed in the parity table, is a code here of its family's one dimension, no two folded into one, its symbol read by parse_alias/1 or named among the choices, and converts as metresis converts it, refusals included
```

## 8. A fixed list of quantities {#quantities}

A quantity is what a unit measures. It chooses how a value is displayed — later a color ramp and physical anchors too (visualize#531 §3) — and carries the facts a host needs to aggregate and draw it (D-155). The list is fixed: it grows by proposal, never by a source naming a new one. `Macaw.Data.Quantity.all/0` is the list in this order:

| Quantity | Base unit | Dimension | Kind | Bounds (in the base unit) | Additive across | Additive over time |
|---|---|---|---|---|---|---|
| `:duration` | `s` | time | linear | ≥ 0 | yes | yes |
| `:information` | `By` | information | linear | ≥ 0 | yes | yes |
| `:data_rate` | `By/s` | information·time⁻¹ | linear | ≥ 0 | yes | no |
| `:frequency` | `Hz` | time⁻¹ | linear | ≥ 0 | yes | no |
| `:ratio` | `1` | none | linear | 0 to 1 (0 to 100 in `%`) | no | no |
| `:count` | `1` | none | linear | ≥ 0 | yes | yes |
| `:temperature` | `Cel` | temperature | affine | — | no | no |
| `:length` | `m` | length | linear | ≥ 0 | yes | yes |
| `:speed` | `m/s` | length·time⁻¹ | linear | ≥ 0 | no | no |
| `:power` | `W` | mass·length²·time⁻³ | linear | — | yes | no |
| `:energy` | `J` | mass·length²·time⁻² | linear | — | yes | yes |
| `:pressure` | `Pa` | mass·length⁻¹·time⁻² | linear | — | no | no |
| `:area` | `m2` | length² | linear | ≥ 0 | yes | yes |
| `:volume` | `l` | length³ | linear | ≥ 0 | yes | yes |
| `:mass` | `g` | mass | linear | ≥ 0 | yes | yes |
| `:pace` | `s/m` | time·length⁻¹ | linear | ≥ 0 | no | no |
| `:angle` | `deg` | angle | cyclic | 0 to 360 | no | no |
| `:currency` | `{iso4217:XXX}`, by code | currency, one per code | linear | — | yes | yes |
| `:electric_potential` | `V` | mass·length²·time⁻²·charge⁻¹ | linear | — | no | no |
| `:electric_current` | `A` | charge·time⁻¹ | linear | — | yes | no |
| `:electric_charge` | `C` | charge | linear | ≥ 0 | yes | yes |
| `:illuminance` | `lx` | luminous intensity·angle²·length⁻² | linear | ≥ 0 | no | no |
| `:sound_level` | `dB[SPL]` | sound pressure level | logarithmic | — | no | no |
| `:mass_concentration` | `g/l` | mass·length⁻³ | linear | ≥ 0 | no | no |
| `:amount_concentration` | `mol/l` | length⁻³ (the mole is a number) | linear | ≥ 0 | no | no |

"Number" is not a quantity: a field with none is plainly formatted. A percent is a `:ratio` written in `%`. A bare `dB` is a level ratio and not a `:sound_level`, which takes `dB[SPL]` and `B[SPL]` (§2). A currency's unit is the annotation of §4's extension, `{iso4217:XXX}`, one dimension per code.

```test:quantities-list
all/0 is the table's quantities in order, each with a base unit that reads and implies it, a kind, bounds and additivity; every family member reads and has its quantity's dimension
```

## 9. Kind and bounds {#quantities-kind}

**Kind** (`Macaw.Data.Quantity.kind/1`) says how values combine. `:linear` values are on a ratio scale. A temperature is `:affine`: its zero is a convention, so a difference is meaningful and a sum of absolutes is not. A sound level is `:logarithmic`: two levels do not add as numbers. An angle is `:cyclic`: 350° and 10° are 20° apart, so a mean of angles is circular.

**Bounds** (`Macaw.Data.Quantity.bounds/1` in the base unit, `bounds/2` in a given unit, `{min | nil, max | nil}`) are a **display hint, never validation** (D-155): they tell an axis where a quantity's values physically lie — a duration is not negative, an angle wraps at 360° — so it can anchor at zero or stop at the wrap. A value outside them is never refused: a difference is legitimately negative (an elevation change, a clock offset, net energy), and a ratio may exceed one. A field's schema overrides them with its own `bounds` ([01 §1](01-sources.md#sources-data)). `bounds/2` converts the base's bounds into the unit (`bounds(:angle, "rad")` is `{0, 2π}`, `bounds(:ratio, "%")` is `{0, 100}`); an affine unit's bounds are its quantity's, none for a temperature.

```test:quantities-kind-bounds
a temperature is affine, a sound level logarithmic, an angle cyclic and the rest linear; bounds are in the base unit and converted into another unit by bounds/2, none for an affine unit
```

## 10. Additivity {#quantities-additivity}

**Additivity depends on the aggregation** (D-155). A quantity carries two physical defaults: **across** — whether summing several series at one instant means anything (the total throughput of several links, the current into a node) — and **over time** — whether summing one series over time does (the bytes sent in a day, but not a day of power readings, which integrate to energy instead). A field's schema may state its **metric kind** ([01 §1](01-sources.md#sources-data)), which refines the second: `Macaw.Data.Quantity.additivity(quantity, metric_kind)` is `%{across: boolean, over_time: boolean}`, where

- no metric kind (`nil`) keeps the quantity's defaults;
- `:gauge` — a level sampled at instants — is never additive over time, since a sum of samples counts each level once per sample;
- `:counter` — the increments of an accumulating count — is additive over time exactly when the quantity is additive across, since increments of an extensive quantity add and increments of a temperature mean nothing;
- `:rate` — a quantity per unit time — is never additive over time: a rate integrates rather than adds;

and across is the quantity's default under every metric kind. A field with no quantity (a plain number) has both defaults `true`. A host derives its aggregation exclusions from the two: a sum over time is offered only when `over_time`, a sum of series only when `across`.

```test:quantities-additivity-defaults
each quantity's defaults across and over time are the table's; a gauge and a rate are never additive over time, a counter is over time exactly when across, across never changes, and no quantity is additive both ways
```

## 11. Families and conventions {#quantities-families}

A quantity's display families are ladders of units, smallest first, each tagged with the unit systems it serves. A quantity whose units are read in several **conventions** holds its families per convention (below); every other quantity has one convention, its row:

| Quantity | Metric | US | UK | Other families (any system) |
|---|---|---|---|---|
| `:duration` | — | — | — | `ns`, `us`, `ms`, `s`, `min`, `h`, `d` |
| `:information` | — | — | — | decimal `By`, `kBy`, `MBy`, `GBy`, `TBy`; binary `By`, `KiBy`, `MiBy`, `GiBy`, `TiBy`; bits `bit`, `kbit`, `Mbit`, `Gbit`, `Tbit` |
| `:data_rate` | — | — | — | the information families over `/s` |
| `:frequency` | — | — | — | `Hz`, `kHz`, `MHz`, `GHz`; events `/h`, `/min`, `/s` |
| `:temperature` | `Cel` | `[degF]` | `Cel` | — |
| `:length` | `mm`, `cm`, `m`, `km` | `[in_i]`, `[ft_i]`, `[mi_i]` | as US | — |
| `:area` | `cm2`, `m2`, `har`, `km2` | `[ft_i]2`, `[acr_us]`, `[mi_i]2` | as US | — |
| `:volume` | `ml`, `l`, `m3` | `[foz_us]`, `[pt_us]`, `[gal_us]` | `[foz_br]`, `[pt_br]`, `[gal_br]` | — |
| `:mass` | `mg`, `g`, `kg`, `t` | `[oz_av]`, `[lb_av]` | `[oz_av]`, `[lb_av]`, `[stone_av]` | — |
| `:speed` | `km/h` | `[mi_i]/h` | as US | — |
| `:pace` | `min/km` | `min/[mi_i]` | as US | — |
| `:power` | — | — | — | `W`, `kW`, `MW`, `GW` |
| `:energy` | — | — | — | `J`, `kJ`, `MJ`, `GJ`; watt-hours `W.h`, `kW.h`, `MW.h`, `GW.h`; calories `cal`, `kcal` |
| `:pressure` | by convention: gauge `Pa`, `kPa`, `MPa`; barometric `hPa` | gauge `[psi]`; barometric `[in_i'Hg]` | gauge `[psi]`; barometric `hPa` | clinical `mm[Hg]` |
| `:electric_potential` | — | — | — | `mV`, `V`, `kV` |
| `:electric_current` | — | — | — | `mA`, `A` |
| `:electric_charge` | — | — | — | `mA.h`, `A.h` |
| `:illuminance` | — | — | — | `lx`, `klx` |

`:ratio`, `:count`, `:angle`, `:currency`, `:sound_level` and the two concentrations have no family: each is displayed in the unit it is given (how a count is written, in SI notation from a thousand, is the drawing library's).

**Conventions** (visualize#598, D-158). One dimension may be read in several conventions, and a unit system picks a unit *within* a convention, never across them: a US weather viewer reads a barometer in inches of mercury, not psi, and a blood pressure is mmHg in every system. A convention is a fact of the quantity table: its families, tagged by system as above, and the codes it **claims** — every member of its families and any further code it holds without a ladder for it. `:pressure` has three, in this order:

| Convention of `:pressure` | Claims | Metric | US | UK | Any system |
|---|---|---|---|---|---|
| gauge (technical) | `Pa`, `kPa`, `MPa`, `[psi]`, `bar` | `Pa`, `kPa`, `MPa` | `[psi]` | `[psi]` | — |
| barometric | `hPa`, `[in_i'Hg]`, `mbar` | `hPa` | `[in_i'Hg]` | `hPa` | — |
| clinical | `mm[Hg]` | — | — | — | `mm[Hg]` |

`bar` is a gauge unit but no metric ladder holds it, so a metric viewer sees 300 kPa as `300 kPa`, as before, and a stored `bar` is still shown in `bar` under `:as_posted`. A unit's convention is chosen by its **exact code first**, across every convention in the table's order, because shape alone cannot tell them apart (`hPa` and `kPa` are one shape, as are `mbar` and `bar`); then, for a code no convention claims, by **shape**, the first convention claiming a code of its shape (`dPa` is gauge's, `kbar` gauge's); and a unit of no convention's shape takes the first convention. Every other quantity has a single convention, so for it the step is empty and nothing changes.

Within its convention, a unit **belongs to** the family that holds a member of its *shape* — its atoms and their exponents, prefixes aside, a binary prefix (`Ki`, `Mi`, `Gi`, `Ti`) kept apart from a decimal one, annotations aside — the first such family in the table's order (metric before US before UK before the others). So the data says which family and no setting does: `MiBy` belongs to the binary ladder and `kBy` to the decimal one — **decimal is the default**, as UCUM's `kBy` and `Telemetry.Metrics`' `:kilobyte` are 1,000 bytes, so a host that measures in `MiBy` keeps `KiB`/`MiB`/`GiB` and nobody else sees them — `bit/s` to the bits, `{request}/s` and `{beat}/min` to the events, `kW.h` to the watt-hours, `dPa` to `Pa`, `kPa`, `MPa`, `hPa` to the barometric `hPa`, `[ft_i]` to the US length ladder. A unit of no family's shape — `mbar`, `bar`, `[nmi_i]`, `[yd_i]`, `[kn_i]`, `m/s`, `K`, `[Cal]` — belongs to none and is displayed as it is given. `Macaw.Data.Quantity.family(quantity, unit, system)` is the ladder a system shows the unit in (below), and `family/2` the unit's own.

```test:quantities-families-conventions
the unit picks its family by shape, decimal by default and binary, bits, events and watt-hours by their own; a convention is chosen by exact code, then shape, then the first; a system picks within a convention, never across, as the pressure table says; every other quantity's family/3 answers are the table's
```

## 12. Unit systems {#quantities-systems}

**Unit systems** (D-155) are `:metric`, `:us`, `:uk` and `:as_posted`, `Macaw.Data.Quantity.systems/0`. A system is a display preference and never touches the data: it chooses the family a value is shown in. Under `:metric`, `:us` or `:uk`, a unit whose convention names a family for that system is shown in it — a mass in `kg` under `:us` is shown in `lb`, a barometric `hPa` in `[in_i'Hg]`, a gauge `kPa` in `[psi]` — and any other is shown as under `:as_posted`, as a clinical `mm[Hg]` is in every system. Under **`:as_posted`**, the default, a value keeps its unit's own family inside its convention and is only rescaled within it, which is D-138's display scaling unchanged: `hPa` stays `hPa`, and `bar` and `mbar`, which no ladder holds, stay as given. "Imperial" alone is not a system: a US and an imperial gallon are 20% apart, and the UK writes stones, imperial pints and °C. A preference that crosses dimensions is **not** a system switch and stays a per-field choice — a glucose reading in `mg/dl` against `mmol/l`, which needs the molar mass, or a pace against a speed, its reciprocal.

```test:quantities-systems-pick
the four systems; a system shows a unit in its own family, US and UK apart, and as posted a unit keeps its own family; a unit no family holds, and a preference across dimensions, is shown as given in every system
```

## 13. The measure {#quantities-measure}

A unit and a quantity together are a *measure*, `%{unit: code | nil, quantity: quantity | nil}`, the two facts a field description carries (visualize#535). `Macaw.Data.Quantity.resolve/1` completes and checks one: the unit is checked (§1); a missing quantity is the one the unit's dimension implies — the table's dimension, a dimensionless unit holding `%` being `:ratio` and any other dimensionless one `:count`, and a code of one currency alone (`{iso4217:USD}`) `:currency` — or `nil` when no quantity has that dimension (`rad/s`, `Cel/s`, a bare `dB`); a missing unit is the quantity's base unit (`nil` for a `:currency`, whose code the data must say); a unit whose dimension is not its quantity's (`By` as a `:duration`, `dB` as a `:sound_level`) is `{:error, {:quantity, quantity, code}}`; a `:ratio` or a `:count` takes any dimensionless unit, and a `:currency` a code of one currency alone — `{iso4217:USD}`, not `{iso4217:USD}/h`, whose quantity is none of the list. It returns `{:ok, %{unit: code | nil, quantity: quantity | nil}}`, `{:error, {:unit, code, reason}}` for a code that does not read, `{:error, {:unknown_quantity, term}}` for a quantity not in the list, or the mismatch. `Macaw.Data.Quantity.of_unit/1` is the inference alone.

**Unit and quantity are facts about the data, not knobs.** Neither changes what a value is; they say what it already is, so a display can choose for it. What a reader sees (the format, the tick count) is the drawing library's to choose, and the unit system is the viewer's; there is no setting that picks decimal against binary apart from the data.

```test:quantities-resolve
resolve/1 completes a measure: a unit implies its quantity and a quantity its base unit; a pair whose dimensions disagree is refused, and so are a code that does not read and a quantity not in the list
```

## 14. The label rule {#quantities-label}

**The label rule.** `Macaw.Data.Quantity.label(measure)` is what a title says about a measure: **the unit, else the quantity, else nothing** — the symbol of the unit with its annotations written (`ms`, `kW·h`, `request/s`, `request`) when it is not empty, else the quantity's name with its underscores as spaces (`count`, `ratio`, `data rate`), else `nil`.

```test:quantities-label-rule
the label is the unit's symbol with its annotations written, else the quantity's name with spaces for underscores, else nil
```
