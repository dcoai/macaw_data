defmodule Macaw.Data.SchemaTest do
  @moduledoc """
  `Macaw.Data.Schema` and its cache (spec/01 §1.2–§1.12): a source's fields described by
  meaning, never by drawing colors; a version every node agrees on, through JSON too; a
  cache that asks a source once.
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  import Macaw.Layers.Color, only: [sigil_RGB: 2]

  alias Macaw.Data.Schema
  alias Macaw.Data.Schema.Cache
  alias Macaw.Layers.Color

  doctest Schema
  doctest Cache

  @full %{
    t: %{type: :time, label: "Time"},
    latency: %{
      type: :number,
      unit: "s",
      quantity: :duration,
      label: "Request time",
      polarity: :lower_is_better,
      target: 0.25,
      continuity: 60
    },
    route: %{type: :text, label: "Route"},
    state: %{
      type: :category,
      order: ["ok", "warn", "fail"],
      status: %{"ok" => :good, "warn" => :warning, "fail" => :bad}
    }
  }

  defp faults(fields) do
    {:error, errors} = Schema.new(fields)
    errors
  end

  describe "new/1: a description by meaning" do
    @tag verifies: "schema-new"
    test "every key with a value it takes" do
      assert {:ok, %Schema{fields: fields}} = Schema.new(@full)
      # Held by the names' strings; every role a string too (spec/01 §1.10).
      assert Map.keys(fields) == ["latency", "route", "state", "t"]
      assert fields["latency"] == @full.latency
      assert fields["state"].status == %{"ok" => "good", "warn" => "warning", "fail" => "bad"}
    end

    @tag verifies: "schema-new"
    test "the fourteen keys are the vocabulary" do
      assert Schema.attributes() ==
               [
                 :type,
                 :unit,
                 :quantity,
                 :label,
                 :order,
                 :status,
                 :polarity,
                 :target,
                 :continuity,
                 :window,
                 :metric_kind,
                 :bounds,
                 :identity,
                 :values
               ]

      assert Map.keys(@full.latency) -- Schema.attributes() == []
      assert Schema.entry_keys() == [:value, :name, :color]
    end

    @tag verifies: "schema-values"
    test "a category field declares the values it takes, every one" do
      values = [:ok, :warning, :error]

      assert {:ok, schema} =
               Schema.new(%{
                 state: %{
                   type: :category,
                   values: values,
                   order: [:ok, :warning, :error],
                   status: %{ok: :good, error: :bad}
                 }
               })

      assert Schema.fetch(schema, :state, :values) == {:ok, ["ok", "warning", "error"]}

      assert {:error, errors} =
               Schema.new(%{
                 a: %{type: :category, values: [:ok, :ok]},
                 b: %{type: :category, values: []},
                 c: %{type: :number, values: [1]},
                 d: %{
                   type: :category,
                   values: [:ok],
                   order: [:ok, :error],
                   status: %{warning: :warning}
                 }
               })

      assert errors == [
               {[:a, :values, 1], :duplicate},
               {[:b, :values], {:type, :values}},
               {[:c, :values], {:invalid_for, :number}},
               {[:d, :order, 1], :not_in_values},
               {[:d, :status, :warning], :not_in_order},
               {[:d, :status, :warning], :not_in_values}
             ]

      for error <- errors, do: assert(is_binary(Schema.format_error(error)))
    end

    @tag verifies: "schema-values"
    test "a declared value may be an entry with a name and a color" do
      values = [
        %{value: "ok", name: "OK", color: ~RGB"#2e7d32"},
        %{value: "degraded", name: "Degraded", color: {:alpha, {:color, "warning"}, 0.74}},
        %{value: :down, color: Color.parse!("#B71C1Ccc")},
        "unknown",
        3
      ]

      assert {:ok, schema} =
               Schema.new(%{
                 state: %{
                   type: :category,
                   values: values,
                   order: ["ok", "degraded"],
                   status: %{"ok" => :good, "degraded" => :warning}
                 }
               })

      # The description is kept as declared, its values by their spelling; the accessors
      # read it.
      assert Schema.fetch(schema, :state, :values) ==
               {:ok, List.replace_at(values, 2, %{value: "down", color: ~RGB"#B71C1Ccc"})}

      assert Schema.values(schema, :state) == ["ok", "degraded", "down", "unknown", 3]
      assert Schema.values(schema, "state") == Schema.values(schema, :state)
      assert Schema.value_names(schema, :state) == %{"ok" => "OK", "degraded" => "Degraded"}

      assert Schema.value_colors(schema, :state) == %{
               "ok" => ~RGB"#2e7d32",
               "degraded" => {:alpha, {:color, "warning"}, 0.74},
               "down" => ~RGB"#B71C1Ccc"
             }
    end

    @tag verifies: "schema-values"
    test "a field with no values: values/2 is nil, the maps empty" do
      schema =
        Schema.new!(%{s: %{type: :category}, b: %{type: :category, values: [:a, :b]}})

      assert Schema.values(schema, :s) == nil
      assert Schema.values(schema, :missing) == nil
      assert Schema.values(schema, :b) == ["a", "b"]

      for field <- [:s, :missing, :b] do
        assert Schema.value_names(schema, field) == %{}
        assert Schema.value_colors(schema, field) == %{}
      end
    end

    @tag verifies: "schema-values"
    test "an entry that says only its value is that value, one version" do
      entry = Schema.new!(%{s: %{type: :category, values: [%{value: :ok}, "x"]}})
      bare = Schema.new!(%{s: %{type: :category, values: [:ok, "x"]}})

      assert entry == bare
      assert Schema.fetch(entry, :s, :values) == {:ok, ["ok", "x"]}
    end

    @tag verifies: "schema-values"
    test "every fault of a value entry, by path" do
      assert faults(%{
               s: %{
                 type: :category,
                 values: [
                   %{name: "No value"},
                   %{value: nil},
                   %{value: "a", name: :a},
                   %{value: "b", color: "#2e7d32"},
                   %{value: "c", color: {:alpha, {:color, :good}, 2}},
                   %{value: "d", color: {:color, "Good"}},
                   %{value: "e", label: "E"},
                   "a",
                   %{value: "b", name: "B again"}
                 ]
               }
             }) == [
               {[:s, :values, 0, :value], :required},
               {[:s, :values, 1, :value], {:type, :state}},
               {[:s, :values, 2, :name], {:type, :string}},
               {[:s, :values, 3, :color], {:type, :color}},
               {[:s, :values, 4, :color], {:type, :color}},
               {[:s, :values, 5, :color], {:type, :color}},
               {[:s, :values, 6, :label], :unknown_entry_key},
               {[:s, :values, 7], :duplicate},
               {[:s, :values, 8], :duplicate}
             ]

      for reason <- [{:type, :state}, {:type, :color}, :unknown_entry_key] do
        assert is_binary(Schema.format_error({[:s, :values, 0, :x], reason}))
      end

      assert Schema.format_error({[:s, :values, 6, :label], :unknown_entry_key}) =~ ":color"

      # An entry that is neither a value nor a map is the list's fault, as it was.
      assert faults(%{s: %{type: :category, values: [:a, [:b]]}}) ==
               [{[:s, :values], {:type, :values}}]

      # A field-level color key is still the fault it was: the hint lives on a value.
      assert faults(%{s: %{type: :category, values: [:a], color: "#fff"}}) ==
               [{[:s, :color], {:color_key, :color}}]
    end

    @tag verifies: "schema-values"
    test "order and status are checked against the bare values" do
      values = [%{value: :ok, name: "OK"}, %{value: :error, color: ~RGB"#c62828"}]

      assert {:ok, _} =
               Schema.new(%{
                 s: %{type: :category, values: values, order: [:ok, :error], status: %{ok: :good}}
               })

      assert faults(%{s: %{type: :category, values: values, status: %{warning: :warning}}}) ==
               [{[:s, :status, :warning], :not_in_values}]
    end

    @tag verifies: "schema-version"
    test "values do not move the version of a schema that does not use them" do
      assert Schema.version(Schema.new!(%{v: %{type: :number}})) ==
               "5cae6d9dd503007869b92cbf89f1983b6b8511eaa1e8f4f1f698abd6b02f0c0a"
    end

    @tag verifies: "schema-new"
    test "a numeric field says its metric kind and its bounds" do
      for kind <- [:gauge, :counter, :rate] do
        assert {:ok, _} = Schema.new(%{v: %{type: :number, quantity: :count, metric_kind: kind}})
      end

      for bounds <- [[0, nil], [nil, 100], [-5, 5], [0.0, 1.0], [nil, nil]] do
        assert {:ok, _} = Schema.new(%{v: %{type: :number, bounds: bounds}}), inspect(bounds)
      end

      assert faults(%{v: %{type: :number, metric_kind: :sum}}) ==
               [{[:v, :metric_kind], {:enum, [:gauge, :counter, :rate]}}]

      for bounds <- [[5, 0], [1, 1], [0], {0, 1}, ["0", 1], [0, 1, 2]] do
        assert faults(%{v: %{type: :number, bounds: bounds}}) == [
                 {[:v, :bounds], {:type, :bounds}}
               ],
               inspect(bounds)
      end

      assert faults(%{v: %{type: :category, metric_kind: :gauge, bounds: [0, 1]}}) == [
               {[:v, :bounds], {:invalid_for, :category}},
               {[:v, :metric_kind], {:invalid_for, :category}}
             ]

      assert Schema.format_error({[:v, :bounds], {:type, :bounds}}) =~ "[min, max]"
    end

    @tag verifies: "schema-new"
    test "type is required and one of the six column types" do
      assert faults(%{v: %{unit: "s"}}) == [{[:v, :type], :required}]

      assert faults(%{v: %{type: :float}}) ==
               [{[:v, :type], {:enum, [:time, :number, :category, :text, :color, :point]}}]
    end

    @tag verifies: "schema-color-keys"
    test "a color key is refused, whatever its value, and says why" do
      # spelling: allow — either spelling is refused.
      for key <- [:color, :colour, :colors, :colours, :palette, :fill, :stroke] do
        assert faults(%{s: %{key => %{"ok" => :good}, :type => :category}}) ==
                 [{[:s, key], {:color_key, key}}]
      end

      line = Schema.format_error({[:s, :colors], {:color_key, :colors}})
      assert line =~ "s.colors"
      assert line =~ "never"
      assert line =~ "status"
      assert line =~ "theme"
    end

    @tag verifies: "schema-color-keys"
    test "a color cannot hide in a status either: a role is a word, never a color" do
      for role <- [{:palette, 5}, {:color, :bad}, ~RGB"#c00", "", nil, true, 3],
          do:
            assert(
              faults(%{s: %{type: :category, status: %{"fail" => role}}}) == [
                {[:s, :status], {:type, :status}}
              ],
              inspect(role)
            )

      # A string is never a color, so a role spelled like a CSS name is a role.
      for role <- [:orange, "orange", "red"] do
        assert {:ok, schema} = Schema.new(%{s: %{type: :category, status: %{"fail" => role}}})
        assert Schema.fetch(schema, :s, :status) == {:ok, %{"fail" => to_string(role)}}
      end

      # A role read back from JSON is its string, and still a role.
      assert {:ok, _} = Schema.new(%{s: %{type: :category, status: %{"fail" => "bad"}}})
    end

    @tag verifies: "schema-new"
    test "an unknown key is reported with the keys there are" do
      assert faults(%{v: %{type: :number, scale: 2}}) == [{[:v, :scale], :unknown_key}]
      assert Schema.format_error({[:v, :scale], :unknown_key}) =~ ":continuity"
    end

    @tag verifies: "schema-new"
    test "a key the field's type does not take" do
      assert faults(%{v: %{type: :category, unit: "s", target: 1}}) ==
               [
                 {[:v, :target], {:invalid_for, :category}},
                 {[:v, :unit], {:invalid_for, :category}}
               ]

      assert faults(%{v: %{type: :number, order: [1, 2]}}) ==
               [{[:v, :order], {:invalid_for, :number}}]

      assert faults(%{v: %{type: :time, status: %{}, quantity: :duration}}) ==
               [
                 {[:v, :quantity], {:invalid_for, :time}},
                 {[:v, :status], {:invalid_for, :time}}
               ]
    end

    @tag verifies: "schema-window-field"
    test "window names a clock: a boolean on a :time or :number field, one field at most" do
      assert {:ok, _} = Schema.new(%{t: %{type: :number, window: true}, v: %{type: :number}})
      assert {:ok, _} = Schema.new(%{t: %{type: :time, window: true}})
      assert {:ok, _} = Schema.new(%{t: %{type: :time, window: false}})

      assert faults(%{s: %{type: :category, window: true}, x: %{type: :text, window: true}}) ==
               [
                 {[:s, :window], {:invalid_for, :category}},
                 {[:x, :window], {:invalid_for, :text}}
               ]

      assert faults(%{t: %{type: :number, window: :yes}}) == [{[:t, :window], {:type, :boolean}}]

      assert faults(%{a: %{type: :time, window: true}, b: %{type: :number, window: true}}) ==
               [{[:b, :window], {:duplicate_window, :a}}]

      assert Schema.format_error({[:b, :window], {:duplicate_window, :a}}) =~ "one field"
      assert Schema.format_error({[:t, :window], {:type, :boolean}}) =~ "true or false"
    end

    @tag verifies: "schema-faults"
    test "values of the wrong shape" do
      assert faults(%{v: %{type: :number, unit: ""}}) == [{[:v, :unit], {:type, :unit}}]
      assert faults(%{v: %{type: :number, unit: :s}}) == [{[:v, :unit], {:type, :unit}}]

      assert faults(%{v: %{type: :number, quantity: "duration"}}) == [
               {[:v, :quantity], {:type, :name}}
             ]

      assert faults(%{v: %{type: :number, quantity: nil}}) == [{[:v, :quantity], {:type, :name}}]
      assert faults(%{v: %{type: :number, label: :x}}) == [{[:v, :label], {:type, :string}}]
      assert faults(%{v: %{type: :number, target: "1"}}) == [{[:v, :target], {:type, :number}}]

      assert faults(%{v: %{type: :number, continuity: 0}}) == [
               {[:v, :continuity], {:type, :positive}}
             ]

      assert faults(%{v: %{type: :number, polarity: :up}}) ==
               [{[:v, :polarity], {:enum, [:higher_is_better, :lower_is_better, :neutral]}}]
    end

    @tag verifies: "schema-measure"
    test "any role word is carried: its list is the theme's" do
      assert {:ok, _} = Schema.new(%{s: %{type: :category, status: %{"x" => :mauve}}})
    end

    @tag verifies: "schema-faults"
    test "an order is non-empty, of states, each once" do
      assert faults(%{s: %{type: :category, order: []}}) == [{[:s, :order], {:type, :order}}]
      assert faults(%{s: %{type: :category, order: [%{}]}}) == [{[:s, :order], {:type, :order}}]

      assert faults(%{s: %{type: :category, order: ["a", "b", "a", "b"]}}) ==
               [{[:s, :order, 2], :duplicate}, {[:s, :order, 3], :duplicate}]
    end

    @tag verifies: "schema-values"
    test "a status names only states the order lists" do
      assert faults(%{
               s: %{type: :category, order: ["ok"], status: %{"ok" => :good, "down" => :bad}}
             }) == [{[:s, :status, "down"], :not_in_order}]

      assert {:ok, _} = Schema.new(%{s: %{type: :category, status: %{"down" => :bad}}})
    end

    @tag verifies: "schema-faults"
    test "field names: atoms or strings, each column once" do
      assert {:ok, _} = Schema.new(%{"v" => %{type: :number}, t: %{type: :time}})
      assert faults(%{1 => %{type: :number}}) == [{[1], {:type, :name}}]
      assert faults(%{"" => %{type: :number}}) == [{[""], {:type, :name}}]
      assert faults(%{nil => %{type: :number}}) == [{[nil], {:type, :name}}]

      assert faults(%{:v => %{type: :number}, "v" => %{type: :number}}) ==
               [{["v"], {:duplicate_field, :v}}]
    end

    @tag verifies: "schema-faults"
    test "a schema is a map of description maps" do
      assert Schema.new(v: %{type: :number}) == {:error, [{[], {:type, :schema}}]}
      assert faults(%{v: [type: :number]}) == [{[:v], {:type, :description}}]
    end

    @tag verifies: "schema-faults"
    test "every fault is reported, by path" do
      errors = faults(%{a: %{}, b: %{type: :number, fill: "#000"}})
      assert errors == [{[:a, :type], :required}, {[:b, :fill], {:color_key, :fill}}]
    end

    @tag verifies: "schema-faults"
    test "new!/1 raises with every fault formatted" do
      error = assert_raise ArgumentError, fn -> Schema.new!(%{a: %{}, b: %{type: :x}}) end
      assert error.message =~ "a.type: is required"
      assert error.message =~ "b.type: must be one of :time"
    end

    @tag verifies: "schema-faults"
    test "every fault formats as a line" do
      for {path, reason} <- [
            {[], {:type, :schema}},
            {[1], {:type, :name}},
            {[:v], {:type, :description}},
            {[:v, :unit], {:type, :unit}},
            {[:v, :label], {:type, :string}},
            {[:v, :target], {:type, :number}},
            {[:v, :continuity], {:type, :positive}},
            {[:v, :order], {:type, :order}},
            {[:v, :status], {:type, :status}},
            {["v"], {:duplicate_field, :v}},
            {[:v, :order, 2], :duplicate},
            {[:v, :status, "down"], :not_in_order}
          ] do
        assert is_binary(Schema.format_error({path, reason}))
      end

      assert Schema.format_error({[:v, :order, 2], :duplicate}) == "v.order[2]: is listed twice"
    end
  end

  describe "new/1: a measure is checked against the vocabulary" do
    @tag verifies: "schema-measure"
    test "a misspelled unit is refused at the field's unit, in parse/1's words" do
      assert faults(%{latency: %{type: :number, unit: "mss"}}) ==
               [{[:latency, :unit], {:unit, "mss", {:unknown_atom, "mss"}}}]

      assert Schema.format_error({[:latency, :unit], {:unit, "mss", {:unknown_atom, "mss"}}}) ==
               ~s(latency.unit: "mss" is not a UCUM unit this vocabulary reads \(spec/03 §1\))
    end

    @tag verifies: "schema-measure"
    test "a symbol a person types is not a code" do
      assert [{[:v, :unit], {:unit, "°C", _reason}}] = faults(%{v: %{type: :number, unit: "°C"}})
      assert {:ok, _} = Schema.new(%{v: %{type: :number, unit: "Cel"}})
    end

    @tag verifies: "schema-measure"
    test "an unknown quantity is refused at the field's quantity" do
      assert faults(%{v: %{type: :number, quantity: :sheep_per_hour}}) ==
               [{[:v, :quantity], {:unknown_quantity, :sheep_per_hour}}]

      assert Schema.format_error({[:v, :quantity], {:unknown_quantity, :sheep_per_hour}}) =~
               "v.quantity: :sheep_per_hour is not a quantity"
    end

    @tag verifies: "schema-measure"
    test "a unit that does not measure its quantity is refused at the quantity, as resolve/1 says" do
      assert faults(%{v: %{type: :number, unit: "By", quantity: :duration}}) ==
               [{[:v, :quantity], {:quantity, :duration, "By"}}]

      assert Schema.format_error({[:v, :quantity], {:quantity, :duration, "By"}}) ==
               ~s(v.quantity: unit "By" does not measure :duration \(spec/03 §13\))
    end

    @tag verifies: "schema-measure"
    test "a pair is checked only once each of it is good" do
      assert faults(%{v: %{type: :number, unit: "mss", quantity: :duration}}) ==
               [{[:v, :unit], {:unit, "mss", {:unknown_atom, "mss"}}}]

      assert faults(%{v: %{type: :number, unit: "By", quantity: :durration}}) ==
               [{[:v, :quantity], {:unknown_quantity, :durration}}]

      # A bad label beside a bad pair hides neither.
      assert faults(%{v: %{type: :number, unit: "By", quantity: :duration, label: 1}}) ==
               [{[:v, :label], {:type, :string}}, {[:v, :quantity], {:quantity, :duration, "By"}}]
    end

    @tag verifies: "schema-measure"
    test "every quantity in its base unit, and the units feeds write, pass" do
      for q <- Macaw.Data.Quantity.all() do
        unit = Macaw.Data.Quantity.base_unit(q) || "{iso4217:USD}"
        assert {:ok, _} = Schema.new(%{v: %{type: :number, unit: unit, quantity: q}})
      end

      for unit <- ~w(ms % 1 {request}/s {request} kW.h MiBy [lb_av] {iso4217:EUR}/kW/h) do
        assert {:ok, _} = Schema.new(%{v: %{type: :number, unit: unit}})
      end

      assert {:ok, _} = Schema.new(%{v: %{type: :number, unit: "%", quantity: :ratio}})
      assert {:ok, _} = Schema.new(%{v: %{type: :number, unit: "{request}", quantity: :count}})
    end

    @tag verifies: "schema-measure"
    test "Telemetry's schemas pass: every unit it maps, with the quantity it implies" do
      for unit <- [
            :second,
            :millisecond,
            :microsecond,
            :nanosecond,
            :byte,
            :kilobyte,
            :megabyte,
            :gigabyte,
            :percent
          ] do
        {:ok, code} = Macaw.Data.Unit.from_telemetry(unit)
        measure = %{unit: code, quantity: Macaw.Data.Quantity.of_unit(code)}
        description = Map.reject(Map.put(measure, :type, :number), fn {_k, v} -> v == nil end)
        assert {:ok, _} = Schema.new(%{value: description}), "#{inspect(unit)} → #{code}"
      end
    end
  end

  describe "fetch/2 and fetch/3" do
    @tag verifies: "schema-fetch"
    test "by either spelling, never creating an atom" do
      schema = Schema.new!(%{"latency" => %{type: :number, unit: "ms"}, t: %{type: :time}})
      assert Schema.fetch(schema, :latency) == {:ok, %{type: :number, unit: "ms"}}
      assert Schema.fetch(schema, "t") == {:ok, %{type: :time}}
      assert Schema.fetch(schema, "never_an_atom_#{System.unique_integer([:positive])}") == :error
      assert Schema.fetch(schema, :latency, :unit) == {:ok, "ms"}
      assert Schema.fetch(schema, :latency, :label) == :error
      assert Schema.fetch(schema, :other, :unit) == :error
    end
  end

  describe "identity" do
    @tag verifies: "schema-identity"
    test "one field, or several, may declare it; a :category, :text or :number one" do
      for type <- [:category, :text, :number] do
        assert {:ok, schema} = Schema.new(%{id: %{type: type, identity: true}})
        assert Schema.identity(schema) == ["id"]
      end

      assert {:ok, schema} =
               Schema.new(%{
                 "iface" => %{type: :category, identity: true},
                 host: %{type: :category, identity: true},
                 t: %{type: :time},
                 bytes: %{type: :number}
               })

      assert Schema.identity(schema) == ["host", "iface"]
    end

    @tag verifies: "schema-identity"
    test "new/1 keeps the identity fields, and a struct assembled by hand derives them" do
      schema =
        Schema.new!(%{
          iface: %{type: :category, identity: true},
          host: %{type: :category, identity: true}
        })

      assert schema.identity == ["host", "iface"]
      by_hand = %Schema{fields: schema.fields, version: schema.version}
      assert by_hand.identity == nil
      assert Schema.identity(by_hand) == ["host", "iface"]

      assert Schema.identity(by_hand, %{host: "mx1", iface: "eth0"}) == %{
               "host" => "mx1",
               "iface" => "eth0"
             }
    end

    @tag verifies: "schema-identity"
    test "never on a :time field, and only a boolean" do
      assert faults(%{t: %{type: :time, identity: true}}) ==
               [{[:t, :identity], {:invalid_for, :time}}]

      assert faults(%{id: %{type: :category, identity: "yes"}}) ==
               [{[:id, :identity], {:type, :boolean}}]

      assert Schema.format_error({[:t, :identity], {:invalid_for, :time}}) ==
               "t.identity: is not a key a :time field takes"
    end

    @tag verifies: "schema-identity"
    test "false is absent: one schema, one version, and nothing declared" do
      said = Schema.new!(%{id: %{type: :category, identity: false}})
      unsaid = Schema.new!(%{id: %{type: :category}})

      assert said == unsaid
      assert Schema.identity(said) == []
      assert Schema.fetch(said, :id, :identity) == :error
    end

    @tag verifies: "schema-identity"
    test "a row's identity: bare for one field, a map for several, nil when it lacks one" do
      none = Schema.new!(%{name: %{type: :category}})
      one = Schema.new!(%{"car" => %{type: :number, identity: true}, x: %{type: :number}})

      two =
        Schema.new!(%{
          host: %{type: :category, identity: true},
          iface: %{type: :category, identity: true}
        })

      assert Schema.identity(none, %{name: "api"}) == nil
      assert Schema.identity(one, %{car: 7, x: 1.5}) == 7
      assert Schema.identity(one, %{"car" => 7}) == 7
      assert Schema.identity(one, %{x: 1.5}) == nil

      assert Schema.identity(two, %{"host" => "mx1", iface: "eth0"}) == %{
               "host" => "mx1",
               "iface" => "eth0"
             }

      assert Schema.identity(two, %{host: "mx1", iface: nil}) == nil
    end
  end

  describe "compatibility/2" do
    @live Schema.new!(%{
            t: %{type: :time, label: "Time"},
            value: %{type: :number, unit: "ms", quantity: :duration, label: "Panel load time"},
            panel: %{type: :category}
          })

    @tag verifies: "schema-compatibility"
    test "names compare as strings; labels, facts and extra fields are not compared" do
      store =
        Schema.new!(%{
          "t" => %{type: :time},
          "value" => %{
            type: :number,
            unit: "s",
            quantity: :duration,
            label: "metresis.panel.load.duration.max",
            polarity: :lower_is_better,
            bounds: [0.0, nil],
            metric_kind: :gauge
          },
          "panel" => %{type: :category, label: "panel"},
          "host" => %{type: :category}
        })

      assert Schema.compatibility(@live, store) == :ok
      # Not symmetric: the store's extra field is missing from the live schema.
      assert Schema.compatibility(store, @live) == {:error, [{"host", :missing}]}
    end

    @tag verifies: "schema-compatibility"
    test "every fault, by the field's string, ordered by name" do
      other =
        Schema.new!(%{"t" => %{type: :number}, "value" => %{type: :number, unit: "By"}})

      assert Schema.compatibility(@live, other) ==
               {:error,
                [
                  {"panel", :missing},
                  {"t", {:type, :time, :number}},
                  {"value", {:unit, "ms", "By"}}
                ]}
    end

    @tag verifies: "schema-compatibility"
    test "units: two absent agree, one absent facing a present one and two currencies do not" do
      bare = Schema.new!(%{v: %{type: :number}})
      ms = Schema.new!(%{v: %{type: :number, unit: "ms"}})
      usd = Schema.new!(%{v: %{type: :number, unit: "{iso4217:USD}"}})
      eur = Schema.new!(%{v: %{type: :number, unit: "{iso4217:EUR}"}})

      assert Schema.compatibility(bare, bare) == :ok
      assert Schema.compatibility(ms, bare) == {:error, [{"v", {:unit, "ms", nil}}]}
      assert Schema.compatibility(bare, ms) == {:error, [{"v", {:unit, nil, "ms"}}]}

      assert Schema.compatibility(usd, eur) ==
               {:error, [{"v", {:unit, "{iso4217:USD}", "{iso4217:EUR}"}}]}

      assert Schema.compatibility(usd, usd) == :ok
    end

    @tag verifies: "schema-compatibility"
    test "identity: different declared fields are a fault, whichever schema declares" do
      host = %{type: :category, identity: true}
      hosts = Schema.new!(%{host: host, v: %{type: :number}})
      bare = Schema.new!(%{host: %{type: :category}, v: %{type: :number}})
      ifaces = Schema.new!(%{"host" => host, "iface" => host, "v" => %{type: :number}})

      assert Schema.compatibility(hosts, hosts) == :ok
      assert Schema.compatibility(hosts, bare) == {:error, [{"host", {:identity, true, false}}]}
      assert Schema.compatibility(bare, hosts) == {:error, [{"host", {:identity, false, true}}]}
      # Extra fields are not faults, but an extra identity field is.
      assert Schema.compatibility(hosts, ifaces) ==
               {:error, [{"iface", {:identity, false, true}}]}

      assert Schema.compatibility(ifaces, hosts) ==
               {:error, [{"iface", :missing}]}
    end
  end

  describe "version/1: the kernel's digest" do
    @tag verifies: "schema-version"
    test "is pinned: a change of encoding is a deliberate, visible change" do
      # macaw_layers 0.3.0's term digest of the schema's term (its spec/01 §7 encoding).
      assert Schema.version(Schema.new!(%{v: %{type: :number}})) ==
               "5cae6d9dd503007869b92cbf89f1983b6b8511eaa1e8f4f1f698abd6b02f0c0a"

      assert Schema.version(Schema.new!(@full)) ==
               "66fddf97b5cab061875480b0f727729d35b39aab07291b3e1b33232d8bf194aa"
    end

    @tag verifies: "schema-version"
    test "is the kernel's digest of the schema's term" do
      schema = Schema.new!(%{v: %{type: :number}, s: %{type: :category, status: %{ok: :good}}})

      assert Schema.version(schema) ==
               Macaw.Layers.Document.digest(%{
                 "fields" => %{
                   "v" => %{type: :number},
                   "s" => %{type: :category, status: %{"ok" => "good"}}
                 }
               })

      # Never of a representation: the JSON form is an adapter the version does not go through.
      refute Schema.version(schema) ==
               Macaw.Layers.Document.digest(%{"fields" => Schema.to_map(schema)})
    end

    @tag verifies: "schema-version"
    test "is the same whichever way a field name is spelled" do
      assert Schema.new!(%{v: %{type: :number}}).version ==
               Schema.new!(%{"v" => %{type: :number}}).version
    end

    @tag verifies: "schema-version"
    property "is independent of the order the maps were built in" do
      entries = Enum.flat_map(@full, fn {name, d} -> Enum.map(d, &{name, &1}) end)

      check all(shuffled <- shuffled(entries)) do
        rebuilt =
          Enum.reduce(shuffled, %{}, fn {name, {k, v}}, acc ->
            v = if is_map(v), do: v |> Enum.shuffle() |> Map.new(), else: v
            Map.update(acc, name, %{k => v}, &Map.put(&1, k, v))
          end)

        assert Schema.new!(rebuilt).version == Schema.new!(@full).version
      end
    end

    @tag verifies: "schema-version"
    test "changes with any change of content" do
      base = Schema.new!(@full).version

      variants = [
        put_in(@full, [:latency, :label], "Latency"),
        put_in(@full, [:latency, :unit], "ms"),
        put_in(@full, [:latency, :target], 0.3),
        put_in(@full, [:latency, :continuity], 60.0),
        put_in(@full, [:state, :order], ["ok", "fail", "warn"]),
        put_in(@full, [:state, :status, "warn"], :bad),
        Map.delete(@full, :route),
        put_in(@full, [:route, :type], :category),
        Map.put(@full, :route2, %{type: :text})
      ]

      versions = Enum.map(variants, &Schema.new!(&1).version)
      refute base in versions
      assert length(Enum.uniq(versions)) == length(variants)
    end

    @tag verifies: "schema-version"
    test "a string state and the atom state are one value, by its spelling" do
      # `new/1` writes each as its string, so the version is the same through JSON too: a
      # delivery read on another node names a version its reader can resolve.
      a = Schema.new!(%{s: %{type: :category, order: ["ok"], status: %{"ok" => :good}}})
      b = Schema.new!(%{s: %{type: :category, order: [:ok], status: %{ok: "good"}}})
      assert a.version == b.version
      refute a.version == Schema.new!(%{s: %{type: :category, order: ["OK"]}}).version
    end

    @tag verifies: "schema-version"
    test "names, states and roles in either spelling: one schema, one version" do
      atoms =
        Schema.new!(%{
          state: %{
            type: :category,
            values: [%{value: :ok, name: "OK"}, :warn, :fail, 3],
            order: [:ok, :warn, :fail],
            status: %{ok: :good, warn: :warning, fail: :bad}
          },
          host: %{type: :category, identity: true},
          t: %{type: :time}
        })

      strings =
        Schema.new!(%{
          "state" => %{
            type: :category,
            values: [%{value: "ok", name: "OK"}, "warn", "fail", 3],
            order: ["ok", "warn", "fail"],
            status: %{"ok" => "good", "warn" => "warning", "fail" => "bad"}
          },
          "host" => %{type: :category, identity: true},
          "t" => %{type: :time}
        })

      assert atoms == strings
      assert atoms.version == strings.version
      assert {:ok, ^atoms} = Schema.from_json(Schema.to_json(atoms))
    end

    @tag verifies: "schema-version"
    test "a state in both spellings is one state, listed or named twice" do
      assert {:ok, _} =
               Schema.new(%{s: %{type: :category, order: [:ok], status: %{"ok" => :good}}})

      assert {:ok, _} = Schema.new(%{s: %{type: :category, values: ["ok"], order: [:ok]}})

      assert faults(%{s: %{type: :category, order: [:ok, "ok"]}}) ==
               [{[:s, :order, 1], :duplicate}]

      assert faults(%{s: %{type: :category, values: [%{value: :ok, name: "OK"}, "ok"]}}) ==
               [{[:s, :values, 1], :duplicate}]

      assert faults(%{s: %{type: :category, status: %{:ok => :good, "ok" => :bad}}}) ==
               [{[:s, :status, "ok"], :duplicate}]
    end

    @tag verifies: "schema-version"
    test "a typed color or a color struct in a value entry never crashes new/1" do
      # The version never goes through the JSON form, so building one answers rather than
      # raises: a color term is a data color (spec/01 §1.7), and a struct that is not a
      # literal is refused as no color.
      red = %Color{r: 255.0, g: 0.0, b: 0.0, opacity: 1.0}

      for color <- [{:color, :good}, red] do
        entry = %{s: %{type: :category, values: [%{value: "ok", color: color}]}}
        assert {:ok, %Schema{}} = Schema.new(entry)
      end

      assert faults(%{
               s: %{type: :category, values: [%{value: "ok", color: %Color{r: 255, g: 0, b: 0}}]}
             }) == [{[:s, :values, 0, :color], {:type, :color}}]
    end

    @tag verifies: "schema-data-colors"
    test "a typed color's names count by their spelling: one color, one version" do
      atoms =
        Schema.new!(%{
          s: %{
            type: :category,
            values: [
              %{value: "ok", color: {:color, :good}},
              %{value: "warn", color: {:alpha, {:blend, [{:color, :warning}, ~RGB"#fff"]}, 0.5}},
              %{value: "fail", color: {:contrast, {:ramp, :status, 0.2}}}
            ]
          }
        })

      strings =
        Schema.new!(%{
          s: %{
            type: :category,
            values: [
              %{value: "ok", color: Color.color("good")},
              %{value: "warn", color: {:alpha, {:blend, [{:color, "warning"}, ~RGB"#fff"]}, 0.5}},
              %{value: "fail", color: {:contrast, {:ramp, "status", 0.2}}}
            ]
          }
        })

      assert atoms == strings
      assert atoms.version == strings.version
    end

    defp shuffled(list), do: StreamData.map(StreamData.integer(), fn _ -> Enum.shuffle(list) end)
  end

  describe "Cache" do
    setup do
      v1 = Schema.new!(%{v: %{type: :number, unit: "s"}})
      v2 = Schema.new!(%{v: %{type: :number, unit: "ms"}})
      %{v1: v1, v2: v2}
    end

    defp counting(answer) do
      test = self()

      fn feed ->
        send(test, {:described, feed})
        answer
      end
    end

    @tag verifies: "schema-cache"
    test "a cached version costs nothing: describe is not called", %{v1: v1} do
      cache = Cache.new([{:latency, v1}])

      assert {:ok, ^v1, ^cache} =
               Cache.resolve(cache, :latency, v1.version, counting({:error, :not_asked}))

      refute_received {:described, _}
    end

    @tag verifies: "schema-cache"
    test "an unknown version calls describe once, then is cached", %{v1: v1} do
      describe = counting({:ok, v1})
      {:ok, ^v1, cache} = Cache.resolve(Cache.new(), :latency, v1.version, describe)
      assert_received {:described, :latency}

      {:ok, ^v1, ^cache} = Cache.resolve(cache, :latency, v1.version, describe)
      refute_received {:described, _}
      assert Cache.fetch(cache, :latency, v1.version) == {:ok, v1}
    end

    @tag verifies: "schema-cache"
    test "the same version of another feed is another entry", %{v1: v1} do
      cache = Cache.new([{:latency, v1}])
      assert Cache.fetch(cache, :other, v1.version) == :error
    end

    @tag verifies: "schema-cache"
    test "describe answering another version is reported and its answer cached",
         %{v1: v1, v2: v2} do
      assert {:error, {:schema_version, :latency, v1_version, v2_version}, cache} =
               Cache.resolve(Cache.new(), :latency, v1.version, counting({:ok, v2}))

      assert {v1_version, v2_version} == {v1.version, v2.version}
      assert Cache.fetch(cache, :latency, v2.version) == {:ok, v2}
    end

    @tag verifies: "schema-cache"
    test "describe failing, and no describe at all", %{v1: v1} do
      cache = Cache.new()

      assert Cache.resolve(cache, :latency, v1.version, fn _ -> {:error, :down} end) ==
               {:error, {:describe, :latency, :down}, cache}

      assert Cache.resolve(cache, :latency, v1.version, nil) ==
               {:error, {:unknown_schema, :latency, v1.version}, cache}
    end

    @tag verifies: "schema-cache"
    test "put/3 keys a schema by its own version", %{v1: v1, v2: v2} do
      cache = Cache.new() |> Cache.put(:f, v1) |> Cache.put(:f, v2)
      assert Cache.fetch(cache, :f, v1.version) == {:ok, v1}
      assert Cache.fetch(cache, :f, v2.version) == {:ok, v2}
    end
  end

  describe "the point type and the window field" do
    @tag verifies: "schema-point"
    test "a :point field is a position: label, continuity and window, nothing numeric or categorical" do
      assert {:ok, schema} = Schema.new(%{where: %{type: :point, label: "Where", continuity: 5}})
      assert Schema.fetch(schema, :where, :type) == {:ok, :point}

      assert faults(%{p: %{type: :point, unit: "m", order: ["a"], identity: true}}) == [
               {[:p, :identity], {:invalid_for, :point}},
               {[:p, :order], {:invalid_for, :point}},
               {[:p, :unit], {:invalid_for, :point}}
             ]
    end

    @tag verifies: "schema-window-field"
    test "the window field: the marked one, else the only time field, else none" do
      field = &Schema.window_field(Schema.new!(&1))

      assert field.(%{t: %{type: :time}, v: %{type: :number}}) == "t"
      assert field.(%{t: %{type: :time}, tick: %{type: :number, window: true}}) == "tick"
      assert field.(%{a: %{type: :time}, b: %{type: :time}}) == nil
      assert field.(%{a: %{type: :time}, b: %{type: :time, window: true}}) == "b"
      assert field.(%{t: %{type: :time, window: false}}) == nil
      assert field.(%{v: %{type: :number}}) == nil
      assert field.(%{p: %{type: :point, window: true}}) == "p"

      assert faults(%{a: %{type: :time, window: true}, b: %{type: :point, window: true}}) ==
               [{[:b, :window], {:duplicate_window, :a}}]
    end

    @tag verifies: "schema-window-field"
    test "the window that applies: a range over time or number, a box over a point" do
      kind = &Schema.window_kind(Schema.new!(&1))
      assert kind.(%{t: %{type: :time}}) == :range
      assert kind.(%{n: %{type: :number, window: true}}) == :range
      assert kind.(%{p: %{type: :point, window: true}}) == :box
      assert kind.(%{v: %{type: :number}}) == nil
    end
  end

  describe "data colors" do
    # Color terms that are data colors: literals, and typed colors whose literal operands are
    # colors and whose names are a theme's.
    @colors [
      ~RGB"#2e7d32",
      ~RGB"#2e7d32cc",
      ~RGB"rebeccapurple",
      Color.rgb(59.5, 111, 168, 0.3),
      {:color, "good"},
      {:color, :good},
      {:series, 3},
      {:ramp, "status", 0.5},
      {:alpha, {:color, "bad"}, 0.74},
      {:intensity, ~RGB"#c62828", 0.5},
      {:shade, {:color, "info"}, 700},
      {:blend, [{:intensity, {:color, "blue"}, 0.65}, ~RGB"red"]},
      {:contrast, :under},
      {:contrast, {:color, "bad"}}
    ]

    # Terms that are not: text in every CSS form, a bare role, malformed typed colors.
    @not_colors [
      "#fff",
      "#2e7d32",
      "red",
      "Orange",
      "rgb(1, 2, 3)",
      "good",
      "",
      :good,
      :orange,
      3,
      nil,
      {:color, ""},
      {:color, "Good"},
      {:color, "3d"},
      {:ramp, "Status", 0.5},
      {:alpha, "#c62828", 0.5},
      {:alpha, {:color, "bad"}, 1.5},
      {:blend, []},
      {:blend, [{:color, "a"}, "red"]},
      %Color{r: 255, g: 0, b: 0, opacity: 1},
      %{r: 255.0, g: 0.0, b: 0.0, opacity: 1.0}
    ]

    @tag verifies: "schema-data-colors"
    test "a data color is a color term, a literal or a typed color; never a string" do
      for c <- @colors, do: assert(Schema.color?(c), inspect(c))
      for c <- @not_colors, do: refute(Schema.color?(c), inspect(c))
    end

    @tag verifies: "schema-data-colors"
    test "a value entry's color is a color term, and a string there is {:type, :color}" do
      for c <- @colors do
        assert {:ok, schema} =
                 Schema.new(%{s: %{type: :category, values: [%{value: "a", color: c}]}})

        assert Map.keys(Schema.value_colors(schema, :s)) == ["a"]
      end

      for c <- @not_colors do
        assert faults(%{s: %{type: :category, values: [%{value: "a", color: c}]}}) ==
                 [{[:s, :values, 0, :color], {:type, :color}}],
               inspect(c)
      end
    end

    @tag verifies: "schema-data-colors"
    test "a :color parameter takes the same color terms" do
      for c <- @colors, do: assert(Macaw.Data.Parameter.conforms?(:color, c), inspect(c))
      for c <- @not_colors, do: refute(Macaw.Data.Parameter.conforms?(:color, c), inspect(c))
    end

    @tag verifies: "schema-data-colors"
    test "the fault names the input edge: Color.parse!/1 and ~RGB" do
      line = Schema.format_error({[:s, :values, 0, :color], {:type, :color}})
      assert line =~ "Macaw.Layers.Color.parse!/1"
      assert line =~ "~RGB"
      assert line =~ "a string is never a color"
    end
  end

  describe "the JSON form" do
    @tag verifies: "schema-json-form"
    test "the map form is sorted pairs, every name, state, role and word by its spelling" do
      schema =
        Schema.new!(%{
          "where" => %{type: :point, window: true},
          state: %{
            type: :category,
            order: [:ok, "warn"],
            status: %{:ok => :good, "warn" => :warning},
            values: [
              %{value: :ok, name: "OK", color: ~RGB"#2e7d32"},
              %{value: "warn", color: {:alpha, {:color, :bad}, 0.74}}
            ]
          },
          latency: %{
            type: :number,
            unit: "s",
            quantity: :duration,
            bounds: [0, nil],
            identity: false
          }
        })

      assert Schema.to_map(schema) == [
               [
                 "latency",
                 %{
                   "type" => "number",
                   "unit" => "s",
                   "quantity" => "duration",
                   "bounds" => [0, nil]
                 }
               ],
               [
                 "state",
                 %{
                   "type" => "category",
                   "order" => ["ok", "warn"],
                   "status" => [["ok", "good"], ["warn", "warning"]],
                   "values" => [
                     %{"value" => "ok", "name" => "OK", "color" => %{"$rgb" => "#2e7d32"}},
                     %{"value" => "warn", "color" => %{"$alpha" => [%{"$color" => "bad"}, 0.74]}}
                   ]
                 }
               ],
               ["where", %{"type" => "point", "window" => true}]
             ]

      assert JSON.decode!(Schema.to_json(schema)) == Schema.to_map(schema)
    end

    @tag verifies: "schema-json-round-trip"
    test "a literal and a typed color in an entry round-trip, with an equal version" do
      colors = [
        ~RGB"#2e7d32",
        ~RGB"#3b6fa880",
        Color.rgb(59.5, 111, 168),
        {:color, :good},
        {:series, 2},
        {:ramp, "status", 0.25},
        {:alpha, {:blend, [{:intensity, {:color, "bad"}, 0.65}, ~RGB"#fff"]}, 0.5},
        {:shade, {:color, "info"}, 300},
        {:contrast, :under},
        {:contrast, {:lighten, ~RGB"#c62828", 0.3}}
      ]

      values = for {c, i} <- Enum.with_index(colors), do: %{value: "v#{i}", color: c}
      schema = Schema.new!(%{s: %{type: :category, values: values}})

      assert {:ok, back} = Schema.from_json(Schema.to_json(schema))
      assert back == schema
      assert Schema.version(back) == Schema.version(schema)
      assert Map.values(Schema.value_colors(back, :s)) |> Enum.all?(&Schema.color?/1)
    end

    @tag verifies: "schema-json-read"
    test "a color written as text reads back refused: a string is never a color" do
      for text <- [
            ~s("#2e7d32"),
            ~s("red"),
            ~s({"$rgb":"red"}),
            ~s({"$color":""}),
            ~s({"$hex":"#fff"})
          ] do
        json = ~s([["s",{"type":"category","values":[{"value":"a","color":#{text}}]}]])

        assert Schema.from_json(json) == {:error, [{["s", :values, 0, :color], {:type, :color}}]},
               text
      end
    end

    @tag verifies: "schema-json-read"
    test "from_json/2 reads words through their vocabularies, names and states as strings, and refuses by new/1" do
      json =
        ~s([["v",{"type":"number","quantity":"duration","polarity":"lower_is_better","metric_kind":"gauge"}],["s",{"type":"category","order":["ok"],"status":[["ok","good"]]}]])

      {:ok, schema} = Schema.from_json(json)

      assert Schema.fetch(schema, "v") ==
               {:ok,
                %{
                  type: :number,
                  quantity: :duration,
                  polarity: :lower_is_better,
                  metric_kind: :gauge
                }}

      assert Schema.fetch(schema, "s") ==
               {:ok, %{type: :category, order: ["ok"], status: %{"ok" => "good"}}}

      # A word outside its vocabulary stays a string, and new/1 refuses it by name.
      assert Schema.from_json(~s([["v",{"type":"float","scale":2}]])) ==
               {:error,
                [
                  {["v", :type], {:enum, [:time, :number, :category, :text, :color, :point]}},
                  {["v", "scale"], :unknown_key}
                ]}

      assert Schema.from_json(~s({"v":1})) == {:error, [{[], {:type, :schema}}]}
      assert Schema.from_json("[") |> elem(0) == :error

      assert Schema.from_json(~s([["v",{"type":"number"}]]), limits: [bytes: 5]) ==
               {:error, [{[], {:limit, :bytes, 5, 25}}]}

      assert {:error, [{_, {:limit, :depth, 2, 3}}]} =
               Schema.from_json(~s([["v",{"type":"number"}]]), limits: [depth: 2])
    end

    @tag verifies: "schema-json-round-trip"
    property "a schema read back from its JSON form has its version and its JSON" do
      check all(fields <- schema_fields()) do
        schema = Schema.new!(fields)
        assert {:ok, back} = Schema.from_json(Schema.to_json(schema))
        assert Schema.version(back) == Schema.version(schema)
        assert Schema.to_json(back) == Schema.to_json(schema)
        # Spelled with strings, as JSON spells it, the schema is read back exactly.
        assert Schema.from_json(Schema.to_json(back)) == {:ok, back}
      end
    end
  end

  # Generated valid schemas: names, types and the keys each type takes.
  defp schema_fields do
    name = map(string(:alphanumeric, min_length: 1, max_length: 6), &("f" <> &1))

    state =
      one_of([
        string(:alphanumeric, min_length: 1, max_length: 4),
        member_of([:a, :b, :c]),
        integer(0..9)
      ])

    description =
      one_of([
        fixed_map(%{type: constant(:time)}),
        map(
          {member_of(["s", "ms", "By", "%", nil]),
           member_of([:higher_is_better, :lower_is_better, :neutral]), float()},
          fn {unit, polarity, target} ->
            %{type: :number, polarity: polarity, target: target}
            |> then(&if(unit, do: Map.put(&1, :unit, unit), else: &1))
          end
        ),
        map(
          uniq_list_of(state, min_length: 1, max_length: 4, uniq_fun: &to_string/1),
          fn states ->
            %{type: :category, order: states, values: states, label: "States"}
          end
        ),
        bind(
          uniq_list_of(state, min_length: 1, max_length: 4, uniq_fun: &to_string/1),
          fn states ->
            map(list_of(data_color(), length: length(states)), fn colors ->
              %{type: :category, values: Enum.zip_with(states, colors, &%{value: &1, color: &2})}
            end)
          end
        ),
        fixed_map(%{type: constant(:text), identity: boolean()}),
        fixed_map(%{type: constant(:point), continuity: float(min: 0.1, max: 100.0)})
      ])

    map_of(name, description, max_length: 5)
  end

  # Generated data colors: literals, 8-bit exact or not, and typed colors by either spelling.
  defp data_color do
    channel = integer(0..255)
    unit = float(min: 0.0, max: 1.0)
    role = member_of([:good, "bad", :warning, "info"])

    literal =
      one_of([
        map({channel, channel, channel}, fn {r, g, b} -> Color.rgb(r, g, b) end),
        map({float(min: 0.0, max: 255.0), channel, channel, unit}, fn {r, g, b, a} ->
          Color.rgb(r, g, b, a)
        end)
      ])

    typed =
      one_of([
        map(role, &{:color, &1}),
        map({role, unit}, fn {name, a} -> {:alpha, {:color, name}, a} end),
        map({literal, unit}, fn {c, t} -> {:intensity, c, t} end),
        map({role, literal}, fn {name, c} -> {:blend, [{:color, name}, c]} end)
      ])

    one_of([literal, typed])
  end
end
