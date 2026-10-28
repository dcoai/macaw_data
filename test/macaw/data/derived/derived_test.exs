defmodule Macaw.Data.DerivedTest do
  # The derived source as a value (spec/02 §1–§3). Ported from visualize's
  # `Visualize.VirtualSourceTest` and adapted: inputs are sources, a window is nil, last or
  # a request, names are strings and the map form is JSON-ready.
  use ExUnit.Case, async: true
  use ExUnitProperties

  # A stored function that raises in the property is reported by its process's exit.
  @moduletag :capture_log

  alias Macaw.Data.{Delivery, Derived, Schema}
  alias Macaw.Data.Derived.{Context, Join, Sandbox}
  alias Macaw.Data.Test.Atoms

  doctest Derived
  doctest Context
  doctest Join

  # Names the stored functions below use, atoms when this module loads.
  @names ~w(hosts host cpu state trend health load mem region)a
  setup_all do
    {:ok, names: @names}
  end

  @hosts Schema.new!(%{
           t: %{type: :time, window: true},
           host: %{type: :category, identity: true},
           cpu: %{type: :number}
         })

  defp health(overrides \\ []) do
    Keyword.merge(
      [
        id: :health,
        from: [hosts: %{last: 20}],
        per: :identity,
        schema: %{
          host: %{type: :category, identity: true},
          state: %{type: :category, values: [:ok, :warning, :error]}
        },
        elixir: "fn rows -> %{state: if(Enum.at(rows, -1).cpu > 90, do: :error, else: :ok)} end"
      ],
      overrides
    )
  end

  describe "new/1: alone" do
    @tag verifies: "derived-new"
    test "a source is built, its names held as strings, its function checked alone" do
      {:ok, source} = Derived.new(health())

      assert source.id == "health"
      assert source.from == [{"hosts", %{last: 20}}]
      assert %Schema{} = source.schema
      assert Map.keys(source.schema.fields) |> Enum.sort() == ["host", "state"]

      assert {:error, [{[:elixir], {:check, 1, {:restricted, {"List", :last, 1}}}}]} =
               Derived.new(health(elixir: "fn rows -> List.last(rows) end"))
    end

    @tag verifies: "derived-new"
    test "every fault, by path" do
      assert {:error, faults} =
               Derived.new(%{
                 id: nil,
                 from: [{"a", %{last: 0}}, {:a, nil}, :b, {[:x, 1], nil}, {:c, %{bogus: 1}}],
                 schema: %{state: %{type: :category, values: []}},
                 elixir: 3,
                 per: :sideways,
                 extra: 1
               })

      assert faults == [
               {[:elixir], {:type, :string}},
               {[:extra], :unknown_key},
               {[:from, 0, :window, :last], {:type, :pos_integer}},
               {[:from, 1], {:duplicate_input, "a"}},
               {[:from, 2], {:type, :input}},
               {[:from, 3], {:type, :input_name}},
               {[:from, 4, :window], {:type, :window}},
               {[:id], {:type, :name}},
               {[:per], {:enum, [:identity]}},
               {[:schema, :state, :values], {:type, :values}}
             ]

      for fault <- faults, do: assert(is_binary(Derived.format_error(fault)))
    end

    @tag verifies: ["derived-new", "derived-input-keys"]
    test "required keys, one function, inputs read under distinct keys" do
      assert {:error, faults} = Derived.new(%{})
      assert {[:from], :required} in faults
      assert {[:schema], :required} in faults
      assert {[:id], :required} in faults
      assert {[:elixir], :required} in faults

      assert {:error, [{[:function], {:exclusive, :elixir}}]} =
               Derived.new(health(elixir: "fn rows -> rows end", function: :health))

      assert {:error, [{[:from, 1], {:duplicate_input, "hosts"}}]} =
               Derived.new(
                 health(
                   per: nil,
                   from: [{:hosts, nil}, {[:ops, :hosts], nil}],
                   elixir: "fn x -> [] end"
                 )
               )

      assert {:error, [{[:from, 1], {:duplicate_input, "hosts"}}]} =
               Derived.new(
                 health(per: nil, from: [{:hosts, nil}, {"hosts", nil}], elixir: "fn x -> [] end")
               )
    end

    @tag verifies: "derived-new"
    test "per names its input when there are several" do
      assert {:error, [{[:per], {:per, :ambiguous}}]} =
               Derived.new(health(from: [hosts: nil, load: nil], elixir: "fn x -> x end"))

      assert {:error, [{[:per], {:per, {:unknown_input, "mem"}}}]} =
               Derived.new(
                 health(
                   from: [hosts: nil, load: nil],
                   per: {:identity, :mem},
                   elixir: "fn x -> x end"
                 )
               )

      assert {:ok, %Derived{per: {:identity, "hosts"}}} =
               Derived.new(
                 health(
                   from: [hosts: nil, load: nil],
                   per: {:identity, :hosts},
                   elixir: "fn x -> x end"
                 )
               )
    end

    @tag verifies: "derived-new"
    test "a request window is checked as a request; anything else is refused" do
      assert {:ok, _} = Derived.new(health(from: [hosts: %{window: [0, 10], latest: true}]))

      assert {:error, [{[:from, 0, :window, :latest], _reason}]} =
               Derived.new(health(from: [hosts: %{latest: "yes"}]))

      assert {:error, [{[:from, 0, :window], {:type, :window}}]} =
               Derived.new(health(from: [hosts: %{}]))
    end

    @tag verifies: "derived-new"
    test "a keyword list that is not one, and anything else; new! names every fault" do
      assert {:error, [{[], {:type, :derived}}]} = Derived.new([1, 2])
      assert {:error, [{[], {:type, :derived}}]} = Derived.new(:nope)

      assert_raise ArgumentError,
                   ~r/not a derived source:\n  elixir: is required\n  from: is required\n  id: is required\n  schema: is required/,
                   fn ->
                     Derived.new!(%{})
                   end
    end
  end

  describe "validate/2: in context" do
    setup do
      {:ok, source: Derived.new!(health(elixir: "fn rows -> %{state: :ok} end"))}
    end

    @tag verifies: "derived-validate"
    test "a function reads its inputs' fields and its own", %{source: source} do
      assert :ok = Derived.validate(source, inputs: %{hosts: @hosts})

      reads_mem = %{source | elixir: "fn rows -> %{state: Enum.at(rows, 0).mem} end"}

      assert {:error, [{[:elixir], {:check, 1, {:unknown_field, "mem"}}}]} =
               Derived.validate(reads_mem, inputs: %{hosts: @hosts})

      # An input whose schema is not known leaves the fields unchecked.
      assert :ok = Derived.validate(reads_mem, inputs: %{})
    end

    @tag verifies: "derived-validate"
    test "a host function is one the registry holds", %{source: source} do
      hosted = %{source | elixir: nil, function: "health"}
      assert :ok = Derived.validate(hosted, functions: %{"health" => {__MODULE__, 1}})

      assert {:error, [{[:function], {:undeclared, :function, "health"}}]} =
               Derived.validate(hosted, functions: %{})

      assert :ok = Derived.validate(hosted)
    end

    @tag verifies: "derived-validate"
    test "a request window is checked against its input's schema", %{source: source} do
      regioned = %{source | from: [{"hosts", %{region: %{"nope" => [0, 1]}}}]}

      assert {:error, [{[:from, 0, :window, :region, "nope"], {:window, :unknown_field}}]} =
               Derived.validate(regioned, inputs: %{hosts: @hosts})
    end

    @tag verifies: "derived-validate"
    test "per identity: the input declares one, and the output's is the input's", %{
      source: source
    } do
      no_identity = Schema.new!(%{host: %{type: :category}, cpu: %{type: :number}})

      assert {:error, [{[:per], {:per, :no_identity}}]} =
               Derived.validate(source, inputs: %{hosts: no_identity})

      other = Schema.new!(%{region: %{type: :category, identity: true}, cpu: %{type: :number}})

      assert {:error, [{[:schema], {:per, {:identity, ["region"], ["host"]}}}]} =
               Derived.validate(source, inputs: %{hosts: other})

      numbered = Schema.new!(%{host: %{type: :number, identity: true}, cpu: %{type: :number}})

      assert {:error, [{[:schema, "host"], {:per, {:identity_type, "host", :number, :category}}}]} =
               Derived.validate(source, inputs: %{hosts: numbered})
    end
  end

  describe "conform/2" do
    setup do
      {:ok,
       source:
         Derived.new!(
           id: :health,
           from: [hosts: nil],
           per: :identity,
           schema: %{
             "region" => %{type: :text},
             host: %{type: :category, identity: true},
             state: %{type: :category, values: [:ok, :error]},
             load: %{type: :number},
             t: %{type: :time},
             at: %{type: :point}
           },
           elixir: "fn x -> x end"
         )}
    end

    @tag verifies: "derived-conform-answers"
    test "rows in the schema conform, keyed by strings; nil is any field's", %{source: source} do
      rows = [
        %{
          host: "a",
          state: :ok,
          load: 1.5,
          t: ~U[2026-10-16 00:00:00Z],
          region: "eu",
          at: {1, 2}
        },
        %{"host" => "b", state: nil, load: nil}
      ]

      assert {:ok,
              [
                %{
                  "host" => "a",
                  "state" => :ok,
                  "load" => 1.5,
                  "t" => ~U[2026-10-16 00:00:00Z],
                  "region" => "eu",
                  "at" => {1, 2}
                },
                %{"host" => "b", "state" => nil, "load" => nil}
              ]} = Derived.conform(source, rows)
    end

    @tag verifies: "derived-conform-answers"
    test "the first fault, by row and field, never the value", %{source: source} do
      assert {:error, {nil, nil, :not_a_list}} = Derived.conform(source, %{})
      assert {:error, {1, nil, :not_a_row}} = Derived.conform(source, [%{host: "a"}, 3])
      assert {:error, {0, "cpu", :undescribed}} = Derived.conform(source, [%{host: "a", cpu: 1}])
      assert {:error, {0, "host", :no_identity}} = Derived.conform(source, [%{state: :ok}])

      assert {:error, {0, "load", {:type, :number}}} =
               Derived.conform(source, [%{host: "a", load: "1"}])

      assert {:error, {0, "t", {:type, :time}}} = Derived.conform(source, [%{host: "a", t: 3}])

      assert {:error, {0, "region", {:type, :text}}} =
               Derived.conform(source, [%{host: "a", region: :eu}])

      assert {:error, {0, "at", {:type, :point}}} =
               Derived.conform(source, [%{host: "a", at: {1, "x"}}])

      assert {:error, {0, "state", :not_in_values}} =
               Derived.conform(source, [%{host: "a", state: :warning}])

      assert {:error, {0, "host", {:type, :category}}} = Derived.conform(source, [%{host: true}])
    end

    @tag verifies: "derived-conform-answers"
    test "a value entry's value is the value" do
      source =
        Derived.new!(
          id: :health,
          from: [hosts: nil],
          schema: %{
            state: %{
              type: :category,
              values: [%{value: :ok, name: "OK", color: "#2e7d32"}, :warning]
            }
          },
          elixir: "fn x -> x end"
        )

      assert {:ok, _} = Derived.conform(source, [%{state: :ok}, %{state: "warning"}])
      assert {:error, {0, "state", :not_in_values}} = Derived.conform(source, [%{state: :error}])

      assert {:error, {0, "state", {:type, :category}}} =
               Derived.conform(source, [%{state: %{value: :ok, name: "OK"}}])
    end
  end

  @tag verifies: "derived-conform-no-value"
  property "no fault of conform ever holds a value of the rows" do
    source =
      Derived.new!(
        id: :s,
        from: [x: nil],
        schema: %{n: %{type: :number}, c: %{type: :category, values: [:a]}},
        elixir: "fn x -> x end"
      )

    check all(
            marker <- string(:alphanumeric, min_length: 8),
            rows <-
              list_of(
                one_of([
                  constant(%{n: "marker"}),
                  constant(%{c: "marker"}),
                  constant(%{other: 1}),
                  constant(%{n: 1})
                ]),
                min_length: 1
              )
          ) do
      rows = Enum.map(rows, &replace(&1, "marker", "m#{marker}"))

      case Derived.conform(source, rows) do
        {:ok, _rows} -> :ok
        {:error, {_i, field, reason}} -> refute inspect({field, reason}) =~ marker
      end
    end
  end

  defp replace(row, from, to) do
    Map.new(row, fn {k, v} ->
      {if(k == from, do: to, else: k), if(v == from, do: to, else: v)}
    end)
  end

  describe "per/3" do
    @tag verifies: "derived-per-entity"
    test "once per entity in order of first appearance, a row without identity dropped, joined" do
      source =
        Derived.new!(
          id: :peak,
          from: [hosts: nil],
          per: :identity,
          schema: %{host: %{type: :category, identity: true}, peak: %{type: :number}},
          function: :peak
        )

      rows = [
        %{host: "b", cpu: 1},
        %{host: "a", cpu: 5},
        %{host: nil, cpu: 99},
        %{host: "b", cpu: 7}
      ]

      inputs = [%{name: "hosts", rows: rows, schema: @hosts}]
      me = self()

      call = fn rows ->
        send(me, {:called, Enum.map(rows, & &1.cpu)})
        %{peak: rows |> Enum.map(& &1.cpu) |> Enum.max()}
      end

      assert {:ok, [%{"host" => "b", "peak" => 7}, %{"host" => "a", "peak" => 5}]} =
               Derived.per(source, inputs, call)

      assert_received {:called, [1, 7]}
      assert_received {:called, [5]}
      refute_received {:called, [99]}
    end

    @tag verifies: "derived-per-entity"
    test "an answer naming another identity, or not rows, does not conform" do
      source =
        Derived.new!(
          id: :s,
          from: [hosts: nil],
          per: :identity,
          schema: %{host: %{type: :category, identity: true}},
          function: :s
        )

      inputs = [%{name: "hosts", rows: [%{host: "a"}], schema: @hosts}]

      assert {:error, :nonconforming, {0, "host", :identity}} =
               Derived.per(source, inputs, fn _ -> %{host: "z"} end)

      assert {:error, :nonconforming, {nil, nil, :not_a_list}} =
               Derived.per(source, inputs, fn _ -> 3 end)

      assert {:ok, [%{"host" => "a"}, %{"host" => "a"}]} =
               Derived.per(source, inputs, fn _ -> [%{}, %{host: "a"}] end)
    end
  end

  @tag verifies: "derived-join-fields"
  test "joined fields: each output field but identity as id.field, nil without an entry" do
    health =
      Schema.new!(%{
        "host" => %{type: :category, identity: true},
        "state" => %{type: :category, values: ["ok"]}
      })

    rows = [%{host: "a", cpu: 3}, %{host: "b", cpu: 9}]
    outputs = [{"health", health, [%{"host" => "a", "state" => "ok"}]}]

    assert [%{"health.state" => "ok"}, %{"health.state" => nil}] =
             Join.join(rows, @hosts, outputs)

    joined = Join.schema(@hosts, outputs)
    assert {:ok, %{type: :category, values: ["ok"]}} = Schema.fetch(joined, "health.state")
    assert Schema.fetch(joined, "health.host") == :error
    assert Join.join(rows, @hosts, []) == rows
  end

  # Checked on the output's own names, never the node's atom count (macaw_data#1).
  @tag verifies: "derived-join-fields"
  test "joining makes no atom of an output's id, its fields or the joined names" do
    [id, field] = names = [Atoms.fresh(), Atoms.fresh()]

    output =
      Schema.new!(%{
        "host" => %{type: :category, identity: true},
        field => %{type: :category, values: ["ok"]}
      })

    outputs = [{id, output, [%{"host" => "a", field => "ok"}]}]
    joined = "#{id}.#{field}"

    assert [%{^joined => "ok"}] = Join.join([%{host: "a"}], @hosts, outputs)
    assert {:ok, _} = Schema.fetch(Join.schema(@hosts, outputs), joined)
    assert Atoms.made([joined, "#{id}.host" | names]) == []
  end

  @tag verifies: "derived-forms-inverse"
  test "to_map and new are inverses; to_json and from_json too, limits first" do
    sources = [
      Derived.new!(health()),
      Derived.new!(health(per: {:identity, ["ops", "hosts"]}, from: [{["ops", "hosts"], nil}])),
      Derived.new!(
        id: :s,
        from: [{{:source, "vm.memory"}, %{window: [~U[2026-10-27 00:00:00Z], nil]}}],
        schema: %{n: %{type: :number}},
        function: :s
      ),
      Derived.new!(
        id: :r,
        from: [
          {"places",
           %{
             box: %{west: 175, south: -20, east: -175, north: -15},
             region: %{"pop" => [1, 9]},
             latest: true
           }}
        ],
        schema: %{n: %{type: :number}},
        elixir: "fn x -> x end"
      )
    ]

    for source <- sources do
      map = Derived.to_map(source)
      assert map |> JSON.encode!() |> JSON.decode!() == map
      assert Derived.new(map) == {:ok, source}
      assert Derived.from_json(Derived.to_json(source)) == {:ok, source}
    end

    json = Derived.to_json(hd(sources))

    assert {:error, [{[], {:limit, :bytes, 10, _}}]} =
             Derived.from_json(json, limits: [bytes: 10])

    assert {:error, [{["nope"], :unknown_key}]} = Derived.new(%{"id" => "x", "nope" => 1})
  end

  describe "inputs" do
    @tag verifies: "derived-input-keys"
    test "a short id, a source and a path each read under their key's string" do
      assert Derived.key(:hosts) == "hosts"
      assert Derived.key("vm.memory") == "vm.memory"
      assert Derived.key({:source, "vm.memory"}) == "vm.memory"
      assert Derived.key(["ops", "health"]) == "health"
      assert Derived.key(3) == nil

      one = Derived.new!(health(elixir: "fn x -> x end"))
      assert Derived.identity_input(one) == "hosts"
      assert Derived.identity_input(%{one | per: nil}) == nil
      assert Derived.identity_input(%{one | per: {:identity, "load"}}) == "load"
    end

    @tag verifies: "derived-argument"
    test "the argument: a stored function reads names as its literals, a host as given" do
      one = Derived.new!(health(elixir: "fn x -> x end"))
      stored = one
      hosted = %{one | elixir: nil, function: "h"}
      inputs = [%{name: "hosts", rows: [%{"state" => "ok", "warning" => 1}], schema: @hosts}]

      # A stored function reads names as its literals: a word's atom (:ok), else the string.
      assert Derived.argument(stored, inputs) == %{"hosts" => [%{"state" => :ok, "warning" => 1}]}

      assert Derived.argument(hosted, inputs) == %{
               "hosts" => [%{"state" => "ok", "warning" => 1}]
             }
    end

    @tag verifies: "derived-input-history"
    test "nil every row, last n per identity or overall, a request finished" do
      rows =
        for {host, t} <- [{"a", 1}, {"b", 2}, {"a", 3}, {"a", 4}, {"b", 5}],
            do: %{host: host, cpu: t, t: DateTime.from_unix!(t)}

      assert Derived.window(rows, nil, @hosts) == rows

      assert Enum.map(Derived.window(rows, %{last: 2}, @hosts), &{&1.host, &1.cpu}) ==
               [{"b", 2}, {"a", 3}, {"a", 4}, {"b", 5}]

      assert Enum.map(Derived.window(rows, %{last: 9}, @hosts), & &1.cpu) == [1, 2, 3, 4, 5]

      plain = Schema.new!(%{t: %{type: :time, window: true}, cpu: %{type: :number}})
      assert Enum.map(Derived.window(rows, %{last: 2}, plain), & &1.cpu) == [4, 5]

      asked = %{window: [DateTime.from_unix!(2), DateTime.from_unix!(4)], latest: true}

      assert Enum.map(Derived.window(rows, asked, @hosts), &{&1.host, &1.cpu}) == [
               {"b", 2},
               {"a", 4}
             ]
    end
  end

  @tag verifies: "derived-context-facts"
  test "the context: each input's schema as data and its delivery's facts; no clock, no variables" do
    delivery =
      Delivery.new([%{cpu: 1}], served: [window: [0, 10], resolution: :minute, capped: true])

    context = Context.new([%{key: :hosts, delivery: delivery, schema: @hosts}])

    assert Map.keys(context) == ["inputs"]

    assert %{
             "inputs" => %{
               "hosts" => %{
                 "schema" => %{"host" => %{"identity" => true, "type" => :category}},
                 "window" => [0, 10],
                 "resolution" => :minute,
                 "capped" => true
               }
             }
           } = context

    # A derived input: its output schema, and a delivery with no facts.
    output = Delivery.new([%{n: 1}])

    derived =
      Context.new([
        %{key: "count", delivery: output, schema: Schema.new!(%{n: %{type: :number}})}
      ])

    assert derived["inputs"]["count"] == %{
             "schema" => %{"n" => %{"type" => :number}},
             "window" => nil,
             "resolution" => nil,
             "capped" => false
           }
  end

  describe "scoping" do
    @paths [["health"], ["ops", "health"], ["ops", "box", "load"], ["other", "health"]]

    @tag verifies: "derived-resolve"
    test "the nearest definition wins, and an inner one shadows an outer one" do
      assert Derived.resolve(@paths, [:ops, :box], :health) == {:ok, ["ops", "health"]}
      assert Derived.resolve(@paths, ["ops", "box"], "load") == {:ok, ["ops", "box", "load"]}
      assert Derived.resolve(@paths, [:elsewhere], :health) == {:ok, ["health"]}
      assert Derived.resolve(@paths, [], :health) == {:ok, ["health"]}
      assert Derived.resolve(@paths, [:ops], :load) == :error
    end

    @tag verifies: "derived-resolve"
    test "a full path names one exactly, from any scope; a source name never resolves" do
      assert Derived.resolve(@paths, [:ops], [:other, :health]) == {:ok, ["other", "health"]}
      assert Derived.resolve(@paths, [:ops], [:ops, :nope]) == :error
      assert Derived.resolve(@paths, [:ops], {:source, "health"}) == :error

      assert Derived.resolve(Map.new(@paths, &{&1, nil}), [:ops], :health) ==
               {:ok, ["ops", "health"]}

      assert Derived.dotted([:ops, :box, "load"]) == "ops.box.load"
    end

    @tag verifies: "derived-cycles"
    test "each cycle named once, sorted; downstream sources in none" do
      reads = %{
        ["a"] => [["b"]],
        ["b"] => [["c"]],
        ["c"] => [["a"]],
        ["d"] => [["a"]],
        ["e"] => [["e"]],
        ["f"] => []
      }

      assert Derived.cycles(reads) == [[["a"], ["b"], ["c"]], [["e"]]]
      assert Derived.cycles(%{["a"] => [], ["b"] => [["a"]]}) == []
    end
  end

  @tag verifies: "derived-properties"
  property "a stored function over generated rows never crashes the caller, leaks no value in a fault, and conforms or faults" do
    source =
      Derived.new!(
        id: :s,
        from: [x: nil],
        schema: %{n: %{type: :number}},
        elixir: "fn %{x: rows} -> Enum.map(rows, fn r -> %{n: r.v * 2} end) end"
      )

    {:ok, compiled} = Sandbox.compile(source.elixir)

    check all(
            marker <- string(:alphanumeric, min_length: 8),
            values <- list_of(one_of([integer(), float(), constant(:text), constant(nil)]))
          ) do
      rows = Enum.map(values, &%{v: if(&1 == :text, do: "m#{marker}", else: &1)})
      argument = Derived.argument(source, [%{name: "x", rows: rows, schema: @hosts}])

      case Sandbox.run(compiled, [argument], max_reductions: 1_000_000) do
        {:ok, answer} ->
          case Derived.conform(source, answer) do
            {:ok, conformed} -> assert length(conformed) == length(rows)
            {:error, fault} -> refute inspect(fault) =~ marker
          end

        {:error, kind, detail} ->
          assert kind in [:raised, :reductions, :memory]
          refute inspect(detail) =~ marker
      end
    end
  end
end
