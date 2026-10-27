# macaw_data

Macaw's data layer (spec/00 §4): the interaction event now; the data model, the source contract and derived sources as the order of work reaches them (spec/00 §5, dco-tek/macaw_compose#55–#58).

| Module | What it is |
|---|---|
| `Macaw.Data.Event` | the one interaction shape every component emits, and its recorded form, which never holds row data (spec/02 §8) |

No dependencies. Released by git tag:

```elixir
{:macaw_data, git: "git@gitlab.conet.yarina.org:dco-tek/macaw_data.git", tag: "v0.1.0"}
```

Part of [Macaw](https://gitlab.conet.yarina.org/dco-tek/macaw_compose).
