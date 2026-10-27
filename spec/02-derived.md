# 02 — Derived sources {#derived}

<!-- surfex: deferred #82: derived sources, order-of-work step 5 -->

A **derived source** (visualize's *virtual source*) is computed from other sources by a function. Macaw adopts visualize's design whole; it is the most developed part of the three projects (visualize.md C2).

## 1. The model {#derived-model}

<!-- surfex: deferred #82: derived sources, order-of-work step 5 -->

- **A derived source is data:** `%{id, from: [{name, window}], schema, body, per}`. It contains no function value, and has map and JSON forms.
  - `from` names its inputs, each with the window it reads them at;
  - `schema` is its declared output;
  - `body` is either `{:elixir, text}`, stored source text, or `{:defsource, module, name}`, a host function by reference;
  - `per` is `nil` (one call over all inputs) or `:identity`: the function is called **once per entity** of its identity input, grouped by the input's declared identity ([01](01-sources.md#sources-data)), entities in order of first appearance, a row with no identity dropped. The calls for every entity are **one** bounded call. Each entity's answer carries the entity's identity, and the answers are joined into one output, held to the schema.
- **A per-identity source joins onto its input's readers.** A slot bound to the input is handed rows carrying, beside their own fields, each per-identity source's output fields for that row's identity, named `<id>.<field>` (`health.state`), `nil` where the output has no entry yet. The slot's schema gains those fields as the output describes them, so a component's legend and checks see their declared values. (visualize spec/15 §14.4, D-194.)
- **Its function is either:**
  - **stored** Elixir source text: untrusted, checked and sandboxed; or
  - a **host** `defsource` in a registered module: trusted but bounded.

  It is never a mini-language.
- **The checker:** exactly one `fn` of arity 1 (inputs) or 2 (inputs, context), against an explicit allowlist of `{module, function, arity}`, generated from the transforms and aggregates registered by enabled packages, except those that declare `needs` (§5). It refuses:
  - `send`, `receive`, `spawn`, `try`, `raise` and `apply`;
  - `import`, `quote`, sigils, struct literals and module atoms;
  - dynamic calls.

  Field reads are limited to the declared schemas, and the source text to 10,000 bytes. It reports every fault with its line.
- **Bounds,** with the outcome read from the process exit and never rescued:
  - each call runs in a process of its own;
  - reductions: 100,000,000, **counted, not timed**, so the verdict is the same on a loaded host;
  - liveness: 30 s;
  - heap: 10,000,000 words.
- **Faults never carry data values.** The last good output survives a fault, and the source's readers draw `stale` ([macaw_compose 05](https://gitlab.conet.yarina.org/dco-tek/macaw_compose/-/blob/main/spec/05-components.md#components-states)), worded with the fault's reason, until the next good output.
- **The output conforms to its declared schema,** or it is a fault.
- **Context has no clock.** A source reads its inputs' schemas and their deliveries' served facts. Anything else it depends on (a variable, a selection) is an input like any other.

### Gates that ship with the sandbox {#derived-gates}

<!-- surfex: deferred #82: the sandbox and its gates, step 5 -->

The sandbox is the one place in the family that runs untrusted code, so it never loses a check in transit. When it moves from visualize to `macaw_data` (macaw_compose#28), it brings, and its CI runs:
- **the checker's allowlist tests:** every refused construct above, refused by name and line;
- **the reductions budget and the separate liveness bound,** each tested by a function that exceeds it (visualize#856, #857);
- **the atom gate:** no atom is created from untrusted input. A check equal to visualize's `vis.atoms` (D-195) fails the build on any `String.to_atom/1` or `binary_to_atom` reachable from document or source data;
- **the conformance and property tests** of the sandbox: generated inputs never crash the caller, never leak data values in faults, and always yield a schema-conforming output or a fault.

Until `macaw_data` passes all of them, adopters keep their own sandbox.

## 2. Inputs {#derived-inputs}

<!-- surfex: deferred #82: derived sources, order-of-work step 5 -->

Inputs are **sources, by name**: anything that satisfies the source contract ([01](01-sources.md#sources-contract)). That covers feeds and other derived sources, and, on a Macaw page, state sources and exports, which `macaw_compose` makes satisfy the contract ([macaw_compose 03](https://gitlab.conet.yarina.org/dco-tek/macaw_compose/-/blob/main/spec/03-state.md#state-sources)). `macaw_data` knows nothing of pages; it sees named sources.

The function may take all of a scope's inputs together. metresis's series naming is computed once over every metric's feed. (metresis.md C2.)

## 3. Scoping {#derived-scoping}

<!-- surfex: deferred #82: derived sources, order-of-work step 5 -->

A derived source is defined at a scope: the page, a surface, a container or a cell. Names resolve from the inside out, so an inner definition shadows an outer one. Cycles are refused with the cycle named ([macaw_compose 03](https://gitlab.conet.yarina.org/dco-tek/macaw_compose/-/blob/main/spec/03-state.md#state-dag)).

## 4. What stays in the source {#derived-database}

<!-- surfex: deferred #82: derived sources, order-of-work step 5 -->

Derivations that need raw rows or the store stay **inside the source**, never in a derived source:
- counter-reset-aware deltas;
- circular means;
- percentiles from raw rows ("a p95 of p95s is not a p95");
- rollup vs raw selection.

(metresis.md C2.)

## 5. Transforms and aggregates {#derived-operations}

<!-- surfex: deferred #83: transforms and aggregates, step 6 -->

The operations a visualize design applies to its data and the operations a derived source may call are **the same code**, in `macaw_data` beside derived sources (macaw_compose#22, decision 11):
- **the transform behavior,** with the table operations: filter, sort, take, fold, sum, bin, stack, window, lttb, m4 and spectrum;
- **the aggregate behavior,** with its statistics.

A computation can therefore move between a design and a derived source unchanged, and a metresis feed and a visualize chart reduce data the same way.

- **Transforms that need geometry** (they declare `needs: [:frame]` or `needs: [:projection]`: layouts, geographic operations) stay in the package that draws, and register through the registry like any other member ([macaw_compose 12](https://gitlab.conet.yarina.org/dco-tek/macaw_compose/-/blob/main/spec/12-registry.md)). A derived source has no frame, so they are never on its allowlist.
- **The sandbox allowlist is generated** from the registered members of enabled packages, never written by hand, so enabling a package is the only way to widen it.
