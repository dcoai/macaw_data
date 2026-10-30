defmodule Macaw.Data.TableChunksTest do
  @moduledoc """
  `Macaw.Data.Table`'s chunks and identity (spec/01 §1.1.1, §1.1.2; macaw_data#9, #17):
  canonical chunks, append and trim copying nothing, and equality and the digest by
  contents, never by layout.
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Macaw.Data.Table
  alias Macaw.Data.Table.Chunk
  alias Macaw.Data.Table.Digest
  alias Macaw.Layers.Document

  # `columns` ({name, type, values}) built in pieces of the given sizes and appended: the
  # same rows, chunked as the sizes say.
  defp chunked(columns, sizes) do
    sizes
    |> Enum.map_reduce(0, fn n, at ->
      {Table.new!(
         for({name, type, values} <- columns, do: {name, type, Enum.slice(values, at, n)})
       ), at + n}
    end)
    |> elem(0)
    |> Enum.reduce(fn piece, acc ->
      {:ok, table} = Table.append(acc, piece)
      table
    end)
  end

  # Sizes of pieces adding up to n: at least one piece, each but an empty table's nonempty.
  defp sizes(0), do: constant([0])

  defp sizes(n) do
    gen all(cuts <- list_of(integer(1..n), max_length: 8)) do
      [0 | cuts |> Enum.uniq() |> Kernel.--([n]) |> Enum.sort()]
      |> Enum.concat([n])
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.map(fn [from, to] -> to - from end)
    end
  end

  defp time_gen do
    one_of([
      constant(nil),
      map(integer(-1_000_000_000_000..4_000_000_000_000), &DateTime.from_unix!(&1, :microsecond)),
      map(integer(0..2_000_000_000), &DateTime.from_unix!/1)
    ])
  end

  # Columns of every packed type, with gaps, of one generated length.
  defp columns_gen do
    gen all(
          n <- integer(0..60),
          numbers <- list_of(one_of([integer(), float(), constant(nil)]), length: n),
          texts <- list_of(one_of([string(:printable, max_length: 4), constant(nil)]), length: n),
          categories <-
            list_of(member_of([:ok, "ok", "warn", true, false, nil, :down]), length: n),
          times <- list_of(time_gen(), length: n),
          terms <- list_of(one_of([integer(), tuple({atom(:alphanumeric)})]), length: n)
        ) do
      [
        {"n", :number, numbers},
        {"s", :text, texts},
        {"c", :category, categories},
        {"t", :time, times},
        {"x", :term, terms}
      ]
    end
  end

  defp slice_columns(columns, from, count),
    do: for({name, type, values} <- columns, do: {name, type, Enum.slice(values, from, count)})

  # Every call `fun` makes, in this process, to a function `pattern` matches, in order, by
  # module and name: traced to a collector, since a process is not its own tracer.
  defp calls(pattern, fun) do
    collector = spawn_link(fn -> collect([]) end)
    :erlang.trace_pattern(pattern, true, [:global])
    :erlang.trace(self(), true, [:call, {:tracer, collector}])
    fun.()
    :erlang.trace(self(), false, [:call])
    :erlang.trace_pattern(pattern, false, [:global])
    ref = :erlang.trace_delivered(self())
    receive do: ({:trace_delivered, _, ^ref} -> :ok)
    send(collector, {:done, self()})
    receive do: ({:calls, calls} -> calls)
  end

  defp collect(calls) do
    receive do
      {:trace, _pid, :call, {module, name, _args}} -> collect([{module, name} | calls])
      {:done, from} -> send(from, {:calls, Enum.reverse(calls)})
    end
  end

  # Any data: never a function, a PID, a reference or a port.
  defp data_gen do
    tree(one_of([integer(), float(), binary(), atom(:alphanumeric), boolean()]), fn child ->
      one_of([
        list_of(child, max_length: 3),
        tuple({child, child}),
        map_of(child, child, max_length: 2)
      ])
    end)
  end

  describe "chunks" do
    @tag verifies: "table-chunks"
    test "new/1 builds canonical chunks of chunk_rows/0 rows from the first, the last shorter" do
      rows = Table.chunk_rows()
      assert rows == 8192
      values = Enum.to_list(1..(2 * rows + 5))
      table = Table.new!([{"v", :number, values}])

      assert for(
               {chunk, first, count} <- Table.chunks(table),
               do: {Chunk.size(chunk), first, count}
             ) ==
               [{rows, 0, rows}, {rows, 0, rows}, {5, 0, 5}]

      assert Table.column(table, "v") == values
      assert Table.size(table) == 2 * rows + 5
      assert Table.chunks(Table.new!([{"v", :number, []}])) == []
      assert Table.chunks(Table.new!([])) == []

      {:ok, from} = Table.from(Enum.map(values, &%{"v" => &1}))
      assert length(Table.chunks(from)) == 3
    end

    @tag verifies: "table-chunks"
    test "a column is packed per chunk, a form and a dictionary each, and reads back whole" do
      {:ok, table} =
        Table.append(
          Table.new!([{"v", :number, [1, 2]}, {"c", :category, [:a, "b"]}]),
          Table.new!([{"v", :number, [1.5, nil]}, {"c", :category, ["b", "a"]}])
        )

      assert [{first, 0, 2}, {second, 0, 2}] = Table.chunks(table)
      assert {:int64, _, _} = first.columns["v"]
      assert {:float64, _, _} = second.columns["v"]
      assert {:dictionary, _, _, {_, "ab"}, nil} = first.columns["c"]
      assert {:dictionary, _, _, {_, "ba"}, nil} = second.columns["c"]

      assert Table.column(table, "v") === [1, 2, 1.5, nil]
      assert Table.column(table, "c") == ["a", "b", "b", "a"]
      assert Table.rows(table) |> length() == 4
      assert Table.row(table, 2) == %{"v" => 1.5, "c" => "b"}
    end
  end

  describe "append and trim" do
    @tag verifies: "table-append-trim"
    property "appending and trimming give the contents a fresh build of the same rows would have" do
      check all(
              columns <- columns_gen(),
              n = length(elem(hd(columns), 2)),
              pieces <- sizes(n),
              cut <- integer(0..(n + 2))
            ) do
        table = chunked(columns, pieces)
        assert Table.equal?(table, Table.new!(columns))
        assert Table.column(table, "n") === elem(hd(columns), 2)

        trimmed = Table.trim(table, cut)
        assert Table.equal?(trimmed, Table.new!(slice_columns(columns, cut, n)))
        assert Table.size(trimmed) == max(n - cut, 0)

        # Every chunk wholly before the cut is dropped: in no entry of chunks/1.
        {before, _} =
          Enum.map_reduce(Table.chunks(table), 0, fn {chunk, _first, count}, at ->
            {{chunk, at + count <= cut}, at + count}
          end)

        kept = for {chunk, _, _} <- Table.chunks(trimmed), do: chunk

        for {chunk, true} <- before, do: refute(Enum.any?(kept, &(&1 === chunk)))
      end
    end

    @tag verifies: "table-append-trim"
    test "append adds the other table's chunks as they are, and refuses other columns" do
      a = Table.new!([{"v", :number, [1, 2, 3]}])
      b = Table.new!([{"v", :number, [4.5]}])
      {:ok, both} = Table.append(a, b)
      assert Table.chunks(both) == Table.chunks(a) ++ Table.chunks(b)

      # The very binaries, not copies.
      [{chunk, 0, 3}, _] = Table.chunks(both)
      [{own, 0, 3}] = Table.chunks(a)
      assert :erts_debug.same(chunk, own)

      assert Table.append(a, Table.new!([{"w", :number, [1]}])) ==
               {:error, {:columns, [{"v", :number}], [{"w", :number}]}}

      assert Table.append(a, Table.new!([{"v", :text, ["x"]}])) ==
               {:error, {:columns, [{"v", :number}], [{"v", :text}]}}
    end

    @tag verifies: "table-append-trim"
    test "trim moves the first chunk that remains to start at the cut" do
      {:ok, table} =
        Table.append(
          Table.new!([{"v", :number, [1, 2, 3]}]),
          Table.new!([{"v", :number, [4, 5]}])
        )

      [{a, 0, 3}, {b, 0, 2}] = Table.chunks(table)
      assert [{^a, 2, 1}, {^b, 0, 2}] = Table.chunks(Table.trim(table, 2))
      assert [{^b, 1, 1}] = Table.chunks(Table.trim(table, 4))
      assert Table.chunks(Table.trim(table, 9)) == []
      assert Table.column(Table.trim(table, 2), "v") == [3, 4, 5]
    end
  end

  describe "identity is the contents" do
    @tag verifies: "table-equal"
    property "the same rows chunked two ways are one value; one changed value is another" do
      check all(
              columns <- columns_gen(),
              n = length(elem(hd(columns), 2)),
              a <- sizes(n),
              b <- sizes(n),
              at <- integer(0..max(n - 1, 0))
            ) do
        one = chunked(columns, a)
        two = chunked(columns, b)

        assert Table.equal?(one, two)
        assert Table.digest(one) == Table.digest(two)
        assert Table.compact(one) == Table.compact(two)
        assert Table.compact(one) == Table.new!(columns)

        if n > 0 do
          changed =
            List.update_at(columns, 1, fn {name, type, values} ->
              {name, type, List.replace_at(values, at, "changed, 🦜")}
            end)

          other = chunked(changed, a)
          refute Table.equal?(one, other)
          refute Table.digest(one) == Table.digest(other)
        end
      end
    end

    @tag verifies: "table-equal"
    test "compaction rewrites to canonical chunks, and a canonical table is returned as it is" do
      rows = Table.chunk_rows()
      values = Enum.to_list(1..(rows + 10))
      table = chunked([{"v", :number, values}], [7, rows, 3])

      compacted = Table.compact(table)
      assert compacted == Table.new!([{"v", :number, values}])

      assert for(
               {chunk, first, count} <- Table.chunks(compacted),
               do: {Chunk.size(chunk), first, count}
             ) ==
               [{rows, 0, rows}, {10, 0, 10}]

      assert Table.compact(compacted) === compacted
      refute table == compacted
      assert Table.equal?(table, compacted)
    end
  end

  describe "the digest" do
    @tag verifies: "table-data"
    test "new/1 refuses a value that is not data, by its path, in any chunk" do
      fun = fn -> :ok end
      data = {:ok, [%{"a" => "b", 1 => 2.5}], <<1::3>>}

      assert Table.new([{"x", :term, [data, make_ref(), fun, self(), [1 | 2], nil]}]) ==
               {:error,
                [
                  {["x", 1], :not_data},
                  {["x", 2], :not_data},
                  {["x", 3], :not_data},
                  {["x", 4], :not_data}
                ]}

      late = List.duplicate(1, Table.chunk_rows()) ++ [make_ref()]
      assert Table.new([{"x", :term, late}]) == {:error, [{["x", Table.chunk_rows()], :not_data}]}

      assert Table.column(Table.new!([{"x", :term, [data, nil]}]), "x") == [data, nil]
    end

    @tag verifies: "table-digest"
    test "digest/1 is the SHA-256 of the canonical form" do
      table = chunked([{"n", :number, [1, 2.5, nil]}, {"s", :text, ["ab", nil, "c"]}], [2, 1])
      sha = &:crypto.hash(:sha256, &1)

      expected =
        sha.([
          1,
          Digest.encode({"macaw.table", [{"n", :number}, {"s", :text}]}),
          <<3::64>>,
          sha.(<<1, 2, 0>>),
          sha.(<<1::little-64, 2.5::float-little-64, 0::64>>),
          sha.(""),
          sha.(<<4, 0, 4>>),
          sha.(<<2::little-64, 0::64, 1::little-64>>),
          sha.("abc")
        ])

      assert Table.digest(table) == Base.encode16(expected, case: :lower)
      assert Table.digest(table) =~ ~r/\A[0-9a-f]{64}\z/
    end

    @tag verifies: "table-digest"
    property "the kernel's encoding the digest uses is the kernel's, byte for byte" do
      check all(term <- data_gen()) do
        assert Document.digest(term) ==
                 Base.encode16(:crypto.hash(:sha256, [1 | Digest.encode(term)]), case: :lower)
      end
    end

    @tag verifies: "table-digest"
    test "every form of the same values gives one digest, one value a chunk or all in one" do
      paris = %DateTime{
        ~U[2026-06-01 10:00:00Z]
        | time_zone: "Europe/Paris",
          zone_abbr: "CEST",
          utc_offset: 3600,
          std_offset: 3600,
          hour: 12
      }

      columns = [
        {"n", :number, [1, 2.5, nil, 2 ** 60, 2 ** 70, -0.0, -7]},
        {"t", :time,
         [
           ~U[2026-01-01 00:00:00Z],
           paris,
           nil,
           ~U[2026-01-01 00:00:00.000000Z],
           ~N[2026-01-01 00:00:00],
           ~D[2026-01-02],
           ~U[1969-12-31 23:59:59.5Z]
         ]},
        {"s", :text, ["a", <<0xC3>>, nil, "", "é", 3, "z"]},
        {"c", :category, [:ok, "warn", true, nil, false, "ok", 3]},
        {"x", :term, [{1}, %{a: [1.0]}, nil, :x, "x", 1, 2 ** 70]}
      ]

      whole = Table.new!(columns)
      singles = chunked(columns, List.duplicate(1, 7))
      assert length(Table.chunks(singles)) == 7
      assert Table.digest(singles) == Table.digest(whole)

      # Each column alone too, so no other column can mask a difference.
      for {name, type, values} <- columns do
        assert Table.digest(chunked([{name, type, values}], List.duplicate(1, 7))) ==
                 Table.digest(Table.new!([{name, type, values}]))
      end
    end

    @tag verifies: "table-digest"
    test "a chunk's digest is its own, as a one-chunk table" do
      columns = [{"v", :number, [1, 2, 3, 4.5, nil]}, {"s", :text, ["a", nil, "b", "c", "d"]}]
      table = chunked(columns, [2, 3])

      for {{chunk, 0, count}, from} <- Enum.zip(Table.chunks(table), [0, 2]) do
        assert Chunk.digest(chunk) ==
                 Table.digest(Table.new!(slice_columns(columns, from, count)))
      end
    end

    @tag verifies: "table-digest"
    test "a dictionary built again in another order keeps the digest" do
      table = Table.new!([{"c", :category, ["x", "y", "x"]}])
      [{chunk, 0, 3}] = Table.chunks(table)
      {:dictionary, _codes, validity, {_offsets, "xy"}, nil} = chunk.columns["c"]

      # The same values, coded into the dictionary ["y", "x"].
      codes = <<1::little-32, 0::little-32, 1::little-32>>
      dictionary = {<<0::little-32, 1::little-32, 2::little-32>>, "yx"}
      again = %{chunk | columns: %{"c" => {:dictionary, codes, validity, dictionary, nil}}}
      rebuilt = %{table | chunks: [{again, 0, 3}]}

      assert Table.column(rebuilt, "c") == ["x", "y", "x"]
      refute rebuilt == table
      assert Table.equal?(rebuilt, table)
      assert Table.digest(rebuilt) == Table.digest(table)
    end

    @tag verifies: "table-digest"
    test "values compare strictly: 1 and 1.0, 0.0 and -0.0 differ" do
      for {a, b} <- [{1, 1.0}, {0.0, -0.0}] do
        one = Table.new!([{"v", :number, [a]}])
        two = Table.new!([{"v", :number, [b]}])
        refute Table.equal?(one, two)
        refute Table.digest(one) == Table.digest(two)
      end

      refute Table.equal?(Table.new!([{"v", :number, [1]}]), Table.new!([{"w", :number, [1]}]))
      refute Table.equal?(Table.new!([{"v", :number, [1]}]), Table.new!([{"v", :term, [1]}]))
    end

    @tag verifies: "table-digest"
    test "reading a chunk's digest, slicing, trimming and appending hash nothing; new/1 hashes each chunk once" do
      rows = Table.chunk_rows()
      values = Enum.map(1..(2 * rows + 1), &(&1 * 1.0))

      assert calls({Digest, :digest, 3}, fn -> Table.new!([{"v", :number, values}]) end) ==
               List.duplicate({Digest, :digest}, 3)

      table = Table.new!([{"v", :number, values}])
      more = Table.new!([{"v", :number, [1.0]}])

      lookups =
        calls({:crypto, :_, :_}, fn ->
          for _ <- 1..100, {chunk, _, _} <- Table.chunks(table), do: Chunk.digest(chunk)
          sliced = Table.slice(table, 5, rows)
          {:ok, appended} = Table.append(Table.trim(sliced, 3), more)
          for {chunk, _, _} <- Table.chunks(appended), do: Chunk.digest(chunk)
        end)

      assert lookups == []
    end
  end
end
