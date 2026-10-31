defmodule Macaw.Data.Source.Description do
  @moduledoc """
  What a source is (spec/01 §2.1): its schema, its parameters, the capabilities it
  honors, and whether it answers every viewer the same.

  - `schema`: a `Macaw.Data.Schema`;
  - `params`: the parameters it takes, by name (strings), each a `Macaw.Data.Parameter`;
  - `supports`: the capabilities it honors, distinct, among `:window | :box | :region |
    :latest | :order | :budget | :push | :as_of`. Every one is optional: Macaw finishes
    what a source does not honor (spec/01 §2.4);
  - `viewer_independent`: `true` declares the source answers every viewer the same, which
    only allows pooling across viewers, fetched with the anonymous viewer (spec/01 §6).
    `false` by default;
  - `lateness`: a hard bound on how late a change may be, declared only by a source that
    refuses changes past some age (spec/01 §4.4): a `Duration` over a `:time` window
    field, a non-negative number in the field's units over a `:number` one; `nil` by
    default, accepting a change of any age;
  - `idle_after`: milliseconds the source may deliver nothing before a derived source's
    watermark leaves it out (spec/02 §8.6), a positive integer; `nil` by default, never
    idle;
  - `chunk_span`: the span of the window field a chunk of the source's table holds
    (spec/01 §1.1.3), declared because the source knows its rate: a positive `Duration`
    of fixed length over a `:time` window field, a positive number over a `:number` one;
    `nil` by default, derived from the resolution by `chunk_span/2`.

  `new/1` builds one and reports every fault at once.
  """

  alias Macaw.Data.{Parameter, Schema, Table}
  alias Macaw.Data.Table.Origin

  # A named resolution's seconds, for the span derived from it (spec/01 §1.1.3).
  @seconds %{second: 1, minute: 60, hour: 3600, day: 86_400}

  @capabilities [:window, :box, :region, :latest, :order, :budget, :push, :as_of]

  @enforce_keys [:schema]
  defstruct [
    :schema,
    params: %{},
    supports: [],
    viewer_independent: false,
    lateness: nil,
    idle_after: nil,
    chunk_span: nil
  ]

  @typedoc "A capability a source may honor."
  @type capability :: :window | :box | :region | :latest | :order | :budget | :push | :as_of

  @type t :: %__MODULE__{
          schema: Schema.t(),
          params: %{String.t() => Parameter.t()},
          supports: [capability()],
          viewer_independent: boolean(),
          lateness: Duration.t() | number() | nil,
          idle_after: pos_integer() | nil,
          chunk_span: Duration.t() | number() | nil
        }

  @doc "The capabilities, in the order spec/01 §2.1 lists them."
  @spec capabilities() :: [capability(), ...]
  def capabilities, do: @capabilities

  @doc """
  A description of the given fields, `schema` required: `{:ok, description}` or every
  fault, `{path, reason}`, ordered by path.

      iex> alias Macaw.Data.{Schema, Source.Description}
      iex> {:ok, d} = Description.new(schema: Schema.new!(%{v: %{type: :number}}), supports: [:budget])
      iex> {d.supports, d.viewer_independent}
      {[:budget], false}
      iex> Description.new(schema: :nope, supports: [:region, :teleport, :region])
      {:error, [{[:schema], {:type, :schema}}, {[:supports, 1], {:enum, Description.capabilities()}}, {[:supports, 2], :duplicate}]}
  """
  @spec new(keyword() | map()) :: {:ok, t()} | {:error, [{list(), term()}, ...]}
  def new(fields) when is_list(fields) or is_map(fields) do
    given = Map.new(fields)

    faults =
      Enum.flat_map(given, fn {key, value} -> field(key, value) end) ++
        if(Map.has_key?(given, :schema), do: [], else: [{[:schema], :required}]) ++
        lateness(Map.get(given, :lateness), Map.get(given, :schema)) ++
        span_faults(Map.get(given, :chunk_span), Map.get(given, :schema))

    case Enum.sort_by(faults, &elem(&1, 0)) do
      [] -> {:ok, struct!(__MODULE__, given)}
      faults -> {:error, faults}
    end
  end

  @doc "As `new/1`, raising `ArgumentError` naming every fault."
  @spec new!(keyword() | map()) :: t()
  def new!(fields) do
    case new(fields) do
      {:ok, description} -> description
      {:error, faults} -> raise ArgumentError, "not a description: #{inspect(faults)}"
    end
  end

  defp field(:schema, %Schema{}), do: []
  defp field(:schema, _), do: [{[:schema], {:type, :schema}}]

  defp field(:params, params) when is_map(params) and not is_struct(params) do
    Enum.flat_map(params, fn {name, parameter} ->
      cond do
        not (is_binary(name) and name != "") ->
          [{[:params, name], {:type, :name}}]

        true ->
          case Parameter.check(parameter) do
            :ok -> []
            {:error, faults} -> Enum.map(faults, fn {path, r} -> {[:params, name | path], r} end)
          end
      end
    end)
  end

  defp field(:params, _), do: [{[:params], {:type, :map}}]

  defp field(:supports, supports) when is_list(supports) do
    supports
    |> Enum.with_index()
    |> Enum.reduce({MapSet.new(), []}, fn {c, i}, {seen, faults} ->
      cond do
        c not in @capabilities -> {seen, [{[:supports, i], {:enum, @capabilities}} | faults]}
        MapSet.member?(seen, c) -> {seen, [{[:supports, i], :duplicate} | faults]}
        true -> {MapSet.put(seen, c), faults}
      end
    end)
    |> elem(1)
  end

  defp field(:supports, _), do: [{[:supports], {:type, :list}}]
  defp field(:viewer_independent, b) when is_boolean(b), do: []
  defp field(:viewer_independent, _), do: [{[:viewer_independent], {:type, :boolean}}]
  # Judged against the schema's window field by `lateness/2`.
  defp field(:lateness, _), do: []
  defp field(:chunk_span, _), do: []
  defp field(:idle_after, nil), do: []
  defp field(:idle_after, ms) when is_integer(ms) and ms > 0, do: []
  defp field(:idle_after, _), do: [{[:idle_after], {:type, :pos_integer}}]
  defp field(key, _), do: [{[key], :unknown_key}]

  # A hard bound in the window field's terms: a `Duration` back from a time, a
  # non-negative number back from a number (spec/01 §4.4).
  defp lateness(nil, _schema), do: []

  defp lateness(lateness, %Schema{} = schema) do
    case Schema.window_field(schema) && schema.fields[Schema.window_field(schema)].type do
      nil ->
        [{[:lateness], :no_window_field}]

      :time ->
        if match?(%Duration{}, lateness), do: [], else: [{[:lateness], {:type, :duration}}]

      :number ->
        if is_number(lateness) and lateness >= 0, do: [], else: [{[:lateness], {:type, :number}}]

      _box ->
        [{[:lateness], :no_window_field}]
    end
  end

  defp lateness(_lateness, _no_schema), do: []

  # A chunk span in the window field's terms: a fixed positive `Duration` over a time, a
  # positive number over a number (spec/01 §1.1.3).
  defp span_faults(nil, _schema), do: []

  defp span_faults(span, %Schema{} = schema) do
    case window_type(schema) do
      :time ->
        if Origin.span_us(span), do: [], else: [{[:chunk_span], {:type, :duration}}]

      :number ->
        if is_number(span) and span > 0, do: [], else: [{[:chunk_span], {:type, :number}}]

      _none ->
        [{[:chunk_span], :no_window_field}]
    end
  end

  defp span_faults(_span, _no_schema), do: []

  defp window_type(schema),
    do: Schema.window_field(schema) && schema.fields[Schema.window_field(schema)].type

  @doc """
  The span of the window field a chunk of the source's table holds, at `resolution`, the
  resolution its relation is held at (`served.resolution`; spec/01 §1.1.3). The declared
  `chunk_span` when there is one; else `Macaw.Data.Table.chunk_rows/0` times the
  resolution: of *r* seconds (a positive number, or `:second`, `:minute`, `:hour` or
  `:day`) a `Duration` over a `:time` window field, of *r* in the field's units a number
  over a `:number` one. `nil` for a resolution it can't read and for a source with no time
  or number window field: its chunks are aligned by row count. Never from the data.

      iex> alias Macaw.Data.{Schema, Source.Description}
      iex> d = Description.new!(schema: Schema.new!(%{t: %{type: :time}}))
      iex> Description.chunk_span(d, :minute)
      Duration.new!(second: 491_520)
      iex> Description.chunk_span(d, nil)
      nil
  """
  @spec chunk_span(t(), term()) :: Duration.t() | number() | nil
  def chunk_span(%__MODULE__{chunk_span: span}, _resolution) when span != nil, do: span

  def chunk_span(%__MODULE__{schema: schema}, resolution) do
    case {window_type(schema), seconds(resolution)} do
      {:time, seconds} when seconds != nil ->
        us = round(seconds * 1_000_000 * Table.chunk_rows())

        case rem(us, 1_000_000) do
          0 -> Duration.new!(second: div(us, 1_000_000))
          micro -> Duration.new!(second: div(us, 1_000_000), microsecond: {micro, 6})
        end

      {:number, _} when is_number(resolution) and resolution > 0 ->
        resolution * Table.chunk_rows()

      _ ->
        nil
    end
  end

  defp seconds(r) when is_number(r) and r > 0, do: r
  defp seconds(r) when is_map_key(@seconds, r), do: Map.fetch!(@seconds, r)
  defp seconds(_r), do: nil
end
