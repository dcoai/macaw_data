# 00 — Overview {#data-overview}

## 1. What macaw_data holds {#data-holds}

`macaw_data` is the smallest Macaw package, and the one every other depends on for data ([macaw_compose 00 §4](https://gitlab.conet.yarina.org/dco-tek/macaw_compose/-/blob/main/spec/00-overview.md#overview-packaging)):
- **the interaction event** and its recorded form ([01 §8](01-sources.md#sources-event));
- **the data model:** Table, Schema, Delivery, units, quantities and facts ([01 §1](01-sources.md#sources-data), [03](03-units.md));
- **the source contract,** push, change notification and the source conformance kit ([01 §2–§7](01-sources.md#sources-contract));
- **derived sources,** with the transform and aggregate behaviors and the table operations ([02](02-derived.md)).

It knows nothing of pages, components or state: those are `macaw_compose`'s, which depends on it. A derived source takes its inputs as named sources ([02 §2](02-derived.md#derived-inputs)); that state sources and exports satisfy the source contract is `macaw_compose`'s concern.

## 2. Dependencies {#data-dependencies}

None required at runtime beyond Elixir and OTP, so an adopter using no other Macaw library (visualize, standalone) can depend on it alone. `table` and `nx` are optional: a host that has either gets its `Table.Reader` sources or tensors read into a table ([01 §1.1](01-sources.md#sources-table)). It depends on `macaw_layers` (v0.1.0), the document kernel: a schema's JSON is read through its gates and its version is its digest ([01 §1.10](01-sources.md#sources-schema-version), [01 §1.11](01-sources.md#sources-schema-json)).

## 3. Order of work {#data-order}

Built in the family's order of work, which puts first what adopters consume:
1. **the interaction event** (step 1): done, v0.1.0;
2. **the data model** (step 3, macaw_compose#57): done, v0.2.0;
3. **the source contract and its kit** (step 4, macaw_compose#58);
4. **derived sources** (step 5), then **transforms, table operations and aggregates** (step 6).

Each is released by git tag. An adopter published on Hex (visualize) switches when `macaw_data` is published on Hex, keeping a field-identical interim definition checked against this one meanwhile.
