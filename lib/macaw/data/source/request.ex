defmodule Macaw.Data.Source.Request do
  @moduledoc """
  What a reader asks a source for (spec/01 §2.3).

  - `params`: the parameters, by name, checked against the description's before the call
    (`Macaw.Data.Parameter.validate/2`);
  - `window`: `[from, to]` over a `:time` or `:number` window field, either bound `nil` for
    open, or `nil`;
  - `box`: `%{west: w, south: s, east: e, north: n}` over a `:point` window field, in
    degrees, or `nil`;
  - `region`: ranges over named fields, `%{field => [from, to]}`, each over a `:time` or
    `:number` field, or `nil` (visualize's region, kept so a region-supporting feed has an
    equivalent; the owner's decision, 2026-10-27);
  - `latest`: `true` asks for each identity's latest row (spec/01 §1.4);
  - `order`: the order the reader looks at the rows in, `[{field, :asc | :desc}, ...]`,
    the first key deciding first, or `[]` for none (`Macaw.Data.Source.Order`): with a
    budget, the reader wants the first rows in it, not a sample;
  - `budget`: the most rows the reader wants, or `nil`;
  - `as_of`: the `DateTime` the answer is as of, for a source supporting `:as_of`, or `nil`;
  - `viewer`: the host's viewer, **opaque** here, passed to the source and never stored;
    `nil` is the anonymous viewer;
  - `now`: the instant, given by the surface; a source never reads a clock;
  - `subscription`: the reference of the push subscription this fetch is a snapshot for,
    or `nil`: a source given one states the snapshot's position in `served.position`
    (spec/01 §4.1).

  `new/1` builds one and reports every fault at once. A request asks; a source may not
  honor every part, and Macaw finishes what it does not (spec/01 §2.4).
  """

  @enforce_keys [:now]
  defstruct params: %{},
            window: nil,
            box: nil,
            region: nil,
            latest: false,
            order: [],
            budget: nil,
            as_of: nil,
            viewer: nil,
            now: nil,
            subscription: nil

  @type t :: %__MODULE__{
          params: map(),
          window: [term()] | nil,
          box: %{west: number(), south: number(), east: number(), north: number()} | nil,
          region: %{term() => [term()]} | nil,
          latest: boolean(),
          order: Macaw.Data.Source.Order.t(),
          budget: pos_integer() | nil,
          as_of: DateTime.t() | nil,
          viewer: term(),
          now: DateTime.t(),
          subscription: reference() | nil
        }

  @fields [
    :params,
    :window,
    :box,
    :region,
    :latest,
    :order,
    :budget,
    :as_of,
    :viewer,
    :now,
    :subscription
  ]

  @doc """
  A request of the given fields (a keyword list or a map), `now` required: `{:ok, request}`
  or every fault, `{[field], reason}`, ordered by field.

      iex> {:ok, r} = Macaw.Data.Source.Request.new(now: ~U[2026-10-27 12:00:00Z], budget: 100)
      iex> {r.budget, r.latest, r.viewer}
      {100, false, nil}
      iex> Macaw.Data.Source.Request.new(budget: 0)
      {:error, [{[:budget], {:type, :pos_integer}}, {[:now], :required}]}
  """
  @spec new(keyword() | map()) :: {:ok, t()} | {:error, [{list(), term()}, ...]}
  def new(fields) when is_list(fields) or is_map(fields) do
    given = Map.new(fields)

    faults =
      Enum.flat_map(given, fn {key, value} -> field(key, value) end) ++
        if(Map.has_key?(given, :now), do: [], else: [{[:now], :required}])

    case Enum.sort_by(faults, &elem(&1, 0)) do
      [] -> {:ok, struct!(__MODULE__, given)}
      faults -> {:error, faults}
    end
  end

  @doc "As `new/1`, raising `ArgumentError` naming every fault."
  @spec new!(keyword() | map()) :: t()
  def new!(fields) do
    case new(fields) do
      {:ok, request} -> request
      {:error, faults} -> raise ArgumentError, "not a request: #{inspect(faults)}"
    end
  end

  defp field(:params, p) when is_map(p) and not is_struct(p), do: []
  defp field(:params, _), do: [{[:params], {:type, :map}}]
  defp field(:window, nil), do: []
  defp field(:window, [_from, _to]), do: []
  defp field(:window, _), do: [{[:window], {:type, :window}}]
  defp field(:box, nil), do: []
  defp field(:box, box), do: if(box?(box), do: [], else: [{[:box], {:type, :box}}])
  defp field(:region, nil), do: []

  defp field(:region, region) when is_map(region) and map_size(region) > 0 do
    for {name, range} <- region, not match?([_, _], range), do: {[:region, name], {:type, :range}}
  end

  defp field(:region, _), do: [{[:region], {:type, :region}}]
  defp field(:latest, b) when is_boolean(b), do: []
  defp field(:latest, _), do: [{[:latest], {:type, :boolean}}]
  defp field(:order, order), do: Macaw.Data.Source.Order.shape(order)
  defp field(:budget, nil), do: []
  defp field(:budget, n) when is_integer(n) and n > 0, do: []
  defp field(:budget, _), do: [{[:budget], {:type, :pos_integer}}]
  defp field(:as_of, nil), do: []
  defp field(:as_of, %DateTime{}), do: []
  defp field(:as_of, _), do: [{[:as_of], {:type, :time}}]
  defp field(:viewer, _any), do: []
  defp field(:now, %DateTime{}), do: []
  defp field(:now, _), do: [{[:now], {:type, :time}}]
  defp field(:subscription, nil), do: []
  defp field(:subscription, ref) when is_reference(ref), do: []
  defp field(:subscription, _), do: [{[:subscription], {:type, :reference}}]
  defp field(key, _) when key not in @fields, do: [{[key], :unknown_key}]

  @doc """
  Whether a value is a box: four bounds in degrees, latitudes from −90 to 90 with `south`
  at most `north`, longitudes from −180 to 180; `west` east of `east` crosses the
  antimeridian.
  """
  @spec box?(term()) :: boolean()
  def box?(%{west: w, south: s, east: e, north: n} = box)
      when map_size(box) == 4 and is_number(w) and is_number(s) and is_number(e) and is_number(n),
      do: s <= n and s >= -90 and n <= 90 and w >= -180 and w <= 180 and e >= -180 and e <= 180

  def box?(_other), do: false
end
