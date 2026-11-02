defmodule Macaw.Data.Source.Order do
  @moduledoc """
  A request's row order (spec/01 §2.3): what a reader looks at first, so a capped or
  reduced delivery can hold the first rows in it rather than a sorted sample.

  An order is a list of `{field, direction}`, the field a name of the schema's (an atom or
  a string, by either spelling) and the direction `:asc` or `:desc`, the first key
  deciding first; `[]` asks for none.

  **Rows compare by their field's type, never by term order** (term order puts a
  `%DateTime{}` by its day before its year): a `:time` by its instant
  (`instant/1`), a `:number` by its value, a `:text` by its string, a
  `:category` by its place in the field's declared `order` and then by its spelling. A
  `nil`, and a value of no reading for its type, sorts **last in either direction**:
  absence is no value, and a reader's first rows are rows that have one. The sort is
  stable, so rows the order cannot tell apart keep their order. `filter`'s orderings
  (spec/04 §4.1) compare by the same keys (`key/2`), so a filter and a sort never disagree.
  """

  alias Macaw.Data.{Schema, Table}

  @typedoc "A direction of one key."
  @type direction :: :asc | :desc

  @typedoc "A row order: the keys, the first deciding first."
  @type t :: [{Schema.name(), direction()}]

  @ordered [:time, :number, :category, :text]
  @epoch ~N[1970-01-01 00:00:00]
  @day 86_400_000_000
  # 1970-01-01's Gregorian day.
  @epoch_days 719_528

  @doc """
  The faults of an order's shape, with no schema: `{[:order, i], {:type, :order}}` for a
  key that is no `{field, :asc | :desc}` with a name for its field, `{[:order, i],
  {:duplicate, field}}` for a field already named (by either spelling), and `{[:order],
  {:type, :order}}` for an order that is no list.

      iex> Macaw.Data.Source.Order.shape([{"p50", :desc}, {:host, :asc}])
      []
      iex> Macaw.Data.Source.Order.shape([{"p50", :down}, {:p50, :asc}, {"p50", :asc}])
      [{[:order, 0], {:type, :order}}, {[:order, 2], {:duplicate, "p50"}}]
  """
  @spec shape(term()) :: [{list(), term()}]
  def shape(order) when is_list(order) do
    {faults, _seen} =
      order
      |> Enum.with_index()
      |> Enum.reduce({[], MapSet.new()}, fn {key, i}, {faults, seen} ->
        case key do
          {field, direction} when direction in [:asc, :desc] ->
            if name?(field) do
              spelling = Schema.spell(field)

              if MapSet.member?(seen, spelling),
                do: {[{[:order, i], {:duplicate, spelling}} | faults], seen},
                else: {faults, MapSet.put(seen, spelling)}
            else
              {[{[:order, i], {:type, :order}} | faults], seen}
            end

          _other ->
            {[{[:order, i], {:type, :order}} | faults], seen}
        end
      end)

    Enum.reverse(faults)
  end

  def shape(_order), do: [{[:order], {:type, :order}}]

  defp name?(name) when is_binary(name), do: name != ""
  defp name?(name) when is_atom(name), do: name not in [nil, true, false]
  defp name?(_name), do: false

  @doc """
  The faults of an order against a schema: `{[:order, i], {:unknown_field, name}}` for a
  field the schema does not describe, and `{[:order, i], {:invalid_for, type}}` for one
  whose type has no order (`:point`, `:color`). An order of the wrong shape is
  `shape/1`'s, and its keys are not looked up.

      iex> alias Macaw.Data.Schema
      iex> schema = Schema.new!(%{p50: %{type: :number}, at: %{type: :point}})
      iex> Macaw.Data.Source.Order.faults([{"p5O", :desc}, {:at, :asc}, {"p50", :desc}], schema)
      [{[:order, 0], {:unknown_field, "p5O"}}, {[:order, 1], {:invalid_for, :point}}]
  """
  @spec faults(term(), Schema.t()) :: [{list(), term()}]
  def faults(order, %Schema{} = schema) do
    case shape(order) do
      [] ->
        for {{field, _direction}, i} <- Enum.with_index(order),
            fault = field_fault(schema, field),
            do: {[:order, i], fault}

      faults ->
        faults
    end
  end

  defp field_fault(schema, field) do
    case Schema.fetch(schema, field, :type) do
      :error -> {:unknown_field, Schema.spell(field)}
      {:ok, type} when type in @ordered -> nil
      {:ok, type} -> {:invalid_for, type}
    end
  end

  @doc """
  The rows sorted by the order under the schema's types, stably, each row read by name
  (`Macaw.Data.Table.get/2`, either spelling): `{:ok, rows}`. `[]` leaves them as they
  are. An order the schema cannot sort by is `{:error, faults}`, `faults/2`'s: a field the
  schema lacks, `{[:order, i], {:unknown_field, name}}`, one whose type has no order,
  `{[:order, i], {:invalid_for, type}}`, and an order of the wrong shape, `shape/1`'s.
  `sort!/3` answers the rows or raises.

      iex> alias Macaw.Data.Schema
      iex> schema = Schema.new!(%{t: %{type: :time}, sev: %{type: :category, order: ["ok", "warn", "bad"]}})
      iex> rows = [
      ...>   %{t: ~U[2026-10-02 00:00:00Z], sev: "ok"},
      ...>   %{t: ~U[2025-12-31 00:00:00Z], sev: "bad"},
      ...>   %{t: nil, sev: "warn"}
      ...> ]
      iex> {:ok, sorted} = Macaw.Data.Source.Order.sort(rows, [{:t, :desc}], schema)
      iex> Enum.map(sorted, & &1.sev)
      ["ok", "bad", "warn"]
      iex> Macaw.Data.Source.Order.sort!(rows, [{:sev, :desc}], schema) |> Enum.map(& &1.sev)
      ["bad", "warn", "ok"]
      iex> Macaw.Data.Source.Order.sort(rows, [{:at, :asc}], schema)
      {:error, [{[:order, 0], {:unknown_field, "at"}}]}
  """
  @spec sort([map()], t(), Schema.t()) :: {:ok, [map()]} | {:error, [{list(), term()}, ...]}
  def sort(rows, order, %Schema{} = schema), do: sort_with(rows, order, schema, &Table.get/2)

  @doc """
  The items sorted by the order under the schema's types, stably, as `sort/3` sorts rows:
  `read` takes an item and a field of the order, as the order names it, to the item's
  value of that field. `{:ok, items}`, or `sort/3`'s faults. `sort/3` is this over rows,
  each read by name; finishing a table (spec/01 §2.4) sorts its row indexes so by several
  field read from its column, and makes no row.

      iex> alias Macaw.Data.{Schema, Source.Order}
      iex> schema = Schema.new!(%{v: %{type: :number}})
      iex> values = {3, nil, 1}
      iex> Order.sort_with([0, 1, 2], [{:v, :asc}], schema, fn i, _field -> elem(values, i) end)
      {:ok, [2, 0, 1]}
  """
  @spec sort_with([item], t(), Schema.t(), (item, Schema.name() -> term())) ::
          {:ok, [item]} | {:error, [{list(), term()}, ...]}
        when item: term()
  def sort_with(items, [], _schema, _read), do: {:ok, items}

  def sort_with(items, order, %Schema{} = schema, read) when is_function(read, 2) do
    case faults(order, schema) do
      [] ->
        keys =
          Enum.map(order, fn {field, direction} ->
            {direction, schema_key(schema, field), &read.(&1, field)}
          end)

        {:ok, sort_by(items, keys)}

      faults ->
        {:error, faults}
    end
  end

  @doc "As `sort/3`, the rows alone, raising `ArgumentError` naming the faults."
  @spec sort!([map()], t(), Schema.t()) :: [map()]
  def sort!(rows, order, %Schema{} = schema) do
    case sort(rows, order, schema) do
      {:ok, sorted} ->
        sorted

      {:error, faults} ->
        raise ArgumentError, "an order the schema cannot sort by: #{inspect(faults)}"
    end
  end

  @doc """
  The items sorted stably by keys, each `{direction, key, read}`: `read` takes an item to
  its value, `key` (from `key/2`) the value to its sort key, `nil` for no reading, which
  sorts **last in either direction**. The first key decides first; items no key tells
  apart keep their order. `sort/3` is this over a schema's fields, and the `sort` step
  (spec/04 §4.6) over one column's readings, so the two order alike.

      iex> alias Macaw.Data.Source.Order
      iex> times = [~U[2026-10-02 00:00:00Z], nil, ~U[2025-12-31 00:00:00Z]]
      iex> Order.sort_by(times, [{:asc, Order.key(:time), & &1}])
      [~U[2025-12-31 00:00:00Z], ~U[2026-10-02 00:00:00Z], nil]
  """
  @spec sort_by([item], [{direction(), (term() -> term()), (item -> term())}]) :: [item]
        when item: term()
  def sort_by(items, []), do: items

  # One key: each item keyed, sorted by `keysorted/3`, which finishing's one-field order
  # sorts a column's keys by too (macaw_data#140), so the two order alike.
  def sort_by(items, [{direction, key, read}]) do
    {present, absent} = split(items, key, read, [], [])
    keysorted(present, absent, direction)
  end

  def sort_by(items, keys) do
    items
    |> Enum.map(fn item -> {Enum.map(keys, &reading(&1, item)), item} end)
    |> Enum.sort_by(&elem(&1, 0), &before?/2)
    |> Enum.map(&elem(&1, 1))
  end

  # The items keyed, `{key, item}`, those with a reading in reverse order, and those
  # without in their order.
  defp split([item | items], key, read, present, absent) do
    case key.(read.(item)) do
      nil -> split(items, key, read, present, [item | absent])
      k -> split(items, key, read, [{k, item} | present], absent)
    end
  end

  defp split([], _key, _read, present, absent), do: {present, :lists.reverse(absent)}

  @doc false
  # One key's sort: `present`, `{key, item}` pairs **in reverse order** of the items, keys
  # that compare as the type orders and none `nil`, sorted stably in `direction`, then
  # `absent`, the items without a reading, in their order: the items alone.
  # `:lists.keysort/2` is stable ascending, so sorting the reversed pairs and reversing the
  # result as the items are taken out of it sorts them descending with items of one key
  # in their order; ascending, the pairs are put back in order first.
  @spec keysorted([{term(), item}], [item], direction()) :: [item] when item: term()
  def keysorted(present, absent, :desc), do: present |> keysort() |> unkey(absent)

  def keysorted(present, absent, :asc),
    do: present |> :lists.reverse() |> keysort() |> :lists.reverse() |> unkey(absent)

  defp keysort(pairs), do: :lists.keysort(1, pairs)

  # The items of the pairs in reverse order, before `acc`.
  defp unkey([{_key, item} | pairs], acc), do: unkey(pairs, [item | acc])
  defp unkey([], acc), do: acc

  # Each key's reading of an item: `{0, key}` with a value, `{1, nil}` without, so every
  # value comes first in either direction; a descending key negates its comparison.
  defp reading({direction, key, read}, item) do
    case key.(read.(item)) do
      nil -> {1, nil}
      k -> {0, {direction, k}}
    end
  end

  # Readings compared key by key; a tie on every key keeps the rows' order (a stable sort
  # takes `true` for equal elements).
  defp before?([], []), do: true

  defp before?([a | rest_a], [b | rest_b]) do
    case compare(a, b) do
      :lt -> true
      :gt -> false
      :eq -> before?(rest_a, rest_b)
    end
  end

  defp compare({1, nil}, {1, nil}), do: :eq
  defp compare({1, nil}, _value), do: :gt
  defp compare(_value, {1, nil}), do: :lt
  defp compare({0, {:asc, a}}, {0, {:asc, b}}), do: compare_keys(a, b)
  defp compare({0, {:desc, a}}, {0, {:desc, b}}), do: compare_keys(b, a)

  defp compare_keys(a, b) when a < b, do: :lt
  defp compare_keys(a, b) when a > b, do: :gt
  defp compare_keys(_a, _b), do: :eq

  @doc false
  # A schema field's sort key: its type's, a category's under its declared `order`. The
  # field is one `faults/2` passed: described, of a type with an order.
  @spec schema_key(Schema.t(), Schema.name()) :: (term() -> term())
  def schema_key(schema, field) do
    {:ok, type} = Schema.fetch(schema, field, :type)

    states =
      case Schema.fetch(schema, field, :order) do
        {:ok, states} when type == :category -> states
        _none -> []
      end

    key(type, states)
  end

  @doc """
  A value's sort key under a type, so keys compare in term order exactly as the type
  orders, and `nil` for no reading: a `:time`'s instant (`instant/1`),
  a `:number`'s value, a `:text`'s string, and a `:category`'s place in `states` (its
  declared `order`, spec/01 §1.2) and then its spelling, a state `states` does not list
  following them. **A type with no order of its own** (`:color`, `:point`, `:term`) keys a
  value by itself, so it sorts by term order; only `nil` is no reading.

      iex> alias Macaw.Data.Source.Order
      iex> Order.key(:time).(~U[2026-10-02 00:00:00Z]) > Order.key(:time).(~U[2025-12-31 00:00:00Z])
      true
      iex> Order.key(:category, ["ok", "warn"]).(:warn)
      {1, "warn"}
      iex> Order.key(:number).("7")
      nil
  """
  @spec key(atom(), [term()]) :: (term() -> term())
  def key(type, states \\ [])

  def key(:time, _states), do: &instant/1
  def key(:number, _states), do: fn value -> if is_number(value), do: value end
  def key(:text, _states), do: fn value -> if is_binary(value), do: value end

  def key(:category, states) do
    places = states |> Enum.with_index() |> Map.new(fn {s, i} -> {spelling(s), i} end)
    last = map_size(places)

    fn
      nil -> nil
      value -> category_key(value, places, last)
    end
  end

  def key(_type, _states), do: & &1

  @doc """
  A time's instant on one scale, Unix microseconds, so times of every kind compare: a
  `DateTime`'s UTC instant, a `NaiveDateTime`'s wall clock and a `Date` at midnight, as
  the edge reads them into a time column (spec/01 §1.1) and as the packed
  `:utc`, `:zoned` and `:naive` forms hold them. Anything else, a number included (a
  `:time` holds instants, never numbers, spec/01 §3), is `nil`, no reading.

      iex> alias Macaw.Data.Source.Order
      iex> Order.instant(~U[1970-01-01 00:00:01Z])
      1_000_000
      iex> Order.instant(~N[1970-01-01 00:00:01]) == Order.instant(~U[1970-01-01 00:00:01Z])
      true
      iex> Order.instant(~D[1970-01-02])
      86_400_000_000
      iex> Order.instant(5)
      nil
  """
  @spec instant(term()) :: integer() | nil
  def instant(%DateTime{} = t), do: DateTime.to_unix(t, :microsecond)
  def instant(%NaiveDateTime{} = t), do: NaiveDateTime.diff(t, @epoch, :microsecond)
  def instant(%Date{} = d), do: (Date.to_gregorian_days(d) - @epoch_days) * @day
  def instant(_value), do: nil

  defp category_key(value, places, last)
       when is_atom(value) or is_binary(value) or is_number(value) do
    spelled = spelling(value)
    {Map.get(places, spelled, last), spelled}
  end

  defp category_key(_value, _places, _last), do: nil

  defp spelling(value) when is_binary(value), do: value
  defp spelling(value), do: to_string(value)
end
