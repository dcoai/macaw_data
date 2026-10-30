defmodule Macaw.Data.Source.Push.Changes do
  @moduledoc false
  # One increment's changes judged before they reach what is held (spec/01 §4.2, §4.4):
  # lateness, overlapping replacements, and changes inside a replaced range, each a fault
  # and not applied. `{change, before, after}`: the changes for `Table.apply/2`
  # (`retract`, `replace` with only the rows inside each, `insert`), and the faults that
  # come before its retraction faults and after them, in §4.2's order. Matching a
  # retraction against what is held is `Table.apply/2`'s.

  alias Macaw.Data.{Delivery, Schema, Table, Window}

  @doc false
  def validate(%Delivery{} = increment, %Schema{} = schema, bound: bound) do
    ctx = %{schema: schema, time: Schema.window_field(schema), bound: bound}

    {replacements, before} = timely_ranges(increment.replace, ctx)
    {replacements, before} = replacements(replacements, ctx, before)
    {retractions, before} = timely(increment.retracted, ctx, before)
    {retractions, before} = outside(retractions, replacements, ctx, before)

    {replacements, after_} =
      Enum.reduce(replacements, {[], []}, fn r, {kept, faults} ->
        {inside, out} = Enum.split_with(r.rows, &in_scope?(&1, r, ctx))
        {kept ++ [%{r | rows: inside}], faults ++ Enum.map(out, &{:outside, &1})}
      end)

    {others, after_} = timely(Delivery.named_rows(increment), ctx, after_)
    {others, after_} = outside(others, replacements, ctx, after_)

    {%{retract: retractions, replace: replacements, insert: others}, before, after_}
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

  defp position(value), do: Window.position(value)
end
