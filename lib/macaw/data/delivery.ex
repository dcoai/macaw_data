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
    - `reduced_by`: who brought the rows within budget, `:source` or `:runtime`, or `nil`
      when nobody had to;
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
      iex> d = Delivery.new(rows, served: [window: [0, 10]], schema: "ab12")
      iex> Delivery.rows(d) === rows
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

  @served_defaults %{
    window: nil,
    resolution: nil,
    capped: false,
    reduced_by: nil,
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
          reduced_by: :source | :runtime | nil,
          params: map(),
          note: String.t() | nil,
          position: non_neg_integer() | nil,
          complete_until: term()
        }

  @typedoc "A range replacement (spec/01 §4.2): over `[from, to)`, limited to `identities`, exactly `rows`."
  @type replacement :: %{from: term(), to: term(), identities: [term()] | nil, rows: [map()]}

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
  `table/2`).

  Raises `ArgumentError` naming the fault: a key that is not a delivery's or a served
  fact, a value a field does not take, a delivery of a delivery, or rows of no shape a
  source has. The rows themselves are not read: a source's rows are its own until a
  reader reads them.
  """
  @spec new(Table.source() | Table.t(), keyword()) :: t()
  def new(rows, opts \\ [])

  def new(%__MODULE__{}, _opts),
    do: raise(ArgumentError, "a delivery carries rows, not another delivery")

  def new(rows, opts) when is_list(opts) do
    opts =
      Keyword.validate!(opts, [:served, :schema, :origin, :types, :names, :retracted, :replace])

    source!(rows)

    %__MODULE__{
      rows: rows,
      names: names(Keyword.get(opts, :names)),
      types: types(Keyword.get(opts, :types, %{})),
      served: served(Keyword.get(opts, :served, [])),
      schema: schema(Keyword.get(opts, :schema)),
      origin: origin(Keyword.get(opts, :origin)),
      retracted: retracted(Keyword.get(opts, :retracted, [])),
      replace: replace(Keyword.get(opts, :replace, []))
    }
  end

  @doc """
  The rows a delivery carries, as `Macaw.Data.Table.rows/1` reads its source: a row list
  itself, uncopied, its tuple rows unchanged; a table, a column map or a tensor one row
  at a time. Nothing is rewritten.
  """
  @spec rows(t()) :: [Table.row()]
  def rows(%__MODULE__{rows: rows}), do: Table.rows(rows)

  @doc """
  The rows as maps, for a reader that reads them by name (finishing, push, a reducer):
  `rows/1`, with tuple rows and a tensor's named by `names` (`Macaw.Data.Table.named/2`).
  Tuple rows without names raise `ArgumentError`: they cannot be read by name, and are
  never dropped for it.
  """
  @spec named_rows(t()) :: [map()]
  def named_rows(%__MODULE__{rows: rows, names: names}) do
    source =
      case {Table.unnamed?(rows), names} do
        {false, _names} ->
          rows

        {true, nil} ->
          raise ArgumentError, "tuple rows have no names: give Delivery.new/2 names: [...]"

        {true, names} ->
          named!(rows, names)
      end

    Table.rows(source)
  end

  @doc """
  The rows packed into a `Macaw.Data.Table` (spec/01 §1.1), for a reader that wants
  columns: `{:ok, table}` or `{:error, faults}`. A table passes as it is. The delivery's
  `types:` and `names:` apply, and `opts` may give others (`types:` merged over them).
  Packing normalizes (an integer beside floats reads back a float, a naive time a UTC
  `DateTime`); the delivery's rows are never changed by it.
  """
  @spec table(t(), keyword()) :: {:ok, Table.t()} | {:error, term()}
  def table(delivery, opts \\ [])
  def table(%__MODULE__{rows: %Table{} = table}, _opts), do: {:ok, table}

  def table(%__MODULE__{} = delivery, opts) do
    opts = Keyword.validate!(opts, types: %{}, names: nil)
    names = opts[:names] || delivery.names

    with {:ok, source} <- named(delivery.rows, names),
         do: Table.from(source, types: Map.merge(delivery.types, opts[:types]))
  end

  @doc "As `table/2`, raising `ArgumentError` naming the faults."
  @spec table!(t(), keyword()) :: Table.t()
  def table!(%__MODULE__{} = delivery, opts \\ []) do
    case table(delivery, opts) do
      {:ok, table} ->
        table

      {:error, faults} ->
        raise ArgumentError, "the rows do not pack into a table: #{inspect(faults)}"
    end
  end

  @doc "Whether the delivery has no rows."
  @spec empty?(t()) :: boolean()
  def empty?(%__MODULE__{rows: %Table{} = table}), do: Table.size(table) == 0
  def empty?(%__MODULE__{rows: rows}) when is_list(rows), do: rows == []
  def empty?(%__MODULE__{} = delivery), do: rows(delivery) == []

  defp named(source, nil), do: {:ok, source}
  defp named(source, names), do: Table.named(source, names)

  defp named!(source, names) do
    case Table.named(source, names) do
      {:ok, named} ->
        named

      {:error, why} ->
        raise ArgumentError, "the tuple rows do not fit their names: #{inspect(why)}"
    end
  end

  # The shapes a source's rows come in, told apart without reading them.
  defp source!(rows) when is_list(rows), do: :ok
  defp source!(%Table{}), do: :ok
  defp source!(%{__struct__: Nx.Tensor}), do: :ok

  defp source!(%_{} = struct) do
    if Code.ensure_loaded?(Elixir.Table.Reader) and Elixir.Table.Reader.impl_for(struct) != nil,
      do: :ok,
      else: raise(ArgumentError, "not a delivery's rows: #{inspect(struct, limit: 5)}")
  end

  defp source!(map) when is_map(map), do: :ok

  defp source!(other),
    do: raise(ArgumentError, "not a delivery's rows: #{inspect(other, limit: 5)}")

  defp names(nil), do: nil

  defp names(names) when is_list(names) do
    if Enum.all?(names, &(is_atom(&1) or is_binary(&1))),
      do: names,
      else: raise(ArgumentError, "not a delivery's names: #{inspect(names)}")
  end

  defp names(other), do: raise(ArgumentError, "not a delivery's names: #{inspect(other)}")

  defp types(%{} = types) when not is_struct(types), do: types
  defp types(types) when is_list(types), do: Map.new(types)
  defp types(other), do: raise(ArgumentError, "not a delivery's types: #{inspect(other)}")

  defp served(facts) when is_list(facts) or is_map(facts) do
    Enum.reduce(facts, @served_defaults, fn {key, value}, acc ->
      if Map.has_key?(@served_defaults, key) do
        check(key, value)
        Map.put(acc, key, value)
      else
        raise ArgumentError, "not a served fact: #{inspect(key)}"
      end
    end)
  end

  defp served(other), do: raise(ArgumentError, "not a delivery's served: #{inspect(other)}")

  defp check(:window, nil), do: :ok
  defp check(:window, [_from, _to]), do: :ok

  defp check(:window, %{} = box) do
    if Request.box?(box), do: :ok, else: check(:bad_window, box)
  end

  defp check(:bad_window, box),
    do: raise(ArgumentError, "not a delivery's served window: #{inspect(box)} (spec/01 §3)")

  defp check(:resolution, _any), do: :ok
  defp check(:capped, capped) when is_boolean(capped), do: :ok
  defp check(:reduced_by, by) when by in [nil, :source, :runtime], do: :ok
  defp check(:params, params) when is_map(params) and not is_struct(params), do: :ok
  defp check(:note, note) when is_nil(note) or is_binary(note), do: :ok
  defp check(:position, p) when is_nil(p) or (is_integer(p) and p >= 0), do: :ok

  defp check(:complete_until, t) when is_nil(t) or is_number(t), do: :ok

  defp check(:complete_until, t) do
    if Window.instant?(t),
      do: :ok,
      else:
        raise(
          ArgumentError,
          "not a delivery's served complete_until: #{inspect(t)} (spec/01 §4.4)"
        )
  end

  defp check(key, value),
    do: raise(ArgumentError, "not a delivery's served #{key}: #{inspect(value)} (spec/01 §3)")

  defp schema(version) when is_nil(version) or is_binary(version), do: version
  defp schema(other), do: raise(ArgumentError, "not a schema version: #{inspect(other)}")

  defp retracted(rows) when is_list(rows) do
    if Enum.all?(rows, &row?/1),
      do: rows,
      else: raise(ArgumentError, "not a delivery's retracted rows: #{inspect(rows, limit: 5)}")
  end

  defp retracted(other),
    do: raise(ArgumentError, "not a delivery's retracted rows: #{inspect(other, limit: 5)}")

  @replacement %{from: nil, to: nil, identities: nil, rows: []}

  defp replace(list) when is_list(list), do: Enum.map(list, &replacement/1)

  defp replace(other),
    do: raise(ArgumentError, "not a delivery's replacements: #{inspect(other, limit: 5)}")

  defp replacement(%{} = given) when not is_struct(given) do
    replacement = Map.merge(@replacement, given)

    if Map.keys(given) -- Map.keys(@replacement) == [] and
         (is_nil(replacement.identities) or is_list(replacement.identities)) and
         is_list(replacement.rows) and Enum.all?(replacement.rows, &row?/1),
       do: replacement,
       else:
         raise(
           ArgumentError,
           "not a range replacement: #{inspect(given, limit: 5)} (spec/01 §4.2)"
         )
  end

  defp replacement(other),
    do:
      raise(ArgumentError, "not a range replacement: #{inspect(other, limit: 5)} (spec/01 §4.2)")

  defp row?(row), do: is_map(row) and not is_struct(row)

  defp origin(nil), do: nil

  defp origin(%{source: _, request: request} = origin)
       when is_binary(request) and map_size(origin) in [2, 3] do
    as_of = Map.get(origin, :as_of)

    if (is_nil(as_of) or match?(%DateTime{}, as_of)) and
         Map.keys(origin) -- [:source, :request, :as_of] == [],
       do: Map.put_new(origin, :as_of, nil),
       else: raise(ArgumentError, "not a delivery's origin: #{inspect(origin)}")
  end

  defp origin(other), do: raise(ArgumentError, "not a delivery's origin: #{inspect(other)}")
end
