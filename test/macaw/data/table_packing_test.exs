defmodule Macaw.Data.TablePackingTest do
  @moduledoc """
  `Macaw.Data.Table`'s packed columns (spec/01 §1.1, #16): each type's forms, their Arrow
  layout byte for byte, and that packing never changes a value.
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Macaw.Data.Table

  defp storage(table, name), do: elem(Map.fetch!(table.columns, name), 1)

  # A `DateTime` in any zone, built by its fields: no time-zone database is involved.
  defp zoned(%DateTime{} = utc, {time_zone, zone_abbr, utc_offset, std_offset}) do
    wall = DateTime.add(utc, utc_offset + std_offset, :second)

    %{
      wall
      | time_zone: time_zone,
        zone_abbr: zone_abbr,
        utc_offset: utc_offset,
        std_offset: std_offset
    }
  end

  @mst {"America/Denver", "MST", -25_200, 0}
  @mdt {"America/Denver", "MDT", -25_200, 3600}
  @cet {"Europe/Paris", "CET", 3600, 0}
  @utc {"Etc/UTC", "UTC", 0, 0}

  describe "numbers (spec/01 §1.1)" do
    @tag verifies: "table-numbers"
    test "integers are int64 and floats float64" do
      table = Table.new!([{:i, :number, [1, nil, -2 ** 63]}, {:f, :number, [1.5, nil, -0.0]}])
      assert {:int64, _, <<0b101>>} = storage(table, :i)
      assert {:float64, _, <<0b101>>} = storage(table, :f)
      assert Table.column(table, :i) === [1, nil, -2 ** 63]
      assert Table.column(table, :f) === [1.5, nil, -0.0]
    end

    @tag verifies: "table-numbers"
    test "a mixed column within ±2^53 reads back as given, through the integral bitmap" do
      table = Table.new!([{:n, :number, [1, 2.5, 3, nil, 4.0, 2 ** 53]}])

      assert {:integral, data, validity, integral} = storage(table, :n)
      assert byte_size(data) == 48
      # Values 0, 2 and 5 were integers; 4.0 stays a float.
      assert validity == <<0b00110111>> and integral == <<0b00100101>>
      assert Table.column(table, :n) === [1, 2.5, 3, nil, 4.0, 2 ** 53]
      # Any Arrow reader sees the floats.
      assert for(<<f::float-little-64 <- data>>, do: f) == [1.0, 2.5, 3.0, 0.0, 4.0, 2.0 ** 53]
    end

    @tag verifies: "table-numbers"
    test "an integer beyond ±2^53 beside a float makes a dense union of int64 and float64" do
      values = [2 ** 60, 1.5, nil, 3, -2 ** 63]
      table = Table.new!([{:n, :number, values}])

      assert {:union, types, offsets, {ints, ints_validity}, floats} = storage(table, :n)
      # A type id per slot (0 int64, 1 float64), an int32 offset into that child.
      assert types == <<0, 1, 0, 0, 0>>
      assert offsets == <<0::little-32, 0::little-32, 1::little-32, 2::little-32, 3::little-32>>

      assert ints ==
               <<2 ** 60::signed-little-64, 0::64, 3::signed-little-64,
                 -2 ** 63::signed-little-64>>

      # The gap is the int64 child's missing slot.
      assert ints_validity == <<0b1101>>
      assert floats == <<1.5::float-little-64>>
      assert Table.column(table, :n) === values

      # A slice reads through the offsets into the same children.
      assert Table.column(Table.slice(table, 1, 3), :n) === [1.5, nil, 3]
      assert Table.row(table, 4) === %{n: -2 ** 63}
    end

    @tag verifies: "table-numbers"
    test "an integer beyond int64 keeps the column a list" do
      table = Table.new!([{:n, :number, [2 ** 70, 1.5, nil]}])
      assert {:list, _} = storage(table, :n)
      assert Table.column_type(table, :n) == :number
      assert Table.column(table, :n) === [2 ** 70, 1.5, nil]

      assert Table.new([{:n, :number, [2 ** 70, "x"]}]) ==
               {:error, [{[:n, 1], {:type, :number}}]}
    end
  end

  describe "times (spec/01 §1.1)" do
    @tag verifies: "table-times"
    test "no time-zone database is configured: every zone below is read back by its fields" do
      assert Calendar.get_time_zone_database() == Calendar.UTCOnlyTimeZoneDatabase
    end

    @tag verifies: "table-times"
    test "an all-UTC column is a plain UTC timestamp of int64 microseconds" do
      values = [~U[2026-01-01 00:00:00.000001Z], nil, ~U[1969-12-31 23:59:59.000000Z]]
      table = Table.new!([{:t, :time, values}])

      assert {:utc, us, <<0b101>>, 6} = storage(table, :t)

      assert us ==
               <<1_767_225_600_000_001::signed-little-64, 0::64, -1_000_000::signed-little-64>>

      assert Table.column(table, :t) == values
    end

    @tag verifies: "table-times"
    test "one named zone across a daylight-saving change is two zone entries" do
      winter = zoned(~U[2026-01-15 19:00:00Z], @mst)
      summer = zoned(~U[2026-07-15 18:00:00Z], @mdt)
      values = [winter, summer, nil, winter]
      table = Table.new!([{:t, :time, values}])

      assert {:zoned, us, <<0b1011>>, 0, zones, codes} = storage(table, :t)
      assert zones == {@mst, @mdt}
      assert codes == <<0::little-32, 1::little-32, 0::little-32, 0::little-32>>
      assert Table.column(table, :t) == values
      assert winter.hour == 12 and summer.hour == 12

      # The struct's first field is the UTC instant, as any Arrow reader reads it.
      assert for(<<v::signed-little-64 <- us>>, do: v) ==
               [
                 DateTime.to_unix(winter, :microsecond),
                 DateTime.to_unix(summer, :microsecond),
                 0,
                 DateTime.to_unix(winter, :microsecond)
               ]
    end

    @tag verifies: "table-times"
    test "mixed zones read back as given, name, abbreviation and both offsets" do
      values = [
        zoned(~U[2026-03-01 08:30:00Z], @cet),
        ~U[2026-03-01 08:30:00Z],
        zoned(~U[2026-03-01 08:30:00Z], @mst),
        zoned(~U[0001-01-01 00:30:00Z], @cet),
        zoned(~U[-0044-03-15 12:00:00Z], @mdt)
      ]

      table = Table.new!([{:t, :time, values}])
      assert {:zoned, _, _, 0, {@cet, @utc, @mst, @mdt}, _} = storage(table, :t)
      assert Table.column(table, :t) == values
      assert Enum.map(Table.rows(table), & &1.t) == values
    end

    @tag verifies: "table-times"
    test "precision is on the column when uniform, else per value; 00Z and 00.000000Z stay distinct" do
      values = [
        ~U[2026-01-01 00:00:00Z],
        ~U[2026-01-01 00:00:00.000000Z],
        nil,
        ~U[2026-01-01 00:00:00.120Z]
      ]

      table = Table.new!([{:t, :time, values}])

      assert {:utc, _, _, <<0, 6, 0, 3>>} = storage(table, :t)
      assert Table.column(table, :t) == values
      refute Enum.at(Table.column(table, :t), 0) == Enum.at(Table.column(table, :t), 1)
      assert Table.column(Table.slice(table, 1, 3), :t) == Enum.slice(values, 1, 3)

      assert {:utc, _, _, 0} = storage(Table.new!([{:t, :time, [~U[2026-01-01 00:00:00Z]]}]), :t)
    end

    @tag verifies: "table-times"
    test "naive times and dates keep their own forms; mixed kinds keep the list" do
      naive = [~N[2026-01-01 12:00:00], nil, ~N[-0001-12-31 23:59:59.123456]]
      dates = [~D[2026-01-01], ~D[1969-12-31], nil, ~D[-0044-03-15]]

      table =
        Table.new!([
          {:n, :time, naive ++ [nil]},
          {:d, :time, dates},
          {:m, :time, [~D[2026-01-01], ~N[2026-01-01 00:00:00], nil, nil]}
        ])

      assert {:naive, _, <<0b0101>>, <<0, 0, 6, 0>>} = storage(table, :n)
      assert {:date, days, <<0b1011>>} = storage(table, :d)

      assert binary_part(days, 0, 8) ==
               <<20_454::signed-little-32, -1::signed-little-32>>

      assert {:list, _} = storage(table, :m)
      assert Table.column(table, :n) == naive ++ [nil]
      assert Table.column(table, :d) == dates

      assert Table.column(table, :m) == [~D[2026-01-01], ~N[2026-01-01 00:00:00], nil, nil]
    end
  end

  describe "text and categories (spec/01 §1.1)" do
    @tag verifies: "table-text"
    test "a text column is offsets and one data buffer, read back as given" do
      table =
        Table.new!([{:s, :text, ["héllo", nil, "", "wörld"]}, {:x, :text, [1, nil, :a, "b"]}])

      assert {:text, offsets, "héllowörld", <<0b1101>>} = storage(table, :s)
      assert for(<<o::little-32 <- offsets>>, do: o) == [0, 6, 6, 6, 12]
      assert Table.column(table, :s) == ["héllo", nil, "", "wörld"]

      # A value that is not a string keeps the column a list.
      assert {:list, _} = storage(table, :x)
      assert Table.column(table, :x) == [1, nil, :a, "b"]
    end

    @tag verifies: "table-text"
    test "an atom and its string are one code, read back as the string" do
      table = Table.new!([{:k, :category, [:ok, "ok", nil, "down", :down, :ok]}])

      assert {:dictionary, codes, <<0b111011>>, {offsets, "okdown"}, nil} = storage(table, :k)
      assert for(<<c::little-32 <- codes>>, do: c) == [0, 0, 0, 1, 1, 0]
      assert for(<<o::little-32 <- offsets>>, do: o) == [0, 2, 6]

      assert Table.column(table, :k) == ["ok", "ok", nil, "down", "down", "ok"]
      assert Enum.map(Table.rows(table), &Table.get(&1, "k")) == Table.column(table, :k)
      assert Table.row(table, 0) == %{k: "ok"}
    end

    @tag verifies: "table-text"
    test "nil, true and false are kept; a column mixing value types is a list" do
      table =
        Table.new!([
          {:b, :category, [true, nil, false, true]},
          {:m, :category, ["web", 1, :db, nil]},
          {:w, :category, [:on, true, "warn", false]}
        ])

      assert {:bool, <<0b1001>>, <<0b1101>>} = storage(table, :b)
      assert Table.column(table, :b) == [true, nil, false, true]

      # A number beside names keeps the list, its atoms still read as their strings.
      assert {:list, _} = storage(table, :m)
      assert Table.column_type(table, :m) == :category
      assert Table.column(table, :m) == ["web", 1, "db", nil]

      # Booleans beside names stay packed: the dictionary, and a side bitmap of which
      # slots are booleans (kind) and their values.
      assert {:dictionary, codes, <<0b1111>>, {_, "onwarn"}, {<<0b1010>>, <<0b0010>>}} =
               storage(table, :w)

      assert for(<<c::little-32 <- codes>>, do: c) == [0, 0, 1, 0]
      assert Table.column(table, :w) == ["on", true, "warn", false]
      assert Table.column(Table.slice(table, 1, 3), :w) == [true, "warn", false]
      assert Table.row(table, 3) == %{b: true, m: nil, w: false}
    end

    @tag verifies: "table-text"
    test "a category reads back the same whichever form holds it" do
      values = [:ok, true, "warn", nil, false, "ok", :down]
      packed = Table.new!([{:k, :category, values}])
      # A number at the end keeps this column a list; the values before it read the same.
      kept = Table.new!([{:k, :category, values ++ [1]}])
      # So does a string that is not UTF-8, which Arrow's utf8 dictionary can't hold.
      binary = Table.new!([{:k, :category, values ++ [<<0xFF>>]}])

      assert {:dictionary, _, _, _, {_, _}} = storage(packed, :k)
      assert {:list, _} = storage(kept, :k)
      assert {:list, _} = storage(binary, :k)

      expected = ["ok", true, "warn", nil, false, "ok", "down"]
      assert Table.column(packed, :k) == expected
      assert Table.column(kept, :k) == expected ++ [1]
      assert Table.column(binary, :k) == expected ++ [<<0xFF>>]
      assert Enum.map(Table.rows(kept), & &1.k) == expected ++ [1]
    end

    @tag verifies: "table-text"
    test "text that is not valid UTF-8 is Arrow binary, the same layout, never utf8" do
      values = ["joe", nil, <<0xC3>>, "mark"]
      table = Table.new!([{:s, :text, values}, {:u, :text, ["é", nil, "", "x"]}])

      assert {:binary, offsets, <<"joe", 0xC3, "mark">>, <<0b1101>>} = storage(table, :s)
      assert for(<<o::little-32 <- offsets>>, do: o) == [0, 3, 3, 4, 8]
      assert Table.column(table, :s) == values
      assert Table.column(Table.slice(table, 1, 3), :s) == [nil, <<0xC3>>, "mark"]

      # Two halves of one character are each invalid, though their bytes together are not.
      halves = Table.new!([{:s, :text, [<<0xC3>>, <<0xA9>>]}])
      assert {:binary, _, "é", _} = storage(halves, :s)
      assert Table.column(halves, :s) == [<<0xC3>>, <<0xA9>>]

      assert {:text, _, "éx", _} = storage(table, :u)
    end
  end

  # Fixtures written by hand from the Arrow columnar format specification
  # (https://arrow.apache.org/docs/format/Columnar.html), its own examples where it gives
  # one. Arrow leaves a missing value's slot unspecified; macaw writes zeros there.
  describe "the Arrow layout, byte for byte" do
    @tag verifies: "table-arrow"
    test "a validity bitmap is least-significant-bit first (Columnar §Validity bitmaps)" do
      # The specification's example: values = [0, 1, null, 2, null, 3] is 0b00101011.
      table = Table.new!([{:v, :number, [0, 1, nil, 2, nil, 3]}])
      assert {:int64, _, <<0b00101011>>} = storage(table, :v)

      # Over a byte: value i is bit (i rem 8) of byte (i div 8), the padding bits 0.
      values = [1, nil, 1, 1, nil, nil, nil, 1, 1, nil]
      table = Table.new!([{:v, :number, values}])
      assert {:int64, _, <<0x8D, 0x01>>} = storage(table, :v)

      # A slice's bitmap starts at its first value: values 3 to 8 are 1 0 0 0 1 1.
      assert {:int64, _, <<0b110001>>} = storage(Table.slice(table, 3, 6), :v)
    end

    @tag verifies: "table-arrow"
    test "an int64 column (Columnar §Fixed-size Primitive Layout)" do
      # The specification's example [1, null, 2, 4, 8], at 64 bits a slot.
      table = Table.new!([{:v, :number, [1, nil, 2, 4, 8]}])

      assert storage(table, :v) ==
               {:int64,
                <<1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 2, 0, 0, 0, 0, 0, 0, 0, 4, 0, 0,
                  0, 0, 0, 0, 0, 8, 0, 0, 0, 0, 0, 0, 0>>, <<0b00011101>>}
    end

    @tag verifies: "table-arrow"
    test "a float64 column (Columnar §Fixed-size Primitive Layout, IEEE 754 binary64)" do
      # 1.5 is 0x3FF8000000000000 and -2.0 0xC000000000000000, little-endian.
      table = Table.new!([{:v, :number, [1.5, nil, -2.0]}])

      assert storage(table, :v) ==
               {:float64,
                <<0, 0, 0, 0, 0, 0, 0xF8, 0x3F, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
                  0xC0>>, <<0b101>>}
    end

    @tag verifies: "table-arrow"
    test "a text column's offsets and data (Columnar §Variable-size Binary Layout)" do
      # The specification's example ['joe', null, null, 'mark'].
      table = Table.new!([{:s, :text, ["joe", nil, nil, "mark"]}])

      assert storage(table, :s) ==
               {:text, <<0, 0, 0, 0, 3, 0, 0, 0, 3, 0, 0, 0, 3, 0, 0, 0, 7, 0, 0, 0>>, "joemark",
                <<0b00001001>>}
    end

    @tag verifies: "table-arrow"
    test "a dictionary column's codes and dictionary (Columnar §Dictionary-encoded Layout)" do
      # The specification's example ['foo', 'bar', 'foo', 'bar', null, 'baz']: int32
      # indices [0, 1, 0, 1, null, 2] into the dictionary ['foo', 'bar', 'baz'].
      table = Table.new!([{:k, :category, ["foo", "bar", "foo", "bar", nil, "baz"]}])

      assert storage(table, :k) ==
               {:dictionary,
                <<0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 2, 0, 0, 0>>,
                <<0b00101111>>, {<<0, 0, 0, 0, 3, 0, 0, 0, 6, 0, 0, 0, 9, 0, 0, 0>>, "foobarbaz"},
                nil}
    end
  end

  # -- the property -----------------------------------------------------------------------

  @zones [@utc, @mst, @mdt, @cet, {"Asia/Kolkata", "IST", 19_800, 0}]
  @min_us DateTime.to_unix(~U[-0999-01-01 00:00:00Z], :microsecond)
  @max_us DateTime.to_unix(~U[9998-12-31 00:00:00Z], :microsecond)

  defp gappy(gen), do: one_of([gen, constant(nil)])

  defp precise(us, p) do
    unit = Integer.pow(10, 6 - p)
    Integer.floor_div(us, unit) * unit
  end

  defp utc_gen do
    gen all(us <- integer(@min_us..@max_us), p <- integer(0..6)) do
      t = DateTime.from_unix!(precise(us, p), :microsecond)
      %{t | microsecond: {elem(t.microsecond, 0), p}}
    end
  end

  defp zoned_gen, do: map({utc_gen(), member_of(@zones)}, fn {t, zone} -> zoned(t, zone) end)
  defp naive_gen, do: map(utc_gen(), &DateTime.to_naive/1)
  defp date_gen, do: map(utc_gen(), &DateTime.to_date/1)

  defp number_gen do
    one_of([
      integer(),
      float(),
      member_of([2 ** 53, -2 ** 53, 2 ** 60, -2 ** 63, 2 ** 63 - 1, 2 ** 64, -2 ** 70])
    ])
  end

  # A column of one type: its declared type and its values.
  defp column_gen do
    one_of([
      tuple({constant(:number), list_of(gappy(integer()))}),
      tuple({constant(:number), list_of(gappy(float()))}),
      tuple({constant(:number), list_of(gappy(number_gen()))}),
      tuple({constant(:time), list_of(gappy(utc_gen()))}),
      tuple({constant(:time), list_of(gappy(zoned_gen()))}),
      tuple({constant(:time), list_of(gappy(naive_gen()))}),
      tuple({constant(:time), list_of(gappy(date_gen()))}),
      tuple({constant(:text), list_of(gappy(string(:printable)))}),
      tuple({constant(:text), list_of(gappy(one_of([string(:printable), binary()])))}),
      tuple(
        {constant(:category),
         list_of(gappy(one_of([member_of([:ok, "ok", true, false]), string(:alphanumeric)])))}
      ),
      tuple({constant(:category), list_of(gappy(one_of([member_of([:ok, true]), binary()])))}),
      tuple(
        {constant(:category),
         list_of(
           gappy(one_of([member_of([:ok, :web, :db]), string(:alphanumeric, max_length: 3)]))
         )}
      ),
      tuple({constant(:category), list_of(gappy(boolean()))}),
      tuple({constant(:category), list_of(gappy(one_of([member_of([:ok, "ok"]), integer()])))}),
      tuple(
        {constant(:color),
         list_of(gappy(member_of([{:color, "good"}, {:alpha, {:color, "bad"}, 0.5}])))}
      ),
      tuple({constant(:point), list_of(gappy(tuple({float(), float()})))}),
      tuple({constant(:term), list_of(gappy(term()))})
    ])
  end

  # What a category column reads back, whatever form holds it: an atom as its string,
  # `nil`, `true` and `false` as themselves.
  defp read_back(:category, values),
    do:
      Enum.map(
        values,
        &if(is_atom(&1) and not is_boolean(&1) and &1 != nil, do: Atom.to_string(&1), else: &1)
      )

  defp read_back(_type, values), do: values

  describe "packing never changes a value" do
    @tag verifies: "table-faithful"
    property "generated columns of each type read back as given, categories as strings" do
      check all(
              columns <- list_of(column_gen(), min_length: 1, max_length: 4),
              start <- integer(0..10),
              count <- integer(0..10)
            ) do
        n = columns |> Enum.map(&length(elem(&1, 1))) |> Enum.min() |> max(1)
        columns = for {type, values} <- columns, do: {type, values ++ [nil]}

        named =
          for {{type, values}, i} <- Enum.with_index(columns),
              do: {"c#{i}", type, Enum.take(values, n)}

        table = Table.new!(named)
        expected = for {name, type, values} <- named, do: {name, read_back(type, values)}

        for {name, values} <- expected do
          assert Table.column(table, name) === values

          assert Table.column(Table.slice(table, start, count), name) ===
                   Enum.slice(values, start, count)
        end

        rows = Table.rows(table)
        assert length(rows) == n

        for {name, values} <- expected,
            do: assert(Enum.map(rows, &Map.fetch!(&1, name)) === values)

        # From the rows, with the types given: the same values (a DateTime column only,
        # since from/2 reads a naive time or a date as a DateTime at the edge).
        source =
          for {name, type, values} <- named,
              type != :time or Enum.all?(values, &(is_nil(&1) or is_struct(&1, DateTime))),
              into: %{},
              do: {name, values}

        types = Map.new(named, fn {name, type, _} -> {name, type} end)
        {:ok, from} = Table.from(source, types: types)

        for {name, values} <- expected,
            Map.has_key?(source, name),
            do: assert(Table.column(from, name) === values)
      end
    end
  end
end
