defmodule Macaw.Data.Table.Origin do
  @moduledoc false
  # Where a source's table comes from, and so where its chunks sit (spec/01 §1.1.3): the
  # source, the resolution its relation is held at, its window field and its chunk span.
  # A chunk's logical id is `{source, resolution, slot}`: the start of the span its rows
  # lie in (event time), or the position among the source's rows where its run of
  # `Table.chunk_rows/0` rows starts (row count). Nothing here reads a clock or depends on
  # the data seen before: the same rows have the same slots on every node, every time.

  @keys [:source, :resolution, :window, :span, :offset]
  @naive_epoch ~N[1970-01-01 00:00:00.000000]
  @day_us 86_400_000_000

  @typedoc "An origin, normalized: the offset is the table's, not the origin's."
  @type t :: %{source: term(), resolution: term(), window: term() | nil, span: term() | nil}

  # A given origin checked against a table's checked columns, `{name, type, values}`:
  # `{:ok, origin, offset}`, or its faults by path.
  @doc false
  @spec check(term(), [{term(), atom(), list()}]) ::
          {:ok, t() | nil, non_neg_integer()} | {:error, [{list(), term()}, ...]}
  def check(nil, _columns), do: {:ok, nil, 0}

  def check(%{} = given, columns) when not is_struct(given) do
    types = Map.new(columns, fn {name, type, _values} -> {name, type} end)
    window = Map.get(given, :window)
    span = Map.get(given, :span)
    offset = Map.get(given, :offset, 0)

    faults =
      for(key <- Map.keys(given), key not in @keys, do: {[:origin, key], :unknown_key}) ++
        for(
          key <- [:source, :resolution],
          not Map.has_key?(given, key),
          do: {[:origin, key], :required}
        ) ++
        window_faults(window, types) ++
        span_faults(span, window, types) ++
        if(is_integer(offset) and offset >= 0,
          do: [],
          else: [{[:origin, :offset], {:type, :non_neg_integer}}]
        )

    case faults do
      [] ->
        {:ok, %{source: given.source, resolution: given.resolution, window: window, span: span},
         offset}

      _ ->
        {:error, Enum.sort(faults)}
    end
  end

  def check(_given, _columns), do: {:error, [{[:origin], {:type, :map}}]}

  defp window_faults(nil, _types), do: []

  defp window_faults(window, types) do
    case types do
      %{^window => type} when type in [:time, :number] -> []
      %{^window => type} -> [{[:origin, :window], {:type, type}}]
      _ -> [{[:origin, :window], :unknown}]
    end
  end

  defp span_faults(nil, _window, _types), do: []
  defp span_faults(span, nil, _types), do: span_faults(span, nil)

  defp span_faults(span, window, types) when is_map_key(types, window),
    do: span_faults(span, types[window])

  defp span_faults(_span, _unknown, _types), do: []

  defp span_faults(_span, nil), do: [{[:origin, :span], :no_window_field}]

  defp span_faults(span, :time),
    do: if(span_us(span), do: [], else: [{[:origin, :span], {:type, :duration}}])

  defp span_faults(span, :number),
    do: if(is_number(span) and span > 0, do: [], else: [{[:origin, :span], {:type, :number}}])

  defp span_faults(_span, _other), do: []

  @doc false
  # A span over time in microseconds: a positive `Duration` of fixed length (no years or
  # months); `nil` for anything else.
  @spec span_us(term()) :: pos_integer() | nil
  def span_us(%Duration{year: 0, month: 0} = d) do
    {us, _precision} = d.microsecond

    total =
      (((d.week * 7 + d.day) * 24 + d.hour) * 60 + d.minute) * 60_000_000 + d.second * 1_000_000 +
        us

    if total > 0, do: total
  end

  def span_us(_other), do: nil

  # -- layout -----------------------------------------------------------------------------

  # The table's chunks as `[{count, id}]`, in order, for `size` rows from `offset` among
  # the source's: `id` nil where the chunk's id is its content digest. `:invalid` when a
  # window value is of no kind a window takes (the column's own fault reports it), and
  # `{:error, faults}` when the rows are not in the window field's order.
  @doc false
  @spec layout(
          t() | nil,
          non_neg_integer(),
          [{term(), atom(), list()}],
          non_neg_integer(),
          pos_integer()
        ) ::
          {:ok, [{pos_integer(), term()}]} | :invalid | {:error, [{list(), term()}, ...]}
  def layout(nil, _offset, _columns, size, rows), do: {:ok, counts(size, rows, nil)}

  def layout(%{window: window, span: span} = origin, _offset, columns, _size, _rows)
      when window != nil and span != nil do
    {_, _, values} = List.keyfind(columns, window, 0)
    positions = Enum.map(values, &position/1)

    cond do
      :invalid in positions ->
        :invalid

      i = unsorted(positions, :start, 0) ->
        {:error, [{[:origin, :window], {:unsorted, i}}]}

      true ->
        {:ok,
         values
         |> Enum.map(&slot(&1, span))
         |> Enum.chunk_by(& &1)
         |> Enum.map(fn [slot | _] = run ->
           {length(run), {origin.source, origin.resolution, slot}}
         end)}
    end
  end

  def layout(origin, offset, _columns, size, rows) do
    first = min(size, rows - rem(offset, rows))
    start = offset - rem(offset, rows)

    [first | counts(size - first, rows, nil) |> Enum.map(&elem(&1, 0))]
    |> Enum.reject(&(&1 == 0))
    |> Enum.with_index()
    |> Enum.map(fn {count, k} ->
      slot = if k == 0, do: start, else: start + k * rows
      {count, {origin.source, origin.resolution, slot}}
    end)
    |> then(&{:ok, &1})
  end

  defp counts(size, rows, id) do
    full = for _ <- 1..div(size, rows)//1, do: {rows, id}
    if rem(size, rows) == 0, do: full, else: full ++ [{rem(size, rows), id}]
  end

  @doc false
  # Whether `later` may follow `earlier` in a window field's order, `nil` last.
  @spec ordered?(term(), term()) :: boolean()
  def ordered?(earlier, later), do: not after?(at(earlier), at(later))

  @doc false
  # Whether the origin lays chunks in event time: a window field and a span.
  @spec windowed?(t() | nil) :: boolean()
  def windowed?(%{window: window, span: span}) when window != nil and span != nil, do: true
  def windowed?(_origin), do: false

  @doc false
  # The slot a window value lies in, under an origin in event time.
  @spec slot_of(t(), term()) :: term()
  def slot_of(%{span: span}, value), do: slot(value, span)

  @doc false
  # Whether a slot's span lies wholly before `until`: its end at or before it
  # (spec/01 §1.1.4). The slot `nil`, and no `until`, never.
  @spec settled?(t(), term(), term()) :: boolean()
  def settled?(_origin, nil, _until), do: false
  def settled?(_origin, _slot, nil), do: false

  def settled?(%{span: span}, slot, until) do
    case {at(slot), at(until)} do
      {start, limit} when is_number(start) and is_number(limit) ->
        start + span_size(span) <= limit

      _incomparable ->
        false
    end
  end

  defp span_size(span) when is_number(span), do: span
  defp span_size(span), do: span_us(span)

  @doc false
  # Where a window value lies, for ordering: microseconds from 1970-01-01 for a time, the
  # number itself, `nil` for none, `:invalid` for no kind a window takes.
  @spec position(term()) :: number() | nil | :invalid
  def position(value), do: at(value)

  # The first index whose position comes before the one before it.
  defp unsorted([], _previous, _i), do: nil

  defp unsorted([p | rest], previous, i),
    do: if(after?(previous, p), do: i, else: unsorted(rest, p, i + 1))

  defp after?(:start, _p), do: false
  defp after?(_previous, nil), do: false
  defp after?(nil, _p), do: true
  defp after?(previous, p), do: previous > p

  # Where a window value lies: microseconds from 1970-01-01 for a time (a DateTime's UTC
  # instant, a naive time's wall clock, a date's midnight), the number itself, `nil` for
  # none.
  defp at(nil), do: nil
  defp at(v) when is_number(v), do: v
  defp at(%DateTime{} = t), do: DateTime.to_unix(t, :microsecond)
  defp at(%NaiveDateTime{} = t), do: NaiveDateTime.diff(t, @naive_epoch, :microsecond)
  defp at(%Date{} = d), do: Date.diff(d, ~D[1970-01-01]) * @day_us
  defp at(_other), do: :invalid

  # The start of the span a window value lies in: a UTC DateTime for a DateTime, a
  # NaiveDateTime for a naive time or a date, a number for a number; `nil` for none.
  defp slot(nil, _span), do: nil
  defp slot(v, span) when is_number(v), do: floor_div(v, span) * span

  defp slot(%DateTime{} = t, span),
    do: DateTime.from_unix!(start_us(at(t), span), :microsecond)

  defp slot(t, span),
    do: NaiveDateTime.add(@naive_epoch, start_us(at(t), span), :microsecond)

  defp start_us(us, span) do
    span_us = span_us(span)
    Integer.floor_div(us, span_us) * span_us
  end

  defp floor_div(v, span) when is_integer(v) and is_integer(span), do: Integer.floor_div(v, span)
  defp floor_div(v, span), do: trunc(Float.floor(v / span))
end
