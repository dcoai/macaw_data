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
