# macaw_data specification

`macaw_data` is Macaw's data layer: the interaction event every component emits, the data model, the source contract, and derived sources. Each Macaw component has its own spec in its own repository (dco-tek/macaw_compose#61); this is `macaw_data`'s. The family's overview, vocabulary and open questions, and the specs of components without a repository of their own yet, are in [macaw_compose's spec](https://gitlab.conet.yarina.org/dco-tek/macaw_compose/-/blob/main/spec/README.md).

| File | Covers | Status |
|---|---|---|
| [00 — Overview](00-overview.md) | what `macaw_data` holds, what it depends on, the order it is built in | |
| [01 — Sources](01-sources.md) | the data model, the source contract, deliveries, push, change notification, running sources, credentials, **the interaction event** (§8) | §8 implemented (v0.1.0); §1–§7 are order-of-work steps 3–4 |
| [02 — Derived sources](02-derived.md) | checked, bounded, deterministic functions over sources; transforms and aggregates | order-of-work steps 5–6 |

Sections keep the anchors they had in the family spec (`sources-*`, `derived-*`), so links into them stay stable.
