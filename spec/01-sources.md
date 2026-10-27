# 01 — Sources {#sources}

<!-- surfex: deferred #112: the source contract this file introduces is complete with its conformance kit -->

A **source** is anything a component's slot reads. One contract serves feeds, queries, derived sources, state sources and exports. It is a strict superset of visualize's `Visualize.Feed`: an existing feed is a source with no parameters.

## 1. The data model {#sources-data}

- **`Data.Table`:** columnar typed data, the currency of deliveries, derived sources and components. Row lists are accepted at the edge ([§1.1](#sources-table)). (visualize.md C1.)
- **`Data.Schema`:** each field's **meaning**: `type` (`:time | :number | :category | :text | :color | :point`, a `:point` being a geographic position), and where known `unit` (UCUM), `quantity`, `label`, `order`, `status`, `polarity`, `continuity`, `bounds`, `identity`, `window`, and declared `values` with names and colors ([§1.2](#sources-schema)). (visualize.md C1.)
- **The window field** is the field a request's window applies to: the one marked `window: true`, else the schema's only `:time` field. A `box` window applies to a `:point` window field. A schema with neither, or with several `:time` fields and none marked, has no window field, and requests to it carry none ([§1.5](#sources-schema-window)).
- **A schema gives data colors, never drawing colors.** A `:color` field, or a color on a declared value (a team's color), is content; how it may be shown is a theme rule ([macaw_layers 04](https://gitlab.conet.yarina.org/dco-tek/macaw_layers/-/blob/main/spec/04-themes.md#themes-rules)).
- **A schema's version is the SHA-256 of a canonical encoding,** the kernel's digest of its JSON form ([§1.10](#sources-schema-version)). A delivery names the version, and a push sends the schema before rows made under it. (visualize.md C1; metresis.md C1.)
- **Identity is declared** (`identity: true`, composite allowed), never guessed. Selection, `latest` and per-identity derivations read it. (visualize.md C1.)
- **Units and quantities** come from one vocabulary, specified in [03](03-units.md): UCUM codes with an ISO 4217 currency extension, and a fixed list of quantities. Nothing translates between two vocabularies. (metresis.md C1.)

### 1.1 The table {#sources-table}

**`Macaw.Data.Table` is columnar typed data,** the currency of deliveries, derived sources and components. A table is named columns of declared types, every column the same length. Its design is visualize#916's (closed when this step absorbed it): rows as lists of maps cost a garbage collection that copies every row, and packed columns don't.

| Type | Holds | Stored as |
|---|---|---|
| `:number` | integers and floats | one packed binary: signed 64-bit integers when every value is an integer that fits, else 64-bit floats |
| `:time` | `DateTime`s | one packed binary of signed 64-bit microseconds since the Unix epoch, UTC |
| `:category`, `:text`, `:color`, `:point`, `:term` | any value; a point is `{longitude, latitude}` | a list |

- **A missing value is `nil`,** in every type. A packed column keeps a validity bitmap beside its binary, so a gap stays a gap and reads back as `nil`, never as 0 (§3).
- **`new/1`** builds a table from `{name, type, values}` columns and reports every fault at once: a type not in the list (`{:enum, types}`), a value its type does not hold (`{[name, i], {:type, type}}`), a column of another length than the first (`{:length, n}`), a name given twice (`:duplicate`). `new!/1` raises naming them.
- **Reading back:** `column/2` is a column's values in order. A number column of integers reads back integers; of floats, or of both, floats, and an integer too large for 64 bits makes its column floats. A time column reads back `DateTime`s in UTC at microsecond precision. `rows/1` is the row view: one map per row keyed by every column name. `row/2` is one row, `nil` past the end; `names/1`, `size/1` and `column_type/2` describe the table.
- **`slice/3`** is a run of rows as a table of the same columns; a packed column's binary is sliced, not copied.
- **The packed columns live off the process heap:** a binary over 64 bytes is reference-counted, so a collection never copies it, and a table's cost to its process does not grow with its rows.

```test:table-new
new/1 builds named typed columns and refuses an unknown type, a value of the wrong type, a column of another length and a duplicate name, all at once, ordered by path
```

```test:table-packed
number and time columns are packed binaries with a validity bitmap; integers read back integers, mixed columns floats, a too-large integer makes floats, times read back in UTC to the microsecond, and a gap reads back nil
```

```test:table-off-heap
a table of a million numbers costs its process the same number of words as one of a hundred thousand, its column a reference-counted binary
```

```test:table-round-trip
for generated rows of numbers, floats, strings and times with gaps, rows to a table and back are the rows, and every column is the table's length
```

```test:table-slice
slice/3 is the rows from start, count of them, for generated tables and bounds; row/2 is one row or nil; a slice shares its parent's binary
```

**Row lists are accepted at the edge.** `from/2` reads every shape data arrives in into a table:
- a list of row maps, a map or keyword list of equal-length columns, an `Nx.Tensor`, or anything implementing `Table.Reader` (Explorer's frames among them), through `rows/1`;
- columns are named by every key of every row, in term order, a row without the key missing there;
- each column's type is the one `types:` gives, else the one `column_types/1` infers, else `:term`;
- a time column's values become `DateTime`s at the edge: a `Date` at midnight UTC, a `NaiveDateTime` as UTC, an ISO 8601 string parsed.

The `table` package and Nx are optional dependencies: without them lists and column maps still work, and a struct source or a tensor raises `UndefinedFunctionError` where it is read.

```test:table-edge
from/2 reads rows, columns and a Table.Reader source, infers or takes the types, turns ISO strings, dates and naive times into DateTimes in a time column, makes a mixed column a term column, passes a table through, and refuses a value its given type does not hold
```

**The row helpers read any source,** as visualize's `Visualize.Data.Table` does (this is its port):
- `rows/1` of a list of rows is the list itself, uncopied; of a map or keyword list of equal-length columns, one map per row; of a rank-2 tensor, one tuple per row, of a rank-1 tensor its values; of a `Table.Reader` source, its rows keyed as the reader names its columns. A map whose values are not equal-length lists, a tensor of another rank, and a struct with no reader are the caller's errors;
- `named/2` names a tensor's columns, or tuple rows' elements, in order, or says why it can't (`{:width, n, size}`, `{:rank, rank}`), and passes any other source through;
- `get/2` reads a column from a row by either spelling of its name, and `key/2` is the key that spells it; no atom is made. `accessor/1` is the function of a name, a function passed through;
- `column_types/1` suggests each column's type from its whole: all temporal is `:time`, all numbers `:number`, all strings `:text`, all atoms or booleans `:category`, a mixed or empty column left out; `time_columns/1` names the temporal ones; `temporal?/1` is whether a value is a `DateTime`, `Date`, `NaiveDateTime` or an ISO 8601 string one of those parses. These are suggestions for a tool; a table's declared types are `column_type/2`'s.

```test:table-sources
rows/1 passes a list of rows through uncopied and tuple rows unchanged, reads column maps, keyword columns, tensors and rank-1 tensor columns, refuses unequal columns, other ranks and a struct with no reader; named/2 names tensor columns and tuple rows or says why not
```

```test:table-row-helpers
get/2 reads a key by either spelling, the exact key first, a nil value being a value; accessor/1 wraps a name and passes a function; a tuple row has no names
```

```test:table-inference
column_types/1 types a column by its whole and leaves a mixed or empty one out; time_columns/1 reads the whole column, nil a gap, names the union of every row's keys; temporal?/1 accepts the three structs and ISO 8601 strings only
```

### 1.2 The schema {#sources-schema}

**`Macaw.Data.Schema` is a source's schema:** what each of its fields means, whoever draws it, and never how it is drawn. It is `%Macaw.Data.Schema{fields, version, identity}`:
- `fields` maps a field name (an atom or a string, as the source's rows spell it) to its **description**, a map of the keys below;
- `version` is the schema's version (§1.10);
- `identity` is the declared identity fields of `identity/1` (§1.4), derived by `new/1` so a row's identity is read without walking the fields again; a struct assembled by hand may leave it `nil`, and `identity/1` derives it then.

`Macaw.Data.Schema.new/1` is the only constructor. It takes the map of descriptions, checks it, and returns `{:ok, schema}` or `{:error, faults}` with every fault found, each `{path, reason}` from the schema to the value (`[:latency, :unit]`), ordered by path (§1.8). `new!/1` returns the schema or raises `ArgumentError` with every fault formatted by `format_error/1`. It is ported from visualize's `Visualize.Data.Schema` (its spec/08 §10.1).

| Key | Value | For a field of type | Meaning |
|---|---|---|---|
| `type` | `:time`, `:number`, `:category`, `:text`, `:color` or `:point` | required, every field | what the column is. A `:time` field holds **instants** (`DateTime`, `NaiveDateTime` or `Date` values, or ISO 8601 strings), never numbers: a count of ticks or a sequence number is `:number`. A `:color` field holds data colors, one per row (§1.7). A `:point` field holds **geographic positions**, `{longitude, latitude}` |
| `unit` | a UCUM code | `:number` | the unit the values are in, a code `Macaw.Data.Unit.parse/1` reads ([03 §1](03-units.md#units-codes)) |
| `quantity` | one of `Macaw.Data.Quantity.all/0` | `:number` | what the unit measures ([03 §8](03-units.md#quantities)) |
| `label` | a string | every type | the field's name for a person: `"Request time"` |
| `order` | a non-empty list of distinct states: strings, atoms or numbers | `:category` | the states in their order, first to last |
| `status` | a map from a state to a role | `:category` | what each state means: `%{"ok" => :good, "warn" => :warning}` |
| `polarity` | `:higher_is_better`, `:lower_is_better` or `:neutral` | `:number` | which way the values are better; `:neutral` reads the distance from `target` either way |
| `target` | a number | `:number` | the value the field is measured against |
| `continuity` | a positive number | every type | the longest gap between two readings that is still one run, along the window field: seconds for a `:time` one, the field's own units for a `:number` one |
| `window` | a boolean | `:time`, `:number` or `:point` | `true`: the field a window is over (§1.5); `false`: not the window field, though it is the only `:time` field |
| `metric_kind` | `:gauge`, `:counter` or `:rate` | `:number` | how the values were measured, which refines what the quantity's additivity allows ([03 §10](03-units.md#quantities-additivity)) |
| `bounds` | `[min, max]`, each a number or `nil`, `min` below `max` when both are given | `:number` | where the values physically lie: a display hint overriding the quantity's, never validation |
| `identity` | a boolean | `:category`, `:text` or `:number` | `true`: the field's value names a thing (§1.4) |
| `values` | a non-empty list of values or value entries, distinct by value | `:category` | **every** value the field takes, a closed set (§1.3) |

`attributes/0` is the fourteen keys in that order. `entry_keys/0` is a value entry's three keys, `value`, `name` and `color` (§1.3): metresis reads it to encode schemas (visualize#879), so it is public. `fetch/2` reads a field's description by either spelling of its name (§1.1), `{:ok, description}` or `:error`; `fetch/3` reads one attribute of it.

```test:schema-new
new/1 takes every key with a value it takes, the fourteen keys are attributes/0, type is required and one of the six types, and a key a field's type does not take is refused
```

```test:schema-point
a :point field takes a label, continuity and window, and a unit, an order or identity is refused on it
```

```test:schema-fetch
fetch/2 and fetch/3 read a field and an attribute by either spelling of its name, never making an atom
```

### 1.3 Value entries {#sources-schema-values}

A declared value may say more than that it exists, as a map in place of the bare value: `%{value: v, name: "Display", color: c}`.
- **The keys.** `value` is required and is a value as a bare one is: a string, an atom other than `nil`, `true` and `false`, or a number. `name`, optional, is a string, the value's display name. `color`, optional, is a data color (§1.7). No other key is an entry's.
- **Distinct by value.** The entries' values, bare and map alike, are distinct: `["ok", %{value: "ok", name: "OK"}]` lists `"ok"` twice, `:duplicate` at the later one's index.
- **An entry that says nothing is its value.** `new/1` keeps `%{value: v}` with neither a `name` nor a `color` as the bare `v`, so the two spellings are one schema of one version.
- **Reading them.** `values/2` is the field's bare values in their declared order, `nil` when the field declares none (an open set). `value_names/2` maps each value with a `name` to its name, and `value_colors/2` each value with a `color` to its color; each is `%{}` when none has one. `fetch/3` of `:values` answers the list as declared, entries included.
- **Checked against `order` and `status`.** With `values`, every state `order` lists and `status` names is one of them, compared with the bare values; with `order`, every state `status` names is one of `order`'s.

```test:schema-values
values may be entries with a name and a color, read back by values/2, value_names/2 and value_colors/2 by either spelling; an entry with only its value is that value, one version; every fault of an entry by path; order and status are checked against the bare values
```

### 1.4 Identity {#sources-schema-identity}

Which rows are about the same thing is a fact about the source, so the source declares it: `identity: true` on each field whose value names the entity a row is about. Nothing guesses it.
- **The fields.** `identity` is allowed on a `:category`, `:text` or `:number` field, and never on a `:time` field, which says when, not what, nor on a `:color` or `:point` one (`{:invalid_for, type}`). It is a boolean, and `false` is the same as absent: `new/1` drops `identity: false`, so the two spellings are one schema of one version.
- **Composite.** Several fields may say `true`, together one identity. `identity/1` is the declared fields, ordered by name as a string, `[]` for none.
- **A row's identity.** `identity/2` is bare for one field, a map from field to value for several, each field read by either spelling of its name; `nil` when the schema declares none or the row lacks a value for one of them.

```test:schema-identity
identity is declared on a category, text or number field, never a time one, and only as a boolean; false is absent; identity/1 is the declared fields; identity/2 is bare for one, a map for several, nil when a value is missing
```

### 1.5 The window field {#sources-schema-window}

**The window field** is the field a request's window applies to (§2), by which rows are ordered, trimmed and routed. `Macaw.Data.Schema.window_field/1` is:
- the one field described `window: true`;
- else the schema's **only** `:time` field, unless it says `window: false`;
- else none (`nil`).

A schema with several `:time` fields and none marked has no window field: "the first" is undefined for a map of fields, and a guess would window the wrong one. At most one field says `window: true` (`{:duplicate_window, other}` at the later one).

`window_kind/1` is the window that applies to it: **`:range`** over a `:time` or `:number` field, from one instant or value to another, and **`:box`** over a `:point` field, a region of positions; `nil` when the schema has no window field.

```test:schema-window-field
window_field/1 is the marked field, else the only time field not marked false, else nil, a point field included; a second marked field is refused; window_kind/1 is a range over time or number and a box over a point
```

### 1.6 Measures, status and continuity {#sources-schema-measure}

**A measure is checked against the vocabulary**, so a misspelled unit or an unknown quantity is refused where the source describes itself:
- **`unit`** is a non-empty string (else `{:type, :unit}`) that `Macaw.Data.Unit.parse/1` reads, else `{:unit, code, reason}` with its reason. A symbol a person types (`°C`, `KB`) is not a code; a source reads it with `Macaw.Data.Unit.parse_alias/1` first.
- **`quantity`** is an atom other than `nil`, `true` and `false` (else `{:type, :name}`) that is one of `Macaw.Data.Quantity.all/0`, else `{:unknown_quantity, quantity}`.
- **The pair.** A field giving both, each good, is checked by `Macaw.Data.Quantity.resolve/1`: a unit not of its quantity's dimension is `{:quantity, quantity, code}` at `[name, :quantity]`.

**`status`'s roles** are a theme's words (`:good`, `:warning`, `:bad`, `:info`, `:neutral`), carried by their spelling and not checked against a list, so a role a theme adds needs no change here. A role is never a color (§1.7). **`continuity`** is carried for the components that draw a source; gaps follow it.

```test:schema-measure
a misspelled unit, a symbol a person types, an unknown quantity and a unit that does not measure its quantity are refused where described; a pair is checked once each is good; every quantity in its base unit and every Telemetry unit pass; any role word is carried
```

### 1.7 Colors: data, never drawing {#sources-schema-colors}

A schema describes meaning, and color is the theme's to choose from it ([macaw_layers 04](https://gitlab.conet.yarina.org/dco-tek/macaw_layers/-/blob/main/spec/04-themes.md#themes-rules)):
- **No color on a field.** A key `color`, `colour`, `colors`, `colours`, `palette`, `fill` or `stroke` in a description is `{:color_key, key}`, whose line names the keys that carry the meaning instead (`status`, `order`, `polarity`, `quantity`). <!-- spelling: allow -->
- **A status role is a word, never a color:** a role that is a data color by its spelling is `{:type, :status}`.
- **A data color is a literal** (`color?/1`): `#rgb`, `#rgba`, `#rrggbb` or `#rrggbbaa` in hexadecimal, or a CSS named color (CSS Color 4's, and `transparent`), any case. A value entry's `color` and a `:color` field's row values are data colors. A theme role or a typed color (visualize's `{:color, :good}`, `{:ramp, …}`) is a drawing color, which a schema never holds: `{:type, :color}`. A `:color` field takes only `label` and `continuity`; any other key is `{:invalid_for, :color}`.

How a data color may be shown (only with a non-color cue, under a contrast guard) is a theme rule.

```test:schema-colors-literal
a data color is hex in four lengths or a CSS name, any case; a short hex, a word, a role, a typed color, an atom and a number are not; a typed color in a value entry is refused
```

```test:schema-color-keys
every color key on a field is refused and says why; a color hides in a status neither as a typed color nor as a color string or atom, while a role read from JSON is a role
```

### 1.8 Faults {#sources-schema-faults}

`new/1` reports every fault, each `{path, reason}`, ordered by path; `format_error/1` words each as a line a person reads.

| Reason | At | Meaning |
|---|---|---|
| `{:type, :schema}` | `[]` | not a map of descriptions |
| `{:type, :name}` | `[name]` | a field name that is not an atom (other than `nil`, `true`, `false`) or a non-empty string |
| `{:duplicate_field, other}` | `[name]` | named twice, as an atom and as its string, which are one column; at the later by term order |
| `{:type, :description}` | `[name]` | the description is not a map |
| `:unknown_key` | `[name, key]` | not one of the fourteen keys |
| `{:color_key, key}` | `[name, key]` | a color, which a schema never names (§1.7) |
| `:required` | `[name, :type]` | no `type` |
| `{:enum, allowed}` | `[name, :type]`, `[name, :polarity]`, `[name, :metric_kind]` | a value not among the allowed |
| `{:unit, code, reason}`, `{:unknown_quantity, q}`, `{:quantity, q, code}` | `[name, :unit]` or `[name, :quantity]` | the measure (§1.6) |
| `{:invalid_for, type}` | `[name, key]` | a key the field's type does not take |
| `{:type, expected}` | `[name, key]` or `[name, :values, i, key]` | a value of the wrong shape, `expected` one of `:unit`, `:name`, `:string`, `:order`, `:status`, `:number`, `:positive`, `:boolean`, `:bounds`, `:values`, `:state`, `:color` |
| `:required` | `[name, :values, i, :value]` | a value entry with no `value` |
| `:unknown_entry_key` | `[name, :values, i, key]` | a key of a value entry other than its three |
| `{:duplicate_window, other}` | `[name, :window]` | a second window field |
| `:duplicate` | `[name, :order, i]`, `[name, :values, i]` | a state listed twice |
| `:not_in_order`, `:not_in_values` | `[name, :status, state]`, `[name, :order, i]` | a state the order, or the values, do not list |

```test:schema-faults
the field names and the shape of a schema are checked, every fault is reported by path, new!/1 raises with every fault formatted, and every fault formats as a line
```

### 1.9 Compatibility {#sources-schema-compatibility}

Two schemas can describe the same data in different words: a live feed and a store's history of one metric spell their fields differently (`:t` and `"t"`), label them from different sources, and know different facts. `compatibility(schema, other)` says whether `other`'s rows read as `schema`'s: `:ok`, or `{:error, faults}` with every fault, each `{field, reason}`, the field spelled as `schema` spells it, ordered by its name as a string. The rule is per field of `schema`; `other`'s extra fields are not faults:

| Reason | Meaning |
|---|---|
| `:missing` | `other` has no field of that name, compared as strings |
| `{:type, a, b}` | `other`'s field is of type `b` where `schema`'s is `a` |
| `{:unit, a, b}` | a `:number` field whose units do not convert, `other`'s `b` to `schema`'s `a` by `Macaw.Data.Unit.conversion/2`, or one absent facing a present one; two absent agree |
| `{:identity, a, b}` | the two declare different identity fields, `a` and `b` whether each declares `identity: true` on it. Checked for every field either declares, so an identity field only `other` has is a fault, spelled as `other` spells it: reading `other`'s rows as `schema`'s would merge what `other` tells apart |

No other attribute is compared: a label, an implied quantity, `polarity`, `bounds` or `order` is what each source knows, and reading `other`'s rows keeps `schema`'s.

```test:schema-compatibility
names compare as strings and labels, facts and extra fields are not compared; every fault in the first schema's spelling, by name; units convert or fault, two absent agreeing; different identity fields fault whichever schema declares them
```

### 1.10 The version {#sources-schema-version}

A schema's version is **the kernel's digest of its map form** (`Macaw.Layers.Document.digest/1` over `%{"fields" => to_map(schema)}`, [macaw_layers 01 §7](https://gitlab.conet.yarina.org/dco-tek/macaw_layers/-/blob/main/spec/01-kernel.md#kernel-digest)): 64 lowercase hex characters, the SHA-256 of a canonical JSON encoding. So an unchanged schema has the same version on every node and under every release, and any change of content, a renamed state or a new label, is a new version. `version/1` returns it, computed once by `new/1`.

- **Names, states and roles count by their spelling.** `:latency` and `"latency"` are one field, and `:ok` and `"ok"` one state, so a schema and its trip through JSON, which spells every one as a string, have one version. A delivery read on another node then names a version its reader can resolve (§1.12). This differs from visualize's own hash, which keeps an atom state apart from its string; reconciling the two is visualize's, at adoption.
- **Nothing depends on map order:** the canonical encoding sorts keys, and the fields are pairs sorted by name.
- The test suite pins one schema's version as a literal, so a change to the encoding fails a test before it changes a version in the field.

```test:schema-version
the version is pinned for two schemas, is the kernel's digest of the map form, is the same whichever way a name or a state is spelled, does not depend on the order the maps were built in, and changes with any change of content
```

### 1.11 The JSON form {#sources-schema-json}

**`to_json/1` and `from_json/2` are public,** so no adopter reads a hidden function (visualize#879). The map form, `to_map/1`, is a list of `[name, description]` pairs sorted by name: every description key by its string, every name, state and role by its spelling, every word of the vocabulary (`type`, `quantity`, `polarity`, `metric_kind`) as its string, `status` as sorted `[state, role]` pairs, `bounds`, `values` and booleans as they are. `to_json/1` is it encoded.

**Reading** (`from_map/1`, `from_json/2`):
- `from_json/2` reads through the kernel's gates first, the byte limit and the scan that stops at a depth or items limit ([macaw_layers 01 §5](https://gitlab.conet.yarina.org/dco-tek/macaw_layers/-/blob/main/spec/01-kernel.md#kernel-gates)), `limits:` tightening them, and then decodes;
- each word is read through its own closed vocabulary, and every name, state and role is a string: **no atom is made from a document**;
- a key no description or entry has stays its string, and a word outside its vocabulary stays its string, for `new/1` to refuse by name;
- anything but a list of `[string, map]` pairs is `{[], {:type, :schema}}`.

A schema read back from its JSON form has the same version and the same JSON form; one spelled with strings, as JSON spells it, reads back exactly.

```test:schema-json-form
to_map/1 is the sorted pairs with every name, state, role and word by its spelling, status as sorted pairs, bounds and values as they are, and to_json/1 is it encoded
```

```test:schema-json-read
from_json/2 reads words through their vocabularies and names and states as strings, makes no atom, refuses an unknown word or key by new/1, refuses a non-schema and malformed JSON, and applies the byte and depth limits
```

```test:schema-json-round-trip
for generated schemas, the schema read back from its JSON has its version and its JSON, and a string-spelled one reads back exactly
```

### 1.12 The cache {#sources-schema-cache}

Schemas are cached by `{source, version}`: a delivery whose version is known costs a map lookup, and one with a version not seen before makes the holder ask the source once. `Macaw.Data.Schema.Cache` is that cache as a **value**, `%Cache{entries}`, not a process and not a table: whatever owns the sources holds it and passes it in, and gets the grown cache back. A source is any term that names one, one source whichever spelling names it.

`new/0` is the empty cache, `new/1` one holding `{source, schema}` pairs, `put/3` adds a schema under its own version, and `fetch/3` is `{:ok, schema}` or `:error`. `resolve(cache, source, version, describe)`, `describe` being `(source -> {:ok, schema} | {:error, reason})` or `nil`, returns:
- `{:ok, schema, cache}` unchanged when the version is cached: describe is not called;
- `{:ok, schema, cache}` with the schema added when describe answers that version: it is called once;
- `{:error, {:schema_version, source, version, got}, cache}` when describe answers another version, which is still cached under its own;
- `{:error, {:describe, source, reason}, cache}` when describe fails;
- `{:error, {:unknown_schema, source, version}, cache}` when the version is not cached and there is no describe.

The cache never evicts: its owner replaces the value when it wants it smaller.

```test:schema-cache
a cached version costs nothing, an unknown one calls describe once and is cached, another source is another entry, another version is reported and cached, a failing or absent describe is reported, and put/3 keys by the schema's own version
```

## 2. The contract {#sources-contract}

**`Macaw.Data.Source` is the behavior** every source implements: a struct whose module answers

```elixir
@callback describe(source, context) :: {:ok, %Source.Description{}} | {:error, reason}
@callback fetch(source, %Source.Request{}) :: {:ok, %Delivery{}} | {:error, reason}
@callback subscribe(source, pid) :: {:ok, reference} | {:error, reason}   # optional, §4
@callback unsubscribe(source, reference) :: :ok                            # optional, §4
```

- **`describe/2`** takes the host's configuration for the source as its `context`, **never a viewer**: what a source is doesn't depend on who asks. So it is answered at boot and cached until the source's schema version changes (§1.12), and validation reads it without I/O ([macaw_compose 07](https://gitlab.conet.yarina.org/dco-tek/macaw_compose/-/blob/main/spec/07-documents.md#documents-validation-time)).
- **The dispatch functions** (`Source.describe/2`, `fetch/3`, `subscribe/2`, `unsubscribe/2`) call a source's module. An answer of the wrong shape is a value too: `{:error, {:bad_describe, answer}}` or `{:error, {:bad_fetch, answer}}`.
- **`fetch/3` checks the request against the description first** (§2.2): a request with an unknown, missing or illegal parameter is `{:error, {:params, faults}}`, and the source is never called. The source receives every parameter, defaults filled in.
- **`subscribe/2` on a source that does not push** is `{:error, :no_push}`, and `unsubscribe/2` on one is `:ok`.
- **`describer/1`** turns a map of named sources, each with its context, into the describe function `Schema.Cache.resolve/4` takes; a name not in the map is `{:error, :no_source}`.
- **Errors are values.** A source never raises. (visualize.md C1; metresis.md C1.)
- **The viewer is an argument, not a setting.** A source may refuse, filter or tease by it. Macaw never writes a viewer to a document, delivery or record. (dcotek_web.md C11; visualize.md C11.)
- **Preferences are state, not part of the viewer.** A viewer's display preferences (`theme`, `zone`, `units`) are state sources ([macaw_compose 03](https://gitlab.conet.yarina.org/dco-tek/macaw_compose/-/blob/main/spec/03-state.md#state-sources)), persisted like any other state and passed to components in their context. The viewer carries identity and access only.

It is a strict superset of visualize's `Visualize.Feed`: an existing feed is a source with no parameters. visualize's `describe/1` answered `{version, schema, supports}` and `fetch/3` took a window and a budget; adapting a feed is visualize's (#112).

```test:contract-describe
describe/2 answers a description from the host's context, a malformed answer is the bad_describe value, and the capabilities are the seven in order
```

```test:contract-fetch
fetch/3 refuses bad parameters without calling the source, fills defaults for the source, honors the reference source's window and parameter, and a malformed answer is the bad_fetch value
```

```test:contract-push-dispatch
subscribe/2 reaches a pushing source and is no_push for one that does not; unsubscribe/2 is :ok for both
```

```test:contract-describer
describer/1 answers a named source's schema, no_source for an unknown name, and serves Schema.Cache.resolve/4
```

### 2.1 The description {#sources-description}

`%Macaw.Data.Source.Description{schema, params, supports, viewer_independent}`, built by `new/1`, which reports every fault at once by path:
- **`schema`**, required, a `Macaw.Data.Schema` (§1.2).
- **`params`**: the parameters the source takes, by name, each a parameter (§2.2); `%{}` by default. A name is a non-empty string.
- **`supports`**: the capabilities it honors, distinct, among `:window`, `:box`, `:region`, `:latest`, `:budget`, `:push` and `:as_of`; `[]` by default. **Every capability is optional:** Macaw finishes a window, box, region, latest or budget the source did not honor, and reports it (§2.4). (visualize.md C1, D-140.)
- **`viewer_independent`**: `true` declares that the source answers every viewer the same. It only allows pooling across viewers (§6), which fetches with the anonymous viewer, so a wrong declaration shows everyone the anonymous answer and never one person's rows to another. The conformance kit checks it by asking two viewers. `false` by default.

There is no other key: the earlier `reveals`, a declaration of what a result tells about the viewer for a page's privacy note, was removed (the owner's decision, 2026-10-27): a page notice of what it shows had no use case, and viewer dependence is what `viewer_independent` and the kit already check.

- **Window-less sources are allowed** (thresholds, projects, fragments). (metresis.md C1; dcotek_web.md C1.)

```test:contract-description
a description defaults its parameters, capabilities and independence, and refuses a bad name, a bad parameter, a non-list of capabilities, a non-boolean independence, an unknown key such as reveals, and a missing schema
```

### 2.2 Parameters {#sources-parameters}

**A parameter is the one shape for every typed option,** a source's or a component's: `Macaw.Data.Parameter`. macaw_data owns it (the owner's decision, 2026-10-27), since sources take parameters before any component exists; macaw_compose's components use the same shape ([macaw_compose 05 §1.1](https://gitlab.conet.yarina.org/dco-tek/macaw_compose/-/blob/main/spec/05-components.md#components-parameters)).

```elixir
%{type: type,                           # required
  default: value,                       # absent: the parameter is required
  values: [value] | nil,                # a closed list of legal values
  legal_for: {slot, field, fact} | nil, # legal values follow from a bound slot's schema
  bindable: false,                      # may it be bound to state? closed by default
  doc: "…"}
```

- **Types:** a data-model type (`:time`, `:number`, `:category`, `:text`, `:color`, `:point`), `{:document, type}` for a nested document of a document type, or `:term`, a value its owner validates, only for options migrated from untyped forms. `conforms?/2` says whether a value is of a type: a `DateTime`, a number, a string or non-boolean atom or number, a string, a data color (§1.7), a `{longitude, latitude}` in range, a map, or anything for `:term`; `nil` is a value only of `:term`.
- **`check/1`** reports every fault of a declaration, by path: the type required and known; the default and each of the values of the type; the default among the values when both are given; `legal_for` a `{slot, field, fact}`; `bindable` a boolean; `doc` a string; no other key. `keys/0` is the six keys.
- **`validate/2`** checks given values against a map of parameters by name, every fault at once: a name no parameter has is `:unknown_param`, a missing parameter with no default `:required`, a value not of its type `{:type, type}`, one outside its values `{:enum, values}`. It answers the values with every missing parameter's default filled in.
- **Legal values may come from the type.** metresis's aggregation is a category whose values are `legal(metric)`, so no consumer can ask for an aggregation the type forbids; `legal_for` names where such values come from, which the runtime that binds slots resolves. (metresis.md C1.)

```test:params-shape
a declaration of every type, and one with every key, passes; every fault of a bad one is reported at once by path; no type, an unknown type, a non-map and empty values are refused
```

```test:params-types
values conform to their types and to nothing else: times, numbers, categories, text, data colors, points in range, documents and terms; nil only to a term
```

```test:params-validate
given values are checked by name, every fault at once, defaults filled in; a value in the closed values is accepted and any other refused by name, for generated values
```

### 2.3 The request {#sources-request}

`%Macaw.Data.Source.Request{}`, built by `new/1`, `now` required, every fault at once by field:

| Field | Value | Default |
|---|---|---|
| `params` | the parameters by name, checked before the call (§2.2) | `%{}` |
| `window` | `[from, to]` over a `:time` or `:number` window field, either bound `nil` for open (§1.5) | `nil` |
| `box` | `%{west, south, east, north}` over a `:point` window field, in degrees, latitudes −90 to 90 with `south` at most `north`, longitudes −180 to 180, `west` east of `east` crossing the antimeridian (`box?/1`) | `nil` |
| `region` | ranges over named `:time` or `:number` fields, `%{field => [from, to]}` | `nil` |
| `latest` | `true` asks for each identity's latest row (§1.4) | `false` |
| `budget` | the most rows the reader wants, a positive integer | `nil` |
| `as_of` | the `DateTime` the answer is as of, for a source supporting `:as_of` | `nil` |
| `viewer` | the host's viewer, **opaque** here: passed to the source, never stored or inspected; `nil` is the anonymous viewer | `nil` |
| `now` | the instant, given by the surface: a source never reads a clock (§6) | required |

`region` keeps visualize's region (ranges over several fields at once) beside the geographic `box`, so a region-supporting `Visualize.Feed` has an equivalent, and `latest` asks for what `supports: [:latest]` honors; both are the owner's decisions of 2026-10-27.

- **The budget never widens the window.** A source may refuse to split a bucket's keys, delivering nothing rather than a partial distribution. (metresis.md C1.)

```test:contract-request
a request carries every axis with its defaults; every fault of a bad window, box, region range, latest, budget, as_of, now and an unknown key is reported at once; an empty region is refused
```

### 2.4 Finishing {#sources-finishing}

**Macaw finishes what a source did not honor** (`Macaw.Data.Source.Finish.finish/3`). Every capability is optional; where the description's `supports` lacks one the request asks, finishing does it to the delivery, in this order, and reports it in `served` (§3):

1. **`:window`**: the rows trimmed to the window field's range, both bounds inclusive, an open bound open; the served window intersected with the asked one. A schema with no window field is not trimmed.
2. **`:box`**: the rows trimmed to the positions in the box over the `:point` window field, across the antimeridian when `west` is east of `east`; the served window is the box.
3. **`:region`**: the rows trimmed to each ranged field's range.
4. **`:latest`**: each identity's latest row by the window field, the later in order on a tie; a row whose identity or time is `nil` names nothing and is dropped.
5. **`:budget`**: the rows reduced to the budget, `reduced_by: :runtime`. Each series (the rows sharing every `:category` field's value) is reduced field by field against the window field, or the row's place without one, by Largest-Triangle-Three-Buckets or, with `reduce: :m4`, by M4 (`Macaw.Data.Reduce`), and the union of the kept rows returned whole, in their order. When many series leave the union over the budget, an even stride over it keeps the first and the last: **never more than the budget**. A delivery within the budget, and a schema with no `:number` field to reduce by, come back as they are.

A step the source honored is not done again. **Finishing only removes rows,** so it never widens the window and never adds a row. A request the schema cannot answer (`Macaw.Data.Window.check/2`) raises `ArgumentError`: a window not of the window field's type or with no window field, a box with no `:point` window field, a region field not described, not `:time` or `:number`, mixed or inverted, or `latest` with no window field or no declared identity; the request is the caller's. `Macaw.Data.Window` holds the comparisons, trims and positions it uses, ported from visualize's `Visualize.Feed.Window`.

```test:finish-window
a window the source did not honor is trimmed, an open bound open, the served window intersected; an honored window, and no window, leave the delivery as it is; a time window trims by DateTime, and a number window on a time field is the caller's error
```

```test:finish-box
a box keeps the positions in it, across the antimeridian too, a missing position dropped; the served window is the box; an honored box is not redone; a box with no point window field is the caller's error
```

```test:finish-region
a region trims each ranged field, the window field among them; an honored region is not redone; an unknown, a categorical and an inverted range are each named
```

```test:finish-latest
latest keeps each identity's latest row by the window field, dropping a row with no identity; an honored latest is not redone; it needs a declared identity and a window field
```

```test:finish-budget
a budget the source did not honor is reduced, the ends kept, recorded runtime; an honored or unneeded budget is not; series share it; m4 reduces too
```

```test:finish-only-removes
for generated rows, windows and budgets, finishing keeps only rows of the input, all within the window, and at most the budget
```

```test:window-arithmetic
times compare by kind; intersections, positions, the newer seam, applies and the instant and time predicates; nothing but a position is in a box
```

## 3. Deliveries {#sources-delivery}

**`Macaw.Data.Delivery` is one answer of a source:** its rows, and what it actually served, a handful of terms beside the rows, never per row. `%Delivery{table, schema, served, origin}`:
- **`table`**, the rows, a `Macaw.Data.Table` (§1.1). `new/2` reads any source shape into one at the edge (`types:` passed to `Table.from/2`; a table passes as it is), and raises `ArgumentError` for rows no table reads. `rows/1` is the row view.
- **`schema`**, the **version** of the schema the rows were produced under (§1.10), never the schema itself, which the cache holds by version (§1.12); `nil` when the source has none.
- **`served`**, what this answer served, which may differ from what was asked:
  - `window`: a range `[from, to]` over a `:time` or `:number` window field; a **box** `%{west: w, south: s, east: e, north: n}` over a `:point` one, in degrees, latitudes from −90 to 90 with `south` at most `north`, longitudes from −180 to 180 (`west` east of `east` crosses the antimeridian); or `nil`;
  - `resolution`: the spacing of the rows as served (seconds, or a name such as `:minute`), or `nil`;
  - `capped`: whether the source stopped short of the window it was asked for, `false` by default;
  - `reduced_by`: who brought the rows within budget: **`:source`** (the source honored the budget) or **`:runtime`** (Macaw reduced a pooled delivery to this reader's budget, finished a budget the source didn't honor, or clamped a budget to the host ceiling); `nil` when nobody had to. A component that draws fewer rows than it was handed says so in its own drawn state ([macaw_compose 05](https://gitlab.conet.yarina.org/dco-tek/macaw_compose/-/blob/main/spec/05-components.md#components-states)), not in the delivery;
  - `params`: the parameters it was answered for, a map, `%{}` by default;
  - `note`: a line for a person (`"coarsened from raw"`), or `nil`.
- **`origin`**: `%{source: name, request: digest, as_of: time}`, the source, a digest of the request (`Macaw.Layers.Document.digest/1` of it), and the `DateTime` it is as of when used, else `nil`; or `nil`.

`new/2` raises `ArgumentError` naming the fault for a key that is not a delivery's or a served fact, or a value a field does not take. visualize's `Visualize.Data.Delivery` holds these facts flat, with `reduced_by: :feed | :visualize` and no `served` or `origin`; mapping them at adoption is visualize's.

**Absence is never zero:** a source never fills a gap with 0, and a delivery's table keeps every gap `nil` (§1.1). (metresis.md C1.)

```test:delivery-table
a delivery's rows are a table read from rows, columns and keyword columns, a table passing as it is, types taken; rows no table reads and a delivery of a delivery are refused
```

```test:delivery-absence
for generated values with gaps, every gap reads back nil through the delivery's table, and only the gaps
```

```test:delivery-served
served holds the window, resolution, capped, reduced_by (source or runtime), params and note, with their defaults; visualize's feed and visualize reductions, a one-element window and every other bad fact are refused
```

```test:delivery-box
a box window over a point field takes four bounds, may cross the antimeridian, and refuses latitudes out of order or range, a longitude out of range, a missing or an extra bound
```

```test:delivery-schema-origin
a delivery names the schema's version, never the schema; its origin is the source, the request's digest and as_of, nil by default; malformed versions and origins are refused
```

## 4. Push {#sources-push}

Push is optional and declared (`:push` in `supports`). A pushing source implements `subscribe(source, pid)`, answering `{:ok, ref}`, and `unsubscribe(source, ref)` (§2); `Macaw.Data.Source.subscribe/2` answers `{:error, :no_push}` for a source that doesn't. It sends the subscriber two messages, both tagged with that reference (`Macaw.Data.Source.Push.schema_message/2`, `delivery_message/2`):

```
{:macaw_source, ref, {:schema, schema}}      first, and again whenever the schema changes
{:macaw_source, ref, {:delivery, delivery}}  an increment: the rows new since the last
```

The subscriber holds a `Macaw.Data.Source.Push`, a value, not a process: `receive/2` takes each message, `:ignore` for one not under its reference; `drain/2` merges what is buffered; `held/1` is the delivery as it stands.

- **The handshake sends the schema first,** so an increment naming its version resolves from the cache without asking the source.
- **A pushed delivery is an increment, merged by the window field.** Its rows after what is held are appended; its late rows, at or before that, are kept unless the very row is held already; the rows stay ordered by the window field, and the served window grows to cover them. A schema with no window field keeps the newest `limit` rows (100 000), marking the delivery `capped` when it drops any.
- **Pushes between two pulses are coalesced:** they buffer, and one `drain/2` merges them all in the order received, whatever the push rate.
- **An unknown schema version falls back to `describe`,** asked once through `Macaw.Data.Schema.Cache.resolve/4` and cached. An increment whose version can't be resolved is dropped and its reason kept in `errors`.

(visualize.md C1; metresis.md C1. The merge is visualize's `Visualize.Feed.Monitor`'s, whose message tag was `:visualize_feed`.)

```test:push-handshake
a subscription's schema message arrives first and is cached, so its increments drain without describe; a message under another reference, or of another shape, is ignored
```

```test:push-unknown-version
an increment naming an uncached version asks describe once and caches it; a version describe cannot answer drops the increment and keeps the reason
```

```test:push-merge
increments merge by the window field, newer appended, late placed, a held row not added twice, the served window grown; with no window field the newest rows to the limit, capped; for any split and any repeat, each row once in time order
```

```test:push-coalesce
fifty pushes buffer without a merge, and one drain merges them all in order
```

## 5. Change notification {#sources-change}

<!-- surfex: deferred #108: change notification needs the page runtime -->

**"This source's data changed; re-read it."** Any writer (an editing component after a commit, a host after an import) announces a change to a source by name, or the source pushes. Every reader on the page, and on other pages through the notification behavior ([macaw_compose 00](https://gitlab.conet.yarina.org/dco-tek/macaw_compose/-/blob/main/spec/00-overview.md#overview-goals) goal 3), re-fetches. Components never need to know who else reads the same data. (macaw_compose#9.)

## 6. Running sources {#sources-running}

### 6.1 Budgets: the ceiling and pooling {#sources-budgets}

- **The host ceiling** clamps every slot's budget ([macaw_compose 05](https://gitlab.conet.yarina.org/dco-tek/macaw_compose/-/blob/main/spec/05-components.md#components-budget)). A host sets it once; a page may lower it, never raise it. `Finish.ceiling/2` is the rule: `{budget, clamped?}`, a `nil` budget reading at the ceiling.
- **Pooling:** several readers of one source and request cost one fetch, at the largest budget among them (`Finish.pooled/1`, `nil` when any reader wants every row), and each reader is reduced to its own budget (`Finish.reduce/4`, `reduced_by: :runtime`). (visualize.md C1.)

```test:finish-ceiling-pool
the ceiling clamps a budget, reads a nil one at the ceiling and takes a page's lower one, never a higher; a pooled fetch asks the largest, nil when any reader wants every row; each reader is reduced to its own
```

### 6.2 On pages {#sources-running-pages}

<!-- surfex: deferred #108: running sources on pages needs the page and surface runtime -->

- **Sources are named and pooled by the page.**
- **Pooling across pages** is required in v1 (macaw_compose#22, decision 9). A request to a source that declares itself `viewer_independent` is fetched **once, with the anonymous viewer**, for every page making it, and delivered to each through the notification behavior. Fetching as the anonymous viewer makes the result independent of the viewer by construction, whatever the source does with the viewer. A surface whose state is `:shared`, watched by many viewers, then costs one fetch per pulse, as a visualize board does today. A source that doesn't declare it is never pooled across viewers.
- **Fetching never blocks the caller.** It runs out of process, with a liveness bound. The first render waits for a bounded time and then draws the loading state. (visualize.md C13 gap; dcotek_web.md C13.)
- **`now` comes from the surface.** One instant per pulse keeps windows, freshness and ages consistent. (visualize.md C1.)

## 7. Credentials {#sources-credentials}

<!-- surfex: deferred #108: the host maps a source name to its configuration in the page runtime -->

Credentials and source configuration never appear in documents. A page names a source; the host maps the name to a configured source (its **source configuration**). For metresis, that is a per-domain token, ideally scoped (metresis#555). (visualize.md C1, D-141; metresis.md C11.)

## 8. The interaction event {#sources-event}

Every component emits interaction in **one struct**, `Macaw.Data.Event`, defined in `macaw_data` so that an adopter using no other Macaw library (visualize standalone) emits the same value it emits on a Macaw page (macaw_compose#22, decision 4; visualize#941):

```elixir
%Event{
  name:      String.t(),               # a name the component declares
  instance:  String.t(),               # the emitting instance's id (macaw_compose spec 01)
  element:   %{frame: id | nil, item: id | nil, path: [id]},  # path innermost first
  identity:  %{field => value} | nil,  # the declared identity of the item, when it maps to data
  value:     term,                     # the event's own value: a window, a chosen option
  initiator: :visitor | :system,
  time:      DateTime.t(),             # the surface's (or standalone holder's) now; never a clock read
  point:     {x, y} | nil,             # where, in the drawing; live only
  modifiers: [atom],
  row:       map | nil                 # the data row, delivered to the host, never recorded
}
```

`name`, `instance`, `initiator` and `time` are required to build one; the rest default: `element` to `%{frame: nil, item: nil, path: []}`, `modifiers` to `[]`, and `identity`, `value`, `point` and `row` to `nil`.

```test:event-struct
the struct can't be built without name, instance, initiator and time, and its defaults are the ones this section lists
```

- **The recorded form,** `Macaw.Data.Event.recordable/1`, drops `row` and `point`. Records, observation and state snapshots only ever see the recorded form, so **row values never reach them**. The `identity` and the event's own `value` do, and they can be personal; whether they are recorded is decided per state source by capture level ([macaw_compose 08](https://gitlab.conet.yarina.org/dco-tek/macaw_compose/-/blob/main/spec/08-records.md#records-stores)).
- **Building one:** `Macaw.Data.Event.new/1` builds an event from a keyword list or a map, checking every field: `name` and `instance` non-empty strings, `initiator` `:visitor` or `:system`, `time` a `DateTime`, `element` a map of `frame`, `item` and `path` with `path` a list (missing keys default to `nil`, `nil` and `[]`), `identity` and `row` a map or `nil`, `point` a pair of numbers or `nil`, `modifiers` a list of `:shift`, `:alt`, `:ctrl` and `:meta`. It returns `{:ok, event}` or `{:error, faults}`, a fault per bad field, **every one at once**, and a field the struct doesn't have is a fault too (`"is not an event field"`), never silently dropped. `Macaw.Data.Event.fields/0` lists the fields in this section's order, which an adopter's interim definition is checked against (macaw_compose spec 00 §5).

```test:event-fields
the struct's fields are exactly name, instance, element, identity, value, initiator, time, point, modifiers and row, and fields/0 returns them in that order
```

```test:event-new-defaults
new/1 with the four required fields builds an event whose element is %{frame: nil, item: nil, path: []}, modifiers [] and point nil
```

```test:event-new-faults
new/1 with a bad name, instance, initiator, time, point, modifiers, element and row and an unknown field returns every one of them as a fault, the unknown one as "is not an event field"
```

```test:event-new-valid
every event with non-empty name and instance, either initiator, a DateTime, modifiers from the four and a list path is accepted (property)
```

```test:event-recordable
recordable/1 drops row and point and keeps every other field, identity and value included
```

```test:event-recordable-no-row
no value of the row ever appears in the recorded form (property over rows carrying a unique marker)
```

### 8.1 Rules for the components that emit events {#sources-event-rules}

<!-- surfex: class component-rule -->

These bind the component that draws, not this library's code; each emitting library's conformance kit checks them (macaw_compose spec 12).

- **`element`** locates what was acted on: the component fills it. `item` is the element's stable id ([macaw_compose 05](https://gitlab.conet.yarina.org/dco-tek/macaw_compose/-/blob/main/spec/05-components.md#components-declares)); `path` lists **the item and its enclosing elements, innermost first** (a visual's mark is `[item]`; a prose component's element, its sections around it), aligned with visualize's established meaning (macaw_compose#65); `frame` is set only by components with an inner coordinate tree (a visual's frame), and is `nil` otherwise.
- **`initiator`**, which the component sets, separates the steps of a view path (a visitor did something) from its markers (the system did something) ([macaw_compose 08](https://gitlab.conet.yarina.org/dco-tek/macaw_compose/-/blob/main/spec/08-records.md#records-paths)). A paused animation is a system event.
- **`time`** is the holder's now, passed to the component; a component's event code never reads a clock for it. A Macaw surface always supplies its own clock, which tests and replays control, so a recorded path replays with its times. A **standalone holder** (a visualize chart outside any surface, whose host is its holder) may default its now to the host's wall clock, if the default stays injectable and is checked to answer a `DateTime` (macaw_compose#73, #91; visualize#955).
- **The drawn-token rule:** an event on an element that maps to data resolves against the drawing it landed on. Each drawing carries a token; an event whose token is not the current drawing's is dropped, never resolved against newer data. (visualize D-170.)
- **Identity is the declared identity** of the item (§1). Inference from other fields is allowed only for a visitor's one-off pick, never for tracking or recording. (visualize D-167.)
