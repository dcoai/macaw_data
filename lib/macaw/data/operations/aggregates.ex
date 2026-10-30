defmodule Macaw.Data.Operations.Aggregates do
  @moduledoc """
  The statistics of `macaw_data`'s package (spec/04 §5), each an aggregate
  (`Macaw.Data.Aggregate`) ported from visualize's `Visualize.Data`:

  | Name | Value | Of no readings | Output type | Unit |
  |---|---|---|---|---|
  | `count` | the number of readings | `0` | `:number` | dropped |
  | `distinct` | the number of distinct readings (`===`, a category by spelling) | `0` | `:number` | dropped |
  | `min`, `max` | the least, the greatest reading, numbers or times | `nil` | the input's | kept |
  | `extent` | `[min, max]` | `nil` | `:term` | kept |
  | `sum` | the sum of numbers | `0` | `:number` | kept |
  | `mean` | the arithmetic mean | `nil` | `:number` | kept |
  | `median` | the middle reading, or the mean of the two middles | `nil` | `:number` | kept |
  | `quantile` | linear interpolation at `(n − 1) · p` | `nil` | `:number` | kept |
  | `variance` | the sample variance | `nil`, and of one | `:number` | dropped |
  | `deviation` | its square root | `nil`, and of one | `:number` | kept |
  | `slope` | the least-squares slope; a number is the point `[i, v]` | `nil`, of one, or every `x` equal | `:number` | dropped |
  | `delta` | the last reading minus the first | `nil` (`0` of one) | `:number` | kept |

  The readings come with every `nil` dropped. A reading of the wrong kind raises
  `ArgumentError` naming the aggregate and the reading. Every statistic but `median` and
  `quantile` has the streaming form, and its `reduce/2` **is** that form folded over the
  readings, so the two are equal by construction: the mean is a running sum over a count,
  the variance and the slope Welford's one-pass updates, which agree with visualize's
  two-pass values to within floating-point rounding.
  """

  alias Macaw.Data.Window

  @doc "The modules of the thirteen statistics, in spec/04 §5's order."
  @spec all() :: [module()]
  def all do
    [
      __MODULE__.Count,
      __MODULE__.Distinct,
      __MODULE__.Min,
      __MODULE__.Max,
      __MODULE__.Extent,
      __MODULE__.Sum,
      __MODULE__.Mean,
      __MODULE__.Median,
      __MODULE__.Quantile,
      __MODULE__.Variance,
      __MODULE__.Deviation,
      __MODULE__.Slope,
      __MODULE__.Delta
    ]
  end

  @doc false
  # Every reading a number, else ArgumentError naming the aggregate and the first other.
  @spec numbers!(String.t(), [term()]) :: [number()]
  def numbers!(name, values) do
    case Enum.find(values, &(not is_number(&1))) do
      nil -> values
      other -> wrong!(name, other, "a number")
    end
  end

  @doc false
  @spec number!(String.t(), term()) :: number()
  def number!(_name, value) when is_number(value), do: value
  def number!(name, value), do: wrong!(name, value, "a number")

  @doc false
  # A reading min and max can order: a number, or an instant of the first reading's kind.
  @spec comparable!(String.t(), term(), term()) :: term()
  def comparable!(_name, value, nil) when is_number(value), do: value

  def comparable!(name, value, nil) do
    if Window.instant?(value), do: value, else: wrong!(name, value, "a number or a time")
  end

  def comparable!(_name, value, first) when is_number(value) and is_number(first), do: value

  def comparable!(_name, %kind{} = value, %kind{}) when kind in [DateTime, NaiveDateTime, Date],
    do: value

  def comparable!(name, value, _first), do: wrong!(name, value, "of the first reading's kind")

  @doc false
  @spec wrong!(String.t(), term(), String.t()) :: no_return()
  def wrong!(name, value, kind) do
    raise ArgumentError,
          "aggregate #{inspect(name)}: #{inspect(value)} is not #{kind} (spec/04 §5)"
  end

  @doc false
  # The canonical form distinct compares by: an atom naming a category is its string.
  @spec spelled(term()) :: term()
  def spelled(value) when is_atom(value) and value not in [nil, true, false],
    do: Atom.to_string(value)

  def spelled(value), do: value

  @doc false
  # A streaming aggregate's reduce: its own form folded over the readings.
  @spec fold(module(), [term()], map()) :: term()
  def fold(module, values, options),
    do:
      module.finish(
        Enum.reduce(values, module.init(options), &module.step(&2, &1, options)),
        options
      )

  @doc false
  # The sorted readings median and quantile interpolate between, as a tuple.
  @spec sorted(String.t(), [term()]) :: tuple()
  def sorted(name, values), do: name |> numbers!(values) |> Enum.sort() |> List.to_tuple()

  # -- the statistics ---------------------------------------------------------------------

  defmodule Count do
    @moduledoc "`count`: the number of readings (spec/04 §5)."
    @behaviour Macaw.Data.Aggregate
    alias Macaw.Data.Operations.Aggregates

    @impl true
    def name, do: "count"
    @impl true
    def options, do: []
    @impl true
    def output(_type, _options), do: :number
    @impl true
    def keeps_unit?, do: false
    @impl true
    def reduce(values, options), do: Aggregates.fold(__MODULE__, values, options)
    @impl true
    def init(_options), do: 0
    @impl true
    def step(n, _value, _options), do: n + 1
    @impl true
    def finish(n, _options), do: n
    @impl true
    def merge(a, b, _options), do: a + b
  end

  defmodule Distinct do
    @moduledoc "`distinct`: the number of distinct readings, a category by spelling (spec/04 §5)."
    @behaviour Macaw.Data.Aggregate
    alias Macaw.Data.Operations.Aggregates

    @impl true
    def name, do: "distinct"
    @impl true
    def options, do: []
    @impl true
    def output(_type, _options), do: :number
    @impl true
    def keeps_unit?, do: false
    @impl true
    def reduce(values, options), do: Aggregates.fold(__MODULE__, values, options)
    @impl true
    def init(_options), do: MapSet.new()
    @impl true
    def step(seen, value, _options), do: MapSet.put(seen, Aggregates.spelled(value))
    @impl true
    def finish(seen, _options), do: MapSet.size(seen)
  end

  defmodule Min do
    @moduledoc "`min`: the least reading, numbers or times (spec/04 §5)."
    @behaviour Macaw.Data.Aggregate
    alias Macaw.Data.Operations.Aggregates
    alias Macaw.Data.Window

    @impl true
    def name, do: "min"
    @impl true
    def options, do: []
    @impl true
    def output(type, _options), do: type
    @impl true
    def keeps_unit?, do: true
    @impl true
    def reduce(values, options), do: Aggregates.fold(__MODULE__, values, options)
    @impl true
    def init(_options), do: nil
    @impl true
    def step(least, value, _options) do
      value = Aggregates.comparable!(name(), value, least)
      if least == nil or Window.compare(value, least) == :lt, do: value, else: least
    end

    @impl true
    def finish(least, _options), do: least

    # The earlier run's least on a tie, as the stream keeps the first.
    @impl true
    def merge(least, nil, _options), do: least
    def merge(nil, other, _options), do: other
    def merge(least, other, options), do: step(least, other, options)
  end

  defmodule Max do
    @moduledoc "`max`: the greatest reading, numbers or times (spec/04 §5)."
    @behaviour Macaw.Data.Aggregate
    alias Macaw.Data.Operations.Aggregates
    alias Macaw.Data.Window

    @impl true
    def name, do: "max"
    @impl true
    def options, do: []
    @impl true
    def output(type, _options), do: type
    @impl true
    def keeps_unit?, do: true
    @impl true
    def reduce(values, options), do: Aggregates.fold(__MODULE__, values, options)
    @impl true
    def init(_options), do: nil
    @impl true
    def step(greatest, value, _options) do
      value = Aggregates.comparable!(name(), value, greatest)
      if greatest == nil or Window.compare(value, greatest) == :gt, do: value, else: greatest
    end

    @impl true
    def finish(greatest, _options), do: greatest

    # The earlier run's greatest on a tie, as the stream keeps the first.
    @impl true
    def merge(greatest, nil, _options), do: greatest
    def merge(nil, other, _options), do: other
    def merge(greatest, other, options), do: step(greatest, other, options)
  end

  defmodule Extent do
    @moduledoc "`extent`: `[min, max]` of the readings (spec/04 §5)."
    @behaviour Macaw.Data.Aggregate
    alias Macaw.Data.Operations.Aggregates
    alias Macaw.Data.Window

    @impl true
    def name, do: "extent"
    @impl true
    def options, do: []
    @impl true
    def output(_type, _options), do: :term
    @impl true
    def keeps_unit?, do: true
    @impl true
    def reduce(values, options), do: Aggregates.fold(__MODULE__, values, options)
    @impl true
    def init(_options), do: nil
    @impl true
    def step(nil, value, _options) do
      value = Aggregates.comparable!(name(), value, nil)
      [value, value]
    end

    def step([low, high], value, _options) do
      value = Aggregates.comparable!(name(), value, low)

      [
        if(Window.compare(value, low) == :lt, do: value, else: low),
        if(Window.compare(value, high) == :gt, do: value, else: high)
      ]
    end

    @impl true
    def finish(extent, _options), do: extent

    @impl true
    def merge(extent, nil, _options), do: extent
    def merge(nil, other, _options), do: other

    def merge(extent, [low, high], options),
      do: extent |> step(low, options) |> step(high, options)
  end

  defmodule Sum do
    @moduledoc """
    `sum`: the sum of numbers, `0` of none (spec/04 §5): exact, so any order and any
    grouping of the readings give the same value. Integers add as integers; with a float
    among them, the exact sum is rounded once to the nearest float.
    """
    @behaviour Macaw.Data.Aggregate
    alias Macaw.Data.Exact
    alias Macaw.Data.Operations.Aggregates

    @impl true
    def name, do: "sum"
    @impl true
    def options, do: []
    @impl true
    def output(_type, _options), do: :number
    @impl true
    def keeps_unit?, do: true
    @impl true
    def reduce(values, options), do: Aggregates.fold(__MODULE__, values, options)
    @impl true
    def init(_options), do: Exact.zero()
    @impl true
    def step(sum, value, _options), do: Exact.add(sum, Aggregates.number!(name(), value))
    @impl true
    def finish(sum, _options), do: Exact.value(sum)
    @impl true
    def merge(a, b, _options), do: Exact.merge(a, b)
  end

  defmodule Mean do
    @moduledoc "`mean`: the arithmetic mean, a float, the exact sum over the count (spec/04 §5)."
    @behaviour Macaw.Data.Aggregate
    alias Macaw.Data.Exact
    alias Macaw.Data.Operations.Aggregates

    @impl true
    def name, do: "mean"
    @impl true
    def options, do: []
    @impl true
    def output(_type, _options), do: :number
    @impl true
    def keeps_unit?, do: true
    @impl true
    def reduce(values, options), do: Aggregates.fold(__MODULE__, values, options)
    @impl true
    def init(_options), do: {Exact.zero(), 0}
    @impl true
    def step({sum, n}, value, _options),
      do: {Exact.add(sum, Aggregates.number!(name(), value)), n + 1}

    @impl true
    def finish({_sum, 0}, _options), do: nil
    def finish({sum, n}, _options), do: Exact.value(sum) / n
    @impl true
    def merge({a, m}, {b, n}, _options), do: {Exact.merge(a, b), m + n}
  end

  defmodule Median do
    @moduledoc "`median`: the middle reading, or the mean of the two middles (spec/04 §5)."
    @behaviour Macaw.Data.Aggregate
    alias Macaw.Data.Operations.Aggregates

    @impl true
    def name, do: "median"
    @impl true
    def options, do: []
    @impl true
    def output(_type, _options), do: :number
    @impl true
    def keeps_unit?, do: true

    @impl true
    def reduce([], _options), do: nil

    def reduce(values, _options) do
      sorted = Aggregates.sorted(name(), values)
      n = tuple_size(sorted)
      mid = div(n, 2)

      if rem(n, 2) == 0,
        do: (elem(sorted, mid - 1) + elem(sorted, mid)) / 2,
        else: elem(sorted, mid)
    end
  end

  defmodule Quantile do
    @moduledoc """
    `quantile`: the `p`-quantile by linear interpolation between the sorted readings, at
    `i = (n − 1) · p`, the last index clamped (spec/04 §5).
    """
    @behaviour Macaw.Data.Aggregate
    alias Macaw.Data.Operations.Aggregates
    alias Macaw.Data.Operations.Option

    @impl true
    def name, do: "quantile"

    @impl true
    def options,
      do: [{"p", %Option{type: {:number, 0, 1}, required: true, doc: "the quantile, 0 to 1"}}]

    @impl true
    def output(_type, _options), do: :number
    @impl true
    def keeps_unit?, do: true

    @impl true
    def reduce([], _options), do: nil

    def reduce(values, %{"p" => p}) do
      sorted = Aggregates.sorted(name(), values)
      n = tuple_size(sorted)
      i = (n - 1) * p
      i0 = trunc(i)
      v0 = elem(sorted, i0)
      v1 = elem(sorted, min(i0 + 1, n - 1))
      v0 + (v1 - v0) * (i - i0)
    end
  end

  defmodule Variance do
    @moduledoc "`variance`: the sample variance, `Σ(v − mean)² / (n − 1)` (spec/04 §5)."
    @behaviour Macaw.Data.Aggregate
    alias Macaw.Data.Operations.Aggregates

    @impl true
    def name, do: "variance"
    @impl true
    def options, do: []
    @impl true
    def output(_type, _options), do: :number
    @impl true
    def keeps_unit?, do: false
    @impl true
    def reduce(values, options), do: Aggregates.fold(__MODULE__, values, options)

    # Welford's update: the count, the running mean and the sum of squared deviations.
    @impl true
    def init(_options), do: {0, 0.0, 0.0}

    @impl true
    def step({n, mean, m2}, value, _options) do
      value = Aggregates.number!(name(), value)
      n = n + 1
      delta = value - mean
      mean = mean + delta / n
      {n, mean, m2 + delta * (value - mean)}
    end

    @impl true
    def finish({n, _mean, _m2}, _options) when n < 2, do: nil
    def finish({n, _mean, m2}, _options), do: m2 / (n - 1)
  end

  defmodule Deviation do
    @moduledoc "`deviation`: the square root of the sample variance (spec/04 §5)."
    @behaviour Macaw.Data.Aggregate
    alias Macaw.Data.Operations.Aggregates
    alias Macaw.Data.Operations.Aggregates.Variance

    @impl true
    def name, do: "deviation"
    @impl true
    def options, do: []
    @impl true
    def output(_type, _options), do: :number
    @impl true
    def keeps_unit?, do: true
    @impl true
    def reduce(values, options), do: Aggregates.fold(__MODULE__, values, options)
    @impl true
    def init(options), do: Variance.init(options)

    @impl true
    def step(state, value, options) do
      Aggregates.number!(name(), value)
      Variance.step(state, value, options)
    end

    @impl true
    def finish(state, options) do
      case Variance.finish(state, options) do
        nil -> nil
        variance -> :math.sqrt(variance)
      end
    end
  end

  defmodule Slope do
    @moduledoc """
    `slope`: the least-squares slope of the points the readings are (spec/04 §5): a number
    `v` at place `i` is the point `[i, v]`, a reading `[x, y]` (or `{x, y}`) the point
    itself. `nil` for fewer than two points, or when every `x` is equal.
    """
    @behaviour Macaw.Data.Aggregate
    alias Macaw.Data.Operations.Aggregates

    @impl true
    def name, do: "slope"
    @impl true
    def options, do: []
    @impl true
    def output(_type, _options), do: :number
    @impl true
    def keeps_unit?, do: false
    @impl true
    def reduce(values, options), do: Aggregates.fold(__MODULE__, values, options)

    # The place, the count and the running means, the co-moment and the x moment: the
    # one-pass covariance update.
    @impl true
    def init(_options), do: {0, 0, 0.0, 0.0, 0.0, 0.0}

    @impl true
    def step({place, n, mx, my, c, m2x}, value, _options) do
      {x, y} = point(value, place)
      n = n + 1
      dx = x - mx
      mx = mx + dx / n
      my = my + (y - my) / n
      {place + 1, n, mx, my, c + dx * (y - my), m2x + dx * (x - mx)}
    end

    @impl true
    def finish({_place, n, _mx, _my, _c, _m2x}, _options) when n < 2, do: nil
    def finish({_place, _n, _mx, _my, _c, m2x}, _options) when m2x == 0, do: nil
    def finish({_place, _n, _mx, _my, c, m2x}, _options), do: c / m2x

    defp point(v, place) when is_number(v), do: {place, v}
    defp point([x, y], _place) when is_number(x) and is_number(y), do: {x, y}
    defp point({x, y}, _place) when is_number(x) and is_number(y), do: {x, y}
    defp point(other, _place), do: Aggregates.wrong!(name(), other, "a number or a point [x, y]")
  end

  defmodule Delta do
    @moduledoc "`delta`: the last reading minus the first (spec/04 §5)."
    @behaviour Macaw.Data.Aggregate
    alias Macaw.Data.Operations.Aggregates

    @impl true
    def name, do: "delta"
    @impl true
    def options, do: []
    @impl true
    def output(_type, _options), do: :number
    @impl true
    def keeps_unit?, do: true
    @impl true
    def reduce(values, options), do: Aggregates.fold(__MODULE__, values, options)
    @impl true
    def init(_options), do: nil
    @impl true
    def step(nil, value, _options), do: {Aggregates.number!(name(), value), value}
    def step({first, _last}, value, _options), do: {first, Aggregates.number!(name(), value)}
    @impl true
    def finish(nil, _options), do: nil
    def finish({first, last}, _options), do: last - first
  end
end
