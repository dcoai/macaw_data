defmodule Macaw.Data.Table.Column.Point do
  @moduledoc false
  # A `:point` column's packed form (spec/01 §1.1, macaw_data#234):
  #
  #   {:point, xs, ys, validity}
  #
  # `xs` and `ys` are the coordinates as two `:number` columns, each packed as a number
  # column of them packs (`Macaw.Data.Table.Column.pack/3`): int64, float64, integral or
  # union, whatever its coordinates need, a missing point missing in both. `validity` is
  # the points' own bitmap. Where a coordinate is past int64, which a number column holds
  # as a list, the point column is a list too. So every form reads back the points given,
  # each coordinate the integer or the float it was.
  #
  # Every operation on the form is its children's: a slice, a gather, a join end to end
  # (`Column.Concat`, `Column.Append`) is each coordinate's and the validity's.

  alias Macaw.Data.Table.{Bitmap, Column}

  @doc false
  # Points, each a `{number, number}` or `nil`, packed: the form above, or `{:list,
  # points}` where a coordinate is past int64.
  @spec pack([{number(), number()} | nil]) :: Column.t()
  def pack(points) do
    {xs, ys} = unzip(points, [], [])

    case {Column.pack(:number, xs, nil), Column.pack(:number, ys, nil)} do
      {{:ok, {:list, _}}, _ys} -> {:list, points}
      {_xs, {:ok, {:list, _}}} -> {:list, points}
      {{:ok, x}, {:ok, y}} -> {:point, x, y, Bitmap.validity(points)}
    end
  end

  defp unzip([], xs, ys), do: {:lists.reverse(xs), :lists.reverse(ys)}
  defp unzip([nil | rest], xs, ys), do: unzip(rest, [nil | xs], [nil | ys])
  defp unzip([{x, y} | rest], xs, ys), do: unzip(rest, [x | xs], [y | ys])

  @doc false
  # The `n` points, `nil` where one is missing: each coordinate column read once.
  @spec values(Column.t(), non_neg_integer()) :: [{number(), number()} | nil]
  def values({:point, xs, ys, _validity}, n), do: zip(Column.values(xs, n), Column.values(ys, n))

  defp zip([nil | xs], [nil | ys]), do: [nil | zip(xs, ys)]
  defp zip([x | xs], [y | ys]), do: [{x, y} | zip(xs, ys)]
  defp zip([], []), do: []

  @doc false
  @spec slice(Column.t(), non_neg_integer(), non_neg_integer()) :: Column.t()
  def slice({:point, xs, ys, validity}, first, n),
    do:
      {:point, Column.slice(xs, first, n), Column.slice(ys, first, n),
       Bitmap.slice(validity, first, n)}

  @doc false
  @spec gather(Column.t(), [non_neg_integer()]) :: Column.t()
  def gather({:point, xs, ys, validity}, indexes),
    do:
      {:point, Column.gather(xs, indexes), Column.gather(ys, indexes),
       Bitmap.take(validity, indexes, nil)}

  @doc false
  # Point columns of `n` points each joined end to end by `join`, applied to each
  # coordinate's pieces (`Column.concat/1`, or `Column.Append.append/2` of two): `{:ok,
  # column}`, or `fallback` where either coordinate's join answers it.
  @spec joined([{Column.t(), non_neg_integer()}], (list() -> {:ok, Column.t()} | atom())) ::
          {:ok, Column.t()} | atom()
  def joined(pieces, join) do
    with {:ok, x} <- join.(for {{:point, x, _y, _v}, n} <- pieces, do: {x, n}),
         {:ok, y} <- join.(for {{:point, _x, y, _v}, n} <- pieces, do: {y, n}) do
      {:ok, {:point, x, y, Bitmap.concat(for {{:point, _x, _y, v}, n} <- pieces, do: {v, n})}}
    end
  end
end
