defmodule Macaw.Data.Source.Finish.Columns do
  @moduledoc false
  # Finishing a table on its columns (spec/01 §2.4, macaw_data#105): each step reads the
  # columns it decides by and answers the indexes of the rows it keeps, ascending, and the
  # kept rows are taken from the chunks that hold them (`Macaw.Data.Table.Subset`). No row
  # is made.
  #
  # Each step keeps exactly the rows its row twin keeps (`Macaw.Data.Window.trim/3`,
  # `latest_rows/3`), by the same comparisons: a packed buffer is compared as it lies only
  # where that is the comparison the row twin makes, and any other column is read value by
  # value through the row twin's own predicate.

  alias Macaw.Data.{Schema, Table, Window}
  alias Macaw.Data.Source.Order
  alias Macaw.Data.Table.{Chunk, Column}
  alias Macaw.Layers.Names

  @doc false
  # The table's column a schema field names, by either spelling, or `nil`.
  @spec column(Table.t(), Table.name() | nil) :: Table.name() | nil
  def column(_table, nil), do: nil
  def column(table, field), do: Enum.find(Table.names(table), &Names.same?(&1, field))

  # -- :window and :region ------------------------------------------------------------------

  @doc false
  # The indexes, ascending, of the rows whose `field` lies in `window` (`Window.within?/2`,
  # both bounds inclusive, a missing value in none). A table sorted by the field
  # (`Table.sorted/1`), every chunk packed in the bounds' kind, is binary-searched to one
  # run; otherwise each chunk is scanned, its packed buffer where the bounds are its kind,
  # its values through `within?/2` where not.
  @spec within(Table.t(), Table.name() | nil, Window.t()) ::
          {:run, non_neg_integer(), non_neg_integer()} | {:at, [non_neg_integer()]}
  def within(table, field, [from, to] = window) do
    size = Table.size(table)

    case column(table, field) do
      nil ->
        {:at, []}

      name ->
        views = Table.chunks(table)

        forms =
          Enum.map(views, fn {chunk, first, count} -> kind(storage(chunk, name, first, count)) end)

        if Table.sorted(table) == name and Enum.all?(forms, &bounds_of?(&1, from, to)) do
          lower =
            if from == nil,
              do: 0,
              else: search(views, name, size, &(&1 == nil or Window.compare(&1, from) != :lt))

          upper =
            search(
              views,
              name,
              size,
              &(&1 == nil or (to != nil and Window.compare(&1, to) == :gt))
            )

          {:run, lower, max(upper - lower, 0)}
        else
          {:at, scan(views, forms, name, window)}
        end
    end
  end

  # A view's column storage, as read.
  defp storage(chunk, name, first, count), do: Chunk.storage(chunk, name, first, count)

  # The kind of time or number a packed column holds, compared as it lies; `:general` for
  # any other form (a list of terms, an integral or union number column).
  defp kind({form, _data, _validity}) when form in [:int64, :float64], do: :number
  defp kind({:utc, _us, _validity, _precision}), do: DateTime
  defp kind({:zoned, _us, _validity, _precision, _zones, _codes}), do: DateTime
  defp kind({:naive, _us, _validity, _precision}), do: NaiveDateTime
  defp kind({:date, _days, _validity}), do: Date
  defp kind(_column), do: :general

  # Whether each bound is of the kind, or open.
  defp bounds_of?(:general, _from, _to), do: false
  defp bounds_of?(kind, from, to), do: bound_of?(kind, from) and bound_of?(kind, to)

  defp bound_of?(_kind, nil), do: true
  defp bound_of?(:number, value), do: is_number(value)
  defp bound_of?(kind, %{__struct__: kind}), do: true
  defp bound_of?(_kind, _value), do: false

  # The first index, of `size`, at which `past?` holds, over a column in ascending order,
  # missing values last: `past?` is false up to it and true from it.
  defp search(views, name, size, past?), do: bisect(views, name, past?, 0, size)

  defp bisect(_views, _name, _past?, low, high) when low >= high, do: low

  defp bisect(views, name, past?, low, high) do
    middle = div(low + high, 2)

    if past?.(value_at(views, name, middle)),
      do: bisect(views, name, past?, low, middle),
      else: bisect(views, name, past?, middle + 1, high)
  end

  # The value of column `name` at row `i` of the table's views.
  defp value_at([{chunk, first, count} | _views], name, i) when i < count,
    do: Chunk.at(chunk, name, first + i)

  defp value_at([{_chunk, _first, count} | views], name, i), do: value_at(views, name, i - count)

  # Every view's kept indexes, offset to the table's.
  defp scan(views, forms, name, window) do
    views
    |> Enum.zip(forms)
    |> Enum.reduce({0, []}, fn {{chunk, first, count}, form}, {start, acc} ->
      kept = kept(chunk, name, first, count, form, window)
      {start + count, [Enum.map(kept, &(&1 + start)) | acc]}
    end)
    |> elem(1)
    |> Enum.reverse()
    |> Enum.concat()
  end

  # One view's indexes in the window: its packed buffer compared against the bounds where
  # they are its kind, each closed bound's test a scan, the two intersected (a test over a
  # buffer keeps no missing value); else its values.
  defp kept(chunk, name, first, count, form, [from, to] = window) do
    tests = for {test, bound} <- [gte: from, lte: to], bound != nil, do: {test, bound}

    with true <- tests != [] and bounds_of?(form, from, to),
         storage = storage(chunk, name, first, count),
         {:ok, [found | more]} <- wheres(storage, count, tests, form) do
      Enum.reduce(more, found, &intersect(&2, &1))
    else
      _general ->
        chunk
        |> Chunk.values(name, first, count)
        |> Enum.with_index()
        |> Enum.flat_map(fn {value, i} -> if Window.within?(value, window), do: [i], else: [] end)
    end
  end

  # Each bound's test over the buffer, ascending indexes, or `:general` when the buffer
  # cannot be read so (`Column.where/4` reads a number buffer only with no value missing).
  defp wheres(storage, count, tests, form) do
    Enum.reduce_while(tests, {:ok, []}, fn {test, bound}, {:ok, acc} ->
      case Column.where(storage, count, test, comparable(bound, form)) do
        {:ok, indexes} -> {:cont, {:ok, acc ++ [indexes]}}
        :general -> {:halt, :general}
      end
    end)
  end

  # A bound as its buffer holds it: a number as itself, a time as its instant.
  defp comparable(bound, :number), do: bound
  defp comparable(bound, _time), do: Order.instant(bound)

  # Two ascending index lists' common indexes.
  defp intersect([a | as], [a | bs]), do: [a | intersect(as, bs)]
  defp intersect([a | as], [b | _] = bs) when a < b, do: intersect(as, bs)
  defp intersect([_ | _] = as, [_ | bs]), do: intersect(as, bs)
  defp intersect(_as, _bs), do: []

  @doc false
  # The indexes, ascending, of the rows whose every ranged field lies in its range
  # (`Window.trim_region/2`): each field's `within/3`, intersected.
  @spec region(Table.t(), %{Table.name() => Window.t()}) :: [non_neg_integer()]
  def region(table, region) do
    region
    |> Enum.map(fn {field, range} -> indexes(within(table, field, range)) end)
    |> Enum.reduce(&intersect(&2, &1))
  end

  defp indexes({:run, first, count}), do: Enum.to_list(first..(first + count - 1)//1)
  defp indexes({:at, indexes}), do: indexes

  # -- :box --------------------------------------------------------------------------------

  @doc false
  # The indexes, ascending, of the rows whose `field` lies in the box (`Window.in_box?/2`):
  # a point column is a list of its positions, read value by value.
  @spec box(Table.t(), Table.name(), map()) :: [non_neg_integer()]
  def box(table, field, box) do
    table
    |> values(field)
    |> Enum.with_index()
    |> Enum.flat_map(fn {position, i} -> if Window.in_box?(position, box), do: [i], else: [] end)
  end

  # -- :order ------------------------------------------------------------------------------

  @doc false
  # The row indexes in the order (`Order.sort_with/4`), each field read from its column as
  # `Order.sort/3` reads it of a row: `{:ok, indexes}`, or the order's faults.
  @spec ordered(Table.t(), Order.t(), Schema.t()) ::
          {:ok, [non_neg_integer()]} | {:error, [{list(), term()}, ...]}
  def ordered(table, order, schema) do
    columns =
      Map.new(order, fn {field, _direction} -> {field, List.to_tuple(values(table, field))} end)

    indexes = Enum.to_list(0..(Table.size(table) - 1)//1)

    Order.sort_with(indexes, order, schema, fn i, field -> elem(Map.fetch!(columns, field), i) end)
  end

  # -- reading a column -------------------------------------------------------------------

  @doc false
  # A field's values, in order, as its column decodes them; every row's `nil` when the
  # table has no column the field names (`Table.get/2` of a row reads it so).
  @spec values(Table.t(), Table.name() | nil) :: [term()]
  def values(table, field) do
    case column(table, field) do
      nil ->
        List.duplicate(nil, Table.size(table))

      name ->
        Enum.flat_map(Table.chunks(table), fn {chunk, first, count} ->
          Chunk.values(chunk, name, first, count)
        end)
    end
  end

  @doc false
  # Each row's `Window.position/1` by a field, `nil` where it has none. A UTC or zoned
  # buffer holds the very position, Unix microseconds, read as it lies; any other column is
  # read value by value.
  @spec positions(Table.t(), Table.name() | nil) :: [number() | nil]
  def positions(table, field) do
    case column(table, field) do
      nil ->
        List.duplicate(nil, Table.size(table))

      name ->
        Enum.flat_map(Table.chunks(table), fn {chunk, first, count} ->
          case kind(storage(chunk, name, first, count)) do
            DateTime -> Chunk.instants(chunk, name, first, count)
            _other -> chunk |> Chunk.values(name, first, count) |> Enum.map(&Window.position/1)
          end
        end)
    end
  end

  # -- :latest ------------------------------------------------------------------------------

  @doc false
  # The indexes, ascending, of each identity's latest row by `field`'s position
  # (`Window.position/1`), the later in order on a tie; a row whose identity or position is
  # `nil` names nothing and is dropped (`Window.latest_rows/3`).
  @spec latest(Table.t(), Table.name(), Schema.t()) :: [non_neg_integer()]
  def latest(table, field, schema) do
    ids = identities(table, Schema.identity(schema))
    Window.latest_indexes(Enum.zip(ids, positions(table, field)))
  end

  # Each row's identity: the one field's value, a tuple of several fields' values, `nil`
  # when one is missing (`Schema.identity/2` tells rows apart the same way); every row's
  # `nil` with no identity declared.
  defp identities(table, []), do: List.duplicate(nil, Table.size(table))

  defp identities(table, fields) do
    case Enum.map(fields, &values(table, &1)) do
      [one] -> one
      several -> Enum.zip_with(several, &composite/1)
    end
  end

  defp composite(values), do: if(nil in values, do: nil, else: List.to_tuple(values))
end
