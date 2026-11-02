defmodule Macaw.Data.Operations.Transforms do
  @moduledoc """
  The table operations of `macaw_data`'s package (spec/04 §4), each a transform
  (`Macaw.Data.Transform`) ported from visualize's `Chart.Transform.Data`, and what they
  share: finding a column by either spelling of its name, reading a chunk's view of one,
  a reading as seconds, and a per-row selection. Each is a column-native step
  (`Macaw.Data.Operations.Step`, spec/04 §1.4); none reads rows.

  | Op | Options (`*` required) |
  |---|---|
  | `filter` | `field*`, `test`, `value` |
  | `take` | `n*`, `side` |
  | `window` | `field*`, `from`, `to`, `latest` |
  | `lttb` | `fields*`, `n*` |
  | `m4` | `fields*`, `width*` |
  | `sort` | `field*`, `order` |
  | `fold` | `fields*`, `as` |
  | `stack` | `fields*`, `order`, `offset` |
  | `bin` | `field*`, `thresholds`, `as`, `fn` |
  | `aggregate`, `sum` | `field*`, `fn*` (`aggregate` only), `by`, `as` |
  | `spectrum` | `field*`, `time`, `every`, `samples`, `window`, `detrend`, `as` |
  """

  alias Macaw.Data.{Table, Window}
  alias Macaw.Data.Operations.Option

  @doc "The modules of the table operations, in spec/04 §4's order."
  @spec all() :: [module()]
  def all do
    [
      __MODULE__.Filter,
      __MODULE__.Take,
      __MODULE__.Window,
      __MODULE__.Lttb,
      __MODULE__.M4,
      __MODULE__.Sort,
      __MODULE__.Fold,
      __MODULE__.Stack,
      __MODULE__.Bin,
      __MODULE__.Aggregate,
      __MODULE__.Sum,
      __MODULE__.Spectrum
    ]
  end

  @doc false
  # Columns with `added` put last, any column spelling an added name dropped first.
  @spec put_columns(Macaw.Data.Transform.columns(), Macaw.Data.Transform.columns()) ::
          Macaw.Data.Transform.columns()
  def put_columns(columns, added) do
    names = MapSet.new(added, fn {name, _type} -> spell(name) end)
    Enum.reject(columns, fn {name, _type} -> MapSet.member?(names, spell(name)) end) ++ added
  end

  @doc false
  # The type of the column spelled `name`, `:term` when there is none.
  @spec type_of(Macaw.Data.Transform.columns(), Table.name()) :: Table.type()
  def type_of(columns, name) do
    Enum.find_value(columns, :term, fn {column, type} ->
      if spell(column) == spell(name), do: type
    end)
  end

  @doc false
  # The name among `names` that spells `field`, `nil` when none does.
  @spec name_in([Table.name()], Table.name()) :: Table.name() | nil
  def name_in(names, field), do: Enum.find(names, &(spell(&1) == spell(field)))

  @doc false
  # The values of the column named `name` in a chunk's view, all `nil` for no column.
  @spec view_values(Table.view(), Table.name() | nil) :: [term()]
  def view_values({_chunk, _first, count}, nil), do: List.duplicate(nil, count)

  def view_values({chunk, first, count}, name),
    do: Macaw.Data.Table.Chunk.values(chunk, name, first, count)

  @doc false
  # A per-row selection of a view of `count` rows from the indexes kept (spec/04 §1.4).
  @spec selection([non_neg_integer()], non_neg_integer()) ::
          Macaw.Data.Operations.Step.selection()
  def selection([], _count), do: :none
  def selection(kept, count) when length(kept) == count, do: :all
  def selection(kept, _count), do: {:rows, kept}

  @doc false
  @spec spell(Table.name()) :: String.t()
  def spell(name) when is_atom(name), do: Atom.to_string(name)
  def spell(name), do: name

  @doc false
  # A reading as seconds from the epoch (spec/04 §4.3): an instant by its time, an ISO
  # 8601 string as `Table.temporal?/1` reads one, a number as it is; else ArgumentError
  # naming the step and the field.
  @spec seconds!(term(), Table.name(), String.t()) :: number()
  def seconds!(%DateTime{} = at, _field, _op), do: DateTime.to_unix(at, :microsecond) / 1_000_000

  def seconds!(%NaiveDateTime{} = at, _field, _op),
    do: NaiveDateTime.diff(at, ~N[1970-01-01 00:00:00], :microsecond) / 1_000_000

  def seconds!(%Date{} = at, _field, _op), do: Date.diff(at, ~D[1970-01-01]) * 86_400.0
  def seconds!(n, _field, _op) when is_number(n), do: n

  def seconds!(string, field, op) when is_binary(string) do
    parsed =
      with :error <- iso(DateTime.from_iso8601(string)),
           :error <- iso(NaiveDateTime.from_iso8601(string)),
           do: iso(Date.from_iso8601(string))

    case parsed do
      {:ok, at} -> seconds!(at, field, op)
      :error -> not_a!(string, field, op, "a time")
    end
  end

  def seconds!(other, field, op), do: not_a!(other, field, op, "a time")

  defp iso({:ok, at}), do: {:ok, at}
  defp iso({:ok, at, _offset}), do: {:ok, at}
  defp iso(_error), do: :error

  @doc false
  @spec not_a!(term(), Table.name(), String.t(), String.t()) :: no_return()
  def not_a!(value, field, op, kind) do
    raise ArgumentError,
          "transform #{inspect(op)}: #{inspect(field)} reads #{inspect(value)}, which is not " <>
            "#{kind} (spec/04 §4)"
  end

  @doc false
  @spec number!(term(), Table.name(), String.t()) :: number()
  def number!(n, _field, _op) when is_number(n), do: n
  def number!(other, field, op), do: not_a!(other, field, op, "a number")

  @typedoc """
  What a step reads a column's values as (spec/04 §3.1): `:number`; `:time`, a time or a
  number as seconds (`seconds!/3`); `:positive`, a number above zero (a log scale's x);
  `:comparable`, numbers, or times of any kinds, not both; `:point`, a number or a point `[x, y]`;
  `:any`, anything.
  """
  @type reading :: :number | :time | :positive | :comparable | :point | :any

  @doc false
  # Whether every reading of the column `name` reads as `kind` (spec/04 §3.1): checked
  # once over the input, in a step's `bind/3`, before any chunk is read, so the step's
  # readers never meet another. A typed column answers by its type alone, at no cost to a
  # run; any other is read value by value. `nil` is a gap, and passes. A column the
  # table lacks reads `nil` throughout.
  @spec readings(Table.t(), Table.name() | nil, reading()) :: :ok | {:error, {:reads, reading()}}
  def readings(_table, nil, _kind), do: :ok
  def readings(_table, _name, :any), do: :ok

  def readings(%Table{} = table, name, kind) do
    if typed?(Table.column_type(table, name), kind) or
         read_as?(Enum.flat_map(Table.chunks(table), &view_values(&1, name)), kind),
       do: :ok,
       else: {:error, {:reads, kind}}
  end

  defp typed?(:number, kind) when kind in [:number, :time, :comparable, :point], do: true
  defp typed?(:time, kind) when kind in [:time, :comparable], do: true
  defp typed?(_type, _kind), do: false

  @doc false
  # Whether every value of `values` reads as `kind`, `nil` passing (`readings/3`).
  @spec read_as?([term()], reading()) :: boolean()
  def read_as?(_values, :any), do: true

  def read_as?(values, :comparable) do
    case Enum.find(values, &(&1 != nil)) do
      nil -> true
      first -> Enum.all?(values, &(&1 == nil or same_kind?(&1, first)))
    end
  end

  def read_as?(values, kind), do: Enum.all?(values, &(&1 == nil or reads?(&1, kind)))

  defp reads?(n, :number), do: is_number(n)
  defp reads?(n, :positive), do: is_number(n) and n > 0
  defp reads?(n, :point) when is_number(n), do: true
  defp reads?([x, y], :point), do: is_number(x) and is_number(y)
  defp reads?({x, y}, :point), do: is_number(x) and is_number(y)
  defp reads?(_other, :point), do: false
  defp reads?(n, :time) when is_number(n), do: true
  defp reads?(%kind{}, :time) when kind in [DateTime, NaiveDateTime, Date], do: true

  defp reads?(string, :time) when is_binary(string),
    do:
      match?({:ok, _}, iso(DateTime.from_iso8601(string))) or
        match?({:ok, _}, iso(NaiveDateTime.from_iso8601(string))) or
        match?({:ok, _}, iso(Date.from_iso8601(string)))

  defp reads?(_other, :time), do: false

  # Numbers with numbers, times of any kinds with times: the scale `Window.compare/2`
  # orders them on (macaw_data#141).
  defp same_kind?(a, b), do: Window.comparable?(a, b)

  @doc false
  # The option every aggregate-naming step shares (spec/04 §4.9, §4.10).
  @spec field_option() :: {String.t(), Option.t()}
  def field_option,
    do: {"field", %Option{type: :field, required: true, doc: "the column read"}}
end
