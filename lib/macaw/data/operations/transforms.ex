defmodule Macaw.Data.Operations.Transforms do
  @moduledoc """
  The table operations of `macaw_data`'s package (spec/04 §4), each a transform
  (`Macaw.Data.Transform`) ported from visualize's `Chart.Transform.Data`, and what they
  share: reading a column by either spelling of its name, a reading as seconds, and
  answering rows as the table `outputs/2` names.

  | Op | Options (`*` required) |
  |---|---|
  | `filter` | `field*`, `test`, `value` |
  | `take` | `n*`, `side` |
  | `window` | `field*`, `from`, `to`, `latest` |
  | `lttb` | `fields*`, `n*` |
  | `m4` | `fields*`, `width*` |
  | `sort` | `field*`, `order` |
  | `fold` | `fields*`, `as` |
  | `aggregate`, `sum` | `field*`, `fn*` (`aggregate` only), `by`, `as` |
  """

  alias Macaw.Data.{Operations, Table}
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
      __MODULE__.Aggregate,
      __MODULE__.Sum
    ]
  end

  @doc false
  # The rows a step derived, as the table its outputs name over the input's columns.
  @spec answer([map()], module(), map(), Table.t()) :: Table.t()
  def answer(rows, module, node, table),
    do: Operations.table(rows, module.outputs(node, Operations.columns(table)))

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
  # The values of the column spelled `name`, read from the table's own storage, a packed
  # column without building a row list; all nil when the table has none.
  @spec column(Table.t(), Table.name()) :: [term()]
  def column(table, name) do
    case Enum.find(Table.names(table), &(spell(&1) == spell(name))) do
      nil -> List.duplicate(nil, Table.size(table))
      found -> Table.column(table, found)
    end
  end

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
  # The `{x, y}` a downsampling reads from a row: x a number or a time in seconds, y a
  # number, and nil either way a gap (spec/04 §4.4).
  @spec point_reader(String.t(), [Table.name()]) :: (map() -> {term(), term()})
  def point_reader(op, [x, y]) do
    fn row ->
      {reading(Table.get(row, x), x, op, &seconds!/3),
       reading(Table.get(row, y), y, op, &number!/3)}
    end
  end

  defp reading(nil, _field, _op, _read), do: nil
  defp reading(value, field, op, read), do: read.(value, field, op)

  @doc false
  @spec number!(term(), Table.name(), String.t()) :: number()
  def number!(n, _field, _op) when is_number(n), do: n
  def number!(other, field, op), do: not_a!(other, field, op, "a number")

  @doc false
  # The option every aggregate-naming step shares (spec/04 §4.9, §4.10).
  @spec field_option() :: {String.t(), Option.t()}
  def field_option,
    do: {"field", %Option{type: :field, required: true, doc: "the column read"}}
end
