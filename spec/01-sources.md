# 01 — Sources {#sources}

A **source** is anything a component's slot reads. One contract serves feeds, queries, derived sources, state sources and exports. It is a strict superset of visualize's `Visualize.Feed`: an existing feed is a source with no parameters.

## 1. The data model {#sources-data}

- **`Data.Table`:** columnar typed data, the currency of deliveries, derived sources and components. Row lists are accepted at the edge ([§1.1](#sources-table)). (visualize.md C1.)
- **`Data.Schema`:** each field's **meaning**: `type` (`:time | :number | :category | :text | :color | :point`, a `:point` being a geographic position), and where known `unit` (UCUM), `quantity`, `label`, `order`, `status`, `polarity`, `continuity`, `bounds`, `identity`, `window`, and declared `values` with names and colors ([§1.2](#sources-schema)). (visualize.md C1.)
- **The window field** is the field a request's window applies to: the one marked `window: true`, else the schema's only `:time` field. A `box` window applies to a `:point` window field. A schema with neither, or with several `:time` fields and none marked, has no window field, and requests to it carry none ([§1.5](#sources-schema-window)).
- **A description never names a color; a row or a value entry may carry a data color.** A `:color` field's values, or a color on a declared value (a team's color), are content: a color term, a literal `%Macaw.Layers.Color{}` or a theme-relative typed color, and never a string. How one may be shown is the theme's data-color guard ([macaw_layers 04 §4](https://github.com/dcoai/macaw_layers/blob/main/spec/04-themes.md#themes-profile)).
- **A schema's version is the SHA-256 of a canonical encoding,** the kernel's digest of the schema's term, its fields with every name normalized to its string at construction; the JSON form is an adapter the version never goes through ([§1.10](#sources-schema-version)). A delivery names the version, and a push sends the schema before rows made under it. (visualize.md C1; metresis.md C1.)
- **Identity is declared** (`identity: true`, composite allowed), never guessed. Selection, `latest` and per-identity derivations read it. (visualize.md C1.)
- **Units and quantities** come from one vocabulary, specified in [03](03-units.md): UCUM codes with an ISO 4217 currency extension, and a fixed list of quantities. Nothing translates between two vocabularies. (metresis.md C1.)

### 1.1 The table {#sources-table}

**`Macaw.Data.Table` is columnar typed data,** the currency of derived sources and components, and the form a delivery packs into for a reader that wants columns (§3). A table is named columns of declared types, every column the same length. Its design is visualize#916's (closed when this step absorbed it): rows as lists of maps cost a garbage collection that copies every row, and packed columns don't.

| Type | Holds |
|---|---|
| `:number` | integers and floats |
| `:time` | `DateTime`s, `NaiveDateTime`s or `Date`s |
| `:text` | any value; text is strings |
| `:category` | any value; a category is a string, an atom spelling one, or a boolean |
| `:color` | color terms, literal or typed (§1.7) |
| `:point` | `{longitude, latitude}` pairs of numbers |
| `:term` | any value |

**Packing never changes a value.** A column is stored in the narrowest form that holds exactly what it was given, laid out as the [Arrow columnar format](https://arrow.apache.org/docs/format/Columnar.html) lays it out, so a column reaches Arrow JS, Explorer, DuckDB or Parquet with at most a copy. Every value reads back `==` to the one given, with one exception by design: a category's atom reads back as the string that spells it. A column whose values no packed form holds exactly is kept as its list of values, the `:term` form, whatever its declared type; its type does not change. The forms (macaw#188 D5, #16):

| Type | Values | Stored as | Arrow's form |
|---|---|---|---|
| `:number` | every one an integer in int64 | little-endian int64 values | `int64` |
| | every one a float | little-endian float64 values | `float64` |
| | both, every integer within ±2^53 | float64 values and an integral bitmap, a bit set where the value was an integer | extension `macaw.integral`, a struct of `value: float64` (first) and `integral: bool` |
| | both, an integer beyond ±2^53 | a dense union: an int8 type id per value (0 for int64, 1 for float64), an int32 offset per value into that child, and the two children | `dense_union<int64 = 0, float64 = 1>`; a missing value is a missing slot of the int64 child, since a union has no validity bitmap of its own |
| | an integer beyond int64 | the list | (none) |
| `:time` | `DateTime`s, every one UTC (`Etc/UTC`, `UTC`, both offsets 0) | int64 microseconds since the Unix epoch | `timestamp[us, UTC]` |
| | `DateTime`s in any other zone | the same UTC microseconds, an int32 code per value, and the column's dictionary of whole zones `{time_zone, zone_abbr, utc_offset, std_offset}` in the order they first appear | extension `macaw.zoned` over a struct whose first field is `instant: timestamp[us, UTC]` and whose second is `zone`, the codes into a dictionary of structs of `time_zone: utf8`, `zone_abbr: utf8`, `utc_offset: int32`, `std_offset: int32` |
| | `NaiveDateTime`s | int64 wall-clock microseconds since 1970-01-01 00:00:00 | `timestamp[us]`, no zone |
| | `Date`s | int32 days since 1970-01-01 | `date32` |
| | kinds mixed, or a calendar other than ISO | the list | (none) |
| `:text` | strings, each valid UTF-8 (`String.valid?/1`) | n + 1 int32 offsets and one data buffer of the strings' bytes, value i the bytes from offset i to offset i + 1 | `utf8` |
| | binaries, one not valid UTF-8 | the same offsets and data | `binary` |
| | anything else, or more than 2^31 - 1 bytes | the list | (none) |
| `:category` | strings (valid UTF-8) and atoms, with or without booleans | an int32 code per value into a dictionary that is itself a text column of the distinct strings, in the order they first appear; an atom and the string that spells it (`Operations.same?/2`) are one code. Booleans beside them take two side bitmaps, which slots hold a boolean (their kind) and its value | `dictionary<int32, utf8>`; with booleans, extension `macaw.category` over a struct of that dictionary (first, missing at a boolean's slot) and `boolean: bool` (missing elsewhere) |
| | booleans only | a bitmap of the values | `bool` |
| | any other value (strings beside numbers), or a string not valid UTF-8 | the list, each atom as its string | (none) |
| `:color`, `:point`, `:term` | any | the list | (none) |

- **Faithful zones without a time-zone database.** A `DateTime` holds its zone's name, abbreviation and both offsets, and `==` compares them all. Offsets change within one zone (Denver is MST in winter, MDT in summer), and macaw_data has no time-zone database, so a zone name on the column could not rebuild the values. A zoned column stores each whole zone once in its dictionary: one named zone is about two entries, standard and daylight time. Any Arrow reader of the struct's first field reads the correct instants.
- **Precision.** A time's precision (the second element of its `microsecond`) is on the column when every value shares it, else in a side buffer of one byte per value. In Arrow's form it is the field's metadata `macaw.precision` when uniform; else a `precision: uint8` field, the last of `macaw.zoned`'s struct, or, for a UTC or naive column, of an extension `macaw.precise` over a struct of `instant` (first) and `precision`. So `~U[2026-01-01 00:00:00Z]` and `~U[2026-01-01 00:00:00.000000Z]` stay distinct.
- **Category values read back as strings** by `rows/1`, `get/2` and `column/2`, in every form: the rule is the `:category` type's, not its encoding's. An atom other than `nil`, `true` and `false` is held as the string that spells it, in the list too, and those three stay themselves. So `[:ok, true, "warn"]` reads back `["ok", true, "warn"]` whichever form holds it.
- **Text is Arrow `utf8` only when it is valid UTF-8,** every string checked by itself (two halves of one character are each invalid, though their bytes together are not). A text column holding a binary that is not is Arrow `binary`, the same layout; a category column holding one is kept as its list.
- **A missing value is `nil`,** in every type. A packed column keeps a **validity bitmap** beside its buffers, so a gap stays a gap and reads back as `nil`, never as 0 (§3). A bitmap is **least-significant-bit first,** as Arrow numbers bits: value i is bit (i rem 8) of byte (i div 8), and the padding bits of the last byte are 0. A missing value's slot in a values buffer holds zeros, which Arrow leaves unspecified, and takes no bytes of a text column's data.
- **`new/1`** builds a table from `{name, type, values}` columns and reports every fault at once: a type not in the list (`{:enum, types}`), a value its type does not hold (`{[name, i], {:type, type}}`: a number column's non-number, a time column's non-time, a color column's value that is not a color term, `Schema.color?/1`, a point column's non-point), a value that is not data, a function, a PID, a reference, a port or an improper list, which has no digest (`{[name, i], :not_data}`, §1.1.2), a column of another length than the first (`{:length, n}`), a name given twice (`:duplicate`). `new!/1` raises naming them.
- **Reading back:** `column/2` is a column's values in order. `rows/1` is the row view: one map per row keyed by every column name. `row/2` is one row, `nil` past the end; `names/1`, `size/1` and `column_type/2` describe the table.
- **`slice/3`** is a run of rows as a table of the same columns. It keeps the chunks the run spans and where the run starts and ends in them (§1.1.1), copying nothing; a column read from it slices its packed buffers and shifts its bitmaps to start at the slice. A text column's offsets keep pointing into their chunk's data, and a dictionary column keeps its chunk's dictionary, as Arrow's slices do.
- **The packed columns live off the process heap:** a binary over 64 bytes is reference-counted, so a collection never copies it. A table's cost to its process is a constant number of words per chunk, never per row.
- **Chunked** (§1.1.1): every form above is a chunk's, so a zoned column's and a category column's dictionary are its chunk's.

```test:table-new
new/1 builds named typed columns and refuses an unknown type, a value of the wrong type, a column of another length and a duplicate name, all at once, ordered by path; a string in a color column is refused
```

```test:table-packed
number and time columns are packed with a validity bitmap; a gap reads back nil, never 0
```

```test:table-numbers
an integer column is int64 and a float column float64; a mixed column within ±2^53 reads back as given through the integral bitmap, one with 2^60 through the dense union, and 2^70 keeps the column a list
```

```test:table-times
an all-UTC column is a plain UTC timestamp; one named zone across a daylight-saving change has two zone entries; mixed zones, mixed precision, naive times and dates read back == as given, with no time-zone database; mixed kinds keep the list
```

```test:table-text
a text column is offsets and one data buffer, Arrow binary when a value is not valid UTF-8; a category column is codes and a dictionary, an atom and its string one code read back as the string, booleans beside names in side bitmaps, booleans and nil kept, a mixed-type or non-UTF-8 column a list whose atoms read back as strings, the same values reading back the same through either form
```

```test:table-arrow
validity bitmaps, int64 and float64 values, a text column's offsets and data, and a dictionary column's codes and dictionary equal fixtures written from the Arrow columnar format, byte for byte
```

```test:table-faithful
for generated columns of each type with gaps, new/1 and from/2 then rows/1 and column/2 read back values == to those given, categories as strings
```

```test:table-off-heap
a table of a million numbers costs its process the same number of words a chunk as one of a hundred thousand, never words a row, each chunk's column a reference-counted binary
```

```test:table-round-trip
for generated rows of numbers, floats, strings and times with gaps, rows to a table and back are the rows, and every column is the table's length
```

```test:table-slice
slice/3 is the rows from start, count of them, for generated tables, chunkings and bounds; row/2 is one row or nil; a slice shares its parent's chunks and their binaries
```

**Row lists are accepted at the edge.** `from/2` reads every shape data arrives in into a table:
- a list of row maps, a map or keyword list of equal-length columns, an `Nx.Tensor`, or anything implementing `Table.Reader` (Explorer's frames among them), through `rows/1`;
- columns are named by every key of every row, in term order, a row without the key missing there. Each row's keys are compared with the row's before it, and only a new shape's are added, so rows of one shape merge nothing;
- each column's type is the one `types:` gives, else the one `column_types/1` infers, else `:term`;
- a time column's values become `DateTime`s at the edge: a `Date` at midnight UTC, a `NaiveDateTime` as UTC, an ISO 8601 string parsed; a `DateTime` keeps its zone, and every value its precision. `new/1` takes `NaiveDateTime`s and `Date`s as themselves.

The `table` package and Nx are optional dependencies: without them lists and column maps still work, and a struct source or a tensor raises `UndefinedFunctionError` where it is read.

```test:table-edge-names
from/2 names the columns by every key of every row, rows of differing shapes included, without merging a row map
```

```test:table-edge
from/2 reads rows, columns and a Table.Reader source, infers or takes the types, turns ISO strings, dates and naive times into DateTimes in a time column, makes a mixed column a term column, passes a table through, and refuses a value its given type does not hold
```

**The row helpers read any source,** as visualize's `Visualize.Data.Table` does (this is its port):
- `rows/1` of a list of rows is the list itself, uncopied; of a map or keyword list of equal-length columns, one map per row; of a rank-2 tensor, one tuple per row, of a rank-1 tensor its values; of a `Table.Reader` source, its rows keyed as the reader names its columns. A map whose values are not equal-length lists, a tensor of another rank, and a struct with no reader are the caller's errors;
- `named/2` names a tensor's columns, or tuple rows' elements, in order, or says why it can't (`{:width, n, size}`, `{:rank, rank}`), and passes any other source through;
- `unnamed?/1` is whether a source's rows have no names to read by: a tensor, or tuple rows (never a keyword list of columns);
- `get/2` reads a column from a row by either spelling of its name, and `key/2` is the key that spells it; no atom is made. `accessor/1` is the function of a name, a function passed through;
- `column_types/1` suggests each column's type from its whole: all temporal is `:time`, all numbers `:number`, all strings `:text`, all color terms (literal or typed, §1.7) `:color`, all atoms or booleans `:category`, a mixed or empty column left out; a string is never a color, so a column of CSS text is `:text`; `time_columns/1` names the temporal ones; `temporal?/1` is whether a value is a `DateTime`, `Date`, `NaiveDateTime` or an ISO 8601 string one of those parses. These are suggestions for a tool; a table's declared types are `column_type/2`'s.

```test:table-sources
rows/1 passes a list of rows through uncopied and tuple rows unchanged, reads column maps, keyword columns, tensors and rank-1 tensor columns, refuses unequal columns, other ranks and a struct with no reader; named/2 names tensor columns and tuple rows or says why not; unnamed?/1 is true for a tensor and tuple rows, never columns
```

```test:table-row-helpers
get/2 reads a key by either spelling, the exact key first, a nil value being a value; accessor/1 wraps a name and passes a function; a tuple row has no names
```

```test:table-inference
column_types/1 types a column by its whole, a column of color terms :color and one of strings :text, and leaves a mixed or empty one out; time_columns/1 reads the whole column, nil a gap, names the union of every row's keys; temporal?/1 accepts the three structs and ISO 8601 strings only
```

#### 1.1.1 Chunks {#sources-table-chunks}

**A table is an ordered list of chunks** (macaw_data#9). A chunk is a run of rows of every column, each column packed by itself in §1.1's forms: Arrow's record batch, so one column across the chunks is Arrow's chunked array. A chunk is immutable. Its forms depend on its own values alone, so a column may be int64 in one chunk and float64 in the next, and a zoned or category column's dictionary is its chunk's.

- **A table views its chunks.** It holds each chunk with the run of that chunk's rows it reads, its first row and its count. `chunks/1` lists them, in order: every chunk the table references, and nothing else.
- **Canonical chunks.** `new/1` and `from/2` build them, and `compact/1` rewrites any table into them. Canonical chunks are aligned by row count, `chunk_rows/0` (8,192) rows each from the first row, the last shorter. A table with no rows has no chunks. The chunk size is not a setting: no caller chooses it.
- **Live windows cost the new data.** Nothing below copies a chunk's buffers:
  - **`append/2`** adds another table's chunks after the table's own. The two have the same names in the same order, each of the same type; another table is `{:error, {:columns, expected, given}}`, each a list of `{name, type}`.
  - **`trim/2`** drops the oldest rows: it drops every chunk wholly before the cut, and moves the first that remains to start at the cut. A dropped chunk is in no entry of `chunks/1`, so it is freed once nothing else references it.
  - **`slice/3`** keeps the chunks the run spans, cut at both ends. It pins only those chunks.
- **The packed buffers are read per chunk:** `column/2` reads each view's slice of its chunk's column, in order.

```test:table-chunks
new/1 builds canonical chunks of chunk_rows/0 rows from the first, the last shorter, and none for no rows; chunks/1 lists each chunk with its first row and count; a column is packed per chunk, int64 in one chunk and float64 in the next, a dictionary per chunk, and reads back whole
```

```test:table-append-trim
appending and trimming give the contents a fresh build of the same rows would have, for generated rows, chunkings and cuts; append copies no chunk and refuses a table of other names or types; trim drops every chunk wholly before the cut, and a dropped chunk is in no entry of chunks/1
```

#### 1.1.2 Identity is the contents {#sources-table-identity}

**A table's identity is its contents, not its layout** (macaw_data#9; an amendment to macaw#188 D5, recorded there): its names in order, each column's type, and each column's values in order as `column/2` reads them back. The same rows chunked two ways are one value.

- **`Table.t()` is opaque,** and `==` on the struct is not a table's equality: two equal tables may hold different chunks.
- **`equal?/2`** is whether two tables have the same contents. Values compare strictly, as the kernel's digest tells them apart, so `1` and `1.0` differ, and so do `0.0` and `-0.0`.
- **`digest/1`** is the table's content digest: 64 lowercase hex characters, a SHA-256 over the table's **canonical form**. It is over the values, never the buffers: a dictionary built again in another order, a column held in another form, and another chunking all keep it. Two tables are `equal?/2` exactly when their digests are equal.
- **The canonical form.** Each value has one canonical form whatever storage holds it: a tag byte naming its kind, an 8-byte little-endian word, and bytes of its own.

  | Value | Tag | Word | Own bytes |
  |---|---|---|---|
  | `nil` | 0 | 0 | none |
  | an integer within int64 | 1 | the integer | none |
  | a float | 2 | its binary64 bits | none |
  | an integer beyond int64 | 3 | 0 | its kernel encoding |
  | a binary | 4 | its byte size | its bytes |
  | any other term | 7 | 0 | its kernel encoding |
  | a UTC `DateTime` | 8 | microseconds since the Unix epoch | its precision, one byte |
  | a `NaiveDateTime` | 9 | wall-clock microseconds since 1970-01-01 | its precision, one byte |
  | a `Date` | 10 | days since 1970-01-01 | none |
  | a `DateTime` in another zone | 11 | UTC microseconds since the Unix epoch | its precision, one byte, then the kernel encoding of `{time_zone, zone_abbr, utc_offset, std_offset}` |

  A time of a calendar other than ISO is "any other term". A column's canonical form is three streams over its values in order: the tags, the words, and the own bytes. The digest is the SHA-256 of a version byte (1), the kernel's encoding (`Macaw.Layers.Document.digest/1`'s, its version byte aside) of `{"macaw.table", [{name, type}, …]}`, the row count as 64 bits big-endian, and then for each column in order the SHA-256 of each of its three streams. Each stream is hashed by itself, so where a chunk ends never reaches the digest. The packed forms lay their values out nearly so already (int64 and float64 values, UTC microseconds, a text column's bytes), so a chunk's digest costs about one pass over its buffers.
- **A table holds data.** A value that is not data (a function, a PID, a reference, a port, an improper list) has no digest, so `new/1` refuses it, `{[name, i], :not_data}`, whatever the column's type.
- **A chunk's digest** (`Table.Chunk.digest/1`) is its content digest as a one-chunk table of the table's names and types. It is computed once, when the chunk is built, and kept in the chunk. Reading it never hashes, and neither does slicing, trimming or appending.
- **`compact/1`** of two equal tables of one origin (§1.1.3) is the same struct (`==`), canonical chunks with the same digests. A table already canonical is returned as it is.
- **The kernel's digest of the struct is of its layout,** until the kernel lets a type supply its canonical digest input (macaw_layers#18), a table's being its digest. Until then a table's digest is `Table.digest/1`. The kernel's encoding it uses is a copy, held byte-for-byte equal to `Macaw.Layers.Document.digest/1`.

```test:table-equal
for generated rows, the same rows chunked two ways are equal? with one digest, compact/1 of each is ==, and changing one value changes both
```

```test:table-data
new/1 refuses a value that is not data, a function, a PID, a reference, a port or an improper list, by its path, as not_data, in any chunk; every other value of a term column is held
```

```test:table-digest
digest/1 is the SHA-256 of the canonical form, the same for every form of the same values, each value a chunk of its own or all in one; the kernel's encoding it uses is the kernel's, byte for byte; a chunk's digest is its own as a one-chunk table; a dictionary built again in another order keeps it; 1 and 1.0 and 0.0 and -0.0 differ; reading a chunk's digest, slicing, trimming and appending hash nothing, and new/1 hashes each chunk once
```

#### 1.1.3 Chunk identity {#sources-table-chunk-identity}

**Every chunk has a logical id: where it sits, which never changes** (macaw_data#9 §2). A cache scopes its entries by it and evicts them when the chunk leaves its window. Beside it a chunk has a **version**, `Chunk.version/1`: its content digest (§1.1.2), or a step output's derivation digest.

- **A table built from rows** (`new/1`, `from/2`) is not a source's. It has no change stream for a stable id to follow, so a chunk's logical id is its content digest, and the caller names nothing.
- **A source's table** is built by `new/2` with `origin: %{source, resolution, window, span, offset}`: the source's name, the resolution its relation is held at (`served.resolution`, §4.3), its window field (or `nil`), its chunk span (`Source.Description.chunk_span/2`, or `nil`), and where the rows given start among the source's rows (0 by default). A chunk's logical id is `{source, resolution, slot}`, and every row of a chunk lies in its slot:
  - **in event time,** when the origin has a window field and a span. The slot is the start of the span the rows lie in. Spans are laid from a fixed origin: the Unix epoch for a time (a `DateTime`'s UTC instant, a `NaiveDateTime`'s wall clock, a `Date` at midnight), 0 for a number. So a chunk is a window. Rows with no window value are the slot `nil`, after every other, as a push holds them (§4). The rows given are in the window field's order, `nil` last; others are `{[:origin, :window], {:unsorted, i}}`, at the first row out of order.
  - **by row count** otherwise. The slot is the position among the source's rows where the chunk's run of `chunk_rows/0` rows starts, a multiple of it. It is fixed when the chunk is built, so trimming the oldest rows never moves a later chunk's slot.
  - **Resolution is in the id.** A relation at one resolution is another relation than the same source's at another (§4.3), so their chunks never share an id, a delta or a cache entry.
  - **`append/2` keeps the alignment.** The rows that fall in the last chunk's slot are written into it, a chunk of the same id with new contents and a new digest; later rows start new chunks. Appended rows lie at or after the last row's window value, else `{:error, {:unsorted, i}}`: a late row is a change, `Table.apply/2`'s (§2.6). A table of another origin is `{:error, {:origin, expected, given}}`.
  - **`compact/1` keeps the slots,** rebuilding a source's table on them.
  - The origin is not part of a table's contents: `equal?/2` and `digest/1` ignore it.
- **The span never depends on data seen at runtime,** so logical ids hold across a rebuild and a restart. `Source.Description.chunk_span/2` of a description and a resolution is the description's `chunk_span` when it declares one (§2.1). Else it is derived from the resolution to target `chunk_rows/0` rows a chunk: `chunk_rows/0` times a resolution of *r* seconds (a number, or `:second`, `:minute`, `:hour` or `:day`) over a time window field, a `Duration`; `chunk_rows/0` times *r*, in the field's units, over a number window field. A resolution it can't read (`nil`, another name, a name over a number field) and a source with no time or number window field have no span, and their chunks are aligned by row count.
- **A step's output chunk** (macaw_data#9 §5) is built without hashing its contents, and `from_chunks/3` is a table of such chunks, each read whole or as a view `{chunk, first, count}` of a run of it, as a per-row step passes an input's chunk through or cuts it (spec/04 §1.4):
  - `Chunk.derive/3`, a per-row step's from the values it computed, and `Chunk.gather/5`, a per-row step's of the rows at given indexes of an input's view, every column's slots copied from its storage and nothing decoded: its logical id is `{input's logical id, step key}`, so caching continues along a chain of steps;
  - `Chunk.combine/3`, a global step's (a sort, a merge of several chunks): its logical id is `{:combined, digest}`, the kernel's digest of `{step key, [{logical id, version}, …]}` over its inputs, so a step after it still caches.
  - The **step key** is the step's name, its checked options and the context it reads as that context resolves for the chunk (spec/04). Keying on raw context would miss on every frame.
- **The derivation digest** is a step output's version: the kernel's digest of `{[version, …], step key}` over its inputs, never of its contents. It is valid because steps are pure and deterministic for their inputs and key. It is a **cache key only:** two derivations of equal results get different keys, which costs a miss and never gives a stale hit. A step output's content digest (`Chunk.digest/1`) is `nil` until it is persisted or compared: `compact/1` gives it one, and `equal?/2` and `digest/1` read its contents.

- **A table may know the column its rows are sorted by** (`sorted/1`): in ascending order, `nil` last, as a window field is held (§1.5). A source's table in event time is sorted by its window field; a table built from rows is sorted by none; `from_chunks/3` takes `sorted:`, as a per-row step keeps its input's. A step binary-searches only that column (spec/04 §4.3). Reading a step's columns, `Chunk.values/4` is one column of a run of a chunk, and `Chunk.at/3` one value, as read through the chunk's delta.

```test:table-sorted
a source's table in event time is sorted by its window field, a table built from rows or aligned by row count by none, and from_chunks/3 keeps the sorted column given; it is not part of the contents
```

```test:table-chunk-ids
a table built from rows has its chunks' content digests as their ids; a source's chunks are {source, resolution, slot}, by span start in event time and by row offset otherwise, equal across a rebuild and to ids written out literally; trimming keeps every remaining chunk's id; appending writes into the last chunk's slot and starts new ones; rows out of window order, and an append of another origin, are refused
```

```test:table-resolution-ids
the same rows of one source held at two resolutions share no chunk id
```

```test:table-span
chunk_span/2 is the declared chunk_span, else chunk_rows times the resolution, a Duration over a time window field and a number over a number one, and nil for a resolution it can't read or no window field; a description refuses a chunk span of the wrong kind; tables of different rows at one span have their boundaries at the same span starts
```

```test:table-derivation
a per-row step's output chunk has the id {input id, step key}, and a global step's the digest of its key over its inputs' ids and versions; a derivation digest is the same across runs, and changes with an input's version or the key; a chain of steps hashes no output's contents, and compact/1 gives a step's output a content digest
```

#### 1.1.4 Settled chunks, open chunks and the delta {#sources-table-delta}

**A source's changes reach its table through `Table.apply/2`** (macaw_data#9 §3), the one seam between the changelog (§4) and the storage (§2.6). It is the continuous-aggregate model: what is settled is read through cached results, what is open is worked live, and `complete_until` (§4.4) is the line between them.

- **Settled and open.** A chunk is **settled** when its span lies wholly before the source's `complete_until`: its slot's end is at or before it. One at or after it is **open**, its results provisional. Settled means settled, not final: a change is still accepted. A chunk of rows with no window value, and every chunk of a table aligned by row count, is open: only a window is ever settled.
- **`Table.apply(table, change)`** applies one increment's changes, already judged for lateness, overlaps and conflicts (§4.2, §4.4), and answers `{table, faults, unheld}`. `change` is `%{insert, retract, replace, schema, settled, thinned}`: the rows inserted, the rows retracted, the range replacements (§4.2's `%{from, to, identities, rows}`), the source's schema (its identity and window field), the `complete_until` in force, and whether the holding is thinned. In §4.2's order:
  1. **Row retractions** are matched as §4.2 matches them, in the chunk of the slot the row's window value lies in, so a retraction reads one chunk. A retraction that is not held, held only at another window value, or that can't tell rows apart is §4.2's fault in `faults`, or counted in `unheld` against a thinned holding.
  2. **Range retractions:** everything held in each replaced range, limited to its identities.
  3. **Insertions:** each row goes to the chunk of its slot, kept in the window field's order. Rows of a slot that has no chunk start one, placed among the chunks in slot order.
- **Where each change lands:**
  - **in an open chunk,** directly: the chunk is written again with its new contents, the same id and a new digest;
  - **in a settled chunk, in its delta,** the chunk's base untouched: a retracted row in its **deleted set**, a range in its **predicate deletes** (the range intersected with the identities named, as Iceberg's equality deletes are), an inserted row in its **side chunk**. A predicate delete reads nothing, so it needs no fetch of a cold chunk;
  - **a chunk wholly inside an unrestricted replacement** (every identity, its whole span) is replaced outright: its slot holds exactly the replacement's rows, a new chunk with no delta;
  - **in a table with no window field, or aligned by row count,** directly: a retraction or replacement writes the chunks it changes again, and insertions are appended to the last chunk, filling its slot before starting new ones. With a window field the rows stay in its order: a row before the last row held is placed in the first chunk whose last row comes after it, which is written again.
- **Read through the delta.** A settled chunk reads as its base without its deleted rows and the rows its predicates match, merged with its side chunk in the window field's order, base rows first among equal values and rows with no window value last. So the window field stays sorted and a binary search over it stays valid. A chunk's size and content digest are of the chunk as read, computed when its delta changes: a chunk's state is its base and its delta, both immutable, so a reader holding a table is never affected by a later change or compaction.
- **The read view is built once per state.** When a chunk's state is made (its delta changes, or a cold chunk is warmed), the chunk as read is packed once, its digest computed from it, and kept with the state beside its base and delta, with where each row read comes from (a base row or a side row). Every read of the state (`Chunk.values/4`, `Chunk.at/3`, a gather, a digest, a binary search's probes) reads that view, so no read applies the delta again. The base and the delta are kept: the base is what a cold tier holds, and with the delta it is what an inverse update reads (spec/04 §1.5). **`Chunk.base_version/1`** is the base's content digest, the version a cache held the base's parts under: the chunk's version when it has no delta, and kept across every change to its delta until compaction makes the read view the new base.
- **Cold chunks.** A chunk's base may be held elsewhere (`Table.Chunk.cold/5`: its header, id, digest and size, and a function that fetches its base); the tier that holds chunks is its own proposal. A change that needs no read leaves a cold chunk unfetched: a predicate delete, or an insertion. Such a chunk's digest is then **pending** (`Chunk.digest/1` is `:pending`), and so is its size under a predicate delete. A pending digest is no chunk's version (`Chunk.version/1` is `nil`), so it never matches a cache key. `Table.warm/1` fetches each pending chunk once and computes its size and digest; every read of a table holding one warms it first.
- **Lazy compaction.** When a settled chunk's delta (its deleted rows, predicates and side rows) reaches a quarter of its base's rows, `Table.apply/2` rewrites the chunk as read into a new base with no delta. The ratio is fixed, not a setting. Compaction changes only the layout: the contents are equal, so it keeps the chunk's id, its content digest and every result cached under them, and it emits nothing.

```test:table-settled
a chunk whose span ends at or before complete_until is settled and one at or after it open; with no complete_until, a chunk of rows with no window value and a table aligned by row count, every chunk is open
```

```test:table-apply
apply/2 writes an open chunk's new contents and a settled chunk's delta, leaving its base; an insertion into a slot with no chunk starts one in slot order; a chunk wholly inside an unrestricted replacement is replaced outright; a table with no window field takes changes directly and appends insertions to its last chunk; retraction faults and unheld counts are §4.2's
```

```test:table-delta
for generated tables and changes to settled chunks, over about 40 seeds, reads through the delta equal the relation built directly from the rows, before and after compaction; the window field stays sorted; compaction keeps each chunk's id, digest and version
```

```test:table-predicate
a replacement over a settled chunk is a predicate delete that reads as its row form, and needs no fetch of a cold chunk
```

```test:table-cold
a cold chunk under a predicate delete has a pending digest and size and no version, so it matches no cache key; warm/1 fetches it once and computes its digest, the one the same contents built warm have
```

```test:table-read-view
a chunk with a delta is read through its state's view, built once: reading its values, a value at a row and a gather, and a window step's binary search over it, apply the delta no more; its base version is its digest before the delta, kept across later changes to the delta, and its digest after compaction
```

```test:table-compaction
compaction happens when a delta reaches a quarter of its base, keeps the id, the digest and the version, and leaves the contents equal; applying a change sends no message
```

#### 1.1.5 Reading a column {#sources-table-read}

**Reading costs the slots, not the bits** (macaw_data#41). A column none of whose values is missing is read without expanding its validity bitmap (§1.1): the bitmap's bytes are checked once, then its values buffer is decoded as it lies. A slice's bitmap is cut as one little-endian integer, shifted down to its first bit and masked, never a bit at a time. A gather takes a bitmap whose bits are all set as all set, reading none of them, and a step's run of a chunk (`Table.Chunk.gather/5`, `reshape/7`) is gathered from the chunk's own storage at the run's offset, never sliced first. Each reads back exactly what reading bit by bit does, so no result and no digest changes.

```test:table-read-cost
for generated columns of every packed form, with gaps and without, a column's values, slices and gathers read back as reading bit by bit does, and a run of a chunk gathers as its slice does; an all-valid float column reads at most two reductions a row and a constant, expanding no bitmap
```

### 1.2 The schema {#sources-schema}

**`Macaw.Data.Schema` is a source's schema:** what each of its fields means, whoever draws it, and never how it is drawn. It is `%Macaw.Data.Schema{fields, version, identity}`:
- `fields` maps a field name to its **description**, a map of the keys below. `new/1` takes a name as an atom or a string, as the source's rows spell it, and the struct holds it as its string, as it holds every state and role (§1.10);
- `version` is the schema's version (§1.10);
- `identity` is the declared identity fields of `identity/1` (§1.4), derived by `new/1` so a row's identity is read without walking the fields again; a struct assembled by hand may leave it `nil`, and `identity/1` derives it then.

`Macaw.Data.Schema.new/1` is the only constructor. It takes the map of descriptions, checks it, and returns `{:ok, schema}` or `{:error, faults}` with every fault found, each `{path, reason}` from the schema to the value (`[:latency, :unit]`), ordered by path (§1.8). `new!/1` returns the schema or raises `ArgumentError` with every fault formatted by `format_error/1`. It is ported from visualize's `Visualize.Data.Schema` (its spec/08 §10.1).

| Key | Value | For a field of type | Meaning |
|---|---|---|---|
| `type` | `:time`, `:number`, `:category`, `:text`, `:color` or `:point` | required, every field | what the column is. A `:time` field holds **instants** (`DateTime`, `NaiveDateTime` or `Date` values, or ISO 8601 strings), never numbers: a count of ticks or a sequence number is `:number`. A `:color` field holds data colors, color terms, one per row (§1.7). A `:point` field holds **geographic positions**, `{longitude, latitude}` |
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
- **The keys.** `value` is required and is a value as a bare one is: a string, an atom other than `nil`, `true` and `false`, or a number. `name`, optional, is a string, the value's display name. `color`, optional, is a data color, a color term (§1.7). No other key is an entry's.
- **Distinct by value.** The entries' values, bare and map alike, are distinct: `["ok", %{value: "ok", name: "OK"}]` lists `"ok"` twice, `:duplicate` at the later one's index.
- **An entry that says nothing is its value.** `new/1` keeps `%{value: v}` with neither a `name` nor a `color` as the bare `v`, so the two spellings are one schema of one version.
- **Reading them.** `values/2` is the field's bare values in their declared order, `nil` when the field declares none (an open set). `value_names/2` maps each value with a `name` to its name, and `value_colors/2` each value with a `color` to its color, the term the schema holds; each is `%{}` when none has one. `fetch/3` of `:values` answers the list as declared, entries included.
- **Checked against `order` and `status`.** With `values`, every state `order` lists and `status` names is one of them, compared with the bare values; with `order`, every state `status` names is one of `order`'s.

```test:schema-values
values may be entries with a name and a color, read back by values/2, value_names/2 and value_colors/2 by either spelling; an entry with only its value is that value, one version; every fault of an entry by path; order and status are checked against the bare values
```

### 1.4 Identity {#sources-schema-identity}

Which rows are about the same thing is a fact about the source, so the source declares it: `identity: true` on each field whose value names the entity a row is about. Nothing guesses it.
- **The fields.** `identity` is allowed on a `:category`, `:text` or `:number` field, and never on a `:time` field, which says when, not what, nor on a `:color` or `:point` one (`{:invalid_for, type}`). It is a boolean, and `false` is the same as absent: `new/1` drops `identity: false`, so the two spellings are one schema of one version.
- **Composite.** Several fields may say `true`, together one identity. `identity/1` is the declared fields, as strings in order, `[]` for none.
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

**`status`'s roles** are a theme's words (`:good`, `:warning`, `:bad`, `:info`, `:neutral`), carried by their spelling and not checked against a list, so a role a theme adds needs no change here. A role is a word, never a color (§1.7). **`continuity`** is carried for the components that draw a source; gaps follow it.

```test:schema-measure
a misspelled unit, a symbol a person types, an unknown quantity and a unit that does not measure its quantity are refused where described; a pair is checked once each is good; every quantity in its base unit and every Telemetry unit pass; any role word is carried
```

### 1.7 Colors: data, never drawing {#sources-schema-colors}
A description says what a field means, and the theme chooses the color of a meaning ([macaw_layers 04 §3](https://github.com/dcoai/macaw_layers/blob/main/spec/04-themes.md#themes-rules)). A row or a value entry may still carry a color as data, a team's color or a verdict's shade, and that color is a **color term**, checked as a term:
- **A description never names a color.** A key `color`, `colour`, `colors`, `colours`, `palette`, `fill` or `stroke` in a description is `{:color_key, key}`, whose line names the keys that carry the meaning instead (`status`, `order`, `polarity`, `quantity`). <!-- spelling: allow -->
- **A data color is a color term** (`color?/1`):
  - a **literal**, `%Macaw.Layers.Color{}` (`Macaw.Layers.Color.literal?/1`): the color itself is the datum, drawn as itself and not re-themed;
  - or a **theme-relative typed color**, a theme's name or a transform of one (`{:color, "good"}`, `{:alpha, {:color, "bad"}, 0.74}`, `{:ramp, "status", 0.5}`, [macaw_layers 04 §1.3](https://github.com/dcoai/macaw_layers/blob/main/spec/04-themes.md#themes-color-typed)), whose literal operands are colors (`Macaw.Layers.Color.value?/1`) and whose names are in a theme's name grammar (`Macaw.Layers.Color.name?/1`). The page's one theme resolves it, so a theme change re-colors it.

  The term says which; there is no flag.
- **A string is never a color.** CSS text (`#hex`, a CSS name, `rgb()`, `hsl()`) is a representation of a color: a program reads it at its input edge with `Macaw.Layers.Color.parse!/1`, or writes `~RGB"#2e7d32"` in its source. A string, a bare role and any other term where a data color belongs is `{:type, :color}`, whose line names those two.
- **Where data colors are checked:** a value entry's `color` (`new/1`), a `:color` field's row values (a derived source's output, [02 §1.2](02-derived.md#derived-conform)), a `:color` parameter (`Macaw.Data.Parameter.conforms?/2`, §2.2). `Macaw.Data.Table.column_types/1` infers `:color` for a column whose every value is a color term; a column of strings is `:text`.
- **`new/1` holds a typed color's names as their strings,** as `Macaw.Layers.Color.color/1` writes them, so `{:color, :good}` and `{:color, "good"}` are one color, one schema of one version (§1.10).
- **A status role is a word, never a color:** a role is an atom (other than `nil`, `true`, `false`) or a non-empty string, else `{:type, :status}`; a typed color or a literal in a `status` is no role. Since a string is never a color, a role spelled like a CSS name (`:orange`, `"red"`) is a role like any other.
- **A `:color` field takes only `label` and `continuity`;** any other key is `{:invalid_for, :color}`.

How a data color may be shown is the theme's **data-color guard**: only with a non-color cue, and under a contrast guard (`Macaw.Layers.Theme.data_color/2`, [macaw_layers 04 §4](https://github.com/dcoai/macaw_layers/blob/main/spec/04-themes.md#themes-profile)).

The principle came first: a schema has described meaning and never drawing since it was specified, and a data color has always been content. When the schema was ported from visualize (macaw#104), macaw_data had no color library to call, so data colors were checked as CSS text, with an inlined list of CSS names; once macaw_layers held the colors as terms (macaw_layers 0.3.0, macaw#188), the check became the term's (macaw#187).

```test:schema-data-colors
a data color is a color term: a literal and a typed color, its names in the theme's grammar, are; a string in any CSS form, a bare role, a malformed typed color, an atom and a number are not, in color?/1, in a value entry and in a :color parameter; an atom name and its string are one color, one version; the fault names Color.parse!/1 and ~RGB
```

```test:schema-color-keys
every color key on a field is refused and says why; a color hides in a status neither as a typed color nor as a literal, while any word is a role, one spelled like a CSS name included, and a role read from JSON is a role
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
| `{:type, expected}` | `[name, key]` or `[name, :values, i, key]` | a value of the wrong shape, `expected` one of `:unit`, `:name`, `:string`, `:order`, `:status`, `:number`, `:positive`, `:boolean`, `:bounds`, `:values`, `:state`, `:color` (no color term, a string included, §1.7) |
| `:required` | `[name, :values, i, :value]` | a value entry with no `value` |
| `:unknown_entry_key` | `[name, :values, i, key]` | a key of a value entry other than its three |
| `{:duplicate_window, other}` | `[name, :window]` | a second window field |
| `:duplicate` | `[name, :order, i]`, `[name, :values, i]`, `[name, :status, state]` | a state listed twice, or named in `status` as an atom and as its string (at the string), by its spelling (§1.10) |
| `:not_in_order`, `:not_in_values` | `[name, :status, state]`, `[name, :order, i]` | a state the order, or the values, do not list |

```test:schema-faults
the field names and the shape of a schema are checked, every fault is reported by path, new!/1 raises with every fault formatted, and every fault formats as a line
```

### 1.9 Compatibility {#sources-schema-compatibility}

Two schemas can describe the same data in different words: a live feed and a store's history of one metric spell their fields differently (`:t` and `"t"`), label them from different sources, and know different facts. `compatibility(schema, other)` says whether `other`'s rows read as `schema`'s: `:ok`, or `{:error, faults}` with every fault, each `{field, reason}`, the field by its string, ordered by it. The rule is per field of `schema`; `other`'s extra fields are not faults:

| Reason | Meaning |
|---|---|
| `:missing` | `other` has no field of that name, compared as strings |
| `{:type, a, b}` | `other`'s field is of type `b` where `schema`'s is `a` |
| `{:unit, a, b}` | a `:number` field whose units do not convert, `other`'s `b` to `schema`'s `a` by `Macaw.Data.Unit.conversion/2`, or one absent facing a present one; two absent agree |
| `{:identity, a, b}` | the two declare different identity fields, `a` and `b` whether each declares `identity: true` on it. Checked for every field either declares, so an identity field only `other` has is a fault, by its string: reading `other`'s rows as `schema`'s would merge what `other` tells apart |

No other attribute is compared: a label, an implied quantity, `polarity`, `bounds` or `order` is what each source knows, and reading `other`'s rows keeps `schema`'s.

```test:schema-compatibility
names compare as strings and labels, facts and extra fields are not compared; every fault by the field's string, by name; units convert or fault, two absent agreeing; different identity fields fault whichever schema declares them
```

### 1.10 The version {#sources-schema-version}

A schema's version is **the kernel's digest of the schema's term** (`Macaw.Layers.Document.digest/1` over `%{"fields" => fields}`, the struct's normalized fields, [macaw_layers 01 §7](https://github.com/dcoai/macaw_layers/blob/main/spec/01-kernel.md#kernel-digest)): 64 lowercase hex characters, the SHA-256 of the kernel's canonical, type-tagged encoding of that term (macaw_layers 0.3.0). So an unchanged schema has the same version on every node and under every release, and any change of content, a renamed state or a new label, is a new version. `version/1` returns it, computed once by `new/1`. **The version is never computed from a representation:** the JSON form (§1.11) is an adapter at the edge, and a value it can't write fails there, naming it, never in `new/1`.

- **Names, states and roles count by their spelling,** because `new/1` normalizes them once, at construction: every field name, every state in `values`, `order` and `status`, and every role in `status`, is held as its string, as is every name in a value entry's typed color (§1.7). So `:latency` and `"latency"` are one field, and `:ok` and `"ok"` one state, one schema `==` the other, of one version. Two spellings of one state in one description are that state twice (`:duplicate`), as two of one field are (§1.8). The words of the vocabulary (`type`, `quantity`, `polarity`, `metric_kind`) stay atoms: they are words, not names. Every function that takes a name takes either spelling. A delivery read on another node then names a version its reader can resolve (§1.12). This differs from visualize's own hash, which keeps an atom state apart from its string; reconciling the two is visualize's, at adoption.
- **Nothing depends on map order:** the kernel's encoding of a map is canonical, its keys in one order however it was built.
- The test suite pins one schema's version as a literal, so a change to the encoding fails a test before it changes a version in the field.

```test:schema-version
the version is pinned for two schemas, is the kernel's digest of the schema's term and not of its JSON form, is the same whichever way a name, a state or a role is spelled, the two schemas equal, does not depend on the order the maps were built in, and changes with any change of content; a state in both spellings is listed twice; a typed color in a value entry never crashes new/1
```

### 1.11 The JSON form {#sources-schema-json}

**`to_json/1` and `from_json/2` are public,** so no adopter reads a hidden function (visualize#879). **It is an adapter at the edge:** the schema's identity, equality and validity are its term's, and the version never goes through it (§1.10). The map form, `to_map/1`, is a list of `[name, description]` pairs sorted by name: every description key by its string, every name, state and role as the string the schema holds, every word of the vocabulary (`type`, `quantity`, `polarity`, `metric_kind`) as its string, `status` as sorted `[state, role]` pairs, `bounds`, `values` and booleans as they are, and a value entry's `color` in macaw_layers' color form (`Macaw.Layers.Color.Form`, [macaw_layers 04 §1.6](https://github.com/dcoai/macaw_layers/blob/main/spec/04-themes.md#themes-color-adapters)): a literal as `{"$rgb": "#2e7d32"}` (or its four fields when it is not 8-bit exact), a typed color by its tags, `{"$color": "good"}`, `{"$alpha": [{"$color": "bad"}, 0.74]}`. `to_json/1` is it encoded.

**Reading** (`from_map/1`, `from_json/2`):
- `from_json/2` reads through the kernel's gates first, the byte limit and the scan that stops at a depth or items limit ([macaw_layers 01 §5](https://github.com/dcoai/macaw_layers/blob/main/spec/01-kernel.md#kernel-gates)), `limits:` tightening them, and then decodes;
- each word is read through its own closed vocabulary, every name, state and role is a string, and an entry's `color` is read inside out by the colors' own reader (`Macaw.Layers.Color.Form.decode_value/2`): **no atom is made from a document**;
- a color the reader does not read, a bare string among them, stays as written, for `new/1` to refuse as `{:type, :color}`: JSON text is no more a color than any other string;
- a key no description or entry has stays its string, and a word outside its vocabulary stays its string, for `new/1` to refuse by name;
- anything but a list of `[string, map]` pairs is `{[], {:type, :schema}}`.

A schema read back from its JSON form has the same version and the same JSON form, a literal or a typed color in an entry included; one spelled with strings, as JSON spells it, reads back exactly.

```test:schema-json-form
to_map/1 is the sorted pairs with every name, state, role and word by its spelling, status as sorted pairs, bounds and values as they are, and to_json/1 is it encoded
```

```test:schema-json-read
from_json/2 reads words through their vocabularies, names and states as strings and an entry's color by the colors' reader, makes no atom, refuses a color as text, refuses an unknown word or key by new/1, refuses a non-schema and malformed JSON, and applies the byte and depth limits
```

```test:schema-json-round-trip
for generated schemas, value entries with literal and typed colors among them, the schema read back from its JSON has its version and its JSON, and a string-spelled one reads back exactly
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

- **`describe/2`** takes the host's configuration for the source as its `context`, **never a viewer**: what a source is doesn't depend on who asks. So it is answered at boot and cached until the source's schema version changes (§1.12), and validation reads it without I/O ([macaw_compose 07](https://github.com/dcoai/macaw/blob/main/spec/07-documents.md#documents-validation-time)).
- **The dispatch functions** (`Source.describe/2`, `fetch/3`, `subscribe/2`, `unsubscribe/2`) call a source's module. An answer of the wrong shape is a value too: `{:error, {:bad_describe, answer}}` or `{:error, {:bad_fetch, answer}}`.
- **`fetch/3` checks the request against the description first** (§2.2): a request with an unknown, missing or illegal parameter is `{:error, {:params, faults}}`, and the source is never called. The source receives every parameter, defaults filled in.
- **`subscribe/2` on a source that does not push** is `{:error, :no_push}`, and `unsubscribe/2` on one is `:ok`.
- **`describer/1`** turns a map of named sources, each with its context, into the describe function `Schema.Cache.resolve/4` takes; a name not in the map is `{:error, :no_source}`.
- **Errors are values.** A source never raises. (visualize.md C1; metresis.md C1.)
- **The viewer is an argument, not a setting.** A source may refuse, filter or tease by it. Macaw never writes a viewer to a document, delivery or record. (dcotek_web.md C11; visualize.md C11.)
- **Preferences are state, not part of the viewer.** A viewer's display preferences (`theme`, `zone`, `units`) are state sources ([macaw_compose 03](https://github.com/dcoai/macaw/blob/main/spec/03-state.md#state-sources)), persisted like any other state and passed to components in their context. The viewer carries identity and access only.

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

`%Macaw.Data.Source.Description{schema, params, supports, viewer_independent, lateness, idle_after, chunk_span}`, built by `new/1`, which reports every fault at once by path:
- **`schema`**, required, a `Macaw.Data.Schema` (§1.2).
- **`params`**: the parameters the source takes, by name, each a parameter (§2.2); `%{}` by default. A name is a non-empty string.
- **`supports`**: the capabilities it honors, distinct, among `:window`, `:box`, `:region`, `:latest`, `:budget`, `:push` and `:as_of`; `[]` by default. **Every capability is optional:** Macaw finishes a window, box, region, latest or budget the source did not honor, and reports it (§2.4). (visualize.md C1, D-140.)
- **`viewer_independent`**: `true` declares that the source answers every viewer the same. It only allows pooling across viewers (§6), which fetches with the anonymous viewer, so a wrong declaration shows everyone the anonymous answer and never one person's rows to another. The conformance kit checks it by asking two viewers. `false` by default.
- **`lateness`**: a hard bound on how late a change may be, for a source that refuses changes past some age (§4.4); `nil` by default, accepting a change of any age.
- **`idle_after`**: milliseconds the source may deliver nothing before a derived source's watermark leaves it out ([02 §8.6](02-derived.md#derived-engine-watermarks)), a positive integer; `nil` by default, never idle.
- **`chunk_span`**: the span of the window field a chunk of the source's table holds (§1.1.3), declared because the source knows its rate: a positive `Duration` of fixed length (no years or months) over a `:time` window field, a positive number in the field's units over a `:number` one. `nil` by default, derived from the resolution (`chunk_span/2`). Another value is `{[:chunk_span], {:type, :duration}}` or `{[:chunk_span], {:type, :number}}`, and one with no window field `{[:chunk_span], :no_window_field}`. Set wrong, chunks are too small or too large, which costs only speed.

There is no other key: the earlier `reveals`, a declaration of what a result tells about the viewer for a page's privacy note, was removed (the owner's decision, 2026-10-27): a page notice of what it shows had no use case, and viewer dependence is what `viewer_independent` and the kit already check.

- **Window-less sources are allowed** (thresholds, projects, fragments). (metresis.md C1; dcotek_web.md C1.)

```test:contract-description
a description defaults its parameters, capabilities and independence, and refuses a bad name, a bad parameter, a non-list of capabilities, a non-boolean independence, an unknown key such as reveals, and a missing schema
```

### 2.2 Parameters {#sources-parameters}

**A parameter is the one shape for every typed option,** a source's or a component's: `Macaw.Data.Parameter`. macaw_data owns it (the owner's decision, 2026-10-27), since sources take parameters before any component exists; macaw_compose's components use the same shape ([macaw_compose 05 §1.1](https://github.com/dcoai/macaw/blob/main/spec/05-components.md#components-parameters)).

```elixir
%{type: type,                           # required
  default: value,                       # absent: the parameter is required
  values: [value] | nil,                # a closed list of legal values
  legal_for: {slot, field, fact} | nil, # legal values follow from a bound slot's schema
  bindable: false,                      # may it be bound to state? closed by default
  doc: "…"}
```

- **Types:** a data-model type (`:time`, `:number`, `:category`, `:text`, `:color`, `:point`), `{:document, type}` for a nested document of a document type, or `:term`, a value its owner validates, only for options migrated from untyped forms. `conforms?/2` says whether a value is of a type: a `DateTime`, a number, a string or non-boolean atom or number, a string, a data color (a color term, never a string, §1.7), a `{longitude, latitude}` in range, a map, or anything for `:term`; `nil` is a value only of `:term`.
- **`check/1`** reports every fault of a declaration, by path: the type required and known; the default and each of the values of the type; the default among the values when both are given; `legal_for` a `{slot, field, fact}`; `bindable` a boolean; `doc` a string; no other key. `keys/0` is the six keys.
- **`validate/2`** checks given values against a map of parameters by name, every fault at once: a name no parameter has is `:unknown_param`, a missing parameter with no default `:required`, a value not of its type `{:type, type}`, one outside its values `{:enum, values}`. It answers the values with every missing parameter's default filled in.
- **Legal values may come from the type.** metresis's aggregation is a category whose values are `legal(metric)`, so no consumer can ask for an aggregation the type forbids; `legal_for` names where such values come from, which the runtime that binds slots resolves. (metresis.md C1.)

```test:params-shape
a declaration of every type, and one with every key, passes; every fault of a bad one is reported at once by path; no type, an unknown type, a non-map and empty values are refused
```

```test:params-types
values conform to their types and to nothing else: times, numbers, categories, text, data colors (color terms, never a string), points in range, documents and terms; nil only to a term
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
| `subscription` | the reference of the push subscription this fetch is a snapshot for, whose position the answer states in `served.position` (§4.1); any other value is `{:type, :reference}` | `nil` |
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
5. **`:budget`**: the rows reduced to the budget, `reduced_by: :runtime`. Each series (the rows sharing every `:category` field's value) is reduced field by field against the window field, or the row's place without one, by the registered reducer `reduce:` names, by spelling ([04 §7](04-operations.md#operations-reducers)): Largest-Triangle-Three-Buckets (`"lttb"`, the default) or M4 (`"m4"`) in `macaw_data`'s own package, over `Macaw.Data.Reduce`, or any transform an enabled package registers that declares `reduces/0` (`operations:`, the registry, `macaw_data`'s own by default); a name that is no registered reducer raises `ArgumentError` naming it. Then the union of the kept rows returned whole, in their order. When many series leave the union over the budget, an even stride over it keeps the first and the last: **never more than the budget**. A delivery within the budget, and a schema with no `:number` field to reduce by, come back as they are.

A step the source honored is not done again. **Finishing only removes rows,** so it never widens the window and never adds a row, and it **keeps the rows' form** (macaw#185): a table stays a table of the same columns and types, and any other source becomes the rows it kept, read by name (`Delivery.named_rows/1`), never packed; a delivery no step acts on comes back as it is. A request the schema cannot answer (`Macaw.Data.Window.check/2`) raises `ArgumentError`: a window not of the window field's type or with no window field, a box with no `:point` window field, a region field not described, not `:time` or `:number`, mixed or inverted, or `latest` with no declared identity or no `:time` or `:number` window field to order by; the request is the caller's. `Macaw.Data.Window` holds the comparisons, trims and positions it uses, ported from visualize's `Visualize.Feed.Window`, and **what a source steps its window by** (macaw#185): `before/4`, the rows in `[from, upper)` (the seam of a combination, an open bound open); `region/2`, the region a window asks of a schema (a range `[from, to]` the window field's region where it applies, else `nil`, the source's own span; a region as it is); `range/2`, a field's range of a window or a region, by either spelling; and `check/2` of the axes alone, a map of `window`, `box`, `region` and `latest`, as well as of a request, any other key `{[key], :unknown_key}`. visualize's box `%{ranges, latest}` (its D-168) is a request's `region` and `latest` here.

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
latest keeps each identity's latest row by the window field, dropping a row with no identity; an honored latest is not redone; it needs a declared identity and a time or number window field, a point one refused
```

```test:finish-budget
a budget the source did not honor is reduced, the ends kept, recorded runtime; an honored or unneeded budget is not; series share it; m4 reduces too
```

```test:finish-keeps-form
a row list finished by a window stays a list of the same rows, integers and naive times untouched; tuple rows with names come back named; with nothing to do, tuple rows come back as they are; a step that must read tuple rows without names raises; a table stays a table
```

```test:finish-only-removes
for generated rows, windows and budgets, finishing keeps only rows of the input, all within the window, and at most the budget
```

```test:window-feed-steps
before/4 keeps [from, upper), an open bound open, a row with no time out; region/2 is the window field's region where the range applies, nil where it doesn't or there is no window field, a region as it is; range/2 reads a region's entry by either spelling and a range as itself; check/2 of the axes alone answers as of a request and names an unknown key
```

```test:window-arithmetic
times compare by kind; intersections, positions, the newer seam, applies and the instant and time predicates; nothing but a position is in a box
```

### 2.5 The model: a relation that varies over time {#sources-model}

**A source is a relation that varies over time.** Each value of it is a **Z-set**: rows, each with an integer weight, so a row held twice has weight 2 and identical rows are never one row (Budiu et al., DBSP, VLDB 2023; Flink's changelog row kinds). Every mechanism of this contract is a view of that one relation (Akidau et al., *Streaming Systems*, 2018, the stream/table duality):
- **A delivery is a snapshot** (§3): the relation at what its `served` describes, a row of weight *n* delivered *n* times.
- **A push is the changelog** (§4): each increment a Z-set of changes. An inserted row is +1, a retracted row −1, and an update is a retraction plus an insertion. A **range replacement** is a change too: everything held in a range retracted, the rows given inserted (§4.2).
- **A full snapshot is the limit case of a range replacement:** the whole range, every identity. So a snapshot delivery (`fetch/2`) and a replacement are one idea, and a snapshot handed to a subscription replaces what it holds (§4.1).
- **`Push.held/1` is the integral:** the sum of the changes so far, from the snapshot the subscription handed off from.
- **`:as_of` reads the relation at a past time** (§2.3).
- **A derived source maps relations to relations** ([02](02-derived.md#derived-model)): its function reads its inputs' relations and answers one, recomputed whole when an input changes ([02 §8.2](02-derived.md#derived-engine-pulse)).
- **What is settled is the source's claim, about time, not rows** (§4.4): `complete_until` says below which value of the window field the source expects no further change. Everything after it is provisional; a change before it is still a change.

So late rows, corrections, range replacements and caching are one story, not mechanisms settled case by case: a change of any age is a change to the relation, applied in the changelog's order, and what is settled is what the source says is.

```test:model-integral
the held relation is the integral of the changelog: for a generated changelog of insertions, retractions, moved rows, range replacements and duplicate rows, under any split into increments, any coalescing between drains and any repetition, the held rows equal the relation built directly, a resolution change and its refetch included
```

### 2.6 Where the relation is held {#sources-model-storage}

**`Push.held/1` holds a chunked `Macaw.Data.Table`** (macaw_data#9, §1.1.1–§1.1.4), and an increment is applied to it by `Table.apply/2`, the one seam between this contract and the table's storage. `held/1` is a `Macaw.Data.Delivery`, so what was served (the window, the resolution, `complete_until`, `capped`) stays beside the rows. Its rows are the table, with the source's origin: the subscription's name as the source, the resolution held (§4.3), the schema's window field, and the span (`Push.new/3`'s `chunk_span:`, the description's, else derived from the resolution, `Description.chunk_span/2`). Its columns are the schema's fields, by their names and types. The rows are packed as `Delivery.table/2` packs them, so a category's atom reads back as its string and a time column's values as `DateTime`s; rows that don't pack are `{:table, faults}` in `errors`, and not applied.
- **A change that reaches a settled range lands in that range's delta,** in this changelog's form: row retractions matched as §4.2 matches them, range replacements as predicate deletes (applied on read, so a cold chunk needs no fetch), and insertions. The delta is applied when the range is read, and a lazy compaction folds it in (Kudu's delta stores; Delta Lake's and Iceberg's deletion vectors).
- **The change event is the push.** A derived source receives the increment when it arrives, the same increment that went into the delta, replacements included. No other trigger exists.
- **Compaction changes only the layout.** The contents before and after it are equal (`Table.equal?/2`), so it emits nothing, and it moves no watermark: a change before `complete_until` doesn't move it.
- The rows are in the window field's order, rows with no window value last (§4).

```test:push-held-table
held/1's rows are a chunked table of the source's origin, its columns the schema's fields, built and changed through Table.apply/2: a settled range's changes land in its delta, and the held rows still equal the relation; rows that don't pack are recorded and not applied
```

## 3. Deliveries {#sources-delivery}

**`Macaw.Data.Delivery` is one answer of a source,** a snapshot of its relation (§2.5): its rows, and what it actually served, a handful of terms beside the rows, never per row. `%Delivery{rows, names, types, schema, served, origin, retracted, replace}`:
- **`rows`, the rows as the source gave them** (macaw#185): a list of row maps or tuples, a map or keyword list of columns, an `Nx.Tensor`, a `Table.Reader` source, or a `Macaw.Data.Table`, which passes as it is. **Nothing is packed or rewritten when a delivery is made:** a delivery is on the hottest path a live chart has, every tick of every chart reading it, and packing at the edge cost a reader of rows half a second for 50,000 rows (visualize#970), dropped tuple rows, and rewrote values a reader gave (an integer beside floats, a naive time, a sparse row). `new/2` checks only the shape, and raises `ArgumentError` for rows of no shape a source has.
- **`names`**: the column names of tuple rows or a tensor, in order, or `nil`; **`types`**: column types for packing, `%{}` to infer them.
- **Reading:**
  - `rows/1` (and `Table.rows/1` of a delivery) is the row view, as `Table.rows/1` reads the source: a row list itself, uncopied, its tuple rows unchanged; a table, a column map or a tensor one row at a time. Nothing is rewritten.
  - `named_rows/1` is the rows as maps, for a reader that reads them by name (finishing, push, a reducer): tuple rows and a tensor named by `names` (`Table.named/2`). **Tuple rows without names raise `ArgumentError`:** they cannot be read by name, and are never dropped for it.
  - `table/2` packs the rows into a `Macaw.Data.Table` (§1.1) for a reader that wants columns, `{:ok, table}` or `{:error, faults}`, with the delivery's `types` and `names` and any `opts` gives; `table!/2` raises. **Packing normalizes, there and only there:** the delivery's rows never change. A source that already holds a table delivers it, and a reader of columns pays nothing.
  - `empty?/1` is whether there are no rows.
- **`schema`**, the **version** of the schema the rows were produced under (§1.10), never the schema itself, which the cache holds by version (§1.12); `nil` when the source has none.
- **`served`**, what this answer served, which may differ from what was asked:
  - `window`: a range `[from, to]` over a `:time` or `:number` window field; a **box** `%{west: w, south: s, east: e, north: n}` over a `:point` one, in degrees, latitudes from −90 to 90 with `south` at most `north`, longitudes from −180 to 180 (`west` east of `east` crosses the antimeridian); or `nil`;
  - `resolution`: the spacing of the rows as served (seconds, or a name such as `:minute`), or `nil`;
  - `capped`: whether the source stopped short of the window it was asked for, `false` by default;
  - `reduced_by`: who brought the rows within budget: **`:source`** (the source honored the budget) or **`:runtime`** (Macaw reduced a pooled delivery to this reader's budget, finished a budget the source didn't honor, or clamped a budget to the host ceiling); `nil` when nobody had to. A component that draws fewer rows than it was handed says so in its own drawn state ([macaw_compose 05](https://github.com/dcoai/macaw/blob/main/spec/05-components.md#components-states)), not in the delivery;
  - `params`: the parameters it was answered for, a map, `%{}` by default;
  - `note`: a line for a person (`"coarsened from raw"`), or `nil`;
  - `position`: for a snapshot taken for a push subscription, the number of the last increment it reflects, a non-negative integer (`0` for none); `nil` for any other answer (§4.1);
  - `complete_until`: a value of the window field, a time or a number, below which the source expects no further change, or `nil` for no claim (§4.4).
- **`origin`**: `%{source: name, request: digest, as_of: time}`, the source, a digest of the request (`Macaw.Layers.Document.digest/1` of it), and the `DateTime` it is as of when used, else `nil`; or `nil`.
- **`retracted`** and **`replace`**: the changes a pushed increment carries beside its inserted rows (§4.2), `[]` by default.

`new/2` raises `ArgumentError` naming the fault for a key that is not a delivery's or a served fact, or a value a field does not take. visualize's `Visualize.Data.Delivery` holds these facts flat, with `reduced_by: :feed | :visualize` and no `served` or `origin`; mapping them at adoption is visualize's.

**Absence is never zero:** a source never fills a gap with 0, and a delivery's table keeps every gap `nil` (§1.1). (metresis.md C1.)

```test:delivery-table
a delivery reads rows, columns, keyword columns and a table as rows, empty?/1 answering; a table passes as it is; table/2 packs with the delivery's types, and a value its type doesn't hold is table/2's fault, not new/2's; a value of no source shape and a delivery of a delivery are refused
```

```test:delivery-rows-as-given
50,000 tuple rows read back the same term through rows/1 and Table.rows/1; integers, naive times, ISO strings and a sparse row read back unchanged; only the packed table normalizes
```

```test:delivery-tuple-rows
tuple rows and a tensor read back as given; named_rows/1 and table/2 name them by names (or table/2's names:); without names named_rows/1 raises, and with too few it raises naming the fit
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

**A push is the source's changelog** (§2.5). Push is optional and declared (`:push` in `supports`). A pushing source implements `subscribe(source, pid)`, answering `{:ok, ref}`, and `unsubscribe(source, ref)` (§2); `Macaw.Data.Source.subscribe/2` answers `{:error, :no_push}` for a source that doesn't. It sends the subscriber three messages, each tagged with that reference (`Macaw.Data.Source.Push.schema_message/2`, `snapshot_message/2`, `increment_message/3`):

```
{:macaw_source, ref, {:schema, schema}}            first, and again whenever the schema changes
{:macaw_source, ref, {:snapshot, delivery}}        the relation, as of its served.position (§4.1)
{:macaw_source, ref, {:increment, seq, delivery}}  the changelog's change numbered seq (§4.1)
```

The subscriber holds a `Macaw.Data.Source.Push`, a value, not a process: `receive/2` takes each message, `:ignore` for one not under its reference; `snapshot/2` takes a snapshot the holder fetched (§4.1); `drain/2` applies what is buffered; `held/1` is the relation as it stands, the integral of the increments (§2.5); `refetch/1` is `nil`, or why the holder must fetch a snapshot.

- **The handshake sends the schema first,** so an increment naming its version resolves from the cache without asking the source.
- **An increment's rows are insertions, merged by the window field.** Its rows after what is held are appended and its late rows placed among the held, every one of them: rows are not deduplicated (§4.1). The rows stay ordered by the window field, and the served window grows to cover them. A schema with no window field keeps the newest `limit` rows (100 000), marking the delivery `capped` when it drops any.
- **Pushes between two pulses are coalesced:** they buffer, and one `drain/2` applies them all, in their numbers' order (§4.1), whatever the push rate.
- **An unknown schema version falls back to `describe`,** asked once through `Macaw.Data.Schema.Cache.resolve/4` and cached. An increment whose version can't be resolved is dropped and its reason kept in `errors`.

(visualize.md C1; metresis.md C1. The merge is visualize's `Visualize.Feed.Monitor`'s, whose message tag was `:visualize_feed`.)

```test:push-handshake
a subscription's schema message arrives first and is cached, so its increments drain without describe; a message under another reference, or of another shape, is ignored
```

```test:push-unknown-version
an increment naming an uncached version asks describe once and caches it; a version describe cannot answer drops the increment and keeps the reason
```

```test:push-merge
increments merge by the window field, newer appended, late placed, an identical row held again, the served window grown; with no window field the newest rows to the limit, capped; for any split, and any increment repeated under its number, each row once in time order
```

```test:push-coalesce
fifty pushes buffer without a merge, and one drain merges them all in order
```

### 4.1 Numbering and the handoff {#sources-push-numbering}

**Each increment carries a sequence number,** a positive integer, increasing by one per subscription from `1`. Idempotence and order are the increment's, never the row's:
- **A repeated or older increment is dropped whole,** one at or below the position held, and counted in `ignored` (`:repeat`). Redelivery is harmless.
- **Rows are not deduplicated.** Two identical rows are two rows of weight 1 (tally taps), so an increment's row is held even when an identical row is held already.
- **Increments apply in the order of their numbers.** Retraction matching and replacement depend on what is held, so the changelog is not commutative.
- **A gap is a lost message.** BEAM delivers messages between two processes in order, so an increment numbered past the next one means some never arrived. It is held back, unapplied. A gap is judged when a drain ends, so increments that arrive out of order between two drains apply in order and leave none; one that remains is recorded in `errors` as `{:gap, from, to}`, the missing numbers, once, and `Push.refetch/1` answers it until a snapshot is taken or the missing increments arrive.

**The snapshot hands off to the stream by position.** A snapshot taken for a subscription states the position it reflects in `served.position` (§3): the number of the last increment it includes, a non-negative integer, `0` for none; `nil` for any answer not taken for a subscription. A source sends one with `snapshot_message/2`, on subscribe or on resubscribe. A holder fetches one after a gap or a resolution mismatch, naming the subscription's reference in the request (`subscription:`, §2.3, `nil` by default), and hands it over with `Push.snapshot/2`.
- **It replaces what is held,** as the full replacement it is (§2.5), and the position becomes its own.
- **Increments at or before its position are dropped** (`:repeat`); later ones apply in order, those held back included.
- **A snapshot older than the position held is dropped whole** (`:stale_snapshot`): it was taken before increments already applied. One that states no position is `{:snapshot, :no_position}` in `errors`, and not applied.
- So **no increment is applied twice or lost** while a snapshot is in flight.
- **Before any snapshot, the relation is empty at position `0`,** so a source that sends no snapshot numbers its first increment `1`, applied to nothing.
- **`Push` is a value, so the holder refetches.** `Push.refetch/1` is `nil`, or why the holder must fetch a snapshot.

**Nothing raises; everything is recorded.** `errors` lists each fault, in order, with its reason, the terms §4.1–§4.4 name; `ignored` counts what was dropped harmlessly, by reason (`%{repeat: n, stale_snapshot: n, unheld: n}`). A fault never fails the rest of its increment.

```test:push-numbered
a redelivered or older increment is dropped whole and counted, increments arriving out of order apply in the order of their numbers, and two identical rows are both held
```

```test:push-gap
a gap in the numbers is recorded with the missing numbers and answered with a refetch; the increments after it are held back, and apply after the snapshot that fills it
```

```test:push-handoff
over generated interleavings of a snapshot and the stream, a snapshot's own position and stale snapshots, no increment is applied twice or lost: the held rows equal the snapshot's plus every later increment's
```

```test:delivery-position
served holds a snapshot's position, nil by default, zero allowed; a negative or non-integer position is refused
```

```test:contract-request-subscription
a request names the subscription it is a snapshot for, nil by default, and refuses one that is not a reference
```

### 4.2 Retractions and range replacements {#sources-push-changes}

**A pushed increment carries its changes beside its inserted rows** (§3): `retracted`, a list of row maps withdrawn, and `replace`, a list of range replacements, each `%{from, to, identities, rows}`; both `[]` by default, and a snapshot carries neither. `Delivery.new/2` checks their shapes, raising `ArgumentError` for a retraction that is not a map, a replacement with another key, `identities` neither a list nor `nil`, or `rows` not a list of maps; a replacement's missing keys take `nil`, `nil`, `nil` and `[]`.

**`retracted`: rows withdrawn from what is held.** Identity names an entity, not a row (§1.4): a series or a host. Several held rows can share an identity and an instant (tally taps, label sets collapsed into one entity, duplicate readings), so a retraction matches in steps:
1. **By identity and the window-field value the row was held at:** its old value, when an edit moves the row. That locates the row, and in the chunked table its chunk (§2.6).
2. **By the fields it names beyond those,** each equal to the held row's. A retraction may name only its identity and window fields; where several held rows remain, it names enough of them to choose.
3. **The rows left must be one group of identical rows,** and one copy is retracted per unit of weight: a row retracted twice in one increment withdraws two copies, and two identical taps with one retracted leave one.
- **With no identity declared,** a retraction matches by the whole row, one copy per unit of weight.
- **What is recorded in `errors`,** never applied to a guessed row: a retraction of a row not held (`{:retract, :not_held, row}`); one whose identity is held only at another window value (`{:retract, :moved, row}`); one that can't tell distinct rows apart (`{:retract, :ambiguous, row}`).
- **A thinned holding may lack rows.** Where what is held came from a delivery that was `capped` or reduced to a budget (`reduced_by` set), a retraction naming an unheld row, or one held only at another window value, is a no-op counted in `ignored` (`:unheld`), not an error. Against a complete holding it stays a recorded fault.

**`replace`: a range replacement.** Each says that over `[from, to)` of the window field (`from: nil` from the start, `to: nil` open-ended), limited to `identities` (a list of identities as `Schema.identity/2` answers them, `nil` for every one), the relation is exactly `rows`.
- **As a change,** it is a retraction of everything held in the range plus an insertion of `rows`. The receiver computes the retraction from what it holds, so the source never has to remember what it sent. A rollup rebuild ("from T onward, exactly these buckets") and retracting a post with months of backfill are each one replacement.
- **Inside a replaced range, the replacement is the whole truth for that increment.** Any other row insertion or retraction in the same increment that falls inside it is `{:conflict, row}` in `errors`, and not applied; a replacement's own row outside its range or identities is `{:outside, row}`; a replacement overlapping another of the same increment is `{:overlap, range}`, and not applied.
- **A row with no window value** lies inside only a range open at both ends. A schema with no window field takes only that range; any other is `{:replace, :no_window_field}`.
- **A full snapshot is the limit case:** the whole range, every identity (§2.5).
- **Downstream,** a derived source receives the replacement as it is: it is part of the changelog's vocabulary. A consumer that needs a plain Z-set computes it against its own held state.
- **Changes to aggregated or thinned rows go through `replace`.** A source sends a changed bucket as a `replace` over that bucket's span, limited to its identity, which applies whatever the reader holds.

**The order within an increment:**
1. row retractions;
2. range retractions;
3. insertions: the replacements' rows and the increment's other rows.

So an update, even one that moves a row, is one increment.

```test:push-retract
a retraction matches by identity and held window value, then by the fields it names, one copy per unit of weight: of two rows differing in one field exactly the named one, of two identical rows one; with no identity by the whole row; a row not held, one held only at another window value and one that can't tell rows apart are each recorded and change nothing
```

```test:push-replace
a replacement equals the row retractions and insertions it stands for on any held state; limited to identities it leaves the others in the range; to nil covers everything from from; a conflicting change inside the range, a row outside it and an overlapping replacement are recorded and not applied; retractions apply before replacements, insertions last
```

```test:push-thinned
after a capped or reduced delivery, a retraction of an unheld row is counted in ignored, not errors; against a complete holding it is an error
```

```test:delivery-changes
a delivery carries retracted rows and range replacements, both empty by default; a retraction that is not a map, a replacement with an unknown key, a non-list of identities and non-map rows are each refused
```

### 4.3 One resolution per subscription {#sources-push-resolution}

**An increment applies only to a held relation at the same resolution** (`served.resolution`, `nil` equal only to `nil`). A source keeps one resolution for a subscription, fixed when it starts.
- **On a mismatch, nothing is merged.** The increment is `{:resolution, held, given}` in `errors`, `Push.refetch/1` answers the same, and the holder fetches a snapshot at the subscription's resolution (§4.1). The increment's number is consumed, so the snapshot hands off as any does.
- **Nothing is ever merged across resolutions:** rows of one spacing applied to rows of another would silently corrupt the relation (metresis#525).

```test:push-resolution
an increment at another resolution than what is held is not merged, is recorded and is answered with a refetch; the snapshot that follows hands off by position and clears it
```

### 4.4 Settled ranges {#sources-push-settled}

**`served.complete_until` is a watermark the source declares** (§3): a value of the window field, a time or a number, below which it expects no further change, or `nil` for no claim. It is an assertion the source makes on each delivery, not a setting.
- **It means settled, not final.** It marks where changes are expected, and so which results downstream are provisional. A change before it is still accepted, unless a hard bound refuses it (below), and lands in that range's delta (§2.6).
- **It never moves backwards within a subscription.** A later delivery, snapshot or increment, with a smaller value is `{:complete_until, :backwards, held, given}` in `errors`; the held claim is kept and the delivery's changes still apply. A new subscription, a new `Push`, starts afresh.
- **`Push` carries it forward:** what is held states the latest claim.
- **Perfect** when the source knows (a closed range), **heuristic** when it estimates (from its ingestion lag).
- **No `complete_until`, no claim:** the source's data is all provisional. That is always correct, just never settled.

**A description may declare `lateness`, a hard bound** (§2.1, `nil` by default), only for a source that really refuses changes past some age: a `Duration` over a `:time` window field, a non-negative number in the field's units over a `:number` one. Another value is `{[:lateness], {:type, :duration}}` or `{[:lateness], {:type, :number}}` from `Description.new/1`, and a `lateness` with no window field `{[:lateness], :no_window_field}`. The holder gives it to `Push.new/3` (`lateness:`).
- **Where declared,** a change whose window value is older than `complete_until − lateness`, the claim held when the increment is applied, is refused: `{:late, row, bound}` in `errors`. A replacement whose range reaches before the bound (`from` earlier, or `nil`) is refused whole, `{:late, range, bound}`, never clipped.
- **Where not declared, a change of any age is accepted.** metresis declares none.
- **A claim the bound can't be taken from,** a time against a number `lateness`, is `{:lateness, :incompatible, claim}` in `errors`, and bounds nothing.
- **A snapshot is the relation itself,** and is never refused.

**What it serves:** a chart draws the part after `complete_until` as provisional; the chunked table marks the chunks wholly before it settled (§2.6); its cold tier prefers settled chunks.

(Watermarks: Akidau et al., *Streaming Systems*, 2018.)

```test:push-settled
complete_until is carried forward; a smaller one is recorded and the held claim kept while the changes apply; a new subscription starts afresh; with none there is no claim
```

```test:push-lateness
a change of any age is accepted without lateness; past a declared bound a row is refused with its reason and a replacement reaching past it refused whole; a snapshot is never refused; a description's lateness is a duration over a time window field, a number over a number one, and refused with no window field
```

```test:delivery-complete-until
served holds complete_until, a time or a number, nil by default; any other value is refused
```

## 5. Change notification {#sources-change}

<!-- surfex: deferred #108: change notification needs the page runtime -->

**"This source's data changed; re-read it."** Any writer (an editing component after a commit, a host after an import) announces a change to a source by name, or the source pushes. Every reader on the page, and on other pages through the notification behavior ([macaw_compose 00](https://github.com/dcoai/macaw/blob/main/spec/00-overview.md#overview-goals) goal 3), re-fetches. Components never need to know who else reads the same data. (macaw_compose#9.)

## 6. Running sources {#sources-running}

### 6.1 Budgets: the ceiling and pooling {#sources-budgets}

- **The host ceiling** clamps every slot's budget ([macaw_compose 05](https://github.com/dcoai/macaw/blob/main/spec/05-components.md#components-budget)). A host sets it once; a page may lower it, never raise it. `Finish.ceiling/2` is the rule: `{budget, clamped?}`, a `nil` budget reading at the ceiling.
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

- **The recorded form,** `Macaw.Data.Event.recordable/1`, drops `row` and `point`. Records, observation and state snapshots only ever see the recorded form, so **row values never reach them**. The `identity` and the event's own `value` do, and they can be personal; whether they are recorded is decided per state source by capture level ([macaw_compose 08](https://github.com/dcoai/macaw/blob/main/spec/08-records.md#records-stores)).
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

- **`element`** locates what was acted on: the component fills it. `item` is the element's stable id ([macaw_compose 05](https://github.com/dcoai/macaw/blob/main/spec/05-components.md#components-declares)); `path` lists **the item and its enclosing elements, innermost first** (a visual's mark is `[item]`; a prose component's element, its sections around it), aligned with visualize's established meaning (macaw_compose#65); `frame` is set only by components with an inner coordinate tree (a visual's frame), and is `nil` otherwise.
- **`initiator`**, which the component sets, separates the steps of a view path (a visitor did something) from its markers (the system did something) ([macaw_compose 08](https://github.com/dcoai/macaw/blob/main/spec/08-records.md#records-paths)). A paused animation is a system event.
- **`time`** is the holder's now, passed to the component; a component's event code never reads a clock for it. A Macaw surface always supplies its own clock, which tests and replays control, so a recorded path replays with its times. A **standalone holder** (a visualize chart outside any surface, whose host is its holder) may default its now to the host's wall clock, if the default stays injectable and is checked to answer a `DateTime` (macaw_compose#73, #91; visualize#955).
- **The drawn-token rule:** an event on an element that maps to data resolves against the drawing it landed on. Each drawing carries a token; an event whose token is not the current drawing's is dropped, never resolved against newer data. (visualize D-170.)
- **Identity is the declared identity** of the item (§1). Inference from other fields is allowed only for a visitor's one-off pick, never for tracking or recording. (visualize D-167.)

## 9. The conformance kit {#sources-conformance}

Every source runs **one kit**, `Macaw.Data.Source.Conformance`: the contract of §2–§4 as checks, so a provider proves conformance by running it rather than by reading this file. It is visualize's `Visualize.Feed.Conformance` (visualize spec 08 §12), with the checks a source's superset of a feed needs.

**Two layers.** `check(check, source, opts)` answers one check's **findings**, `{check, reason}` terms, `[]` for a source that passes; `check(source, opts)` runs them all, in the order of `checks/0`; `format/1` words a finding as a line a person reads. `use Macaw.Data.Source.Conformance, source: …` inside a module that uses `ExUnit.Case` writes one test per check, in a `describe` block, failing with the findings. The kit itself references no ExUnit function (`describe`, `test` and `flunk` appear only in the code `use` writes), so it loads in production. `use` refuses a missing `source:` and an unknown option at compile time; `check/3` refuses an unknown check, an unknown option and a request key outside the six below.

**The eight checks:**

| Check | Holds |
|---|---|
| `:describe` | `describe/2`, given the host's `context:`, answers a description `Description.new/1` accepts as it stands; its schema is one `Schema.new/1` accepts, its version the content hash (§1.10); a measure the vocabulary refuses is its own finding, naming the field; a source naming `:window` has a `:time` or `:number` window field, one naming `:box` a `:point` one; a second describe answers the same description |
| `:deliveries` | each request, at each budget, answers a well-formed delivery (§3) naming the described version: every row field described; the window field holding values of its type; every other `:time` field instants; every declared identity field present; every row within the served window; no two rows of a series closer than the served resolution; the served window complete (an open fetch holds no row inside it that the delivery lacks); `capped` true only with a shortfall and false only without one; `reduced_by` `:source` only when the source reduced, and never `:runtime`, which is Macaw's (§2.4) |
| `:supports` | `supports` is distinct capabilities, and each it names is true: the window kept (served within, no row outside), the box kept, every region range kept, `latest` one row per identity and none older than its last, the budget never exceeded, `as_of` answered as of the instant asked (an origin names it, and an hour's later `now` changes nothing), `:push` subscribable; a source not naming `:push` refuses `subscribe/2` |
| `:push` | the handshake's first message is the schema; every pushed schema is valid; every pushed snapshot and increment is well formed, within its served window, and after the schema it names; a snapshot states its position (`{:snapshot_position, got}`), and the increments are numbered one past it, or from `1` with none, each one past the last (`{:numbering, expected, got}`); `push:` makes an increment arrive (§4) |
| `:errors` | requests no source can read (a window of no times, of either kind, mixed; a box; a region over an unknown field with `latest`) answer values, a delivery or an error, never a crash; an undeclared parameter never reaches the source (`{:error, {:params, faults}}`, §2.2); `unsubscribe/2` of an unknown reference is `:ok`; a `down:` source answers errors to `describe`, `fetch` and `subscribe` |
| `:unsubscribe` | after `unsubscribe/2`, a push made by `push:` delivers nothing |
| `:determinism` | one request, one `now`: two fetches give one answer, the same rows and served terms. A row stamped after `now` arrived between them and is not compared. An answer depends on the request, never on a clock the source reads |
| `:viewers` | a source declaring `viewer_independent` answers the two `viewers:` alike, which pooling across viewers (§6) relies on |

**Requests.** `requests:` lists what is asked, each a keyword list of request fields among `params`, `window`, `box`, `region`, `latest` and `as_of` (`[[]]` by default), each fetched at every one of `budgets:` (`[nil, 5]`), at `now:` (the moment the check starts by default) and as the first of `viewers:`. A capability the source names that no request probes is a finding (`{:no_probe, capability}`), and so is a request the schema cannot answer (`{:probe, ask, faults}`): both are the run's to fix. The other options are `context:`, `as_of:` (a day before `now` by default), `push:`, `down:`, `timeout:`, `reductions:`, `processes:` and `quiet:`.

**Isolation.** Every callback runs in a process of its own (`Macaw.Data.Bounded`), so a raise or an exit is a finding (`{:raised, call, reason}`), not a crash of the check. A callback is judged by the **reductions** its process spends against `reductions:`, the source author's cost budget (`nil` makes no cost claim), with the reductions of the named `processes:` during the call added for a source that works in a server; liveness is a separate wall-clock bound, `timeout:`, for a call blocked in `receive`, which is `{:hung, call, timeout}`. A budgeted callback still working when `timeout:` passes is left to its budget, so a slow one on a loaded host is judged by its count, never hung (macaw_data#33); a callback with no budget has only the clock, and past it is hung whatever it is doing. **Load changes no verdict:** nothing is judged by the clock but a hang.

The kit is **ported, not reinvented**, so visualize's feeds keep their checks when they become sources; the adapter that runs it over them is visualize's (macaw_compose#58, #112).

```test:conformance-honest
an honest source passes every check, with a down source and declared identities too; a source that cannot describe stops each check with the reason; a finding reads as a line naming its check
```

```test:conformance-flaws
every flaw of the broken sources fails the check it targets with the finding that names it, every check is failed by some flaw, and every finding formats as a line
```

```test:conformance-errors
a down source that answers describe, fetch and subscribe is three findings; a source raising on an unreadable request is a raised finding, not a crash
```

```test:conformance-probes
a capability no request probes is a no_probe finding for the window, budget, push, region and box; a request the schema cannot answer is a probe finding; a request key outside the six is refused
```

```test:conformance-use
use writes one test per check into each describe block, refuses a missing source and an unknown option at compile time, and an unknown check is refused
```

```test:conformance-load
idle and with every scheduler saturated the verdicts agree: a correct source passes, a budget of one reduction fails describe while a generous one passes, an endless fetch is stopped at its budget, a blocked one is hung at the bound, and work in another process counts only when that process is named
```
