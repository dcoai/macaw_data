defmodule Macaw.Data.ReadersNeverRaiseTest do
  @moduledoc """
  No reader of untrusted input raises (spec/00 §5, macaw_data#130, #159). Over generated
  malformed input, each answers `{:ok, value}` or `{:error, faults}`, and its `!` twin
  raises `Macaw.Data.Error` holding exactly those faults. The input is of the type the
  reader takes, a list or a map, a keyword list of options, a binary, with the wrong shape
  inside it: an argument of the wrong type is a programming error, outside the rule.
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Macaw.Data.{Derived, Error, Fault, Schema, Stack, Table}
  alias Macaw.Data.Source.{Description, Finish, Push, Request}

  # A leaf of any kind, small: the shapes are the generators' work, not the values'.
  defp leaf do
    one_of([
      integer(),
      float(),
      boolean(),
      constant(nil),
      atom(:alphanumeric),
      string(:printable, max_length: 6),
      constant(~U[2026-01-01 00:00:00Z]),
      constant(~D[2026-01-01]),
      constant(:category),
      constant(make_ref())
    ])
  end

  defp value,
    do: one_of([leaf(), list_of(leaf(), max_length: 3), map_of(leaf(), leaf(), max_length: 2)])

  # A map form's value: the terms a decoded document holds. A struct, a tuple or a
  # reference in a map form raises inside macaw_layers' `Form.from_map/3` today, the
  # kernel's to refuse as a fault (dco-tek/macaw/macaw_layers#37).
  defp document_value do
    doc_leaf =
      one_of([integer(), float(), boolean(), constant(nil), string(:printable, max_length: 6)])

    one_of([
      doc_leaf,
      list_of(doc_leaf, max_length: 3),
      map_of(string(:alphanumeric, max_length: 4), doc_leaf, max_length: 2)
    ])
  end

  # Structs of every kind a map test passes: one that enumerates, one that enumerates as
  # pairs, one with fields that read as a description's keys, and plain values.
  defp structs do
    [
      ~U[2026-01-01 00:00:00Z],
      ~D[2026-01-01],
      1..2,
      MapSet.new([{"type", "number"}]),
      %URI{path: "type"}
    ]
  end

  defp name,
    do: one_of([atom(:alphanumeric), string(:alphanumeric, min_length: 1, max_length: 4)])

  defp pairs(keys),
    do: list_of(tuple({one_of([member_of(keys), leaf()]), value()}), max_length: 4)

  # A list of options: pairs keyed by a known key or another, and now and then no pair.
  defp options(keys),
    do: list_of(one_of([tuple({member_of(keys), value()}), leaf()]), max_length: 3)

  # The value twin's answer, and the twin raising exactly its faults.
  defp answers(value, bang) do
    case value.() do
      {:ok, _value} = ok ->
        ok

      {:error, faults} ->
        assert is_binary(Fault.sentence(faults))
        error = assert_raise Error, bang
        assert error.reason == faults
        error
    end
  end

  @tag verifies: "data-errors-readers"
  property "Table.new/2 answers columns of any shape as a table or faults" do
    types = Table.types() ++ [:bogus]

    check all(
            columns <-
              list_of(
                one_of([
                  tuple(
                    {name(), member_of(types), one_of([list_of(leaf(), max_length: 3), leaf()])}
                  ),
                  map_of(atom(:alphanumeric), leaf(), max_length: 2),
                  tuple({name(), member_of(types)}),
                  leaf()
                ]),
                max_length: 4
              ),
            opts <- options([:origin])
          ) do
      answers(fn -> Table.new(columns, opts) end, fn -> Table.new!(columns, opts) end)
    end
  end

  @tag verifies: "data-errors-readers"
  property "Table.from/2 answers any source and any types: as a table or faults" do
    check all(
            source <-
              one_of([
                value(),
                list_of(map_of(name(), leaf(), max_length: 3), max_length: 3),
                map_of(name(), one_of([list_of(leaf(), max_length: 3), leaf()]), max_length: 3)
              ]),
            opts <- options([:types])
          ) do
      case Table.from(source, opts) do
        {:ok, %Table{}} -> :ok
        {:error, [_ | _] = faults} -> assert is_binary(Fault.sentence(faults))
      end
    end
  end

  # A tensor of rank 1 to 3: rank 3 is refused.
  defp tensor do
    bind(integer(1..3), fn rank ->
      map(list_of(integer(1..2), length: rank), &Nx.iota(List.to_tuple(&1)))
    end)
  end

  # The readers of a caller's source besides from/2 (#161): each answers source/1's faults.
  @tag verifies: "data-errors-readers"
  property "column_types/1, time_columns/1 and Stack.generate/2 answer any source or faults" do
    stack = Stack.new() |> Stack.keys([:a, "b"])

    check all(
            source <-
              one_of([
                value(),
                list_of(one_of([map_of(name(), leaf(), max_length: 3), leaf()]), max_length: 3),
                list_of(tuple({leaf(), leaf()}), max_length: 3),
                map_of(name(), one_of([list_of(leaf(), max_length: 3), leaf()]), max_length: 3),
                tensor()
              ])
          ) do
      refused =
        case Table.source(source) do
          :ok -> nil
          {:error, faults} -> {:error, faults}
        end

      for {value, bang} <- [
            {fn -> Table.column_types(source) end, fn -> Table.column_types!(source) end},
            {fn -> Table.time_columns(source) end, fn -> Table.time_columns!(source) end},
            {fn -> Stack.generate(stack, source) end, fn -> Stack.generate!(stack, source) end}
          ] do
        answer = answers(value, bang)
        if refused, do: assert(match?(%Error{}, answer) and {:error, answer.reason} == refused)
      end
    end
  end

  # The stack's own keys, so a value reaches its arithmetic on every run (#178): a raise
  # here fails on every seed, where rows of generated names reached it now and then.
  defp reading do
    one_of([
      leaf(),
      integer(),
      float(),
      member_of([1.0e308, -1.0e308, 1.7976931348623157e308, 5.0e-324, 10 ** 400, -(10 ** 400)])
    ])
  end

  @tag verifies: "operations-stack-values"
  property "Stack.generate/2 answers any value under its own keys, whatever its order and offset" do
    orders = [:none, :reverse, :ascending, :descending, :insideout, {:keys, ["b"]}]
    offsets = [:none, :expand, :diverging, :silhouette, :wiggle]

    check all(
            keys <- member_of([[:a], [:a, "b"], [:a, "b", :c]]),
            order <- member_of(orders),
            offset <- member_of(offsets),
            own <- boolean(),
            rows <-
              list_of(fixed_map(%{:a => reading(), "b" => reading(), :c => reading()}),
                max_length: 3
              )
          ) do
      stack = Stack.new() |> Stack.keys(keys) |> Stack.order(order) |> Stack.offset(offset)
      stack = if own, do: Stack.value(stack, &Table.get(&1, &2)), else: stack

      answers(fn -> Stack.generate(stack, rows) end, fn -> Stack.generate!(stack, rows) end)
      answers(fn -> Stack.stacked(stack, rows) end, fn -> Stack.stacked!(stack, rows) end)
    end
  end

  @tag verifies: "data-errors-readers"
  property "Schema.new/1, from_map/1 and from_json/2 answer any document as a schema or faults" do
    keys = Schema.attributes()

    check all(
            fields <-
              map_of(
                name(),
                one_of([
                  map_of(one_of([member_of(keys), leaf()]), value(), max_length: 3),
                  leaf()
                ]),
                max_length: 3
              ),
            pairs <-
              list_of(one_of([tuple({leaf(), value()}), list_of(value(), max_length: 2), leaf()]),
                max_length: 3
              ),
            json <-
              one_of([
                string(:printable, max_length: 20),
                member_of([
                  ~s({"$version": 1, "fields": []}),
                  ~s({"fields": {"a": 1}}),
                  ~s([["a", {"type": 3}]]),
                  "[1, {",
                  "null"
                ])
              ]),
            named <- string(:alphanumeric, min_length: 1, max_length: 4),
            struct <- member_of(structs())
          ) do
      # On every run, not when a pair happens to be a binary name then a struct (#182).
      assert Schema.from_map([[named, struct]]) ==
               {:error, [{[named], {:type, :description}}]}

      assert {:error, [_ | _] = in_values} =
               Schema.from_map([[named, %{"type" => "category", "values" => [struct]}]])

      assert {[named, :values], {:type, :values}} in in_values

      answers(fn -> Schema.new(fields) end, fn -> Schema.new!(fields) end)

      assert match?({:ok, %Schema{}}, Schema.from_map(pairs)) or
               match?({:error, [_ | _]}, Schema.from_map(pairs))

      assert match?({:ok, %Schema{}}, Schema.from_json(json)) or
               match?({:error, [_ | _]}, Schema.from_json(json))
    end
  end

  @tag verifies: "data-errors-readers"
  property "Description.new/1 and Request.new/1 answer any fields as a value or faults" do
    description = [
      :schema,
      :params,
      :supports,
      :viewer_independent,
      :lateness,
      :idle_after,
      :chunk_span
    ]

    request = [
      :window,
      :box,
      :region,
      :latest,
      :order,
      :budget,
      :as_of,
      :viewer,
      :now,
      :subscription
    ]

    check all(
            d <-
              one_of([pairs(description), map_of(member_of(description), value(), max_length: 3)]),
            r <-
              one_of([
                list_of(one_of([tuple({member_of(request), value()}), leaf()]), max_length: 4),
                map_of(member_of(request), value(), max_length: 3)
              ])
          ) do
      answers(fn -> Description.new(d) end, fn -> Description.new!(d) end)
      answers(fn -> Request.new(r) end, fn -> Request.new!(r) end)
    end
  end

  @tag verifies: "data-errors-readers"
  property "Derived.new/1 and from_map/2 answer any source as a derived source or faults" do
    keys = [:id, :from, :schema, :elixir, :function, :per, :input]

    check all(
            source <- one_of([pairs(keys), map_of(member_of(keys), value(), max_length: 4)]),
            document <-
              map_of(
                member_of(["$version", "id", "from", "schema", "elixir", "per", "input", "x"]),
                document_value(),
                max_length: 4
              )
          ) do
      answers(fn -> Derived.new(source) end, fn -> Derived.new!(source) end)

      case Derived.from_map(document) do
        {:ok, %Derived{}} -> :ok
        {:error, [_ | _]} -> :ok
      end
    end
  end

  @tag verifies: ["data-errors-readers", "push-options"]
  property "Push.new/3 and Finish.ceiling/2 answer any options as a value or faults" do
    check all(
            name <- leaf(),
            push <- options([:cache, :limit, :lateness, :chunk_span]),
            budget <- leaf(),
            ceiling <- options([:host, :page])
          ) do
      answers(fn -> Push.new(name, make_ref(), push) end, fn ->
        Push.new!(name, make_ref(), push)
      end)

      # What new/3 accepts works: its options never raise from what uses them (#177).
      with {:ok, %Push{} = accepted} <- Push.new(name, make_ref(), push) do
        for fields <- [%{"t" => %{type: :number, window: true}}, %{"t" => %{type: :number}}] do
          schema = Schema.new!(fields)
          rows = [%{"t" => 1}, %{"t" => 2}]
          claim = [position: 0, complete_until: 1, resolution: 1]
          snapshot = Macaw.Data.Delivery.new!(rows, schema: schema.version, served: claim)

          increment =
            Macaw.Data.Delivery.new!([%{"t" => 3}],
              schema: schema.version,
              served: [resolution: 1]
            )

          pushed =
            accepted
            |> Push.snapshot(snapshot)
            |> Push.receive(Push.increment_message(accepted.ref, 1, increment))
            |> elem(1)
            |> Push.drain(fn _name -> {:ok, schema} end)

          assert {:ok, %Push{}} = Push.trim(pushed, 1)
        end
      end

      answers(fn -> Finish.ceiling(budget, ceiling) end, fn ->
        Finish.ceiling!(budget, ceiling)
      end)
    end
  end

  @tag verifies: "data-errors-readers"
  test "what the properties found answers its fault: non-pair fields, a struct, types: that is no map" do
    now = ~U[2026-01-01 00:00:00Z]
    assert Request.new([{:now, now}, :budget]) == {:error, [{[], {:type, :keyword}}]}
    assert Request.new(now) == {:error, [{[], {:type, :keyword}}]}
    assert Request.new(now: now, region: now) == {:error, [{[:region], {:type, :region}}]}
    assert Description.new([1, 2]) == {:error, [{[], {:type, :keyword}}]}
    assert Table.from([%{v: 1}], types: [v: :number]) == {:error, [{[:types], {:type, :map}}]}
    assert Table.from([%{v: 1}], typo: %{}) == {:error, [{[:typo], :unknown_key}]}

    delivery = Macaw.Data.Delivery.new!([%{v: 1}])

    assert Macaw.Data.Delivery.table(delivery, types: [v: :number]) ==
             {:error, [{[:types], {:type, :map}}]}

    assert Fault.sentence([{[make_ref()], :required}]) =~ ~r/^#Reference<.*>: is required$/
  end
end
