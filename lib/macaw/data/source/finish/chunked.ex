defmodule Macaw.Data.Source.Finish.Chunked do
  @moduledoc false
  # A table's budget reduced chunk by chunk on the ladder (spec/01 §2.4, macaw_data#247):
  # the rows `m4` and `lttb` keep of each series and number field, read off per-chunk
  # partials a caller's `Macaw.Data.Operations.Cache` holds (spec/04 §1.5), so a warm call
  # costs the chunks that changed and the merge, not the rows.
  #
  # The answer is the whole reduction's (`Finish.reduce/5` without a cache). A series'
  # extent and row count decide its level as the step's `bind/3` decides it over the
  # series' own table; a chunk's partial depends on its rows, the scale's kind and the
  # level alone; and partials merge exactly (`Ladder.combine/2`, `runs/1`). So the merged
  # partial is the whole series', and the step's finish (`M4.refs/3`, `Lttb.refs/2`, or
  # their kernels) reads the same rows off it (spec/04 §4.5.1).
  #
  # Per view of the table, under its chunk's id and version, the cache holds the view's
  # series (`{:finish_series, ...}`: each series' rows, the extent of its x and its row
  # count) and each series and field's partial (`{:finish_partial, ...}`), each beside the
  # view's bounds, the partial beside its level. Held at the view's bounds a part is
  # reused; a partial held at a finer level is folded into the coarser one
  # (`Ladder.coarsen/2`), never read from rows again; anything else is computed and
  # replaces what was held, so a cut view the window moves holds one part, not one a frame.

  alias Macaw.Data.{Schema, Table}
  alias Macaw.Data.Operations.Cache
  alias Macaw.Data.Operations.Transforms
  alias Macaw.Data.Operations.Transforms.{Ladder, Lttb, M4}
  alias Macaw.Data.Table.Chunk

  # Past half the largest float an extent's arithmetic could pass a float's range
  # (spec/04 §4.4): the whole reduction answers that fault.
  @half 8.0e307

  @doc false
  # Whether a reducer and a table reduce here: `m4` or `lttb` over a window field's
  # `:time` or `:number` column and a column for every number field.
  @spec applies?(module(), Table.t(), Table.name() | nil, [Table.name()]) :: boolean()
  def applies?(module, table, time, numbers) do
    names = Table.names(table)
    x = time && Transforms.name_in(names, time)

    module in [M4, Lttb] and x != nil and Table.column_type(table, x) in [:time, :number] and
      Enum.all?(numbers, &(Transforms.name_in(names, &1) != nil))
  end

  @doc false
  # The ascending indexes of the rows the reducer keeps at the count `count.(share)` gives
  # (`share` the series times the fields), the count, and the cache:
  # `{:ok, kept, count, cache}`; `{:error, faults}` for a field the reducer cannot place
  # (an `lttb` over an extent its arithmetic doesn't hold, `{[:rows, field], :overflow}`);
  # `:whole` where an extent passes half the largest float, for the whole reduction to
  # answer.
  @spec kept(
          Table.t(),
          Schema.t(),
          [Table.name()],
          module(),
          (pos_integer() -> pos_integer()),
          Cache.t()
        ) ::
          {:ok, [non_neg_integer()], pos_integer(), Cache.t()} | {:error, list()} | :whole
  def kept(table, schema, numbers, module, count, cache) do
    names = Table.names(table)
    x = Transforms.name_in(names, Schema.window_field(schema))
    kind = if Table.column_type(table, x) == :time, do: :time, else: :linear

    categories =
      for {name, %{type: :category}} <- schema.fields,
          do: Transforms.name_in(names, name)

    categories = Enum.sort_by(categories, &to_string/1)
    views = Table.chunks(table)
    tally = %{reused: 0, updated: 0, computed: 0}

    {indexed, {cache, tally}} =
      views
      |> Enum.with_index()
      |> Enum.map_reduce({cache, tally}, fn {view, j}, acc ->
        {index, acc} = series_index(view, categories, x, kind, acc)
        {{j, index}, acc}
      end)

    offsets =
      views |> Enum.map(&elem(&1, 2)) |> Enum.scan(&(&1 + &2)) |> then(&List.to_tuple([0 | &1]))

    series = merged(indexed)
    c = count.(map_size(series) * length(numbers))

    if Enum.all?(series, fn {_key, s} -> holds?(s.extent) end) do
      at = %{views: List.to_tuple(views), offsets: offsets, x: x, kind: kind, names: names}

      fields =
        numbers |> Enum.sort_by(&to_string/1) |> Enum.map(&{&1, Transforms.name_in(names, &1)})

      result =
        for {key, s} <- series, {field, y} <- fields, reduce: {:ok, MapSet.new(), cache, tally} do
          {:ok, kept, cache, tally} ->
            case series_kept(key, s, field, y, module, c, at, {cache, tally}) do
              {:ok, rows, {cache, tally}} -> {:ok, Enum.into(rows, kept), cache, tally}
              {:error, _faults} = error -> error
            end

          {:error, _faults} = error ->
            error
        end

      with {:ok, kept, cache, tally} <- result,
           do: {:ok, kept |> MapSet.to_list() |> Enum.sort(), c, Cache.counted(cache, tally)}
    else
      :whole
    end
  end

  defp holds?(nil), do: true
  defp holds?({lo, hi}), do: abs(lo) < @half and abs(hi) < @half

  # -- each view's series ---------------------------------------------------------------

  # A view's series, held or computed: `%{key => {rows, extent, n}}`, `rows` `:all` or the
  # view's rows of the series ascending, `extent` its x's least and greatest in the scale's
  # space (`nil` for none), `n` its rows.
  defp series_index({chunk, first, count} = view, categories, x, kind, {cache, tally}) do
    key = {:finish_series, categories, x, kind}
    bounds = {first, count}

    case Cache.held(cache, chunk, key) do
      %{bounds: ^bounds, index: index} ->
        {index, {cache, bump(tally, :reused)}}

      _other ->
        index = index_of(view, categories, x, kind)

        {index,
         {Cache.hold(cache, chunk, key, %{bounds: bounds, index: index}), bump(tally, :computed)}}
    end
  end

  defp index_of({chunk, first, count}, categories, x, kind) do
    positions = positions(chunk, x, first, count, kind)

    case categories do
      [] ->
        %{{} => {:all, extent(positions), count}}

      _ ->
        categories
        |> Enum.map(&Chunk.values(chunk, &1, first, count))
        |> Enum.zip_with(&List.to_tuple/1)
        |> Enum.zip(positions)
        |> Enum.with_index()
        |> Enum.group_by(fn {{key, _p}, _i} -> key end, fn {{_key, p}, i} -> {i, p} end)
        |> Map.new(fn {key, rows} ->
          {key,
           {Enum.map(rows, &elem(&1, 0)), rows |> Enum.map(&elem(&1, 1)) |> extent(),
            length(rows)}}
        end)
    end
  end

  # A view's x positions in the scale's space, `nil` for none: a time's instant in
  # microseconds, read from its buffer, on the time scale; a number itself on the linear
  # one, as `Ladder.space/3` places each.
  defp positions(chunk, x, first, count, :time), do: Chunk.instants(chunk, x, first, count)
  defp positions(chunk, x, first, count, :linear), do: Chunk.values(chunk, x, first, count)

  defp extent(positions) do
    Enum.reduce(positions, nil, fn
      nil, e -> e
      p, nil -> {p, p}
      p, {lo, hi} -> {min(lo, p), max(hi, p)}
    end)
  end

  # Every view's series merged, in the table's order: each series' extent, its rows and
  # the views it lies in, `[{view, rows}]` with `rows` `:all` or a tuple.
  defp merged(indexed) do
    indexed
    |> Enum.reduce(%{}, fn {j, index}, acc ->
      Enum.reduce(index, acc, fn {key, {rows, extent, n}}, acc ->
        part = {j, if(rows == :all, do: :all, else: List.to_tuple(rows))}

        Map.update(acc, key, %{extent: extent, n: n, parts: [part]}, fn s ->
          %{s | extent: widen(s.extent, extent), n: s.n + n, parts: [part | s.parts]}
        end)
      end)
    end)
    |> Map.new(fn {key, s} -> {key, %{s | parts: Enum.reverse(s.parts)}} end)
  end

  defp widen(nil, e), do: e
  defp widen(e, nil), do: e
  defp widen({a, b}, {c, d}), do: {min(a, c), max(b, d)}

  # -- each series and field --------------------------------------------------------------

  # The table's indexes of the rows the reducer keeps of one series and field.
  defp series_kept(key, s, field, y, module, c, at, acc) do
    level = level(module, s.extent, c)

    if module == Lttb and s.n <= c do
      {:ok, Enum.flat_map(s.parts, &all_rows(&1, at)), acc}
    else
      bound = %{x: at.x, y: field, x_name: at.x, y_name: y, kind: at.kind}

      {partials, acc} =
        Enum.map_reduce(s.parts, acc, &partial(&1, key, bound, level, module, at, &2))

      merged = Enum.reduce(tl(partials), hd(partials), &Ladder.combine(&2, &1))

      with {:ok, refs} <- refs(module, merged, s.extent, c, level, field) do
        parts = List.to_tuple(s.parts)
        {:ok, Enum.map(refs, fn {v, r} -> index(elem(parts, v), r, at) end), acc}
      end
    end
  end

  # The level the step's `bind/3` picks for the series, with no previous level.
  defp level(M4, {lo, hi}, width) when hi > lo, do: Ladder.level((hi - lo) / width / 4, nil)
  defp level(Lttb, {lo, hi}, n) when hi > lo, do: Ladder.level((hi - lo) / (2 * n), nil)
  defp level(_module, _extent, _count), do: Ladder.level(nil, nil)

  # One view's partial of a series and field at `level`: held at the view's bounds and
  # the level, folded from a finer level held, or computed from the view's rows of the
  # series (the whole view, or its rows gathered into a chunk of their own).
  defp partial({j, rows}, key, bound, level, module, at, {cache, tally}) do
    {chunk, first, count} = view = elem(at.views, j)
    part_key = {:finish_partial, key, bound.x_name, bound.y_name, bound.kind}
    bounds = {first, count}

    case Cache.held(cache, chunk, part_key) do
      %{bounds: ^bounds, level: ^level, partial: partial} ->
        {partial, {cache, bump(tally, :reused)}}

      %{bounds: ^bounds, level: held, partial: partial} = part when held < level ->
        folded = Ladder.coarsen(partial, level)
        cache = Cache.hold(cache, chunk, part_key, %{part | level: level, partial: folded})
        {folded, {cache, bump(tally, :updated)}}

      _other ->
        partial = computed(view, rows, bound, level, module)

        cache =
          Cache.hold(cache, chunk, part_key, %{bounds: bounds, level: level, partial: partial})

        {partial, {cache, bump(tally, :computed)}}
    end
  end

  defp computed(view, :all, bound, level, module),
    do: Ladder.partial(view, bound, level, module.name())

  defp computed({chunk, first, count}, rows, bound, level, module) do
    rows = Tuple.to_list(rows)
    series = Chunk.gather(chunk, first, count, rows, :finish_series)
    Ladder.partial({series, 0, length(rows)}, bound, level, module.name())
  end

  # The rows the step's finish keeps off the merged partial, `{view, row}`: `m4`'s pixel
  # columns over the series' extent, `lttb`'s selection over its candidates.
  defp refs(M4, merged, extent, width, level, _field) do
    merged = Ladder.coarsen(merged, max(elem(merged, 0), level))

    case Ladder.m4_native(merged, extent, width) do
      :fallback -> {:ok, M4.refs(merged, extent, width)}
      refs -> {:ok, refs}
    end
  end

  defp refs(Lttb, merged, extent, n, level, field) do
    merged = Ladder.coarsen(merged, max(elem(merged, 0), level))

    if Ladder.lttb_holds?(merged, extent) do
      case Ladder.lttb_native(merged, n) do
        :fallback -> {:ok, Lttb.refs(merged, n)}
        refs -> {:ok, refs}
      end
    else
      {:error, [{[:rows, field], :overflow}]}
    end
  end

  # A row of a series part, `r` a row of the part's view (`:all`) or of its rows, as the
  # table's index.
  defp index({j, :all}, r, at), do: elem(at.offsets, j) + r
  defp index({j, rows}, r, at), do: elem(at.offsets, j) + elem(rows, r)

  defp all_rows({j, :all}, at) do
    {_chunk, _first, count} = elem(at.views, j)
    start = elem(at.offsets, j)
    Enum.to_list(start..(start + count - 1)//1)
  end

  defp all_rows({j, rows}, at),
    do: rows |> Tuple.to_list() |> Enum.map(&(&1 + elem(at.offsets, j)))

  defp bump(tally, how), do: Map.update!(tally, how, &(&1 + 1))
end
