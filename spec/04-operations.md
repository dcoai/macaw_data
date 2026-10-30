# 04 — Operations {#operations}

The operations a design applies to its data and the operations a derived source may call are **the same code**, here in `macaw_data` beside derived sources (macaw_compose#22, decision 11; R18 of `design/visualize-alignment.md`). A computation therefore moves between a design and a derived source unchanged, and a metresis feed and a visualize chart reduce data the same way. This file is visualize's spec/14 §5.4.1 (the data steps) and its proposals visualize#886 (the transform behavior) and visualize#909 (the aggregate behavior), both folded into Macaw by the owner on 2026-10-26, adapted to Macaw's contracts (macaw_compose#83):

- **a transform reads and returns a `Macaw.Data.Table`** ([01 §1.1](01-sources.md#sources-table)), the currency of deliveries; rows are a view at the edge;
- **names are strings, matched by spelling.** A document's op name, option key, enum value or column name is read by spelling against the library's own vocabulary, and no atom is ever made from one. A column a step adds is named by the node's `as`, as it spells it, else by the step's default name, a string (`"count"`, `"x0"`): visualize's defaults are atoms, Macaw's are strings, as derived sources' joined fields are (02 §1.4);
- **the registry is explicit and default closed** (§2): `macaw_data`'s own package is always in, and anything else only when a host enables its package;
- **transforms that need geometry** (layouts, geographic operations) implement the same behavior and declare it (`needs: [:frame]`, §1.1). They live in the package that draws, never here, and are never reachable from a derived source, which has no frame.

| Module | What it is |
|---|---|
| `Macaw.Data.Transform` | the transform behavior (§1.1) |
| `Macaw.Data.Aggregate` | the aggregate behavior (§1.2) |
| `Macaw.Data.Operations` | `macaw_data`'s own package, the registry, and running nodes and aggregates (§2, §3) |
| `Macaw.Data.Operations.Option` | option declarations, their types and their checks (§1.3) |
| `Macaw.Data.Operations.Transforms.*`, `Macaw.Data.Operations.Aggregates.*` | one module per table operation (§4) and per statistic (§5); `Aggregates.all/0` lists the statistics |
| `Macaw.Data.Stack`, `Macaw.Data.FFT` | the engines of `stack` and `spectrum`, ported from `Visualize.Shape.Stack` and `Visualize.Data.FFT` (§4.8, §4.11) |
| `Macaw.Data.Ops` | what a stored function calls (§6) |

## 1. The behaviors {#operations-behaviors}

Each behavior is a module's declaration of what it reads and what it answers, so **one declaration** feeds the validator (§3.1), the drawer's builder forms and vocabulary, the JSON forms and the sandbox (§6); a member is never described a second time anywhere else. **A member is pure and deterministic:** the same node and table give the same table, with no processes, ETS, NIFs, `Regex`, clock or randomness (the portable set, visualize#918). Anything a member needs that varies comes in its node or its context.

### 1.1 Transforms {#operations-transform}

`@behaviour Macaw.Data.Transform`:

| Callback | Contract |
|---|---|
| `name() :: String.t()` | the op a node names, unique in a registry (§2) |
| `options() :: [{String.t(), Option.t()}]` | every key the op reads, in order, each declared as §1.3 says |
| `needs() :: [:frame \| :projection \| :text]` | the context the op requires beyond §3.2's: `[]` for a table operation; `[:frame]` for a layout (the plot's size and center), `[:projection]` for a geographic projection, `[:text]` for text measurement |
| `outputs(node, columns) :: [{name, type}]` | the columns, in order and with their `Macaw.Data.Table` types, of the table `run/3` answers for a node (checked, §3.1) over input columns (`[{name, type}]`) |
| `run(node, table, context) :: table` | the step: the table after it |
| `reduces() :: {String.t(), pos_integer()}` *(optional)* | a **reducer**: the option holding the target count, and the rows each unit of it keeps at most (`lttb`: `{"n", 1}`; `m4`: `{"width", 4}`), so a budget can name it (§7) |
| `prepare(nodes, table, context) :: term()` *(optional)* | computed once per design and shared by every mark that reads it (a force layout's positions), passed to `run/3` in the context under `prepared`; the drawer's, never called here |
| `class/1`, `reads/0`, `bind/3`, `resolve/3`, `chunk/3`, `keyed/1`, `combine/3`, `finish/3` *(optional)* | a **column-native step**'s class, the context it reads, its part per chunk and its merge (§1.4) |
| `update(node, part, change, resolved)` *(optional, a combine's)* | its **inverse update** where exact (§1.5): a chunk's part from its base's part and its delta's changes, `{:ok, part}` or `:recompute` |

`run/3` is given **the node checked** (§3.1): its keys strings, each of the op's options present with its default filled in, an enum value its declared atom, a frame-bound value resolved to a number. `outputs/2` is given the same node. `outputs/2` holds for `run/3`: for every fixture of the op's tests, the columns `run/3` answers are, by name and type, the ones `outputs/2` names.

```test:operations-transform-callbacks
a transform declares its name, options, needs and outputs and runs a checked node over a table; an optional reducer, prepare and the column-native step's callbacks are declared only by the ops that have them; outputs agree with what run answers on every fixture
```

### 1.2 Aggregates {#operations-aggregate}

`@behaviour Macaw.Data.Aggregate`: a statistic, the reduction of one column's readings to one value.

| Callback | Contract |
|---|---|
| `name() :: String.t()` | the name a node's `fn` or a stored function names, unique in a registry |
| `options() :: [{String.t(), Option.t()}]` | the keys the aggregate reads (`quantile`'s `p`), declared as §1.3 says. None may be a key of the step that names it (`op`, `field`, `by`, `as`, `fn`, `thresholds`, `values`): the registry refuses it (§2) |
| `output(type, options) :: type` | the output's `Table` type for an input column of `type` |
| `keeps_unit?() :: boolean()` | whether the input's unit and quantity carry to the output (§5) |
| `reduce(values, options) :: term()` | the value of the readings, **`nil` readings already dropped**: a gap is absence, never zero (01 §1.1) |
| `init(options)`, `step(state, value, options)`, `finish(state, options)` *(optional, together)* | the streaming form chunked windows use, over the same readings in the same order: `finish(Enum.reduce(values, init(options), &step(&2, &1, options)), options)` equals `reduce(values, options)` |
| `merge(state, state, options)` *(optional, with the streaming form)* | the **combining form**: the state of two runs of readings, the first before the second, from each run's state. It is associative, so a step's per-chunk states merge under any grouping (§1.4): `merge(state(a), state(b))` finishes to the value of `state(a ++ b)` |
| `retract(state, state, options)` *(optional, with the combining form)* | its **inverse, where exact** (§1.5): the state of a run's readings with some removed, from the run's state and the removed readings' state, `{:ok, state}` equal to the state of the readings that remain, or `:inexact`. `count` has it; `sum` has it while every reading is an integer (once a float is among them the sum is a float, where the remaining integers' would be an integer); no other statistic has it |

```test:operations-aggregate-callbacks
an aggregate declares its name, options, output type and whether it keeps the unit, and reduces readings with nils dropped; where it has the streaming form, the stream equals reduce on every fixture, chunked at every split; where it has the combining form, merging the states of two runs equals the state of both
```

### 1.3 Options {#operations-options}

An option is declared `{name, %Option{type: type, default: value, required: boolean, frame: :width | nil, doc: String.t()}}`. A required option has no default; an optional one's `default` is filled in when the node omits it (`nil` is a default). `frame: :width` makes it **frame-bound** (§3.2).

| Type | Holds |
|---|---|
| `:field` | a column name, a string or an atom; read by either spelling |
| `{:list, type}` | a list of `type` |
| `{:pair, type}` | a two-element list of `type` (`fields: [x, y]`) |
| `:name` | the name of a column the step adds, a string or an atom, kept as written |
| `:number` | any number |
| `{:number, low, high}` | a number in `low..high`, both inclusive |
| `:positive` | a number above zero |
| `:integer` | any integer |
| `{:integer, min}` | an integer at least `min` |
| `:power_of_two` | a positive integer power of two |
| `:boolean` | `true` or `false` |
| `{:enum, atoms}` | one of `atoms`, written as the atom or its string |
| `{:one_of, types}` | a value of the first of `types` that holds it |
| `:duration` | `[n, unit]`, `n` a number and `unit` one of `second`, `minute`, `hour`, `day`, `week`, `year` (§4.3) |
| `:aggregate` | the name of an aggregate in the registry (§2) |
| `:term` | any value |

`Option.check(registry, option, value)` answers `{:ok, value}`, the value as `run/3` is given it (an enum's atom, an aggregate's module), or `{:error, reason}` (§3.1).

```test:operations-option-types
every option type holds the values it names and refuses the rest with a reason naming the type; an enum is read by spelling into its atom; a frame-bound option takes "plot" or its own type
```

### 1.4 Steps: a part per chunk, and a merge {#operations-steps}

**A table is chunked** ([01 §1.1.1](01-sources.md#sources-table-chunks)), and each of `macaw_data`'s table operations works it **a chunk at a time** (macaw_data#9 §5): a part per chunk, then a merge of the parts into the step's table. No step transposes: it decides from only the columns it reads, then gathers every column, a packed column by slicing or copying its buffers. No step calls `Table.rows/1` or `Operations.table/2` inside a chain; `rows/1` and `row/2` are the row view at the edge. A chunk's part depends on that chunk and on the context as it resolves for it, so a caller may keep it across frames, changes and compaction ([01 §1.1.3](01-sources.md#sources-table-chunk-identity)). `Macaw.Data.Operations.Step` runs a step so; a transform without the callbacks below is run whole by `run/3`, as a host's may be.

A column-native step declares, beside §1.1's callbacks (each optional, together):

| Callback | Contract |
|---|---|
| `class(node) :: :row \| :combine \| :global` | its **class**, which decides its merge |
| `reads() :: [atom()]` | the keys of the context it reads (§3.2): only those reach it |
| `bind(node, table, context) :: map()` *(optional)* | the declared context resolved over the whole input, once: `window`'s `now`, the newest reading when the caller gives none. Without it, the declared context as it is |
| `resolve(node, view, bound) :: term()` | the context **as it resolves for one chunk**, from the bound context and the chunk's place (`:at`, the input's row its view starts at, and `:rows`, the input's count). It reads that chunk's columns alone |
| `chunk(node, view, resolved) :: part` | the chunk's part |
| `keyed(node) :: map()` *(optional)* | the node's options a chunk's part depends on, when not all: the step key holds them in place of the whole node (`m4` and `lttb` leave out their count, which only the merge reads) |

A view is `{chunk, first, count}`, the run of a chunk the input reads (`Table.chunks/1`).

- **Per row** (`:row`): `filter`, `take` and `window` without `latest`. Each chunk is worked by itself, and **the merge is concatenation**. A per-row step's part is a selection of its view's rows: `:all`, the view passed through unchanged, its chunk the input's; `:none`, dropped; `{:run, first, count}`, a run of it, cut without copying; or `{:rows, indexes}`, those rows, every column gathered into a new chunk by copying its slots (`Table.Chunk.gather/5`), whose id is `{input's id, step key}`. The output keeps the input's columns and the column it is known to be sorted by (`Table.sorted/1`).
- **A combine** (`:combine`): `sum`; `m4` and `lttb` (§4.5.1); `aggregate` and `bin` with no `fn` or one with the combining form (§1.2: `count`, `sum`, `mean`, `min`, `max`, `extent`); and `window` with `latest`. Each chunk's part is a **partial**, and the step declares `combine(node, a, b)`, the partials of two runs merged, the first's chunks before the second's, and `finish(node, merged, %{input, key})`, its table from the merged partial (`nil` for an input of no chunks). `combine/3` is **associative**: the partials are merged in the input's chunk order, and any grouping of them, any tree, gives the same merged partial, so per-chunk partials may be kept and merged again, and any chunking gives `Table.equal?/2` results. Where a step's order matters (groups in order of first appearance, `latest`'s ties, `bin`'s readings) the merge keeps it: the first run's before the second's. A combine's output is one chunk over every input chunk (`Step.output/3`, `Table.Chunk.combine/3`), its key the step's identity over every part's key, or gathered rows named by the rows they hold (`latest`). An exact sum is what makes a floating-point sum combine: any grouping of the same readings gives the same bits (§5).
- **Global** (`:global`): `sort`, `stack`, `spectrum`, and `aggregate` and `bin` with an `fn` that has no combining form (`median`, `quantile`, `distinct`, `variance`, `deviation`, `slope`, `delta`). Each chunk's part is what the step reads of it (its readings, the group keys); the merge is stated by the step: `finish(node, partials, %{input, key, context})`, given every partial in chunk order, runs over the whole input. **A global output's id is its step key over its inputs:** one chunk over every input chunk (`Step.output/3`, `Table.Chunk.combine/3`), named by the step's identity over the parts' keys and the inputs' ids and versions, so the same input gives the same id run after run, and a step after a global step still caches. Rows a global step keeps are **gathered across the chunks** (`Step.gather/5`): each value read back and packed again, so a dictionary is the output's own and codes are remapped across chunks, a cost the step counts.
- **Reshapes:** `fold` is per row, its part `{:reshape, indexes, added}`: the view's rows at `indexes`, repeats allowed, its carried columns gathered at them by copying slots and its added columns packed from their values (`Table.Chunk.reshape/7`), under the step's `outputs/2`. `stack` gathers across chunks with repeated indexes, one row per series per datum, and adds its columns. With these, **no step transposes**.
- **The step key** of a chunk is the step's identity (`step_digest/2`'s, the kernel's digest of its module and its checked node, or of `keyed/1`'s options when the step names them), the context as it resolved for the chunk, and the run of the chunk the view reads when that is not the whole chunk. Keying on raw context would miss on every frame, so the key changes only when the chunk's part could: a cache keys a part by `{Chunk.id/1, Chunk.version/1, step key}`. `Step.parts/4` lists each chunk's view, resolved context and key, computing no part; `Step.chunk/3` computes one and `Step.merge/6` merges them, given the parts' keys and the context; `Step.run/4` is the three.
- **The chunking never changes a result:** the same rows chunked any way give `Table.equal?/2` results.

```test:operations-step-classes
every column-native step declares its class and the context it reads, and only that context reaches it; a per-row step's merge is concatenation, its output's chunks the input's passed through, cut to a run, or gathered under the id {input id, step key}, in order, the input's sorted column kept
```

```test:operations-step-combine
for generated rows over about 40 seeds, sum, aggregate with count, sum, mean, min and max by groups, bin counting and reducing, and window with latest give equal? results under every chunking and every grouping of their partials merged in chunk order, equal to the rows' answer; a float sum is the same bits whatever the grouping
```

```test:operations-step-global
for generated rows over about 40 seeds, sort, fold, stack, spectrum, and aggregate and bin with median, quantile and distinct give equal? results under every chunking, equal to the rows' answer
```

```test:operations-step-global-cache
a global step's output chunk is named by its step key over its inputs, the same run after run and another when an input changes, so the next step's keys hold; a category column whose chunks have different dictionaries is sorted across them with every value read back as given
```

```test:operations-step-no-transpose
a chain through every table operation calls neither Table.rows/1 nor Operations.table/2
```

```test:operations-step-chunking
for generated rows over about 40 seeds, filter, take and window give equal? results over the same rows chunked a row a chunk, 7 rows a chunk, canonically, and as one chunk, equal to the rows' answer
```

```test:operations-step-keys
a chunk's step key is the step's identity, the context as it resolved for the chunk and the run its view reads; window keys a chunk wholly inside it without now, so the key holds across frames, drops one wholly outside, and keys an edge chunk by its slice bounds
```

```test:operations-step-cost
take n: 100 reads only the chunks it returns, its work growing by a step a chunk and never with the rows; a chain of filter, window and take calls neither Table.rows/1 nor Operations.table/2
```

### 1.5 Caching: owned by the caller {#operations-cache}

**The operations are pure** (macaw_data#9 §6): they hold no cache and no hidden state. The caller owns the cache of steps' per-chunk parts, since the frame or the feed knows when a chunk leaves its window. `Macaw.Data.Operations.Cache` is the example caller, a plain value the caller holds and passes back.

- **The key** of a part is `{logical id, version, step key}`: `Chunk.id/1`, where the chunk sits ([01 §1.1.3](01-sources.md#sources-table-chunk-identity)); `Chunk.version/1`, its content digest, or a step output's derivation digest; and the part's step key (§1.4). **The version decides validity:** any rebuild of the same contents (a re-fetch, a restart, another process) has the same digest and hits, and different contents never do. **The logical id scopes eviction:** `Cache.prune/2` keeps only the parts of chunks the tables given still hold, at their version or their base version.
- **A digest is never computed on lookup.** The version is read from the chunk, computed once when its state was made. A chunk whose digest is pending has no version and never matches a key.
- **`Cache.run(cache, module, node, table, context)`** answers `{table, cache}`: for each of `Step.parts/4`'s parts, the part held under its key is **reused**; else a chunk with a delta whose base's part is held is **updated** by inverse, where that is exact; else the part is **computed** (`Step.chunk/3`). Only the merge (`Step.merge/6`) is recomputed. The table equals `Step.run/4`'s, a per-chunk run with cached parts equal to a full run. `Cache.run/5` records how the last run came by its parts (`last`: `reused`, `updated`, `computed`).
- **Compaction keeps every cached part:** it changes neither a chunk's logical id nor its content digest (01 §1.1.4).
- **What is reused frame after frame:** scale-domain extremes, M4 and `lttb` partials within a bucket level (§4.5.1), and any per-chunk part of a settled chunk. A drawn path segment is not free: it is reusable only if the caller applies the scale as a transform when drawing, which is the caller's concern.

**A delta's change to a cached part** (01 §1.1.4):

- **Inverse update, where exact.** A chunk with a delta keeps the version of its base (`Chunk.base_version/1`, its content digest before the delta), under which a cache held the base's part. `Step.update(module, node, part, base_part)` computes the part as `base ⊕ part(inserted) ⊖ part(removed)`: the step's `update/4` is given the parts of the base rows the delta removes and of its side rows, under the context the chunk's part resolved to, and where each base and side row lies in the chunk as read. Its result **equals the part the chunk as read computes**, so every path gives the same result. A delta is always over its base, so successive changes never update an update, and nothing drifts. Only the delta's rows are worked. It applies only to a part of a whole chunk (a view of a run recomputes). The exact domains:
  - **counts:** `aggregate` with `count`, by groups or none;
  - **`bin` counts:** `bin` without `fn`, each bin's readings kept in the order they read;
  - **integer sums:** `sum`, and `aggregate` with `sum`, while every reading is an integer (`retract/3`, §1.2).

  A group's order of first appearance is kept: a group none of whose rows remain is gone, and the groups are ordered by where their first rows read. A group whose first row was removed has its next first row unknown without reading the chunk, so that chunk recomputes.
- **Recompute otherwise:** a floating-point sum or mean, min and max, M4's extremes, `lttb`'s preselection and every other step recompute that one chunk, once per content digest. Subtraction drifts in floating point, which would break the property that every path gives the same result.

**What a frame costs** (macaw_data#9 item 7). A synthetic frame loop modeled on visualize's (`Macaw.Data.Test.FrameLoop`) holds a live source's 50,000-row window, appends a canonical chunk's worth of readings a frame and trims the oldest, and runs a chart's steps over it: `take n: 100`, `filter`, a `window` then `m4` to 1,000 pixels, a `window` then `lttb` to 1,000 points, and `sum` by series. It runs two ways: recomputed in full, and per chunk through a cache. The default suite states the per-chunk recompute's cost as work, in reductions: its changed chunks cost at most a full run over one chunk's readings, and its whole frame, merges included, at most half the full recompute. A wall-clock run is `@tag :benchmark` (`mix test --only benchmark`) and gates nothing; its results, and the decision on native kernels they inform, are recorded on macaw_data#9. The real loop's number is visualize's to measure. Its pure-Elixir cost is pinned as well (macaw_data#41): at most 1,100,000 reductions a per-chunk frame and 600,000 for its merges alone. **A frame's garbage collection:** the ladder's partials, the bulk of the cache, are packed binaries off the caller's heap (§4.5.3, macaw_data#46), so the frame loop's cache is about 11,000 words of heap (it was about 824,000 words of terms) and a collection no longer copies it. What a frame at the default heap still collects is its own working garbage, the terms a merge builds as it reads; a caller that sizes its frame process's heap (`:erlang.spawn_opt/2`'s `min_heap_size`) pays almost none of that. The benchmark reports both.

```test:operations-cache-frame-heap
the frame loop's cache, on either path, holds at most 50,000 words on the frame process's heap: the ladder's partials sit beside it as packed binaries
```

```test:operations-cache-frame-budget
the synthetic frame loop's per-chunk frame costs at most 1,100,000 reductions and its merges alone at most 600,000, so a regression in a per-row path fails the default suite
```

```test:operations-cache-frame
a synthetic frame loop at 50k rows with one new chunk's worth of readings a frame: every frame the per-chunk recompute equals the full recompute and computes only the changed chunks' parts; in reductions its changed chunks cost at most a full run over one chunk's readings, and its whole frame at most half the full recompute's
```

```test:operations-cache-reuse
a per-chunk run with cached parts equals a full run, for every combine, per-row and global step; a second run over the same table reuses every part and hashes no content; a rebuilt table of the same contents hits every part, and one with a chunk's contents changed computes that chunk alone; a chunk whose digest is pending is warmed before its key is read
```

```test:operations-cache-inverse
for generated settled tables and changes to them over about 40 seeds, count by groups, bin counts and an integer sum update each changed chunk by inverse from its base's cached part, equal to the part the chunk as read computes, and the run equal to a full run
```

```test:operations-cache-recompute
a float sum, a mean, min, max, m4 and lttb recompute a changed chunk rather than update it, equal to a full run; a group whose first row is removed recomputes its chunk
```

```test:operations-cache-prune
prune keeps the parts of the chunks the tables hold, at their version or base version, and drops a chunk's that left the window or a version no chunk has
```

#### 1.5.1 What a frame costs with the native kernels {#operations-cache-native-frame}

**With the native kernels loaded (§1.7), the frame loop's per-row work runs in them** (macaw_data#38, #54): the ladder partial (§4.5.2), the finishes (§4.5.4), the exact sum by group (§5.1), and the filter's mask and gather (§4.1.1). What is left on the BEAM is the steps' plumbing: their keys and the cache, `window`'s search, building output chunks and the merged partials' few terms. Measured on #26's loop (macaw_data#54, `mix run` and the `:benchmark` test, a shared box under load 5–19, so wall times are ranges):

| Frame | Reductions, Elixir path → kernels | ms at the default heap, Elixir → kernels | ms, frame heap sized (4M words), Elixir → kernels |
|---|---:|---:|---:|
| per chunk | 958,680 → ~181,000 | 36–47 → 7–10 | 13–16 → 6–8 |
| every part reused (merges alone) | 552,014 → ~175,000 | 23–40 → 6.5–10 | 9 → 5–7 |
| recomputed in full | 1,931,845 → ~186,000 | 55–58 → 9–11 | 30–33 → 7.4–11.4 |

So with the kernels a frame is within visualize's ~17 ms budget at the default heap, per chunk and recomputed in full: sizing the frame process's heap (§1.5) is no longer needed to meet it, though it still trims a millisecond or two. Without them, the Elixir path's cost and pins above stand. The kernels' work counts no reductions, so the frame's reductions with them are pinned too, as a guard that the kernels keep answering it:

```test:operations-cache-native-frame-budget
with the kernels loaded, the synthetic frame loop's per-chunk frame, its merges alone and its full recompute each cost at most 250,000 reductions, so a kernel that stops answering a step of the frame fails the default suite
```

### 1.6 Execution: inline by default, parallel on request {#operations-parallel}

**A step runs its chunks inline by default** (macaw_data#9 §7): a caller such as a frame task already runs many charts at once, and parallel work inside one step would compete with them.

- **`parallel: true`** in the context (§3.2) asks `Step.run/4` and `Cache.run/5` to work the chunks' parts across the schedulers, one task a part (`Step.chunks/4`). It is a per-call choice: the caller knows its own concurrency. It is no step's declared context, so it never reaches a step's key.
- **Above a size threshold only.** A run goes parallel when asked and its input holds at least two chunks and `Step.parallel_rows/0` rows: two canonical chunks' worth (16,384). Below it, a process per chunk costs more than the chunk's work, so the run is inline. The threshold is fixed, not a setting (`Step.parallel?/2`).
- **The merge has a fixed shape.** Inline or parallel, the parts reach the merge in chunk order, and the merge folds them in that order, one tree whatever ran them. Floating-point merges in another order would differ in the last bits, breaking both identical results and the derivation digest's precondition (01 §1.1.3). So **a parallel run is bit-identical to the inline run**, and the chunk size never changes a result (§1.4).
- **Set wrong, it only slows down:** the results are the same.

```test:operations-parallel-identical
for every column-native table operation over generated rows of several chunks, a parallel run and an inline run give identical tables, the same values bit for bit, including floating-point sums and means, and a cached run asked for parallel equals both
```

```test:operations-parallel-threshold
asked for parallel, a run above parallel_rows/0 with two chunks or more works its parts in other processes, in chunk order; below the threshold, with one chunk, or not asked, every part is worked in the caller's process
```

### 1.7 Native kernels: optional, and identical {#operations-native}

**A step's per-row work may run in a native kernel** (macaw_data#9 §8, #38): Zig, compiled through Zigler, `Macaw.Data.Native`. A kernel reads a column's packed Arrow buffers in place (01 §1.1): int64 and float64 values, LSB-first validity bitmaps, date32, timestamp[us] and dictionary int32 codes. It neither decodes a column to values nor expands a bitmap. The macaw forms (`macaw.integral`, the int/float union, per-value precision, `:list`) stay on the Elixir path, which every step keeps for them, for a build without the kernels, and for steps that have none.

- **Identical results.** A kernel answers exactly what the step's Elixir path answers, term for term and bit for bit, so a run with kernels equals one without. Its floating point is Zig's strict mode, its default: no expression is reordered, contracted into a fused multiply-add or assumed finite, and each follows the Elixir path's order of operations. Where the Elixir path would answer with an integer past 64 bits, or raise, the kernel answers `:fallback` and the Elixir path runs, so the edge cases are the Elixir path's own.
- **Optional, and visible.** The kernels are built when the build has Zigler and a Zig of the version Zigler targets (`.tool-versions`: Zigler 0.16.0, Zig 0.16.0). Zigler is an optional dependency: an adopter that wants the kernels lists `{:zigler, "~> 0.16.0", runtime: false}`. Without the toolchain the build prints a warning, not a compiler diagnostic, so a `--warnings-as-errors` build without Zig still succeeds, and every step runs its Elixir path. **`Macaw.Data.Native.loaded?/0`** is decided once, when the application starts, by asking the kernels their interface version, and held in `:persistent_term`.
- **`config :macaw_data, native: :optional | :required`**, default `:optional`. It is read at compile time. The deployer knows whether this build is expected to be fast. Set wrong, it fails loudly: `:required` without the toolchain fails the build, and `:required` with kernels that don't load fails the application's start. `:optional` degrades to the Elixir path, visible through `loaded?/0`.
- **The 1 ms rule.** A kernel reads a row in nanoseconds, and builds its answer's terms at tens of nanoseconds each, so a call's time follows its rows and the size of its answer. A call over at most `Native.sync_rows/0` rows (8,192, one canonical chunk) runs on a normal scheduler, within the BEAM's 1 ms even when every row answers a term of its own. A larger one, a one-chunk table built from rows, runs the same kernel on a dirty CPU scheduler (`Native.scheduler/1`). Each kernel's test states its call's time.
- **Reductions count no kernel's work.** A statement of work in reductions, such as the frame's (§1.5), is measured on the Elixir path: `Native.elixir/1` runs a function with every step in its process on its Elixir path, and `Native.active?/0`, which each step with a kernel asks, is false inside it. The Elixir path is also the reference each kernel is held equal to.
- **A panic is never silent.** The kernels are built ReleaseSafe in every environment, so a bounds or overflow fault panics rather than reading past a buffer. Each kernel checks its buffers' sizes and returns an error, raised in Elixir, for a malformed input. A panic is then a bug, and it takes the node down with its message and stack trace on standard error.

```test:operations-native-loaded
loaded? is a boolean held in persistent_term, decided when the application starts, true exactly when the kernels were built; a build under native: :required has them loaded, and a start whose kernels fail to load is refused under :required and runs the Elixir path under :optional
```

```test:operations-native-config
the toolchain and the native: setting decide the build: built with a toolchain, the Elixir path and a warning without one under :optional, a failed build without one under :required, and any other setting refused
```

```test:operations-native-scheduler
a kernel call over at most sync_rows/0 rows, 8,192, runs on a normal scheduler, and a larger one on a dirty CPU scheduler
```

```test:operations-native-elixir
active? is loaded? outside Native.elixir/1 and false inside it, and back after it; a step with a kernel run inside it takes its Elixir path, whose work reductions count
```

```test:operations-native-panic
a kernel that panics, run in a BEAM of its own, takes that node down with the panic's message on standard error, never silently
```

## 2. Packages and the registry {#operations-registry}

**A package is a module with `__members__/0`**, the list of its modules that implement a behavior of this file or of any other Macaw behavior (macaw_compose spec/12 §1). Which behavior a member implements is read from its own `@behaviour` declarations, so a package author maintains one list. `Macaw.Data.Operations` is `macaw_data`'s own package: the twelve table operations of §4 and the thirteen statistics of §5.

`Macaw.Data.Operations.registry(packages)` builds the registry, a `%Macaw.Data.Operations.Registry{}`, from an **explicit list** of package modules:

- **Default closed.** `macaw_data`'s own package is always in, since it is the library's own pure code, as `Enum` is the allowlist's (02 §6.2). Anything else is what the list names and nothing more: a module that is merely loaded is not reachable, and no application environment is read.
- **Duplicates fail at build.** Two members of one behavior with one name raise `ArgumentError` naming the name, both modules and their packages; a package listed twice is listed once. So does an aggregate declaring a step's key as its own option (§1.2), and a module `__members__/0` lists that implements none of the behaviors.
- **Names are strings, matched by spelling,** and the registry maps each to its module: `transform(registry, name)` and `aggregate(registry, name)` answer `{:ok, module}` or `:error`; `transforms/1` and `aggregates/1` every name, sorted; `packages/1` the packages, `Macaw.Data.Operations` first; `digest/1` the kernel's term digest of every member's name and module (`Macaw.Layers.Document.digest/1`, never `term_to_binary`, which need not agree across OTP releases), which a compile cache keys by (§6.2); it does not depend on the order members were registered in.
- **A checked step has a canonical identity,** `step_digest(registry, node)`: the kernel's term digest of the transform module its name resolves to and the node `validate/3` checked, options by their strings with defaults filled in. Two nodes that mean the same step have one identity whatever the order their options were written in; the same name resolved to another module has another. A node naming no transform raises `ArgumentError`. It is what a cache of a step's results keys by (macaw_data#9's step keys build on it).
- macaw_compose's registry (step 8) builds on this one for its other behaviors and does not replace it. It knows the packages a host lists but has not enabled, so it is what names the providing package in an unknown name's fault (`transform "sankey" is not available: enable visualize_layouts`); here an unknown name is a fault without one (§3.1).

```test:operations-registry-build
the registry holds macaw_data's own package and exactly the packages listed; a duplicate name, an aggregate declaring a step's key and a member implementing no behavior each raise naming what collides; names resolve by spelling to their module and the digest changes with the members
```

```test:operations-step-digest
the registry's digest is the kernel's term digest of its names and modules; a checked step's identity is the same for the same step written with its options in any order, differs with an option's value and with the module its name resolves to, and a node naming no transform raises
```

## 3. Running {#operations-run}

| Function | Contract |
|---|---|
| `Operations.validate(registry, nodes, context)` | `{:ok, checked}`, every node checked (§3.1), or `{:error, faults}` |
| `Operations.apply(registry, nodes, table, context)` | the context `%{}` by default; the nodes run in order over the table, each step's output the next one's input: `{:ok, table}` or `{:error, faults}`, the validation's |
| `Operations.apply!/4` | as `apply/4`, raising `ArgumentError` naming every fault |
| `Operations.aggregate(registry, name, values, options)` | the aggregate's value of `values`, `nil`s dropped: `{:ok, value}` or `{:error, faults}` |
| `Operations.outputs(registry, nodes, columns, context)` | the columns after every node, by `outputs/2`, the context `%{}` by default: `{:ok, columns}` or `{:error, faults}` |
| `Operations.format_error/1` | one fault as a sentence: `step 2, order: is one of ascending or descending`. Like every fault, it carries no value from the data |
| `Operations.columns/1`, `table/2` | for members: a table's `[{name, type}]`, and the table of rows with given columns, each read by either spelling |

`table` is a `Macaw.Data.Table` or any source `Table.from/2` reads (a list of rows, a map of columns); a node is a map with string or atom keys.

```test:operations-run-apply
apply runs the checked nodes in order, each step's table the next one's input, and refuses before any runs; apply! raises the worded faults; aggregate reduces with nils dropped after checking its options; outputs names the columns; format_error words a fault
```

### 3.1 Validation {#operations-validate}

Every node is checked before any runs, and **every** fault is answered at once, each `{[index, key], reason}`: `index` the node's place in the list, `key` the option's string (`"op"` for the op itself). `aggregate/4`'s faults are at `[key]`, and at `[]` for an unknown name.

| Reason | Meaning |
|---|---|
| `{:unknown, :transform, name}` | the op names no transform in the registry |
| `{:unknown, :aggregate, name}` | an `:aggregate` option names no aggregate in the registry |
| `:required` | a required option, or `op` itself, is missing |
| `{:invalid_for, op}` | the node has a key the op does not read |
| `{:type, type}` | a value the option's type does not hold |
| `{:needs, need}` | the op needs context the caller did not give (`:frame`, `:projection`, `:text`), at `"op"`; or a frame-bound option is `"plot"` and the context has no frame, at that option |
| `:not_a_node` | a node that is not a map, at `[index]` |

A transform whose node names an aggregate (`fn: "quantile"`) is checked with the aggregate's options too: `p` is the node's key, held to `quantile`'s declaration, and a key neither declares is `{:invalid_for, op}`.

A step whose reading is wrong only at run time (a `window` over a column that holds no time, a `stack` over a value that is not a number) **raises `ArgumentError`** naming the step, the option and the reading, as visualize's steps do: the data is the caller's, and the bounded runner reports it as any raise (02 §6.4). A step never catches.

```test:operations-validate-faults
every fault of every node is answered at once at its index and key: an unknown op or aggregate, a missing required key or op, a key the op does not read, a value of the wrong type, an unmet need, and a node that is not a map; format_error words each
```

### 3.2 The context {#operations-context}

The context is plain data, a map:

| Key | Holds | Read by |
|---|---|---|
| `now` | the instant a relative window is measured back from: a `DateTime`, a `NaiveDateTime`, a `Date`, an ISO 8601 string or a number of seconds; absent, a step measures from its own column's newest reading | `window` (§4.3) |
| `schema` | the `Macaw.Data.Schema` of the table the pipeline reads, whose **declared** identity `window`'s `latest` groups by | `window` |
| `sources` | named tables, for a step that reads a second one (a graph's nodes) | the drawer's |
| `frame` | `%{width: w, height: h, center: [x, y]}`, the plot area | frame-bound options; the drawer's layouts |
| `scale` | the `x` scale's kind, `:linear`, `:time` or `:log`: the space the bucket ladder is laid in | `m4`, `lttb` (§4.5.1) |
| `level` | the ladder's level the previous run used, for its hysteresis | `m4`, `lttb` (§4.5.1) |
| `parallel` | `true` to work a step's chunks across the schedulers, above a size threshold; inline when absent | `Step.run/4`, `Cache.run/5` (§1.6), never a step |
| `projection`, `text`, `prepared` | what `needs/0` names, and `prepare/3`'s result | the drawer's |

- **A need is met by its key.** A transform declaring `needs: [:frame]` runs only with `frame` in the context; otherwise its node is `{:needs, :frame}` at validation. A derived source has no frame, projection or text, so a member that needs one is never callable from a stored function (§6).
- **A frame-bound option** (`lttb`'s `n`, `m4`'s `width`) may be written `"plot"` (or `:plot`): the plot's width in whole pixels, `ceil` of the frame's `width`, resolved **before** `run/3` is called, so the step itself is a pure data operation. Without a frame it is `{:needs, :frame}` at that option, never a crash. So `lttb(fields: ["t", "bpm"], n: "plot")` says "one point per pixel" and follows the plot when it is resized.

```test:operations-context-needs
a transform needing a frame runs with one and is refused without one; plot resolves to the ceiling of the frame's width before the step runs and is refused without a frame; now and schema reach the step
```

## 4. Table operations {#operations-table}

Each is a module of `macaw_data`'s package implementing §1.1, ported from visualize's `Chart.Transform.Data` (spec/14 §5.4.1) with its behavior and faults; every visualize test of the step is ported with it. **A column is found by either spelling of its name** (as `Macaw.Data.Table.get/2` reads a row), and a column the rows lack reads `nil`, which the step treats as its section says. A step works its input a chunk at a time, its class named in its section (§1.4). **A step that derives a row from a datum keeps the datum's columns** and adds its own. Each step's **outputs** are named in its section. **Rows pass through a table:** `Table.from/2` reads them at the edge, so a row lacking a column another row has reads `nil` there, and a `Date`, a `NaiveDateTime` or an ISO 8601 string in a time column is a `DateTime` from then on, as everywhere a delivery carries one, and a category's atom is the string that spells it (01 §1.1). `Macaw.Data.Operations.Transforms.all/0` lists the operations, and the package also registers them.

| Op | Options (`*` required) | Section |
|---|---|---|
| `filter` | `field*`, `test`, `value` | §4.1 |
| `take` | `n*`, `side` | §4.2 |
| `window` | `field*`, `from`, `to`, `latest` | §4.3 |
| `lttb` | `fields*`, `n*` | §4.4 |
| `m4` | `fields*`, `width*` | §4.5 |
| `sort` | `field*`, `order` | §4.6 |
| `fold` | `fields*`, `as` | §4.7 |
| `stack` | `fields*`, `order`, `offset` | §4.8 |
| `bin` | `field*`, `thresholds`, `as`, `fn` | §4.9 |
| `aggregate`, `sum` | `field*`, `fn*` (`aggregate` only), `by`, `as` | §4.10 |
| `spectrum` | `field*`, `time`, `every`, `samples`, `window`, `detrend`, `as` | §4.11 |

```test:operations-table-package
the table operations are macaw_data's transforms, in the table's order, each needing nothing and registered under its name; each one's outputs name the columns its run answers
```

### 4.1 filter {#operations-filter}

`field` (`:field`, required); `test` (`{:enum, [:eq, :ne, :lt, :lte, :gt, :gte, :present, :absent]}`, `:present`); `value` (`:term`, `nil`). The rows, in order, whose reading of `field` passes the test against `value`:
- `present` keeps a reading that is not `nil`, and `absent` one that is;
- `eq` keeps a reading equal to `value` and `ne` one that is not. A category is one value whichever spelling a row or the node gives it, so `:ok` equals `"ok"` (an atom and a string are equal when the atom's string is the string; `Macaw.Data.Operations.same?/2`);
- `lt`, `lte`, `gt` and `gte` keep a reading that is not `nil` and stands so to `value` under Elixir's term ordering, as `sort` orders. **A `nil` reading never passes an ordering.**

The test is `test`, not `op`, because `op` names the step. A column the rows lack reads `nil`, so `filter(field: "height", test: :eq, value: 0)` after a hierarchy keeps its leaves. **Outputs:** the input's columns. **Class:** per row (§1.4), each chunk decided from `field`'s column alone: a chunk every row of which passes is passed through, one none of which passes is dropped, one whose passing rows are one run is cut to that run without copying, and any other gathers the rows that pass. **A packed number column with no value missing** is tested by an ordering against a number by scanning its values buffer as it lies, nothing decoded (macaw_data#41); any other column or test reads the values one by one, in one pass.

```test:operations-filter-scan
for generated number columns with and without gaps, integer and float, every test and value keeps exactly the rows reading value by value keeps; rows that pass as one run are cut from the chunk, rows apart gathered; an ordering over an all-valid float column costs at most 3 reductions a row
```

```test:operations-filter-tests
each test keeps exactly its rows in order: present and absent by nil, eq and ne by value with an atom equal to its string, the orderings by term order with nil never passing; a missing column reads nil
```

#### 4.1.1 The mask and the gather in native kernels {#operations-filter-native}

**`filter`'s selection, and the gather of the rows it keeps, run in native kernels where the kernels are loaded** (§1.7, macaw_data#38). `Filter.chunk/3` hands the view's column to `filter_mask`, which reads it in place and answers the selection itself (`:all`, `:none`, `{:run, a, n}`, or `{:rows, indexes}`), so a chunk is passed through, dropped, cut or gathered exactly as on the Elixir path:
- **`present` and `absent`** read only the validity bitmap, of any column whose bitmap alone says which rows are `nil` (every packed form but the int/float union and `:list`).
- **An int64 or float64 column against a number** (an integer within int64, or a float) compares each reading as Erlang compares numbers: exactly, an integer against a float too, past 2^53 included. **Against any other value**, every number stands to it as the term order puts numbers, below every other type, so the Elixir path's test of one number is every reading's answer.
- **A dictionary of strings** (no booleans beside it) is tested once per dictionary string, by the Elixir path's own test (`eq` and `ne` with `same?/2`'s spellings, the orderings by term order), and each row reads its code's answer.
- A missing row passes as the Elixir path's test of `nil` answers. Any other column or test (the union, an integral column's orderings, a time against a time, a dictionary with booleans) is the Elixir path's, and so is a float buffer holding a value that isn't finite (`:fallback`).

**The gather** of a chunk's columns at the rows kept (`Column.gather/2`, so every gather and reshape) copies each fixed-width buffer's slots (`take`) and each bitmap's bits (`take_bits`) at the indexes, in their order, repeats allowed, the bits packed least-significant first with zero padding: the Elixir path's bytes. An index past its buffer is a fault, raised. A text column's offsets and data, and the macaw forms' children, are gathered on the Elixir path from those.
- **Its cost:** no column is decoded and no bitmap expanded; a few nanoseconds a row and a term an index kept. A call over at most `Native.sync_rows/0` rows or indexes runs on a normal scheduler, within 1 ms; a larger one on a dirty CPU scheduler.

```test:operations-filter-native-identical
for generated int, wide int, float, union, category, category with booleans, text and time columns with nils, every test and values of every kind (small and past int64 numbers, strings, atoms, nil, a time), chunked several ways and viewed from an offset, the kernel's selection equals the Elixir path's and it answers every form it reads; an integer against a float compares exactly past 2^53; the steps' tables are equal with and without the kernels; a gather at any indexes equals Column.gather/2's slot for slot and bit for bit
```

```test:operations-filter-native-bound
a mask over sync_rows/0 rows, 8,192, and a gather of half as many indexes take under 1 ms on a normal scheduler, a larger view runs dirty with the Elixir path's selection, and an index past its buffer raises
```

### 4.2 take {#operations-take}

`n` (`{:integer, 0}`, required); `side` (`{:enum, [:end, :start]}`, `:end`). The last, or the first, `n` rows in order. An `n` at or above the row count is every row, and `n` of zero is none; a negative `n` is `{:type, {:integer, 0}}`. A design that shows the newest reading beside its history reads `take(n: 1)`. **Outputs:** the input's columns. **Class:** per row (§1.4), reading no column: each chunk's run is resolved from where it sits and the input's count, so a chunk it does not return is never read, and its work grows by a step a chunk, never with the rows.

```test:operations-take-ends
take keeps the last n rows by default and the first with side start; n at or above the count is every row, zero is none, and a negative n is refused
```

### 4.3 window {#operations-window}

`field` (`:field`, required: a time column); `from` and `to` (`:duration`, `nil`), each a duration **ago** as `[n, unit]`, a unit the seconds it names: a `second` is 1, a `minute` 60, an `hour` 3,600, a `day` 86,400, a `week` 604,800 and a `year` 365 days, 31,536,000. A window is an extent of time, not a calendar walk. `latest` (`:boolean`, `false`).

The rows whose reading of `field` lies in **`[now − from, now − to)`**, in order:
- **A given `to` is exclusive**, which stops two adjacent windows sharing a row: `window(from: [1, :year], to: [24, :hour])` and `window(from: [24, :hour], to: [1, :hour])` are disjoint and contiguous.
- **An absent `to` closes the window at `now`, inclusively**, so `window(from: [15, :minute])` is the last fifteen minutes up to now and holds the newest reading.
- **An absent `from` is open** at the old end.

So four windows of decreasing span partition a column exactly.
- **`now`** is the context's `now` (§3.2) when given, else the newest reading of `field` over the rows entering the step. A live dashboard means the wall clock and a test means the data's own end, and only the caller knows which. A derived source's context has no clock (02 §2.3), so in a stored function a window is measured from its data's newest reading.
- **Readings** are seconds: a `DateTime`, a `NaiveDateTime` (as UTC) and a `Date` (at midnight UTC) by their instant, an ISO 8601 string as `Table.temporal?/1` reads one, a number as it is. A `nil` reading is skipped. Any other reading raises `ArgumentError` naming the step and the field.

**`latest: true`** asks for each entity's current state: of the rows the window selects, for each identity value, the one row whose reading of `field` is greatest, the later row in order where two tie, kept in their order. It is what a request's `latest` gives (01 §2.4), by the same function, `Macaw.Data.Window.latest_rows/3`. The identity is the one the context's `schema` **declares** (`Macaw.Data.Schema.identity/2`), never inferred, and a row whose identity is `nil` names nothing and is dropped. A `latest` step without a schema in its context, or over a schema declaring no identity, raises `ArgumentError` naming the step. Dropping the entities that are gone is a `filter` after it. **Class:** a combine (§1.4). Each chunk's partial is, of the rows the window selects in it, each identity's newest; two runs' partials merge by keeping the greater reading, the second run's on a tie, so ties are broken by chunk order and then by row order, as the rows' order breaks them. The rows kept are gathered from their chunks, in their order.

**Outputs:** the input's columns.

**Class:** without `latest`, per row (§1.4). `now` and the window's bounds are bound over the whole input once; then, for each chunk:
- **a chunk wholly inside the window** passes through unchanged, and its step key holds no `now`, so it holds across frames;
- **a chunk wholly outside it** is dropped;
- **only an edge chunk is cut,** keyed by its slice bounds. Over the column the input is known to be sorted by (`Table.sorted/1`: a source's window field, kept by every per-row step), the bounds are found by binary search, a few readings a chunk, and the chunk is cut to a run without copying; the newest reading is found from the end the same way. Any other column is scanned, every reading read.

```test:operations-window-sorted
over a table sorted by its window field, window binary-searches each chunk, reading a few values a chunk rather than every one, and cuts an edge chunk to a run of it; over an unsorted column it scans and gathers, and the two agree
```

```test:operations-window-spans
a window selects [now - from, now - to): a given to is exclusive, an absent to closes at now inclusively, an absent from is open, so adjacent windows partition the rows; now is the context's or the newest reading; every reading form is read in seconds and any other raises; a bad unit is refused
```

```test:operations-window-latest
latest keeps each declared identity's newest row in the window, the later on a tie, in order, dropping a nil identity; without a schema, or with one declaring no identity, it raises naming the step
```

### 4.4 lttb {#operations-lttb}

`fields` (`{:pair, :field}`, required: `[x, y]`, the two columns a line reads); `n` (`{:integer, 3}`, frame-bound, required). **Shape-preserving downsampling** by **MinMaxLTTB** (Van Der Donckt et al., 2023): the least and greatest row of each bucket of the ladder (§4.5.1) are preselected, and Largest-Triangle-Three-Buckets (Steinarsson 2013, `Macaw.Data.Reduce.lttb/3`) selects `n` rows from them. **This is a breaking change** from the exact algorithm over every row (macaw_data#9), recorded with its tolerance; the exact algorithm stays as the function `Macaw.Data.Reduce.lttb/3`, which visualize's sandbox (`lttb/2,3`) calls, and is the oracle the step is held to.
- **The level** is the ladder's coarsest whose bucket is at most `span / (2n)`, `span` the extent of `x` in the scale's space: at least `2n` buckets, so at least `4n` candidates (a preselection ratio of 4). Each run's first and last rows are candidates too.
- **The contract:** at most `n` rows when the rows have no gaps (with gaps, `n` is shared among the runs between them as `Reduce.lttb/3` shares it, and each run of gap rows keeps its first row in place, so a line still breaks where the input broke); the first and the last row kept; deterministic, the same rows under every chunking, inline or cached; input of `n` or fewer rows returned unchanged. An `n` below 3 is refused, since a line needs its two ends and a point between to have a shape.
- **Faithful within a tolerance:** the mean absolute error of the reduced line, read by linear interpolation at every input row's `x` and divided by the extent of `y`, is at most twice `Reduce.lttb/3`'s with the same `n`, plus 0.005. Measured over 2,700 generated series (sines with noise, random walks, sparse spikes; `n` of 20, 60 and 150), the worst ratio was 1.27 for sines, 1.37 for walks and 1.56 for spikes at the smallest `n`.
- an `x` reads in the scale's space (§4.5.1), a number or a time; a `y` as a number. Any other reading raises `ArgumentError` naming the step and the field;
- **whole rows are kept,** every column of each, so a tooltip over a kept point reads the datum itself. O(n) in the rows.

**Outputs:** the input's columns. **Reducer:** `{"n", 1}`. **Class:** a combine (§1.4): each chunk's partial is its buckets' extremes, partials merge by concatenation (§4.5.1), and the selection runs in `finish/3`, over the candidates in one pass.

```test:operations-lttb-shape
lttb keeps the ends and at most n rows, whole; n or fewer rows come back unchanged; gaps pass through with each run of gaps kept as its first row; a time column under a linear scale reads in seconds and a non-number y raises; n below 3 is refused
```

```test:operations-lttb-minmax
lttb is MinMaxLTTB: for generated series and several n, its mean interpolation error is within twice Reduce.lttb's plus 0.005, it keeps at most n rows, the first and the last, and it answers the same rows under every chunking
```

### 4.5 m4 {#operations-m4}

`fields` (`{:pair, :field}`, required); `width` (`{:integer, 1}`, frame-bound, required). Per pixel column the **first, last, minimum and maximum** rows, as `lttb` reads them, deduplicated and in input order. The columns split the extent of the `x` readings in the scale's space. When that is the drawn `x` domain, the reduced line **draws the pixels of the unreduced one** to within a bucket at each column boundary: every column it crosses, with its top, bottom, entry and exit, so a peak is never lost. It is the right choice where one must not be lost: an alert threshold, a heart-rate maximum. `width: "plot"` is what a design means nearly always; an integer is for one reduced for a size it knows. Gaps, readings, faults, whole rows and the cost are `lttb`'s.

- **On the ladder** (§4.5.1): the level is the coarsest whose bucket is at most a quarter of a pixel (`span / width / 4`). Each chunk's partial is its buckets' first, last, least and greatest rows; the merge folds each bucket into the pixel column its start lies in.
- **Accuracy:** the answer is exactly M4 over pixel columns whose boundaries are moved to a bucket edge, each at most one bucket away: at most a quarter of a pixel, half a pixel under hysteresis. Where the buckets' edges are the pixels' edges it is `Macaw.Data.Reduce.m4/3`'s answer exactly. This is a change from M4 over the rows themselves, within that tolerance.

**Outputs:** the input's columns. **Reducer:** `{"width", 4}`. **Class:** a combine (§1.4).

```test:operations-m4-columns
m4 keeps each column's first, last, minimum and maximum rows, deduplicated in order, so every extreme survives within a bucket of its column; gaps, readings and faults are lttb's; width below 1 is refused
```

```test:operations-m4-ladder
on linear, time and log scales, m4 is exact M4 over pixel columns whose boundaries move to the bucket edge at most one bucket away, and Reduce.m4 itself where the bucket edges are the pixel edges; a bucket straddling a chunk edge merges to the one-chunk answer
```

#### 4.5.1 The bucket ladder {#operations-ladder}

`m4` and `lttb` reduce on **one absolute ladder of buckets** (macaw_data#9 §5, `Macaw.Data.Operations.Transforms.Ladder`), so a chunk's partial depends on its rows, the scale's kind and the level alone, never on the data first read, the extent or a restart:
- **The scale's space** is the context's `scale` (§3.2), which each step declares it reads: `:linear`, `x` as a number or a time in seconds; `:time`, a time in microseconds since the Unix epoch (a number read as seconds); `:log`, `log2` of an `x` above 0, any other raising `ArgumentError` naming the step. Without one, `:time` over a `:time` column and `:linear` otherwise. On a log scale, buckets in log space have even pixel widths.
- **A bucket** at level `k` (any integer, negative too) is `2^k` wide from origin 0: `s` lies in bucket `floor(s / 2^k)`, computed exactly.
- **The level** is the coarsest whose bucket is at most the step's ideal width, from the span (the extent of `x` in the space, read at the ends of a sorted column, else scanned) and its count. **Hysteresis:** the previous level, the context's `level` (§3.2), is kept while its bucket is within a factor of 2 of the ideal width, so a span drifting near a power of two keeps one level and its partials. The level a run used is in each part's resolved context (`Step.parts/4`), for the caller to pass back.
- **A zoom within a level** changes no partial and no step key: the extent and the pixel width enter only the merge. **A zoom out** folds finer partials into the coarser level (`Ladder.coarsen/2`) exactly as computing them there would; partials at two levels merge at the coarser. Only a zoom in computes again.
- **A chunk's partial is one pass over its rows** (macaw_data#41): the bucket's width is read once a partial, an integer `s` at a level `k` of 0 or above lies in bucket `s >>> k` (an arithmetic shift, which is the floor) and below 0 in `s <<< -k`, and a row landing in the open bucket allocates nothing unless it is the bucket's new least or greatest. The partial is the definition's: each run's buckets, `floor(s / 2^k)`, with their first, last, least and greatest points.
- **Chunk edges** needn't align with buckets: a bucket straddling one gets a partial from each chunk, and the merge combines them. **Gaps** split the rows into runs; a run of gap rows is one gap kept as its first row, and a gap on a chunk boundary is kept, the merge joining runs and gaps across the edge.
- **A partial is ordered, and a merge costs the chunks, not the buckets** (macaw_data#39). A partial holds a piece per view, in chunk order: the view's runs and gaps in row order, each run's buckets **ascending by bucket**, each once, every point's ref its row within the view. `combine/2` concatenates the two partials' views and pieces, the second's view indexes moved past the first's, and reads no bucket, so it costs a constant per chunk whatever the buckets each holds; any grouping of the same partials gives the same partial. Since a source's table is sorted by its window field, adjacent chunks share at most the boundary bucket, so the chunk edges are joined **once, when the merged partial is read** (`Ladder.runs/1`): a run continuing across an edge is one run, the bucket it straddles has its two summaries merged, and two gaps meeting at an edge are one gap. Rows whose `x` is not in order still answer exactly: a chunk's run is made ascending when it is computed, and runs whose buckets overlap across chunks are merged bucket by bucket when read. `coarsen/2` is one pass over each run. `finish/3` reads the merged buckets once: `m4` folds them into pixel columns in order (a bucket's column never falls as the bucket rises), and `lttb` takes its candidates in input order, sorting only rows out of order.

```test:operations-ladder-levels
the level is the coarsest whose bucket is at most the ideal width; with the previous level given, a span oscillating around a power of two keeps one level and every unchanged chunk keeps its step key; a zoom within a level keeps every key, and a zoom out folds finer partials into the coarser level's exactly
```

```test:operations-ladder-merge
combining two chunks' partials costs the same reductions whether each holds ten buckets or thousands, and every grouping of a table's partials gives the same merged partial; rows whose x is out of order, chunked any way, give m4 and lttb the one-chunk answer
```

```test:operations-ladder-walk
for generated rows on linear, time and log scales, with gaps, repeated and out-of-order x, integer and float readings, and levels below and above 0, a chunk's partial equals one built from the definition; a sorted chunk of integer x and float y costs at most 12 reductions a row, its two columns' decoding included, and 1.5 a bucket packing its piece (§4.5.3)
```

```test:operations-ladder-gaps
a gap on a chunk boundary survives m4 and lttb, which answer under every chunking as over one chunk
```

#### 4.5.2 The ladder partial's native kernel {#operations-ladder-native}

**A chunk's partial is computed by a native kernel where the kernels are loaded** (§1.7, macaw_data#38). `Ladder.partial/4` hands the view to it when both columns are in a form it reads, on a linear or time scale:
- **x:** int64, float64, timestamp[us] (a UTC, zoned or naive instant's microseconds) or date32. **y:** int64 or float64. Validity is read from each column's bitmap in place, a view's rows counted from its first slot. The `:log` scale, whose `log2` per row must equal `:math.log2/1`, and every other form stay on the Elixir walk.
- **Its answer is the Elixir walk's piece, byte for byte as packed (§4.5.3):** the same segments, runs and gaps, each run's buckets ascending and each once (a run out of x order sorted by bucket and each bucket's summaries merged, as `summary/2` merges them), and every point's `s` and `y` an integer where the walk's is one and the same float where it is a float. `s` follows `space/3` operation for operation: microseconds over 1,000,000 as a float on a linear scale, days times 86,400.0, a float x times 1,000,000.0 on a time scale.
- **It hands the view back** (`:fallback`) where the walk would answer with an integer past 64 bits or raise: an x times 1,000,000 past int64, an integer shifted left past it, a float quotient whose floor is past it, a level whose `2^k` is no float's exact power of two. The Elixir walk then answers, so those edges are its own.
- **Its cost:** the view's columns are never decoded and no bitmap is expanded; the kernel's time is not counted in reductions. A call over at most `Native.sync_rows/0` rows runs on a normal scheduler: a few nanoseconds a row, and at worst, every row its own bucket, about half a millisecond building the answer. A larger view runs on a dirty CPU scheduler.

```test:operations-ladder-native-identical
for generated rows of every x form the kernel reads, on linear and time scales, with gaps, unsorted x, integer and float y, views at an offset and levels from far below 0 to past a float's exponent, the partial equals the Elixir walk's term for term, and the kernel answered every view it can
```

```test:operations-ladder-native-bound
a call over sync_rows/0 rows, 8,192, each its own bucket, the largest answer a call builds, takes under 1 ms on a normal scheduler, and a view past sync_rows runs on a dirty scheduler with the same answer
```

#### 4.5.3 Packed pieces {#operations-ladder-packed}

**A partial's piece is one binary** (macaw_data#38, #46; `Ladder.Packed`), so a partial a caller's cache holds is a few words on its heap and a binary off it, whatever its buckets, and its merge reads buffers. The Elixir walk packs its segments; the native kernel (§4.5.2) writes the same bytes. Little-endian throughout:
- **A header,** 8 bytes: `1`, then the points' `s` type and `y` type (`0` every one an int64, `1` every one a float64; both `0` with no bucket), a zero byte, and the count of segments (u32).
- **A head a segment,** in row order, 8 bytes: a gap is `0`, three zero bytes and its first row (u32); a run is `1`, three zero bytes and its count of buckets (u32).
- **The runs' buckets,** in order, 88 bytes each: the bucket (i64), then its first, last, least and greatest points, each its row (u32), `s` and `y` (8 bytes each, of the header's types).
- **A piece whose points aren't of one type,** or whose bucket or integer `s` is past int64 (a macaw form's mixed readings, a log scale's far bucket), is `2` followed by the segments in the external term format, every value kept exactly as the walk answered it.

`combine/2` concatenates pieces and reads none; `runs/1` reads each piece once into its buckets as its view's, and `coarsen/2` reads, folds and packs again. A piece read back is the walk's segments, term for term.

```test:operations-ladder-packed-read
for generated segments of either number type, mixed types, values past int64, gaps and runs, a piece packed and read back is the segments, term for term, and read as a view's it is each gap and bucket with that view
```

#### 4.5.4 The finishes' native kernels {#operations-ladder-finish}

**`m4`'s and `lttb`'s finishes run in native kernels where the kernels are loaded** (§1.7, macaw_data#38). `finish/3` hands the merged partial's packed pieces (§4.5.3), coarsened to the step's level, to `m4_finish` or `lttb_finish`, which read them in place and answer the refs the step gathers:
- **The merge read** is `Ladder.runs/1`'s: a run ending one piece and one starting the next are one run, the bucket they share merged by `summary/2`; a gap ending one and one starting the next are one gap, the first; a run whose buckets fall out of order across pieces is sorted by bucket and each bucket's summaries merged.
- **`m4`:** each run's buckets folded into the pixel column their start lies in, `floor((b·2^k − lo) / (hi − lo) · width)` clamped to `[0, width − 1]` (every bucket column 0 when the extent is a point or none), and each column's first, least, greatest and last refs, with each gap's. The refs are the Elixir path's (`M4.refs/3`) as a set, which is all the gather reads.
- **`lttb`:** the candidates of `Lttb`'s Elixir path, each run's first and last points and each bucket's least and greatest, each once in input order, with each gap; then `Reduce.lttb/3` to `n` over them: the run's share `max(min(len, 2), floor(n·len / defined))`, the canonical algorithm's buckets of `every` points, each bucket's mean point summed from the integer 0 and the largest triangle, earliest on a tie. The refs are the Elixir path's (`Lttb.refs/2`), in order.
- **Its arithmetic is Erlang's, operation for operation:** two integers stay an exact integer; an integer meeting a float is first converted to the nearest float; `/` is a float division; floats in Zig's strict mode, no expression reordered or contracted. The expression order is `column_of/3`'s and `Reduce`'s.
- **It hands the partial back** (`:fallback`) where it can't answer exactly that way: a piece kept as a term (§4.5.3), pieces whose points are of different types, an extent or an intermediate integer past int64, a level above 62 or below −1074 (a bucket no int64 or float multiplies exactly), and anything Erlang would raise on (a float that is not finite, a division by zero). The Elixir path then answers.
- **Its cost:** tens of nanoseconds a bucket, no term built but the refs it answers. A call over at most `Native.finish_buckets/0` buckets (2,048) runs on a normal scheduler, within 1 ms even when every bucket gives `lttb` two candidates; a larger one on a dirty CPU scheduler (`Native.finish_scheduler/1`).

```test:operations-ladder-finish-identical
for generated rows of int, float and time x on linear, time and log scales, integer and float y, gaps, unsorted and repeated x, chunked several ways, at several widths, n and levels, m4_finish's refs equal M4.refs/3's as a set and lttb_finish's equal Lttb.refs/2's in order, the kernels answering every such partial, and the steps' tables equal with and without the kernels; a piece kept as a term, or an extent past int64, is handed back
```

```test:operations-ladder-finish-bound
a finish over finish_buckets/0 buckets, 2,048, each giving lttb two candidates, takes under 1 ms on a normal scheduler, and a larger one runs on a dirty scheduler with the Elixir path's refs
```

### 4.6 sort {#operations-sort}


`field` (`:field`, required); `order` (`{:enum, [:ascending, :descending]}`, `:ascending`). The rows **stably** sorted by the reading of `field` under `Enum.sort_by/3`'s term ordering, in that direction. **Outputs:** the input's columns. **Class:** global (§1.4): each chunk's readings of `field`, then every row sorted and gathered across the chunks.

```test:operations-sort-stable
sort orders rows by the field ascending or descending under term order, keeping equal readings in their input order
```

### 4.7 fold {#operations-fold}

`fields` (`{:list, :field}`, required); `as` (`{:pair, :name}`, `["key", "value"]`). Wide columns to long rows: **one output row per input row per listed column the row has**:
- a listed column the rows lack is skipped, never a fault. That is how a design says "these, if they exist";
- a row's `nil` in a folded column yields no row for it;
- the row's other columns are carried unchanged, the folded columns dropped by spelling;
- the folded column's name goes under the first name of `as`, as the node spells it, and its value under the second;
- rows come in input order, and within a row the columns in the order `fields` lists them, so the series order is the author's.

**Outputs:** the input's columns without the folded ones, then `as`'s two: the key a `:category`, the value the folded columns' type when they share one, else `:term`. **Class:** a per-row reshape (§1.4): each chunk's rows gathered with repeated indexes, the key and value columns added.

```test:operations-fold-long
fold makes one row per input row per listed column it has, in row then field order, carrying the other columns, skipping a missing column and a nil reading, under the as names
```

### 4.8 stack {#operations-stack}

`fields` (`{:list, :field}`, required: the series keys); `order` (`{:one_of, [{:enum, [:none, :ascending, :descending, :inside_out, :reverse, :appearance]}, {:keys, {:list, :field}}]}`, `:none`); `offset` (`{:enum, [:none, :expand, :silhouette, :wiggle, :diverging]}`, `:none`). d3-shape's stack (`Macaw.Data.Stack`, ported from `Visualize.Shape.Stack`), each series' value its reading, `nil` read as `0`; a reading that is neither raises `ArgumentError` naming the step.

**The order** is a permutation of the series, bottom first:
- `none`: `fields` order;
- `reverse`: its reverse;
- `ascending` and `descending`: by each series' sum, stably;
- `appearance`: d3's `stackOrderAppearance`, ascending by the index of each series' first greatest value, stably;
- `inside_out`: d3's `stackOrderInsideOut`. In order of appearance, each series joins the top when the top's sum is less than the bottom's, else the bottom; the order is the bottom reversed, then the top;
- `{:keys, [k, …]}` (a node may write `%{keys: [...]}`): a fixed order, the listed keys bottom first, then the keys it does not list in `fields` order. A listed key not in `fields` is ignored.

Every order but `keys` is computed from the rows the step is given, so over a streaming source it is computed afresh each time, and a layer can change places. A design whose layers must hold their places fixes them with `keys`.

**The offset** sets the baselines:
- `none`: each series sits on the previous one's top from zero;
- `expand`: each column normalized to sum to 1 (a column summing to 0 stays 0);
- `silhouette`: centered on zero;
- `wiggle`: Byron and Wattenberg's streamgraph baseline, which minimizes the weighted change in slope;
- `diverging`: positives stack up from zero and negatives down, each apart, and a zero sits at zero.

**The cost is linear in the rows** for every order and offset (#126): the offsets that read a column across the series (`expand`, `silhouette`, `diverging`) take the points column by column once, never by index, and `expand` normalizes as it stacks, so the points are copied once.

```test:operations-stack-linear
every offset's work is linear in the rows, four times the rows under five times the work; every offset over twenty thousand rows answers in a stored function within the runner's default bounds
```

**Rows:** one per series in `fields` order, per datum in data order: the datum's columns plus `key` (the series' key), `series` (its stacking position, 0 the bottom), `value`, `y0` and `y1`, the names visualize's marks read. **Outputs:** the input's columns, then `key` (`:category`), `series`, `value`, `y0` and `y1` (`:number`). **Class:** global and a reshape (§1.4): each chunk's readings of the series, the offsets stacked across every row, the datum's columns gathered with repeated indexes and the stack's columns added.

```test:operations-stack-orders
every order and offset matches d3-shape's on the reference fixtures, keys fixed and the others computed from the rows; nil reads as zero and a non-number raises; each row carries the datum's columns and its key, series, value, y0 and y1
```

### 4.9 bin {#operations-bin}

`field` (`:field`, required); `thresholds` (`{:one_of, [{:integer, 1}, {:list, :number}]}`, `10`); `as` (`:name`, `"count"`); `fn` (`:aggregate`, `nil`) and the named aggregate's options. The readings of `field` with `nil`s dropped, binned:
- **The domain** is the readings' extent `[d0, d1]`.
- **An integer `n` thresholds** is `n` equal-width bins: `n − 1` inner thresholds at `d0 + i · (d1 − d0) / n`. A list is the inner thresholds as given.
- **A reading belongs to** the first bin `[x0, x1)` holding it, or to the last bin when it equals the domain's maximum.
- One row per bin, in order: `x0`, `x1`, `y0` (`0`, so a histogram's channels read the rows alone), `as` and `values` (the bin's readings, in input order).

`as` holds the bin's count, or, with `fn`, the named aggregate of the bin's readings (`bin(field: "latency", fn: "median")`), an empty bin's being that aggregate's empty value (§5). No readings yield no rows; a reading that is not a number raises `ArgumentError` naming the step.

**Outputs:** `x0`, `x1`, `y0` (`:number`), `as` (`:number`, or the aggregate's output type) and `values` (`:term`). **Class:** counting, or with an `fn` that has the combining form (§1.2), a combine (§1.4): the bins are bound over the whole input's extent once, each chunk's readings are binned into each bin's count or state and its readings in order, and the bins merge, states by the combining form and readings in chunk order. With any other `fn` (`median`, `quantile`, `distinct`, …) it is global (§1.4): each chunk's readings binned, and every bin's readings reduced at once in the merge.

```test:operations-bin-counts
bin splits the extent into n equal bins or at the given thresholds, each reading in its half-open bin and the maximum in the last, counting by default or reducing each bin's readings by fn; no readings yield no rows
```

### 4.10 aggregate and sum {#operations-group}

`aggregate`: `field` (`{:one_of, [:field, {:pair, :field}]}`, required); `fn` (`:aggregate`, required) and the named aggregate's options; `by` (`{:one_of, [:field, {:list, :field}]}`, `nil`); `as` (`:name`, the aggregate's name).
- **Groups:** one row per distinct value of `by` (a list of fields groups by every one), in order of first appearance, a `nil` value a group of its own. The row holds `by`'s columns and, under `as`, the aggregate of the group's readings of `field`, `nil`s dropped. Without `by`, one row holds `as` alone.
- **A pair field** `[x, y]` reads each row as the point `[x, y]` for an aggregate that reads points (`slope`, §5), `x` in seconds when it is a time. A row whose `x` or `y` is `nil` is dropped.

`sum` is **`aggregate` with `fn: "sum"`**: `field`, `by` and `as` (`"sum"`), no `fn`. It is vocabulary a design writes, not an alias kept for compatibility, so it is never deprecated.

**Outputs:** `by`'s columns with their input types, then `as` of the aggregate's output type. **Class:** `sum`, and `aggregate` with an `fn` that has the combining form (§1.2: `count`, `sum`, `mean`, `min`, `max`, `extent`), is a combine (§1.4): each chunk's groups in order of first appearance, each with its state, and two runs' groups merged, the first run's order first and each group's states by the combining form. With any other `fn` it is global (§1.4): each chunk's keys and readings, and every group's readings reduced at once in the merge. **A chunk's groups are found in one pass** (macaw_data#41): a row's group is looked up and its state, first row and count updated together, once a row; grouped by one category column, the rows are grouped by the column's dictionary codes and each group named by its string once.

```test:operations-group-chunk
for generated rows, aggregate with count, sum and mean by a category column, by a number column, by two columns and by none gives each chunk's groups in order, their states, first rows and counts as grouping row by row does; summing a chunk of 8192 rows by a category column costs at most 16 reductions a row
```

```test:operations-group-rows
aggregate makes one row per distinct by value in order of first appearance, or one row without by, holding the named aggregate of the group's non-nil readings; a pair field reads points; sum equals aggregate with fn sum
```

### 4.11 spectrum {#operations-spectrum}

`field` (`:field`, required: the sample column); `time` (`:field`, `nil`); `every` (`:positive`, `nil`: the seconds between samples); `samples` (`:power_of_two`, `nil`); `window` (`{:enum, [:hann, :hamming, :none]}`, `:hann`); `detrend` (`:boolean`, `false`); `as` (`{:one_of, [{:list, :name}, :name]}`, `["frequency", "magnitude"]`).

A time series to its **one-sided amplitude spectrum** by a radix-2 Cooley–Tukey FFT, `Macaw.Data.FFT` (ported from `Visualize.Data.FFT`; pure Elixir, `O(N log N)`):
- **The sample interval** is `every` when given; else the median positive gap between consecutive non-`nil` readings of `time` (`DateTime`s in seconds, numbers as they are); else `1`.
- **The samples:** the newest `samples` rows with a numeric reading of `field`. When `samples` isn't given, that is the largest power of two not above their count. Fewer than two, or fewer than `samples`, yield no rows.
- **Detrending:** with `detrend: true`, the samples' mean is subtracted first, so an offset doesn't leak from the DC line into the bins beside it.
- **The taper:** `hann` is `0.5 − 0.5 cos(2πi/(N−1))` and `hamming` is `0.54 − 0.46 cos(2πi/(N−1))`. A sequence shorter than four is not tapered.
- **The lines:** the samples are transformed and read as `samples / 2` lines, `k` from 0. A line's frequency is `k / (samples · every)` hertz. Its magnitude is `|X_k| · 2 / (samples · gain)`, where `gain` is the window's mean, and the DC line is not doubled. Its phase is the argument of `X_k`.

Each row holds `as`'s names for the frequency and the magnitude, and a third name, when `as` gives one, for the phase. A single name is the frequency's, with the magnitude `"magnitude"`; a list of any other length raises `ArgumentError` naming the step.

**Outputs:** the `as` names, `:number`. **Class:** global (§1.4): each chunk's readings of `field` and `time`, the transform over the newest samples of all of them.

```test:operations-spectrum-lines
a sine's spectrum peaks at its frequency with its amplitude under every window; the interval is every, else the time column's median gap, else 1; samples default to the largest power of two and are refused when not one; detrend removes the DC leak; as names two or three columns
```

## 5. Statistics {#operations-statistics}

Each is an aggregate of `macaw_data`'s package implementing §1.2 (`Macaw.Data.Operations.Aggregates.*`), ported from `Visualize.Data` and matching visualize's function on its fixtures. The readings come with `nil`s dropped (§1.2). A **number** is an integer or a float; a **time** a `DateTime`, `NaiveDateTime` or `Date`, compared as instants (`Macaw.Data.Window.compare/2`). A numeric column of a table is read from its packed binary without building a row list.

| Name | Options | Value | Of no readings | Output type | Unit |
|---|---|---|---|---|---|
| `count` | | the number of readings | `0` | `:number` | dropped |
| `distinct` | | the number of distinct readings (`===`, a category by spelling) | `0` | `:number` | dropped |
| `min` | | the least reading, numbers or times | `nil` | the input's | kept |
| `max` | | the greatest | `nil` | the input's | kept |
| `extent` | | `[min, max]` | `nil` | `:term` | kept |
| `sum` | | the sum of numbers, exact: integers as an integer; with a float among them, the exact sum rounded once to the nearest float, ties to even | `0` | `:number` | kept |
| `mean` | | the arithmetic mean, a float: the exact sum over the count | `nil` | `:number` | kept |
| `median` | | the middle of the sorted readings; of an even count, the mean of the two middles | `nil` | `:number` | kept |
| `quantile` | `p` (`{:number, 0, 1}`, required) | linear interpolation between the sorted readings: at `i = (n − 1) · p`, `v[⌊i⌋] + (v[⌊i⌋+1] − v[⌊i⌋]) · (i − ⌊i⌋)`, the last index clamped | `nil` | `:number` | kept |
| `variance` | | the sample variance, `Σ(v − mean)² / (n − 1)` | `nil`, and `nil` of one | `:number` | dropped |
| `deviation` | | the square root of `variance` | `nil`, and `nil` of one | `:number` | kept |
| `slope` | | the least-squares slope of the points: a number `v` at place `i` is the point `[i, v]`, a reading `[x, y]` (or `{x, y}`) the point itself | `nil`, and `nil` of one point or when every `x` is equal | `:number` | dropped |
| `delta` | | the last reading minus the first | `nil` (`0` of one) | `:number` | kept |

- **A unit carries** where the value is of the reading's own kind: a min, a mean or a deviation of milliseconds is milliseconds. Where it is not, it is dropped: a count, the square of a unit, a rate per sample. A host drawing a sum still holds it to the quantity's additivity ([03 §10](03-units.md#quantities-additivity)): a sum of a quantity that does not add across or over time is the host's to refuse, not the statistic's.
- **A reading of the wrong kind raises `ArgumentError`** naming the aggregate and the reading: `sum` of a string, `mean` of a time.
- **The streaming form** (§1.2) is given by `count`, `distinct`, `min`, `max`, `extent`, `sum`, `mean`, `variance`, `deviation`, `slope` and `delta`. `median` and `quantile` need every reading, so they give none. A streaming statistic's `reduce/2` **is** its streaming form folded over the readings, so the two agree exactly: the mean is a running sum over a count, and the variance, the deviation and the slope are Welford's one-pass updates, numerically stable and equal to visualize's two-pass values to within floating-point rounding.
- **The combining form** (§1.2) is given by `count`, `min`, `max`, `extent`, `sum` and `mean`: their states merge exactly. A floating-point sum is not associative, so a sum over chunks would change with the chunking; `sum` and `mean` therefore sum exactly (each float as the integer multiple of 2^-1074 it is), and every order and grouping of the same readings gives the same bits. The state sums each float's signed mantissa with its binary exponent's, exactly, and counts the sums in units of 2^-1074 once, when the value is read (macaw_data#41), so adding a float shifts no integer. `min` and `max` keep the first run's on a tie. `distinct`, `variance`, `deviation`, `slope` and `delta` give none: their merges would be inexact in floating point or would grow with the readings. `median` and `quantile` need every reading: a quantile is exact here, never a sketch's approximation, so a step reducing by one reads every reading at once.
- **spec/02 §4 still holds.** A statistic of a delivery's rows is the statistic of those rows: a quantile of a reduced or rolled-up delivery is not the quantile of the raw readings ("a p95 of p95s is not a p95"), so a percentile from raw rows stays in the source.

```test:operations-statistics-values
each statistic answers visualize's value on its fixtures, its empty value for no readings, and its output type; the unit carries exactly for the keeping statistics; a reading of the wrong kind raises naming the aggregate
```

```test:operations-statistics-combine
the combining form of count, min, max, extent, sum and mean merges two runs' states into the state of both, for every split; sum is exact, the same bits in any order, an integer of integers and the exact sum rounded once with a float; exactly those statistics give it
```

```test:operations-statistics-exact
for generated floats, normal, subnormal and near the largest, and integers, sum's value is the exact sum of their multiples of 2^-1074 rounded once, ties to even, the same bits an oracle summing those multiples gives; adding a float costs at most 5 reductions
```

```test:operations-statistics-stream
the streaming form of every statistic that has one equals its reduce over every fixture, however the readings are chunked
```

### 5.1 The exact sum by group's native kernel {#operations-group-native}

**A grouping's exact sum runs in a native kernel where the kernels are loaded** (§1.7, macaw_data#38). `aggregate` with `sum`, `mean` or `count`, and `sum`, hand a chunk's view to `group_sum` when `field` is one int64 or float64 column and `by` is one dictionary column (its codes and their validity, read in place) or absent. The kernel reads every row once and answers each group in order of first appearance: its code (or `nil`, a missing key), its first row and count of rows in the view, its count of readings (values present), and its exact sum, the state `Macaw.Data.Exact` builds:
- **integers** summed as an integer, exactly (in 128 bits, past int64 as the bignum it is);
- **floats** as their signed mantissas summed by biased exponent, a subnormal's exponent `0`, `-0.0` the mantissa `0` at exponent `0`; `nil` while no float was added.

The step then builds each group's state (`sum`'s exact sum, `mean`'s with the count of readings, `count`'s count) and names it by its dictionary string, a group at a time, so the chunk's part equals the Elixir fold's term for term, and so does every merge and finish after it.
- **It hands the view back** (`:fallback`) where the Elixir path would raise: a code past the dictionary, or a value that is not a finite float. Any other aggregate, field form (`macaw.integral`, the union, a pair) or `by` (several columns, a column not a dictionary, a dictionary with booleans) is the Elixir path's.
- **Its cost:** the column is never decoded and the bitmaps are not expanded; a few nanoseconds a row (a run of one exponent adds to the sum it last found; another is found through a small hash table of the groups' exponents), then a few terms an entry of the answer, a group or one of its exponents' sums, at tens of nanoseconds each. A call over at most `Native.sync_rows/0` rows runs on a normal scheduler and answers there up to `Native.sync_entries/0` entries (2,048), within 1 ms; past that it answers `:dirty` before building a term, and the step makes the same call on a dirty CPU scheduler, as it does for a view past `sync_rows/0`.

```test:operations-group-native-identical
for generated int and float readings (subnormal, signed zeros, near the largest, past int64 summed) with nils, grouped by a dictionary column with missing keys, or not grouped, chunked several ways and viewed from an offset, the native groups equal the Elixir fold's term for term for sum, mean and count, the kernel answering every such view, and the steps' tables equal with and without the kernels; a code past the dictionary is handed back
```

```test:operations-group-native-bound
a call over sync_rows/0 rows, 8,192, answering sync_entries/0 entries, 2,048 (256 groups of 7 exponents each), takes under 1 ms on a normal scheduler; one entry fewer allowed answers :dirty; every row its own group, and a view past sync_rows, run on a dirty scheduler with the Elixir path's groups
```

## 6. In a stored function {#operations-sandbox}

A derived source's stored function (02 §6) reaches the registered operations through **one module, `Macaw.Data.Ops`**, and through nothing else:

| Function | Contract |
|---|---|
| `Ops.aggregate(values, name)`, `aggregate(values, name, options)` | the aggregate's value of `values`, `nil`s dropped |
| `Ops.transform(rows, name)`, `transform(rows, name, options)` | the transform run over the rows, its answer as rows |

```elixir
fn %{hosts: rows} ->
  p95 = rows |> Enum.map(& &1.cpu) |> Macaw.Data.Ops.aggregate("quantile", %{p: 0.95})

  rows
  |> Macaw.Data.Ops.transform("filter", %{field: "cpu", test: :gte, value: p95})
  |> Macaw.Data.Ops.transform("sort", %{field: "cpu", order: :descending})
end
```

**Both take their subject first**, so a pipe reads in order, and the name second. Called from a host's own code rather than a stored function, they use `macaw_data`'s own package (`Macaw.Data.Operations.registry/0`). **Options are the nodes a design writes**, the same keys and values, so a step moves between a design and a stored function unchanged; a transform's options name no `op`, since the name is the op, and one that does raises. They are read by spelling: an option key or enum value the checker doesn't know as an atom comes back as its string (02 §6.1), and the operation reads it as the same option. The checker's word table therefore doesn't grow with the registry, and a stored function makes no atom through one.

```test:operations-sandbox-ops
Ops takes its subject first and the name second, so a pipe reads in order; called from host code it runs macaw_data's own package, rows in and rows out; a transform's options that name an op raise
```

### 6.1 The allowlist is generated {#operations-allowlist}

**`Macaw.Data.Ops` is on the allowlist (02 §6.2); the operations it reaches are the registry's**, never written by hand. Enabling a package is the only way to widen it: the engine's `packages:` (02 §8.4), `[]` by default, so a stored function reaches `macaw_data`'s own package alone unless its host enables another. The checker is given the registry (`Sandbox.check/2`'s `operations:`, `macaw_data`'s own package by default), and holds every call of `Ops`:

- **The name is a literal string.** An operation named by a variable, an expression, an interpolation or a capture (`&Macaw.Data.Ops.aggregate/2`) is `{:operation_name, :literal}` at its line. A name decides what code runs, so it is known when the function is checked. An atom literal that is not one of the checker's words reads as its string (02 §6.1), so `:mean` names `"mean"`.
- **The name is registered.** One the registry doesn't hold is `{:unknown_operation, :transform | :aggregate, name}`.
- **It needs nothing a derived source lacks.** A transform whose `needs/0` isn't empty is `{:needs, name, need}`, since a derived source has no frame, projection or text.
- **The call is compiled against the registry it was checked against.** It becomes `Ops.__run__(kind, registry, name, subject, options)` with the registry escaped into the compiled code, so it runs exactly what was checked, with nothing read from the node's environment, and no module atom passes through the stored source. `__run__/5` is on `Macaw.Data.Ops`'s excluded list (`:internal`), so a stored source that writes it is refused like any other unlisted call.
- **Before it is placed,** a source is checked with `operations: nil` (`Derived.new/1`, which knows no engine): its names need only be literals. `Derived.validate/2` takes `operations:` as it takes `functions:`, and the engine passes its registry, so a name its packages do not hold is a fault at define time. `Sandbox.compile/2` needs a registry and raises `ArgumentError` without one.
- **The options are checked when the call runs.** They may be built by the function, so a fault in them (§3.1) raises `ArgumentError` with `format_error/1`'s words, which the runner reports as `:raised` (02 §6.4).
- **Rows in, rows out.** `transform/2,3` reads its rows with `Table.from/2` and answers `Table.rows/1` of the result. The context a stored call runs with has no `now`, `frame` or `schema` (02 §2.3), so a `window` measures from its data's newest reading, and `latest` raises: a function asks its input for `latest` instead (02 §2.2).

**The compile cache is keyed by the source and the registry's digest** (§2), so the same text compiled against another registry is compiled again. `Macaw.Data.Reduce` leaves the allowlist: `lttb` and `m4` are reached as transforms, so a stored function has one way to reduce. `Allowlist.modules/0` is then `Enum`, `Map`, `Keyword`, `String`, `Integer`, `Float`, `:math` and `Macaw.Data.Ops`.

```test:operations-sandbox-calls
a stored function calls a registered aggregate and transform by literal name and gets the same answer apply gives; a name that is not literal, not registered, or of a transform with needs is refused at its line; a bad option raises when the call runs; a test package's members are callable only when enabled
```

```test:operations-sandbox-cache
the same source compiled against registries with different digests compiles twice, and against the same registry once; Reduce is no longer allowed and Ops is
```

### 6.2 The gates {#operations-gates}

The sandbox's gates (02 §6.5) grow with its reach:
- **The attack suite** adds attacks through an operation's name: a variable, an interpolated string, a name built at run time, a `nil` and a map read as the name, a pipe that puts the rows where the name goes, a captured operation, a module alias as the name, `__run__/5` written directly, an unregistered aggregate or transform, `Macaw.Data.Operations` called directly, and `Macaw.Data.Reduce`, no longer reachable. Each is refused by name at its line, and none makes an atom. A drawing transform's `{:needs, name, need}` is tested beside them, with a host package enabled.
- **The load suite** calls every operation of `macaw_data`'s package from a stored function, every `stack` offset and every statistic among them, over five thousand rows: each verdict is the same idle and with every scheduler saturated, and each is an answer within the runner's default bounds.

```test:operations-sandbox-attacks
every attack through an operation's name is refused at its line, and parsing them makes no atom
```

```test:operations-sandbox-load
every operation of macaw_data's package, called from a stored function over five thousand rows, answers within the default bounds, the same idle and saturated
```

### 6.3 From `Visualize.Data` {#operations-migration}

visualize's sandbox allows `Visualize.Data`. A stored function written against it moves to Macaw by this table, and the move is the adopter's (visualize#939):

| visualize | Macaw |
|---|---|
| `min/1,2`, `max/1,2`, `extent/1,2`, `sum/1,2`, `mean/1,2`, `median/1,2`, `variance/1,2`, `deviation/1,2`, `slope/1,2`, `delta/1,2` | `Ops.aggregate(values, name)`, the accessor applied first (`Enum.map(rows, & &1.cpu)`) |
| `quantile(data, p)`, `quantile(data, p, accessor)` | `Ops.aggregate(values, "quantile", %{p: p})` |
| `extent` as `{min, max}` | `[min, max]` |
| `lttb/2,3`, `m4/2,3` | `Ops.transform(rows, "lttb", %{fields: [x, y], n: n})`, `"m4"` with `width` |
| `bin/1,2` | `Ops.transform(rows, "bin", %{field: f, thresholds: t})` |
| `group/2` | `Enum.group_by/2` |
| `rollup/3` | `Enum.group_by/2` and `Map.new/2`, or `Ops.transform(rows, "aggregate", %{field: f, fn: name, by: k})` |
| `sort/2,3` | `Enum.sort_by/2,3`, or `Ops.transform(rows, "sort", …)` |
| `unique/1,2` | `Enum.uniq/1`, `Enum.uniq_by/2` |
| `cross/2,3` | `for x <- a, y <- b, do: …` |
| `range/2,3` | a range, `Enum.to_list(a..b//s)` |
| `ticks/3` | none: a scale's ticks are the drawer's (visualize) |

## 7. Budget reducers {#operations-reducers}

A budget's reducer (01 §2.4, `:budget`) is **any registered transform declaring `reduces/0`** (§1.1), by name: `lttb` (the default) and `m4` in `macaw_data`'s package, and any an enabled package adds. `Macaw.Data.Source.Finish.finish/4` and `reduce/5` take `reduce:` (a name, by spelling) and `operations:` (the registry, `macaw_data`'s own package by default):

- each series and number field is reduced as 01 §2.4 says, by the reducer's node `%{fields: [x, y], <count>: c}`. Here `x` is the window field or the row's place, `<count>` is the option `reduces/0` names, and `c = max(min, div(budget, per · share))`, where `per` is the rows a unit keeps, `share` the series times the number fields, and `min` the least its option's type allows (`lttb`: 3; `m4`: 1);
- the union of the kept rows is returned whole, in their order, never more than the budget;
- **a `reduce:` naming no registered reducer** (unknown, or a transform without `reduces/0`) raises `ArgumentError` naming it: the request is the caller's, as a request the schema cannot answer is.

```test:operations-reducers-named
a budget reduces by lttb by default, by m4 when named, and by a test reducer of an enabled package; an unknown name and a transform that does not reduce each raise naming it
```
