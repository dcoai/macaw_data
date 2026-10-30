defmodule Macaw.Data.Table.Delta do
  @moduledoc false
  # A settled chunk's delta over its base (spec/01 §1.1.4), in the changelog's form: the
  # base rows retracted (a deleted set of their indexes, a deletion vector), the ranges
  # replaced (predicate deletes: a range of the window field, limited to identities,
  # matched on read, as Iceberg's equality deletes are), and the rows inserted (a side
  # chunk, in arrival order). Immutable: a change makes a new delta, and a reader holding
  # the old one is never affected.

  alias Macaw.Data.Schema
  alias Macaw.Data.Table
  alias Macaw.Data.Table.Origin

  defstruct deleted: MapSet.new(), predicates: [], side: [], window: nil

  @type predicate :: %{
          from: term(),
          to: term(),
          identities: [term()] | nil,
          schema: Schema.t() | nil
        }

  @type t :: %__MODULE__{
          deleted: MapSet.t(non_neg_integer()),
          predicates: [predicate()],
          side: [map()],
          window: term()
        }

  @doc false
  # How many changes the delta holds, against a quarter of its base's rows for compaction.
  @spec size(t()) :: non_neg_integer()
  def size(%__MODULE__{} = d), do: MapSet.size(d.deleted) + length(d.predicates) + length(d.side)

  @doc false
  # The rows as read: the base's rows (in order) without the deleted ones and those a
  # predicate matches, merged with the side chunk's in the window field's order, base rows
  # first among equal values, rows with no window value last. Each row with where it is
  # held, `{:base, i}` or `{:side, j}`.
  @spec read(t() | nil, [map()]) :: [{map(), {:base | :side, non_neg_integer()}}]
  def read(nil, rows), do: rows |> Enum.with_index() |> Enum.map(fn {r, i} -> {r, {:base, i}} end)

  def read(%__MODULE__{} = delta, rows) do
    base =
      for {row, i} <- Enum.with_index(rows),
          not MapSet.member?(delta.deleted, i),
          not Enum.any?(delta.predicates, &matches?(row, &1, delta.window)),
          do: {row, {:base, i}}

    side = delta.side |> Enum.with_index() |> Enum.map(fn {r, j} -> {r, {:side, j}} end)
    merge(base, side, delta.window)
  end

  @doc false
  # Whether a row lies in a replacement's scope (spec/01 §4.2): in its range, a row with no
  # window value only in a range open at both ends, and among its identities.
  @spec matches?(map(), predicate(), term()) :: boolean()
  def matches?(row, %{identities: ids, schema: schema} = p, window) do
    in_range?(row, p, window) and (ids == nil or Schema.identity(schema, row) in ids)
  end

  defp in_range?(_row, %{from: nil, to: nil}, _window), do: true
  defp in_range?(_row, _p, nil), do: false

  defp in_range?(row, %{from: from, to: to}, window) do
    case Origin.position(Table.get(row, window)) do
      t when is_number(t) ->
        (from == nil or t >= Origin.position(from)) and (to == nil or t < Origin.position(to))

      _none ->
        false
    end
  end

  # Two runs, each in the window field's order, merged stably: the first's rows first among
  # equal values; rows with no window value last.
  defp merge(base, [], _window), do: base

  defp merge(base, side, window) do
    key = fn {row, _ref} ->
      case window && Origin.position(Table.get(row, window)) do
        p when is_number(p) -> {0, p}
        _none -> {1, 0}
      end
    end

    (Enum.map(base, &{key.(&1), 0, &1}) ++ Enum.map(side, &{key.(&1), 1, &1}))
    |> Enum.with_index()
    |> Enum.sort_by(fn {{k, source, _row}, i} -> {k, source, i} end)
    |> Enum.map(fn {{_k, _source, row}, _i} -> row end)
  end
end
