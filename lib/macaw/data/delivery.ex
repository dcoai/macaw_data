defmodule Macaw.Data.Delivery do
  @moduledoc """
  One answer of a source: its rows, as the source gave them, and what it actually served
  (spec/01 §3).

  A delivery is a handful of terms beside its rows, never per row:

  - `rows`: **the rows as the source gave them** (macaw#185): a list of row maps or
    tuples, a map or keyword list of columns, an `Nx.Tensor`, a `Table.Reader` source, or
    a `Macaw.Data.Table`. Nothing is packed or rewritten at construction: `rows/1` reads
    them as they are, a row list uncopied, and `table/2` packs them into a table for a
    reader that wants columns, normalizing there and only there. A source that has a
    table delivers it, and it passes as it is. A gap stays `nil` in either form:
    **absence is never zero**.
  - `names`: the column names of tuple rows or a tensor, in order, for whoever must read
    them by name (`named_rows/1`, `table/2`, finishing); `nil` otherwise.
  - `types`: column types for `table/2` to pack with, `%{}` to infer them.
  - `schema`: the **version** of the schema the rows were produced under
    (`Macaw.Data.Schema.version/1`), never the schema itself, which
    `Macaw.Data.Schema.Cache` holds by version; `nil` when the source has none.
  - `served`: what this answer served, which may differ from what was asked:
    - `window`: a range `[from, to]`, a box over a `:point` window field
      `%{west: w, south: s, east: e, north: n}`, or `nil`;
    - `resolution`: the spacing of the rows as served (seconds, or a name such as
      `:minute`), or `nil`;
    - `capped`: whether the source stopped short of the window it was asked for;
    - `stale`: whether the source answered from a store it could not refresh, so the
      answer may be out of date (its upstream failed, and it served its last good
      answer); a fact of this one answer, as `capped` is, not a capability;
    - `reduced_by`: who brought the rows within budget, `:source` or `:runtime`, or `nil`
      when nobody had to;
    - `ordered`: who put the rows in the request's `order` (spec/01 §2.4): `:source`, which
      served its first rows in it; `:runtime`, which ordered every row the source served
      and kept the first; `:sample`, which ordered rows the source had already cut (its
      `reduced_by: :source`, or `capped`), so they are in the order but need not be the
      first in it; or `nil`, no order asked;
    - `params`: the parameters it was answered for, a map;
    - `note`: a line for a person (`"coarsened from raw"`), or `nil`;
    - `position`: for a snapshot taken for a push subscription, the sequence number of
      the last increment it reflects (`0` for none); `nil` for any other answer
      (spec/01 §4.1);
    - `complete_until`: a value of the window field, a time or a number, below which the
      source expects no further change, or `nil` for no claim (spec/01 §4.4).
  - `origin`: where it came from, `%{source: name, request: digest, as_of: time | nil}`,
    or `nil`;
  - `retracted` and `replace`: the changes a pushed increment carries beside its inserted
    rows (spec/01 §4.2), rows withdrawn and range replacements
    `%{from, to, identities, rows}`; both `[]` by default, and a snapshot carries neither.

  The shape of visualize's `Visualize.Data.Delivery`, whose facts are flat and whose
  `reduced_by` is `:feed` or `:visualize`, is spec/01 §3's here.

  ## Examples

      iex> alias Macaw.Data.Delivery
      iex> rows = [%{t: 1, v: 3}, %{t: 2, v: nil}]
      iex> {:ok, d} = Delivery.new(rows, served: [window: [0, 10]], schema: "ab12")
      iex> Delivery.rows(d) === {:ok, rows}
      true
      iex> {d.served.window, d.served.capped, d.served.reduced_by}
      {[0, 10], false, nil}
      iex> d |> Delivery.table!() |> Macaw.Data.Table.column(:v)
      [3, nil]

  """

  alias Macaw.Data.Source.Request
  alias Macaw.Data.{Table, Window}

  # `table` is optional: `new/2` asks its protocol about a struct only when it is loaded.
  @compile {:no_warn_undefined, [Elixir.Table.Reader]}

  @enforce_keys [:rows, :served]
  defstruct [
    :rows,
    :served,
    names: nil,
    types: %{},
    schema: nil,
    origin: nil,
    retracted: [],
    replace: []
  ]

  @options [:served, :schema, :origin, :types, :names, :retracted, :replace]
  @reduced_by [nil, :source, :runtime]
  @ordered [nil, :source, :runtime, :sample]

  @served_defaults %{
    window: nil,
    resolution: nil,
    capped: false,
    stale: false,
    reduced_by: nil,
    ordered: nil,
    params: %{},
    note: nil,
    position: nil,
    complete_until: nil
  }

  @typedoc "A window as served: a range, a box over positions, or none."
  @type window ::
          [term()]
          | %{west: number(), south: number(), east: number(), north: number()}
          | nil

  @typedoc "What one answer served (spec/01 §3)."
  @type served :: %{
          window: window(),
          resolution: term(),
          capped: boolean(),
          stale: boolean(),
          reduced_by: :source | :runtime | nil,
          ordered: :source | :runtime | :sample | nil,
          params: map(),
          note: String.t() | nil,
          position: non_neg_integer() | nil,
          complete_until: term()
        }

  @typedoc "A range replacement (spec/01 §4.2): over `[from, to)`, limited to `identities`, exactly `rows`."
  @type replacement :: %{from: term(), to: term(), identities: [term()] | nil, rows: [map()]}

  @typedoc "A fault in a delivery's arguments: where it is, and why (`format_error/1`)."
  @type fault :: {[atom() | non_neg_integer()], term()}

  @typedoc "Where an answer came from."
  @type origin :: %{source: term(), request: String.t(), as_of: DateTime.t() | nil} | nil

  @type t :: %__MODULE__{
          rows: Table.source() | Table.t(),
          names: [Table.name()] | nil,
          types: %{Table.name() => Table.type()},
          served: served(),
          schema: String.t() | nil,
          origin: origin(),
          retracted: [map()],
          replace: [replacement()]
        }

  @doc """
  A delivery of `rows`, any source `Macaw.Data.Table.rows/1` reads, kept as given, with
  `served:` (a keyword list or map of the served facts), `schema:` (a version), `origin:`,
  `names:` (tuple rows' or a tensor's column names, in order) and `types:` (for
  `table/2`): `{:ok, delivery}`, or every fault, `{path, reason}` (spec/01 §3):

  - `{[:rows], :delivery}`: a delivery of a delivery;
  - `{[:rows], {:type, :rows}}`: rows of no shape a source has;
  - `{[key], :unknown_key}`: an option that is not a delivery's, and
    `{[:opts], {:type, :keyword}}` options that are not a keyword list;
  - `{[:served, fact], :unknown_key}`: a fact that is not a served fact, and
    `{[:served, fact], reason}` a value it does not take: `{:type, :window}`,
    `{:type, :boolean}`, `{:enum, values}`, `{:type, :map}`, `{:type, :string}`,
    `{:type, :non_neg_integer}` or `{:type, :instant}`; `{[:served], {:type, :keyword}}`
    for served facts that are neither a keyword list nor a map;
  - `{[:names], {:type, :names}}`, `{[:types], {:type, :map}}`,
    `{[:schema], {:type, :version}}` and `{[:origin], {:type, :origin}}`;
  - `{[:retracted], {:type, :list}}` and `{[:retracted, i], {:type, :row}}`;
    `{[:replace], {:type, :list}}` and `{[:replace, i], {:type, :replacement}}`.

  `format_error/1` gives a fault's words. The rows themselves are not read: a source's
  rows are its own until a reader reads them.
  """
  @spec new(Table.source() | Table.t(), keyword()) :: {:ok, t()} | {:error, [fault(), ...]}
  def new(rows, opts \\ [])

  def new(rows, opts) when is_list(opts) do
    names = Keyword.get(opts, :names)
    types = Keyword.get(opts, :types, %{})
    {served, served_faults} = served(Keyword.get(opts, :served, []))
    schema = Keyword.get(opts, :schema)
    {origin, origin_faults} = origin(Keyword.get(opts, :origin))
    retracted = Keyword.get(opts, :retracted, [])
    {replace, replace_faults} = replace(Keyword.get(opts, :replace, []))

    case source(rows) ++
           options(opts) ++
           names(names) ++
           types(types) ++
           served_faults ++
           schema(schema) ++ origin_faults ++ retracted(retracted) ++ replace_faults do
      [] ->
        {:ok,
         %__MODULE__{
           rows: rows,
           names: names,
           types: Map.new(types),
           served: served,
           schema: schema,
           origin: origin,
           retracted: retracted,
           replace: replace
         }}

      faults ->
        {:error, faults}
    end
  end

  def new(_rows, _opts), do: {:error, [{[:opts], {:type, :keyword}}]}

  @doc "As `new/2`, raising `Macaw.Data.Error` in `format_error/1`'s words."
  @spec new!(Table.source() | Table.t(), keyword()) :: t()
  def new!(rows, opts \\ []) do
    case new(rows, opts) do
      {:ok, delivery} ->
        delivery

      {:error, faults} ->
        raise Macaw.Data.Error, reason: faults, message: "not a delivery: " <> words(faults)
    end
  end

  @doc """
  The rows a delivery carries, as `Macaw.Data.Table.rows/1` reads its source:
  `{:ok, rows}`, a row list itself, uncopied, its tuple rows unchanged; a table, a column
  map or a tensor one row at a time. Nothing is rewritten. `new/2` checks the rows' shape,
  so a delivery it built always answers them; rows of a delivery built another way that
  `Macaw.Data.Table.source/1` refuses are its faults under `[:rows]`.
  """
  @spec rows(t()) :: {:ok, [Table.row()]} | {:error, [fault(), ...]}
  def rows(%__MODULE__{rows: rows}) do
    case Table.rows(rows) do
      {:ok, _rows} = ok -> ok
      {:error, faults} -> {:error, Enum.map(faults, fn {path, why} -> {[:rows | path], why} end)}
    end
  end

  @doc "As `rows/1`, the rows alone, raising `Macaw.Data.Error` in `format_error/1`'s words."
  @spec rows!(t()) :: [Table.row()]
  def rows!(%__MODULE__{} = delivery) do
    case rows(delivery) do
      {:ok, rows} ->
        rows

      {:error, faults} ->
        raise Macaw.Data.Error,
          reason: faults,
          message: "the rows cannot be read: " <> words(faults)
    end
  end

  @doc """
  The rows as maps, for a reader that reads them by name (finishing, push, a reducer):
  `{:ok, rows}`, `rows/1` with tuple rows and a tensor's named by `names`
  (`Macaw.Data.Table.named/2`). Tuple rows without names are `{:error, [{[:names],
  :required}]}`: they cannot be read by name, and are never dropped for it. Rows that do
  not fit their names are `{[:names], reason}`, `Macaw.Data.Table.named/2`'s reason
  (`{:width, names, width}`, `{:rank, rank}`).
  """
  @spec named_rows(t()) :: {:ok, [map()]} | {:error, [fault(), ...]}
  def named_rows(%__MODULE__{rows: rows, names: names} = delivery) do
    case {Table.unnamed?(rows), names} do
      {false, _names} ->
        rows(delivery)

      {true, nil} ->
        {:error, [{[:names], :required}]}

      {true, names} ->
        case Table.named(rows, names) do
          {:ok, named} -> rows(%{delivery | rows: named})
          {:error, why} -> {:error, [{[:names], why}]}
        end
    end
  end

  @doc "As `named_rows/1`, raising `Macaw.Data.Error` in `format_error/1`'s words."
  @spec named_rows!(t()) :: [map()]
  def named_rows!(%__MODULE__{} = delivery) do
    case named_rows(delivery) do
      {:ok, rows} ->
        rows

      {:error, faults} ->
        raise Macaw.Data.Error,
          reason: faults,
          message: "the rows cannot be read by name: " <> words(faults)
    end
  end

  @doc """
  The rows packed into a `Macaw.Data.Table` (spec/01 §1.1), for a reader that wants
  columns: `{:ok, table}` or `{:error, faults}`. A table passes as it is. The delivery's
  `types:` and `names:` apply, and `opts` may give others (`types:` merged over them); an
  option it does not take is `{[key], :unknown_key}`.
  Packing normalizes (an integer beside floats reads back a float, a naive time a UTC
  `DateTime`); the delivery's rows are never changed by it.
  """
  @spec table(t(), keyword()) :: {:ok, Table.t()} | {:error, term()}
  def table(delivery, opts \\ [])
  def table(%__MODULE__{rows: %Table{} = table}, _opts), do: {:ok, table}

  def table(%__MODULE__{} = delivery, opts) do
    with {:ok, opts} <- Macaw.Data.Options.known(opts, types: %{}, names: nil),
         {:ok, source} <- named(delivery.rows, opts[:names] || delivery.names),
         do: Table.from(source, types: Map.merge(delivery.types, opts[:types]))
  end

  @doc "As `table/2`, raising `Macaw.Data.Error` naming the faults."
  @spec table!(t(), keyword()) :: Table.t()
  def table!(%__MODULE__{} = delivery, opts \\ []) do
    case table(delivery, opts) do
      {:ok, table} ->
        table

      {:error, faults} ->
        raise Macaw.Data.Error, reason: faults, what: "the rows do not pack into a table"
    end
  end

  @doc "Whether the delivery has no rows."
  @spec empty?(t()) :: boolean()
  def empty?(%__MODULE__{rows: %Table{} = table}), do: Table.size(table) == 0
  def empty?(%__MODULE__{rows: rows}) when is_list(rows), do: rows == []
  def empty?(%__MODULE__{} = delivery), do: rows(delivery) == {:ok, []}

  defp named(source, nil), do: {:ok, source}
  defp named(source, names), do: Table.named(source, names)

  @doc """
  A delivery's fault in words: where it is, its path read as `served.position` or
  `replace[2]`, and what is wrong there.

      iex> Macaw.Data.Delivery.format_error({[:served, :position], {:type, :non_neg_integer}})
      "served.position: not a non-negative integer"
  """
  @spec format_error(fault()) :: String.t()
  def format_error({path, reason}), do: "#{where(path)}: #{why(path, reason)}"

  defp words(faults), do: Enum.map_join(faults, "; ", &format_error/1)

  defp where(path) do
    path
    |> Enum.map_join(".", fn
      i when is_integer(i) -> "[#{i}]"
      key when is_atom(key) or is_binary(key) -> to_string(key)
      other -> inspect(other)
    end)
    |> String.replace(".[", "[")
  end

  defp why([:rows], :delivery), do: "a delivery carries rows, not another delivery"
  defp why([:rows], {:type, :rows}), do: "not a delivery's rows: no shape a source's rows have"
  defp why([:served, _fact], :unknown_key), do: "not a served fact (spec/01 §3)"
  defp why(_path, :unknown_key), do: "not a delivery's option"
  defp why([:names], :required), do: "tuple rows have no names: give Delivery.new/2 names: [...]"

  defp why([:names], {:width, n, width}),
    do: "the tuple rows do not fit their names: #{n} names, a row of #{width}"

  defp why([:names], {:rank, rank}),
    do: "the tensor does not fit its names: rank #{rank}, not 1 or 2"

  defp why(_path, {:rank, rank}), do: "a tensor of rank #{rank}, not 1 or 2"
  defp why(_path, {:length, n}), do: "a column of another length than the first's #{n}"
  defp why(_path, {:type, :column}), do: "not a column: a list of values"
  defp why(_path, {:enum, values}), do: "not one of #{inspect(values)}"
  defp why(_path, {:type, :keyword}), do: "not a keyword list or a map"
  defp why(_path, {:type, :window}), do: "not a range [from, to], a box or nil (spec/01 §3)"
  defp why(_path, {:type, :boolean}), do: "not a boolean"
  defp why(_path, {:type, :map}), do: "not a map"
  defp why(_path, {:type, :string}), do: "not a string or nil"
  defp why(_path, {:type, :non_neg_integer}), do: "not a non-negative integer"

  defp why(_path, {:type, :instant}),
    do: "not a time, a number or nil, below which no change is expected (spec/01 §4.4)"

  defp why(_path, {:type, :names}), do: "not a list of atoms or strings"
  defp why(_path, {:type, :version}), do: "not a schema version, a string or nil"

  defp why(_path, {:type, :origin}),
    do: "not an origin, %{source: name, request: digest, as_of: time | nil}"

  defp why(_path, {:type, :list}), do: "not a list"
  defp why(_path, {:type, :row}), do: "not a row map"

  defp why(_path, {:type, :replacement}),
    do: "not a range replacement, %{from, to, identities, rows} (spec/01 §4.2)"

  # Every option not a delivery's, or the options not a keyword list.
  defp options(opts) do
    Enum.flat_map(opts, fn
      {key, _value} when key in @options -> []
      {key, _value} when is_atom(key) -> [{[key], :unknown_key}]
      _other -> [{[:opts], {:type, :keyword}}]
    end)
  end

  # The shapes a source's rows come in, told apart without reading them.
  defp source(rows) when is_list(rows), do: []
  defp source(%__MODULE__{}), do: [{[:rows], :delivery}]
  defp source(%Table{}), do: []
  defp source(%{__struct__: Nx.Tensor} = tensor), do: shape(tensor)

  defp source(%_{} = struct) do
    if Code.ensure_loaded?(Elixir.Table.Reader) and Elixir.Table.Reader.impl_for(struct) != nil,
      do: [],
      else: [{[:rows], {:type, :rows}}]
  end

  defp source(map) when is_map(map), do: shape(map)
  defp source(_other), do: [{[:rows], {:type, :rows}}]

  # A column map's columns of one length, and a tensor of rank 1 or 2
  # (`Macaw.Data.Table.source/1`), told from their lengths and rank, no value read.
  defp shape(columns) do
    case Table.source(columns) do
      :ok -> []
      {:error, faults} -> for {path, reason} <- faults, do: {[:rows | path], reason}
    end
  end

  defp names(nil), do: []

  defp names(names) when is_list(names) do
    if Enum.all?(names, &(is_atom(&1) or is_binary(&1))),
      do: [],
      else: [{[:names], {:type, :names}}]
  end

  defp names(_other), do: [{[:names], {:type, :names}}]

  defp types(%{} = types) when not is_struct(types), do: []

  defp types(types) when is_list(types) do
    if Enum.all?(types, &match?({_, _}, &1)), do: [], else: [{[:types], {:type, :map}}]
  end

  defp types(_other), do: [{[:types], {:type, :map}}]

  # The served facts over their defaults, and every fault among them.
  defp served(facts) when is_list(facts) or (is_map(facts) and not is_struct(facts)) do
    Enum.reduce(facts, {@served_defaults, []}, fn
      {key, value}, {acc, faults} when is_map_key(@served_defaults, key) ->
        {Map.put(acc, key, value), faults ++ check(key, value)}

      {key, _value}, {acc, faults} ->
        {acc, faults ++ [{[:served, key], :unknown_key}]}

      _other, {acc, faults} ->
        {acc, faults ++ [{[:served], {:type, :keyword}}]}
    end)
  end

  defp served(_other), do: {@served_defaults, [{[:served], {:type, :keyword}}]}

  defp check(:window, nil), do: []
  defp check(:window, [_from, _to]), do: []

  defp check(:window, %{} = box) do
    if Request.box?(box), do: [], else: [{[:served, :window], {:type, :window}}]
  end

  defp check(:window, _other), do: [{[:served, :window], {:type, :window}}]
  defp check(:resolution, _any), do: []
  defp check(:capped, capped) when is_boolean(capped), do: []
  defp check(:capped, _other), do: [{[:served, :capped], {:type, :boolean}}]
  defp check(:stale, stale) when is_boolean(stale), do: []
  defp check(:stale, _other), do: [{[:served, :stale], {:type, :boolean}}]
  defp check(:reduced_by, by) when by in @reduced_by, do: []
  defp check(:reduced_by, _other), do: [{[:served, :reduced_by], {:enum, @reduced_by}}]
  defp check(:ordered, by) when by in @ordered, do: []
  defp check(:ordered, _other), do: [{[:served, :ordered], {:enum, @ordered}}]
  defp check(:params, params) when is_map(params) and not is_struct(params), do: []
  defp check(:params, _other), do: [{[:served, :params], {:type, :map}}]
  defp check(:note, note) when is_nil(note) or is_binary(note), do: []
  defp check(:note, _other), do: [{[:served, :note], {:type, :string}}]
  defp check(:position, p) when is_nil(p) or (is_integer(p) and p >= 0), do: []
  defp check(:position, _other), do: [{[:served, :position], {:type, :non_neg_integer}}]
  defp check(:complete_until, t) when is_nil(t) or is_number(t), do: []

  defp check(:complete_until, t) do
    if Window.instant?(t), do: [], else: [{[:served, :complete_until], {:type, :instant}}]
  end

  defp schema(version) when is_nil(version) or is_binary(version), do: []
  defp schema(_other), do: [{[:schema], {:type, :version}}]

  defp retracted([]), do: []

  defp retracted(rows) when is_list(rows) do
    for {row, i} <- Enum.with_index(rows), not row?(row), do: {[:retracted, i], {:type, :row}}
  end

  defp retracted(_other), do: [{[:retracted], {:type, :list}}]

  @replacement %{from: nil, to: nil, identities: nil, rows: []}

  defp replace([]), do: {[], []}

  defp replace(list) when is_list(list) do
    list
    |> Enum.with_index()
    |> Enum.map_reduce([], fn {given, i}, faults ->
      case replacement(given) do
        {:ok, replacement} -> {replacement, faults}
        :error -> {given, faults ++ [{[:replace, i], {:type, :replacement}}]}
      end
    end)
  end

  defp replace(other), do: {other, [{[:replace], {:type, :list}}]}

  defp replacement(%{} = given) when not is_struct(given) do
    replacement = Map.merge(@replacement, given)

    if Map.keys(given) -- Map.keys(@replacement) == [] and
         (is_nil(replacement.identities) or is_list(replacement.identities)) and
         is_list(replacement.rows) and Enum.all?(replacement.rows, &row?/1),
       do: {:ok, replacement},
       else: :error
  end

  defp replacement(_other), do: :error

  defp row?(row), do: is_map(row) and not is_struct(row)

  defp origin(nil), do: {nil, []}

  defp origin(%{source: _, request: request} = origin)
       when is_binary(request) and map_size(origin) in [2, 3] do
    as_of = Map.get(origin, :as_of)

    if (is_nil(as_of) or match?(%DateTime{}, as_of)) and
         Map.keys(origin) -- [:source, :request, :as_of] == [],
       do: {Map.put_new(origin, :as_of, nil), []},
       else: {origin, [{[:origin], {:type, :origin}}]}
  end

  defp origin(other), do: {other, [{[:origin], {:type, :origin}}]}
end
