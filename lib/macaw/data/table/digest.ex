defmodule Macaw.Data.Table.Digest do
  @moduledoc false
  # A table's content digest (spec/01 §1.1.2): a SHA-256 over its canonical form, never
  # its buffers, so a chunking, a column's form and a dictionary's order all keep it.
  #
  #   SHA-256(version byte 1,
  #           the kernel's encoding of {"macaw.table", [{name, type}, ...]},
  #           the row count, 64-bit big-endian,
  #           then for each column in order: the SHA-256 of its tags, of its words and of
  #           its bytes, `Macaw.Data.Table.Canonical`'s three streams)
  #
  # Each stream is hashed by itself, a segment (a chunk's view) at a time, so where a
  # segment ends never reaches the digest. The streams are near-buffers for the packed
  # forms: a chunk's digest costs about as much as hashing its buffers once.
  #
  # The header and a value no packed form holds are in the kernel's own encoding,
  # `Macaw.Layers.Document.encode/1` (macaw_layers 0.5.0), so a change to it moves these
  # digests with `Document.digest/1`'s: there is one encoder in the family.

  alias Macaw.Data.Table.Canonical
  alias Macaw.Data.Table.Chunk
  alias Macaw.Data.Table.Column
  alias Macaw.Layers.Document

  # The version of this form. It is this library's: the canonical streams are its own. It
  # equals the kernel's `Document.encoding_version/0`, which a test pins, so a new kernel
  # encoding fails that test and asks for a new version of this form with it.
  @encoding 1

  @typedoc "A column's storage a segment at a time: each a function answering a form and its count."
  @type segments :: [(-> {Column.t(), non_neg_integer()})]

  @doc false
  @spec digest([{term(), atom()}], non_neg_integer(), [segments()]) :: String.t()
  def digest(header, size, columns) do
    columns =
      Enum.map(columns, fn segments ->
        segments
        |> Enum.reduce({init(), init(), init()}, fn segment, {t, w, b} ->
          {storage, count} = segment.()
          {tags, words, bytes} = Canonical.streams(storage, count)

          {:crypto.hash_update(t, tags), :crypto.hash_update(w, words),
           :crypto.hash_update(b, bytes)}
        end)
        |> Tuple.to_list()
        |> Enum.map(&:crypto.hash_final/1)
      end)

    :sha256
    |> :crypto.hash([@encoding, encode({"macaw.table", header}), <<size::64>> | columns])
    |> Base.encode16(case: :lower)
  end

  defp init, do: :crypto.hash_init(:sha256)

  # A canonical chunk's rows (spec/01 §1.1.1), `Macaw.Data.Table.chunk_rows/0`.
  @rows 8192

  @doc false
  # A table's canonical term (`Macaw.Layers.Digest`, spec/01 §1.1.2): what the kernel's
  # digest encodes in its place, `{"macaw.table", header, digests}`. `digests` are the
  # content digests, each as a one-chunk table under `header`, of its rows `@rows` at a
  # time from the first, the last run shorter: the digests a canonical rebuild's chunks
  # carry. So it is equal exactly when the contents are (`Table.equal?/2`). Views that
  # are those chunks already, whole, hashed, with no delta and the table's columns in its
  # order, give the digests they keep, hashing nothing and fetching no cold chunk; any
  # other layout hashes its rows a run at a time, as `digest/3` hashes a table.
  @spec canonical([{term(), atom()}], [{Chunk.t(), non_neg_integer(), non_neg_integer()}]) ::
          {String.t(), [{term(), atom()}], [String.t()]}
  def canonical(header, views) do
    digests =
      case kept(views, header, []) do
        {:ok, digests} -> digests
        :general -> views |> runs(@rows, [], []) |> Enum.map(&run_digest(header, &1))
      end

    {"macaw.table", header, digests}
  end

  # The digests whole canonical chunks keep, in order, or `:general`.
  defp kept([], _header, acc), do: {:ok, Enum.reverse(acc)}

  defp kept([{chunk, 0, count} | rest], header, acc)
       when count == @rows or (rest == [] and count in 1..@rows//1) do
    digest = Chunk.digest(chunk)

    if count == Chunk.size(chunk) and not Chunk.delta?(chunk) and is_binary(digest) and
         Chunk.header(chunk) == header,
       do: kept(rest, header, [digest | acc]),
       else: :general
  end

  defp kept(_views, _header, _acc), do: :general

  # The views cut into runs of `@rows` rows from the first, the last shorter: `room` the
  # rows the current run still takes.
  defp runs([], _room, [], done), do: Enum.reverse(done)
  defp runs([], _room, run, done), do: Enum.reverse([Enum.reverse(run) | done])

  defp runs([{_chunk, _first, count} = view | rest], room, run, done) when count < room,
    do: runs(rest, room - count, [view | run], done)

  defp runs([{chunk, first, count} | rest], room, run, done) do
    done = [Enum.reverse([{chunk, first, room} | run]) | done]
    rest = if count == room, do: rest, else: [{chunk, first + room, count - room} | rest]
    runs(rest, @rows, [], done)
  end

  # A run's content digest as a one-chunk table under `header`.
  defp run_digest(header, run) do
    size = run |> Enum.map(&elem(&1, 2)) |> Enum.sum()

    columns =
      for {name, _type} <- header do
        for {chunk, first, count} <- run,
            do: fn -> {Chunk.storage(chunk, name, first, count), count} end
      end

    digest(header, size, columns)
  end

  @doc false
  # A chunk's canonical term (`Macaw.Layers.Digest`): `{"macaw.table.chunk", header,
  # digest}`, its content digest as a one-chunk table, read where it keeps one and else
  # hashed as read. Its id is where it sits, not its contents, so it is not in the term,
  # as a table's origin is not in its.
  @spec chunk_canonical([{term(), atom()}], String.t()) ::
          {String.t(), [{term(), atom()}], String.t()}
  def chunk_canonical(header, digest) when is_binary(digest),
    do: {"macaw.table.chunk", header, digest}

  @doc false
  # The kernel's digest (`Macaw.Layers.Document.digest/1`) of a term this library built
  # from parts already judged data: a chunk's derivation and combined id (its inputs' ids
  # and versions and a step key), a step's identity over a checked node, a registry's
  # names, a schema's normalized fields. Such a term is data by construction, so a fault
  # here is a defect in this library, raised as a named invariant (`built_not_data/1`).
  @spec term(term()) :: String.t()
  def term(value) do
    case Document.digest(value) do
      {:ok, digest} -> digest
      {:error, faults} -> built_not_data(faults)
    end
  end

  defp built_not_data(faults) do
    raise ArgumentError,
          "a term macaw_data built as data is not data, at " <>
            Enum.map_join(faults, ", ", fn {path, _} -> inspect(path) end)
  end

  @doc """
  Whether a value is data the kernel's digest encodes: an atom, a number, a bitstring,
  and proper lists, tuples and maps of data. A function, a PID, a reference, a port and an
  improper list are not. A struct is judged as the kernel encodes it, by its canonical
  term (`Macaw.Layers.Digest`), which unless its type says otherwise is its map.
  """
  @spec data?(term()) :: boolean()
  def data?(v) when is_atom(v) or is_number(v) or is_bitstring(v), do: true
  def data?(tuple) when is_tuple(tuple), do: tuple |> Tuple.to_list() |> data?()

  def data?(%_{} = struct) do
    case Macaw.Layers.Digest.canonical(struct) do
      ^struct -> map?(struct)
      canonical -> data?(canonical)
    end
  end

  def data?(map) when is_map(map), do: map?(map)

  def data?(list) when is_list(list), do: list?(list)
  def data?(_other), do: false

  defp map?(map), do: map |> :maps.to_list() |> Enum.all?(fn {k, v} -> data?(k) and data?(v) end)

  # A proper list of data: its tail a list at every step, `[]` at the end.
  defp list?([]), do: true
  defp list?([head | tail]), do: data?(head) and list?(tail)
  defp list?(_improper), do: false

  @doc false
  # The kernel's encoding (`Macaw.Layers.Document.encode/1`, its version byte aside) of a
  # term this library holds as data: a table's header, which it builds from names and
  # types, or a column's value no packed form holds, judged with `data?/1` as the column
  # was built. A fault here is a defect in this library, the named invariant
  # (`built_not_data/1`).
  @spec encode(term()) :: iodata()
  def encode(term) do
    case Document.encode(term) do
      {:ok, bytes} -> bytes
      {:error, faults} -> built_not_data(faults)
    end
  end
end
