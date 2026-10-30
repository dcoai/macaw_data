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


None required at runtime beyond Elixir and OTP, so an adopter using no other Macaw library (visualize, standalone) can depend on it alone. `table` and `nx` are optional: a host that has either gets its `Table.Reader` sources or tensors read into a table ([01 §1.1](01-sources.md#sources-table)), and **a host with neither compiles it without a warning** (CI compiles it so, #7). It depends on `macaw_layers` (v0.1.0), the document kernel: a schema's JSON is read through its gates and its version is its digest ([01 §1.10](01-sources.md#sources-schema-version), [01 §1.11](01-sources.md#sources-schema-json)).

## 4. Order of work {#data-order}

Built in the family's order of work, which puts first what adopters consume:
1. **the interaction event** (step 1): done, v0.1.0;
2. **the data model** (step 3, macaw_compose#57): done, v0.2.0;
3. **the source contract and its kit** (step 4, macaw_compose#58): done, v0.3.0;
4. **derived sources** (step 5, macaw_compose#82): done, v0.4.0; then **transforms, table operations and aggregates** (step 6, macaw_compose#83): done, v0.5.0. v0.6.0 makes a delivery keep the rows its source gave, packing on demand, for live charts (macaw#185).

Each is released by git tag. An adopter published on Hex (visualize) switches when `macaw_data` is published on Hex, keeping a field-identical interim definition checked against this one meanwhile.
