<img src="brand/logo/macaw_scarlet.svg" alt="The Macaw logo, a scarlet macaw in flight" width="128">

# macaw_data

> **This software is a very early release, and not ready for general use.**

Public home: [github.com/dcoai/macaw_data](https://github.com/dcoai/macaw_data) · Docs: [hexdocs.pm](https://hexdocs.pm/macaw_data)

Macaw's data layer (spec/00 §4): the interaction event, the data model, the source contract with its conformance kit, derived sources, and the operations designs and derived sources share: transforms, table operations and aggregates (spec/00 §5, dco-tek/macaw_compose#83; #55–#58, #82).

| Module | What it is |
|---|---|
| `Macaw.Data.Event` | the one interaction shape every component emits, and its recorded form, which never holds row data ([spec/01 §8](https://github.com/dcoai/macaw_data/blob/main/spec/01-sources.md#sources-event)) |
| `Macaw.Data.Schema`, `Macaw.Data.Schema.Cache` | what each field of a source means: types (`:point` among them), measures, states, identity, the window field, data colors; its version, its public JSON form, and the cache by version ([spec/01 §1.2–§1.12](https://github.com/dcoai/macaw_data/blob/main/spec/01-sources.md#sources-schema)) |
| `Macaw.Data.Delivery` | one answer of a source: its rows as the source gave them (a table packed on demand), the schema version, what it served (window or box, resolution, capped, `reduced_by: :source | :runtime`, params, note) and its origin ([spec/01 §3](https://github.com/dcoai/macaw_data/blob/main/spec/01-sources.md#sources-delivery)) |
| `Macaw.Data.Source`, `Macaw.Data.Source.Description`, `Macaw.Data.Source.Request`, `Macaw.Data.Parameter` | the source contract: describe with the host's context, fetch a request (parameters, window, box, region, latest, budget, `as_of`, viewer, `now`), optional push; parameters checked before a source is called ([spec/01 §2](https://github.com/dcoai/macaw_data/blob/main/spec/01-sources.md#sources-contract)) |
| `Macaw.Data.Source.Finish`, `Macaw.Data.Window`, `Macaw.Data.Reduce` | finishing what a source did not honor: window, box, region, latest and budget (by any registered reducer, LTTB by default), only ever removing rows; the host ceiling and pooled budgets ([spec/01 §2.4, §6.1](https://github.com/dcoai/macaw_data/blob/main/spec/01-sources.md#sources-finishing)) |
| `Macaw.Data.Source.Push` | one push subscription as a value: the schema first, increments merged by the window field, pushes coalesced per pulse ([spec/01 §4](https://github.com/dcoai/macaw_data/blob/main/spec/01-sources.md#sources-push)) |
| `Macaw.Data.Source.Conformance`, `Macaw.Data.Bounded` | the conformance kit every source runs: eight checks as findings or as ExUnit tests, each callback isolated and judged by reductions ([spec/01 §9](https://github.com/dcoai/macaw_data/blob/main/spec/01-sources.md#sources-conformance)) |
| `Macaw.Data.Derived`, `Macaw.Data.Derived.Context`, `Macaw.Data.Derived.Join` | derived sources: computed from other sources by a stored or host function, as data, with their forms, conformance, per-identity batches, joined fields and scoping ([spec/02 §1–§3](https://github.com/dcoai/macaw_data/blob/main/spec/02-derived.md#derived-model)) |
| `Macaw.Data.Derived.Sandbox` | the checker, allowlist, compile-once cache and bounded runner every derived source's function runs in, with its gates, the atom gate among them ([spec/02 §6](https://github.com/dcoai/macaw_data/blob/main/spec/02-derived.md#derived-sandbox)) |
| `Macaw.Data.Derived.Functions`, `Macaw.Data.Derived.Engine`, `Macaw.Data.Derived.Output` | host functions (`defsource`, an explicit registry), the engine that pulses derived sources, and a derived source read as a source ([spec/02 §7–§8](https://github.com/dcoai/macaw_data/blob/main/spec/02-derived.md#derived-functions)) |
| `Macaw.Data.Transform`, `Macaw.Data.Aggregate`, `Macaw.Data.Operations` | the transform and aggregate behaviors, `macaw_data`'s own package, the explicit default-closed registry of enabled packages, and running nodes and aggregates with every fault at once ([spec/04 §1–§3](https://github.com/dcoai/macaw_data/blob/main/spec/04-operations.md#operations-behaviors)) |
| `Macaw.Data.Operations.Transforms.*`, `Macaw.Data.Stack`, `Macaw.Data.FFT` | the twelve table operations: filter, take, window, lttb, m4, sort, fold, stack, bin, aggregate, sum and spectrum, with the stack and FFT engines ([spec/04 §4](https://github.com/dcoai/macaw_data/blob/main/spec/04-operations.md#operations-table)) |
| `Macaw.Data.Operations.Aggregates.*` | the thirteen statistics, streaming where they can ([spec/04 §5](https://github.com/dcoai/macaw_data/blob/main/spec/04-operations.md#operations-statistics)) |
| `Macaw.Data.Ops` | what a stored function calls to reach the registered operations by literal name, checked and compiled against the engine's registry ([spec/04 §6](https://github.com/dcoai/macaw_data/blob/main/spec/04-operations.md#operations-sandbox)) |
| `Macaw.Data.Table` | columnar typed data in immutable chunks with stable ids, packed as Arrow lays them out, gaps kept; every source shape read at the edge ([spec/01 §1.1](https://github.com/dcoai/macaw_data/blob/main/spec/01-sources.md#sources-table)) |
| `Macaw.Data.Unit` | units named by their UCUM codes, with aliases, the ISO 4217 currency extension, display symbols and exact conversion ([spec/03 §1–§7](https://github.com/dcoai/macaw_data/blob/main/spec/03-units.md#units-codes)) |
| `Macaw.Data.Quantity` | the fixed list of quantities and their facts: kind, bounds, additivity, families, conventions and unit systems; the measure; the label rule ([spec/03 §8–§14](https://github.com/dcoai/macaw_data/blob/main/spec/03-units.md#quantities)) |

Depends on `macaw_layers` (the document kernel); `table` and `nx` are optional, for reading their sources into a table, and `zigler` is optional, a build tool for the native kernels (`{:zigler, "~> 0.16.0", runtime: false}` with Zig 0.16.0; without it every step runs its Elixir path). From Hex:

```elixir
{:macaw_data, "~> 0.8.0"}
```

Part of [Macaw](https://github.com/dcoai/macaw).
