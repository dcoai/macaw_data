# 01 — Sources {#sources}

<!-- surfex: deferred #58: the source contract this file introduces is order-of-work step 4 -->

A **source** is anything a component's slot reads. One contract serves feeds, queries, derived sources, state sources and exports. It is a strict superset of visualize's `Visualize.Feed`: an existing feed is a source with no parameters.

## 1. The data model {#sources-data}

<!-- surfex: deferred #57: the data model, order-of-work step 3 -->

- **`Data.Table`:** columnar typed data, the currency of deliveries, derived sources and components. Row lists are accepted at the edge. (visualize.md C1.)
- **`Data.Schema`:** each field's **meaning**: `type` (`:time | :number | :category | :text | :color | :point`, a `:point` being a geographic position), and where known `unit` (UCUM), `quantity`, `label`, `order`, `status`, `polarity`, `continuity`, `bounds`, `identity`, `window`, and declared `values` with names and colors. (visualize.md C1.)
- **The window field** is the field a request's window applies to: the one marked `window: true`, else the schema's first `:time` field. A `box` window applies to a `:point` window field. A schema with neither has no window field, and requests to it carry none.
- **A schema gives data colors, never drawing colors.** A `:color` field, or a color on a declared value (a team's color), is content; how it may be shown is a theme rule ([macaw_compose 11](https://gitlab.conet.yarina.org/dco-tek/macaw_compose/-/blob/main/spec/11-themes.md#themes-rules)).
- **A schema's version is the SHA-256 of a canonical encoding.** A delivery names the version, and a push sends the schema before rows made under it. (visualize.md C1; metresis.md C1.)
- **Identity is declared** (`identity: true`, composite allowed), never guessed. Selection, `latest` and per-identity derivations read it. (visualize.md C1.)
- **Units and quantities** come from one vocabulary (visualize's), so nothing translates between two. (metresis.md C1.)

## 2. The contract {#sources-contract}

<!-- surfex: deferred #58: the source contract, order-of-work step 4 -->

```elixir
@callback describe(source, context) ::
  {:ok, %Description{
     schema:   Data.Schema.t(),
     params:   %{String.t() => parameter},   # parameters, as macaw_compose spec 05 §1.1 defines them
     supports: [:window | :box | :latest | :budget | :push | :as_of],
     reveals:  Disclosure.t(),
     viewer_independent: boolean()          # default false; see §6
   }} | {:error, reason}

@callback fetch(source, %Request{
     params:  %{String.t() => term},   # validated against the description's params before the call
     window:  nil | window | box,      # meaningful only when the schema has a window field
     budget:  nil | pos_integer,       # rows
     as_of:   nil | DateTime.t(),      # only if supports :as_of
     viewer:  Viewer.t(),              # never stored
     now:     DateTime.t()             # given by the surface; a source never reads a clock
   }) ::
  {:ok, %Delivery{table, schema, served, origin}} | {:error, reason}

@optional_callbacks subscribe: 2, unsubscribe: 2
```

- **`describe/2`** takes the host's configuration for the source as its `context`, **never a viewer**: what a source is doesn't depend on who asks. So it is answered at boot and cached until the source's schema version changes, and validation reads it without I/O ([macaw_compose 07](https://gitlab.conet.yarina.org/dco-tek/macaw_compose/-/blob/main/spec/07-documents.md#documents-validation-time)).
- **`params`** are **parameters** ([macaw_compose 05](https://gitlab.conet.yarina.org/dco-tek/macaw_compose/-/blob/main/spec/05-components.md#components-parameters)), the one shape for every typed option, with the same type vocabulary as `Data.Schema` and **legal values**. For example, metresis's aggregation is a category whose values are `legal(metric)`, so no consumer can ask for an aggregation the type forbids. (metresis.md C1.)
- **`supports`:** every capability is optional. Macaw finishes a window, box, latest or budget that the source did not honor, and reports it. (visualize.md C1, D-140.)
- **Window-less sources are allowed** (thresholds, projects, fragments). (metresis.md C1; dcotek_web.md C1.)
- **The budget never widens the window.** A source may refuse to split a bucket's keys, delivering nothing rather than a partial distribution. (metresis.md C1.)
- **`reveals`** declares what a result tells about the data or the viewer. Hosts generate disclosure from it, and from nothing else. (dcotek_web.md C12.)
- **`viewer_independent`** declares that the source answers every viewer the same. It only allows pooling across viewers (§6), which fetches with the anonymous viewer, so a wrong declaration shows everyone the anonymous answer and never one person's rows to another.
- **The viewer is an argument, not a setting.** A source may refuse, filter or tease by it. Macaw never writes a viewer to a document, delivery or record. (dcotek_web.md C11; visualize.md C11.)
- **Preferences are state, not part of the viewer.** A viewer's display preferences (`theme`, `zone`, `units`) are state sources ([macaw_compose 03](https://gitlab.conet.yarina.org/dco-tek/macaw_compose/-/blob/main/spec/03-state.md#state-sources)), persisted like any other state and passed to components in their context. The viewer argument carries identity and access only.
- **Errors are values.** A source never raises. (visualize.md C1; metresis.md C1.)

## 3. Deliveries {#sources-delivery}

<!-- surfex: deferred #57: deliveries are the data model, step 3 -->

A delivery reports what it actually served:
- `served`: the window, resolution, `capped`, `reduced_by`, the params, and a note (for example, "coarsened from raw");
- `reduced_by` says who brought the rows within budget: `:source` (the source honored the budget) or `:runtime` (Macaw reduced a pooled delivery to this reader's budget, finished a budget the source didn't honor, or clamped a budget to the host ceiling). A component that draws fewer rows than it was handed says so in its own drawn state, `capped` ([macaw_compose 05](https://gitlab.conet.yarina.org/dco-tek/macaw_compose/-/blob/main/spec/05-components.md#components-states)), not in the delivery;
- `origin`: the source, a digest of the request, and `as_of` when used.

Absence is never zero: a source never fills a gap with 0. (metresis.md C1.)

## 4. Push {#sources-push}

<!-- surfex: deferred #58: push is part of the source contract, step 4 -->

Push is optional and declared:
- the subscribe handshake sends the schema first;
- a pushed delivery is an increment, merged by the window field;
- pushes between two pulses are coalesced;
- an unknown schema version falls back to `describe`.

(visualize.md C1; metresis.md C1.)

## 5. Change notification {#sources-change}

<!-- surfex: deferred #58: change notification is part of the source contract, step 4 -->

**"This source's data changed; re-read it."** Any writer (an editing component after a commit, a host after an import) announces a change to a source by name, or the source pushes. Every reader on the page, and on other pages through the notification behavior ([macaw_compose 00](https://gitlab.conet.yarina.org/dco-tek/macaw_compose/-/blob/main/spec/00-overview.md#overview-goals) goal 3), re-fetches. Components never need to know who else reads the same data. (macaw_compose#9.)

## 6. Running sources {#sources-running}

<!-- surfex: deferred #58: running sources is part of the source contract, step 4 -->

- **Pooling:** sources are named and pooled by the page. Several readers of the same source and request cost one fetch, at the largest budget among them, and each reader is reduced to its own budget (`reduced_by: :runtime`). (visualize.md C1.)
- **Pooling across pages** is required in v1 (macaw_compose#22, decision 9). A request to a source that declares itself `viewer_independent` is fetched **once, with the anonymous viewer**, for every page making it, and delivered to each through the notification behavior. Fetching as the anonymous viewer makes the result independent of the viewer by construction, whatever the source does with the viewer. A surface whose state is `:shared`, watched by many viewers, then costs one fetch per pulse, as a visualize board does today. A source that doesn't declare it is never pooled across viewers.
- **The host ceiling** clamps every slot's budget ([macaw_compose 05](https://gitlab.conet.yarina.org/dco-tek/macaw_compose/-/blob/main/spec/05-components.md#components-budget)). A host sets it once; a page may lower it, never raise it.
- **Fetching never blocks the caller.** It runs out of process, with a liveness bound. The first render waits for a bounded time and then draws the loading state. (visualize.md C13 gap; dcotek_web.md C13.)
- **`now` comes from the surface.** One instant per pulse keeps windows, freshness and ages consistent. (visualize.md C1.)

## 7. Credentials {#sources-credentials}

<!-- surfex: deferred #58: credentials are part of the source contract, step 4 -->

Credentials and source configuration never appear in documents. A page names a source; the host maps the name to a configured source (its **source configuration**). For metresis, that is a per-domain token, ideally scoped (metresis#555). (visualize.md C1, D-141; metresis.md C11.)

## 8. The interaction event {#sources-event}

Every component emits interaction in **one struct**, `Macaw.Data.Event`, defined in `macaw_data` so that an adopter using no other Macaw library (visualize standalone) emits the same value it emits on a Macaw page (macaw_compose#22, decision 4; visualize#941):

```elixir
%Event{
  name:      String.t(),               # a name the component declares
  instance:  String.t(),               # the emitting instance's id (macaw_compose spec 01)
  element:   %{frame: id | nil, item: id | nil, path: [id]},  # path innermost first
  identity:  %{field => value} | nil,  # the declared identity of the item, when it maps to data
  value:     term,                     # the event's own value: a window, a chosen option
  initiator: :visitor | :system,
  time:      DateTime.t(),             # the surface's (or standalone holder's) now; never a clock read
  point:     {x, y} | nil,             # where, in the drawing; live only
  modifiers: [atom],
  row:       map | nil                 # the data row, delivered to the host, never recorded
}
```

`name`, `instance`, `initiator` and `time` are required to build one; the rest default: `element` to `%{frame: nil, item: nil, path: []}`, `modifiers` to `[]`, and `identity`, `value`, `point` and `row` to `nil`.

```test:event-struct
the struct can't be built without name, instance, initiator and time, and its defaults are the ones this section lists
```

- **The recorded form,** `Macaw.Data.Event.recordable/1`, drops `row` and `point`. Records, observation and state snapshots only ever see the recorded form, so **row values never reach them**. The `identity` and the event's own `value` do, and they can be personal; whether they are recorded is decided per state source by capture level ([macaw_compose 08](https://gitlab.conet.yarina.org/dco-tek/macaw_compose/-/blob/main/spec/08-records.md#records-stores)).
- **Building one:** `Macaw.Data.Event.new/1` builds an event from a keyword list or a map, checking every field: `name` and `instance` non-empty strings, `initiator` `:visitor` or `:system`, `time` a `DateTime`, `element` a map of `frame`, `item` and `path` with `path` a list (missing keys default to `nil`, `nil` and `[]`), `identity` and `row` a map or `nil`, `point` a pair of numbers or `nil`, `modifiers` a list of `:shift`, `:alt`, `:ctrl` and `:meta`. It returns `{:ok, event}` or `{:error, faults}`, a fault per bad field, **every one at once**, and a field the struct doesn't have is a fault too (`"is not an event field"`), never silently dropped. `Macaw.Data.Event.fields/0` lists the fields in this section's order, which an adopter's interim definition is checked against (macaw_compose spec 00 §5).

```test:event-fields
the struct's fields are exactly name, instance, element, identity, value, initiator, time, point, modifiers and row, and fields/0 returns them in that order
```

```test:event-new-defaults
new/1 with the four required fields builds an event whose element is %{frame: nil, item: nil, path: []}, modifiers [] and point nil
```

```test:event-new-faults
new/1 with a bad name, instance, initiator, time, point, modifiers, element and row and an unknown field returns every one of them as a fault, the unknown one as "is not an event field"
```

```test:event-new-valid
every event with non-empty name and instance, either initiator, a DateTime, modifiers from the four and a list path is accepted (property)
```

```test:event-recordable
recordable/1 drops row and point and keeps every other field, identity and value included
```

```test:event-recordable-no-row
no value of the row ever appears in the recorded form (property over rows carrying a unique marker)
```

### 8.1 Rules for the components that emit events {#sources-event-rules}

<!-- surfex: class component-rule -->

These bind the component that draws, not this library's code; each emitting library's conformance kit checks them (macaw_compose spec 12).

- **`element`** locates what was acted on: the component fills it. `item` is the element's stable id ([macaw_compose 05](https://gitlab.conet.yarina.org/dco-tek/macaw_compose/-/blob/main/spec/05-components.md#components-declares)); `path` lists **the item and its enclosing elements, innermost first** (a visual's mark is `[item]`; a prose component's element, its sections around it), aligned with visualize's established meaning (macaw_compose#65); `frame` is set only by components with an inner coordinate tree (a visual's frame), and is `nil` otherwise.
- **`initiator`**, which the component sets, separates the steps of a view path (a visitor did something) from its markers (the system did something) ([macaw_compose 08](https://gitlab.conet.yarina.org/dco-tek/macaw_compose/-/blob/main/spec/08-records.md#records-paths)). A paused animation is a system event.
- **`time`** is the holder's now, passed to the component; a component's event code never reads a clock for it. A Macaw surface always supplies its own clock, which tests and replays control, so a recorded path replays with its times. A **standalone holder** (a visualize chart outside any surface, whose host is its holder) may default its now to the host's wall clock, if the default stays injectable and is checked to answer a `DateTime` (macaw_compose#73, #91; visualize#955).
- **The drawn-token rule:** an event on an element that maps to data resolves against the drawing it landed on. Each drawing carries a token; an event whose token is not the current drawing's is dropped, never resolved against newer data. (visualize D-170.)
- **Identity is the declared identity** of the item (§1). Inference from other fields is allowed only for a visitor's one-off pick, never for tracking or recording. (visualize D-167.)
