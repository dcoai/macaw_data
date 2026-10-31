defmodule Macaw.Data.Window do
  @moduledoc """
  Windows, boxes and regions over a source's rows (spec/01 §2.3, §2.4).

  - A **window** is `nil` (whatever a source holds) or `[from, to]`, either bound `nil`
    for open, over the window field: numbers for a `:number` field, instants (`DateTime`,
    `NaiveDateTime` or `Date`) for a `:time` one (`applies?/2`).
  - A **box** is `%{west, south, east, north}` in degrees over a `:point` window field
    (`Macaw.Data.Source.Request.box?/1`); `west` east of `east` crosses the antimeridian.
  - A **region** is ranges over named `:time` or `:number` fields, `%{field => [from, to]}`.

  These are the comparisons, the trims and the numeric position that finishing
  (`Macaw.Data.Source.Finish`) and push share. Fields are read by either spelling of their
  name (`Macaw.Data.Table.get/2`). Ported from visualize's `Visualize.Feed.Window`, its box
  rewritten for a geographic box and its ranges kept as the region.

  ## Examples

      iex> Macaw.Data.Window.within?(5, [0, 10])
      true
      iex> Macaw.Data.Window.trim([%{t: 1}, %{t: 5}, %{t: 9}], :t, [2, nil])
      [%{t: 5}, %{t: 9}]
      iex> Macaw.Data.Window.in_box?({179.5, 0}, %{west: 170, south: -10, east: -170, north: 10})
      true
  """

  alias Macaw.Data.{Schema, Table}
  alias Macaw.Data.Source.Request

  # The request's fields a window check reads.
  @axes [:window, :box, :region, :latest, :order]

  @type time :: number() | DateTime.t() | NaiveDateTime.t() | Date.t()
  @type t :: [time() | nil] | nil

  @doc "`:lt`, `:eq` or `:gt` between two times of one kind."
  @spec compare(time(), time()) :: :lt | :eq | :gt
  def compare(a, b) when is_number(a) and is_number(b) do
    cond do
      a < b -> :lt
      a > b -> :gt
      true -> :eq
    end
  end

  def compare(%DateTime{} = a, %DateTime{} = b), do: DateTime.compare(a, b)
  def compare(%NaiveDateTime{} = a, %NaiveDateTime{} = b), do: NaiveDateTime.compare(a, b)
  def compare(%Date{} = a, %Date{} = b), do: Date.compare(a, b)

  @doc "Whether a value is one a window can be over: a number or an instant."
  @spec time?(term()) :: boolean()
  def time?(value), do: is_number(value) or instant?(value)

  @doc "Whether a value is an instant: a `DateTime`, a `NaiveDateTime` or a `Date`."
  @spec instant?(term()) :: boolean()
  def instant?(%DateTime{}), do: true
  def instant?(%NaiveDateTime{}), do: true
  def instant?(%Date{}), do: true
  def instant?(_value), do: false

  @doc """
  Whether a window applies to a window field of the type: its bounds instants for
  `:time`, numbers for `:number`; a `nil` window, and a window with no bound, to either.

      iex> Macaw.Data.Window.applies?([~U[2026-10-12 00:00:00Z], nil], :number)
      false
  """
  @spec applies?(t(), :time | :number) :: boolean()
  def applies?(nil, _type), do: true

  def applies?([from, to], type) when type in [:time, :number],
    do: of?(from, type) and of?(to, type)

  def applies?(_window, _type), do: false

  defp of?(nil, _type), do: true
  defp of?(value, :number), do: is_number(value)
  defp of?(value, :time), do: instant?(value)

  @doc "Whether a time lies within a window, both bounds inclusive; `nil` lies in none but `nil`."
  @spec within?(time() | nil, t()) :: boolean()
  def within?(_time, nil), do: true
  def within?(nil, _window), do: false
  def within?(time, [from, to]), do: after_from?(time, from) and before_to?(time, to)

  @doc "The rows whose `field` lies within the window, in their order."
  @spec trim([map()], Table.name(), t()) :: [map()]
  def trim(rows, _field, nil), do: rows
  def trim(rows, field, window), do: Enum.filter(rows, &within?(Table.get(&1, field), window))

  @doc "The rows whose `field` lies strictly after `time`; every row for `nil`. A push's seam."
  @spec newer([map()], Table.name(), time() | nil) :: [map()]
  def newer(rows, _field, nil), do: rows

  def newer(rows, field, time) do
    Enum.filter(rows, fn row ->
      value = Table.get(row, field)
      value != nil and compare(value, time) == :gt
    end)
  end

  @doc """
  The rows whose `field` lies in `[from, upper)`: `from` inclusive and open when `nil`,
  `upper` exclusive and open when `nil`; a row with no time lies in none. The seam of a
  combination, where one source's rows stop and the next's begin (macaw#185, ported from
  visualize's `Visualize.Feed.Window.before/4`).

      iex> Macaw.Data.Window.before([%{t: 1}, %{t: 5}, %{t: 9}], :t, nil, 5)
      [%{t: 1}]
      iex> Macaw.Data.Window.before([%{t: 1}, %{t: 5}, %{t: 9}], :t, 5, nil)
      [%{t: 5}, %{t: 9}]
  """
  @spec before([map()], Table.name(), time() | nil, time() | nil) :: [map()]
  def before(rows, field, from, upper) do
    Enum.filter(rows, fn row ->
      time = Table.get(row, field)
      time != nil and after_from?(time, from) and (upper == nil or compare(time, upper) == :lt)
    end)
  end

  @doc """
  The region a window asks of a schema (macaw#185): a range `[from, to]` is the window
  field's region, `%{field => [from, to]}`, where it applies to the window field's type,
  and `nil` (the source's own span) where it does not or the schema has no `:time` or
  `:number` window field; a region passes as it is; `nil` is `nil`.

  visualize's box (D-168), `%{ranges: ranges, latest: latest}`, is a request's `region`
  and `latest` here: `region(ranges, schema)` and `latest:` beside it.

      iex> alias Macaw.Data.Schema
      iex> schema = Schema.new!(%{t: %{type: :number, window: true}, v: %{type: :number}})
      iex> Macaw.Data.Window.region([0, 10], schema)
      %{"t" => [0, 10]}
      iex> Macaw.Data.Window.region([~U[2026-10-14 00:00:00Z], nil], schema)
      nil
      iex> Macaw.Data.Window.region(%{v: [0, 1]}, schema)
      %{v: [0, 1]}
  """
  @spec region(t() | %{Table.name() => t()}, Schema.t()) :: %{Table.name() => t()} | nil
  def region(nil, %Schema{}), do: nil

  def region([_from, _to] = window, %Schema{} = schema) do
    field = Schema.window_field(schema)

    with field when field != nil <- field,
         {:ok, type} when type in [:time, :number] <- Schema.fetch(schema, field, :type),
         true <- applies?(window, type) do
      %{field => window}
    else
      _ -> nil
    end
  end

  def region(%{} = region, %Schema{}) when not is_struct(region), do: region

  @doc """
  A field's range of a window or a region (macaw#185, visualize's `range/2`): a region's
  entry for the field, by either spelling of its name; a range `[from, to]` itself, which
  is the window field's; `nil` when there is none. Anything else is returned as it is,
  so a source that reads its window field's range this way still refuses what it can't.

      iex> Macaw.Data.Window.range(%{"t" => [1, 5], x: [0, 9]}, :t)
      [1, 5]
      iex> Macaw.Data.Window.range([1, 5], :t)
      [1, 5]
      iex> Macaw.Data.Window.range(%{x: [0, 9]}, :t)
      nil
  """
  @spec range(term(), Table.name()) :: term()
  def range(%{} = region, field) when not is_struct(region) do
    Enum.find_value(region, fn {name, range} -> if same?(name, field), do: range end)
  end

  def range(window, _field), do: window

  defp same?(a, b) when (is_atom(a) or is_binary(a)) and (is_atom(b) or is_binary(b)),
    do: to_string(a) == to_string(b)

  defp same?(_a, _b), do: false

  @doc "The intersection of two windows, either `nil` for everything."
  @spec intersect(t(), t()) :: t()
  def intersect(nil, window), do: window
  def intersect(window, nil), do: window
  def intersect([f1, t1], [f2, t2]), do: [latest(f1, f2), earliest(t1, t2)]

  @doc "The later of two times, a `nil` ignored."
  @spec latest(time() | nil, time() | nil) :: time() | nil
  def latest(nil, b), do: b
  def latest(a, nil), do: a
  def latest(a, b), do: if(compare(a, b) == :lt, do: b, else: a)

  @doc "The earlier of two times, a `nil` ignored."
  @spec earliest(time() | nil, time() | nil) :: time() | nil
  def earliest(nil, b), do: b
  def earliest(a, nil), do: a
  def earliest(a, b), do: if(compare(a, b) == :gt, do: b, else: a)

  @doc """
  A time as a number, for a reduction's `x`: a number itself, a `DateTime` its Unix
  microseconds, a `NaiveDateTime` its Gregorian seconds, a `Date` its Gregorian days;
  anything else `nil`, a gap.
  """
  @spec position(term()) :: number() | nil
  def position(value) when is_number(value), do: value
  def position(%DateTime{} = value), do: DateTime.to_unix(value, :microsecond)

  def position(%NaiveDateTime{} = value) do
    {seconds, micro} = NaiveDateTime.to_gregorian_seconds(value)
    seconds + micro / 1_000_000
  end

  def position(%Date{} = value), do: Date.to_gregorian_days(value)
  def position(_value), do: nil

  @doc """
  Whether a position `{longitude, latitude}` lies in a box, bounds inclusive; a box whose
  `west` is east of its `east` crosses the antimeridian. Anything but a position lies in
  none.
  """
  @spec in_box?(term(), map()) :: boolean()
  def in_box?({lon, lat}, %{west: w, south: s, east: e, north: n})
      when is_number(lon) and is_number(lat) do
    lat >= s and lat <= n and if(w <= e, do: lon >= w and lon <= e, else: lon >= w or lon <= e)
  end

  def in_box?(_position, _box), do: false

  @doc "The rows whose `field` lies in the box, in their order; every row for `nil`."
  @spec trim_box([map()], Table.name(), map() | nil) :: [map()]
  def trim_box(rows, _field, nil), do: rows
  def trim_box(rows, field, box), do: Enum.filter(rows, &in_box?(Table.get(&1, field), box))

  @doc "The rows whose every ranged field lies in its range; every row for `nil`."
  @spec trim_region([map()], %{Table.name() => t()} | nil) :: [map()]
  def trim_region(rows, nil), do: rows

  def trim_region(rows, region),
    do: Enum.reduce(region, rows, fn {field, range}, rows -> trim(rows, field, range) end)

  @doc """
  Each identity's last row: of the rows, for each identity `identify` gives, the row whose
  `time` (a number) is greatest, the later in order on a tie, kept in their order. A row
  whose identity or time is `nil` names nothing and is dropped.

      iex> rows = [%{id: "a", t: 1}, %{id: "b", t: 2}, %{id: "a", t: 3}, %{id: nil, t: 4}]
      iex> Macaw.Data.Window.latest_rows(rows, & &1.t, & &1.id)
      [%{id: "b", t: 2}, %{id: "a", t: 3}]
  """
  @spec latest_rows([map()], (map() -> number() | nil), (map() -> term())) :: [map()]
  def latest_rows(rows, time, identify) when is_function(time, 1) and is_function(identify, 1) do
    last =
      rows
      |> Enum.with_index()
      |> Enum.reduce(%{}, fn {row, i}, last ->
        with id when id != nil <- identify.(row),
             t when t != nil <- time.(row) do
          case Map.fetch(last, id) do
            {:ok, {held, _i}} when held > t -> last
            _later_or_first -> Map.put(last, id, {t, i})
          end
        else
          nil -> last
        end
      end)

    kept = MapSet.new(last, fn {_id, {_t, i}} -> i end)
    for {row, i} <- Enum.with_index(rows), MapSet.member?(kept, i), do: row
  end

  @doc """
  Whether a schema can answer a request's window, box, region, latest and order: `:ok`, or
  `{:error, faults}`, every fault `{path, reason}` by path. A window must apply to a
  `:time` or `:number` window field; a box needs a `:point` window field; each region
  field is described, `:time` or `:number`, its range two ends of its type, not inverted;
  `latest` needs a `:time` or `:number` window field and a declared identity; each field
  of an `order` is described and of a type with an order (`Macaw.Data.Source.Order.faults/2`).
  A request asking none of them is `:ok`.

  It takes a `%Request{}`, or the axes alone as a map of its fields (`window`, `box`,
  `region`, `latest`, `order`, each defaulting as a request's does), so a source stepping its
  window checks one without a whole request (macaw#185); any other key is
  `{[key], :unknown_key}`.

      iex> alias Macaw.Data.Schema
      iex> schema = Schema.new!(%{t: %{type: :number, window: true}, v: %{type: :number}})
      iex> Macaw.Data.Window.check(%{region: %{t: [0, 5]}}, schema)
      :ok
      iex> Macaw.Data.Window.check(%{window: [9, 1], at: 3}, schema)
      {:error, [{[:at], :unknown_key}]}

      iex> alias Macaw.Data.{Schema, Source.Request}
      iex> schema = Schema.new!(%{t: %{type: :number, window: true}, s: %{type: :category}})
      iex> Macaw.Data.Window.check(Request.new!(now: ~U[2026-10-27 00:00:00Z], region: %{t: [9, 1], s: ["a", "b"]}, latest: true), schema)
      {:error,
       [
         {[:latest], {:window, :no_identity}},
         {[:region, :s], {:invalid_for, :category}},
         {[:region, :t], {:window, :inverted}}
       ]}
  """
  @spec check(Request.t() | map(), Schema.t()) :: :ok | {:error, [{list(), term()}, ...]}
  def check(request_or_axes, schema)

  # The axes alone, as a map of the request's fields (macaw#185): a source steps its
  # window, or visualize checks its box, without a whole request.
  def check(%{} = axes, %Schema{} = schema) when not is_struct(axes) do
    unknown = for key <- Map.keys(axes), key not in @axes, do: {[key], :unknown_key}

    request =
      struct(
        Request,
        Map.merge(%{window: nil, box: nil, region: nil, latest: false, order: []}, axes)
      )

    case {unknown, check(request, schema)} do
      {[], result} -> result
      {unknown, :ok} -> {:error, Enum.sort_by(unknown, &elem(&1, 0))}
      {unknown, {:error, faults}} -> {:error, Enum.sort_by(unknown ++ faults, &elem(&1, 0))}
    end
  end

  def check(%Request{} = request, %Schema{} = schema) do
    field = Schema.window_field(schema)
    type = field && Schema.fetch(schema, field, :type) |> elem(1)

    faults =
      window_faults(request.window, type) ++
        box_faults(request.box, type) ++
        region_faults(request.region, schema) ++
        latest_faults(request.latest, field, schema) ++
        Macaw.Data.Source.Order.faults(request.order, schema)

    case Enum.sort_by(faults, &elem(&1, 0)) do
      [] -> :ok
      faults -> {:error, faults}
    end
  end

  defp window_faults(nil, _type), do: []
  defp window_faults(_window, nil), do: [{[:window], {:window, :no_window_field}}]

  defp window_faults(window, type) when type in [:time, :number],
    do: if(applies?(window, type), do: [], else: [{[:window], {:type, type}}])

  defp window_faults(_window, type), do: [{[:window], {:invalid_for, type}}]

  defp box_faults(nil, _type), do: []
  defp box_faults(_box, :point), do: []
  defp box_faults(_box, nil), do: [{[:box], {:window, :no_window_field}}]
  defp box_faults(_box, type), do: [{[:box], {:invalid_for, type}}]

  defp region_faults(nil, _schema), do: []

  defp region_faults(region, schema) do
    Enum.flat_map(region, fn {field, range} ->
      path = [:region, field]

      case Schema.fetch(schema, field, :type) do
        :error -> [{path, {:window, :unknown_field}}]
        {:ok, type} when type not in [:time, :number] -> [{path, {:invalid_for, type}}]
        {:ok, type} -> ends_faults(path, range, type)
      end
    end)
  end

  defp ends_faults(path, [from, to], type) do
    case for(
           {end_, i} <- [{from, 0}, {to, 1}],
           not of?(end_, type),
           do: {path ++ [i], {:type, type}}
         ) do
      [] -> order_faults(path, from, to)
      faults -> faults
    end
  end

  defp order_faults(_path, from, to) when from == nil or to == nil, do: []

  defp order_faults(path, from, to) do
    cond do
      kind(from) != kind(to) -> [{path, {:window, :mixed}}]
      compare(from, to) == :gt -> [{path, {:window, :inverted}}]
      true -> []
    end
  end

  defp kind(value) when is_number(value), do: :number
  defp kind(%module{}), do: module

  defp latest_faults(false, _field, _schema), do: []

  # Latest is by the window field's order, which a `:point` field does not have.
  defp latest_faults(true, field, schema) do
    by =
      case field && Schema.fetch(schema, field, :type) do
        nil -> [{[:latest], {:window, :no_window_field}}]
        {:ok, type} when type in [:time, :number] -> []
        {:ok, type} -> [{[:latest], {:invalid_for, type}}]
      end

    by ++ if Schema.identity(schema) == [], do: [{[:latest], {:window, :no_identity}}], else: []
  end

  defp after_from?(_time, nil), do: true
  defp after_from?(time, from), do: compare(time, from) != :lt

  defp before_to?(_time, nil), do: true
  defp before_to?(time, to), do: compare(time, to) != :gt
end
