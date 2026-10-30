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
  # The header and a value no packed form holds are in the kernel's own encoding
  # (`Macaw.Layers.Document.digest/1`), copied below byte for byte: the kernel keeps its
  # encoder private (macaw_layers#18 asks for it, and for a hook through which the kernel's
  # digest of a table would be this one).

  alias Macaw.Data.Table.Canonical
  alias Macaw.Data.Table.Column

  # The version of this form, and of the kernel's encoding it uses.
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

  @doc """
  Whether a value is data the kernel's digest encodes: an atom, a number, a bitstring,
  and proper lists, tuples and maps of data. A function, a PID, a reference, a port and an
  improper list are not.
  """
  @spec data?(term()) :: boolean()
  def data?(v) when is_atom(v) or is_number(v) or is_bitstring(v), do: true
  def data?(tuple) when is_tuple(tuple), do: tuple |> Tuple.to_list() |> data?()

  def data?(map) when is_map(map),
    do: map |> :maps.to_list() |> Enum.all?(fn {k, v} -> data?(k) and data?(v) end)

  def data?(list) when is_list(list), do: list?(list)
  def data?(_other), do: false

  # A proper list of data: its tail a list at every step, `[]` at the end.
  defp list?([]), do: true
  defp list?([head | tail]), do: data?(head) and list?(tail)
  defp list?(_improper), do: false

  @doc false
  # The kernel's canonical encoding of a term, without its version byte.
  @spec encode(term()) :: iodata()
  def encode(term)

  def encode(atom) when is_atom(atom), do: sized(?a, Atom.to_string(atom))
  def encode(binary) when is_binary(binary), do: sized(?b, binary)
  def encode(int) when is_integer(int), do: sized(?i, Integer.to_string(int))
  def encode(float) when is_float(float), do: [?f | <<float::float-64>>]

  def encode(bits) when is_bitstring(bits) do
    size = bit_size(bits)
    [?s, <<size::64>>, <<bits::bitstring, 0::size(8 - rem(size, 8))>>]
  end

  def encode(list) when is_list(list),
    do: [?l, <<length_of(list, list, 0)::64>> | Enum.map(list, &encode/1)]

  def encode(tuple) when is_tuple(tuple),
    do: [?t, <<tuple_size(tuple)::64>> | tuple |> Tuple.to_list() |> Enum.map(&encode/1)]

  def encode(map) when is_map(map) do
    entries =
      map
      |> :maps.to_list()
      |> Enum.map(fn {k, v} -> {IO.iodata_to_binary(encode(k)), v} end)
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.map(fn {k, v} -> [k | encode(v)] end)

    [?m, <<map_size(map)::64>> | entries]
  end

  def encode(other), do: not_data(other)

  defp sized(tag, bytes), do: [tag, <<byte_size(bytes)::64>> | bytes]

  defp length_of([_ | tail], list, n), do: length_of(tail, list, n + 1)
  defp length_of([], _list, n), do: n
  defp length_of(_tail, list, _n), do: not_data(list)

  defp not_data(term),
    do: raise(ArgumentError, "not data, so it has no digest: #{inspect(term)}")
end
