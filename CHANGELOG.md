# Changelog

## Unreleased

- **Spec:** the source contract is one model, a relation that varies over time (#11, #10): a delivery is a snapshot, a push the changelog of Z-set increments, `Push.held/1` their integral, `:as_of` a past snapshot, a derived source a map from relations to relations (spec/01 §2.5). The deferred §2.6 and §4.1–§4.4, and spec/02 §8.6, specify what #12–#15 and macaw_data#9 build: numbered increments and the snapshot's handoff, retractions and range replacements, one resolution per subscription, settled ranges, and derived watermarks.
- **Breaking:** push increments are numbered, and a snapshot hands off to the stream by position (#12, spec/01 §4.1). A source sends `{:increment, seq, delivery}` (`Push.increment_message/3`, numbered from 1 per subscription) and may send `{:snapshot, delivery}` (`Push.snapshot_message/2`) whose `served.position` (new) is the last increment it reflects; `Push.delivery_message/2` is gone. `Push` drops a repeated or older increment whole (counted in `ignored`, a count by reason), applies increments in the order of their numbers, holds back those past a gap, records the gap and answers it from `Push.refetch/1`; a snapshot, received or fetched with the request's new `subscription:` and handed over by `Push.snapshot/2`, replaces what is held and drops the increments it already reflects. **Rows are no longer deduplicated:** an identical row pushed again is a second row (tally taps), so redelivery is guarded by the number, not the row. The conformance kit's `:push` check holds increments to their numbering. **Upgrade:** number each subscription's increments from 1 and send them with `increment_message/3`.
- **New:** pushed increments carry corrections (#13, spec/01 §4.2–§4.3). A delivery's `retracted` rows are withdrawn, each matched by identity, the window value it was held at and the fields it names, one copy per unit of weight, never a guessed row: one not held, held only at another window value, or that can't tell rows apart is `{:retract, reason, row}` in `errors`, and against a `capped` or reduced holding an unheld retraction is counted in `ignored` (`:unheld`). Its `replace` ranges, `%{from, to, identities, rows}`, make the relation over `[from, to)`, limited to identities, exactly the rows given; a change inside a replaced range, a replacement's row outside it and an overlapping replacement are recorded and not applied. Row retractions apply first, then range retractions, then insertions. An increment is merged only into a relation held at its `served.resolution`; a mismatch is recorded and answered by `Push.refetch/1`.
- **New:** settled ranges (#14, spec/01 §4.4). A delivery's `served.complete_until` is the source's watermark, a time or a number below which it expects no further change: settled, not final. `Push` carries the latest claim forward on what it holds and records a smaller one as `{:complete_until, :backwards, held, given}`, keeping the held claim; a new subscription starts afresh. A description may declare `lateness`, a hard bound (a `Duration` over a time window field, a number over a number one); given to `Push.new/3` as `lateness:`, it refuses a change older than the claim minus the bound (`{:late, row, bound}`) and a replacement reaching past it whole. Without it a change of any age is accepted.
- **New:** derived watermarks (#15, spec/02 §8.6). A derived source's output states `served.complete_until`, the minimum of its inputs' claims, each capped by its request window's upper bound; an input with no claim leaves none, and a change of the watermark alone marks the readers. A description may declare `idle_after` (milliseconds), which the owner passes to `Engine.new/2` by name (`idle_after:`): a source that has delivered nothing for that long, judged against the `now` the engine is given, is left out of the minimum until its next delivery, unless every input is idle.

## v0.7.0 (2026-10-30)

**Terms are the form** (dco-tek/macaw/macaw#188), macaw_data's part. A value's identity and validity are the BEAM term's own; JSON and Arrow are adapters at the edge. On macaw_layers 0.3.0. This release is breaking throughout; the guide below is what an adopter of 0.6.1 changes, and the entries after it are the detail.

### Upgrading from 0.6.1

1. **Depend on macaw_layers `~> 0.3.0`** (#27); its own upgrade guide applies to any kernel call you make directly.
2. **Every schema version changes** (D1). A stored version, cache key or golden written by 0.6.1 differs; regenerate it. A schema's names, states and roles are now strings in the struct (`Schema.new/1` normalizes them), so code that pattern-matches `:latency` inside a schema matches `"latency"`; every function that takes a name still takes either spelling.
3. **A data color is a color term** (D2): a `%Macaw.Layers.Color{}` literal or a typed color, never a string. Parse CSS text at your input edge with `Macaw.Layers.Color.parse!/1`, or write `~RGB"#3b6fa8"` in code. A role spelled like a CSS name (`"orange"`) is now a valid status role.
4. **A derived source is built from its value** (D3). Pass `Derived.new/1` a keyword list or a map of terms; read a stored form with `Derived.from_map/2` or `from_json/2`. `to_map/1` and `to_json/1` now answer `{:ok, form}` or faults.
5. **The operations registry's digest changes** (D4); a compile cache keyed by it recompiles once. `Operations.step_digest/2` is new: a checked step's canonical identity.
6. **Category values read back as strings** (D5): a `:category` column holding `:ok` answers `"ok"` from `rows/1`, `get/2` and `column/2`; compare with strings, or with `Operations.same?/2`. `nil`, `true` and `false` are kept.
7. **Packed columns are faithful and Arrow-compatible** (D5). A mixed integer/float column and a zoned time read back exactly as given; anything that held packed buffers (stored binaries) changes with the bitmap order.

### Changes

- **Breaking:** on macaw_layers `~> 0.3.0` (#27): the kernel's digest is over the value, so every pinned version moved before D1 changed what it digests.
- **Breaking:** every schema version changes (D1, #28, dco-tek/macaw/macaw#188). `Schema.version` is the kernel's digest of the schema's term, not of its JSON form, which is now only an adapter at the edge; a value entry's color no longer goes through the JSON form when `Schema.new/1` versions the schema, so a typed color there can't crash it. The struct holds every field name, state and role as its string, normalized once by `new/1`, so `fields`, `identity/1`, `window_field/1`, `compatibility/2`'s faults and `identity/2`'s maps name fields by their strings; every function that takes a name still takes either spelling. A state named in both spellings in one description is `:duplicate`.
- **Breaking:** data colors are color terms, and a string is never a color (D2, #29, dco-tek/macaw/macaw#187, dco-tek/macaw/macaw#188). A value entry's `color`, a `:color` field's row values (a derived source's output), a `:color` parameter and `Schema.color?/1` take a literal `%Macaw.Layers.Color{}` or a theme-relative typed color (`{:color, "good"}`, `{:alpha, {:color, "bad"}, 0.74}`), its names in a theme's name grammar; a string there, `"#2e7d32"` or `"red"`, is `{:type, :color}`. `new/1` holds a typed color's names as strings, so `{:color, :good}` and `{:color, "good"}` are one version. The schema's JSON form writes and reads an entry's color in macaw_layers' color form (`Macaw.Layers.Color.Form`: `{"$rgb": "#2e7d32"}`, `{"$color": "good"}`), making no atom. `Table.column_types/1` infers `:color` for a column of color terms; a column of strings stays `:text`. A status role spelled like a CSS name (`:orange`) is now a role. **Upgrade:** read CSS text into a color at your input edge with `Macaw.Layers.Color.parse!/1`, or write `~RGB"#2e7d32"` in source (`import Macaw.Layers.Color, only: [sigil_RGB: 2]`); a stored schema whose entry colors are strings reads back refused, so convert its colors with `parse!/1` before reading it.
- **Breaking:** a derived source is built from its value, and its forms are an adapter (D3, #30, dco-tek/macaw/macaw#188). `Derived.new/1` takes the value only, a keyword list or a map of its fields as terms; it no longer guesses whether it was given a map form, and a map form's string keys are each `:unknown_key`. The map and JSON forms are written and read by macaw_layers' JSON adapter (`Macaw.Layers.Form`), with the kernel's tags and the source's own in one tag table: `to_map/1` and `to_json/1` answer `{:ok, form}` or every value without a form, by path; `from_map/2` and `from_json/2` read through the gates (the limits, the version, the tag table, the keys, making no atom) and then judge the value with `new/1`. The output schema is used as built, a `%Schema{}` as given and fields by `Schema.new/1`, never written to its form and read back; in the form it is `Schema.to_map/1`'s. `Derived.Form`'s private tag scheme is gone. A color, literal or typed, in a schema's value entry reaches a stored function's context as the term it is; before, its tags were respelled as strings. **Upgrade:** the form changed: an input is `{"$input": [name, window]}`, a source's name `{"$source": name}`, `per` `{"$atom": "identity"}` or `{"$identity": input}`, a region an object keyed by field names, and `to_json/1` stamps `"$version": 1`. Nothing in this library stored the old form of pair lists, so no version step reads it: write a stored source again with `to_map/1` from its value. Read a map form with `from_map/2`, not `new/1`.
- **Breaking:** the operations registry's `digest/1` is the kernel's term digest of its names and modules, not a SHA-256 of `term_to_binary` (D4, #31, dco-tek/macaw/macaw#188), so every registry digest changes and a compile cache keyed by one recompiles once. New: `Operations.step_digest/2`, a checked step's canonical identity, for caches of a step's results.
- **Breaking:** a table's packed columns are faithful and laid out as Arrow lays them out (D5, #16, dco-tek/macaw/macaw#188), spec/01 §1.1. Packing never changes a value. A category column of strings and atoms is one Arrow dictionary of strings, so `rows/1`, `get/2` and `column/2` read a category's atom back as the **string** that spells it (`:ok` and `"ok"` are one code, read as `"ok"`), in every form the column takes; `nil`, `true` and `false` stay themselves, beside the names in side bitmaps, so `[:ok, true, "warn"]` reads back `["ok", true, "warn"]`. Validity bitmaps are least-significant-bit first, Arrow's order, not Elixir's `<<b::1>>` order, so every stored packed binary changes. A `DateTime` keeps its zone (name, abbreviation and both offsets, in a per-column dictionary, with no time-zone database) and its precision, so a time reads back as given rather than in UTC at microsecond precision. A text column is an offsets buffer and one data buffer, Arrow `utf8` when every value is valid UTF-8 and Arrow `binary` when one is not; a category column holding a string that is not valid UTF-8 is kept as its list. `new/1` takes `NaiveDateTime`s and `Date`s in a time column as themselves, and refuses a value in a `:color` column that is not a color term (`Schema.color?/1`), `{[name, i], {:type, :color}}`. **Upgrade:** compare a category value with `Operations.same?/2`, or as a string.
- **Fixed:** a number column mixing integers and floats reads back each as given, through an integral bitmap, or a dense union of int64 and float64 when an integer is beyond ±2^53; an integer beyond int64 keeps its column a list rather than becoming a float. A time column keeps each value's zone and precision, so `~U[2026-01-01 00:00:00Z]` and `~U[2026-01-01 00:00:00.000000Z]` stay distinct (#16, dco-tek/macaw/macaw#188).

## v0.6.1 (2026-10-29)

- **Fixed:** compiling macaw_data in an app without the optional `table` package warned that `Table.Reader.impl_for/1` is undefined; CI now compiles it without its optional dependencies (#7).

## v0.6.0 (2026-10-29)

- What a source steps its window by: `Window.before/4`, `region/2` (visualize's `box/2`: a window as the region it asks of a schema), `range/2`, and `check/2` of the axes alone as well as of a request (dco-tek/macaw/macaw#185, #5).
- Packing a table and reading it back do about half the work: types inferred only where not given, values checked in one pass, column names merged once, rows built a column step at a time, and time columns converted by the date's fields, a fifth of `DateTime`'s own conversion (dco-tek/macaw/macaw#185, #4).
- **Breaking:** a delivery keeps the rows its source gave (dco-tek/macaw/macaw#185). `%Delivery{rows, names, types, served, schema, origin}`: nothing is packed or rewritten when it is made; `Delivery.rows/1` and `Table.rows/1` of a delivery read the rows as they are (a row list uncopied, tuple rows unchanged); `Delivery.table/2` and `table!/2` pack them for a reader that wants columns; `named_rows/1` names tuple rows and tensors by `names:`; `empty?/1`. The `table` field is gone: read `Delivery.table!/1`. Finishing and push keep the rows' form. `Table.unnamed?/1` (#3).

## v0.5.4 (2026-10-28)

- The macaw logo in the docs and the README (macaw#175).
- Tests check "makes no atom" on the input's own names, never the node's atom count, and the atom gate forbids the count in `test/` (#1).

## v0.5.3 (2026-10-28)

- On Hex: depends on `macaw_layers ~> 0.2.2` from Hex instead of its git tag, and the README installs from Hex (macaw#155).
- The README opens with the early-release notice (macaw#174).

## v0.5.2 (2026-10-28)

- Dependencies named by their `dco-tek/macaw` group paths (macaw#152).
- Package metadata for Hex: the public home, the changelog link, the files shipped, and docs with `ex_doc` (macaw_compose#155).

## v0.5.1 (2026-10-28)

- macaw_data v0.5.1: on macaw_layers v0.2.0 (macaw_compose#145)

## v0.5.0 (2026-10-27)

- macaw_data v0.5.0: transforms, table operations and aggregates (macaw_compose#83): the behaviors, the registry, twelve table operations, thirteen statistics, Macaw.Data.Ops in the sandbox, budget reducers by name

## v0.4.0 (2026-10-27)

- macaw_data v0.4.0: derived sources (macaw_compose#82): the model, the sandbox and its gates, host functions and the engine

## v0.3.0 (2026-10-27)

- macaw_data v0.3.0: the source contract (macaw_compose#58): the behavior, description, request and parameters; windows and finishing; push; the conformance kit

## v0.2.0 (2026-10-27)

- macaw_data v0.2.0: the data model (macaw_compose#57): units and quantities, the columnar table, the schema, the delivery

## v0.1.0 (2026-10-27)

- macaw_data 0.1.0: Macaw.Data.Event
