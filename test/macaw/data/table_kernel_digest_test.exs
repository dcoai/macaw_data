defmodule Macaw.Data.TableKernelDigestTest do
  @moduledoc """
  The kernel's digest of a table is of its contents, never its layout (spec/01 §1.1.2;
  macaw_data#220): `Macaw.Data.Table` and `Macaw.Data.Table.Chunk` implement
  `Macaw.Layers.Digest`, so `Macaw.Layers.Document.digest/1` of any term holding one
  follows `Macaw.Data.Table.equal?/2`.
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Macaw.Data.Operations
  alias Macaw.Data.Test.Ops
  alias Macaw.Data.Table
  alias Macaw.Data.Table.Chunk
  alias Macaw.Data.Table.Digest
  alias Macaw.Layers.Document

  import Macaw.Data.Test.Trace, only: [calls: 2]

  @rows Table.chunk_rows()

  defp digest!(term) do
    {:ok, digest} = Document.digest(term)
    digest
  end

  # `columns` ({name, type, values}) built in pieces of the given sizes and appended.
  defp chunked(columns, sizes) do
    sizes
    |> Enum.map_reduce(0, fn n, at ->
      {Table.new!(
         for {name, type, values} <- columns, do: {name, type, Enum.slice(values, at, n)}
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
      map(integer(-1_000_000_000_000..4_000_000_000_000), &DateTime.from_unix!(&1, :microsecond))
    ])
  end

  # Columns of every packed type, with gaps, of one generated length.
  defp columns_gen do
    gen all(
          n <- integer(0..40),
          numbers <- list_of(one_of([integer(), float(), constant(nil)]), length: n),
          texts <- list_of(one_of([string(:printable, max_length: 4), constant(nil)]), length: n),
          categories <- list_of(member_of([:ok, "ok", "warn", true, nil]), length: n),
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

  # The rows of `columns` as the middle of a longer table, sliced out of it.
  defp sliced(columns, pad) do
    padded = for {name, type, values} <- columns, do: {name, type, pad ++ values ++ pad}
    Table.slice(Table.new!(padded), length(pad), length(elem(hd(columns), 2)))
  end

  # The same rows as a source's table, aligned by row count: other chunk ids, an origin.
  defp sourced(columns) do
    {:ok, table} =
      Table.new(columns, origin: %{source: "held", resolution: 1, window: nil, span: nil})

    table
  end

  describe "a table's kernel digest" do
    @tag verifies: "table-kernel-digest"
    property "equal tables in every layout give one Document.digest/1; one changed value another" do
      check all(
              columns <- columns_gen(),
              n = length(elem(hd(columns), 2)),
              a <- sizes(n),
              b <- sizes(n),
              pad <- list_of(constant(nil), max_length: 3),
              at <- integer(0..max(n - 1, 0))
            ) do
        one = chunked(columns, a)

        layouts = [
          chunked(columns, b),
          Table.new!(columns),
          Table.compact(one),
          sliced(columns, pad),
          sourced(columns)
        ]

        for other <- layouts do
          assert Table.equal?(one, other)
          assert digest!(one) == digest!(other)
        end

        if n > 0 do
          changed =
            List.update_at(columns, 1, fn {name, type, values} ->
              {name, type, List.replace_at(values, at, "changed, 🦜")}
            end)

          refute digest!(chunked(changed, a)) == digest!(one)
        end
      end
    end

    @tag verifies: "table-kernel-digest"
    property "across canonical chunk boundaries, every cut of the rows gives the digests a canonical table keeps" do
      check all(
              extra <- integer(0..(2 * @rows)),
              n = @rows + extra,
              cuts <- sizes(n),
              scale <- member_of([1, 1.5]),
              max_runs: 15
            ) do
        columns = [{"v", :number, Enum.map(1..n, &(&1 * scale))}]
        canonical = Table.new!(columns)
        cut = chunked(columns, cuts)

        assert Table.canonical(cut) == Table.canonical(canonical)
        assert digest!(cut) == digest!(canonical)

        assert {"macaw.table", [{"v", :number}], kept} = Table.canonical(canonical)
        assert kept == for({chunk, 0, _} <- Table.chunks(canonical), do: Chunk.digest(chunk))
      end
    end

    @tag verifies: "table-kernel-digest"
    test "two tables of other columns and no rows differ; the origin and the sorted column do not count" do
      refute digest!(Table.new!([{"a", :number, []}])) ==
               digest!(Table.new!([{"b", :number, []}]))

      refute digest!(Table.new!([{"a", :number, []}])) == digest!(Table.new!([{"a", :text, []}]))

      {:ok, sorted} =
        Table.new([{"t", :number, [1, 2, 3]}],
          origin: %{source: "s", resolution: 1, window: "t", span: 2}
        )

      assert Table.sorted(sorted) == "t"
      assert digest!(sorted) == digest!(Table.new!([{"t", :number, [1, 2, 3]}]))
      refute digest!(sorted) == digest!(Table.new!([{"t", :number, [1, 2, 3.0]}]))
    end

    @tag verifies: "table-kernel-digest"
    test "a table nested in a map, a list, a tuple, a column and a step's identity gets one digest across layouts" do
      columns = [
        {"v", :number, Enum.to_list(1..(@rows + 7))},
        {"k", :category, [:a | List.duplicate("b", @rows + 6)]}
      ]

      one = Table.new!(columns)
      two = chunked(columns, [5, @rows, 2])
      refute one == two

      for wrap <- [&%{"rows" => &1}, &[1, &1], &{:t, [&1]}] do
        assert digest!(wrap.(one)) == digest!(wrap.(two))
      end

      assert Table.digest(Table.new!([{"x", :term, [one, nil]}])) ==
               Table.digest(Table.new!([{"x", :term, [two, nil]}]))

      registry = Operations.registry!([Ops])

      [a, b] =
        for table <- [one, two] do
          {:ok, [node]} =
            Operations.validate(
              registry,
              [%{"op" => "filter", "field" => "x", "test" => "eq", "value" => table}],
              %{}
            )

          Operations.step_digest!(registry, node)
        end

      assert a == b
    end

    @tag verifies: "table-kernel-digest"
    test "a table of canonical chunks gives the digests they keep: nothing hashed, no cold chunk fetched" do
      values = Enum.map(1..(2 * @rows + 1), &(&1 * 1.0))
      table = Table.new!([{"v", :number, values}])

      me = self()
      [{warm, 0, n} | rest] = Table.chunks(table)
      base = warm.columns

      fetch = fn ->
        send(me, :fetched)
        base
      end

      cold = Chunk.cold(Chunk.header(warm), Chunk.id(warm), Chunk.digest(warm), n, fetch)
      held = %{table | chunks: [{cold, 0, n} | rest]}

      assert calls({Digest, :digest, 3}, fn -> digest!(held) end) == []
      refute_received :fetched
      assert digest!(held) == digest!(chunked([{"v", :number, values}], [3, 2 * @rows - 2]))
    end
  end

  describe "a chunk's kernel digest" do
    @tag verifies: "table-kernel-digest"
    test "is its contents' as a one-chunk table: its id, its form and a step output's missing digest do not count" do
      header = [{"v", :number}]
      [{built, 0, 3}] = Table.chunks(Table.new!([{"v", :number, [1, 2, 3]}]))
      [{sourced, 0, 3}] = Table.chunks(sourced([{"v", :number, [1, 2, 3]}]))
      refute Chunk.id(built) == Chunk.id(sourced)

      assert Chunk.canonical(built) == {"macaw.table.chunk", header, Chunk.digest(built)}
      assert digest!(built) == digest!(sourced)

      # A step's output, its content digest not yet computed.
      {:ok, derived} = Chunk.derive(built, :step, [{"v", :number, [1, 2, 3]}])
      assert Chunk.digest(derived) == nil
      assert digest!(derived) == digest!(built)

      # A cold chunk: a fetch function in its fields, digested by what it stands for.
      cold = Chunk.cold(header, Chunk.id(built), Chunk.digest(built), 3, fn -> built.columns end)
      assert digest!(cold) == digest!(built)

      {:ok, other} = Chunk.derive(built, :step, [{"v", :number, [1, 2, 3.0]}])
      refute digest!(other) == digest!(built)
      refute digest!(built) == digest!(Table.new!([{"v", :number, [1, 2, 3]}]))
    end
  end
end
