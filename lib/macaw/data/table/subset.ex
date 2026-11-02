defmodule Macaw.Data.Table.Subset do
  @moduledoc false
  # Some of a table's rows as a table of its columns, no row made (spec/01 §1.1.1): the
  # rows a columnar step keeps, by index. Rows in the table's order are runs of its
  # chunks, a contiguous run read where it lies as a view and any other gathered by its
  # slots (`Chunk.gather/5`), nothing decoded. Rows in another order are gathered in the
  # table's order, then each column read in theirs: only the kept rows are decoded.
  #
  # `last: n` (`Macaw.Data.Derived.Last`) and finishing (`Macaw.Data.Source.Finish`) keep
  # rows so.

  alias Macaw.Data.Table
  alias Macaw.Data.Table.Chunk

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

    if ascending?(indexes) do
      sorted = Keyword.get(opts, :sorted, Table.sorted(table))
      {:ok, taken} = Table.from_chunks(header, runs(views, indexes), sorted: sorted)
      taken
    else
      in_order = Enum.sort(indexes)
      {:ok, gathered} = Table.from_chunks(header, runs(views, in_order))
      place = in_order |> Enum.with_index() |> Map.new()
      at = Enum.map(indexes, &Map.fetch!(place, &1))

      columns =
        for {name, type} <- header do
          values = gathered |> Table.column(name) |> List.to_tuple()
          {name, type, Enum.map(at, &elem(values, &1))}
        end

      {:ok, taken} = Table.new(columns)
      taken
    end
  end

  defp ascending?([a | [b | _] = rest]), do: a < b and ascending?(rest)
  defp ascending?(_one_or_none), do: true

  # The views of the ascending indexes `kept`, view by view of the table's.
  defp runs(views, kept), do: runs(views, 0, kept, [])

  defp runs(_views, _start, [], acc), do: Enum.reverse(acc)

  defp runs([{chunk, first, count} | views], start, kept, acc) do
    {here, rest} = split_below(kept, start + count, [])
    acc = if here == [], do: acc, else: [run(chunk, first, count, start, here) | acc]
    runs(views, start + count, rest, acc)
  end

  defp split_below([i | rest], limit, acc) when i < limit, do: split_below(rest, limit, [i | acc])
  defp split_below(rest, _limit, acc), do: {:lists.reverse(acc), rest}

  # One view's kept rows: a contiguous run read where it lies, any other gathered.
  defp run(chunk, first, count, start, [i | _] = here) do
    locals = Enum.map(here, &(&1 - start))
    k = length(locals)

    if List.last(here) - i + 1 == k,
      do: {chunk, first + i - start, k},
      else: {Chunk.gather(chunk, first, count, locals, {:subset, locals}), 0, k}
  end
end
