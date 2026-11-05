defmodule Macaw.Data.Stack do
  @moduledoc """
  d3-shape's stack (spec/04 §4.8): a baseline for each datum, so layers of data stack on
  one another. The engine of the `stack` transform, ported from visualize's
  `Visualize.Shape.Stack`.

  ## Examples

      data = [
        %{month: "Jan", apples: 10, oranges: 20, bananas: 15},
        %{month: "Feb", apples: 15, oranges: 25, bananas: 10},
        %{month: "Mar", apples: 20, oranges: 15, bananas: 25}
      ]

      stack = Macaw.Data.Stack.new()
        |> Macaw.Data.Stack.keys([:apples, :oranges, :bananas])

      {:ok, series} = Macaw.Data.Stack.generate(stack, data)
      # One series per key, in key order, each with :key, :index (its position
      # in the stacking order) and :points. Points have :data, :y0 (baseline), :y1 (top).

  """

  alias Macaw.Data.Checked

  defstruct keys: [],
            value: nil,
            order: :none,
            offset: :none

  @type t :: %__MODULE__{
          keys: [any()],
          value: (map(), any() -> number()) | nil,
          order: :none | :ascending | :descending | :reverse | :insideout | {:keys, [any()]},
          offset: :none | :expand | :diverging | :silhouette | :wiggle
        }

  @type point :: %{
          key: any(),
          index: non_neg_integer(),
          data: any(),
          value: number(),
          y0: number(),
          y1: number()
        }
  @type series :: %{key: any(), index: non_neg_integer(), points: [point()]}

  @doc """
  Creates a new stack generator. Its value function reads a datum's `key` by name
  (`Macaw.Data.Table.get/2`), `nil` read as `0`, so it reads rows that have names.
  """
  @spec new() :: t()
  def new, do: %__MODULE__{value: &__MODULE__.by_name/2}

  @doc false
  # The default value function: an external capture, so `generate/2` knows it is the one
  # stacking and can refuse rows it cannot read by name.
  def by_name(d, key) do
    case Macaw.Data.Table.get(d, key) do
      nil -> 0
      value -> value
    end
  end

  @doc """
  Sets the keys to stack.

  Keys determine the layers in the stack, typically field names.
  """
  @spec keys(t(), [any()]) :: t()
  def keys(%__MODULE__{} = stack, keys) when is_list(keys) do
    %{stack | keys: keys}
  end

  @doc """
  Sets the value accessor function.

  The function receives (datum, key) and returns a number.
  """
  @spec value(t(), (map(), any() -> number())) :: t()
  def value(%__MODULE__{} = stack, func) when is_function(func, 2) do
    %{stack | value: func}
  end

  @doc """
  Sets the stack order.

  - `:none` - Use key order (default)
  - `:ascending` - Smallest series on bottom
  - `:descending` - Largest series on bottom
  - `:reverse` - Reverse key order
  - `:insideout` - d3's `stackOrderInsideOut`: the earliest-peaking series in the middle,
    later ones outward on whichever side has the smaller sum (good for streamgraphs)
  - `{:keys, list}` - The listed keys bottom first, then the unlisted keys in key order;
    a listed key the stack does not have is ignored (spec/04 §4.8)

  Every order but `{:keys, list}` is computed from the data `generate/2` is given, so over
  a stream of data it can change between frames; `{:keys, list}` is fixed.

      iex> alias Macaw.Data.Stack
      iex> Stack.new()
      ...> |> Stack.keys([:a, :b, :c])
      ...> |> Stack.order({:keys, [:c, :x, :a]})
      ...> |> Stack.generate!([%{a: 1, b: 2, c: 3}])
      ...> |> Enum.map(&{&1.key, &1.index})
      [a: 1, b: 2, c: 0]
  """
  @spec order(t(), atom() | {:keys, [any()]}) :: t()
  def order(%__MODULE__{} = stack, order)
      when order in [:none, :ascending, :descending, :reverse, :insideout] do
    %{stack | order: order}
  end

  def order(%__MODULE__{} = stack, {:keys, keys} = order) when is_list(keys) do
    %{stack | order: order}
  end

  @doc """
  Sets the stack offset.

  - `:none` - Zero baseline (default)
  - `:expand` - Normalize to 0-1 (100% stacked)
  - `:diverging` - Positive values stack up from zero, negative values stack down from zero
  - `:silhouette` - Center the stack around zero
  - `:wiggle` - Minimize weighted wiggle (for streamgraphs)
  """
  @spec offset(t(), atom()) :: t()
  def offset(%__MODULE__{} = stack, offset)
      when offset in [:none, :expand, :diverging, :silhouette, :wiggle] do
    %{stack | offset: offset}
  end

  @doc """
  Generates the stacked series data.

  `{:ok, series}`: one series per key, **in key order**, each a map with:
  - `:key` - The series key
  - `:index` - The series' position in the stacking order (0 is the bottom)
  - `:points` - One point per datum with `:data`, `:value`, `:y0`, `:y1`, `:index`

  The data is any source, read by `Macaw.Data.Table.rows/1`; a source of no shape it
  reads is `Macaw.Data.Table.source/1`'s `{:error, faults}` (macaw_data#161). Rows with
  no names, a tensor's or tuple rows, are `{:error, [{[:names], :required}]}` under the
  default value function, which reads by name: `Macaw.Data.Table.named/2` names them, or
  `value/2` reads them another way.

  A value that is no number is `{[key, j], {:reads, :number}}`, row `j` under `key`, every
  one at once, whichever function read it. The default function reads `nil` as `0`; a
  caller's answering `nil` answers no number (macaw_data#178). A stack of one key under
  the `:none` offset and an order that reads no value (`:none`, `:reverse`, `{:keys, _}`)
  does no arithmetic, so it reads nothing as a number and answers each value as it is.

  A sum past a float's range is `:overflow`: `{[key, j], :overflow}` for a point, or
  `{[:order], :overflow}` for a series' sum an order reads. What a float holds answers as
  the BEAM's arithmetic does; integers alone never overflow.

      iex> alias Macaw.Data.Stack
      iex> Stack.new() |> Stack.keys([:a]) |> Stack.generate([%{a: 1}, 2])
      {:error, [{[], {:type, :rows}}]}
      iex> Stack.new() |> Stack.keys([:a]) |> Stack.generate([{1, 2}])
      {:error, [{[:names], :required}]}
      iex> Stack.new() |> Stack.keys([:a, :b]) |> Stack.generate([%{a: 1, b: "x"}])
      {:error, [{[:b, 0], {:reads, :number}}]}
      iex> Stack.new() |> Stack.keys([:a, :b]) |> Stack.generate([%{a: 1.0e308, b: 1.0e308}])
      {:error, [{[:b, 0], :overflow}]}
  """
  @spec generate(t(), Macaw.Data.Table.source()) ::
          {:ok, [series()]} | {:error, [{list(), term()}, ...]}
  def generate(%__MODULE__{} = stack, data) do
    with {:ok, rows} <- Macaw.Data.Table.rows(data),
         :ok <- readable(stack, data),
         do: stacked(stack, rows)
  end

  defp readable(%__MODULE__{value: value}, data) do
    if value == (&__MODULE__.by_name/2) and Macaw.Data.Table.unnamed?(data),
      do: {:error, [{[:names], :required}]},
      else: :ok
  end

  @doc "As `generate/2`, the series alone, raising `Macaw.Data.Error` with its faults."
  @spec generate!(t(), Macaw.Data.Table.source()) :: [series()]
  def generate!(%__MODULE__{} = stack, data) do
    case generate(stack, data) do
      {:ok, series} ->
        series

      {:error, faults} ->
        raise Macaw.Data.Error, reason: faults, what: "not a source it stacks", root: "source"
    end
  end

  @doc """
  As `generate/2`, over a list of data each given to the value function as it is: no
  source read as rows, so no source's fault. `{:ok, series}`, or the faults of a value that
  is no number and of a sum past a float's range. The `stack` step stacks row places so
  (spec/04 §4.8).

      iex> alias Macaw.Data.Stack
      iex> stack = Stack.new() |> Stack.keys([:a, :b]) |> Stack.value(fn d, _key -> d end)
      iex> Stack.stacked(stack, [:no_number])
      {:error, [{[:a, 0], {:reads, :number}}, {[:b, 0], {:reads, :number}}]}
  """
  @spec stacked(t(), [term()]) :: {:ok, [series()]} | {:error, [{list(), term()}, ...]}
  def stacked(%__MODULE__{keys: []}, data) when is_list(data), do: {:ok, []}
  def stacked(%__MODULE__{}, []), do: {:ok, []}

  def stacked(%__MODULE__{} = stack, data) when is_list(data) do
    series = readings(stack, data)

    case unread(series, stack) do
      [] -> stack(series, stack, length(data))
      faults -> {:error, faults}
    end
  end

  @doc "As `stacked/2`, the series alone, raising `Macaw.Data.Error` with its faults."
  @spec stacked!(t(), [term()]) :: [series()]
  def stacked!(%__MODULE__{} = stack, data) do
    case stacked(stack, data) do
      {:ok, series} -> series
      {:error, faults} -> raise Macaw.Data.Error, reason: faults, what: "not data it stacks"
    end
  end

  @doc """
  `stacked!/2`: the series as a bare list, raising `Macaw.Data.Error` on a value that is no
  number or a sum past a float's range. `stacked/2` answers those as values.
  """
  @spec series(t(), [term()]) :: [series()]
  def series(%__MODULE__{} = stack, data) when is_list(data), do: stacked!(stack, data)

  defp readings(%__MODULE__{keys: keys, value: value_fn}, data) do
    # `series` is a tuple of series in key order; each series is a list of points with
    # `value` and provisional `y0 = 0`, `y1 = value`, as d3 initializes `[0, value]`.
    keys
    |> Enum.map(fn key ->
      points =
        data
        |> Enum.with_index()
        |> Enum.map(fn {d, j} ->
          v = value_fn.(d, key)
          %{key: key, index: j, data: d, value: v, y0: 0, y1: v}
        end)

      %{key: key, index: 0, points: points}
    end)
    |> List.to_tuple()
  end

  # Every value that is no number, where the stack reads its values as numbers: everywhere
  # but one key under the `:none` offset and an order that reads no value, which does no
  # arithmetic and so takes each value as it is.
  defp unread(_series, %__MODULE__{keys: [_key], offset: :none, order: order})
       when order in [:none, :reverse] or (is_tuple(order) and elem(order, 0) == :keys),
       do: []

  defp unread(series, %__MODULE__{}) do
    series |> Tuple.to_list() |> Enum.flat_map(&unread/1)
  end

  defp unread(%{key: key, points: points}) do
    if all_numbers?(points) do
      []
    else
      for %{index: j, value: value} <- points,
          not is_number(value),
          do: {[key, j], {:reads, :number}}
    end
  end

  defp all_numbers?([%{value: value} | rest]) when is_number(value), do: all_numbers?(rest)
  defp all_numbers?([]), do: true
  defp all_numbers?(_points), do: false

  # The stacking order is a permutation of key indexes (d3's `order(series)`).
  defp stack(series, %__MODULE__{keys: keys, order: order, offset: offset}, n) do
    case stacking_order(series, order, keys) do
      :overflow ->
        {:error, [{[:order], :overflow}]}

      order_ix ->
        stacked = series |> apply_offset(order_ix, offset, n) |> Tuple.to_list()

        case overflowed(stacked) do
          [] ->
            {:ok,
             stacked
             |> Enum.with_index()
             |> Enum.map(fn {s, key_index} ->
               %{s | index: Enum.find_index(order_ix, &(&1 == key_index))}
             end)}

          faults ->
            {:error, faults}
        end
    end
  end

  # The first point of each series a sum overflowed at.
  defp overflowed(stacked) do
    Enum.flat_map(stacked, fn %{key: key, points: points} ->
      case first_overflow(points) do
        nil -> []
        j -> [{[key, j], :overflow}]
      end
    end)
  end

  defp first_overflow([%{value: value, y0: y0, y1: y1} = point | _rest])
       when :overflow in [value, y0, y1],
       do: point.index

  defp first_overflow([_point | rest]), do: first_overflow(rest)
  defp first_overflow([]), do: nil

  # --- Order: a permutation of key indexes -------------------------------------------------

  # A fixed order: the listed keys the stack has, at their first mention, then the
  # rest in key order. It reads no value, so it is the same for every frame of a stream.
  defp stacking_order(series, {:keys, listed}, keys) do
    named =
      listed
      |> Enum.map(fn key -> Enum.find_index(keys, &(&1 == key)) end)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    named ++ Enum.reject(stacking_order(series, :none), &(&1 in named))
  end

  defp stacking_order(series, order, _keys), do: stacking_order(series, order)

  # The key indexes by each series' sum, stably; `:overflow` when a sum is past a float.
  defp by_sum(series, sorter) do
    sums = series |> stacking_order(:none) |> Enum.map(&{&1, series_sum(series, &1)})

    if Enum.any?(sums, fn {_i, sum} -> sum == :overflow end),
      do: :overflow,
      else: sums |> Enum.sort_by(&elem(&1, 1), sorter) |> Enum.map(&elem(&1, 0))
  end

  defp stacking_order(series, :none), do: Enum.to_list(0..(tuple_size(series) - 1)//1)
  defp stacking_order(series, :reverse), do: Enum.reverse(stacking_order(series, :none))

  defp stacking_order(series, :ascending), do: by_sum(series, :asc)
  defp stacking_order(series, :descending), do: by_sum(series, :desc)

  # d3's `stackOrderInsideOut` (d3-shape src/order/insideOut.js): in order of
  # appearance, each series joins the top when the top's sum is less than the bottom's,
  # otherwise the bottom; the order is the bottom reversed, then the top.
  defp stacking_order(series, :insideout) do
    {bottoms, tops, bottom, top} =
      series
      |> appearance_order()
      |> Enum.reduce({[], [], 0, 0}, fn i, {bottoms, tops, bottom, top} ->
        sum = series_sum(series, i)

        if top < bottom,
          do: {bottoms, [i | tops], bottom, Checked.add(top, sum)},
          else: {[i | bottoms], tops, Checked.add(bottom, sum), top}
      end)

    # `bottoms` is already reversed, as built; `tops` is not.
    if :overflow in [bottom, top], do: :overflow, else: bottoms ++ Enum.reverse(tops)
  end

  # d3's `stackOrderAppearance` (src/order/appearance.js): key indexes in ascending order
  # of each series' peak, a stable sort, so ties keep key order.
  defp appearance_order(series) do
    series |> stacking_order(:none) |> Enum.sort_by(&series_peak(series, &1))
  end

  # d3's `peak`: the index of the series' first greatest value (it compares with `>`).
  defp series_peak(series, i) do
    series
    |> elem(i)
    |> Map.fetch!(:points)
    |> Enum.max_by(& &1.value, fn -> %{index: 0} end)
    |> Map.fetch!(:index)
  end

  defp series_sum(series, i) do
    series
    |> elem(i)
    |> Map.fetch!(:points)
    |> Enum.reduce(0, fn %{value: v}, acc -> Checked.add(acc, v) end)
  end

  # --- Offsets ------------------------------------------------------------------------------

  # `:none` stacks each series in stacking order on the previous one's top; the bottom
  # series keeps whatever `y0` the offset set (0 unless an offset moved the baseline).
  defp apply_offset(series, order_ix, :none, _n), do: stack_none(series, order_ix)

  # Each column normalized to sum to 1 as it is stacked, so the points are copied once.
  defp apply_offset(series, order_ix, :expand, n) do
    totals = column_totals(series, n)

    stack_values(series, order_ix, fn %{index: j, value: v} ->
      total = elem(totals, j)
      if total == 0, do: 0, else: Checked.divide(v, total)
    end)
  end

  defp apply_offset(series, order_ix, :silhouette, n) do
    totals = column_totals(series, n)

    baselines =
      Enum.map(0..(n - 1)//1, fn j -> Checked.divide(Checked.negate(elem(totals, j)), 2) end)

    series
    |> with_baselines(hd(order_ix), baselines)
    |> stack_none(order_ix)
  end

  # d3's `stackOffsetDiverging`: positives accumulate upward from zero, negatives downward,
  # each independently of the other; a zero value sits at the origin. The points are taken
  # column by column in stacking order, once, and put back by series: linear in the rows
  # (#126; indexing each column of each series was quadratic).
  defp apply_offset(series, order_ix, :diverging, _n) do
    restacked =
      order_ix
      |> Enum.map(&elem(series, &1).points)
      |> Enum.zip_with(&diverge/1)
      |> Enum.zip_with(& &1)

    order_ix
    |> Enum.zip(restacked)
    |> Enum.reduce(series, fn {i, points}, series ->
      put_elem(series, i, %{elem(series, i) | points: points})
    end)
  end

  # d3's `stackOffsetWiggle` (Byron & Wattenberg's streamgraph baseline): the baseline
  # moves between columns so as to minimize the weighted change in slope of the layers.
  defp apply_offset(series, order_ix, :wiggle, n) do
    values =
      order_ix
      |> Enum.map(fn i ->
        series |> elem(i) |> Map.fetch!(:points) |> Enum.map(& &1.value) |> List.to_tuple()
      end)
      |> List.to_tuple()

    m = tuple_size(values)

    {baselines, y} =
      Enum.reduce(1..(n - 1)//1, {[], 0}, fn j, {acc, y} ->
        {s1, s2} =
          Enum.reduce(0..(m - 1)//1, {0, 0}, fn i, {s1, s2} ->
            sij0 = elem(elem(values, i), j)
            sij1 = elem(elem(values, i), j - 1)

            s3 =
              Enum.reduce(0..(i - 1)//1, Checked.divide(difference(sij0, sij1), 2), fn k, s3 ->
                Checked.add(
                  s3,
                  difference(elem(elem(values, k), j), elem(elem(values, k), j - 1))
                )
              end)

            {Checked.add(s1, sij0), Checked.add(s2, Checked.multiply(s3, sij0))}
          end)

        y_next =
          if s1 == 0,
            do: y,
            else: difference(y, Checked.divide(s2, s1))

        {[y | acc], y_next}
      end)

    baselines = Enum.reverse([y | baselines])

    series
    |> with_baselines(hd(order_ix), baselines)
    |> stack_none(order_ix)
  end

  defp difference(a, b), do: Checked.add(a, Checked.negate(b))

  # One column's points, bottom first, stacked up from zero if positive and down if negative.
  defp diverge(column) do
    {points, _yp, _yn} =
      Enum.reduce(column, {[], 0, 0}, fn p, {points, yp, yn} ->
        cond do
          p.value > 0 ->
            y = Checked.add(yp, p.value)
            {[%{p | y0: yp, y1: y} | points], y, yn}

          p.value < 0 ->
            y = Checked.add(yn, p.value)
            {[%{p | y1: yn, y0: y} | points], yp, y}

          true ->
            {[%{p | y0: 0, y1: 0} | points], yp, yn}
        end
      end)

    Enum.reverse(points)
  end

  # Sets the bottom series' y0/y1 to the given per-column baselines.
  defp with_baselines(series, bottom_ix, baselines) do
    s = elem(series, bottom_ix)

    points =
      Enum.zip_with(s.points, baselines, fn p, b ->
        %{p | y0: b, y1: Checked.add(b, p.value)}
      end)

    put_elem(series, bottom_ix, %{s | points: points})
  end

  # d3's `stackOffsetNone`.
  defp stack_none(series, [first | rest]) do
    {series, _} =
      Enum.reduce(rest, {series, first}, fn i, {series, prev_ix} ->
        prev = elem(series, prev_ix)
        s = elem(series, i)

        points =
          Enum.zip_with(s.points, prev.points, fn p, %{y1: base} ->
            %{p | y0: base, y1: Checked.add(base, p.value)}
          end)

        {put_elem(series, i, %{s | points: points}), i}
      end)

    series
  end

  # d3's `stackOffsetNone` over values `value` reads from each point, the bottom series
  # from zero: one pass, one copy of the points.
  defp stack_values(series, [first | rest], value) do
    bottom = elem(series, first)

    points =
      Enum.map(bottom.points, fn p ->
        v = value.(p)
        %{p | value: v, y0: 0, y1: v}
      end)

    {series, _} =
      Enum.reduce(rest, {put_elem(series, first, %{bottom | points: points}), first}, fn i,
                                                                                         {series,
                                                                                          prev_ix} ->
        prev = elem(series, prev_ix)
        s = elem(series, i)

        points =
          Enum.zip_with(s.points, prev.points, fn p, %{y1: base} ->
            v = value.(p)
            %{p | value: v, y0: base, y1: Checked.add(base, v)}
          end)

        {put_elem(series, i, %{s | points: points}), i}
      end)

    series
  end

  # Each column's sum over the series, in one pass over the points (#126).
  defp column_totals(series, _n) do
    series
    |> Tuple.to_list()
    |> Enum.map(fn s -> Enum.map(s.points, & &1.value) end)
    |> Enum.zip_with(fn column -> Enum.reduce(column, 0, &Checked.add(&2, &1)) end)
    |> List.to_tuple()
  end
end
