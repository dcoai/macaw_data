# 02 — Derived sources {#derived}

A **derived source** (visualize's *virtual source*) is a source computed from other sources by a function: rows in, rows out. Macaw adopts visualize's design whole; it is the most developed part of the three projects (visualize.md C2). This file is visualize's spec/08 §10.5 and spec/15 §14 (visualize#643, D-194, D-195, D-220, D-228), adapted to Macaw's contracts (macaw_compose#82):

- **inputs are sources** ([01 §2](01-sources.md#sources-contract)), by name, and their answers are `Macaw.Data.Delivery`s;
- **a derived source is itself a source**, so it is another's input and a slot's source, held to the conformance kit ([01 §9](01-sources.md#sources-conformance));
- **the context has no clock and no variables**: a variable, a selection, anything else a function depends on is an input like any other;
- **names, forms and limits are `macaw_layers`'s**;
- **registration is explicit and default closed**: a host passes its function modules, and no application environment is read.

The function is Elixir, never a language of this library's own: either a `defsource` in a host module, the host's own trusted code (§7), or **source text stored in a document**, which is untrusted, since a builder, a store or a shared host can put any text there. The sandbox (§6) is the checker every stored function passes before it is compiled, the compile-once cache, and the bounded runner every function, stored or the host's, is called through. Its design follows Dune's (an allowlist of `{module, function, arity}` triples, a process per run with heap and work limits, failure kinds rather than raises) without adopting it, since Dune interprets its rewritten AST on every call and a derived source is compiled once and called on every change (visualize#643's prior-art review).

| Module | What it is |
|---|---|
| `Macaw.Data.Derived` | the value, its checks, its conformance, its paths and its forms (§1–§3) |
| `Macaw.Data.Derived.Context` | the context a function of two arguments is given (§2.3) |
| `Macaw.Data.Derived.Join` | joined fields: a per-identity source's output on its input's rows (§1.4) |
| `Macaw.Data.Derived.Sandbox`, `.Allowlist`, `.Cache` | the checker, the allowlist, compiling once and the bounded runner (§6) |
| `Macaw.Data.Derived.Functions` | a host's functions, `defsource` and the registry (§7) |
| `Macaw.Data.Derived.Engine`, `.Output` | where derived sources run, and a derived source's answer as a source (§8) |

Each section's tests are written as **`planned-test:` blocks** until its work item is built (macaw_compose#114–#117). A planned test is a test hint whose code doesn't exist yet: surfex judges every `test:` hint and can't defer one, so each becomes a `test:` hint, unchanged, in the change that implements it.

## 1. The model {#derived-model}

A derived source is **data**: a struct with no function in it, its function a name or a source text, so a document holds it and its forms write it (§1.5).

### 1.1 The value {#derived-value}

`%Macaw.Data.Derived{}`:

| Field | Value | Default |
|---|---|---|
| `id` | the source's name: a string, or an atom other than `nil`, `true` and `false` that Elixir input spells it with, held as its string (`Macaw.Layers.Names`) | required |
| `from` | its inputs, a non-empty list of `{name, window}` (§2) | required |
| `schema` | its output's fields, a `%Macaw.Data.Schema{}` ([01 §1.2](01-sources.md#sources-schema)); in the map form, the map of descriptions `Schema.new/1` takes | required |
| `elixir` | the function as source text: one `fn` of one argument, its inputs, or two, its inputs and its context (§2.3), checked by the sandbox (§6.1) | one of `elixir` and `function` |
| `function` | the name of a host's function, defined with `defsource` (§7), held as its string and found in the registry by spelling | one of `elixir` and `function` |
| `per` | `nil`, `:identity` or `{:identity, input}` (§1.3) | `nil` |

`Macaw.Data.Derived.new/1` takes the map form (§1.5), or a keyword list of the same keys, and answers `{:ok, derived}` or `{:error, faults}` with **every** fault, each `{path, reason}`, the path from the source to the value, ordered by path. `new!/1` answers the source or raises `ArgumentError` naming every fault.

**Alone and in context.** `new/1` checks what the source says of itself: its keys and their types, its schema through `Schema.new/1`, its inputs' shapes, `per` against the inputs' count, and the function's text through `Sandbox.check/2` with `fields: nil`, since what its inputs hold is not known alone. `Macaw.Data.Derived.validate(derived, opts)` checks it **given what it reads**:

- `inputs:` a map from each input's key to the input's `%Schema{}`, where it is known: the function's text is then checked against the fields of its inputs' schemas and its own (`{:unknown_field, name}` for any other, §6.1), each window that is a request is checked against its input's schema (`Macaw.Data.Window.check/2`, [01 §2.4](01-sources.md#sources-finishing)), and `per` against the identity input's declared identity (§1.3);
- `functions:` the host functions' registry (§7): a `function` no registered module defines is `{:undeclared, :function, name}`.

The engine validates every source in context before it first runs, and again whenever an input's schema version changes (§8.2), where every input's schema is known.

| Reason | Meaning |
|---|---|
| `{:type, :derived}` | at `[]`: neither a map nor a keyword list |
| `:unknown_key` | at `[key]`: a key not of the table above |
| `:required` | at `[:id]`, `[:from]` or `[:schema]`; at `[:elixir]` when neither `elixir` nor `function` is given |
| `{:type, expected}` | at the key: `:name` for `id` and `function`, `:inputs` for `from` (not a non-empty list), `:input` for an entry that is not a `{name, window}` pair, `:input_name` for a name that is none of §2.1's, `:string` for `elixir`, `:schema` for `schema` (not a map of descriptions), `:window` for a window that is none of §2.2's, `:pos_integer` for a `last` that is not a positive integer |
| `{:exclusive, :elixir}` | at `[:function]`: both `elixir` and `function` are given; a source has one function |
| `{:duplicate_input, key}` | at `[:from, i]`: two inputs read under the same key, an atom and a string of one spelling being one key (§2.1) |
| `{:check, line, reason}` | at `[:elixir]`: a fault of the sandbox's checker, `{line, reason}` of §6.1 |
| `{:undeclared, :function, name}` | at `[:function]`, in context: no registered host module defines it (§7) |
| `{:enum, [:identity]}` | at `[:per]`: a `per` that is neither `nil`, `:identity` nor `{:identity, input}` |
| `{:per, :ambiguous}` | at `[:per]`: `:identity` over several inputs, which must name the one whose entities it is per |
| `{:per, {:unknown_input, name}}` | at `[:per]`: `{:identity, name}` naming no input |
| `{:per, :no_identity}` | at `[:per]`, in context: the identity input's schema declares no identity ([01 §1.4](01-sources.md#sources-schema-identity)) |
| `{:per, {:identity, input, output}}` | at `[:schema]`, in context: the output's identity fields, `output`, are not the identity input's, `input`, each a list of names as strings, in order |
| `{:per, {:identity_type, field, input, output}}` | at `[:schema, field]`, in context: an identity field the output describes as type `output` where the input describes it as `input` |
| a window's fault | at `[:from, i, :window \| path]`, in context: `Macaw.Data.Window.check/2`'s, with its path |

The schema's faults are reported at `[:schema | path]`, `path` the schema's own (`[:state, :values, 1]`). `Macaw.Data.Derived.format_error/1` words one fault, the root named `derived source`.

```test:derived-new
a source of id, inputs, schema and an elixir or function is built, names held as strings; every fault of a bad source is reported at once, by path, each table reason among them; new! raises naming them
```

```test:derived-validate
in context, a function reading a field no input or output describes, a window its input cannot answer, an undeclared host function and a per over an input without identity are each refused at their path; with every input's schema known a valid source passes
```

### 1.2 The output and its conformance {#derived-conform}

**Rows in, rows out.** A source's function answers a list of rows in its schema: one summary row (many to one), a row per region (many to many) or several rows per input row (one to many) all fall out of it. A row is a map whose keys are its schema's fields, by either spelling.

`Macaw.Data.Derived.conform(derived, rows)` holds an answer to the schema: `{:ok, rows}`, the rows keyed by their fields' strings, or `{:error, {index, field, reason}}` for the first row that does not hold: `index` its position, `field` the field's string (`nil` for a fault of the row or of the answer as a whole), and **never the value** (visualize#643, settled question 4).

| Reason | Meaning |
|---|---|
| `:not_a_list` | the answer is not a list of rows (`index` and `field` are `nil`) |
| `:not_a_row` | a row is not a map (`field` is `nil`) |
| `:undescribed` | a row has a key its schema does not describe |
| `{:type, type}` | a field's value is not `nil` and not of the field's type: a number for `:number`, an instant (`Macaw.Data.Window.instant?/1`) for `:time`, a string, an atom other than `true` and `false`, or a number for `:category`, a string for `:text`, `{longitude, latitude}` numbers for `:point`, a literal color (`Macaw.Data.Schema.color?/1`) for `:color` |
| `:not_in_values` | a `:category` field's value is not one of its declared `values` |
| `:no_identity` | an identity field is `nil` or absent: a row that does not say what it is about names nothing |
| `:identity` | under `per`, a row names another identity than its entity's |

An answer that does not conform is the engine's fault `:nonconforming` (§8.3), this its detail; the output the source last held stays.

```test:derived-conform-answers
a conforming answer is its rows keyed by strings; a non-list, a non-row, an undescribed key, a value of the wrong type, a category outside its values and a missing identity are each the first fault's index, field and reason, and no fault holds the value
```

```test:derived-conform-no-value
no fault of conform ever holds a value of the rows (property over rows carrying a unique marker)
```

### 1.3 Per identity {#derived-per}

With `per`, the function is called **once per entity** of one input, its **identity input**: the only input under `:identity`, the one named under `{:identity, input}`. Its schema must declare identity (`{:per, :no_identity}`).

- **Each call** is given that entity's rows of the identity input, its history in the input's window (§2.2): the rows alone when the source has one input (`fn rows -> … end`), else the inputs' map with the identity input's key holding the entity's rows and every other input whole. A function of two arguments is given the source's context beside them, the same for every entity. It answers one row, a map, or a list of rows.
- **Entities** are grouped by the input's declared identity (`Macaw.Data.Schema.identity/2`), in their order of first appearance; a row with no identity is dropped.
- **The output's identity is the input's:** its schema must declare as identity exactly the input's identity fields, of the same types (`{:per, {:identity, …}}`, `{:per, {:identity_type, …}}`). Each answered row is given the entity's identity values, and a row that names another value for an identity field does not conform (`:identity`).
- **Joined back by identity:** the output holds every entity's rows, entity by entity, in the input's order of first appearance.
- **One bounded call:** the calls for every entity run in **one** call of the runner (§6.4), so the batch's limits are the batch's.

`Macaw.Data.Derived.per(derived, inputs, call)` is the batch over already-read inputs: `call` the function applied to one entity's arguments, answering the joined rows or the first fault.

```test:derived-per-entity
a per source is called once per entity in order of first appearance, a row without identity dropped, each answer given its entity's identity and the answers joined; a row naming another identity does not conform
```

### 1.4 Joined fields {#derived-join}

**A reader of the input reads a per-identity source's answer for its own identity** (visualize D-194). `Macaw.Data.Derived.Join.join(rows, schema, outputs)` hands rows that carry, beside their own fields, the fields of every per-identity source over the same input: `outputs` a list of `{id, output_schema, output_rows}`. Each row's identity is looked up in each output, and the output's every field but its identity is written on the row as the **string** `"<id>.<field>"` (`"health.state"`, `"health.trend"`), `nil` for a row whose entity the output does not hold (the source loading, or failing before its first answer). The joined name is a string, never an atom: it is made from a document's names.

`Join.schema(schema, outputs)` is the input's schema with each joined field described as the source's output describes it, without `identity`, so a joined field's `values` reach a component's legend and coverage checks; its version is computed as any schema's. Which sources a reader sees (the ones its scope resolves to, §3) is the owner's to decide; on a Macaw page, `macaw_compose`'s.

```test:derived-join-fields
each row gains every per-identity output's fields but its identity as "id.field" strings, nil where its entity has no output row; the joined schema describes them as the outputs do, without identity, and no atom is made
```

### 1.5 The map and JSON forms {#derived-forms}

`Macaw.Data.Derived.to_map/1` is the source's **map form**, JSON-ready, with every name a string:

| Key | Map form |
|---|---|
| `"id"` | its string |
| `"from"` | a list of `[name, window]` pairs: a short id its string, `{:source, name}` the object `{"source": name}`, a path a list of strings; the window `null`, `{"last": n}`, or a request object (§2.2) of the keys it has: `"window"` `[from, to]`, `"box"` `{"west", "south", "east", "north"}`, `"region"` a list of `[field, [from, to]]` pairs, `"latest"` a boolean, each time `{"$time": …}` |
| `"schema"` | `Macaw.Data.Schema.to_map/1` of it ([01 §1.11](01-sources.md#sources-schema-json)) |
| `"elixir"` | its string, or absent |
| `"function"` | its string, or absent |
| `"per"` | `"identity"`, `["identity", name]`, or absent |

`new/1` reads that form back: `new(to_map(derived)) == {:ok, derived}` for every valid source. `to_json/1` is the map form encoded, and `from_json(json, opts)` reads JSON through `macaw_layers`' gates (`Macaw.Layers.Document.read/3`: bytes, nesting and counts within `Macaw.Layers.Limits`, `opts` tightening them) before `new/1`. A pair list is used wherever a JSON object's keys would lose a name's spelling. A document that holds derived sources (a `macaw_compose` page) writes each in this form, with no tag of its own.

```test:derived-forms-inverse
to_map and new are exact inverses for valid sources, every name a string, every input form, window form and per form among them; to_json and from_json likewise, and from_json refuses input over the limits before reading it
```

## 2. Inputs {#derived-inputs}

Inputs are **sources, by name**: anything that satisfies the source contract ([01](01-sources.md#sources-contract)). That covers feeds and other derived sources, and, on a Macaw page, state sources and exports, which `macaw_compose` makes satisfy the contract ([macaw_compose 03](https://gitlab.conet.yarina.org/dco-tek/macaw_compose/-/blob/main/spec/03-state.md#state-sources)). `macaw_data` knows nothing of pages; it sees named sources.

The function may take all of a scope's inputs together. metresis's series naming is computed once over every metric's feed. (metresis.md C2.)

An input is `{name, window}`.

### 2.1 Names and keys {#derived-input-names}

**The name** says what is read:

- a **short id**, a name (a string, or an atom Elixir input spells it with, held as its string) that is a derived source's id or a source's name, resolved as §3 says: a derived source from the inside out, else a source; a dotted name never splits (`"vm.memory.total"`);
- **`{:source, name}`**, a source's own name, which no derived source may shadow;
- a **list of names**, a derived source's full path (§3), each held as its string.

The function reads the input under its **key**: the short id, the source's name, or a path's last name, its string (`Macaw.Data.Derived.key/1`). Two inputs of one key are `{:duplicate_input, key}`: an atom and a string of one spelling are one key.

```test:derived-input-keys
a short id, a source name and a path each read under their key's string; an atom and a string of one spelling are one key, so two such inputs are a duplicate
```

### 2.2 Windows: the history each input needs {#derived-input-windows}

**The window** says how much history the function needs (visualize#643, D-168):

- `nil`: everything the owner holds of the input;
- `%{last: n}`, `n` a positive integer: **each identity's newest `n` rows** by the input's window field when its schema declares identity, else the newest `n` rows;
- a **request**: a map of any of `window`, `box`, `region` and `latest`, the request fields of [01 §2.3](01-sources.md#sources-request), the rows they select, **finished** as the runtime finishes a delivery (`Macaw.Data.Source.Finish`, [01 §2.4](01-sources.md#sources-finishing)) and checked against its input's schema in context (§1.1).

The function **gets what is there** (visualize#643, settled question 3): a window of `last: 20` over an entity with three rows hands it three, and its clauses can match on the length (`[a, b, c | _]`). `Macaw.Data.Derived.window(rows, window, schema)` is the window applied to rows.

**Nothing is aligned** (visualize#643, settled question 13): each input's rows are its current window, and a function over inputs that arrive at different rates aligns them itself.

**How a function reads its inputs.** The function receives the inputs as one map from key to rows: `fn %{hosts: rows} -> … end`.

- **A stored function reads a name as it reads its own literals** (§6.1): an input's key, a row's field and a row's category value is the atom of a word an allowed function takes (`:ok`, `:error`, `:day`, `:first`, …), else its string. So a row's `:ok` is the function's `:ok`, a row's `:warning` and the function's `:warning` are both `"warning"`, and `row.field` reads either spelling (§6.3).
- **A host's function** (§7) receives the inputs keyed by their strings (`inputs["hosts"]`) and each row as its source gave it.

Whichever function answers, its rows are keyed by their fields' strings in the output (§1.2). `Macaw.Data.Derived.argument(derived, inputs)` is that first argument, each input `%{name, rows, schema}` as its owner read it.

```test:derived-argument
the first argument is the inputs keyed by their key; a stored function reads keys, fields and category values as its literals, a word's atom else the string, a host's function its rows as given
```

```test:derived-input-history
nil hands every row, last n each identity's newest n rows by the window field (or the newest n without identity), fewer when fewer are there; a request window is the finished rows of its window, box, region and latest
```

### 2.3 The context {#derived-context}

A function of **two arguments** is called with the inputs and its **context**, the facts that stand beside the rows and not in them. **The arity decides:** `fn inputs, context -> … end`, or `defsource name(inputs, context)` (§7), takes it; a function of one argument is called with its inputs alone. `Macaw.Data.Derived.Context.new(inputs)` builds it, a map with **string keys** throughout:

```elixir
%{
  "inputs" => %{key => %{
    "schema" => %{field => description},  # the input's schema, every name a string
    "window" => [from, to] | box | nil,    # the delivery's served facts (01 §3)
    "resolution" => term() | nil,
    "capped" => boolean()
  }}
}
```

- **`"inputs"`** is keyed as the first argument keys its inputs (a stored function's by its literals' rule, a host's by the key's string), so `for {key, rows} <- inputs` finds each input's facts under the same `key`.
- **`"schema"` is the input's schema as data, not a `%Schema{}`**: a struct is restricted in a stored function (§6.1), and reading a struct's fields would bind a stored function to the library's internals. It is a map from each field's name to its description, each description's keys their strings (`"type"`, `"unit"`, `"bounds"`, `"continuity"`, `"order"`, `"status"`, …), a field's `"values"` its declared values in order, an entry a map of its keys' strings (`%{"value" => v, "name" => "OK", "color" => c}`), a bare value itself. It is a term, not JSON: a value is the term the schema holds. An input that is a derived source gives its output's schema.
- **`"window"`, `"resolution"` and `"capped"` are the delivery's** `served` facts, as the source answered them: the window actually served, the rows' spacing, whether the answer stopped short. They are not the input's own window (`last:` or a request), which says how much of the delivery the function is handed. A derived source's output is a delivery with `nil`, `nil` and `false`.
- **No clock.** The context carries no "now". A source runs only when it is marked (§8.2), and a function that read the time would answer differently on every pulse with nothing marking it. A window that moves with the clock is its input's (`"window"`).
- **No variables.** visualize's context also carries its scope's variables (visualize D-228). Here a variable, a selection, or anything else a function depends on is **an input like any other**: on a Macaw page, a state source. It is read as rows, its change marks the source as any input's does, and its fields are checked as any input's are.
- **Values never leave it.** A context's values are the data as much as the rows are, so no fault's detail carries one (§6.4).

A stored function reads its context with `[]`: `context["inputs"]["hosts"]["schema"]["cpu"]["bounds"]`.

```test:derived-context-facts
the context holds each input's schema as string-keyed data and its delivery's window, resolution and capped, keyed as the inputs are; it has no clock and no variables; a derived input gives its output's schema and nil, nil, false
```

## 3. Scoping {#derived-scoping}

A derived source is defined at a scope: on a Macaw page, the page, a surface, a container or a cell ([macaw_compose 03](https://gitlab.conet.yarina.org/dco-tek/macaw_compose/-/blob/main/spec/03-state.md#state-dag)). `macaw_data` knows scopes only as **paths**: a source's path is its scopes' names from the outside in, then its id, a **list of strings** (visualize#643, settled question 1), so a name that holds a dot cannot break it. It is shown **dotted**, `ops.health` (`Macaw.Data.Derived.dotted/1`).

**One resolver, from the inside out** (visualize#643, settled question 2). `Macaw.Data.Derived.resolve(paths, scope, ref)` finds what a reference names, given the paths of every definition (a list, or a map keyed by path) and the scope it is read from (a scope's path): `{:ok, path}` or `:error`.

- A **short id** is looked for in the scope, then in each scope around it, outward: from `["ops", "box"]`, `"health"` is `["ops", "box", "health"]`, else `["ops", "health"]`, else `["health"]`. **The nearest definition wins**, so an inner definition shadows an outer one. An atom and a string of one spelling are one id, and a scope or a path given with atoms is read by spelling.
- A **full path**, a list, names exactly one: that definition or nothing, from any scope.
- `{:source, name}` is never resolved: it names a source (§2.1).

**Cycles are refused, named.** The sources and the sources they read are a directed graph. Each strongly connected component that holds a cycle (by `:digraph_utils.cyclic_strong_components/1`, a source that reads itself included) is `{:cycle, paths}`, `paths` every member's path, sorted. A count of what is left after a topological sort cannot name the cycle, since it also holds every source downstream of one (visualize#643's prior-art review). `Macaw.Data.Derived.cycles/1` answers them over a map of definitions by path whose inputs are resolved.

```test:derived-resolve
a short id resolves from the inside out, the nearest definition shadowing an outer one; a full path names exactly one; a source name never resolves to a derived source; dotted joins a path; atoms and strings of one spelling are one name
```

```test:derived-cycles
each cycle, a self-read included, is named once with every member's path, sorted; sources downstream of a cycle are not named; an acyclic set has none
```

## 4. What stays in the source {#derived-database}

<!-- surfex: class source-rule -->

Derivations that need raw rows or the store stay **inside the source**, never in a derived source:
- counter-reset-aware deltas;
- circular means;
- percentiles from raw rows ("a p95 of p95s is not a p95");
- rollup vs raw selection.

(metresis.md C2.)

## 5. Transforms and aggregates {#derived-operations}

<!-- surfex: deferred #83: transforms and aggregates, step 6 -->

The operations a visualize design applies to its data and the operations a derived source may call are **the same code**, in `macaw_data` beside derived sources (macaw_compose#22, decision 11):
- **the transform behavior,** with the table operations: filter, sort, take, fold, sum, bin, stack, window, lttb, m4 and spectrum;
- **the aggregate behavior,** with its statistics.

A computation can therefore move between a design and a derived source unchanged, and a metresis feed and a visualize chart reduce data the same way.

- **Transforms that need geometry** (they declare `needs: [:frame]` or `needs: [:projection]`: layouts, geographic operations) stay in the package that draws, and register through the registry like any other member ([macaw_compose 12](https://gitlab.conet.yarina.org/dco-tek/macaw_compose/-/blob/main/spec/12-registry.md)). A derived source has no frame, so they are never on its allowlist.
- **The sandbox allowlist is generated** from the registered members of enabled packages, never written by hand, so enabling a package is the only way to widen it. Until step 6 (macaw_compose#83) lands, the allowlist is §6.2's.

## 6. The sandbox {#derived-sandbox}

`Macaw.Data.Derived.Sandbox`: the checker (§6.1) a stored function passes before it is compiled, the allowlist it is held to (§6.2), compiling once (§6.3), and the bounded runner every function is called through (§6.4). It is the one place in the family that runs untrusted code.

### 6.1 The checker {#derived-checker}

`Sandbox.check(source, opts)` reads a stored function and answers `{:ok, quoted}`, the checked AST, or `{:error, faults}` with **every** fault found, each `{line, reason}`, `line` the source line the fault is on (`nil` for a fault of the whole source), ordered by line. It evaluates nothing. Its options are `arity:` (the arities the function may take, an integer or a list of them, `[1, 2]`), `fields:` (the field names a `row.field` may read; `nil`, the default, reads any) and `max_source:` (the most bytes a source may have, `10_000`, tighten-only, §6.4).

- **Parsing.** A source longer than `max_source` is `{:too_long, max, size}` and is not parsed. Otherwise it is parsed with a **static atoms encoder** (`Code.string_to_quoted(source, static_atoms_encoder: …, existing_atoms_only: true)`): every name the source writes comes back as its string, and one pass gives each its meaning by where it stands, from tables the library builds when it compiles. No atom is ever made from a stored function, and what parses does not depend on what the node has loaded:
  - a **call's name** (an allowed or excluded function of an allowed module, a `Kernel` function or macro, a special form) is the checker's own atom; one the checker does not know is a sentinel it refuses by the name as written (`{:restricted, {"frobnicate", 1}}`);
  - a **variable** is one of a fixed pool of the library's own atoms, one per distinct name (256 for the plain and 256 for the `_`-prefixed; more is `{:too_many_variables, 256}`), its written name kept beside it for every fault that names it;
  - an **alias part** of an allowed module (`Enum`, `Map`, `Macaw`, `Data`, `Reduce`, …) is its atom; any other is its string, which the checker refuses as an alias;
  - a **literal atom, a map key or a keyword key** is the atom of a word an allowed function takes or the checker refuses by name (`:ok`, `:error`, `:desc`, `:second`, `:trim`, `:do`, `:__struct__`, `:erlang`, …), else **its string**: `:warning` in a source is `"warning"`, and `:"Elixir.File.Stream"` is a string that names no module;
  - a **map read** `row.field` keeps the field as written, and reads it by spelling when the function runs (§6.3).

  Any other syntax error is `{:syntax, message}`, the parser's own words.
- **The shape.** The source is **one `fn`**; anything else is `{:not_a_function, arity}`, `arity` the option as given. Its clauses take **one arity, and one `arity:` holds**: clauses that disagree (`fn a -> …; a, b -> … end`), or agree on an arity `arity:` does not hold, are `{:fn_arity, arities}`, the clauses' arities in the order they are first written.
- **The walk.** Every form of the AST is held to the allowlist of §6.2, before macros expand, in one of three contexts: an **expression**, a **pattern** (a clause's head, the left of `=`, `<-` in `for` and `with`) and a **guard** (after `when`). Whatever the allowlist does not name is refused: a remote call is `{:restricted, {module, function, arity}}`, a local one `{:restricted, {function, arity}}`. So `send/2`, `receive`, `spawn/1`, `self/0`, `try`, `raise/1`, `throw/1`, `exit/1`, `apply/2,3`, `import`, `require`, `alias`, `quote`, `unquote`, `defmodule`, `binding/0`, `dbg`, a module attribute (`{:restricted, {:@, 1}}`), every sigil (`{:restricted, {:sigil_r, 2}}`), `inspect/1`, `then/2`, `length/1`, `elem/2` and the rest of `Kernel` are refused by name. **A failure is the runner's to report, not something the function catches**, so `try` and `raise` are refused with the rest.
- **A map read is not a call.** `row.field` and `module.function(x)` share one AST shape. The receiver decides: an alias of an allowed module or the atom `:math` makes a **remote call**, held to the module's list at the arity written, with the arguments a `|>` adds counted; any other receiver with **no parentheses and no arguments** is a **map read**; any other receiver with parentheses or arguments is a **dynamic call**, `{:dynamic_call, name}`, refused, since its module is unknown when the function is checked. An anonymous call `f.(x)` is allowed: a function value a stored function can reach was made by the function itself.
- **A field is a schema's.** With `fields:` given, the name of every map read must be one of them, by either spelling: `{:unknown_field, name}` otherwise. A derived source gives the fields of its inputs' schemas and its own. A map read whose receiver is the function's context (its second parameter, as a clause's head names it with a variable), or a read of one, is not held to `fields:`.
- **A collectable is a literal.** `for … into:` and `Enum.into/2,3` take only a literal empty `%{}`, `[]` or `""`; any other target is `{:into, :literal}`. `for`'s `uniq:` is a literal boolean (`{:uniq, :literal}`); `reduce:` is any expression.
- **No struct, no module as a value.** A struct literal is `{:restricted, :struct}`. An alias anywhere but a remote call's receiver, an atom literal whose name begins `Elixir.` and the atom `:__struct__` are `{:restricted_atom, atom}`, and a special-form variable (`__MODULE__`, `__ENV__`, `__CALLER__`, `__DIR__`, `__STACKTRACE__`) is `{:restricted, {name, 0}}`: a map naming a module under `:__struct__` dispatches a protocol to that module's implementation, a call the checker never saw. The modules a value from the data can name (`DateTime`, `NaiveDateTime`, `Date`, `Time`, `Calendar.ISO`) implement none of `Enumerable`, `Collectable` and `Access`, so a struct rebuilt from a row's time raises rather than calling anything (`:raised`, §6.4).
- **What compiles.** A variable read or pinned before it is bound in its scope is `{:undefined_variable, name}`; a guard holds only the guard-safe part of the list, else `{:guard, call}`; a pattern holds only patterns (literals, variables, `^`, lists, tuples, maps with literal or pinned keys, binaries and `<>` with a literal prefix, `=`), else `{:pattern, form}`. Each is a fault the compiler would raise for; finding it here names its line.

A refused function's faults are its check's and are shown at their lines; nothing is evaluated until the check passes. **Cost is not the checker's:** `1..10_000_000_000`, a large `**` or a comprehension over a huge range pass the check, and the runner's heap limit and reductions cap stop them (§6.4).

| Reason | Meaning |
|---|---|
| `{:too_long, max, size}` | the source is `size` bytes, more than `max_source` |
| `{:too_many_variables, max}` | the source binds more distinct variables than the pool holds, refused before the walk |
| `{:syntax, message}` | the source does not parse |
| `{:not_a_function, arity}` | the source is not one `fn` |
| `{:restricted, {module, function, arity}}` | a remote call the allowlist does not name; `module` the atom for `Kernel`, an allowed module or an Erlang one, the alias as written for any other (`"Process"`) |
| `{:restricted, {function, arity}}` | a local call or a special form the allowlist does not name |
| `{:restricted, :struct}` | a struct literal |
| `{:restricted_atom, atom}` | an atom naming an Elixir module, `:__struct__`, or an alias as a value, given as written |
| `{:dynamic_call, name}` | a call whose receiver is not an allowed module |
| `{:unknown_field, name}` | a map read of a name `fields:` does not hold |
| `{:into, :literal}` | a collectable other than a literal empty `%{}`, `[]` or `""` |
| `{:uniq, :literal}` | `for … uniq:` that is not `true` or `false` |
| `{:undefined_variable, name}` | a variable read, or pinned, before it is bound |
| `{:guard, call}` | a call in a guard that is not guard-safe |
| `{:pattern, form}` | a form in a pattern that is not a pattern |
| `{:fn_arity, arities}` | the clauses take different arities, or one `arity:` does not hold |
| `{:compile, message}` | the checked source does not compile (§6.3) |

`Sandbox.format_error/1` words one fault: `line 3: Process.send/3 is not allowed in a derived source`.

```test:derived-checker-refusals
every refused construct (send, receive, spawn, try, raise, apply, import, quote, sigils, attributes, struct literals, module atoms, special-form variables, dynamic calls, unknown functions) is refused by name at its line, every fault of a source reported at once; format_error/1 words each reason as a line
```

```test:derived-checker-shape
a source over the size limit is not parsed; one that is not one fn, or whose clauses disagree on arity or take one arity does not allow, is refused; a syntax error is the parser's words
```

```test:derived-checker-names
parsing a stored function makes no atom: unknown names, keys and atom literals come back as strings and an interpolated atom is refused
```

```test:derived-checker-reads
a map read is not a call, a dynamic call is refused, a field outside fields is unknown, a context read is not held to fields, and only a literal empty collectable is allowed
```

```test:derived-checker-compiles
a variable read before it is bound, a call in a guard that is not guard-safe and a non-pattern in a pattern are each refused at their line
```

### 6.2 The allowlist {#derived-allowlist}

`Macaw.Data.Derived.Sandbox.Allowlist` holds what a stored function may call as **explicit lists**, never "a module minus a few": visualize#643's allowlist, decided 2026-10-15 (start small, and grow one entry at a time).

- **Control:** `case`, `cond`, `if`, `unless`, `with`, `for`, `fn`, pattern matching (`=`), guards (`when`), the pin `^`, blocks, and `&` captures, of an allowed function (`&Enum.sum/1`, `&max/2`) or of an expression over `&1`, `&2`, ….
- **Math and comparison:** `+`, `-`, `*`, `/` and unary `-` and `+`; `==`, `!=`, `===`, `!==`, `<`, `>`, `<=`, `>=`; `and`, `or`, `not`, `&&`, `||`, `!`; `in` and `not in`; `div/2`, `rem/2`, `abs/1`, `round/1`, `trunc/1`, `min/2`, `max/2` and `**/2`; and every `is_*` guard of `Kernel`.
- **Data:** literals, ranges (`..`, `..//`), tuples, lists (`|`, `++`, `--`), maps (`%{}`, `%{m | k: v}`), binaries (`<<>>` with the segment types `binary`, `bits`, `bitstring`, `bytes`, `integer`, `float`, `utf8`, `utf16`, `utf32`, `signed`, `unsigned`, `big`, `little`, `native`, `size/1` and `unit/1`; `<>`), `|>`, `[]` access (`row[:key]`, `Access.get/2`) and `row.field`; `to_string/1`, and with it **string interpolation**: `"#{x}"` is a binary whose segment calls `Kernel.to_string/1`, so a label is `"#{row.host}: #{row.load}"`. An atom written with interpolation (`:"a#{x}"`) stays refused, as `{:restricted, {:erlang, :binary_to_existing_atom, 2}}`; a sigil with interpolation is refused as every sigil is.
- **Modules:** `Enum`, `Map`, `Keyword`, `String`, `Integer`, `Float`, `:math` and `Macaw.Data.Reduce`, each an explicit list of `{function, arity}`. Every export of these modules on the Elixir and OTP the library is built with is on its module's allowed list or its excluded list, and the test suite holds each module's exports to the union of the two, exactly: a new Elixir that adds a function fails that test, and the function is reviewed before it is allowed. `Macaw.Data.Reduce` is the library's own: `lttb/2,3` and `m4/2,3` are pure, an accessor argument is an `fn` the stored function made. `Integer.is_even/1` and `Integer.is_odd/1` are macros and allowed.

| Module | Excluded | Why |
|---|---|---|
| `Enum` | `random/1`, `shuffle/1`, `take_random/2` | `:nondeterministic`: a function gives the same output for the same input |
| `Enum` | `chunk/2,3,4`, `filter_map/3`, `partition/2`, `uniq/2` | `:deprecated`; their replacements are allowed |
| `Enum` | `__in__/2` | `:internal` to the compiler |
| `String` | `to_atom/1`, `to_existing_atom/1` | `:atoms`: atom creation, and probing which atoms exist |
| `String` | `to_char_list/1`, `strip/1,2`, `lstrip/1,2`, `rstrip/1,2`, `ljust/2,3`, `rjust/2,3`, `valid_character?/1` | `:deprecated` |
| `Integer` | `to_char_list/1,2` | `:deprecated` |
| `Float` | `to_char_list/1,2`, `to_string/2` | `:deprecated` |
| `Map` | `map/2`, `size/1` | `:deprecated` |
| `Keyword` | `delete/3`, `map/2`, `size/1` | `:deprecated` |
| `:math` | none | pure; random numbers live in `:rand`, which is not on the list |
| `Macaw.Data.Reduce` | none | pure |

`Enum.into/2,3` is allowed with a literal empty target only (§6.1). Everything else these modules export is allowed, `String.splitter/2,3` included.

**The guard-safe part** is what Erlang allows in a guard: the comparison, arithmetic and boolean operators (`and`, `or`, `not`; not `&&`, `||` or `!`), `in` over a literal list or range, `div`, `rem`, `abs`, `round`, `trunc`, `min`, `max`, every `is_*` guard, `Integer.is_even/1`, `Integer.is_odd/1` and a map read.

`Allowlist.modules/0` is the eight modules; `allowed/1` a module's allowed `{function, arity}` list, `excluded/1` its excluded list with each reason (`:nondeterministic`, `:deprecated`, `:atoms`, `:internal`), and `kernel/0` the `{function, arity}` of every `Kernel` function and special form a function may call. Step 6 (§5) adds the registered aggregates and transforms to `modules/0`; nothing else widens it.

```test:derived-allowlist-exact
for each allowed module, the allowed and excluded lists are disjoint and together exactly its exports on this Elixir; every exclusion carries one of the four reasons; the Kernel list names only Kernel's functions and special forms, every is_* guard among them
```

```test:derived-allowlist-calls
a call of every allowed module's allowed function passes the checker, every excluded one is refused, and the guard-safe part alone passes in a guard
```

### 6.3 Compiling once {#derived-compile}

`Sandbox.compile(source, opts)` checks the source (§6.1) and, when it passes, compiles it **once into a closure**: `{:ok, %Sandbox.Compiled{hash, fun, arity, warnings}}`, or `{:error, faults}` with the checker's faults. It takes the checker's options and the runner's (§6.4).

- **Rewritten first.** Every map read in a body becomes `Macaw.Data.Derived.Sandbox.Runtime.get(receiver, field)`, which reads the row's key of the field's spelling, an atom or a string, as `Macaw.Data.Table.get/2` finds it, making no atom, and raises as a map read does when the row has neither. In a guard, which calls nothing, it becomes `:erlang.map_get(field, receiver)` of the field as the function's inputs spell it. Either way an atom receiver is not a module: in Elixir 1.20 `x.name` on an atom still calls the function `name/0` of the module the atom names, so a stored `m.halt` with `m` bound to `:erlang` would halt the node; both reads take a map and raise on anything else. The function is evaluated with `require Integer` before it, for `is_even` and `is_odd`. The rewrite is the library's own code, after the check, so the checked AST is what runs.
- **An interpreted closure.** The rewritten `fn` is evaluated with `Code.eval_quoted/3`, once, into an ordinary function value (visualize#643, settled question 8): no module is made per function, so compiling makes no atom and leaves nothing to purge. The compiler's warnings are kept in `warnings`, each `{line, message}`, through `Code.with_diagnostics/2`, and printed nowhere.
- **In the bounded runner.** The evaluation runs as any call does (§6.4). A source the checker passed but the compiler refuses is the fault `{nil, {:compile, message}}`, the compiler's exception message, read from the process's exit reason and never rescued.
- **The cache is a value.** `%Macaw.Data.Derived.Sandbox.Cache{}`, held by whatever owns the functions (the engine, §8), not a process or a table. `Cache.compile(cache, source, opts)` is `{:ok, compiled, cache}` or `{:error, faults, cache}`, keyed by the **SHA-256 of the source** together with the arities and the fields it was checked against. A source compiled before is a map lookup, a refusal included. `hash` is that SHA-256, 64 lowercase hexadecimal digits. The cache never evicts; its owner replaces it.

```test:derived-compile-once
a checked source compiles once into a closure that reads row.field by either spelling and raises on a non-map; warnings are kept, not printed; a checked source the compiler refuses is one compile fault; the cache answers a second compile, a refusal included, from its key without checking again
```

### 6.4 The bounded runner {#derived-runner}

`Sandbox.run(function, args, opts)` calls a function (a `Compiled`, or a host's function value) with a list of arguments in a **process of its own** and answers `{:ok, value}` or `{:error, kind, detail}`. A host's function (§7) is trusted, so it skips the checker, but it runs here too: a runaway in it is contained like one in a stored function.

**The bounds are tighten-only** (macaw_compose#82). The defaults are the ceiling: `max_reductions:` `100_000_000`, `timeout:` (milliseconds) `30_000`, `max_heap:` (words) `10_000_000`, 80 MB on a 64-bit host, and §6.1's `max_source:` `10_000` bytes. An option above its default is `ArgumentError`, as a `Macaw.Layers.Limits` loosening is. Set too low, every call over it fails loudly, as `:reductions`, `:hung` or `:memory` at its source.

- **The process** is spawned through `Macaw.Data.Bounded.run/2` ([01 §9](01-sources.md#sources-conformance)) with `:monitor` and its `max_heap_size` set at the spawn (`%{size: max_heap, kill: true, error_logger: false, include_shared_binaries: true}`), so there is no moment it runs without the limit. The arguments are copied into it and count against its heap. It carries the caller in its `$callers`.
- **Cost is counted, not timed** (visualize#852, D-220). What a call costs is the **reductions** its process spends, collections included, and the cap is the limit that stops a runaway. A wall-clock bound judged the host instead: one second bought about 148 million reductions idle and 41 million saturated, so the same program passed idle and failed loaded. Two readings decide the verdict, and neither depends on the load:
  - **a call that answers is judged by its own count**, read as the function returns: over the cap is `{:error, :reductions, max_reductions}` even though a value came back;
  - **a call still running is read every 10 ms** and killed at the first reading over the cap. The overshoot is bounded, at most 10 ms of one scheduler's work, and is CPU the host spends, never a verdict: a call that finished within the cap and answered as the kill was sent is still `{:ok, value}`.
- **The cap is derived** (visualize#852's root-cause note): `100_000_000` reductions is about 4,500 times the costliest stored document visualize has to compile and about 7,500 times its run over its four hosts, so a per-identity batch over some 180,000 input rows fits. A runaway reaches it in about 0.7 s idle and 2.4 s saturated.
- **Liveness is separate from cost.** A call blocked in `receive` spends no reductions, so no cap stops it. `timeout:` is a generous wall-clock bound for that case alone: a call that has not answered when it passes is killed and reported as **hung**, `{:error, :hung, timeout}`, never as slow. A stored function cannot `receive` (§6.1).
- **The outcome is read from the process, never rescued.** A result within the cap is `{:ok, value}`; one over it `{:error, :reductions, max_reductions}`. A `:DOWN` of `:killed` is the heap limit, `{:error, :memory, max_heap}`. The caller's own kills are `:reductions` and `:hung`. Any other exit is a raise, `{:error, :raised, name}`, `name` the exception's module as `Exception.normalize/3` reads the reason, **never its message**, which may quote the rows. A killed process is waited for before the call returns, so nothing it does outlives the call.

| Kind | When | Detail |
|---|---|---|
| `:restricted` | the checker refused the function, or the compiler did (§6.1, §6.3), or it failed validation in context (§1.1) | the faults |
| `:reductions` | the call's process spent more than `max_reductions` | the cap |
| `:hung` | the call did not answer within `timeout`: it is blocked, not slow | the bound, milliseconds |
| `:memory` | the process's heap passed `max_heap` and the VM killed it | the limit, words |
| `:raised` | the function raised | the exception's module |
| `:nonconforming` | the function answered rows that are not its schema's (§1.2) | the index and field, never a value |

`:restricted` and `:nonconforming` are not the runner's, but a derived source's fault (§8.3) is one of the six.

**What the limits do not bound.** A heap limit is checked when the process collects, so a single allocation larger than the limit (`String.duplicate("x", 10_000_000_000)`, a huge `**`) is made before the VM kills the process: the host must have room for one such allocation. The check does not refuse these functions, since cost is the author's to weigh (visualize#643's second allowlist decision).

```test:derived-runner-outcomes
a call answers its value; a raise is its exception's module and never its message; a heap overrun is memory; a call blocked in receive is hung at the bound; nothing the call started outlives it
```

```test:derived-runner-reductions
a runaway is stopped as reductions at the cap; a call that answers over the cap is reductions though a value came back; a call within it is ok
```

```test:derived-runner-tighten
each bound may be lowered and refuses a value above its default
```

### 6.5 Gates that ship with the sandbox {#derived-gates}

The sandbox is the one place in the family that runs untrusted code, so it never loses a check in transit. It moved from visualize to `macaw_data` with every gate, and macaw_data's CI runs them:

- **the checker's refusal tests:** every refused construct, refused by name and line (§6.1);
- **the allowlist's exactness test** (§6.2);
- **the reductions budget, the separate liveness bound and the heap limit,** each tested by a function that exceeds it (visualize#856, #857);
- **the attack suite:** visualize's sandbox attacks (escaping through a protocol, an atom, a module name, an alias, a map read on an atom, the compiler, the code server), each refused or contained;
- **the load suite:** every verdict the same idle and with every scheduler saturated;
- **the property tests:** generated inputs never crash the caller, never leak a data value in a fault, and always yield a schema-conforming output or a fault;
- **the atom gate**, `ci/atoms.exs`: no atom is created from untrusted input. It fails on any call that makes an atom from a string (`String.to_atom`, `:erlang.binary_to_atom`, `List.to_atom`, `:erlang.list_to_atom`) or an interpolated atom literal on any line of a `.ex` file under `lib/`, outside its allowlist `ci/atoms_allowlist.exs`. Each entry names a file, a fragment of the lines it allows, how many lines hold it, its class and its reason; an entry whose count is not what the file holds fails too, so the list cannot go stale. `String.to_existing_atom` makes none and is not matched. The classes are visualize's (D-195): (a) a closed library vocabulary, (a-host) a vocabulary host code registers, (d) a set the library bounds. A name a document or a client declares, and one derived from such names, is a string, so an entry of either class fails. Ported from visualize's `mix vis.atoms`.

Adopters keep their own sandbox until `macaw_data` passes all of them.

```test:derived-attacks
each of visualize's sandbox attacks is refused by the checker or contained by the runner, and none reaches the caller, the node or an atom
```

```test:derived-load
the runner's and the checker's verdicts are the same idle and with every scheduler saturated
```

```test:derived-properties
for generated stored functions and inputs, a run never crashes the caller, no fault holds a data value, and the answer conforms to its schema or is a fault
```

```test:derived-atom-gate
the atom gate passes this library; it fails on an atom made from a string or an interpolated atom outside the allowlist, on an allowlist entry whose count is stale, and on an entry of a document's or a client's names
```

## 7. Host functions: `defsource` {#derived-functions}

A host writes a derived source's function as Elixir in its own module, tested with ExUnit:

```elixir
defmodule MyApp.Sources do
  use Macaw.Data.Derived.Functions

  defsource health(rows) do
    cpu = Enum.map(rows, & &1.cpu)
    %{state: if(List.last(cpu) > 90, do: :error, else: :ok)}
  end

  defsource bins(inputs, context) do
    %{"bounds" => [lo, hi]} = context["inputs"]["hosts"]["schema"]["cpu"]
    ...
  end
end
```

- **`use Macaw.Data.Derived.Functions`** imports `defsource/2` and compiles `__derived__/0`: each function's name, its **arity** and its **source text**, `[{name, arity, source}]` in definition order. `defsource name(inputs) do … end` is a public `def` of one argument, and `defsource name(inputs, context) do … end` one of two, which takes the context (§2.3). One name has one arity: clauses of one name and two arities are a `CompileError`, as a head of any other arity is; a function of several clauses is defined clause by clause and listed once, its source the clauses together. The text is captured **when the module compiles** (`Macro.to_string/1` of each clause as an `fn` clause), because a release strips the debug information a later reading would need.
- **Trusted, and bounded.** A host's function is the host's code: the checker does not read it, and it may call anything. It still runs through the bounded runner (§6.4), so a runaway in it ends as `:memory` or `:reductions` like a stored one, and one that blocks ends as `:hung`.
- **Registered explicitly, default closed.** `Macaw.Data.Derived.Functions.registry(modules)` is the given modules' functions, `%{name => {module, arity}}`, keyed by the name's string; a module without `__derived__/0`, or a name two modules define, is an `ArgumentError`. **No application environment is read:** a function is callable only when its module is passed to the engine (`functions:`, §8.4). A source names its function by its string and finds it by spelling; one naming a function the registry does not hold is `{:undeclared, :function, name}` in context (§1.1).
- **Versioning is git's** (visualize#643's review). A document names a host function; the code that runs is the host's current code, and its history is the host's repository's. A stored function travels with its document.

```test:derived-defsource
defsource defines a public function of one or two arguments, listed by __derived__ with its arity and its source text in definition order, a multi-clause function once; two arities of one name do not compile
```

```test:derived-registry
the registry maps each function's name string to its module and arity from the modules given, and nothing else; a module without __derived__ and a name defined twice are refused
```

## 8. The engine {#derived-engine}

<!-- surfex: deferred #117: the engine -->

A derived source runs **where its inputs are fetched**, once, and its result is shared by every reader: a trend over twenty values is computed once, not in five places (visualize#643). `Macaw.Data.Derived.Engine` is the engine, a **value** its owner holds and calls from its own callbacks, as a `Macaw.Data.Source.Push` is held ([01 §4](01-sources.md#sources-push)): one owner, and no second process between the owner and its sources' rows. On a Macaw page the owner is `macaw_compose`'s runtime.

### 8.1 Defining: references, cycles, ranks {#derived-engine-define}

<!-- surfex: deferred #117: the engine -->

`Engine.new(sources, opts)` takes the derived sources by path (§3) and defines them in three steps, each over all of them. A set that fails any step is not defined: `{:error, faults}`, each `{path, at, reason}`.

1. **References.** Every input's name resolves (§3) from the scope the source is defined in: a short id to a derived source from the inside out, else to a source of `sources:` by spelling; `{:source, name}` to a source; a list to a derived source's full path. A name that resolves to nothing is `{:unknown_input, name}` at `[:from, i]`. A `function` the registry (`functions:`) does not hold is `{:undeclared, :function, name}` at `[:function]`.
2. **Cycles.** Refused, named (§3): `{:cycle, paths}` at `[:from]` of the first of its members.
3. **Ranks.** A source that reads only sources has rank `0`; any other, one more than the greatest rank of the derived sources it reads. Sources run in rank order, so a source always runs after its inputs.

Each stored function is compiled once into the engine's cache (§6.3) when it is defined.

```planned-test:derived-engine-defines
a set of derived sources is defined with every input resolved and ranks assigned; an unknown input, an undeclared function and a cycle (named) each refuse the whole set at their path
```

### 8.2 Pulses {#derived-engine-pulse}

<!-- surfex: deferred #117: the engine -->

**A pulse is the unit of recompute** (visualize#643, settled questions 4 and 11). `Engine.push(engine, deliveries, schemas, now)` shows the engine its sources' latest deliveries and schemas, by name. A source whose delivery is not the one the engine last saw has **changed**, and every derived source that reads it is marked. The first mark after a pulse makes the next pulse **due** `debounce:` milliseconds after `now` (`0`: due at once), so changes within it, from any number of pushes and sources, are one pulse. `now` is the owner's monotonic milliseconds: the engine never reads a clock. `Engine.run(engine, now)` runs a due pulse:

- **In rank order, each source at most once.** The marked sources run from the lowest rank to the highest. A source whose answer differs from its last one marks the sources that read it, which run later in the same pulse, after every input they have; a source whose answer is unchanged marks nothing, and an unmarked source does not run. A source with two inputs that changed in one pulse runs once, with both: no glitches.
- **Whole windows.** A source is called with each input's whole current window (§2.2), not with what changed.
- **Every input present.** A source with an input that has no delivery yet (a source loading, a derived source not yet computed) does not run; it stays `:loading`.
- **In context.** Before a source first runs, and again when an input's schema version changes, it is validated given its inputs' schemas and the registry (§1.1). A source that fails is the fault `:restricted`, its detail the faults.
- A function of two arguments is given its context (§2.3), which the engine builds from what it was shown.

The engine is unchanged when no pulse is due. A test sets `debounce: 0`, so a pulse is in the same `run/2` as the change, and nothing waits on a clock.

```planned-test:derived-engine-pulses
a changed input marks its readers and a pulse is due after the debounce; a pulse runs marked sources in rank order, each once, a downstream source only when its input's answer changed; a source whose input has no delivery stays loading; nothing runs when no pulse is due
```

### 8.3 Faults {#derived-engine-faults}

<!-- surfex: deferred #117: the engine -->

A source's call is one bounded call (§6.4), with the engine's bounds. **When it fails, the source keeps its last good output, and the pulse does not propagate past it**: the sources that read it are not marked by it (visualize#643, settled question 4). Its state is `{:down, {:derived, id, kind}}`, `kind` one of §6.4's six. Its readers draw its last output as `stale`, worded with the kind ([macaw_compose 05](https://gitlab.conet.yarina.org/dco-tek/macaw_compose/-/blob/main/spec/05-components.md#components-states)). The fault's **detail** (the checker's faults, the limit, the exception's module, the index and field of a nonconforming answer) never holds a value of the rows nor of a context. The next pulse that marks the source runs it again; a good answer clears the fault.

```planned-test:derived-engine-fault-kept
a failing source keeps its last good output, is down with its kind, and does not mark its readers; its detail holds no value; the next good answer clears it
```

### 8.4 The options and the functions {#derived-engine-api}

<!-- surfex: deferred #117: the engine -->

| Option of `new/2` | Default | Meaning |
|---|---|---|
| `sources:` | `[]` | the names of the sources the derived sources may read |
| `functions:` | `%{}` | the host functions' registry (§7), default closed |
| `debounce:` | `250` | milliseconds a pulse waits for more changes |
| `max_reductions:`, `timeout:`, `max_heap:` | §6.4's | each call's bounds, tighten-only |

| Function | Contract |
|---|---|
| `Engine.new/1`, `new/2` | `new(sources, opts)`: the engine over derived sources by path, defined (§8.1): `{:ok, engine}` or `{:error, [{path, at, reason}]}` |
| `Engine.push/4` | `push(engine, deliveries, schemas, now)`: the readers of a changed source marked, and the next pulse due (§8.2) |
| `Engine.run/2` | `run(engine, now)`: the due pulse run (§8.2); the engine unchanged when none is due |
| `Engine.due/1` | the millisecond the next pulse is due, or `nil` |
| `Engine.source/2`, `source/3` | `source(engine, path, opts)`: the derived source at `path` as a `Macaw.Data.Source` (§8.5) |
| `Engine.resolve/3` | `resolve(engine, scope, name)`: `{:derived, path}`, `{:source, name}` or `:error`, what a name read from a scope names |
| `Engine.sources_read/1` | the sources some derived source reads, sorted |
| `Engine.outputs/1` | every derived source's last good output, a `%Macaw.Data.Delivery{}` naming its output schema's version, by path |
| `Engine.schemas/1` | every derived source's output schema, by path |
| `Engine.status/1` | every derived source's state by path: `:loading`, `:live` or `{:down, {:derived, id, kind}}` |
| `Engine.faults/1` | every failing source's fault by path, `%{kind: kind, detail: detail}` |
| `Engine.runs/1` | how many times each source has run, by path |

```planned-test:derived-engine-run
an engine run end to end answers each source's output as a delivery naming its schema's version, its schema, its state, its fault and its run count by path; resolve names a derived source or a source from a scope; sources_read lists the sources read
```

### 8.5 A derived source as a source {#derived-as-source}

<!-- surfex: deferred #117: the engine -->

A derived source's answer is read as any source's: `Engine.source(engine, path)` is a `%Macaw.Data.Derived.Output{}`, a struct implementing `Macaw.Data.Source` ([01 §2](01-sources.md#sources-contract)) over the engine's last good output at that path:

- **`describe/2`** answers its output schema, `supports: []`, no parameters, and `viewer_independent:` as its owner declares it (`Engine.source(engine, path, viewer_independent: true)`, `false` by default). A derived source answers from its inputs alone, so it is viewer independent when every input is, but the engine sees its inputs' deliveries, not their descriptions, so only the owner can say;
- **`fetch/2`** answers the last good output whole, or `{:error, :loading}` before the first good output. It honors nothing, so the runtime finishes it as any such delivery ([01 §2.4](01-sources.md#sources-finishing));
- it does not push: its owner's engine is what changes it, and the owner tells readers ([01 §5](01-sources.md#sources-change)).

So a derived source is another derived source's input and a slot's source alike, and the conformance kit holds it as it holds any source.

```planned-test:derived-output-kit
a derived source's output passes the source conformance kit, describes its output schema, and fetches its last good output, or loading before the first
```
