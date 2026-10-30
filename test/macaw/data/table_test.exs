defmodule Macaw.Data.TableTest do
  @moduledoc "`Macaw.Data.Table` (spec/01 §1.1): columnar typed data, and every source shape read at its edge."
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Macaw.Data.Table

  import Macaw.Data.Test.Storage, only: [storage: 2]

  doctest Table

  # Rows to a column map: the inverse `rows/1` is tested against.
  defp columns(rows) do
    names = rows |> Enum.flat_map(&Map.keys/1) |> Enum.uniq()
    Map.new(names, fn name -> {name, Enum.map(rows, &Map.fetch!(&1, name))} end)
  end

  defp row_gen do
    gen all(t <- integer(), v <- float(), s <- string(:alphanumeric)) do
      %{t: t, v: v, s: s}
    end
  end

  describe "rows/1 over lists" do
    @tag verifies: "table-sources"
    property "a list of rows is itself, zero-copy" do
      check all(rows <- list_of(row_gen())) do
        assert Table.rows(rows) === rows
      end
    end

    @tag verifies: "table-sources"
    property "rows(columns(rows)) == rows for a column map and a keyword list" do
      check all(rows <- list_of(row_gen(), min_length: 1)) do
        assert Table.rows(columns(rows)) == rows
        assert Table.rows(Map.to_list(columns(rows))) == rows
      end
    end

    @tag verifies: "table-sources"
    test "tuple rows pass through" do
      assert Table.rows([{1, 2}, {3, 4}]) === [{1, 2}, {3, 4}]
    end

    @tag verifies: "table-sources"
    test "the empty list, map and keyword list are []" do
      assert Table.rows([]) == []
      assert Table.rows(%{}) == []
    end

    @tag verifies: "table-sources"
    test "string column names stay strings" do
      assert Table.rows(%{"t" => [1, 2], "v" => [3, 4]}) == [
               %{"t" => 1, "v" => 3},
               %{"t" => 2, "v" => 4}
             ]
    end

    @tag verifies: "table-sources"
    test "a keyword list of columns is columns, not rows, as table reads it" do
      assert Table.rows(t: [1, 2], v: [3, 4]) == [%{t: 1, v: 3}, %{t: 2, v: 4}]
    end

    @tag verifies: "table-sources"
    test "a keyword list of unequal columns is rows" do
      assert Table.rows([{:a, [1]}, {:b, [1, 2]}]) == [{:a, [1]}, {:b, [1, 2]}]
    end

    @tag verifies: "table-sources"
    test "a map whose values are not equal-length lists is a caller error" do
      assert_raise ArgumentError, ~r/expected every column/, fn ->
        Table.rows(%{t: [1, 2], v: [3]})
      end

      assert_raise ArgumentError, fn -> Table.rows(%{t: 1}) end
    end
  end

  describe "rows/1 over Nx and Table.Reader" do
    @tag verifies: "table-sources"
    test "a rank-2 tensor yields one tuple per row" do
      assert Table.rows(Nx.tensor([[1, 10], [2, 20], [3, 30]])) == [{1, 10}, {2, 20}, {3, 30}]
    end

    @tag verifies: "table-sources"
    test "a rank-1 tensor yields its values" do
      assert Table.rows(Nx.tensor([1.5, 2.5])) == [1.5, 2.5]
    end

    @tag verifies: "table-sources"
    test "a map or keyword list of rank-1 tensors is columns, as one of lists is" do
      rows = Table.rows(%{t: [1, 2], v: [3.0, 4.0]})
      assert Table.rows(%{t: Nx.tensor([1, 2]), v: Nx.tensor([3.0, 4.0])}) == rows
      assert Table.rows(t: Nx.tensor([1, 2]), v: [3.0, 4.0]) == rows
    end

    @tag verifies: "table-sources"
    test "a column tensor of another rank, or of another length, is a caller error" do
      assert_raise ArgumentError, ~r/expected every column/, fn ->
        Table.rows(%{t: Nx.tensor([[1, 2]]), v: [3, 4]})
      end

      assert_raise ArgumentError, ~r/expected every column/, fn ->
        Table.rows(%{t: Nx.tensor([1, 2]), v: [3]})
      end
    end

    @tag verifies: "table-sources"
    test "named/2 names a tensor's columns in order, and passes any other source" do
      assert Table.named(Nx.tensor([[1, 10], [2, 20]]), ["t", "v"]) ==
               {:ok, %{"t" => [1, 2], "v" => [10, 20]}}

      assert Table.named(Nx.tensor([1, 2]), [:v]) == {:ok, %{v: [1, 2]}}
      assert Table.named(Nx.tensor([[1, 10]]), [:t]) == {:error, {:width, 1, 2}}
      assert Table.named(Nx.tensor([1, 2]), [:t, :v]) == {:error, {:width, 2, 1}}
      assert Table.named(Nx.tensor([[[1]]]), [:t]) == {:error, {:rank, 3}}
      assert Table.named(Nx.tensor(1), [:t]) == {:error, {:rank, 0}}
      rows = [%{t: 1}]
      assert Table.named(rows, [:t]) == {:ok, rows}

      # Whether a source has no names to read by: a tensor and tuple rows, never columns.
      assert Table.unnamed?(Nx.tensor([[1, 10]]))
      assert Table.unnamed?([{1, 10}])
      refute Table.unnamed?(t: [1, 2])
      refute Table.unnamed?(rows)
      refute Table.unnamed?(%{t: [1]})
    end

    @tag verifies: "table-sources"
    test "a struct with no Table.Reader impl is the protocol's error" do
      assert_raise Protocol.UndefinedError, fn -> Table.rows(~D[2024-01-01]) end
    end

    @tag verifies: "table-sources"
    test "any other rank is a caller error" do
      assert_raise ArgumentError, ~r/rank 1 or 2/, fn -> Table.rows(Nx.tensor([[[1]]])) end
    end
  end

  describe "get/2 and accessor/1" do
    @tag verifies: "table-row-helpers"
    test "an atom name reads an atom key, then the string spelling" do
      assert Table.get(%{v: 1}, :v) == 1
      assert Table.get(%{"v" => 2}, :v) == 2
      assert Table.get(%{:v => 1, "v" => 2}, :v) == 1
      assert Table.get(%{w: 1}, :v) == nil
    end

    @tag verifies: "table-row-helpers"
    test "a string name reads a string key, then the atom spelling" do
      assert Table.get(%{"v" => 2}, "v") == 2
      assert Table.get(%{v: 1}, "v") == 1
      assert Table.get(%{:v => 1, "v" => 2}, "v") == 2
      assert Table.get(%{w: 1}, "v") == nil
    end

    @tag verifies: "table-row-helpers"
    test "a nil value is a value, not a miss" do
      assert Table.get(%{:v => nil, "v" => 2}, :v) == nil
    end

    @tag verifies: "table-row-helpers"
    test "accessor/1 wraps a name and passes a function through" do
      fun = fn d -> d.v * 2 end
      assert Table.accessor(fun) == fun
      assert Table.accessor(:v).(%{"v" => 3}) == 3
      assert Table.accessor("v").(%{v: 4}) == 4
    end

    @tag verifies: "table-row-helpers"
    test "a tuple row has no names" do
      assert_raise BadMapError, fn -> Table.get({1, 2}, :v) end
    end
  end

  describe "column_types/1" do
    @tag verifies: "table-inference"
    test "types a column by its whole, leaves a mixed or empty one out" do
      rows = [
        %{
          t: ~U[2024-01-01 00:00:00Z],
          d: "2024-01-01",
          n: 1,
          f: 1.5,
          s: "a",
          k: :x,
          b: true,
          m: 1,
          e: nil
        },
        %{
          t: ~U[2024-01-02 00:00:00Z],
          d: "2024-01-02",
          n: 2,
          f: nil,
          s: "b",
          k: :y,
          b: false,
          m: "x",
          e: nil
        }
      ]

      assert Table.column_types(rows) == %{
               t: :time,
               d: :time,
               n: :number,
               f: :number,
               s: :text,
               k: :category,
               b: :category
             }
    end

    @tag verifies: "table-inference"
    test "a column that stops being temporal is text, a column map and a tuple table" do
      assert Table.column_types([%{d: "2024-01-01"}, %{d: "later"}]) == %{d: :text}
      assert Table.column_types(%{t: [1, 2], s: ["a", "b"]}) == %{t: :number, s: :text}
      assert Table.column_types([{1, 2}, {3, 4}]) == %{}
      assert Table.column_types([]) == %{}
    end

    @tag verifies: "table-inference"
    test "a column of color terms is :color; a column of CSS text is :text" do
      red = Macaw.Layers.Color.parse!("#c62828")

      rows = [
        %{c: {:color, "good"}, l: red, x: "#c62828", n: "red", m: red},
        %{c: {:alpha, {:color, :bad}, 0.5}, l: nil, x: "#2e7d32", n: "green", m: "#fff"},
        %{c: nil, l: red, x: nil, n: "blue", m: nil}
      ]

      assert Table.column_types(rows) == %{c: :color, l: :color, x: :text, n: :text}

      # Packing infers it too, where no type is given.
      assert {:ok, table} = Table.from(rows)
      assert Table.column_type(table, :c) == :color
      assert Table.column_type(table, :x) == :text
      assert Table.column_type(table, :m) == :term
    end
  end

  describe "time_columns/1 and temporal?/1" do
    @tag verifies: "table-inference"
    test "each temporal type is detected, over the whole column" do
      source = %{
        dt: [~U[2024-01-01 00:00:00Z], ~U[2024-01-02 00:00:00Z]],
        d: [~D[2024-01-01], ~D[2024-01-02]],
        ndt: [~N[2024-01-01 00:00:00], ~N[2024-01-02 00:00:00]],
        iso: ["2024-01-01T00:00:00Z", "2024-01-02"],
        v: [1, 2],
        mixed: [~D[2024-01-01], 2],
        strings: ["2024-01-01", "tomorrow"]
      }

      assert Table.time_columns(source) == [:d, :dt, :iso, :ndt]
    end

    @tag verifies: "table-inference"
    test "nil is a gap, not a value; an all-nil column is not temporal" do
      assert Table.time_columns(%{t: [nil, ~D[2024-01-01]], u: [nil, nil]}) == [:t]
    end

    @tag verifies: "table-inference"
    test "a first-row check would pass what the whole column fails" do
      assert Table.time_columns([%{t: ~D[2024-01-01]}, %{t: "later"}]) == []
    end

    @tag verifies: "table-inference"
    test "names are the union of every row's keys, sorted; a row missing a key is a gap" do
      rows = [%{b: ~D[2024-01-01]}, %{a: ~D[2024-01-02], b: ~D[2024-01-02]}]
      assert Table.time_columns(rows) == [:a, :b]
    end

    @tag verifies: "table-inference"
    test "tuple rows have no columns" do
      assert Table.time_columns([{~D[2024-01-01], 1}]) == []
    end

    @tag verifies: "table-inference"
    test "temporal?/1 accepts the three structs and ISO 8601 strings only" do
      assert Table.temporal?(~U[2024-01-01 00:00:00Z])
      assert Table.temporal?(~D[2024-01-01])
      assert Table.temporal?(~N[2024-01-01 00:00:00])
      assert Table.temporal?("2024-01-01T00:00:00+01:00")
      assert Table.temporal?("2024-01-01T00:00:00")
      assert Table.temporal?("2024-01-01")
      refute Table.temporal?("2024")
      refute Table.temporal?("01/02/2024")
      refute Table.temporal?(1_704_067_200)
      refute Table.temporal?(nil)
    end
  end

  describe "a table is columnar" do
    @tag verifies: "table-new"
    test "new/1 builds named typed columns, and refuses every fault at once" do
      table =
        Table.new!([
          {"t", :time, [~U[2024-01-01 00:00:00Z], nil]},
          {"v", :number, [1, 2]},
          {"k", :category, [:a, :b]},
          {"p", :point, [{-73.98, 40.75}, nil]}
        ])

      assert Table.names(table) == ["t", "v", "k", "p"]
      assert Table.size(table) == 2
      assert Table.column_type(table, "v") == :number
      assert Table.column_type(table, "nope") == nil
      # A category reads back as the string that spells it (macaw_data#16).
      assert Table.column(table, "k") == ["a", "b"]
      assert Table.column(table, "nope") == nil
      assert Table.types() == [:number, :time, :category, :text, :color, :point, :term]

      assert Table.new([
               {"v", :number, [1, "x"]},
               {"t", :time, ["2024-01-01"]},
               {"w", :number, [1, 2, 3]},
               {"v", :text, ["a", "b"]},
               {"z", :money, [1, 2]},
               {"p", :point, [{1, 2}, {:a, 2}]},
               {"c", :color, ["#fff", {:color, "good"}]}
             ]) ==
               {:error,
                [
                  {["c", 0], {:type, :color}},
                  {["p", 1], {:type, :point}},
                  {["t"], {:length, 2}},
                  {["v"], :duplicate},
                  {["v", 1], {:type, :number}},
                  {["w"], {:length, 2}},
                  {["z"], {:enum, Table.types()}}
                ]}

      assert_raise ArgumentError, ~r/not a table/, fn -> Table.new!([{"v", :number, ["x"]}]) end
      assert {:ok, %Table{size: 0, names: []}} = Table.new([])
    end

    # A time column converts by the date's fields, not DateTime's own functions
    # (macaw#185): over the whole range DateTime takes, before year 0 and after, it
    # reads back what DateTime would.
    @tag verifies: "table-packed"
    property "a time column reads back each time as DateTime converts it, from year -9999 to 9999" do
      min = DateTime.to_unix(~U[-9999-01-01 00:00:00.000000Z], :microsecond)
      max = DateTime.to_unix(~U[9999-12-31 23:59:59.999999Z], :microsecond)
      edges = [min, max, 0, -1, -62_167_219_200_000_000, -62_167_219_200_000_001]

      check all(
              us <- list_of(one_of([integer(min..max), member_of(edges)]), max_length: 40),
              gap <- boolean()
            ) do
        times = Enum.map(us, &DateTime.from_unix!(&1, :microsecond))
        values = if gap, do: [nil | times], else: times
        {:ok, table} = Table.new([{:t, :time, values}])
        assert Table.column(table, :t) == values
      end
    end

    @tag verifies: "table-packed"
    test "numbers and times are packed binaries with a validity bitmap; a gap stays a gap" do
      table =
        Table.new!([
          {:i, :number, [1, nil, -3]},
          {:f, :number, [1.5, nil, 2]},
          {:t, :time, [~U[2024-01-01 00:00:00.000001Z], nil, ~U[1969-12-31 23:59:59Z]]}
        ])

      # The bitmap is least-significant-bit first: values 0 and 2 present, 0b101.
      assert {:int64, bin, valid} = storage(table, :i)
      assert byte_size(bin) == 24 and valid == <<0b101>>
      assert {:integral, _, <<0b101>>, <<0b100>>} = storage(table, :f)
      assert {:utc, _, <<0b101>>, _precision} = storage(table, :t)

      # Each value reads back as given, integer or float; never 0 for a gap.
      assert Table.column(table, :i) === [1, nil, -3]
      assert Table.column(table, :f) === [1.5, nil, 2]

      assert Table.column(table, :t) == [
               ~U[2024-01-01 00:00:00.000001Z],
               nil,
               ~U[1969-12-31 23:59:59Z]
             ]
    end

    @tag verifies: "table-off-heap"
    test "a table's cost to its process is words a chunk, never words a row" do
      # Whole chunks, so each table's cost is its chunks' and nothing else's.
      rows = Table.chunk_rows()

      build = fn chunks ->
        Table.new!([{"v", :number, Enum.map(1..(chunks * rows), &(&1 * 1.0))}])
      end

      words = &:erts_debug.size/1
      small = build.(12)
      large = build.(123)

      # One chunk more costs the same words, whatever the table's length.
      per_chunk = words.(build.(2)) - words.(build.(1))
      assert Table.size(large) >= 1_000_000
      assert words.(large) - words.(small) == (123 - 12) * per_chunk
      assert per_chunk < rows / 50

      for {chunk, 0, ^rows} <- Table.chunks(large) do
        assert {:float64, bin, _} = chunk.columns["v"]
        assert byte_size(bin) == 8 * rows
        # Over 64 bytes, a binary is reference-counted, off the process heap.
        assert :binary.referenced_byte_size(bin) == 8 * rows
      end
    end

    @tag verifies: "table-edge"
    test "from/2 reads every source shape, inferring types or taking them" do
      rows = [
        %{t: ~U[2024-01-01 00:00:00Z], v: 1, k: :a, s: "x"},
        %{t: "2024-01-02", v: nil, k: :b, s: "y"},
        %{t: ~N[2024-01-03 12:00:00], v: 3, k: nil, s: "z"}
      ]

      {:ok, table} = Table.from(rows)
      assert Table.names(table) == [:k, :s, :t, :v]

      assert Map.new(Table.names(table), &{&1, Table.column_type(table, &1)}) ==
               %{t: :time, v: :number, k: :category, s: :text}

      # Each time at its own precision, as packing keeps it (macaw_data#16).
      assert Table.column(table, :t) == [
               ~U[2024-01-01 00:00:00Z],
               ~U[2024-01-02 00:00:00Z],
               ~U[2024-01-03 12:00:00Z]
             ]

      # A category reads back as the string that spells it (macaw_data#16).
      assert Table.column(table, :k) == ["a", "b", nil]

      {:ok, typed} = Table.from(rows, types: %{s: :term, k: :term})
      assert Table.column_type(typed, :s) == :term
      assert Table.column_type(typed, :k) == :term
      assert Table.column(typed, :k) == [:a, :b, nil]

      # A string is never a color.
      assert {:error, [{[:s, 0], {:type, :color}} | _]} = Table.from(rows, types: %{s: :color})

      # A mixed column is a term column; a table passes through.
      {:ok, mixed} = Table.from([%{m: 1}, %{m: "x"}])
      assert Table.column_type(mixed, :m) == :term
      assert Table.from(table) == {:ok, table}

      # Columns, a Table.Reader source, and a refusal by type.
      assert {:ok, %Table{size: 2}} = Table.from(%{a: [1, 2], b: ["x", "y"]})

      reader = %Macaw.Data.Test.Reader{columns: ["a"], rows: [[1], [2]]}
      assert {:ok, read} = Table.from(reader)
      assert Table.column(read, "a") == [1, 2]

      assert Table.from([%{t: "not a time"}], types: %{t: :time}) ==
               {:error, [{[:t, 0], {:type, :time}}]}
    end

    @tag verifies: "table-edge"
    test "a Table.Reader source yields its rows, keyed as the reader names its columns" do
      reader = %Macaw.Data.Test.Reader{columns: ["t", "v"], rows: [[1, 10.0], [2, 20.0]]}
      assert Table.rows(reader) == [%{"t" => 1, "v" => 10.0}, %{"t" => 2, "v" => 20.0}]
    end

    @tag verifies: "table-round-trip"
    property "rows to a table and back are the rows, and every column has the table's length" do
      check all(
              rows <-
                list_of(
                  fixed_map(%{
                    n: one_of([integer(), constant(nil)]),
                    f: one_of([float(), constant(nil)]),
                    s: one_of([string(:alphanumeric), constant(nil)]),
                    t:
                      one_of([
                        map(
                          integer(-1_000_000_000_000..4_000_000_000_000),
                          &DateTime.from_unix!(&1, :microsecond)
                        ),
                        constant(nil)
                      ])
                  }),
                  max_length: 30
                )
            ) do
        {:ok, table} = Table.from(rows, types: %{n: :number, f: :number, s: :text, t: :time})
        assert Table.rows(table) == rows

        for name <- Table.names(table),
            do: assert(length(Table.column(table, name)) == Table.size(table))
      end
    end

    @tag verifies: "table-slice"
    property "slice/3 is the rows from start, count of them, as a table, however it is chunked" do
      check all(
              values <- list_of(one_of([integer(), constant(nil)]), max_length: 40),
              cuts <- list_of(integer(0..40), max_length: 6),
              start <- integer(0..45),
              count <- integer(0..45)
            ) do
        # The same values, appended at generated cuts.
        table =
          [0 | cuts]
          |> Enum.filter(&(&1 <= length(values)))
          |> Enum.concat([length(values)])
          |> Enum.sort()
          |> Enum.chunk_every(2, 1, :discard)
          |> Enum.map(fn [from, to] ->
            piece = Enum.slice(values, from, to - from)
            Table.new!([{"v", :number, piece}, {"s", :term, piece}])
          end)
          |> Enum.reduce(fn piece, acc -> elem(Table.append(acc, piece), 1) end)

        sliced = Table.slice(table, start, count)
        assert Table.rows(sliced) == Enum.slice(Table.rows(table), start, count)
        assert Table.size(sliced) == length(Enum.slice(values, start, count))
      end
    end

    @tag verifies: "table-slice"
    test "row/2 is one row, nil past the end, and a slice shares its parent's chunks" do
      table = Table.new!([{"v", :number, Enum.map(1..100, &(&1 * 1.0))}])
      assert Table.row(table, 0) == %{"v" => 1.0}
      assert Table.row(table, 100) == nil

      [{chunk, 0, 100}] = Table.chunks(table)
      assert [{^chunk, 10, 20}] = Table.chunks(Table.slice(table, 10, 20))

      {:float64, bin, _} = storage(Table.slice(table, 10, 20), "v")
      assert byte_size(bin) == 160
      assert :binary.referenced_byte_size(bin) == 800
    end
  end
end
