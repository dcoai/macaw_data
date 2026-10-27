# macaw_data

Macaw's data layer (spec/00 §4): the interaction event, the data model and the source contract with its conformance kit; derived sources as the order of work reaches them (spec/00 §5, dco-tek/macaw_compose#55–#58).

| Module | What it is |
|---|---|
| `Macaw.Data.Event` | the one interaction shape every component emits, and its recorded form, which never holds row data ([spec/01 §8](spec/01-sources.md#sources-event)) |
| `Macaw.Data.Schema`, `Macaw.Data.Schema.Cache` | what each field of a source means: types (`:point` among them), measures, states, identity, the window field, data colors; its version, its public JSON form, and the cache by version ([spec/01 §1.2–§1.12](spec/01-sources.md#sources-schema)) |
| `Macaw.Data.Delivery` | one answer of a source: its table, the schema version, what it served (window or box, resolution, capped, `reduced_by: :source | :runtime`, params, note) and its origin ([spec/01 §3](spec/01-sources.md#sources-delivery)) |
| `Macaw.Data.Source`, `Macaw.Data.Source.Description`, `Macaw.Data.Source.Request`, `Macaw.Data.Parameter` | the source contract: describe with the host's context, fetch a request (parameters, window, box, region, latest, budget, `as_of`, viewer, `now`), optional push; parameters checked before a source is called ([spec/01 §2](spec/01-sources.md#sources-contract)) |
| `Macaw.Data.Source.Finish`, `Macaw.Data.Window`, `Macaw.Data.Reduce` | finishing what a source did not honor: window, box, region, latest and budget (LTTB, M4), only ever removing rows; the host ceiling and pooled budgets ([spec/01 §2.4, §6.1](spec/01-sources.md#sources-finishing)) |
| `Macaw.Data.Source.Push` | one push subscription as a value: the schema first, increments merged by the window field, pushes coalesced per pulse ([spec/01 §4](spec/01-sources.md#sources-push)) |
| `Macaw.Data.Source.Conformance`, `Macaw.Data.Bounded` | the conformance kit every source runs: eight checks as findings or as ExUnit tests, each callback isolated and judged by reductions ([spec/01 §9](spec/01-sources.md#sources-conformance)) |
| `Macaw.Data.Table` | columnar typed data: packed number and time columns off the heap, gaps kept; every source shape read at the edge ([spec/01 §1.1](spec/01-sources.md#sources-table)) |
| `Macaw.Data.Unit` | units named by their UCUM codes, with aliases, the ISO 4217 currency extension, display symbols and exact conversion ([spec/03 §1–§7](spec/03-units.md#units-codes)) |
| `Macaw.Data.Quantity` | the fixed list of quantities and their facts: kind, bounds, additivity, families, conventions and unit systems; the measure; the label rule ([spec/03 §8–§14](spec/03-units.md#quantities)) |

Depends on `macaw_layers` (the document kernel); `table` and `nx` are optional, for reading their sources into a table. Released by git tag:

```elixir
{:macaw_data, git: "git@gitlab.conet.yarina.org:dco-tek/macaw_data.git", tag: "v0.3.0"}
```

Part of [Macaw](https://gitlab.conet.yarina.org/dco-tek/macaw_compose).
