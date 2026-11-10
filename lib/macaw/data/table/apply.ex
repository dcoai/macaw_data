defmodule Macaw.Data.Table.Apply do
  @moduledoc false
  # One increment's changes applied to a table's chunks (spec/01 §1.1.4), in §4.2's order:
  # row retractions, then range retractions, then insertions. Each lands where its slot is:
  # in an open chunk's new contents, or in a settled chunk's delta, its base untouched. The
  # changes come already judged (lateness, overlaps, conflicts: `Push.Changes`); matching a
  # retraction against what is held is done here, in the chunk of its slot, and never
  # guesses.

  alias Macaw.Data.{Schema, Table}
  alias Macaw.Data.Table.{Chunk, Column, Delta, Origin}

  @doc false
  # `{chunks, next, faults, unheld}`: the table's whole chunks after the change, the
  # source position after its last row, the faults in order, and the retractions a thinned
  # holding lacks.
  def run(%{header: header, origin: origin, chunks: chunks, next: next}, change) do
    schema = change.schema

    ctx = %{
      header: header,
      types: Map.new(header),
      origin: origin,
      windowed?: Origin.windowed?(origin),
      schema: schema,
      time: (origin && origin.window) || (schema && Schema.window_field(schema)),
      identity: if(schema, do: Schema.identity(schema), else: []),
      settled: change.settled,
      thinned?: change.thinned
    }

    retract = Enum.map(change.retract, &edge(&1, ctx))
    replace = Enum.map(change.replace, &%{&1 | rows: Enum.map(&1.rows, fn r -> edge(r, ctx) end)})
    insert = Enum.flat_map(replace, & &1.rows) ++ Enum.map(change.insert, &edge(&1, ctx))

    case packs(insert, ctx) do
      {:ok, packed} ->
        state = %{chunks: chunks, next: next, faults: [], unheld: 0, touched: MapSet.new()}
        state = Enum.reduce(retract, state, &retract(&1, &2, ctx))
        state = Enum.reduce(replace, state, &range(&1, &2, ctx))
        state = insert(insert, state, Map.put(ctx, :packed, packed))
        chunks = Enum.map(state.chunks, &compacted(&1, state.touched))
        {chunks, state.next, state.faults, state.unheld}

      {:error, faults} ->
        {chunks, next, [{:table, faults}], 0}
    end
  end

  # Rows given as the edge reads them, as `Delivery.table/2` packs: a time column's ISO
  # strings, dates and naive times as `DateTime`s, a category's atom as its string.
  defp edge(%_{} = row, ctx), do: row |> Map.from_struct() |> edge(ctx)

  defp edge(row, ctx) do
    Map.new(row, fn {key, value} ->
      name = column(key, ctx)
      {name || key, if(name, do: Table.at_edge(ctx.types[name], value), else: value)}
    end)
  end

  defp column(key, ctx) do
    Enum.find_value(ctx.header, fn {name, _type} ->
      if key_spelling(name) == key_spelling(key), do: name
    end)
  end

  # A row key as a name's spelling: a key that spells nothing (a row map's keys are its
  # own) is itself, and is no column.
  defp key_spelling(key) when is_atom(key) or is_binary(key) or is_number(key),
    do: to_string(key)

  defp key_spelling(key), do: key

  # The rows to be inserted packed, each column a canonical chunk's run of them at a time
  # as `Table.new/2` packs a table of them, its faults as it answers them; none applies if
  # any (macaw_data#204). `{:ok, columns}`, the columns by name where the rows are one run
  # (`nil` where they are none or several), which an insertion of exactly these rows in
  # this order holds as they are; or `{:error, faults}`.
  defp packs([], _ctx), do: {:ok, nil}

  defp packs(rows, ctx) do
    runs = Enum.chunk_every(rows, Table.chunk_rows())

    {columns, faults} =
      Enum.reduce(ctx.header, {%{}, []}, fn {name, type}, {columns, faults} ->
        {pieces, faults, _at} =
          Enum.reduce(runs, {[], faults, 0}, fn run, {pieces, faults, at} ->
            case Column.piece(type, Enum.map(run, &Map.get(&1, name)), name, at) do
              {:ok, column} -> {[column | pieces], faults, at + length(run)}
              {:error, more} -> {pieces, more ++ faults, at + length(run)}
            end
          end)

        {Map.put(columns, name, pieces), faults}
      end)

    case {faults, runs} do
      {[], [_one]} -> {:ok, Map.new(columns, fn {name, [column]} -> {name, column} end)}
      {[], _several} -> {:ok, nil}
      # Each value's fault is its own path, so the order is Table.new/2's.
      _faults -> {:error, Enum.sort_by(faults, &elem(&1, 0))}
    end
  end

  # -- row retractions (spec/01 §4.2) ---------------------------------------------------------

  defp retract(retraction, state, ctx) do
    candidates =
      if ctx.windowed? do
        slot = Origin.slot_of(ctx.origin, ctx.time && Table.get(retraction, ctx.time))
        for {chunk, k} <- Enum.with_index(state.chunks), slot_of(chunk) == slot, do: {chunk, k}
      else
        Enum.with_index(state.chunks)
      end

    named =
      for {chunk, k} <- candidates,
          {row, ref} <- Chunk.read(chunk),
          names?(retraction, row, ctx),
          do: {row, k, ref}

    case Enum.uniq_by(named, &normal(elem(&1, 0))) do
      [_one] ->
        [{_row, k, ref} | _] = named
        delete(state, k, ref, ctx)

      [] when ctx.thinned? ->
        %{state | unheld: state.unheld + 1}

      [] ->
        held = for chunk <- state.chunks, {row, _ref} <- Chunk.read(chunk), do: row

        %{
          state
          | faults: state.faults ++ [{:retract, missing(retraction, held, ctx), retraction}]
        }

      _several ->
        %{state | faults: state.faults ++ [{:retract, :ambiguous, retraction}]}
    end
  end

  # One held row withdrawn: from a settled chunk's delta, or an open chunk written again.
  defp delete(state, k, ref, ctx) do
    chunk = Enum.at(state.chunks, k)

    if settled?(chunk, ctx) do
      delta = chunk.delta || %Delta{window: ctx.time}

      delta =
        case ref do
          {:base, i} -> %{delta | deleted: MapSet.put(delta.deleted, i)}
          {:side, j} -> %{delta | side: List.delete_at(delta.side, j)}
        end

      put(state, k, Chunk.with_delta(chunk, delta))
    else
      rows = for {row, r} <- Chunk.read(chunk), r != ref, do: row
      rewrite(state, k, chunk, rows, ctx)
    end
  end

  # With identity declared, every field the retraction names equals the row's, the window
  # field compared as instants; without, the whole row.
  defp names?(retraction, row, ctx) do
    case ctx.identity do
      [] ->
        normal(retraction) == normal(row)

      _fields ->
        Enum.all?(retraction, fn {field, value} ->
          held = Table.get(row, field)
          if key_spelling(field) == ctx.time, do: same_time?(held, value), else: held == value
        end)
    end
  end

  # Held only at another window value is a moved row; else it is not held.
  defp missing(retraction, held, ctx) do
    id = ctx.schema && Schema.identity(ctx.schema, retraction)
    time = ctx.time && Table.get(retraction, ctx.time)

    same =
      if id == nil, do: [], else: Enum.filter(held, &(Schema.identity(ctx.schema, &1) == id))

    if ctx.time != nil and same != [] and
         not Enum.any?(same, &same_time?(Table.get(&1, ctx.time), time)),
       do: :moved,
       else: :not_held
  end

  defp same_time?(a, b), do: a == b or (pos(a) != nil and pos(a) == pos(b))

  defp normal(row), do: Map.new(row, fn {k, v} -> {key_spelling(k), v} end)

  # -- range retractions ----------------------------------------------------------------------

  defp range(%{} = r, state, ctx) do
    predicate = %{
      from: r.from,
      to: r.to,
      identities: identities(r.identities),
      schema: ctx.schema
    }

    {chunks, touched} =
      Enum.reduce(state.chunks, {[], state.touched}, fn chunk, {chunks, touched} ->
        cond do
          not reaches?(chunk, r, ctx) ->
            {[chunk | chunks], touched}

          # Replaced outright: its slot holds exactly the replacement's rows, inserted next.
          whole?(chunk, r, ctx) ->
            {chunks, touched}

          settled?(chunk, ctx) ->
            # The predicate reads the base on read; the side chunk, in memory and inserted
            # before it, is filtered now, so a later insertion is never taken by it.
            delta = chunk.delta || %Delta{window: ctx.time}
            side = Enum.reject(delta.side, &Delta.matches?(&1, predicate, ctx.time))
            predicates = delta.predicates ++ [predicate]
            changed = Chunk.with_delta(chunk, %{delta | predicates: predicates, side: side})

            {[changed | chunks], MapSet.put(touched, Chunk.id(chunk))}

          true ->
            rows =
              for {row, _} <- Chunk.read(chunk),
                  not Delta.matches?(row, predicate, ctx.time),
                  do: row

            {rewritten(chunk, rows, ctx) ++ chunks, touched}
        end
      end)

    %{state | chunks: Enum.reverse(chunks), touched: touched}
  end

  defp identities(nil), do: nil
  defp identities(ids), do: Enum.map(ids, &spelled/1)

  defp spelled(v) when is_atom(v) and not is_boolean(v) and v != nil, do: Atom.to_string(v)
  defp spelled(v), do: v

  # Whether a range can reach a chunk's rows: by its slot's span in event time, every
  # chunk otherwise.
  defp reaches?(chunk, %{from: from, to: to}, %{windowed?: true} = ctx) do
    case slot_of(chunk) do
      nil ->
        from == nil and to == nil

      slot ->
        {start, stop} = span(slot, ctx)
        (from == nil or pos(from) < stop) and (to == nil or start < pos(to))
    end
  end

  defp reaches?(_chunk, _range, _ctx), do: true

  # A chunk wholly inside an unrestricted replacement: every identity, its whole span.
  defp whole?(chunk, %{from: from, to: to, identities: nil}, %{windowed?: true} = ctx) do
    case slot_of(chunk) do
      nil ->
        from == nil and to == nil

      slot ->
        {start, stop} = span(slot, ctx)
        (from == nil or pos(from) <= start) and (to == nil or stop <= pos(to))
    end
  end

  defp whole?(_chunk, %{from: nil, to: nil, identities: nil}, _ctx), do: true
  defp whole?(_chunk, _range, _ctx), do: false

  # -- insertions -----------------------------------------------------------------------------

  defp insert([], state, _ctx), do: state

  # Each row's window value is read once (macaw_data#215): its slot key groups the rows,
  # each group's slot term is built once from one of its values, and its position keys the
  # group's sort. The groups and their order are the ones grouping by `Origin.slot_of/2`
  # gives, and each group's rows the ones sorting it by `key/2` gives.
  defp insert(rows, state, %{windowed?: true} = ctx) do
    rows
    |> Enum.map(&keyed(&1, ctx))
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Map.new(fn {_key, [{_sort, row} | _] = group} ->
      {Origin.slot_of(ctx.origin, Table.get(row, ctx.time)), group}
    end)
    |> Enum.sort_by(fn {slot, _group} -> order(slot) end)
    |> Enum.reduce(state, fn {slot, keyed}, state ->
      case Enum.find_index(state.chunks, &(slot_of(&1) == slot)) do
        nil ->
          id = {ctx.origin.source, ctx.origin.resolution, slot}
          {_keyed, group} = sorted(keyed)

          chunk =
            case packed(group, rows, ctx) do
              nil ->
                {:ok, chunk} = Chunk.of_rows(ctx.header, group, id)
                chunk

              columns ->
                Chunk.build(ctx.header, columns, length(group), id)
            end

          at =
            Enum.find_index(state.chunks, &(order(slot_of(&1)) > order(slot))) ||
              length(state.chunks)

          %{state | chunks: List.insert_at(state.chunks, at, chunk)}

        k ->
          chunk = Enum.at(state.chunks, k)

          if settled?(chunk, ctx) do
            # A side chunk holds its rows in the order they came; reading sorts them.
            group = Enum.map(keyed, &elem(&1, 1))
            delta = chunk.delta || %Delta{window: ctx.time}
            put(state, k, Chunk.with_delta(chunk, %{delta | side: delta.side ++ group}))
          else
            {keyed, group} = sorted(keyed)
            written = written(chunk, keyed, group, rows, ctx)
            %{state | chunks: List.replace_at(state.chunks, k, written)}
          end
      end
    end)
  end

  # Aligned by row count: appended to the last chunk, filling its slot before starting new
  # ones. With a window field, the rows stay in its order: a row before the last held is
  # placed in the chunk that spans it, which is written again.
  defp insert(rows, state, %{time: time} = ctx) when time != nil do
    last = last_key(state.chunks, ctx)
    {late, rows} = Enum.split_with(ordered(rows, ctx), &(key(&1, ctx) < last))
    state = Enum.reduce(late, state, &place(&1, &2, ctx))
    append(rows, state, ctx)
  end

  defp insert(rows, state, ctx), do: append(rows, state, ctx)

  # An open chunk with `group` inserted, kept in the window field's order, a held row
  # first among equal values (spec/01 §1.1.4) (macaw_data#204). Only the group is sorted.
  # The held rows up to the first one later than the group's earliest are kept as they
  # lie; only those after it are read, merged with the group and packed, and joined after
  # them (`Chunk.written_from/4`): a group starting at or after the last row is appended,
  # nothing read. A chunk the split can't be found in (a delta, a window column of
  # another form) and any column the join can't keep exact is written again from all its
  # rows. Either way the chunk is the one packing its rows in order gives.
  # `keyed` is the sorted group beside each row's order key, `group` its rows.
  defp written(chunk, [{first, _row} | _] = keyed, group, rows, ctx) do
    with false <- Chunk.delta?(chunk) or Chunk.size(chunk) == 0,
         at when is_integer(at) <- split(chunk, first, ctx),
         {:ok, chunk} <- moved(chunk, at, keyed, group, rows, ctx) do
      chunk
    else
      _rewrite ->
        rows = for({row, _} <- Chunk.read(chunk), do: row) ++ group
        {:ok, chunk} = Chunk.of_rows(ctx.header, ordered(rows, ctx), Chunk.id(chunk))
        chunk
    end
  end

  # The increment's packed columns (`packs/2`) where `group`, sorted, is every row it
  # inserts in the order they came, so they are this group's as packed; else `nil`.
  defp packed(group, rows, %{packed: packed}) when packed != nil and group == rows, do: packed
  defp packed(_group, _rows, _ctx), do: nil

  # A late row into the first chunk whose last row comes after it.
  defp place(row, state, ctx) do
    k = Enum.find_index(state.chunks, &(last_key([&1], ctx) > key(row, ctx)))
    chunk = Enum.at(state.chunks, k)
    rows = for({held, _} <- Chunk.read(chunk), do: held) ++ [row]
    rewrite(state, k, chunk, ordered(rows, ctx), ctx)
  end

  # The order key of the last held row, nothing held before everything.
  defp last_key(chunks, ctx) do
    case chunks do
      [] -> {-1, 0}
      _ -> chunks |> List.last() |> Chunk.read() |> List.last() |> elem(0) |> key(ctx)
    end
  end

  # The held rows from `at` merged with the group, packed and joined after the rest.
  defp moved(chunk, at, keyed, group, rows, ctx) do
    case Chunk.size(chunk) - at do
      0 ->
        Chunk.written_from(chunk, at, group, packed(group, rows, ctx))

      n ->
        tail = for row <- Chunk.rows(chunk, at, n), do: {key(row, ctx), row}
        Chunk.written_from(chunk, at, merged(tail, keyed, []), nil)
    end
  end

  # Two runs in the window field's order, each row beside its order key, merged into rows,
  # the held row first among equals: the order a stable sort of the held rows and then
  # the group gives.
  defp merged([], group, acc), do: :lists.reverse(acc, Enum.map(group, &elem(&1, 1)))
  defp merged(held, [], acc), do: :lists.reverse(acc, Enum.map(held, &elem(&1, 1)))

  defp merged([{hk, h} | held] = hs, [{gk, g} | group] = gs, acc) do
    if hk <= gk,
      do: merged(held, gs, [h | acc]),
      else: merged(hs, group, [g | acc])
  end

  # Where the group goes: the index of the first held row later than its earliest
  # (`first`, an order key), so every row before it stays where it lies; the chunk's size
  # when none is, read from its last row alone. Found by binary search over the window
  # column's packed positions, which are in its order (spec/01 §1.5); `nil` for a column
  # whose form holds no position to search.
  defp split(chunk, first, ctx) do
    size = Chunk.size(chunk)

    cond do
      held_key(chunk, ctx) <= first ->
        size

      probe = probe(Chunk.packed(chunk, ctx.time)) ->
        search(probe, first, 0, size)

      true ->
        nil
    end
  end

  # The first index in [lo, hi) whose key is after `first`, every key before it not.
  defp search(_probe, _first, lo, lo), do: lo

  defp search(probe, first, lo, hi) do
    mid = div(lo + hi, 2)

    if probe.(mid) > first,
      do: search(probe, first, lo, mid),
      else: search(probe, first, mid + 1, hi)
  end

  # The order key of row i, read from the window column's buffer as it lies: a time's
  # instant (`Origin.position/1`'s microseconds), a number itself. A chunk of a slot holds
  # a value in every row, so validity is not read.
  defp probe({form, us, _validity, _precision}) when form in [:utc, :naive], do: int64(us)
  defp probe({:zoned, us, _validity, _precision, _zones, _codes}), do: int64(us)
  defp probe({:int64, data, _validity}), do: int64(data)

  defp probe({:date, days, _validity}) do
    fn i ->
      <<d::signed-little-32>> = binary_part(days, i * 4, 4)
      {0, d * 86_400_000_000}
    end
  end

  defp probe({:float64, data, _validity}) do
    fn i ->
      <<v::float-little-64>> = binary_part(data, i * 8, 8)
      {0, v}
    end
  end

  defp probe(_column), do: nil

  defp int64(data) do
    fn i ->
      <<v::signed-little-64>> = binary_part(data, i * 8, 8)
      {0, v}
    end
  end

  # The order key of a chunk's last row, read from its window column alone.
  defp held_key(chunk, ctx),
    do: value_key(Chunk.at(chunk, ctx.time, Chunk.size(chunk) - 1))

  defp key(row, ctx), do: value_key(Table.get(row, ctx.time))

  # A group's rows beside their order keys, sorted stably by them as `ordered/2` sorts
  # rows, and the rows alone.
  defp sorted(keyed) do
    keyed = List.keysort(keyed, 0)
    {keyed, Enum.map(keyed, &elem(&1, 1))}
  end

  # A row's slot key and, beside the row, its order key (`key/2`), from one reading of its
  # window value.
  defp keyed(row, ctx) do
    {slot, p} = Origin.slot_key(ctx.origin, Table.get(row, ctx.time))
    {slot, {position_key(p), row}}
  end

  defp value_key(value), do: position_key(Origin.position(value))

  defp position_key(p) when is_number(p), do: {0, p}
  defp position_key(_none), do: {1, 0}

  defp append([], state, _ctx), do: state

  defp append(rows, state, ctx) do
    {kept, last} =
      case state.chunks do
        [] -> {[], []}
        chunks -> {Enum.drop(chunks, -1), [List.last(chunks)]}
      end

    held = for chunk <- last, {row, _} <- Chunk.read(chunk), do: row

    {laid, next} =
      case ctx.origin do
        nil ->
          {lay(held ++ rows, [], ctx), state.next}

        origin ->
          start =
            case last do
              [chunk] -> elem(Chunk.id(chunk), 2)
              [] -> state.next
            end

          room = if last == [], do: 0, else: max(start + Table.chunk_rows() - state.next, 0)
          {into, after_} = Enum.split(rows, room)
          head = if last == [], do: [], else: [fill(hd(last), held ++ into, ctx)]

          {head ++ lay(after_, [origin: Map.put(origin, :offset, state.next + length(into))], ctx),
           state.next + length(rows)}
      end

    %{state | chunks: kept ++ laid, next: next}
  end

  defp fill(chunk, rows, ctx) do
    {:ok, chunk} = Chunk.of_rows(ctx.header, rows, Chunk.id(chunk))
    chunk
  end

  defp lay([], _opts, _ctx), do: []

  defp lay(rows, opts, ctx) do
    columns = for {name, type} <- ctx.header, do: {name, type, Enum.map(rows, &Map.get(&1, name))}
    {:ok, table} = Table.new(columns, opts)
    for {chunk, _first, _count} <- Table.chunks(table), do: chunk
  end

  # -- chunks ---------------------------------------------------------------------------------

  defp put(state, k, chunk),
    do: %{
      state
      | chunks: List.replace_at(state.chunks, k, chunk),
        touched: MapSet.put(state.touched, Chunk.id(chunk))
    }

  # An open chunk written again with `rows`: the same id, new contents, a new digest; no
  # chunk when no row is left.
  defp rewrite(state, k, chunk, rows, ctx),
    do: %{
      state
      | chunks: List.replace_at(state.chunks, k, rewritten(chunk, rows, ctx)) |> List.flatten()
    }

  defp rewritten(_chunk, [], _ctx), do: []

  defp rewritten(chunk, rows, ctx) do
    {:ok, chunk} = Chunk.of_rows(ctx.header, rows, Chunk.id(chunk))
    [chunk]
  end

  # A changed settled chunk whose delta has reached a quarter of its base, compacted.
  defp compacted(chunk, touched) do
    if MapSet.member?(touched, Chunk.id(chunk)) and Chunk.due?(chunk),
      do: Chunk.compact(chunk),
      else: chunk
  end

  defp settled?(chunk, %{windowed?: true} = ctx),
    do: Origin.settled?(ctx.origin, slot_of(chunk), ctx.settled)

  defp settled?(_chunk, _ctx), do: false

  defp slot_of(chunk) do
    case Chunk.id(chunk) do
      {_source, _resolution, slot} -> slot
      _other -> :none
    end
  end

  defp span(slot, ctx) do
    start = pos(slot)
    {start, start + span_size(ctx.origin.span)}
  end

  defp span_size(span) when is_number(span), do: span
  defp span_size(span), do: Origin.span_us(span)

  # A slot's place: by its start, the slot `nil` last.
  defp order(nil), do: {1, 0}
  defp order(slot), do: {0, pos(slot)}

  defp ordered(rows, %{time: nil}), do: rows
  defp ordered(rows, ctx), do: Enum.sort_by(rows, &key(&1, ctx))

  defp pos(nil), do: nil

  defp pos(value) do
    case Origin.position(value) do
      :invalid -> nil
      p -> p
    end
  end
end
