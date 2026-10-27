# macaw_data

Macaw's data layer (spec/00 §4): the interaction event now; the data model, the source contract and derived sources as the order of work reaches them (spec/00 §5, dco-tek/macaw_compose#55–#58).

| Module | What it is |
|---|---|
| `Macaw.Data.Event` | the one interaction shape every component emits, and its recorded form, which never holds row data (spec/02 §8) |
| `Macaw.Data.Unit` | units named by their UCUM codes, with aliases, the ISO 4217 currency extension, display symbols and exact conversion ([spec/03 §1–§7](spec/03-units.md#units-codes)) |
| `Macaw.Data.Quantity` | the fixed list of quantities and their facts: kind, bounds, additivity, families, conventions and unit systems; the measure; the label rule ([spec/03 §8–§14](spec/03-units.md#quantities)) |

No dependencies. Released by git tag:

```elixir
{:macaw_data, git: "git@gitlab.conet.yarina.org:dco-tek/macaw_data.git", tag: "v0.1.0"}
```

Part of [Macaw](https://gitlab.conet.yarina.org/dco-tek/macaw_compose).
