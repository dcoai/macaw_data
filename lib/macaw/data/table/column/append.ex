defmodule Macaw.Data.Table.Column.Append do
  @moduledoc false
  # Two pieces of one column joined end to end exactly as packing their values together
  # would pack them (macaw_data#204): the held rows of an open chunk, as they lie, and
  # the rows an increment adds after them, packed by themselves. `{:ok, column}` only
  # where the join is byte for byte `Column.pack/3` of every value, so the chunk built
  # from it is the chunk a full rewrite builds; `:repack` wherever it might not be, and
  # the caller packs every value again.
  #
  # Each piece must be packed from its own values (`Column.pack/3`) or be `head/2` of
  # such a column. A form is joined only where packing
  # the values together picks the same form:
  #
  # - int64 and int64, float64 and float64, date and date: their buffers and validity
  #   joined. Packing picks int64 for numbers with no float, float64 for floats with no
  #   integer, so two pieces of one form keep it; any other pair (an all-missing piece
  #   packs as int64) is repacked.
  # - utc and utc, naive and naive: the instants and validity joined, the precision the
  #   one every present value shares (a piece with no value present has none to share),
  #   or both pieces' per-value bytes joined where both already spell it per value. Two
  #   uniform precisions that differ, or one uniform and one spelled, are repacked.
  # - text and text, binary and binary: the data joined, offsets moved, while the whole
  #   fits int32 offsets. A string's validity as UTF-8 is its own, so the pair keeps its
  #   form; text beside binary is repacked.
  # - dictionary and dictionary: the first piece's dictionary is its strings in
  #   first-appearance order, and joining it with the second's in order is the order
  #   packing every value gives. A slice keeps its column's whole dictionary, strings its
  #   rows may lack, so the kept rows are cut by `head/2` to the strings they hold.
  #
  # - terms and terms: as dictionary and dictionary, the kept values' terms cut by
  #   `head/2` to those they hold (`Column.Terms`).
  # - point and point: each coordinate joined as the number column it is (int64 or
  #   float64 by both pieces), the validity joined. Packing every point gives a point
  #   column where no coordinate is past int64, which neither piece's is, and each
  #   coordinate the form packing its values gives, which its join keeps.
  #
  # Every other form (integral, union, zoned, bool, list) is repacked.

  import Bitwise

  alias Macaw.Data.Table.Column

  @doc false
  @spec append({Column.t(), non_neg_integer()}, {Column.t(), non_neg_integer()}) ::
          {:ok, Column.t()} | :repack
  def append({head, n}, {tail, m}) do
    case {head, tail} do
      {{form, _, _}, {form, _, _}} when form in [:int64, :float64, :date] ->
        concat(head, n, tail, m)

      {{form, _, hv, hp}, {form, _, tv, tp}} when form in [:utc, :naive] ->
        with {:ok, precision} <- precision({hp, hv, n}, {tp, tv, m}),
             {:ok, {^form, us, validity, _p}} <- concat(head, n, tail, m) do
          {:ok, {form, us, validity, precision}}
        end

      {{form, _, data, _}, {form, _, _, _}}
      when form in [:text, :binary] and is_binary(data) ->
        concat(head, n, tail, m)

      {{:dictionary, _, _, _, _}, {:dictionary, _, _, _, _}} ->
        concat(head, n, tail, m)

      {{:terms, _, _, _}, {:terms, _, _, _}} ->
        concat(head, n, tail, m)

      {{:point, _, _, _}, {:point, _, _, _}} ->
        Column.Point.joined([{head, n}, {tail, m}], fn [x, y] -> append(x, y) end)

      _other ->
        :repack
    end
  end

  @doc false
  # The first `at` values of a column packed from its own values, as `append/2` takes
  # them: a slice (`Column.slice/3`), a dictionary's cut to the strings those values
  # hold. Codes number strings in first-appearance order, so the kept values hold codes
  # 0 to k - 1 and their strings are the dictionary's first k: the dictionary packing
  # them alone gives.
  @spec head(Column.t(), non_neg_integer()) :: Column.t()
  def head({:dictionary, _codes, _validity, _dictionary, _booleans} = column, at) do
    {:dictionary, codes, validity, {offsets, data}, booleans} = Column.slice(column, 0, at)
    k = held_strings(codes, validity, booleans, at)
    <<_::binary-size(^k * 4), last::signed-little-32, _::binary>> = offsets

    {:dictionary, codes, validity,
     {binary_part(offsets, 0, (k + 1) * 4), binary_part(data, 0, last)}, booleans}
  end

  def head({:terms, _codes, _validity, _terms} = column, at), do: Column.Terms.head(column, at)
  def head(column, at), do: Column.slice(column, 0, at)

  # How many strings the first `n` slots hold: one past the largest code, or none where
  # no slot holds a string (a missing or boolean slot holds code 0).
  defp held_strings(codes, validity, booleans, n) do
    case Enum.reduce(for(<<c::little-32 <- codes>>, do: c), 0, &max/2) do
      0 -> if holds_string?(validity, booleans, n), do: 1, else: 0
      top -> top + 1
    end
  end

  defp holds_string?(_validity, _booleans, 0), do: false

  defp holds_string?(validity, booleans, n) do
    mask = (1 <<< n) - 1
    kinds = if booleans, do: int(elem(booleans, 0)), else: 0
    (int(validity) &&& bnot(kinds) &&& mask) != 0
  end

  defp int(bitmap) do
    size = byte_size(bitmap)
    <<x::little-size(^size * 8)>> = bitmap
    x
  end

  defp concat(head, n, tail, m) do
    case Column.concat([{head, n}, {tail, m}]) do
      {:ok, column} -> {:ok, column}
      :general -> :repack
    end
  end

  # The precision packing every value gives: the one all present values share, `6` with
  # none present, or both pieces' bytes where both spell it per value.
  defp precision({hp, hv, n}, {tp, tv, m}) when is_integer(hp) and is_integer(tp) do
    case {present?(hv, n), present?(tv, m)} do
      {false, false} -> {:ok, 6}
      {true, false} -> {:ok, hp}
      {false, true} -> {:ok, tp}
      {true, true} when hp == tp -> {:ok, hp}
      {true, true} -> :repack
    end
  end

  defp precision({hp, _hv, _n}, {tp, _tv, _m}) when is_binary(hp) and is_binary(tp),
    do: {:ok, hp <> tp}

  defp precision(_head, _tail), do: :repack

  # Whether any of the first `n` bits of a validity bitmap is set.
  defp present?(_validity, 0), do: false

  defp present?(validity, n), do: (int(validity) &&& (1 <<< n) - 1) != 0
end
