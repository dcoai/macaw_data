defmodule Macaw.Data.Delivery do
  @moduledoc """
  One answer of a source: its rows, as a table, and what it actually served (spec/01 §3).

  A delivery is a handful of terms beside its table, never per row:

  - `table`: the rows, a `Macaw.Data.Table`. `new/2` reads any source shape into one at
    the edge, so a gap stays `nil`: **absence is never zero**.
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
    - `note`: a line for a person (`"coarsened from raw"`), or `nil`.
  - `origin`: where it came from, `%{source: name, request: digest, as_of: time | nil}`,
    or `nil`.

  The shape of visualize's `Visualize.Data.Delivery`, whose facts are flat and whose
  `reduced_by` is `:feed` or `:visualize`, is spec/01 §3's here.

  ## Examples

      iex> alias Macaw.Data.{Delivery, Table}
      iex> d = Delivery.new(%{t: [1, 2], v: [3, nil]}, served: [window: [0, 10]], schema: "ab12")
      iex> Table.rows(d.table)
      [%{t: 1, v: 3}, %{t: 2, v: nil}]
      iex> {d.served.window, d.served.capped, d.served.reduced_by}
      {[0, 10], false, nil}

  """

  alias Macaw.Data.Table

  @enforce_keys [:table, :served]
  defstruct [:table, :served, schema: nil, origin: nil]

  @served_defaults %{
    window: nil,
    resolution: nil,
    capped: false,
    reduced_by: nil,
    params: %{},
    note: nil
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
          note: String.t() | nil
        }

  @typedoc "Where an answer came from."
  @type origin :: %{source: term(), request: String.t(), as_of: DateTime.t() | nil} | nil

  @type t :: %__MODULE__{
          table: Table.t(),
          served: served(),
          schema: String.t() | nil,
          origin: origin()
        }

  @doc """
  A delivery of `rows`, any source `Macaw.Data.Table.from/2` reads (a table passes as it
  is), with `served:` (a keyword list or map of the served facts), `schema:` (a version)
  and `origin:`. `types:` is passed to `Table.from/2`.

  Raises `ArgumentError` naming the fault: a key that is not a delivery's or a served
  fact, a value a field does not take, or rows no table reads.
  """
  @spec new(Table.source() | Table.t(), keyword()) :: t()
  def new(rows, opts \\ [])

  def new(%__MODULE__{}, _opts),
    do: raise(ArgumentError, "a delivery carries rows, not another delivery")

  def new(rows, opts) when is_list(opts) do
    opts = Keyword.validate!(opts, [:served, :schema, :origin, :types])

    table =
      case Table.from(rows, types: Keyword.get(opts, :types, %{})) do
        {:ok, table} -> table
        {:error, faults} -> raise ArgumentError, "not a delivery's rows: #{inspect(faults)}"
      end

    %__MODULE__{
      table: table,
      served: served(Keyword.get(opts, :served, [])),
      schema: schema(Keyword.get(opts, :schema)),
      origin: origin(Keyword.get(opts, :origin))
    }
  end

  @doc "The rows a delivery carries, one map per row (`Macaw.Data.Table.rows/1`)."
  @spec rows(t()) :: [map()]
  def rows(%__MODULE__{table: table}), do: Table.rows(table)

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

  defp check(:window, %{west: w, south: s, east: e, north: n} = box)
       when map_size(box) == 4 and is_number(w) and is_number(s) and is_number(e) and
              is_number(n) and s <= n and s >= -90 and n <= 90 and w >= -180 and w <= 180 and
              e >= -180 and e <= 180,
       do: :ok

  defp check(:resolution, _any), do: :ok
  defp check(:capped, capped) when is_boolean(capped), do: :ok
  defp check(:reduced_by, by) when by in [nil, :source, :runtime], do: :ok
  defp check(:params, params) when is_map(params) and not is_struct(params), do: :ok
  defp check(:note, note) when is_nil(note) or is_binary(note), do: :ok

  defp check(key, value),
    do: raise(ArgumentError, "not a delivery's served #{key}: #{inspect(value)} (spec/01 §3)")

  defp schema(version) when is_nil(version) or is_binary(version), do: version
  defp schema(other), do: raise(ArgumentError, "not a schema version: #{inspect(other)}")

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
