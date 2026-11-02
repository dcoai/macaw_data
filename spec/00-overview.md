# 00 — Overview {#data-overview}

## 1. What macaw_data holds {#data-holds}

`macaw_data` is the smallest Macaw package, and the one every other depends on for data ([macaw_compose 00 §4](https://github.com/dcoai/macaw/blob/main/spec/00-overview.md#overview-packaging)):
- **the interaction event** and its recorded form ([01 §8](01-sources.md#sources-event));
- **the data model:** Table, Schema, Delivery, units, quantities and facts ([01 §1](01-sources.md#sources-data), [03](03-units.md));
- **the source contract,** push, change notification and the source conformance kit ([01 §2–§7](01-sources.md#sources-contract), [§9](01-sources.md#sources-conformance));
- **derived sources** ([02](02-derived.md)), and **the operations** they and designs share: the transform and aggregate behaviors, the registry of enabled packages, the table operations and the statistics ([04](04-operations.md)).

It knows nothing of pages, components or state: those are `macaw_compose`'s, which depends on it. A derived source takes its inputs as named sources ([02 §2](02-derived.md#derived-inputs)); that state sources and exports satisfy the source contract is `macaw_compose`'s concern.

## 2. Terms are the form {#data-terms}

**A value is a BEAM term, and its encodings are adapters** (dco-tek/macaw/macaw#188, from v0.7.0), as in macaw_layers ([macaw_layers 00 §2](https://github.com/dcoai/macaw_layers/blob/main/spec/00-overview.md#layers-terms)):
- **Identity is the term's.** A schema's version is the kernel's digest of its term ([01 §1.10](01-sources.md#sources-schema-version)); the operations registry and a checked step are identified the same way ([04 §2](04-operations.md#operations-registry)).
- **Validity is the term's.** A data color is a color term, never text ([01 §1.7](01-sources.md#sources-schema-colors)); a derived source is judged as the value it is ([02 §1.1](02-derived.md#derived-value)).
- **Each value has one form.** Names, states and roles are strings; a category value is held as its string. No value is kept in two spellings.
- **JSON and Arrow are adapters at the edge.** The schema's and a derived source's JSON forms are written and read at the edge ([01 §1.11](01-sources.md#sources-schema-json), [02 §1.5](02-derived.md#derived-forms)); packed columns are laid out as Arrow lays them out, and packing never changes a value ([01 §1.1](01-sources.md#sources-table)).

## 3. Dependencies {#data-dependencies}


It requires one library at runtime, **`macaw_layers`**, the document kernel: a schema's JSON is read through its gates and its version is its digest ([01 §1.10](01-sources.md#sources-schema-version), [01 §1.11](01-sources.md#sources-schema-json)). Nothing else is required, so an adopter that uses no other Macaw library (visualize, standalone) depends on `macaw_data` and `macaw_layers` alone. The rest is optional:
- **`table` and `nx`:** a host that has either gets its `Table.Reader` sources or tensors read into a table ([01 §1.1](01-sources.md#sources-table)), and **a host with neither compiles it without a warning** (CI compiles it so, #7).
- **`zigler`, a build tool only:** with it and the Zig it targets, the native kernels are built; without it, every step runs its Elixir path ([04 §1.7](04-operations.md#operations-native)).

**Of the kernel's untrusted strings** ([macaw_layers 01 §8](https://github.com/dcoai/macaw_layers/blob/main/spec/01-kernel.md#kernel-untrusted)), macaw_data's documents hold none that needs a host's say. **They hold no URL:** a derived source's reader holds what it reads to the kernel's closed policy ([02 §1.5](02-derived.md#derived-forms)), and a schema's reader reads no `$url` ([01 §1.11](01-sources.md#sources-schema-json)), so no read takes a `urls:` policy. **It builds no theme and writes no CSS:** a data color is a color term judged by the kernel's `Color` ([01 §1.7](01-sources.md#sources-schema-colors)), so the untrusted-text checks are its adopters', where they write a schema's labels and colors into a page.

**No version is written here.** The requirements are `mix.exs`'s, and only there, so this section cannot fall behind them (#34).

## 4. Order of work {#data-order}

Built in the family's order of work, which puts first what adopters consume:
1. **the interaction event** (step 1): done, v0.1.0;
2. **the data model** (step 3, macaw_compose#57): done, v0.2.0;
3. **the source contract and its kit** (step 4, macaw_compose#58): done, v0.3.0;
4. **derived sources** (step 5, macaw_compose#82): done, v0.4.0; then **transforms, table operations and aggregates** (step 6, macaw_compose#83): done, v0.5.0. v0.6.0 makes a delivery keep the rows its source gave, packing on demand, for live charts (macaw#185).
5. **the source contract as a time-varying relation, and chunked tables** (macaw_data#10, #9): done, v0.8.0. A push is a numbered changelog with corrections and settled ranges ([01 §2.5](01-sources.md#sources-model), [§4](01-sources.md#sources-push)); a table is a list of immutable chunks that every step works a chunk at a time, with optional native kernels ([01 §1.1](01-sources.md#sources-table), [04 §1.4](04-operations.md#operations-steps), [§1.7](04-operations.md#operations-native)). v0.7.0 made terms the form (§2). v0.8.1 starts an application without the kernels with nothing logged at error level (macaw_data#76). v0.9.0 moves to macaw_layers 0.4.0 and gives a request a row order ([01 §2.3](01-sources.md#sources-request), macaw_data#80).

Each is released by git tag. An adopter published on Hex (visualize) switches when `macaw_data` is published on Hex, keeping a field-identical interim definition checked against this one meanwhile.

## 5. Errors are values {#data-errors}

**A public function answers bad input with `{:error, reason}`; it does not raise** (macaw_data#114). A raise is caught by no one, because this library and its adopters rescue nothing, while a value is read by the caller that can act on it.
- **Success** is `{:ok, value}`, or a bare value only where nothing the caller passes can fail.
- **A `name!` twin** may raise. It calls `name` and raises its `{:error, reason}` as an `ArgumentError` in that module's `format_error/1` words. The twin is for a caller that knows its input is valid, as the library's own callers often do.
- **A macro's misuse** fails the build with a `CompileError`: there is no caller to answer.
- **A broken internal invariant** may raise. That is a bug in this library, not bad input, and each one is named in the guard's allowlist with its reason.

**Reasons are data, in one vocabulary,** the shapes the library already answers:
- a fault at a place, `{path, reason}`: a list of the keys, indexes and names that lead to the bad part, and why (`Table.from/1`, `Schema.new/1`, `Operations.apply/4`, a derived source's form, [01 §1.1](01-sources.md#sources-table), [04 §3.1](04-operations.md#operations-run));
- a reason about a value read, `{:unknown_column, name}`, `{:wrong_type, name, expected, actual}` and `{:type, what}` ([02 §2.2](02-derived.md#derived-input-windows));
- a module's own named reasons, such as a unit's `{:dimension, from, to}` ([03](03-units.md)).

Each module's `format_error/1` gives a reason's words, and each converted function's spec section names its reasons.

**The guard**, `ci/raises.exs`, holds the library to this. It reads every `.ex` file under `lib/` as code, so a raise in a doc or a comment is no site, and finds each `raise`, `reraise` and `throw` with the function it sits in, `Module.name/arity`. A public `name!` whose module also defines `name` of the same arity is a twin and passes. Every other site must be named in `ci/raises_allowlist.exs` with how many sites its function holds, a class and a reason, and an entry whose count is not what its function holds fails too. The classes are:
- `:bang`: a private helper the twins share;
- `:compile`: compile-time code;
- `:invariant`: a named invariant.

Bad input has no class: the milestone's `:convert` class, which listed each site still to convert, is retired and refused (macaw_data#121).

```test:data-errors-guard
the raise guard passes this library; it fails on a raise outside a bang twin and the allowlist, at its line, and on an allowlist entry whose count is stale, whose class is unknown (the retired :convert among them), or that names no site; a raise in a doc or a comment is no site
```

**What once raised implicitly answers too** (macaw_data#121). A function's option it does not take is `{[key], :unknown_key}` and a missing required one `{[key], :required}`, where `Keyword.validate!/2` and `Keyword.fetch!/2` would raise; a quantity not in `Macaw.Data.Quantity.all/0` is `{:unknown_quantity, quantity}`, a system none of `systems/0` `{:unknown_system, system}` and a metric kind none of `:gauge`, `:counter` and `:rate` `{:unknown_metric_kind, kind}`, where a map read would raise. What stays an implicit raise reads only what the library itself built: an engine's map by a path it defined, a chunk's column by its header's name, a word table by a word the checker produced. **`Macaw.Data.Table.rows/1` reads a source `Table.source/1` accepts**: every entry that takes a caller's rows (`Table.from/2`, `Delivery.new/2`, `Operations.apply/4`) checks it first, and an aggregate's `reduce/2` and `step/3` take readings as its `reads/0` declares, checked by `Operations.aggregate/4` and the steps. Those three are named invariants in the guard's allowlist.

```test:data-errors-implicit
an option Delivery.table/2, Derived.validate/2, Engine.new/2, Engine.source/3, Push.new/3 and Finish.ceiling/2 do not take is {[key], :unknown_key}, a missing required one {[key], :required}, an unknown engine path {[:path], :unknown_path}; a quantity, unit, system or metric kind outside Quantity's vocabulary is its fault; none raises, and the ! twins raise them
```
