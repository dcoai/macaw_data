defmodule Macaw.Data.Source.Order do
  @moduledoc """
  A request's row order (spec/01 §2.3): what a reader looks at first, so a capped or
  reduced delivery can hold the first rows in it rather than a sorted sample.

  An order is a list of `{field, direction}`, the field a name of the schema's (an atom or
  a string, by either spelling) and the direction `:asc` or `:desc`, the first key
  deciding first; `[]` asks for none.

  **Rows compare by their field's type, never by term order** (term order puts a
  `%DateTime{}` by its day before its year): a `:time` by its instant
  (`Macaw.Data.Window.position/1`), a `:number` by its value, a `:text` by its string, a
  `:category` by its place in the field's declared `order` and then by its spelling. A
  `nil`, and a value of no reading for its type, sorts **last in either direction**:
  absence is no value, and a reader's first rows are rows that have one. The sort is
  stable, so rows the order cannot tell apart keep their order.
  """

  alias Macaw.Data.{Schema, Table, Window}

  @typedoc "A direction of one key."
  @type direction :: :asc | :desc

  @typedoc "A row order: the keys, the first deciding first."
  @type t :: [{Schema.name(), direction()}]

  @ordered [:time, :number, :category, :text]

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
  (`Macaw.Data.Table.get/2`, either spelling). `[]` leaves them as they are. The order is
  the caller's to have checked (`faults/2`); a field the schema lacks raises
  `ArgumentError`.

      iex> alias Macaw.Data.Schema
      iex> schema = Schema.new!(%{t: %{type: :time}, sev: %{type: :category, order: ["ok", "warn", "bad"]}})
      iex> rows = [
      ...>   %{t: ~U[2026-10-02 00:00:00Z], sev: "ok"},
      ...>   %{t: ~U[2025-12-31 00:00:00Z], sev: "bad"},
      ...>   %{t: nil, sev: "warn"}
      ...> ]
      iex> Macaw.Data.Source.Order.sort(rows, [{:t, :desc}], schema) |> Enum.map(& &1.sev)
      ["ok", "bad", "warn"]
      iex> Macaw.Data.Source.Order.sort(rows, [{:sev, :desc}], schema) |> Enum.map(& &1.sev)
      ["bad", "warn", "ok"]
  """
  @spec sort([map()], t(), Schema.t()) :: [map()]
  def sort(rows, [], _schema), do: rows

  def sort(rows, order, %Schema{} = schema) do
    keys =
      Enum.map(order, fn {field, direction} ->
        {direction, schema_key(schema, field), &Table.get(&1, field)}
      end)

    sort_by(rows, keys)
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

  # One key: the keys are terms that compare as the type orders, so a stable sort of them
  # in its direction, the items without a reading after, in their order.
  def sort_by(items, [{direction, key, read}]) do
    {present, absent} =
      items
      |> Enum.map(fn item -> {key.(read.(item)), item} end)
      |> Enum.split_with(&(elem(&1, 0) != nil))

    present
    |> Enum.sort_by(&elem(&1, 0), direction)
    |> Enum.concat(absent)
    |> Enum.map(&elem(&1, 1))
  end

  def sort_by(items, keys) do
    items
    |> Enum.map(fn item -> {Enum.map(keys, &reading(&1, item)), item} end)
    |> Enum.sort_by(&elem(&1, 0), &before?/2)
    |> Enum.map(&elem(&1, 1))
  end

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

  # A schema field's sort key: its type's, a category's under its declared `order`.
  defp schema_key(schema, field) do
    case Schema.fetch(schema, field, :type) do
      {:ok, type} when type in @ordered ->
        states =
          case Schema.fetch(schema, field, :order) do
            {:ok, states} when type == :category -> states
            _none -> []
          end

        key(type, states)

      {:ok, type} ->
        raise ArgumentError, "a #{inspect(type)} field has no order: #{inspect(field)}"

      :error ->
        raise ArgumentError, "an order names a field the schema lacks: #{inspect(field)}"
    end
  end

  @doc """
  A value's sort key under a type, so keys compare in term order exactly as the type
  orders, and `nil` for no reading: a `:time`'s instant (`Macaw.Data.Window.position/1`),
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

  def key(:time, _states), do: &Window.position/1
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

  defp category_key(value, places, last)
       when is_atom(value) or is_binary(value) or is_number(value) do
    spelled = spelling(value)
    {Map.get(places, spelled, last), spelled}
  end

  defp category_key(_value, _places, _last), do: nil

  defp spelling(value) when is_binary(value), do: value
  defp spelling(value), do: to_string(value)
end
