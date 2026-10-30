defmodule Macaw.Data.Operations.Transforms.Ladder.Packed do
  @moduledoc """
  A ladder piece as one binary (spec/04 §4.5.1; macaw_data#38, #46): its segments as
  fixed-width records, so a partial the caller's cache holds is a few words on its heap,
  an off-heap binary beside it, and the merge reads buffers rather than terms. The Elixir
  walk and the native kernel (`Ladder.partial/4`) answer the same bytes.

  **The packed form**, little-endian throughout:

      <<1, s_type, y_type, 0, segments::32, heads::binary-size(8 * segments), buckets::binary>>

  - `s_type` and `y_type`: `0` every point's `s` (or `y`) an int64, `1` every one a float64
    (both `0` with no bucket);
  - a head per segment in row order, 8 bytes: `<<0, 0::24, row::32>>` a gap, its first row;
    `<<1, 0::24, buckets::32>>` a run, its count of buckets;
  - the runs' buckets in order, 88 bytes each: `<<b::signed-64>>`, then its first, last,
    least and greatest points, each `<<row::32, s::64, y::64>>`.

  **The term form**, `<<2, external term format of the segments>>`, holds a piece whose
  points are not all of one number type, or past int64 (a log scale's integer bucket, a
  macaw form's mixed readings): every value is kept exactly, as the walk answered it.
  """

  @packed 1
  @term 2
  @int64_min -0x8000_0000_0000_0000
  @int64_max 0x7FFF_FFFF_FFFF_FFFF

  defguardp int64(v) when is_integer(v) and v >= @int64_min and v <= @int64_max

  @typedoc "A piece's segments, as `Ladder` reads them."
  @type segments :: [{:run, [{integer(), tuple()}]} | {:gap, non_neg_integer()}]

  @doc "A piece's segments as one binary: packed where its points share their types, else as a term."
  @spec pack(segments()) :: binary()
  def pack(segments) do
    {st, yt} = types(segments)

    case encode(segments, st, yt, 0, <<>>, <<>>) do
      {n, heads, body} -> <<@packed, st, yt, 0, n::little-32, heads::binary, body::binary>>
      :term -> <<@term, :erlang.term_to_binary(segments)::binary>>
    end
  end

  # The types of the first point read: a piece's points are of one column each, so of one
  # type, except a macaw form's, which then fails a guard and is kept as a term.
  defp types([{:run, [{_b, {{_r, s, y}, _l, _lo, _hi}} | _]} | _]), do: {type(s), type(y)}
  defp types([_gap | rest]), do: types(rest)
  defp types([]), do: {0, 0}

  defp type(v) when is_float(v), do: 1
  defp type(_v), do: 0

  defp encode([], _st, _yt, n, heads, body), do: {n, heads, body}

  defp encode([{:gap, row} | rest], st, yt, n, heads, body),
    do: encode(rest, st, yt, n + 1, <<heads::binary, 0, 0::24, row::little-32>>, body)

  defp encode([{:run, run} | rest], st, yt, n, heads, body) do
    case buckets(run, st, yt, 0, body) do
      {count, body} ->
        encode(rest, st, yt, n + 1, <<heads::binary, 1, 0::24, count::little-32>>, body)

      :term ->
        :term
    end
  end

  # One clause a pair of types, each reading its points' values with that type's guard and
  # writing them with its segment type.
  for {st, s_spec, s_guard} <- [
        {0, quote(do: signed - integer), :int64},
        {1, quote(do: float), :is_float}
      ],
      {yt, y_spec, y_guard} <- [
        {0, quote(do: signed - integer), :int64},
        {1, quote(do: float), :is_float}
      ] do
    defp buckets(
           [{b, {{r1, s1, y1}, {r2, s2, y2}, {r3, s3, y3}, {r4, s4, y4}}} | rest],
           unquote(st),
           unquote(yt),
           count,
           body
         )
         when int64(b) and unquote(s_guard)(s1) and unquote(s_guard)(s2) and
                unquote(s_guard)(s3) and unquote(s_guard)(s4) and unquote(y_guard)(y1) and
                unquote(y_guard)(y2) and unquote(y_guard)(y3) and unquote(y_guard)(y4) do
      body =
        <<body::binary, b::little-signed-64, r1::little-32, s1::little-unquote(s_spec)-64,
          y1::little-unquote(y_spec)-64, r2::little-32, s2::little-unquote(s_spec)-64,
          y2::little-unquote(y_spec)-64, r3::little-32, s3::little-unquote(s_spec)-64,
          y3::little-unquote(y_spec)-64, r4::little-32, s4::little-unquote(s_spec)-64,
          y4::little-unquote(y_spec)-64>>

      buckets(rest, unquote(st), unquote(yt), count + 1, body)
    end
  end

  defp buckets([], _st, _yt, count, body), do: {count, body}
  defp buckets(_run, _st, _yt, _count, _body), do: :term

  @doc "A piece's segments, as `pack/1` was given them."
  @spec unpack(binary()) :: segments()
  def unpack(piece), do: read(piece, nil)

  @doc """
  A piece's segments read as view `v`'s: each gap `{:gap, {v, row}}` and each bucket
  `{b, {v, summary}}`, as `Ladder.runs/1` joins them.
  """
  @spec located(binary(), non_neg_integer()) :: list()
  def located(piece, v) when is_integer(v), do: read(piece, v)

  defp read(<<@packed, st, yt, 0, n::little-32, rest::binary>>, v) do
    size = 8 * n
    <<heads::binary-size(^size), body::binary>> = rest
    segments(heads, body, st, yt, v, [])
  end

  defp read(<<@term, etf::binary>>, nil), do: :erlang.binary_to_term(etf)

  defp read(<<@term, etf::binary>>, v) do
    for segment <- :erlang.binary_to_term(etf) do
      case segment do
        {:gap, row} -> {:gap, {v, row}}
        {:run, run} -> {:run, for({b, s} <- run, do: {b, {v, s}})}
      end
    end
  end

  defp segments(<<>>, <<>>, _st, _yt, _v, acc), do: :lists.reverse(acc)

  defp segments(<<0, 0::24, row::little-32, heads::binary>>, body, st, yt, nil, acc),
    do: segments(heads, body, st, yt, nil, [{:gap, row} | acc])

  defp segments(<<0, 0::24, row::little-32, heads::binary>>, body, st, yt, v, acc),
    do: segments(heads, body, st, yt, v, [{:gap, {v, row}} | acc])

  defp segments(<<1, 0::24, count::little-32, heads::binary>>, body, st, yt, v, acc) do
    {run, body} = run(body, count, st, yt, v, [])
    segments(heads, body, st, yt, v, [{:run, run} | acc])
  end

  # A run's `count` buckets off the front of `body`, each `{b, summary}`, or `{b, {v,
  # summary}}` read as view `v`'s. A point that is two of the bucket's (its first and its
  # least, say) is read twice, two equal terms.
  for {st, s_spec} <- [{0, quote(do: signed - integer)}, {1, quote(do: float)}],
      {yt, y_spec} <- [{0, quote(do: signed - integer)}, {1, quote(do: float)}] do
    defp run(
           <<b::little-signed-64, r1::little-32, s1::little-unquote(s_spec)-64,
             y1::little-unquote(y_spec)-64, r2::little-32, s2::little-unquote(s_spec)-64,
             y2::little-unquote(y_spec)-64, r3::little-32, s3::little-unquote(s_spec)-64,
             y3::little-unquote(y_spec)-64, r4::little-32, s4::little-unquote(s_spec)-64,
             y4::little-unquote(y_spec)-64, body::binary>>,
           count,
           unquote(st),
           unquote(yt),
           v,
           acc
         )
         when count > 0 do
      summary = {{r1, s1, y1}, {r2, s2, y2}, {r3, s3, y3}, {r4, s4, y4}}
      entry = if v == nil, do: {b, summary}, else: {b, {v, summary}}
      run(body, count - 1, unquote(st), unquote(yt), v, [entry | acc])
    end
  end

  defp run(body, 0, _st, _yt, _v, acc), do: {:lists.reverse(acc), body}
end
