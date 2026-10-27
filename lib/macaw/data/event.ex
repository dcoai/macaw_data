defmodule Macaw.Data.Event do
  @moduledoc """
  The one interaction shape every component emits (Macaw spec 02 §8).

  It lives in `macaw_data`, the smallest Macaw package, so an adopter using
  no other Macaw library (visualize, standalone) emits the same value it
  emits on a Macaw page.

  - `name`: the event's name, a string the component declares (`"pick"`,
    `"brush"`).
  - `instance`: the emitting instance's id.
  - `element`: what was acted on. `item` is the element's stable id;
    `path` lists its enclosing elements, innermost first; `frame` is set
    only by components with an inner coordinate tree (a visual's frame).
  - `identity`: the item's **declared** identity (`%{field => value}`),
    when it maps to data. Inference from other fields is the component's,
    only for a visitor's one-off pick, never for tracking.
  - `value`: the event's own value: a window, a chosen option.
  - `initiator`: `:visitor` or `:system`, which separates a view path's
    steps from its markers.
  - `time`: the holder's now (a surface's, or a standalone holder's), never
    a clock read by the component.
  - `point`: where, in the drawing; live only.
  - `modifiers`: the keys held, from `:shift`, `:alt`, `:ctrl` and `:meta`.
  - `row`: the data row, delivered to the host, **never recorded**.

  **The recorded form** (`recordable/1`) drops `row` and `point`. Records,
  observation and state snapshots only ever see it, so row values never
  reach them; `identity` and `value` do, and whether they are recorded is
  decided per state source by capture level.

  Decoding a click from the wire and resolving it against the drawing it
  landed on (the drawn-token rule) belong to the component that drew it,
  not here.
  """

  @modifiers [:shift, :alt, :ctrl, :meta]

  @enforce_keys [:name, :instance, :initiator, :time]
  defstruct name: nil,
            instance: nil,
            element: %{frame: nil, item: nil, path: []},
            identity: nil,
            value: nil,
            initiator: nil,
            time: nil,
            point: nil,
            modifiers: [],
            row: nil

  @type id :: term()
  @type modifier :: :shift | :alt | :ctrl | :meta
  @type element :: %{frame: id() | nil, item: id() | nil, path: [id()]}

  @type t :: %__MODULE__{
          name: String.t(),
          instance: String.t(),
          element: element(),
          identity: %{optional(term()) => term()} | nil,
          value: term(),
          initiator: :visitor | :system,
          time: DateTime.t(),
          point: {number(), number()} | nil,
          modifiers: [modifier()],
          row: map() | nil
        }

  @typedoc "The recorded form: an event without its data row or point."
  @type recorded :: %{
          name: String.t(),
          instance: String.t(),
          element: element(),
          identity: %{optional(term()) => term()} | nil,
          value: term(),
          initiator: :visitor | :system,
          time: DateTime.t(),
          modifiers: [modifier()]
        }

  @fields [
    :name,
    :instance,
    :element,
    :identity,
    :value,
    :initiator,
    :time,
    :point,
    :modifiers,
    :row
  ]

  @doc "The struct's fields, in spec order."
  @spec fields() :: [atom()]
  def fields, do: @fields

  @doc """
  The recorded form: everything but `row` and `point`, as a plain map. What
  records, observation and state snapshots see.
  """
  @spec recordable(t()) :: recorded()
  def recordable(%__MODULE__{} = event),
    do: event |> Map.from_struct() |> Map.drop([:row, :point])

  @doc """
  Builds an event from a keyword list or map, checking every field:
  `{:ok, event}`, or `{:error, faults}` naming each bad field. Unknown
  fields are faults too, never silently dropped.
  """
  @spec new(keyword() | map()) :: {:ok, t()} | {:error, [{atom() | term(), String.t()}]}
  def new(attrs) when is_list(attrs), do: attrs |> Map.new() |> new()

  def new(attrs) when is_map(attrs) do
    unknown = for key <- Map.keys(attrs), key not in @fields, do: {key, "is not an event field"}
    attrs = Map.take(attrs, @fields)

    checks = [
      {:name,
       check(Map.get(attrs, :name), &(is_binary(&1) and &1 != ""), "must be a non-empty string")},
      {:instance,
       check(
         Map.get(attrs, :instance),
         &(is_binary(&1) and &1 != ""),
         "must be a non-empty string"
       )},
      {:initiator,
       check(
         Map.get(attrs, :initiator),
         &(&1 in [:visitor, :system]),
         "must be :visitor or :system"
       )},
      {:time, check(Map.get(attrs, :time), &match?(%DateTime{}, &1), "must be a DateTime")},
      {:element,
       check(
         Map.get(attrs, :element, %{path: []}),
         &element?/1,
         "must be %{frame, item, path} with path a list"
       )},
      {:identity,
       check(Map.get(attrs, :identity), &(is_nil(&1) or is_map(&1)), "must be a map or nil")},
      {:point, check(Map.get(attrs, :point), &point?/1, "must be {x, y} numbers or nil")},
      {:modifiers,
       check(
         Map.get(attrs, :modifiers, []),
         &modifiers?/1,
         "must be a list of #{inspect(@modifiers)}"
       )},
      {:row, check(Map.get(attrs, :row), &(is_nil(&1) or is_map(&1)), "must be a map or nil")}
    ]

    case unknown ++ for({field, {:error, why}} <- checks, do: {field, why}) do
      [] ->
        element = Map.merge(%{frame: nil, item: nil, path: []}, Map.get(attrs, :element, %{}))
        {:ok, struct!(__MODULE__, Map.put(attrs, :element, element))}

      faults ->
        {:error, faults}
    end
  end

  defp check(value, valid?, why), do: if(valid?.(value), do: :ok, else: {:error, why})

  defp element?(%{} = element) do
    Map.keys(element) -- [:frame, :item, :path] == [] and is_list(Map.get(element, :path, []))
  end

  defp element?(_), do: false

  defp point?(nil), do: true
  defp point?({x, y}), do: is_number(x) and is_number(y)
  defp point?(_), do: false

  defp modifiers?(list) when is_list(list), do: Enum.all?(list, &(&1 in @modifiers))
  defp modifiers?(_), do: false
end
