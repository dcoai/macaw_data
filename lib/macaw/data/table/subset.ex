defmodule Macaw.Data.Table.Subset do
  @moduledoc false
  # Some of a table's rows as a table of its columns, no row made (spec/01 §1.1.1): the
  # rows a columnar step keeps, by index. Rows in the table's order are runs of its
  # chunks, a contiguous run read where it lies as a view and any other gathered by its
  # slots (`Chunk.gather/5`), nothing decoded. Rows in another order from one view are
  # gathered from its chunk in that order, nothing decoded either; across views they are
  # gathered in the table's order, then each column joined across those views and gathered
  # in theirs, nothing decoded where its views share a form a join takes (`Column.concat/1`),
  # only the kept rows of any other column decoded and packed again.
  #
  # `last: n` (`Macaw.Data.Derived.Last`) and finishing (`Macaw.Data.Source.Finish`) keep
  # rows so.

  alias Macaw.Data.Table
  alias Macaw.Data.Table.{Chunk, Column}

  @doc false
  # The table with its cold chunks fetched when one's count is pending (spec/01 §1.1.4),
  # so its views can be walked by count.
  @spec ready(Table.t()) :: Table.t()
  def ready(table), do: if(pending?(table), do: Table.warm(table), else: table)

  defp pending?(table), do: Enum.any?(Table.chunks(table), fn {_c, _f, count} -> count == nil end)

  @doc false
  # The rows at `indexes` (of a ready table), in that order, as a table of its columns. In
  # ascending order the table says they are sorted by `sorted:`, the input's own column
  # (`Table.sorted/1`) by default; in another order it names none.
  @spec at(Table.t(), [non_neg_integer()], keyword()) :: Table.t()
  def at(table, indexes, opts \\ []) do
    header = for name <- Table.names(table), do: {name, Table.column_type(table, name)}
    views = Table.chunks(table)

    cond do
      ascending?(indexes) ->
        sorted = Keyword.get(opts, :sorted, Table.sorted(table))
        {:ok, taken} = Table.from_chunks(header, runs(views, indexes), sorted: sorted)
        taken

      view = one_view(views, indexes) ->
        {:ok, taken} = Table.from_chunks(header, [view])
        taken

      true ->
        repacked(header, views, indexes)
    end
  end

  @doc false
  # The rows a budget's reducer kept, at the ascending `indexes` (of a ready table), as a
  # table of its columns (spec/01 §2.4, macaw_data#247): each view's kept rows one reduced
  # chunk named `{source id, key}` (`Chunk.pick/5`), or the view's run where they are
  # contiguous, so the names hold from one reduction to the next.
  @spec picked(Table.t(), [non_neg_integer()], term()) :: Table.t()
  def picked(table, indexes, key) do
    header = for name <- Table.names(table), do: {name, Table.column_type(table, name)}
    views = runs(Table.chunks(table), 0, indexes, [], {:picked, key})
    {:ok, taken} = Table.from_chunks(header, views, sorted: Table.sorted(table))
    taken
  end

  # Rows in another order, all of one view: gathered from its chunk in their order, every
  # column copied by its slots (`Chunk.gather/5` takes indexes in any order).
  defp one_view(views, indexes) do
    {low, high} = Enum.min_max(indexes)
    one_view(views, 0, low, high, indexes)
  end

  defp one_view([{chunk, first, count} | _views], start, low, high, indexes)
       when low >= start and high < start + count do
    locals = Enum.map(indexes, &(&1 - start))
    {Chunk.gather(chunk, first, count, locals, {:subset, locals}), 0, length(locals)}
  end

  defp one_view([{_chunk, _first, count} | views], start, low, high, indexes)
       when low >= start + count,
       do: one_view(views, start + count, low, high, indexes)

  defp one_view(_views, _start, _low, _high, _indexes), do: nil

  # Rows in another order across views (macaw_data#128): each column joined across views
  # into one storage (`Column.concat/1`) and its slots gathered in their order
  # (`Column.gather/2`), nothing decoded, then cut into chunks of `Table.chunk_rows/0`. When
  # the rows kept are a quarter of the table's or more, the join is of the table's views as
  # they lie and the slots are the indexes themselves; for fewer, the kept rows are first
  # gathered in the table's order (`runs/2`), so a join copies only them. A column whose
  # views hold no one form a join takes is read value by value and packed again, that
  # column alone.
  defp repacked(header, views, indexes) do
    size = Enum.sum(for {_chunk, _first, count} <- views, do: count)
    kept = length(indexes)

    {views, slots} =
      if 4 * kept >= size do
        {views, indexes}
      else
        in_order = Enum.sort(indexes)
        place = in_order |> Enum.with_index() |> Map.new()
        {runs(views, in_order), Enum.map(indexes, &Map.fetch!(place, &1))}
      end

    columns = Map.new(header, fn {name, type} -> {name, gathered(views, name, type, slots)} end)

    chunks =
      for first <- 0..(kept - 1)//Table.chunk_rows() do
        n = min(Table.chunk_rows(), kept - first)
        packed = Map.new(columns, fn {name, column} -> {name, Column.slice(column, first, n)} end)
        Chunk.build(header, packed, n)
      end

    {:ok, taken} = Table.from_chunks(header, chunks)
    taken
  end

  # A column's values at the slots of the views' rows, as one storage: the views' storages
  # joined and gathered, or, where their forms don't join, their values read and packed.
  defp gathered(views, name, type, slots) do
    pieces =
      for {chunk, first, count} <- views, do: {Chunk.storage(chunk, name, first, count), count}

    case Column.concat(pieces) do
      {:ok, column} ->
        Column.gather(column, slots)

      :general ->
        values =
          views
          |> Enum.flat_map(fn {chunk, first, count} ->
            Chunk.values(chunk, name, first, count)
          end)
          |> List.to_tuple()

        {:ok, column} = Column.piece(type, Enum.map(slots, &elem(values, &1)), name, 0)
        column
    end
  end

  defp ascending?([a | [b | _] = rest]), do: a < b and ascending?(rest)
  defp ascending?(_one_or_none), do: true

  # The views of the ascending indexes `kept`, view by view of the table's.
  defp runs(views, kept), do: runs(views, 0, kept, [], :subset)

  defp runs(_views, _start, [], acc, _name), do: Enum.reverse(acc)

  defp runs([{chunk, first, count} | views], start, kept, acc, name) do
    {here, rest} = split_below(kept, start + count, [])
    acc = if here == [], do: acc, else: [run(chunk, first, count, start, here, name) | acc]
    runs(views, start + count, rest, acc, name)
  end

  defp split_below([i | rest], limit, acc) when i < limit, do: split_below(rest, limit, [i | acc])
  defp split_below(rest, _limit, acc), do: {:lists.reverse(acc), rest}

  # One view's kept rows: a contiguous run read where it lies, any other gathered. The rows
  # are in order, so they are a run when they span as many places as they hold and none
  # repeats: [10, 10, 12, 13] spans four and holds four (macaw_data#205).
  defp run(chunk, first, count, start, [i | _] = here, name) do
    locals = Enum.map(here, &(&1 - start))
    k = length(locals)

    cond do
      List.last(here) - i + 1 == k and ascending?(here) -> {chunk, first + i - start, k}
      name == :subset -> {Chunk.gather(chunk, first, count, locals, {:subset, locals}), 0, k}
      {:picked, key} = name -> {Chunk.pick(chunk, first, count, locals, key), 0, k}
    end
  end
end
