defmodule Macaw.Data.Reduce do
  @moduledoc """
  Shape-preserving downsampling (spec/01 §2.4): the two reducers finishing uses to bring a
  delivery within a budget.

  - `lttb/3`, Largest-Triangle-Three-Buckets, keeps about `n` points chosen to keep a
    series' visual shape;
  - `m4/3` keeps, per pixel column, the first, last, least and greatest points, which a
    line drawn that wide needs to draw the same pixels as all of them.

  Both treat a datum whose `x` or `y` is not a number as a gap, kept in place, so a line
  over the result still breaks where the input broke. Ported from visualize's
  `Visualize.Data.lttb/3` and `m4/3`.

  Both answer `{:ok, elements}` or `{:error, reason}` (spec/00 §5): arithmetic past a
  float's range is `{:values, :overflow}`, never `ArithmeticError` (macaw_data#192). Their
  `!` twins answer the elements or raise `Macaw.Data.Error`.
  """

  alias Macaw.Data.{Checked, Error, Lists}

  # A sum past half the largest float could pass the range in the step after it.
  @half 8.0e307

  @typedoc "Why a reduction is refused (`format_error/1`)."
  @type reason ::
          {:data, :list | :pair}
          | {:n, term()}
          | {:width, term()}
          | {:accessor, term()}
          | {:values, :overflow}

  @doc """
  A refusal's words.

      iex> Macaw.Data.Reduce.format_error({:n, 2})
      "n is an integer of at least 3, not 2"
  """
  @spec format_error(reason()) :: String.t()
  def format_error({:data, :list}), do: "the data is a proper list"
  def format_error({:data, :pair}), do: "the accessor reads every element as an {x, y} pair"
  def format_error({:n, n}), do: "n is an integer of at least 3, not #{inspect(n)}"

  def format_error({:width, width}),
    do: "width is an integer of at least 1, below half the largest float, not #{inspect(width)}"

  def format_error({:accessor, accessor}),
    do: "the accessor is a function of one argument or nil, not #{inspect(accessor)}"

  def format_error({:values, :overflow}),
    do: "the values are past what the reduction's arithmetic holds in a float's range"

  @doc """
  Largest-Triangle-Three-Buckets: about `n` of the elements, chosen to keep the series'
  visual shape (Steinarsson 2013).

  The accessor returns `{x, y}`; without one the elements are `{x, y}` tuples. A datum
  whose `x` or `y` is not a number is a gap: the defined data are reduced run by run
  between the gaps, and each run of gaps keeps its first element in place, so a line over
  the result still breaks where the input broke. Input of `n` or fewer elements is
  returned unchanged; without gaps the result is exactly `n` elements, the first and the
  last among them. `n` must be at least 3.

  A refusal is `{:data, :list}`, `{:data, :pair}`, `{:n, n}`, `{:accessor, accessor}` or
  `{:values, :overflow}`: a bucket's sum, or a triangle over the extents, at half the
  largest float or past it (spec/04 §4.4).

  ## Examples

      iex> Macaw.Data.Reduce.lttb([{0, 0}, {1, 1}, {2, 0}, {3, 5}, {4, 0}, {5, 1}, {6, 0}], 4)
      {:ok, [{0, 0}, {2, 0}, {3, 5}, {6, 0}]}

      iex> Macaw.Data.Reduce.lttb([{0, 0}, {1, 3}, {2, nil}, {3, 4}, {4, 1}], 9)
      {:ok, [{0, 0}, {1, 3}, {2, nil}, {3, 4}, {4, 1}]}

      iex> Macaw.Data.Reduce.lttb([{1.0e308, 1}, {-1.0e308, 2}, {1.0e308, 3}, {-1.0e308, 4}], 3)
      {:error, {:values, :overflow}}

  """
  @spec lttb([any()], pos_integer(), (any() -> {term(), term()}) | nil) ::
          {:ok, [any()]} | {:error, reason()}
  def lttb(data, n, accessor \\ nil) do
    cond do
      not Lists.proper?(data) ->
        {:error, {:data, :list}}

      not (is_integer(n) and n >= 3) ->
        {:error, {:n, n}}

      not (is_nil(accessor) or is_function(accessor, 1)) ->
        {:error, {:accessor, accessor}}

      length(data) <= n ->
        {:ok, data}

      true ->
        with {:ok, read} <- read(data, accessor, []),
             :ok <- lttb_holds(read) do
          {:ok, lttb_read(read, n)}
        end
    end
  end

  @doc "As `lttb/3`, the elements alone, raising `Macaw.Data.Error` in `format_error/1`'s words."
  @spec lttb!([any()], pos_integer(), (any() -> {term(), term()}) | nil) :: [any()]
  def lttb!(data, n, accessor \\ nil) do
    case lttb(data, n, accessor) do
      {:ok, value} -> value
      {:error, reason} -> raise Error, reason: reason, message: format_error(reason)
    end
  end

  @doc false
  # `lttb/3` over `{element, x, y}` candidates a step read off its own partial, whose bound
  # it has already held (`Ladder.lttb_holds?/2`): the one check, so no second pass in a frame.
  @spec candidates_lttb([{term(), number(), number()} | {:gap, term()}], pos_integer()) :: [any()]
  def candidates_lttb(read, n) when length(read) <= n do
    Enum.map(read, fn
      {:gap, element} -> element
      {element, _x, _y} -> element
    end)
  end

  def candidates_lttb(read, n), do: lttb_read(read, n)

  defp lttb_read(read, n) do
    segments = runs(read, [], [])
    defined = Enum.sum(for {:run, len, _points} <- segments, do: len)
    Enum.flat_map(segments, &lttb_segment(&1, n, defined))
  end

  # Below these no bucket's sum and no triangle passes a float's range: at most `count`
  # points a sum, and twice each of a triangle's two products, over the extents.
  defp lttb_holds(read) do
    case extents(read) do
      nil ->
        :ok

      {count, {x_lo, x_hi}, {y_lo, y_hi}} ->
        x_most = max(abs(x_lo), abs(x_hi))
        y_most = max(abs(y_lo), abs(y_hi))
        x_range = Checked.subtract(x_hi, x_lo)
        y_range = Checked.subtract(y_hi, y_lo)

        if below_half?(Checked.multiply(count, x_most)) and
             below_half?(Checked.multiply(count, y_most)) and
             below_half?(Checked.multiply(4, Checked.multiply(x_range, y_range))),
           do: :ok,
           else: {:error, {:values, :overflow}}
    end
  end

  defp below_half?(:overflow), do: false
  defp below_half?(value), do: value < @half

  defp extents(read) do
    Enum.reduce(read, nil, fn
      {:gap, _element}, extents -> extents
      {_element, x, y}, nil -> {1, {x, x}, {y, y}}
      {_element, x, y}, {count, xs, ys} -> {count + 1, widen(xs, x), widen(ys, y)}
    end)
  end

  defp widen({lo, hi}, value), do: {Kernel.min(lo, value), Kernel.max(hi, value)}

  defp lttb_segment({:gap, element}, _n, _defined), do: [element]

  defp lttb_segment({:run, len, points}, n, defined) do
    budget = Kernel.max(Kernel.min(len, 2), floor(n * len / defined))

    cond do
      budget >= len -> for {element, _x, _y} <- Tuple.to_list(points), do: element
      budget == 2 -> [element(points, 0), element(points, len - 1)]
      true -> lttb_run(points, len, budget)
    end
  end

  # The canonical algorithm over one run of `len > n >= 3` points: the two ends kept, the
  # interior split into `n - 2` buckets of `every` points, and from each bucket the point
  # forming the largest triangle with the point kept before it and the mean point of the
  # bucket after it. Every point is read twice — once as a candidate, once in a mean — so
  # the pass is O(len).
  defp lttb_run(points, len, n) do
    every = (len - 2) / (n - 2)
    middle = buckets(points, len, every, 0, n - 2, 0, [])
    [element(points, 0) | middle] ++ [element(points, len - 1)]
  end

  defp buckets(_points, _len, _every, count, count, _a, kept), do: :lists.reverse(kept)

  defp buckets(points, len, every, i, count, a, kept) do
    from = floor(i * every) + 1
    to = floor((i + 1) * every) + 1
    next_to = Kernel.min(floor((i + 2) * every) + 1, len)
    {cx, cy} = mean_point(points, to, next_to)
    {_element, ax, ay} = elem(points, a)
    chosen = largest(points, from, to, ax, ay, cx, cy, from, -1)
    buckets(points, len, every, i + 1, count, chosen, [element(points, chosen) | kept])
  end

  # The mean point of the indices `[from, to)`, never empty: the bucket after the last
  # holds at least the last point.
  defp mean_point(points, from, to), do: sum_point(points, from, to, 0, 0, to - from)

  defp sum_point(_points, to, to, sx, sy, count), do: {sx / count, sy / count}

  defp sum_point(points, j, to, sx, sy, count) do
    {_element, x, y} = elem(points, j)
    sum_point(points, j + 1, to, sx + x, sy + y, count)
  end

  # The index in `[j, to)` whose point makes the largest triangle with `a` and `c`; the
  # earliest on a tie. Twice the area is enough to compare.
  defp largest(_points, to, to, _ax, _ay, _cx, _cy, best, _area), do: best

  defp largest(points, j, to, ax, ay, cx, cy, best, best_area) do
    {_element, x, y} = elem(points, j)
    area = abs((ax - cx) * (y - ay) - (ax - x) * (cy - ay))

    if area > best_area,
      do: largest(points, j + 1, to, ax, ay, cx, cy, j, area),
      else: largest(points, j + 1, to, ax, ay, cx, cy, best, best_area)
  end

  @doc """
  M4: per pixel column, the first, last, least-`y` and greatest-`y` elements — the
  elements a line drawn `width` pixels wide needs to draw the same pixels as all of them
  (Jugel et al. 2014).

  The columns split the extent of the defined `x` readings evenly. The accessor, the gaps
  and the runs are as `lttb/3`'s: each run of gaps keeps its first element in place, and
  each stretch of one run in one column keeps at most four elements, deduplicated and in
  input order. `width` must be at least 1.

  A refusal is `{:data, :list}`, `{:data, :pair}`, `{:width, width}`,
  `{:accessor, accessor}` or `{:values, :overflow}`: an `x` at half the largest float or
  past it, as the `m4` step's (spec/04 §4.5.1).

  ## Examples

      iex> Macaw.Data.Reduce.m4([{0, 1}, {1, 5}, {2, 0}, {3, 2}, {4, 3}, {5, 9}, {6, 4}, {7, 6}], 2)
      {:ok, [{0, 1}, {1, 5}, {2, 0}, {3, 2}, {4, 3}, {5, 9}, {7, 6}]}

      iex> Macaw.Data.Reduce.m4([{0, 1}, {1, 2}, {2, nil}, {3, nil}, {4, 3}], 1)
      {:ok, [{0, 1}, {1, 2}, {2, nil}, {4, 3}]}

      iex> Macaw.Data.Reduce.m4([{1.0e308, 1}, {-1.0e308, 2}], 2)
      {:error, {:values, :overflow}}

  """
  @spec m4([any()], pos_integer(), (any() -> {term(), term()}) | nil) ::
          {:ok, [any()]} | {:error, reason()}
  def m4(data, width, accessor \\ nil) do
    cond do
      not Lists.proper?(data) ->
        {:error, {:data, :list}}

      not (is_integer(width) and width >= 1 and width < @half) ->
        {:error, {:width, width}}

      not (is_nil(accessor) or is_function(accessor, 1)) ->
        {:error, {:accessor, accessor}}

      true ->
        with {:ok, read} <- read(data, accessor, []),
             :ok <- m4_holds(read) do
          {:ok, m4_walk(read, column_of(read, width), nil, [])}
        end
    end
  end

  @doc "As `m4/3`, the elements alone, raising `Macaw.Data.Error` in `format_error/1`'s words."
  @spec m4!([any()], pos_integer(), (any() -> {term(), term()}) | nil) :: [any()]
  def m4!(data, width, accessor \\ nil) do
    case m4(data, width, accessor) do
      {:ok, value} -> value
      {:error, reason} -> raise Error, reason: reason, message: format_error(reason)
    end
  end

  defp m4_holds(read) do
    case extents(read) do
      nil ->
        :ok

      {_count, {x_lo, x_hi}, _ys} ->
        if max(abs(x_lo), abs(x_hi)) < @half, do: :ok, else: {:error, {:values, :overflow}}
    end
  end

  # A defined `x` to its column over the defined extent; every `x` is column 0 when the
  # extent is a point (or there is none).
  defp column_of(read, width) do
    extent =
      Enum.reduce(read, nil, fn
        {:gap, _element}, extent -> extent
        {_element, x, _y}, nil -> {x, x}
        {_element, x, _y}, {lo, hi} -> {Kernel.min(lo, x), Kernel.max(hi, x)}
      end)

    case extent do
      {lo, hi} when hi > lo ->
        fn x -> Kernel.min(width - 1, floor((x - lo) / (hi - lo) * width)) end

      _point_or_none ->
        fn _x -> 0 end
    end
  end

  # One pass: a column visit is `{column, count, first, low, high, last}` with `low` and
  # `high` as `{index, element, y}` within the visit; a gap or a new column flushes it.
  defp m4_walk([], _column, visit, kept), do: :lists.reverse(flush_visit(visit, kept))

  defp m4_walk([{:gap, element} | rest], column, visit, kept),
    do: m4_walk(skip_gaps(rest), column, nil, [element | flush_visit(visit, kept)])

  defp m4_walk([{element, x, y} | rest], column, visit, kept) do
    c = column.(x)

    case visit do
      {^c, i, first, {_, _, ly} = low, {_, _, hy} = high, _last} ->
        low = if y < ly, do: {i, element, y}, else: low
        high = if y > hy, do: {i, element, y}, else: high
        m4_walk(rest, column, {c, i + 1, first, low, high, element}, kept)

      _other_column_or_none ->
        start = {c, 1, element, {0, element, y}, {0, element, y}, element}
        m4_walk(rest, column, start, flush_visit(visit, kept))
    end
  end

  # A visit's first, earliest least, earliest greatest and last elements, deduplicated and
  # in input order, onto the reversed result.
  defp flush_visit(nil, kept), do: kept

  defp flush_visit({_c, count, first, {li, low, _}, {hi, high, _}, last}, kept) do
    [{0, first}, {li, low}, {hi, high}, {count - 1, last}]
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.dedup_by(&elem(&1, 0))
    |> Enum.reduce(kept, fn {_i, element}, kept -> [element | kept] end)
  end

  # The elements read once through the accessor: a defined datum as `{element, x, y}`, a
  # gap as `{:gap, element}` — the sizes differ, so no element is mistaken for the tag.
  defp read(data, nil, read), do: read(data, & &1, read)
  defp read([], _get, read), do: {:ok, :lists.reverse(read)}

  defp read([element | rest], get, read) do
    case get.(element) do
      {x, y} when is_number(x) and is_number(y) -> read(rest, get, [{element, x, y} | read])
      {_x, _y} -> read(rest, get, [{:gap, element} | read])
      _other -> {:error, {:data, :pair}}
    end
  end

  # The read elements as segments in order: `{:run, length, points}` with the points a
  # tuple for the buckets' random access, and `{:gap, element}` for the first of each run
  # of gaps.
  defp runs([], run, segments), do: :lists.reverse(flush_run(run, segments))

  defp runs([{:gap, element} | rest], run, segments),
    do: runs(skip_gaps(rest), [], [{:gap, element} | flush_run(run, segments)])

  defp runs([point | rest], run, segments), do: runs(rest, [point | run], segments)

  defp flush_run([], segments), do: segments

  defp flush_run(run, segments),
    do: [{:run, length(run), run |> :lists.reverse() |> List.to_tuple()} | segments]

  defp skip_gaps([{:gap, _element} | rest]), do: skip_gaps(rest)
  defp skip_gaps(rest), do: rest

  defp element(points, i), do: points |> elem(i) |> elem(0)
end
