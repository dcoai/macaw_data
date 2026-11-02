defmodule Macaw.Data.Derived.Last do
  @moduledoc false
  # `%{last: n}` over a table, on its columns (spec/02 §2.2, macaw_data#47): the rows
  # ordered by the window field's key, each identity's newest `n` kept (else the newest
  # `n`), and the kept rows taken from the chunks that hold them. No row is made: the
  # window field is read as keys (a packed time column's instants from its buffer), the
  # identity fields as values, and the kept rows are views of the input's chunks or
  # gathered from them (`Chunk.gather/5`), every column copied by its slots.
  #
  # It answers what `Macaw.Data.Derived.window/3` answers over the table's rows: the same
  # order (`Derived.order_key/2`'s, stable, the rows left as they came when a key is
  # missing), the same identities (`Schema.identity/2`'s, a row with none dropped), the
  # same rows kept.

  alias Macaw.Data.{Derived, Schema, Table}
  alias Macaw.Data.Table.{Chunk, Subset}
  alias Macaw.Layers.Names

  @doc false
  @spec window(Table.t(), pos_integer(), Schema.t()) :: Table.t()
  def window(table, n, schema) when is_integer(n) and n > 0 do
    table = Subset.ready(table)
    size = Table.size(table)
    views = Table.chunks(table)
    {order, sorted} = order(table, views, schema)

    case {Schema.identity(schema), order} do
      {[], :as_is} ->
        Table.slice(table, max(size - n, 0), n)

      {[], order} ->
        Subset.at(table, Enum.take(order, -n), sorted: sorted)

      {fields, order} ->
        ids = identities(table, views, size, fields)
        Subset.at(table, newest(indexes(order, size), ids, n), sorted: sorted)
    end
  end

  @doc false
  # The rows at `indexes`, ascending, as a table of the input's columns: runs of its
  # chunks as views, any other row gathered by its slots (`Chunk.gather/5`). Nothing is
  # decoded. A `per` source's entity reads its rows so (spec/02 §1.3).
  @spec rows_at(Table.t(), [non_neg_integer()]) :: Table.t()
  def rows_at(table, indexes), do: table |> Subset.ready() |> Subset.at(indexes)

  # The rows' order by the window field: `:as_is` with the column the table is known to be
  # sorted by, or the row indexes sorted stably by their keys, with the window field's
  # column. A table already sorted by its window field is in its keys' order (spec/01
  # §1.1.3: ascending, `nil` last), and so is left as it is: a key missing leaves the rows
  # as they came, and there they already are.
  defp order(table, views, schema) do
    with field when field != nil <- Schema.window_field(schema),
         {:ok, type} <- Derived.order_key(schema, field),
         name when name != nil <- column(table, field),
         false <- Table.sorted(table) == name,
         keys = keys(views, name, type),
         false <- nil in keys do
      sorted =
        keys
        |> Enum.with_index()
        |> then(&:lists.keysort(1, &1))
        |> Enum.map(&elem(&1, 1))

      {sorted, name}
    else
      _as_is -> {:as_is, Table.sorted(table)}
    end
  end

  defp keys(views, name, :time),
    do:
      Enum.flat_map(views, fn {chunk, first, count} ->
        Chunk.instants(chunk, name, first, count)
      end)

  defp keys(views, name, :number) do
    Enum.flat_map(views, fn {chunk, first, count} ->
      for value <- Chunk.values(chunk, name, first, count), do: if(is_number(value), do: value)
    end)
  end

  # The table's column a schema field names, by either spelling, or `nil`.
  defp column(table, field), do: Enum.find(Table.names(table), &Names.same?(&1, field))

  defp indexes(:as_is, size), do: Enum.to_list(0..(size - 1)//1)
  defp indexes(order, _size), do: order

  # Each row's identity, by index: the one field's value, a tuple of several fields'
  # values, `nil` when one is missing (`Schema.identity/2` tells rows apart the same way).
  defp identities(table, views, size, fields) do
    columns =
      for field <- fields do
        case column(table, field) do
          nil ->
            List.duplicate(nil, size)

          name ->
            Enum.flat_map(views, fn {chunk, first, count} ->
              Chunk.values(chunk, name, first, count)
            end)
        end
      end

    case columns do
      [one] -> List.to_tuple(one)
      several -> several |> Enum.zip_with(&composite/1) |> List.to_tuple()
    end
  end

  defp composite(values), do: if(nil in values, do: nil, else: List.to_tuple(values))

  # The indexes, in `order`, of each identity's newest `n` rows: walked from the newest,
  # an identity's count kept, a row with no identity dropped.
  defp newest(order, ids, n) do
    {_counts, kept} =
      order
      |> Enum.reverse()
      |> Enum.reduce({%{}, []}, fn i, {counts, kept} ->
        case elem(ids, i) do
          nil ->
            {counts, kept}

          id ->
            case Map.get(counts, id, 0) do
              c when c < n -> {Map.put(counts, id, c + 1), [i | kept]}
              _full -> {counts, kept}
            end
        end
      end)

    kept
  end
end
