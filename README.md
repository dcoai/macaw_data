# macaw_data

Macaw's data layer (spec/00 §4): the interaction event now; the data model, the source contract and derived sources as the order of work reaches them (spec/00 §5, dco-tek/macaw_compose#55–#58).

| Module | What it is |
|---|---|
| `Macaw.Data.Event` | the one interaction shape every component emits, and its recorded form, which never holds row data (spec/02 §8) |
| `Macaw.Data.Schema`, `Macaw.Data.Schema.Cache` | what each field of a source means: types (`:point` among them), measures, states, identity, the window field, data colors; its version, its public JSON form, and the cache by version ([spec/01 §1.2–§1.12](spec/01-sources.md#sources-schema)) |
| `Macaw.Data.Delivery` | one answer of a source: its table, the schema version, what it served (window or box, resolution, capped, `reduced_by: :source | :runtime`, params, note) and its origin ([spec/01 §3](spec/01-sources.md#sources-delivery)) |
| `Macaw.Data.Table` | columnar typed data: packed number and time columns off the heap, gaps kept; every source shape read at the edge ([spec/01 §1.1](spec/01-sources.md#sources-table)) |
| `Macaw.Data.Unit` | units named by their UCUM codes, with aliases, the ISO 4217 currency extension, display symbols and exact conversion ([spec/03 §1–§7](spec/03-units.md#units-codes)) |
| `Macaw.Data.Quantity` | the fixed list of quantities and their facts: kind, bounds, additivity, families, conventions and unit systems; the measure; the label rule ([spec/03 §8–§14](spec/03-units.md#quantities)) |

Depends on `macaw_layers` (the document kernel); `table` and `nx` are optional, for reading their sources into a table. Released by git tag:

```elixir
{:macaw_data, git: "git@gitlab.conet.yarina.org:dco-tek/macaw_data.git", tag: "v0.2.0"}
```

Part of [Macaw](https://gitlab.conet.yarina.org/dco-tek/macaw_compose).
