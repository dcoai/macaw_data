defmodule Macaw.Data.Table.Apply do
  @moduledoc false
  # One increment's changes applied to a table's chunks (spec/01 §1.1.4), in §4.2's order:
  # row retractions, then range retractions, then insertions. Each lands where its slot is:
  # in an open chunk's new contents, or in a settled chunk's delta, its base untouched. The
  # changes come already judged (lateness, overlaps, conflicts: `Push.Changes`); matching a
  # retraction against what is held is done here, in the chunk of its slot, and never
  # guesses.

  alias Macaw.Data.{Schema, Table}
  alias Macaw.Data.Table.{Chunk, Delta, Origin}

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
      [] ->
        state = %{chunks: chunks, next: next, faults: [], unheld: 0, touched: MapSet.new()}
        state = Enum.reduce(retract, state, &retract(&1, &2, ctx))
        state = Enum.reduce(replace, state, &range(&1, &2, ctx))
        state = insert(insert, state, ctx)
        chunks = Enum.map(state.chunks, &compacted(&1, state.touched))
        {chunks, state.next, state.faults, state.unheld}

      faults ->
        {chunks, next, [{:table, faults}], 0}
    end
  end

  # Rows given as the edge reads them, as `Delivery.table/2` packs: a time column's ISO
  # strings, dates and naive times as `DateTime`s, a category's atom as its string.
  defp edge(row, ctx) do
    Map.new(row, fn {key, value} ->
      name = column(key, ctx)
      {name || key, if(name, do: Table.at_edge(ctx.types[name], value), else: value)}
    end)
  end

  defp column(key, ctx) do
    Enum.find_value(ctx.header, fn {name, _type} ->
      if to_string(name) == to_string(key), do: name
    end)
  end

  # The faults of packing the rows to be inserted; none applies if any.
  defp packs([], _ctx), do: []

  defp packs(rows, ctx) do
    columns = for {name, type} <- ctx.header, do: {name, type, Enum.map(rows, &Map.get(&1, name))}

    case Table.new(columns) do
      {:ok, _table} -> []
      {:error, faults} -> faults
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
          if to_string(field) == ctx.time, do: same_time?(held, value), else: held == value
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

  defp normal(row), do: Map.new(row, fn {k, v} -> {to_string(k), v} end)

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

  defp insert(rows, state, %{windowed?: true} = ctx) do
    rows
    |> Enum.group_by(&Origin.slot_of(ctx.origin, Table.get(&1, ctx.time)))
    |> Enum.sort_by(fn {slot, _rows} -> order(slot) end)
    |> Enum.reduce(state, fn {slot, group}, state ->
      case Enum.find_index(state.chunks, &(slot_of(&1) == slot)) do
        nil ->
          id = {ctx.origin.source, ctx.origin.resolution, slot}
          {:ok, chunk} = Chunk.of_rows(ctx.header, ordered(group, ctx), id)

          at =
            Enum.find_index(state.chunks, &(order(slot_of(&1)) > order(slot))) ||
              length(state.chunks)

          %{state | chunks: List.insert_at(state.chunks, at, chunk)}

        k ->
          chunk = Enum.at(state.chunks, k)

          if settled?(chunk, ctx) do
            delta = chunk.delta || %Delta{window: ctx.time}
            put(state, k, Chunk.with_delta(chunk, %{delta | side: delta.side ++ group}))
          else
            rows = for({row, _} <- Chunk.read(chunk), do: row) ++ group
            rewrite(state, k, chunk, ordered(rows, ctx), ctx)
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

  defp key(row, ctx) do
    case pos(Table.get(row, ctx.time)) do
      p when is_number(p) -> {0, p}
      _none -> {1, 0}
    end
  end

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
