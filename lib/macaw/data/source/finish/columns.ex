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
  alias Macaw.Data.Table.{Bitmap, Chunk, Column, Subset}
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
  # (`Table.sorted/1`), every chunk packed in a form its bounds compare with as it lies (a
  # number buffer and numbers, a time buffer and instants of any kind), is binary-searched
  # to one run; otherwise each chunk is scanned, its packed buffer where the bounds compare
  # with it, its values through `within?/2` where not.
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

  # Whether each bound is open or compares with the buffer as it lies: a number with a
  # number buffer, an instant of any kind with a time buffer, which holds instants on
  # `Order.instant/1`'s scale, the scale `Window.compare/2` compares any two instants on.
  defp bounds_of?(:general, _from, _to), do: false
  defp bounds_of?(kind, from, to), do: bound_of?(kind, from) and bound_of?(kind, to)

  defp bound_of?(_kind, nil), do: true
  defp bound_of?(:number, value), do: is_number(value)
  defp bound_of?(_time, value), do: Window.instant?(value)

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
  # they compare with it as it lies, each closed bound's test a scan, the two intersected (a
  # test over a buffer keeps no missing value); else its values.
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
  # The row indexes in the order, each field read from its column as `Order.sort/3` reads
  # it of a row: `{:ok, indexes}`, or the order's faults. One field sorts its column's keys
  # (macaw_data#140), a time buffer's instants read as they lie and any other column's
  # values keyed by the field's `Order.schema_key/2`, each paired with its index and
  # sorted by `Order.keysorted/3`, the sort `Order.sort_by/2` gives one key. Several
  # fields sort the indexes by `Order.sort_with/4`, each read from its column.
  @spec ordered(Table.t(), Order.t(), Schema.t()) ::
          {:ok, [non_neg_integer()]} | {:error, [{list(), term()}, ...]}
  def ordered(table, [{field, direction}] = order, schema) do
    case Order.faults(order, schema) do
      [] ->
        {present, absent} = keyed(table, field, schema)
        {:ok, Order.keysorted(present, absent, direction)}

      faults ->
        {:error, faults}
    end
  end

  def ordered(table, order, schema) do
    columns =
      Map.new(order, fn {field, _direction} -> {field, List.to_tuple(values(table, field))} end)

    indexes = Enum.to_list(0..(Table.size(table) - 1)//1)

    Order.sort_with(indexes, order, schema, fn i, field -> elem(Map.fetch!(columns, field), i) end)
  end

  # A field's keys paired with their row indexes, `{key, i}`, in reverse order, and the
  # indexes of the rows with no key, in order. A `:time` field's key is its instant
  # (`Order.key/2`), which a time buffer holds as it lies (`Chunk.instants/4`); every row
  # has none when the table has no column the field names.
  defp keyed(table, field, schema) do
    case column(table, field) do
      nil ->
        {[], Enum.to_list(0..(Table.size(table) - 1)//1)}

      name ->
        key =
          if Schema.fetch(schema, field, :type) == {:ok, :time},
            do: nil,
            else: Order.schema_key(schema, field)

        {present, absent, _i} =
          Enum.reduce(Table.chunks(table), {[], [], 0}, fn {chunk, first, count}, acc ->
            chunk |> view_keys(name, first, count, key) |> pair(key, acc)
          end)

        {present, :lists.reverse(absent)}
    end
  end

  defp view_keys(chunk, name, first, count, nil), do: Chunk.instants(chunk, name, first, count)
  defp view_keys(chunk, name, first, count, _key), do: Chunk.values(chunk, name, first, count)

  # Each value's key paired with its index, onto the reversed pairs and the reversed
  # indexes without one; a `nil` key reads the values as keys already (instants).
  defp pair([value | values], nil, {present, absent, i}) do
    case value do
      nil -> pair(values, nil, {present, [i | absent], i + 1})
      k -> pair(values, nil, {[{k, i} | present], absent, i + 1})
    end
  end

  defp pair([value | values], key, {present, absent, i}) do
    case key.(value) do
      nil -> pair(values, key, {present, [i | absent], i + 1})
      k -> pair(values, key, {[{k, i} | present], absent, i + 1})
    end
  end

  defp pair([], _key, acc), do: acc

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
  # Each row's `Window.position/1` by a field, `nil` where it has none. A time buffer (UTC,
  # zoned, naive or date) holds the very position, `Order.instant/1`'s microseconds, read
  # as it lies; any other column is read value by value.
  @spec positions(Table.t(), Table.name() | nil) :: [number() | nil]
  def positions(table, field) do
    case column(table, field) do
      nil ->
        List.duplicate(nil, Table.size(table))

      name ->
        Enum.flat_map(Table.chunks(table), fn {chunk, first, count} ->
          case kind(storage(chunk, name, first, count)) do
            time when time in [DateTime, NaiveDateTime, Date] ->
              Chunk.instants(chunk, name, first, count)

            _other ->
              chunk |> Chunk.values(name, first, count) |> Enum.map(&Window.position/1)
          end
        end)
    end
  end

  # -- :budget ------------------------------------------------------------------------------

  @doc false
  # One series of a table as a budget's reducer reads it (macaw_data#146): a table of the
  # series' rows, `"x"` the window field's column as it is packed (`nil` for the row's
  # place in the series), `"y"` the field's, and `"i"` each row's index in the table, so
  # the reducer's kept rows name the table's rows. Every column but `"i"` is the table's
  # storage, read where it lies: no value is decoded and none packed again. `indexes` are
  # the series' rows of `table`, ascending; the table's columns are ones `series?/3`
  # passes.
  @spec series(Table.t(), Table.name() | nil, Table.name(), [non_neg_integer()]) :: Table.t()
  def series(table, time, field, indexes) do
    x = column(table, time)
    y = column(table, field)
    rows = if length(indexes) == Table.size(table), do: table, else: Subset.at(table, indexes)
    x_type = if x, do: Table.column_type(table, x), else: :number
    header = [{"x", x_type}, {"y", Table.column_type(table, y)}, {"i", :number}]

    {views, {[], _place}} =
      Enum.map_reduce(Table.chunks(rows), {indexes, 0}, fn {chunk, first, count}, {left, place} ->
        {here, left} = Enum.split(left, count)

        columns = %{
          "x" =>
            if(x,
              do: Chunk.storage(chunk, x, first, count),
              else: ints(place..(place + count - 1)//1, count)
            ),
          "y" => Chunk.storage(chunk, y, first, count),
          "i" => ints(here, count)
        }

        {{Chunk.of_storage(header, columns, count), 0, count}, {left, place + count}}
      end)

    sorted = if x != nil and Table.sorted(rows) == x, do: "x"
    {:ok, series} = Table.from_chunks(header, views, sorted: sorted)
    series
  end

  @doc false
  # Whether a budget's reducer reads the table's columns where they lie (`series/4`): a
  # column for every field, and a window field, if any, whose column is a `:time` or a
  # `:number` one, which the reducer places exactly at the rows' positions
  # (`positions/2`: a time's `Order.instant/1` microseconds on its time scale, a number
  # itself). Any other is read by value.
  @spec series?(Table.t(), Table.name() | nil, [Table.name()]) :: boolean()
  def series?(table, time, fields) do
    Enum.all?(fields, &(column(table, &1) != nil)) and
      (time == nil or
         case column(table, time) do
           nil -> false
           x -> Table.column_type(table, x) in [:time, :number]
         end)
  end

  # Integers, `count` of them and none missing, as an int64 column.
  defp ints(values, count),
    do: {:int64, for(v <- values, into: <<>>, do: <<v::signed-little-64>>), Bitmap.ones(count)}

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
