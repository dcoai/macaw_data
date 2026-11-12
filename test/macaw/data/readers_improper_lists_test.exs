defmodule Macaw.Data.ReadersImproperListsTest do
  @moduledoc """
  An improper list passes `is_list/1` and raises from `Enum` (spec/00 §5, macaw_data#184,
  #169). A generated value holds one only now and then, so this walks a valid input of each
  reader and makes each list in it improper in turn: every position, on every run. Each
  answers `{:ok, value}` or `{:error, faults}`, and its `!` twin raises exactly those faults.

  Each call runs in its own process, so a failure lists every position that raised.
  """
  use ExUnit.Case, async: true

  alias Macaw.Data.{Delivery, Derived, Error, Format, Operations, Parameter, Schema, Stack, Table}
  alias Macaw.Data.Source.{Description, Finish, Order, Push, Request}

  @moduletag :capture_log

  @now ~U[2026-01-01 00:00:00Z]

  # Each list in a term made improper, one at a time: a term per position. A struct is
  # whole: its lists are its own, read by what built it.
  defp improper(term) do
    term |> positions() |> Enum.map(& &1.(:improper))
  end

  # A function per list position, from a tail to the term with that list ending in it.
  defp positions(list) when is_list(list) and list != [] do
    [fn tail -> ended(list, tail) end | within_list(list)]
  end

  defp positions(%_{}), do: []

  defp positions(map) when is_map(map) do
    for {key, value} <- map, at <- positions(value) do
      fn tail -> Map.put(map, key, at.(tail)) end
    end
  end

  defp positions(tuple) when is_tuple(tuple) do
    for i <- 0..(tuple_size(tuple) - 1)//1, at <- positions(elem(tuple, i)) do
      fn tail -> put_elem(tuple, i, at.(tail)) end
    end
  end

  defp positions(_leaf), do: []

  defp within_list(list) do
    for {element, i} <- Enum.with_index(list), at <- positions(element) do
      fn tail -> List.replace_at(list, i, at.(tail)) end
    end
  end

  # The list with `tail` where its `[]` was.
  defp ended([last], tail), do: [last | tail]
  defp ended([head | rest], tail), do: [head | ended(rest, tail)]

  # Every call whose process died, each with its input and why.
  defp raised(inputs, call) do
    for input <- inputs,
        {pid, ref} = spawn_monitor(fn -> call.(input) end),
        reason = down(pid, ref),
        reason != :normal,
        do: {input, where(reason)}
  end

  # The reason and the library's frame nearest it, what a failure needs to be read.
  defp where({reason, stack}) when is_list(stack) do
    frame =
      Enum.find_value(stack, fn
        {module, name, arity, at} when is_atom(module) ->
          if String.starts_with?(Atom.to_string(module), "Elixir.Macaw.Data") and
               not String.ends_with?(Atom.to_string(module), "Test"),
             do: {module, name, if(is_list(arity), do: length(arity), else: arity), at[:line]}

        _other ->
          nil
      end)

    {reason, frame}
  end

  defp where(other), do: other

  defp down(pid, ref) do
    receive do
      {:DOWN, ^ref, :process, ^pid, reason} -> reason
    end
  end

  # The value twin answers, and the twin raises exactly its faults.
  defp answers(value, bang) do
    case value.() do
      {:ok, _value} ->
        :ok

      {:error, faults} ->
        %Error{reason: ^faults} =
          assert_raise(Error, fn -> bang.() end)
    end
  end

  defp answered(value) do
    case value do
      {:ok, _value} -> :ok
      {:error, [_ | _]} -> :ok
    end
  end

  defp schema do
    Schema.new!(%{
      "t" => %{type: :number, window: true},
      "state" => %{
        type: :category,
        identity: true,
        order: ["ok", "bad"],
        status: %{"ok" => :good, "bad" => :bad},
        values: ["ok", %{value: "bad", color: {:color, :warning}}]
      }
    })
  end

  defp sources do
    [
      [%{"a" => 1, "b" => [1, 2]}, %{"a" => 2, "b" => [3]}],
      [{1, 2}, {3, 4}],
      %{"a" => [1, 2], "b" => [3, 4]}
    ]
  end

  @tag verifies: "data-errors-readers"
  test "Table.new/2: columns, a column's values, a column's name, options" do
    input = {[{"a", :number, [1, 2]}, {"b", :category, ["x", "y"]}], [origin: nil]}

    assert raised(improper(input), fn {columns, opts} ->
             answers(fn -> Table.new(columns, opts) end, fn -> Table.new!(columns, opts) end)
           end) == []
  end

  @tag verifies: "data-errors-readers"
  test "Table.from/2: rows, tuples, a column map, its types: option" do
    for source <- sources() do
      input = {source, [types: %{"a" => :number}]}

      assert raised(improper(input), fn {source, opts} ->
               answers(fn -> Table.from(source, opts) end, fn -> Table.from!(source, opts) end)
             end) ==
               []
    end
  end

  @tag verifies: "data-errors-readers"
  test "Table.column_types/1, time_columns/1 and Stack.generate/2: every source" do
    stack = Stack.new() |> Stack.keys(["a", "b"])

    for source <- sources() do
      assert raised(improper(source), fn source ->
               answers(fn -> Table.column_types(source) end, fn ->
                 Table.column_types!(source)
               end)

               answers(fn -> Table.time_columns(source) end, fn ->
                 Table.time_columns!(source)
               end)

               answers(fn -> Stack.generate(stack, source) end, fn ->
                 Stack.generate!(stack, source)
               end)
             end) == []
    end
  end

  @tag verifies: "data-errors-readers"
  test "Schema.new/1: order, values, an entry and their neighbors" do
    input = %{
      a: %{
        type: :category,
        order: ["x", "y"],
        values: ["x", %{value: "y", label: "Y"}],
        status: %{"x" => :good},
        bounds: [0, 1]
      },
      b: %{type: :number, bounds: [0, 1], unit: "s"},
      c: %{type: :point, bounds: [[0, 0], [1, 1]]}
    }

    assert raised(improper(input), fn fields ->
             answers(fn -> Schema.new(fields) end, fn -> Schema.new!(fields) end)
           end) == []
  end

  @tag verifies: "data-errors-readers"
  test "Schema.from_map/1: its pairs, a pair, values, status, a color's payload" do
    {:ok, half} = Macaw.Layers.Color.alpha({:color, :warning}, 0.5)

    {:ok, map} =
      Schema.new!(%{
        "state" => %{
          type: :category,
          order: ["ok", "bad"],
          status: %{"ok" => :good, "bad" => :bad},
          values: [
            %{value: "ok", color: {:color, :warning}},
            %{value: "bad", color: half}
          ]
        },
        "n" => %{type: :number, bounds: [0, 1]}
      })
      |> then(&{:ok, Schema.to_map(&1)})

    assert length(improper(map)) >= 8

    assert raised(improper(map), fn pairs ->
             answers(fn -> Schema.from_map(pairs) end, fn -> Schema.from_map!(pairs) end)
           end) == []
  end

  @tag verifies: "data-errors-readers"
  test "Description.new/1: its fields, supports, a parameter's values" do
    input = [
      schema: schema(),
      supports: [:window, :budget],
      params: %{"p" => %{type: :category, values: ["a", "b"], default: "a"}},
      viewer_independent: true
    ]

    assert raised(improper(input), fn fields ->
             answers(fn -> Description.new(fields) end, fn -> Description.new!(fields) end)
           end) == []
  end

  @tag verifies: "data-errors-readers"
  test "Parameter.validate/2 over a parameter's values" do
    assert raised(
             improper(%{"p" => %{type: :category, values: ["a", "b"]}}),
             fn params -> answered(Parameter.validate(params, %{"p" => "z"})) end
           ) == []
  end

  @tag verifies: "data-errors-readers"
  test "Request.new/1: its fields, a window, a region's range, an order" do
    input = [
      now: @now,
      window: [1, 2],
      region: %{"a" => [1, 2]},
      order: [{"a", :asc}, {"b", :desc}],
      params: %{"a" => [1, 2]},
      viewer: [:anyone]
    ]

    assert raised(improper(input), fn fields ->
             answers(fn -> Request.new(fields) end, fn -> Request.new!(fields) end)
           end) == []
  end

  @tag verifies: "data-errors-readers"
  test "the calls #184 and #169 name answer the fault their position has" do
    bad = {:type, :schema}
    assert Schema.from_map([["a", %{}] | :b]) == {:error, [{[], bad}]}

    assert Schema.from_map([["a", %{"type" => "category", "values" => [1 | 2]}]]) ==
             {:error, [{["a", :values], {:type, :values}}]}

    assert {:error, [{["a", :status], _reason}]} =
             Schema.from_map([["a", %{"type" => "category", "status" => [["x", "y"] | 2]}]])

    assert {:error, faults} =
             Schema.from_map([
               [
                 "a",
                 %{
                   "type" => "category",
                   "values" => [%{"value" => "x", "color" => %{"$alpha" => [1 | 2]}}]
                 }
               ]
             ])

    assert is_binary(Macaw.Data.Fault.sentence(faults))

    assert Schema.new(%{a: %{type: :category, values: [1 | 2]}}) ==
             {:error, [{[:a, :values], {:type, :values}}]}

    assert Schema.new(%{a: %{type: :category, order: [1 | 2]}}) ==
             {:error, [{[:a, :order], {:type, :order}}]}

    order = [{"a", :asc} | :b]
    assert Order.shape(order) == [{[:order], {:type, :order}}]

    assert Order.faults(order, Schema.new!(%{a: %{type: :number}})) == [
             {[:order], {:type, :order}}
           ]

    assert Request.new(order: order) ==
             {:error, [{[:now], :required}, {[:order], {:type, :order}}]}

    assert Table.new([{"a", :number, [1]} | :b]) == {:error, [{[], {:type, :columns}}]}

    assert Table.new([{"a", :number, [1]}], [{:origin, nil} | :b]) ==
             {:error, [{[:opts], {:type, :keyword}}]}

    assert Operations.validate(Operations.registry(), [%{"op" => "sum"} | :b], %{}) ==
             {:error, [{["nodes"], {:type, :nodes}}]}
  end

  @tag verifies: "data-errors-readers"
  test "Order.shape/1 and faults/2" do
    assert raised(improper([{"t", :asc}, {"state", :desc}]), fn order ->
             assert is_list(Order.shape(order))
             assert is_list(Order.faults(order, schema()))
           end) == []
  end

  @tag verifies: "data-errors-readers"
  test "Derived.new/1: its fields, its inputs, an input's path, a window" do
    input = [
      id: "d",
      from: [{"hosts", %{last: 20, region: %{"a" => [1, 2]}, window: [1, 2]}}, {["a", "b"], nil}],
      schema: %{"h" => %{type: :number, bounds: [0, 1]}},
      function: "f",
      per: {:identity, ["a", "b"]}
    ]

    assert raised(improper(input), fn fields ->
             answers(fn -> Derived.new(fields) end, fn -> Derived.new!(fields) end)
           end) == []
  end

  # `Derived.from_map/2` is not walked: an improper list in a map form, like a struct,
  # raises inside `Macaw.Layers.Form.gates/3` today, the kernel's to refuse
  # (dco-tek/macaw/macaw_layers#37). A decoded document can't hold one.

  @tag verifies: "data-errors-readers"
  test "Format.parse/2 and Format.Locale.new/1: their options, fields and grouping" do
    locale = Format.Locale.english()

    assert raised(improper(locale: locale), fn opts ->
             answers(fn -> Format.parse(",.2f", opts) end, fn -> Format.parse!(",.2f", opts) end)
           end) == []

    assert raised(improper(grouping: [3, 2], currency: ["$", ""], decimal: "."), fn fields ->
             answers(fn -> Format.Locale.new(fields) end, fn -> Format.Locale.new!(fields) end)
           end) == []

    assert raised(improper(%{grouping: [3, 2], currency: ["$", ""]}), fn fields ->
             answers(fn -> Format.Locale.new(fields) end, fn -> Format.Locale.new!(fields) end)
           end) == []
  end

  @tag verifies: "data-errors-readers"
  test "Push.new/3 and Finish.ceiling/2: their options" do
    assert raised(improper(cache: 1, limit: 10), fn opts ->
             ref = make_ref()
             answers(fn -> Push.new("n", ref, opts) end, fn -> Push.new!("n", ref, opts) end)
           end) == []

    assert raised(improper(host: 10, page: 10), fn opts ->
             answers(fn -> Finish.ceiling(10, opts) end, fn -> Finish.ceiling!(10, opts) end)
           end) == []
  end

  @tag verifies: "data-errors-readers"
  test "Delivery.new/2: rows, names, types, served, retracted, replace" do
    input =
      {[%{"a" => 1}],
       [
         names: ["a"],
         types: [{"a", :number}],
         served: [window: [1, 2], capped: true, params: %{"a" => [1]}],
         retracted: [%{"a" => 1}],
         replace: [%{from: 1, to: 2, identities: [1, 2], rows: [%{"a" => 1}]}]
       ]}

    assert raised(improper(input), fn {rows, opts} ->
             answers(fn -> Delivery.new(rows, opts) end, fn -> Delivery.new!(rows, opts) end)
           end) == []

    # A list of rows is not walked by new/2, which reads no row: reading it answers.
    assert {:ok, delivery} = Delivery.new([%{"a" => 1} | :improper])
    assert {:error, [_ | _]} = Delivery.rows(delivery)
    assert {:error, [_ | _]} = Delivery.table(delivery)
    assert {:error, [_ | _]} = Delivery.named_rows(delivery)

    assert raised(improper(served: %{window: [1, 2]}), fn opts ->
             answers(fn -> Delivery.new([], opts) end, fn -> Delivery.new!([], opts) end)
           end) == []
  end

  @tag verifies: "data-errors-readers"
  test "Operations.apply/4: its nodes, every list a step takes, its source" do
    registry = Operations.registry()
    source = [%{"a" => 1, "b" => 2, "t" => 1}, %{"a" => 2, "b" => 3, "t" => 2}]

    nodes = [
      %{"op" => "aggregate", "field" => ["a", "b"], "fn" => "sum", "by" => ["t"]},
      %{"op" => "bin", "field" => "a", "thresholds" => [1, 2]},
      %{"op" => "filter", "field" => "a", "test" => "eq", "value" => [1, 2]},
      %{"op" => "fold", "fields" => ["a", "b"], "as" => ["k", "v"]},
      %{"op" => "lttb", "fields" => ["a", "b"], "n" => 3},
      %{"op" => "m4", "fields" => ["a", "b"], "width" => 3},
      %{"op" => "stack", "fields" => ["a", "b"], "order" => %{"keys" => ["a", "b"]}},
      %{"op" => "sum", "field" => "a", "by" => ["t"]},
      %{"op" => "window", "field" => "t", "from" => [1, "hour"], "to" => [1, "second"]}
    ]

    for node <- nodes do
      assert raised(improper([node]), fn nodes ->
               answers(fn -> Operations.apply(registry, nodes, source) end, fn ->
                 Operations.apply!(registry, nodes, source)
               end)
             end) == []
    end

    assert raised(improper(source), fn source ->
             answers(fn -> Operations.apply(registry, [], source) end, fn ->
               Operations.apply!(registry, [], source)
             end)
           end) == []
  end
end
