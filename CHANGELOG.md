# Changelog

## v0.6.0 (2026-10-29)

- What a source steps its window by: `Window.before/4`, `region/2` (visualize's `box/2`: a window as the region it asks of a schema), `range/2`, and `check/2` of the axes alone as well as of a request (dco-tek/macaw/macaw#185, #5).
- Packing a table and reading it back do about half the work: types inferred only where not given, values checked in one pass, column names merged once, rows built a column step at a time, and time columns converted by the date's fields, a fifth of `DateTime`'s own conversion (dco-tek/macaw/macaw#185, #4).
- **Breaking:** a delivery keeps the rows its source gave (dco-tek/macaw/macaw#185). `%Delivery{rows, names, types, served, schema, origin}`: nothing is packed or rewritten when it is made; `Delivery.rows/1` and `Table.rows/1` of a delivery read the rows as they are (a row list uncopied, tuple rows unchanged); `Delivery.table/2` and `table!/2` pack them for a reader that wants columns; `named_rows/1` names tuple rows and tensors by `names:`; `empty?/1`. The `table` field is gone: read `Delivery.table!/1`. Finishing and push keep the rows' form. `Table.unnamed?/1` (#3).

## v0.5.4 (2026-10-28)

- The macaw logo in the docs and the README (macaw#175).
- Tests check "makes no atom" on the input's own names, never the node's atom count, and the atom gate forbids the count in `test/` (#1).

## v0.5.3 (2026-10-28)

- On Hex: depends on `macaw_layers ~> 0.2.2` from Hex instead of its git tag, and the README installs from Hex (macaw#155).
- The README opens with the early-release notice (macaw#174).

## v0.5.2 (2026-10-28)

- Dependencies named by their `dco-tek/macaw` group paths (macaw#152).
- Package metadata for Hex: the public home, the changelog link, the files shipped, and docs with `ex_doc` (macaw_compose#155).

## v0.5.1 (2026-10-28)

- macaw_data v0.5.1: on macaw_layers v0.2.0 (macaw_compose#145)

## v0.5.0 (2026-10-27)

- macaw_data v0.5.0: transforms, table operations and aggregates (macaw_compose#83): the behaviors, the registry, twelve table operations, thirteen statistics, Macaw.Data.Ops in the sandbox, budget reducers by name

## v0.4.0 (2026-10-27)

- macaw_data v0.4.0: derived sources (macaw_compose#82): the model, the sandbox and its gates, host functions and the engine

## v0.3.0 (2026-10-27)

- macaw_data v0.3.0: the source contract (macaw_compose#58): the behavior, description, request and parameters; windows and finishing; push; the conformance kit

## v0.2.0 (2026-10-27)

- macaw_data v0.2.0: the data model (macaw_compose#57): units and quantities, the columnar table, the schema, the delivery

## v0.1.0 (2026-10-27)

- macaw_data 0.1.0: Macaw.Data.Event
