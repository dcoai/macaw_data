defmodule Macaw.Data.Source.Push.Changes do
  @moduledoc false
  # One increment's changes applied to the rows held (spec/01 §4.2): row retractions,
  # then range retractions, then insertions. Matching never guesses: a retraction that
  # is not held, held only at another window value, or can't tell distinct rows apart is
  # a fault, and so is any change that contradicts a replacement in the same increment.
  # The rows are named rows (maps), read by either spelling of a field's name.

  alias Macaw.Data.{Delivery, Schema, Table, Window}

  @doc false
  # `{rows, inserted, faults, unheld}`: the rows after the increment (the held ones left,
  # then the inserted ones), the rows inserted, the faults in order, and how many
  # retractions named a row a thinned holding lacks. `bound` is the lateness bound in
  # force (spec/01 §4.4), `nil` for none: a change older than it is refused, and a
  # replacement reaching before it refused whole.
  def apply(held, %Delivery{} = increment, %Schema{} = schema, thinned?: thinned?, bound: bound) do
    ctx = %{schema: schema, time: Schema.window_field(schema), thinned?: thinned?, bound: bound}

    {replacements, faults} = timely_ranges(increment.replace, ctx)
    {replacements, faults} = replacements(replacements, ctx, faults)
    {retractions, faults} = timely(increment.retracted, ctx, faults)
    {retractions, faults} = outside(retractions, replacements, ctx, faults)

    {held, faults, unheld} =
      Enum.reduce(retractions, {held, faults, 0}, &retract(&1, &2, ctx))

    held = Enum.reject(held, fn row -> Enum.any?(replacements, &in_scope?(row, &1, ctx)) end)

    {replaced, faults} =
      Enum.reduce(replacements, {[], faults}, fn r, {rows, faults} ->
        {inside, out} = Enum.split_with(r.rows, &in_scope?(&1, r, ctx))
        {rows ++ inside, faults ++ Enum.map(out, &{:outside, &1})}
      end)

    {others, faults} = timely(Delivery.named_rows(increment), ctx, faults)
    {others, faults} = outside(others, replacements, ctx, faults)
    inserted = replaced ++ others
    {held ++ inserted, inserted, faults, unheld}
  end

  # The replacements that apply: a range other than the whole one needs a window field,
  # and one overlapping an earlier replacement of the increment is refused.
  defp replacements(given, ctx, faults) do
    Enum.reduce(given, {[], faults}, fn r, {kept, faults} ->
      cond do
        ctx.time == nil and (r.from != nil or r.to != nil) ->
          {kept, faults ++ [{:replace, :no_window_field}]}

        Enum.any?(kept, &overlap?(&1, r)) ->
          {kept, faults ++ [{:overlap, {r.from, r.to}}]}

        true ->
          {kept ++ [r], faults}
      end
    end)
  end

  # Under a lateness bound, a row whose window value is older is refused, and a range
  # reaching before it refused whole, never clipped.
  defp timely(rows, %{bound: nil}, faults), do: {rows, faults}

  defp timely(rows, %{bound: bound} = ctx, faults) do
    {late, timely} = Enum.split_with(rows, &before?(Table.get(&1, ctx.time), bound))
    {timely, faults ++ Enum.map(late, &{:late, &1, bound})}
  end

  defp timely_ranges(ranges, %{bound: nil}), do: {ranges, []}

  defp timely_ranges(ranges, %{bound: bound}) do
    {late, timely} = Enum.split_with(ranges, &(&1.from == nil or before?(&1.from, bound)))
    {timely, Enum.map(late, &{:late, {&1.from, &1.to}, bound})}
  end

  defp before?(value, bound) do
    case position(value) do
      nil -> false
      t -> t < position(bound)
    end
  end

  # Changes that fall inside a replaced range are conflicts, never applied.
  defp outside(rows, replacements, ctx, faults) do
    {inside, out} =
      Enum.split_with(rows, fn row -> Enum.any?(replacements, &in_scope?(row, &1, ctx)) end)

    {out, faults ++ Enum.map(inside, &{:conflict, &1})}
  end

  defp overlap?(a, b) do
    ids? =
      a.identities == nil or b.identities == nil or a.identities -- b.identities != a.identities

    ids? and below?(a.from, b.to) and below?(b.from, a.to)
  end

  # `from < to`, a `nil` from the start or open-ended.
  defp below?(nil, _to), do: true
  defp below?(_from, nil), do: true
  defp below?(from, to), do: position(from) < position(to)

  defp in_scope?(row, %{identities: ids} = r, ctx),
    do: in_range?(row, r, ctx) and (ids == nil or Schema.identity(ctx.schema, row) in ids)

  defp in_range?(_row, %{from: nil, to: nil}, _ctx), do: true

  defp in_range?(row, %{from: from, to: to}, ctx) do
    case position(Table.get(row, ctx.time)) do
      nil -> false
      t -> (from == nil or t >= position(from)) and (to == nil or t < position(to))
    end
  end

  # One retraction: the held rows it names, which must be one group of identical rows;
  # one copy is withdrawn.
  defp retract(retraction, {held, faults, unheld}, ctx) do
    named = Enum.filter(held, &names?(retraction, &1, ctx))

    case Enum.uniq_by(named, &normal/1) do
      [one] ->
        {List.delete(held, one), faults, unheld}

      [] when ctx.thinned? ->
        {held, faults, unheld + 1}

      [] ->
        {held, faults ++ [{:retract, missing(retraction, held, ctx), retraction}], unheld}

      _several ->
        {held, faults ++ [{:retract, :ambiguous, retraction}], unheld}
    end
  end

  # With identity declared, every field the retraction names equals the row's, the
  # window field compared as instants; without, the whole row.
  defp names?(retraction, row, ctx) do
    case Schema.identity(ctx.schema) do
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
    id = Schema.identity(ctx.schema, retraction)
    time = ctx.time && Table.get(retraction, ctx.time)

    same = if id == nil, do: [], else: Enum.filter(held, &(Schema.identity(ctx.schema, &1) == id))

    if ctx.time != nil and same != [] and
         not Enum.any?(same, &same_time?(Table.get(&1, ctx.time), time)),
       do: :moved,
       else: :not_held
  end

  defp same_time?(a, b), do: a == b or (position(a) != nil and position(a) == position(b))

  defp position(value), do: Window.position(value)

  defp normal(row), do: Map.new(row, fn {k, v} -> {to_string(k), v} end)
end
