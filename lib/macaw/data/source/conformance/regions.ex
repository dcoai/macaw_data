defmodule Macaw.Data.Source.Conformance.Regions do
  @moduledoc false
  # The supports check's clauses for a box, a region and `latest` (spec/01 §9): a `:box`
  # source's rows within the box, a `:region` source's rows within every range, and a
  # `:latest` source's one row per identity, the last within the rest of the request, and
  # an `:order` source's rows in the order asked, the first of its answer without a budget.
  # `fetch` is the kit's probe, a probe to `{:ok, delivery, rows}` or its findings, so
  # these clauses run as isolated as every other. Ported from visualize's
  # `Visualize.Feed.Conformance.Box`, its box rewritten for the point box.

  alias Macaw.Data.{Schema, Table, Window}
  alias Macaw.Data.Source.{Description, Order, Request}
  alias Macaw.Data.Source.Conformance.Deliveries

  @doc false
  # Of every request with a box, each row's position within it.
  def box(fetch, %Description{supports: supports, schema: schema}, o) do
    asks = for ask <- o.requests, Keyword.get(ask, :box) != nil, valid?(ask, schema, o), do: ask
    time = Schema.window_field(schema)

    cond do
      :box not in supports ->
        []

      asks == [] ->
        [{:no_probe, :box}]

      true ->
        for ask <- asks, budget <- o.budgets do
          case fetch.({ask, budget}) do
            {:ok, _delivery, rows} ->
              box_kept(rows, {ask, budget}, time, Keyword.fetch!(ask, :box))

            _faults ->
              []
          end
        end
        |> List.flatten()
    end
  end

  defp box_kept(rows, probe, time, box) do
    case Enum.find(rows, &Deliveries.outside?(Table.get(&1, time), box)) do
      nil -> []
      row -> [{:box_row, probe, Table.get(row, time)}]
    end
  end

  @doc false
  # Of every request with a region, each row's value of each ranged field within its range.
  def region(fetch, %Description{supports: supports, schema: schema}, o) do
    asks =
      for ask <- o.requests, Keyword.get(ask, :region) != nil, valid?(ask, schema, o), do: ask

    cond do
      :region not in supports ->
        []

      asks == [] ->
        [{:no_probe, :region}]

      true ->
        for ask <- asks, budget <- o.budgets do
          case fetch.({ask, budget}) do
            {:ok, _delivery, rows} ->
              region_kept(rows, {ask, budget}, Keyword.fetch!(ask, :region))

            _faults ->
              []
          end
        end
        |> List.flatten()
    end
  end

  defp region_kept(rows, probe, ranges) do
    for {field, range} <- Enum.sort(ranges),
        row = Enum.find(rows, &(not Window.within?(Table.get(&1, field), range))),
        row != nil,
        do: {:region_row, probe, field, Table.get(row, field)}
  end

  @doc false
  # Of every request asking `latest`, at most one row per identity, and none older than
  # the same request's last row of it without `latest`.
  def latest(fetch, %Description{supports: supports, schema: schema}, o) do
    asks =
      for ask <- o.requests, Keyword.get(ask, :latest, false), valid?(ask, schema, o), do: ask

    cond do
      :latest not in supports ->
        []

      asks == [] ->
        [{:no_probe, :latest}]

      true ->
        for ask <- asks, budget <- o.budgets do
          latest_kept(fetch, {ask, budget}, schema)
        end
        |> List.flatten()
    end
  end

  defp latest_kept(fetch, {ask, _budget} = probe, schema) do
    time = Schema.window_field(schema)

    with {:ok, _delivery, rows} <- fetch.(probe),
         {:ok, _whole, all} <- fetch.({Keyword.put(ask, :latest, false), nil}) do
      by_id = Enum.group_by(rows, &Schema.identity(schema, &1))
      twice = for {id, [_, _ | _]} <- by_id, id != nil, do: {:latest_twice, probe, id}

      last =
        all
        |> Window.latest_rows(&place(&1, time), &Schema.identity(schema, &1))
        |> Map.new(&{Schema.identity(schema, &1), place(&1, time)})

      older =
        for {id, [row]} <- by_id,
            id != nil,
            newest = Map.get(last, id),
            newest != nil and (place(row, time) == nil or place(row, time) < newest),
            do: {:not_latest, probe, id}

      twice ++ older
    else
      _unanswered -> []
    end
  end

  @doc false
  # Of every request with an order, at every budget: the rows served in the order, stated
  # `ordered: :source`, and under a budget the first rows of the answer without one, read
  # by the order's fields (rows the order ties may be any of them).
  def order(fetch, %Description{supports: supports, schema: schema}, o) do
    asks =
      for ask <- o.requests, Keyword.get(ask, :order, []) != [], valid?(ask, schema, o), do: ask

    cond do
      :order not in supports ->
        []

      asks == [] ->
        [{:no_probe, :order}]

      true ->
        for ask <- asks, budget <- o.budgets do
          ordered(fetch, {ask, budget}, schema)
        end
        |> List.flatten()
    end
  end

  defp ordered(fetch, {ask, budget} = probe, schema) do
    order = Keyword.fetch!(ask, :order)

    case fetch.(probe) do
      {:ok, delivery, rows} ->
        stated =
          if delivery.served.ordered == :source,
            do: [],
            else: [{:order_unstated, probe, delivery.served.ordered}]

        sorted = readings(rows, order) == readings(Order.sort(rows, order, schema), order)
        in_order = if sorted, do: [], else: [{:not_ordered, probe}]

        stated ++
          in_order ++ if(sorted, do: first(fetch, probe, rows, budget, {order, schema}), else: [])

      _unanswered ->
        []
    end
  end

  defp first(_fetch, _probe, _rows, nil, _by), do: []

  defp first(fetch, {ask, _asked} = probe, rows, _budget, {order, schema}) do
    case fetch.({ask, nil}) do
      {:ok, _whole, all} ->
        head = all |> Order.sort(order, schema) |> Enum.take(length(rows))
        if readings(rows, order) == readings(head, order), do: [], else: [{:not_first, probe}]

      _unanswered ->
        []
    end
  end

  # Each row's readings of the order's fields: what the order sees of it.
  defp readings(rows, order),
    do: for(row <- rows, do: for({f, _} <- order, do: Table.get(row, f)))

  # A request the schema can answer; one it cannot is the deliveries check's to report.
  defp valid?(ask, schema, o) do
    case Request.new(ask ++ [now: o.now]) do
      {:ok, request} -> Window.check(request, schema) == :ok
      {:error, _faults} -> false
    end
  end

  defp place(row, time) do
    value = Table.get(row, time)
    if Window.time?(value), do: Window.position(value)
  end
end
