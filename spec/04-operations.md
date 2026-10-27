# 04 — Operations {#operations}

The operations a design applies to its data and the operations a derived source may call are **the same code**, here in `macaw_data` beside derived sources (macaw_compose#22, decision 11; R18 of `design/visualize-alignment.md`). A computation therefore moves between a design and a derived source unchanged, and a metresis feed and a visualize chart reduce data the same way. This file is visualize's spec/14 §5.4.1 (the data steps) and its proposals visualize#886 (the transform behavior) and visualize#909 (the aggregate behavior), both folded into Macaw by the owner on 2026-10-26, adapted to Macaw's contracts (macaw_compose#83):

- **a transform reads and returns a `Macaw.Data.Table`** ([01 §1.1](01-sources.md#sources-table)), the currency of deliveries; rows are a view at the edge;
- **names are strings, matched by spelling.** A document's op name, option key, enum value or column name is read by spelling against the library's own vocabulary, and no atom is ever made from one. A column a step adds is named by the node's `as`, as it spells it, else by the step's default name, a string (`"count"`, `"x0"`): visualize's defaults are atoms, Macaw's are strings, as derived sources' joined fields are (02 §1.4);
- **the registry is explicit and default closed** (§2): `macaw_data`'s own package is always in, and anything else only when a host enables its package;
- **transforms that need geometry** (layouts, geographic operations) implement the same behavior and declare it (`needs: [:frame]`, §1.1). They live in the package that draws, never here, and are never reachable from a derived source, which has no frame.

Each section's tests are written as **`planned-test:` blocks** until its work item is built (macaw_compose#119–#124), as spec/02's were: surfex judges every `test:` hint and can't defer one, so each becomes a `test:` hint, unchanged, in the change that implements it.

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

`run/3` is given **the node checked** (§3.1): its keys strings, each of the op's options present with its default filled in, an enum value its declared atom, a frame-bound value resolved to a number. `outputs/2` is given the same node. `outputs/2` holds for `run/3`: for every fixture of the op's tests, the columns `run/3` answers are, by name and type, the ones `outputs/2` names.

```test:operations-transform-callbacks
a transform declares its name, options, needs and outputs and runs a checked node over a table; an optional reducer and prepare are declared only by the ops that have them; outputs agree with what run answers on every fixture
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

```test:operations-aggregate-callbacks
an aggregate declares its name, options, output type and whether it keeps the unit, and reduces readings with nils dropped; where it has the streaming form, the stream equals reduce on every fixture, chunked at every split
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

## 2. Packages and the registry {#operations-registry}

**A package is a module with `__members__/0`**, the list of its modules that implement a behavior of this file or of any other Macaw behavior (macaw_compose spec/12 §1). Which behavior a member implements is read from its own `@behaviour` declarations, so a package author maintains one list. `Macaw.Data.Operations` is `macaw_data`'s own package: the twelve table operations of §4 and the thirteen statistics of §5.

`Macaw.Data.Operations.registry(packages)` builds the registry, a `%Macaw.Data.Operations.Registry{}`, from an **explicit list** of package modules:

- **Default closed.** `macaw_data`'s own package is always in, since it is the library's own pure code, as `Enum` is the allowlist's (02 §6.2). Anything else is what the list names and nothing more: a module that is merely loaded is not reachable, and no application environment is read.
- **Duplicates fail at build.** Two members of one behavior with one name raise `ArgumentError` naming the name, both modules and their packages; a package listed twice is listed once. So does an aggregate declaring a step's key as its own option (§1.2), and a module `__members__/0` lists that implements none of the behaviors.
- **Names are strings, matched by spelling,** and the registry maps each to its module: `transform(registry, name)` and `aggregate(registry, name)` answer `{:ok, module}` or `:error`; `transforms/1` and `aggregates/1` every name, sorted; `packages/1` the packages, `Macaw.Data.Operations` first; `digest/1` a digest of every member's name and module, which a compile cache keys by (§6.2).
- macaw_compose's registry (step 8) builds on this one for its other behaviors and does not replace it. It knows the packages a host lists but has not enabled, so it is what names the providing package in an unknown name's fault (`transform "sankey" is not available: enable visualize_layouts`); here an unknown name is a fault without one (§3.1).

```test:operations-registry-build
the registry holds macaw_data's own package and exactly the packages listed; a duplicate name, an aggregate declaring a step's key and a member implementing no behavior each raise naming what collides; names resolve by spelling to their module and the digest changes with the members
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
| `projection`, `text`, `prepared` | what `needs/0` names, and `prepare/3`'s result | the drawer's |

- **A need is met by its key.** A transform declaring `needs: [:frame]` runs only with `frame` in the context; otherwise its node is `{:needs, :frame}` at validation. A derived source has no frame, projection or text, so a member that needs one is never callable from a stored function (§6).
- **A frame-bound option** (`lttb`'s `n`, `m4`'s `width`) may be written `"plot"` (or `:plot`): the plot's width in whole pixels, `ceil` of the frame's `width`, resolved **before** `run/3` is called, so the step itself is a pure data operation. Without a frame it is `{:needs, :frame}` at that option, never a crash. So `lttb(fields: ["t", "bpm"], n: "plot")` says "one point per pixel" and follows the plot when it is resized.

```test:operations-context-needs
a transform needing a frame runs with one and is refused without one; plot resolves to the ceiling of the frame's width before the step runs and is refused without a frame; now and schema reach the step
```

## 4. Table operations {#operations-table}

Each is a module of `macaw_data`'s package implementing §1.1, ported from visualize's `Chart.Transform.Data` (spec/14 §5.4.1) with its behavior and faults; every visualize test of the step is ported with it. **Rows are read with `Macaw.Data.Table.get/2`**, so a column is found by either spelling, and a column the rows lack reads `nil`, which the step treats as its section says. **A step that derives a row from a datum keeps the datum's columns** and adds its own. Each step's **outputs** are named in its section. **Rows pass through a table:** `Table.from/2` reads them at the edge, so a row lacking a column another row has reads `nil` there, and a `Date`, a `NaiveDateTime` or an ISO 8601 string in a time column is a `DateTime` from then on, as everywhere a delivery carries one (01 §1.1). `Macaw.Data.Operations.Transforms.all/0` lists the operations, and the package also registers them.

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

The test is `test`, not `op`, because `op` names the step. A column the rows lack reads `nil`, so `filter(field: "height", test: :eq, value: 0)` after a hierarchy keeps its leaves. **Outputs:** the input's columns.

```test:operations-filter-tests
each test keeps exactly its rows in order: present and absent by nil, eq and ne by value with an atom equal to its string, the orderings by term order with nil never passing; a missing column reads nil
```

### 4.2 take {#operations-take}

`n` (`{:integer, 0}`, required); `side` (`{:enum, [:end, :start]}`, `:end`). The last, or the first, `n` rows in order. An `n` at or above the row count is every row, and `n` of zero is none; a negative `n` is `{:type, {:integer, 0}}`. A design that shows the newest reading beside its history reads `take(n: 1)`. **Outputs:** the input's columns.

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

**`latest: true`** asks for each entity's current state: of the rows the window selects, for each identity value, the one row whose reading of `field` is greatest, the later row in order where two tie, kept in their order. It is what a request's `latest` gives (01 §2.4), by the same function, `Macaw.Data.Window.latest_rows/3`. The identity is the one the context's `schema` **declares** (`Macaw.Data.Schema.identity/2`), never inferred, and a row whose identity is `nil` names nothing and is dropped. A `latest` step without a schema in its context, or over a schema declaring no identity, raises `ArgumentError` naming the step. Dropping the entities that are gone is a `filter` after it.

**Outputs:** the input's columns.

```test:operations-window-spans
a window selects [now - from, now - to): a given to is exclusive, an absent to closes at now inclusively, an absent from is open, so adjacent windows partition the rows; now is the context's or the newest reading; every reading form is read in seconds and any other raises; a bad unit is refused
```

```test:operations-window-latest
latest keeps each declared identity's newest row in the window, the later on a tie, in order, dropping a nil identity; without a schema, or with one declaring no identity, it raises naming the step
```

### 4.4 lttb {#operations-lttb}

`fields` (`{:pair, :field}`, required: `[x, y]`, the two columns a line reads); `n` (`{:integer, 3}`, frame-bound, required). **Shape-preserving downsampling** by Largest-Triangle-Three-Buckets (Steinarsson 2013), `Macaw.Data.Reduce.lttb/3` over the rows with the accessor reading `{x, y}`:
- the first row, the last, and `n − 2` rows between that keep the line's visual area;
- input of `n` or fewer rows is returned unchanged. An `n` below 3 is refused, since a line needs its two ends and a point between to have a shape;
- **gaps pass through.** A row whose `x` or `y` reads `nil` is a gap: the rows reduce run by run between the gaps, each run's share of `n` in proportion to its length, and each run of gap rows keeps its first row in place, so a line still breaks where the input broke;
- an `x` reads as a number or as a time in seconds, as `window` reads one; a `y` as a number. Any other reading raises `ArgumentError` naming the step and the field;
- **whole rows are kept,** every column of each, so a tooltip over a kept point reads the datum itself. O(n) in the rows.

**Outputs:** the input's columns. **Reducer:** `{"n", 1}`.

```test:operations-lttb-shape
lttb keeps the ends and n - 2 rows between, whole, chosen as the reference algorithm chooses; n or fewer rows come back unchanged; gaps pass through with each run of gaps kept as its first row; time readings are seconds and a non-number y raises; n below 3 is refused
```

### 4.5 m4 {#operations-m4}

`fields` (`{:pair, :field}`, required); `width` (`{:integer, 1}`, frame-bound, required). Per pixel column the **first, last, minimum and maximum** rows, `Macaw.Data.Reduce.m4/3` over the rows as `lttb` reads them, deduplicated and in input order. The columns split the extent of the defined `x` readings. When that is the drawn `x` domain, the reduced line **draws the same pixels as the unreduced one**: every column it crosses, with the same top, bottom, entry and exit, so a peak is never lost. It is the right choice where one must not be lost: an alert threshold, a heart-rate maximum. `width: "plot"` is what a design means nearly always; an integer is for one reduced for a size it knows. Gaps, readings, faults, whole rows and the cost are `lttb`'s.

**Outputs:** the input's columns. **Reducer:** `{"width", 4}`.

```test:operations-m4-columns
m4 keeps each column's first, last, minimum and maximum rows, deduplicated in order, so every extreme survives; gaps, readings and faults are lttb's; width below 1 is refused
```

### 4.6 sort {#operations-sort}

`field` (`:field`, required); `order` (`{:enum, [:ascending, :descending]}`, `:ascending`). The rows **stably** sorted by the reading of `field` under `Enum.sort_by/3`'s term ordering, in that direction. **Outputs:** the input's columns.

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

**Outputs:** the input's columns without the folded ones, then `as`'s two: the key a `:category`, the value the folded columns' type when they share one, else `:term`.

```test:operations-fold-long
fold makes one row per input row per listed column it has, in row then field order, carrying the other columns, skipping a missing column and a nil reading, under the as names
```

### 4.8 stack {#operations-stack}

<!-- surfex: deferred #122: table operations II -->

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

**Rows:** one per series in `fields` order, per datum in data order: the datum's columns plus `key` (the series' key), `series` (its stacking position, 0 the bottom), `value`, `y0` and `y1`, the names visualize's marks read. **Outputs:** the input's columns, then `key` (`:category`), `series`, `value`, `y0` and `y1` (`:number`).

```planned-test:operations-stack-orders
every order and offset matches d3-shape's on the reference fixtures, keys fixed and the others computed from the rows; nil reads as zero and a non-number raises; each row carries the datum's columns and its key, series, value, y0 and y1
```

### 4.9 bin {#operations-bin}

<!-- surfex: deferred #122: table operations II -->

`field` (`:field`, required); `thresholds` (`{:one_of, [{:integer, 1}, {:list, :number}]}`, `10`); `as` (`:name`, `"count"`); `fn` (`:aggregate`, `nil`) and the named aggregate's options. The readings of `field` with `nil`s dropped, binned:
- **The domain** is the readings' extent `[d0, d1]`.
- **An integer `n` thresholds** is `n` equal-width bins: `n − 1` inner thresholds at `d0 + i · (d1 − d0) / n`. A list is the inner thresholds as given.
- **A reading belongs to** the first bin `[x0, x1)` holding it, or to the last bin when it equals the domain's maximum.
- One row per bin, in order: `x0`, `x1`, `y0` (`0`, so a histogram's channels read the rows alone), `as` and `values` (the bin's readings, in input order).

`as` holds the bin's count, or, with `fn`, the named aggregate of the bin's readings (`bin(field: "latency", fn: "median")`), an empty bin's being that aggregate's empty value (§5). No readings yield no rows; a reading that is not a number raises `ArgumentError` naming the step.

**Outputs:** `x0`, `x1`, `y0` (`:number`), `as` (`:number`, or the aggregate's output type) and `values` (`:term`).

```planned-test:operations-bin-counts
bin splits the extent into n equal bins or at the given thresholds, each reading in its half-open bin and the maximum in the last, counting by default or reducing each bin's readings by fn; no readings yield no rows
```

### 4.10 aggregate and sum {#operations-group}

`aggregate`: `field` (`{:one_of, [:field, {:pair, :field}]}`, required); `fn` (`:aggregate`, required) and the named aggregate's options; `by` (`{:one_of, [:field, {:list, :field}]}`, `nil`); `as` (`:name`, the aggregate's name).
- **Groups:** one row per distinct value of `by` (a list of fields groups by every one), in order of first appearance, a `nil` value a group of its own. The row holds `by`'s columns and, under `as`, the aggregate of the group's readings of `field`, `nil`s dropped. Without `by`, one row holds `as` alone.
- **A pair field** `[x, y]` reads each row as the point `[x, y]` for an aggregate that reads points (`slope`, §5), `x` in seconds when it is a time. A row whose `x` or `y` is `nil` is dropped.

`sum` is **`aggregate` with `fn: "sum"`**: `field`, `by` and `as` (`"sum"`), no `fn`. It is vocabulary a design writes, not an alias kept for compatibility, so it is never deprecated.

**Outputs:** `by`'s columns with their input types, then `as` of the aggregate's output type.

```test:operations-group-rows
aggregate makes one row per distinct by value in order of first appearance, or one row without by, holding the named aggregate of the group's non-nil readings; a pair field reads points; sum equals aggregate with fn sum
```

### 4.11 spectrum {#operations-spectrum}

<!-- surfex: deferred #122: table operations II -->

`field` (`:field`, required: the sample column); `time` (`:field`, `nil`); `every` (`:positive`, `nil`: the seconds between samples); `samples` (`:power_of_two`, `nil`); `window` (`{:enum, [:hann, :hamming, :none]}`, `:hann`); `detrend` (`:boolean`, `false`); `as` (`{:one_of, [{:list, :name}, :name]}`, `["frequency", "magnitude"]`).

A time series to its **one-sided amplitude spectrum** by a radix-2 Cooley–Tukey FFT, `Macaw.Data.FFT` (ported from `Visualize.Data.FFT`; pure Elixir, `O(N log N)`):
- **The sample interval** is `every` when given; else the median positive gap between consecutive non-`nil` readings of `time` (`DateTime`s in seconds, numbers as they are); else `1`.
- **The samples:** the newest `samples` rows with a numeric reading of `field`. When `samples` isn't given, that is the largest power of two not above their count. Fewer than two, or fewer than `samples`, yield no rows.
- **Detrending:** with `detrend: true`, the samples' mean is subtracted first, so an offset doesn't leak from the DC line into the bins beside it.
- **The taper:** `hann` is `0.5 − 0.5 cos(2πi/(N−1))` and `hamming` is `0.54 − 0.46 cos(2πi/(N−1))`. A sequence shorter than four is not tapered.
- **The lines:** the samples are transformed and read as `samples / 2` lines, `k` from 0. A line's frequency is `k / (samples · every)` hertz. Its magnitude is `|X_k| · 2 / (samples · gain)`, where `gain` is the window's mean, and the DC line is not doubled. Its phase is the argument of `X_k`.

Each row holds `as`'s names for the frequency and the magnitude, and a third name, when `as` gives one, for the phase. A single name is the frequency's, with the magnitude `"magnitude"`.

**Outputs:** the `as` names, `:number`.

```planned-test:operations-spectrum-lines
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
| `sum` | | the sum of numbers | `0` | `:number` | kept |
| `mean` | | the arithmetic mean, a float | `nil` | `:number` | kept |
| `median` | | the middle of the sorted readings; of an even count, the mean of the two middles | `nil` | `:number` | kept |
| `quantile` | `p` (`{:number, 0, 1}`, required) | linear interpolation between the sorted readings: at `i = (n − 1) · p`, `v[⌊i⌋] + (v[⌊i⌋+1] − v[⌊i⌋]) · (i − ⌊i⌋)`, the last index clamped | `nil` | `:number` | kept |
| `variance` | | the sample variance, `Σ(v − mean)² / (n − 1)` | `nil`, and `nil` of one | `:number` | dropped |
| `deviation` | | the square root of `variance` | `nil`, and `nil` of one | `:number` | kept |
| `slope` | | the least-squares slope of the points: a number `v` at place `i` is the point `[i, v]`, a reading `[x, y]` (or `{x, y}`) the point itself | `nil`, and `nil` of one point or when every `x` is equal | `:number` | dropped |
| `delta` | | the last reading minus the first | `nil` (`0` of one) | `:number` | kept |

- **A unit carries** where the value is of the reading's own kind: a min, a mean or a deviation of milliseconds is milliseconds. Where it is not, it is dropped: a count, the square of a unit, a rate per sample. A host drawing a sum still holds it to the quantity's additivity ([03 §10](03-units.md#quantities-additivity)): a sum of a quantity that does not add across or over time is the host's to refuse, not the statistic's.
- **A reading of the wrong kind raises `ArgumentError`** naming the aggregate and the reading: `sum` of a string, `mean` of a time.
- **The streaming form** (§1.2) is given by `count`, `distinct`, `min`, `max`, `extent`, `sum`, `mean`, `variance`, `deviation`, `slope` and `delta`. `median` and `quantile` need every reading, so they give none. A streaming statistic's `reduce/2` **is** its streaming form folded over the readings, so the two agree exactly: the mean is a running sum over a count, and the variance, the deviation and the slope are Welford's one-pass updates, numerically stable and equal to visualize's two-pass values to within floating-point rounding.
- **spec/02 §4 still holds.** A statistic of a delivery's rows is the statistic of those rows: a quantile of a reduced or rolled-up delivery is not the quantile of the raw readings ("a p95 of p95s is not a p95"), so a percentile from raw rows stays in the source.

```test:operations-statistics-values
each statistic answers visualize's value on its fixtures, its empty value for no readings, and its output type; the unit carries exactly for the keeping statistics; a reading of the wrong kind raises naming the aggregate
```

```test:operations-statistics-stream
the streaming form of every statistic that has one equals its reduce over every fixture, however the readings are chunked
```

## 6. In a stored function {#operations-sandbox}

<!-- surfex: deferred #123: the sandbox's reach -->

A derived source's stored function (02 §6) reaches the registered operations through **one module, `Macaw.Data.Ops`**, and through nothing else:

| Function | Contract |
|---|---|
| `Ops.aggregate(name, values)`, `aggregate(name, values, options)` | the aggregate's value of `values`, `nil`s dropped |
| `Ops.transform(rows, name)`, `transform(rows, name, options)` | the transform run over the rows, its answer as rows |

```elixir
fn %{hosts: rows} ->
  p95 = Macaw.Data.Ops.aggregate("quantile", Enum.map(rows, & &1.cpu), %{p: 0.95})

  rows
  |> Macaw.Data.Ops.transform("filter", %{field: "cpu", test: :gte, value: p95})
  |> Macaw.Data.Ops.transform("sort", %{field: "cpu", order: :descending})
end
```

**Options are the nodes a design writes**, the same keys and values, so a step moves between a design and a stored function unchanged. They are read by spelling: an option key or enum value the checker doesn't know as an atom comes back as its string (02 §6.1), and the operation reads it as the same option. The checker's word table therefore doesn't grow with the registry, and a stored function makes no atom through one.

### 6.1 The allowlist is generated {#operations-allowlist}

<!-- surfex: deferred #123: the sandbox's reach -->

**`Macaw.Data.Ops` is on the allowlist (02 §6.2); the operations it reaches are the registry's**, never written by hand. Enabling a package is the only way to widen it. The checker is given the engine's registry (`operations:`), and holds every call of `Ops`:

- **The name is a literal string.** An operation named by a variable, an expression or an interpolation is `{:operation_name, :literal}` at its line. A name decides what code runs, so it is known when the function is checked.
- **The name is registered.** One the registry doesn't hold is `{:unknown_operation, :transform | :aggregate, name}`.
- **It needs nothing a derived source lacks.** A transform whose `needs/0` isn't empty is `{:needs, name, need}`, since a derived source has no frame, projection or text.
- **The checker compiles the call to its member.** The call becomes a call of `Ops.__run__/4` with the member's module, so nothing is looked up when the function runs, and a module atom never passes through the stored source. `__run__/4` is not on the allowlist, so a stored source that writes it is refused like any other call.
- **The options are checked when the call runs.** They may be built by the function, so a fault in them (§3.1) raises `ArgumentError` with `format_error/1`'s words, which the runner reports as `:raised` (02 §6.4).
- **Rows in, rows out.** `transform/2,3` reads its rows with `Table.from/2` and answers `Table.rows/1` of the result. The context a stored call runs with has no `now`, `frame` or `schema` (02 §2.3), so a `window` measures from its data's newest reading, and `latest` raises: a function asks its input for `latest` instead (02 §2.2).

**The compile cache is keyed by the source and the registry's digest** (§2), so the same text compiled against another registry is compiled again. `Macaw.Data.Reduce` leaves the allowlist: `lttb` and `m4` are reached as transforms, so a stored function has one way to reduce. `Allowlist.modules/0` is then `Enum`, `Map`, `Keyword`, `String`, `Integer`, `Float`, `:math` and `Macaw.Data.Ops`.

```planned-test:operations-sandbox-calls
a stored function calls a registered aggregate and transform by literal name and gets the same answer apply gives; a name that is not literal, not registered, or of a transform with needs is refused at its line; a bad option raises when the call runs; a test package's members are callable only when enabled
```

```planned-test:operations-sandbox-cache
the same source compiled against registries with different digests compiles twice, and against the same registry once; Reduce is no longer allowed and Ops is
```

### 6.2 The gates {#operations-gates}

<!-- surfex: deferred #123: the sandbox's reach -->

The sandbox's gates (02 §6.5) grow with its reach:
- **The attack suite** adds attacks through an operation's name: a variable, an interpolated string, a name built at run time, `__run__/4` written directly, an unregistered name, a module atom as the name, and a drawing transform. Each is refused by name at its line, and none makes an atom.
- **The load gate** runs every operation of `macaw_data`'s package over the gate's largest input, within the runner's default bounds.

```planned-test:operations-sandbox-attacks
every attack through an operation's name is refused at its line, and parsing them makes no atom
```

```planned-test:operations-sandbox-load
every operation of macaw_data's package runs over the load gate's largest input within the default bounds
```

### 6.3 From `Visualize.Data` {#operations-migration}

<!-- surfex: deferred #123: the sandbox's reach -->

visualize's sandbox allows `Visualize.Data`. A stored function written against it moves to Macaw by this table, and the move is the adopter's (visualize#939):

| visualize | Macaw |
|---|---|
| `min/1,2`, `max/1,2`, `extent/1,2`, `sum/1,2`, `mean/1,2`, `median/1,2`, `variance/1,2`, `deviation/1,2`, `slope/1,2`, `delta/1,2` | `Ops.aggregate(name, values)`, the accessor applied first (`Enum.map(rows, & &1.cpu)`) |
| `quantile(data, p)`, `quantile(data, p, accessor)` | `Ops.aggregate("quantile", values, %{p: p})` |
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

<!-- surfex: deferred #124: budget reducers -->

A budget's reducer (01 §2.4, `:budget`) is **any registered transform declaring `reduces/0`** (§1.1), by name: `lttb` (the default) and `m4` in `macaw_data`'s package, and any an enabled package adds. `Macaw.Data.Source.Finish.finish/4` and `reduce/5` take `reduce:` (a name, by spelling) and `operations:` (the registry, `macaw_data`'s own package by default):

- each series and number field is reduced as 01 §2.4 says, by the reducer's node `%{fields: [x, y], <count>: c}`. Here `x` is the window field or the row's place, `<count>` is the option `reduces/0` names, and `c = max(min, div(budget, per · share))`, where `per` is the rows a unit keeps, `share` the series times the number fields, and `min` the least its option's type allows (`lttb`: 3; `m4`: 1);
- the union of the kept rows is returned whole, in their order, never more than the budget;
- **a `reduce:` naming no registered reducer** (unknown, or a transform without `reduces/0`) raises `ArgumentError` naming it: the request is the caller's, as a request the schema cannot answer is.

```planned-test:operations-reducers-named
a budget reduces by lttb by default, by m4 when named, and by a test reducer of an enabled package; an unknown name and a transform that does not reduce each raise naming it
```
