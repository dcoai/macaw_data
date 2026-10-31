defmodule Macaw.Data.Schema do
  @moduledoc """
  A source's schema: what each of its fields means (spec/01 §1.2).

  A schema maps a field, named as the source's rows name it (an atom or a string), to a
  **description**: its `type` (`:time`, `:number`, `:category`, `:text`, `:color` or
  `:point`, a geographic position), and as much of `unit`, `quantity`, `label`, `order`,
  `status`, `polarity`, `target`, `continuity`, `window`, `metric_kind`, `bounds` and
  `identity` as the source knows, and for a `:category` field the `values` it takes,
  every one. It says what the numbers *are*, whoever draws them, and never how they are
  drawn: a description has no color key, since color is the theme's to choose from the
  meaning. A declared value may be an entry, `%{value: v, name: "Display", color: c}`,
  whose color is a data color: a color term, a literal `%Macaw.Layers.Color{}` or a
  theme-relative typed color, and never a string (`color?/1`, spec/01 §1.7).

  A `unit` is a UCUM code `Macaw.Data.Unit` reads and a `quantity` one of
  `Macaw.Data.Quantity.all/0`, and when both are given the unit measures the quantity
  (spec/01 §1.6). A field whose value names the thing a row is about says
  `identity: true`, several such fields together naming it (spec/01 §1.4). The window
  field is `window_field/1`'s (spec/01 §1.5).

  Names, states and roles count by their spelling: `new/1` writes each as a string, once,
  so `:latency` and `"latency"` are one field, and the schema holds it as `"latency"`.
  Every function that takes a name takes either spelling.

  A schema is identified by its `version`: the kernel's digest of its term, the normalized
  fields (`Macaw.Layers.Document.digest/1`, spec/01 §1.10), the same on every node and
  under every release, and new with any change of content. A `Macaw.Data.Delivery` names
  the version its rows were produced under; `Macaw.Data.Schema.Cache` holds schemas by
  `{source, version}`. `compatibility/2` says when one schema's rows read as another's
  (spec/01 §1.9). `to_json/1` and `from_json/2` are its public JSON form, an adapter at the
  edge that the version never goes through (spec/01 §1.11).

  Ported from visualize's `Visualize.Data.Schema`, with the `:point` type, data colors as
  color terms, the window field, the kernel's digest and a public JSON form.

  ## Examples

      iex> {:ok, schema} =
      ...>   Macaw.Data.Schema.new(%{
      ...>     t: %{type: :time},
      ...>     latency: %{type: :number, unit: "s", quantity: :duration, label: "Request time"},
      ...>     state: %{type: :category, order: ["ok", "warn", "fail"],
      ...>              status: %{"ok" => :good, "warn" => :warning, "fail" => :bad}}
      ...>   })
      iex> Macaw.Data.Schema.fetch(schema, "latency", :unit)
      {:ok, "s"}
      iex> String.length(Macaw.Data.Schema.version(schema))
      64
      iex> Macaw.Data.Schema.new(%{state: %{type: :category, colors: %{"ok" => "#0a0"}}})
      {:error, [{[:state, :colors], {:color_key, :colors}}]}

  """

  alias Macaw.Data.{Quantity, Table, Unit}
  alias Macaw.Data.Schema.Form
  alias Macaw.Layers.{Color, Document}

  @enforce_keys [:fields, :version]
  # `identity` is derived by `new/1`: the identity fields in order, read once per schema
  # rather than per row (visualize#812). A struct assembled by hand leaves it `nil`, and
  # `identity/1` derives it from the fields then.
  defstruct [:fields, :version, identity: nil]

  @typedoc "A field name, as the feed's rows spell it."
  @type name :: atom() | String.t()

  @typedoc "What one field means (spec/01 §1.2)."
  @type description :: %{
          required(:type) => :time | :number | :category | :text | :color | :point,
          optional(:unit) => String.t(),
          optional(:quantity) => atom(),
          optional(:label) => String.t(),
          optional(:order) => [String.t() | atom() | number(), ...],
          optional(:status) => %{value() => atom() | String.t()},
          optional(:polarity) => :higher_is_better | :lower_is_better | :neutral,
          optional(:target) => number(),
          optional(:continuity) => number(),
          optional(:window) => boolean(),
          optional(:metric_kind) => :gauge | :counter | :rate,
          optional(:bounds) => [number() | nil],
          optional(:identity) => boolean(),
          optional(:values) => [value() | value_entry(), ...]
        }

  @typedoc "A category field's value: a string, an atom or a number."
  @type value :: String.t() | atom() | number()

  @typedoc """
  A declared value with what a person reads of it (spec/01 §1.2, visualize D-224): its display
  `name`, and a `color` hint, a data color: a literal or a typed color (spec/01 §1.7).
  """
  @type value_entry :: %{
          required(:value) => value(),
          optional(:name) => String.t(),
          optional(:color) => Color.value()
        }

  @type t :: %__MODULE__{
          fields: %{String.t() => description()},
          version: String.t(),
          identity: [String.t()] | nil
        }

  @typedoc "A fault of `new/1`: the path from the schema to the value, and why."
  @type error :: {[name() | atom() | non_neg_integer() | term()], term()}

  @attributes [
    :type,
    :unit,
    :quantity,
    :label,
    :order,
    :status,
    :polarity,
    :target,
    :continuity,
    :window,
    :metric_kind,
    :bounds,
    :identity,
    :values
  ]
  @types [:time, :number, :category, :text, :color, :point]
  @polarities [:higher_is_better, :lower_is_better, :neutral]
  @metric_kinds [:gauge, :counter, :rate]
  # spelling: allow — a feed schema refuses a color key in either spelling.
  @color_keys [:color, :colour, :colors, :colours, :palette, :fill, :stroke]

  # The keys a field's type takes; every other key but `type`, `label` and `continuity` is
  # `{:invalid_for, type}` on it. `window` is a clock's: a `:time` or a `:number` field's.
  # A `:color` field takes none of them (visualize D-233).
  @numeric [:unit, :quantity, :polarity, :target, :metric_kind, :bounds]
  @categorical [:order, :status, :values]
  @clocks [:time, :number, :point]
  # `identity` names a thing, which a `:time` field never does: it says when (visualize D-167).
  @identities [:category, :text, :number]
  # A value entry's keys (visualize D-224): the one place a schema holds a color, a host's hint.
  @entry_keys [:value, :name, :color]

  @not_names [nil, true, false]

  @doc "The fourteen description keys, `:type` first (spec/01 §1.2)."
  @spec attributes() :: [atom(), ...]
  def attributes, do: @attributes

  @doc false
  # The words a description's values take: its types, polarities and metric kinds, each read
  # from its spelling through a closed vocabulary (spec/01 §1.11), never made an atom.
  @spec words() :: [atom(), ...]
  def words, do: @types ++ @polarities ++ @metric_kinds

  @doc false
  # Each word of a description's vocabulary by its key, which the JSON form reads through
  # its own closed table (`Macaw.Data.Schema.Form`, spec/01 §1.11).
  @spec vocabularies() :: %{
          type: [atom(), ...],
          polarity: [atom(), ...],
          metric_kind: [atom(), ...]
        }
  def vocabularies, do: %{type: @types, polarity: @polarities, metric_kind: @metric_kinds}

  @doc """
  A value entry's three keys, `:value` first (spec/01 §1.3): what a codec reads an entry's
  keys as, never making an atom of another. Public, so a host that encodes schemas itself
  (metresis) reads it rather than a hidden function.

      iex> Macaw.Data.Schema.entry_keys()
      [:value, :name, :color]
  """
  @spec entry_keys() :: [atom(), ...]
  def entry_keys, do: @entry_keys

  @doc false
  # The three polarities, which a color scale over a ramp reads too (visualize's spec/14 §4.3, visualize D-143).
  @spec polarities() :: [atom(), ...]
  def polarities, do: @polarities

  @doc """
  The schema of a map of field descriptions, or every fault of it by path (spec/01 §1.2).
  A fault names the field as given; the schema holds every name, state and role as its
  string (spec/01 §1.10).

      iex> Macaw.Data.Schema.new(%{v: %{type: :category, unit: "s"}})
      {:error, [{[:v, :unit], {:invalid_for, :category}}]}

      iex> Macaw.Data.Schema.new(%{v: %{type: :number, unit: "By", quantity: :duration}})
      {:error, [{[:v, :quantity], {:quantity, :duration, "By"}}]}
  """
  @spec new(term()) :: {:ok, t()} | {:error, [error(), ...]}
  def new(fields) when is_map(fields) and not is_struct(fields) do
    errors =
      Enum.flat_map(fields, fn {name, description} -> field(name, description) end) ++
        duplicates(Map.keys(fields)) ++ windows(fields)

    case Enum.sort_by(errors, &elem(&1, 0)) do
      [] ->
        fields = Map.new(fields, fn {name, d} -> {spell(name), d |> declared() |> spelled()} end)
        {:ok, %__MODULE__{fields: fields, version: hash(fields), identity: identities(fields)}}

      errors ->
        {:error, errors}
    end
  end

  def new(_other), do: {:error, [{[], {:type, :schema}}]}

  @doc "The schema of a map of field descriptions, or `ArgumentError` naming every fault."
  @spec new!(term()) :: t()
  def new!(fields) do
    case new(fields) do
      {:ok, schema} ->
        schema

      {:error, errors} ->
        raise ArgumentError,
              "not a schema:\n" <> Enum.map_join(errors, "\n", &("  " <> format_error(&1)))
    end
  end

  @doc """
  The schema's version: the SHA-256 of its canonical encoding as 64 lowercase hex digits
  (spec/01 §1.10), computed once by `new/1`.
  """
  @spec version(t()) :: String.t()
  def version(%__MODULE__{version: version}), do: version

  @doc """
  A field's description, by either spelling of its name (spec/01 §1.1).

      iex> schema = Macaw.Data.Schema.new!(%{"v" => %{type: :number}})
      iex> Macaw.Data.Schema.fetch(schema, :v)
      {:ok, %{type: :number}}
      iex> Macaw.Data.Schema.fetch(schema, :w)
      :error
  """
  @spec fetch(t(), name()) :: {:ok, description()} | :error
  def fetch(%__MODULE__{fields: fields}, name) when is_atom(name) or is_binary(name),
    do: Map.fetch(fields, spell(name))

  @doc "One attribute of a field's description; `:error` when the field or the attribute is absent."
  @spec fetch(t(), name(), atom()) :: {:ok, term()} | :error
  def fetch(%__MODULE__{} = schema, name, key) when is_atom(key) do
    with {:ok, description} <- fetch(schema, name), do: Map.fetch(description, key)
  end

  @doc """
  A field's declared values, bare, in their declared order (spec/01 §1.2, visualize D-224): each
  value entry's `value`, and each bare value as it is. `nil` when the schema has no such
  field or the field declares no `values` — an open set, where `[]` would say a closed one
  holding nothing. Read by either spelling of the field's name.

  What compares or lists a field's values reads them here, never through `fetch/3`, whose
  `:values` is the list as declared, entries and all.

      iex> schema = Macaw.Data.Schema.new!(%{state: %{type: :category, values: [
      ...>   %{value: "ok", name: "OK", color: {:color, "good"}}, "unknown"]}})
      iex> Macaw.Data.Schema.values(schema, :state)
      ["ok", "unknown"]
      iex> Macaw.Data.Schema.values(schema, :other)
      nil
  """
  @spec values(t(), name()) :: [value(), ...] | nil
  def values(%__MODULE__{} = schema, field) do
    case fetch(schema, field, :values) do
      {:ok, [_ | _] = values} -> Enum.map(values, &bare/1)
      _none -> nil
    end
  end

  @doc """
  A map from each declared value with a `name` to its name (spec/01 §1.2, visualize D-224); `%{}`
  when none has one, or the field declares no values.

      iex> schema = Macaw.Data.Schema.new!(%{state: %{type: :category, values: [
      ...>   %{value: "ok", name: "OK"}, %{value: "down", color: {:color, "bad"}}, "unknown"]}})
      iex> Macaw.Data.Schema.value_names(schema, "state")
      %{"ok" => "OK"}
  """
  @spec value_names(t(), name()) :: %{value() => String.t()}
  def value_names(%__MODULE__{} = schema, field), do: entries(schema, field, :name)

  @doc """
  A map from each declared value with a `color` to its color, the color term the schema
  holds, a literal or a typed color (spec/01 §1.3, §1.7); `%{}` when none has one, or the
  field declares no values. A drawing library may use it as a color map, under the theme's
  data-color guard; a design's own colors outrank it.

      iex> import Macaw.Layers.Color, only: [sigil_RGB: 2]
      iex> schema = Macaw.Data.Schema.new!(%{state: %{type: :category, values: [
      ...>   %{value: "ok", color: ~RGB"#2e7d32"}, %{value: "warn", color: {:color, :warning}}]}})
      iex> Macaw.Data.Schema.value_colors(schema, :state)
      %{"ok" => ~RGB"#2e7d32", "warn" => {:color, "warning"}}
  """
  @spec value_colors(t(), name()) :: %{value() => Color.value()}
  def value_colors(%__MODULE__{} = schema, field), do: entries(schema, field, :color)

  defp entries(schema, field, key) do
    case fetch(schema, field, :values) do
      {:ok, values} when is_list(values) ->
        for %{value: value} = entry <- values, Map.has_key?(entry, key), into: %{} do
          {value, Map.fetch!(entry, key)}
        end

      _none ->
        %{}
    end
  end

  @doc """
  The fields the schema declares `identity: true`, as strings, in order; `[]` when it
  declares none (spec/01 §1.2, visualize D-167).

      iex> schema = Macaw.Data.Schema.new!(%{
      ...>   iface: %{type: :category, identity: true},
      ...>   host: %{type: :category, identity: true},
      ...>   bytes: %{type: :number}
      ...> })
      iex> Macaw.Data.Schema.identity(schema)
      ["host", "iface"]
  """
  @spec identity(t()) :: [String.t()]
  def identity(%__MODULE__{identity: identity}) when is_list(identity), do: identity
  def identity(%__MODULE__{fields: fields}), do: identities(fields)

  defp identities(fields) do
    for({name, %{identity: true}} <- fields, do: name)
    |> Enum.sort_by(&to_string/1)
  end

  @doc """
  A row's identity under the schema (spec/01 §1.2, visualize D-167): the bare value of the one
  identity field, a map from field to value, keyed by the fields' strings, for several,
  and `nil` when the schema declares none or the row has no value for one of them. Each
  field is read by either spelling of its name.

      iex> one = Macaw.Data.Schema.new!(%{id: %{type: :category, identity: true}, x: %{type: :number}})
      iex> Macaw.Data.Schema.identity(one, %{"id" => "frog-1", "x" => 3})
      "frog-1"
      iex> two = Macaw.Data.Schema.new!(%{host: %{type: :category, identity: true},
      ...>   iface: %{type: :category, identity: true}})
      iex> Macaw.Data.Schema.identity(two, %{host: "mx1", iface: "eth0", bytes: 9})
      %{"host" => "mx1", "iface" => "eth0"}
      iex> Macaw.Data.Schema.identity(two, %{host: "mx1"})
      nil
  """
  @spec identity(t(), map()) :: term()
  def identity(%__MODULE__{} = schema, row) when is_map(row) do
    case identity(schema) do
      [] -> nil
      [field] -> Table.get(row, field)
      fields -> composite(fields, row)
    end
  end

  defp composite(fields, row) do
    values = Map.new(fields, &{&1, Table.get(row, &1)})
    if Enum.any?(values, fn {_field, value} -> value == nil end), do: nil, else: values
  end

  @doc """
  The schema's window field (spec/01 §1.5): the field a request's window applies to, by
  which rows are ordered, trimmed and routed. It is the field described `window: true`,
  else the schema's one `:time` field when it does not say `window: false`; `nil` when
  there is neither, and a schema with several `:time` fields and none marked has none.

      iex> alias Macaw.Data.Schema
      iex> Schema.window_field(Schema.new!(%{t: %{type: :time}, v: %{type: :number}}))
      "t"
      iex> Schema.window_field(Schema.new!(%{tick: %{type: :number, window: true}, v: %{type: :number}}))
      "tick"
      iex> Schema.window_field(Schema.new!(%{a: %{type: :time}, b: %{type: :time}}))
      nil
  """
  @spec window_field(t()) :: String.t() | nil
  def window_field(%__MODULE__{fields: fields}) do
    case for({name, %{window: true}} <- fields, do: name) do
      [name] -> name
      [] -> the_time_field(fields)
    end
  end

  defp the_time_field(fields) do
    case for({name, %{type: :time} = d} <- fields, Map.get(d, :window) != false, do: name) do
      [name] -> name
      _none_or_several -> nil
    end
  end

  @doc """
  The window that applies to the schema's window field (spec/01 §1.5): `:range` over a
  `:time` or a `:number` field, from one instant or value to another; `:box` over a
  `:point` field, a region of positions; `nil` when the schema has no window field.
  """
  @spec window_kind(t()) :: :range | :box | nil
  def window_kind(%__MODULE__{} = schema) do
    case window_field(schema) do
      nil -> nil
      name -> if schema.fields[name].type == :point, do: :box, else: :range
    end
  end

  @typedoc "Why a field of one schema cannot read another's rows (spec/01 §1.2, visualize D-159)."
  @type incompatibility ::
          :missing
          | {:type, atom(), atom()}
          | {:unit, term(), term()}
          | {:identity, boolean(), boolean()}

  @doc """
  Whether `other`'s rows read as `schema`'s (spec/01 §1.2, visualize D-159): for each field of
  `schema`, `other` has a field of the same name, of the same type, and for a `:number`
  field a unit that converts into `schema`'s — two absent units agree, one absent facing a
  present one does not. `{:error, faults}` lists every fault, `field` the field's string,
  ordered by it. Labels and facts are not compared, and `other`'s extra fields are not
  faults — except identity (visualize D-167):
  a field one schema declares `identity: true` and the other does not is `{:identity, a,
  b}`, `a` and `b` whether each declares it, even a field only `other` has, since
  `other`'s rows read as `schema`'s would merge the things `other` tells apart.

      iex> live = Macaw.Data.Schema.new!(%{t: %{type: :time}, value: %{type: :number, unit: "ms"}})
      iex> history = Macaw.Data.Schema.new!(%{"t" => %{type: :time}, "value" => %{type: :number, unit: "s", label: "Load"}})
      iex> Macaw.Data.Schema.compatibility(live, history)
      :ok
      iex> bytes = Macaw.Data.Schema.new!(%{"value" => %{type: :number, unit: "By"}})
      iex> Macaw.Data.Schema.compatibility(live, bytes)
      {:error, [{"t", :missing}, {"value", {:unit, "ms", "By"}}]}
      iex> hosts = Macaw.Data.Schema.new!(%{host: %{type: :category, identity: true}})
      iex> ifaces = Macaw.Data.Schema.new!(%{host: %{type: :category, identity: true},
      ...>   iface: %{type: :category, identity: true}})
      iex> Macaw.Data.Schema.compatibility(hosts, ifaces)
      {:error, [{"iface", {:identity, false, true}}]}
  """
  @spec compatibility(t(), t()) :: :ok | {:error, [{String.t(), incompatibility()}, ...]}
  def compatibility(%__MODULE__{fields: fields} = schema, %__MODULE__{} = other) do
    ours =
      Enum.flat_map(fields, fn {name, description} ->
        case fetch(other, name) do
          {:ok, theirs} ->
            compatible(name, description, theirs) ++ same_identity(name, description, theirs)

          :error ->
            [{name, :missing}]
        end
      end)

    # An identity field only `other` has: its rows tell apart what `schema`'s do not.
    theirs =
      for name <- identity(other),
          fetch(schema, name) == :error,
          do: {name, {:identity, false, true}}

    case Enum.sort_by(ours ++ theirs, &elem(&1, 0)) do
      [] -> :ok
      faults -> {:error, faults}
    end
  end

  defp same_identity(name, ours, theirs) do
    case {Map.get(ours, :identity, false), Map.get(theirs, :identity, false)} do
      {same, same} -> []
      {a, b} -> [{name, {:identity, a, b}}]
    end
  end

  defp compatible(name, %{type: ours}, %{type: theirs}) when ours != theirs,
    do: [{name, {:type, ours, theirs}}]

  defp compatible(name, %{type: :number} = ours, theirs) do
    case {Map.get(ours, :unit), Map.get(theirs, :unit)} do
      {same, same} ->
        []

      {to, from} when to == nil or from == nil ->
        [{name, {:unit, to, from}}]

      {to, from} ->
        case Unit.conversion(from, to) do
          {:ok, _conversion} -> []
          {:error, _reason} -> [{name, {:unit, to, from}}]
        end
    end
  end

  defp compatible(_name, _ours, _theirs), do: []

  # -- checks ---------------------------------------------------------------------------

  defp field(name, _description) when not (is_atom(name) or is_binary(name)) or name == "",
    do: [{[name], {:type, :name}}]

  defp field(name, _description) when name in @not_names, do: [{[name], {:type, :name}}]

  defp field(name, description) when is_map(description) and not is_struct(description) do
    type = Map.get(description, :type)

    missing = if Map.has_key?(description, :type), do: [], else: [{[name, :type], :required}]

    keys = Enum.flat_map(description, fn {key, value} -> key(name, type, key, value) end)

    missing ++ keys ++ unordered(name, description) ++ measure(name, description, keys)
  end

  defp field(name, _description), do: [{[name], {:type, :description}}]

  # Every state `status` names is one of `order`'s, when the description gives both; and
  # with `values`, every state `order` lists and `status` names is one of them (visualize D-194).
  defp unordered(name, description) do
    in_order(name, description) ++ in_values(name, description)
  end

  defp in_order(name, %{order: order, status: status}) when is_list(order) and is_map(status) do
    order = Enum.map(order, &spell/1)

    for {state, _role} <- status,
        spell(state) not in order,
        do: {[name, :status, state], :not_in_order}
  end

  defp in_order(_name, _description), do: []

  defp in_values(name, %{values: [_ | _] = declared} = description) do
    values = Enum.map(declared, &spell(bare(&1)))

    order =
      case Map.get(description, :order) do
        [_ | _] = order ->
          for {state, i} <- Enum.with_index(order),
              spell(state) not in values,
              do: {[name, :order, i], :not_in_values}

        _none ->
          []
      end

    status =
      case Map.get(description, :status) do
        status when is_map(status) ->
          for {state, _role} <- status,
              spell(state) not in values,
              do: {[name, :status, state], :not_in_values}

        _none ->
          []
      end

    order ++ status
  end

  defp in_values(_name, _description), do: []

  # Two spellings of one column (spec/01 §1.1) are one field named twice: reported at the
  # later spelling by term order, which is the string.
  defp duplicates(names) do
    strings = for name <- names, is_binary(name), into: MapSet.new(), do: name

    for name <- names,
        is_atom(name) and name not in @not_names,
        spelled = Atom.to_string(name),
        MapSet.member?(strings, spelled),
        do: {[spelled], {:duplicate_field, name}}
  end

  # A state a status names in both spellings is named twice: `:duplicate` at the string,
  # the later by term order, as a field is.
  defp twice(states, path) do
    for state <- states,
        is_atom(state),
        spelled = Atom.to_string(state),
        spelled in states,
        do: {path ++ [spelled], :duplicate}
  end

  # A feed's windows are over one field: a second `window: true` is reported at the later
  # field by term order, naming the first. A field whose type takes no `window` is
  # reported for that alone.
  defp windows(fields) do
    case for({name, %{type: type, window: true}} when type in @clocks <- fields, do: name) do
      [_ | [_ | _]] = names ->
        [first | rest] = Enum.sort(names)
        for name <- rest, do: {[name, :window], {:duplicate_window, first}}

      _one_or_none ->
        []
    end
  end

  defp key(name, _type, key, _value) when key in @color_keys,
    do: [{[name, key], {:color_key, key}}]

  defp key(name, _type, key, _value) when key not in @attributes,
    do: [{[name, key], :unknown_key}]

  defp key(name, _type, :type, value) do
    if value in @types, do: [], else: [{[name, :type], {:enum, @types}}]
  end

  defp key(name, type, key, _value) when key in @numeric and type in @types and type != :number,
    do: [{[name, key], {:invalid_for, type}}]

  defp key(name, type, key, _value)
       when key in @categorical and type in @types and type != :category,
       do: [{[name, key], {:invalid_for, type}}]

  defp key(name, type, :window, _value) when type in @types and type not in @clocks,
    do: [{[name, :window], {:invalid_for, type}}]

  defp key(name, type, :identity, _value) when type in @types and type not in @identities,
    do: [{[name, :identity], {:invalid_for, type}}]

  defp key(name, _type, :unit, value), do: unit(value, [name, :unit])

  defp key(name, _type, :quantity, value) when not is_atom(value) or value in @not_names,
    do: [{[name, :quantity], {:type, :name}}]

  defp key(name, _type, :quantity, value) do
    if value in Quantity.all(),
      do: [],
      else: [{[name, :quantity], {:unknown_quantity, value}}]
  end

  defp key(name, _type, :label, value) do
    if is_binary(value), do: [], else: [{[name, :label], {:type, :string}}]
  end

  defp key(name, _type, :order, value), do: order(value, [name, :order])

  defp key(name, _type, :values, value), do: declared_values(value, [name, :values])

  defp key(name, _type, :status, value) do
    if is_map(value) and not is_struct(value) and
         Enum.all?(value, fn {state, role} -> state?(state) and role?(role) end),
       do: twice(Map.keys(value), [name, :status]),
       else: [{[name, :status], {:type, :status}}]
  end

  defp key(name, _type, :polarity, value) do
    if value in @polarities, do: [], else: [{[name, :polarity], {:enum, @polarities}}]
  end

  defp key(name, _type, :target, value) do
    if is_number(value), do: [], else: [{[name, :target], {:type, :number}}]
  end

  defp key(name, _type, :continuity, value) do
    if is_number(value) and value > 0, do: [], else: [{[name, :continuity], {:type, :positive}}]
  end

  defp key(name, _type, :metric_kind, value) do
    if value in @metric_kinds, do: [], else: [{[name, :metric_kind], {:enum, @metric_kinds}}]
  end

  defp key(name, _type, :bounds, value) do
    if bounds?(value), do: [], else: [{[name, :bounds], {:type, :bounds}}]
  end

  defp key(name, _type, :window, value) do
    if is_boolean(value), do: [], else: [{[name, :window], {:type, :boolean}}]
  end

  defp key(name, _type, :identity, value) do
    if is_boolean(value), do: [], else: [{[name, :identity], {:type, :boolean}}]
  end

  # `identity: false` is the description that says nothing, kept as that one schema
  # (spec/01 §1.2, visualize D-167).
  # An entry that says nothing but its value is that value, so the two spellings are one
  # schema too (visualize D-224).
  defp declared(%{identity: false} = description),
    do: description |> Map.delete(:identity) |> declared()

  defp declared(%{values: [_ | _] = values} = description),
    do: %{description | values: Enum.map(values, &plain/1)}

  defp declared(description), do: description

  defp plain(%{value: value} = entry) when map_size(entry) == 1, do: value
  defp plain(entry), do: entry

  # Every state and role of a checked description as its string (spec/01 §1.10). The
  # words of the vocabulary stay atoms: they are words, not names.
  defp spelled(description) do
    Map.new(description, fn
      {:order, order} -> {:order, Enum.map(order, &spell/1)}
      {:status, status} -> {:status, Map.new(status, fn {s, role} -> {spell(s), spell(role)} end)}
      {:values, values} -> {:values, Enum.map(values, &spelled_value/1)}
      other -> other
    end)
  end

  defp spelled_value(%{value: value} = entry),
    do: %{entry | value: spell(value)} |> Map.replace_lazy(:color, &spelled_color/1)

  defp spelled_value(value), do: spell(value)

  # A typed color's names are a theme's, held as their strings as `Macaw.Layers.Color.color/1`
  # writes them, so `{:color, :good}` and `{:color, "good"}` are one color of one version.
  defp spelled_color({:color, name}), do: {:color, spell(name)}
  defp spelled_color({:ramp, name, t}), do: {:ramp, spell(name), t}
  defp spelled_color({:blend, colors}), do: {:blend, Enum.map(colors, &spelled_color/1)}
  defp spelled_color({:contrast, c}), do: {:contrast, spelled_color(c)}
  defp spelled_color({op, c, t}), do: {op, spelled_color(c), t}
  defp spelled_color(literal_or_word), do: literal_or_word

  # A unit is a UCUM code `Macaw.Data.Unit` reads (spec/03 §1, visualize D-157).
  defp unit(value, path) when is_binary(value) and value != "" do
    case Unit.parse(value) do
      {:ok, _components} -> []
      {:error, reason} -> [{path, {:unit, value, reason}}]
    end
  end

  defp unit(_value, path), do: [{path, {:type, :unit}}]

  # A numeric field giving a unit and a quantity, each good on its own, gives a unit of
  # that quantity (spec/03 §13, visualize D-157): the pair is `Macaw.Data.Quantity.resolve/1`'s, so
  # its fault is the one an axis's measure reports.
  defp measure(name, %{type: :number, unit: unit, quantity: quantity}, faults) do
    reported? = Enum.any?(faults, &match?({[_, key], _} when key in [:unit, :quantity], &1))

    case reported? || Quantity.resolve(%{unit: unit, quantity: quantity}) do
      {:error, reason} -> [{[name, :quantity], reason}]
      _good_or_reported -> []
    end
  end

  defp measure(_name, _description, _faults), do: []

  defp order([_ | _] = states, path) do
    if Enum.all?(states, &state?/1),
      do: distinct(states, path),
      else: [{path, {:type, :order}}]
  end

  defp order(_other, path), do: [{path, {:type, :order}}]

  # Each state listed once, by its spelling: a later one listed before is `:duplicate` at
  # its index. A value entry is compared by its value, and one whose value is no state is
  # its own fault.
  defp distinct(states, path) do
    states
    |> Enum.with_index()
    |> Enum.reduce({MapSet.new(), []}, fn {state, i}, {seen, errors} ->
      cond do
        not state?(state) -> {seen, errors}
        MapSet.member?(seen, spell(state)) -> {seen, [{path ++ [i], :duplicate} | errors]}
        true -> {MapSet.put(seen, spell(state)), errors}
      end
    end)
    |> elem(1)
    |> Enum.reverse()
  end

  # A closed set of values is a list like an order, each distinct by value (visualize D-194); an entry
  # may be a map of its value, name and color (visualize D-224).
  defp declared_values([_ | _] = values, path) do
    if Enum.all?(values, &(state?(&1) or entry?(&1))) do
      entries =
        values
        |> Enum.with_index()
        |> Enum.flat_map(fn {entry, i} -> entry(entry, path ++ [i]) end)

      entries ++ distinct(Enum.map(values, &bare/1), path)
    else
      [{path, {:type, :values}}]
    end
  end

  defp declared_values(_other, path), do: [{path, {:type, :values}}]

  defp entry?(v), do: is_map(v) and not is_struct(v)

  defp entry(entry, path) when is_map(entry) do
    missing = if Map.has_key?(entry, :value), do: [], else: [{path ++ [:value], :required}]
    missing ++ Enum.flat_map(entry, fn {key, value} -> entry_key(key, value, path ++ [key]) end)
  end

  defp entry(_state, _path), do: []

  defp entry_key(:value, value, path),
    do: if(state?(value), do: [], else: [{path, {:type, :state}}])

  defp entry_key(:name, name, path),
    do: if(is_binary(name), do: [], else: [{path, {:type, :string}}])

  defp entry_key(:color, color, path),
    do: if(color?(color), do: [], else: [{path, {:type, :color}}])

  defp entry_key(_key, _value, path), do: [{path, :unknown_entry_key}]

  @doc """
  Whether a value is a data color (spec/01 §1.7): a color term, checked as a term. It is a
  literal `%Macaw.Layers.Color{}` (`Macaw.Layers.Color.literal?/1`), the color itself as the
  datum, or a theme-relative typed color (`{:color, "good"}`, `{:alpha, c, 0.5}`, …) whose
  literal operands are colors (`Macaw.Layers.Color.value?/1`) and whose names are in a
  theme's name grammar (`Macaw.Layers.Color.name?/1`). A string is never a color: CSS text is
  read at the input edge with `Macaw.Layers.Color.parse!/1`, or written `~RGB"#2e7d32"`.

      iex> import Macaw.Layers.Color, only: [sigil_RGB: 2]
      iex> Macaw.Data.Schema.color?(~RGB"#2e7d32")
      true
      iex> Macaw.Data.Schema.color?({:alpha, {:color, :bad}, 0.74})
      true
      iex> Macaw.Data.Schema.color?("#2e7d32")
      false
      iex> Macaw.Data.Schema.color?(:good)
      false
  """
  @spec color?(term()) :: boolean()
  def color?(term), do: Color.value?(term) and Enum.all?(color_names(term), &Color.name?/1)

  # The theme names a color value reads, operands included: its colors' and its ramps'.
  defp color_names({:color, name}), do: [name]
  defp color_names({:ramp, name, _t}), do: [name]
  defp color_names({:blend, colors}), do: Enum.flat_map(colors, &color_names/1)
  defp color_names({:contrast, c}), do: color_names(c)
  defp color_names({_op, c, _t}), do: color_names(c)
  defp color_names(_literal_or_slot), do: []

  # A declared value, bare: an entry's value, or the value it is.
  defp bare(%{value: value}), do: value
  defp bare(value), do: value

  # `[min, max]`, each a number or `nil`, the first below the second when both are given.
  defp bounds?([min, max]) when is_number(min) and is_number(max), do: min < max
  defp bounds?([min, max]), do: (is_number(min) or min == nil) and (is_number(max) or max == nil)
  defp bounds?(_other), do: false

  defp state?(v), do: is_binary(v) or is_number(v) or (is_atom(v) and v not in @not_names)
  # A role is a theme's word, either spelling, held as its string (spec/01 §1.10), and never
  # a color: a status says what a state means, and the theme colors the meaning. A word is
  # never a color term, so a role spelled like a CSS name (`:orange`) is a role.
  defp role?(v) when is_binary(v), do: v != ""
  defp role?(v), do: is_atom(v) and v not in @not_names

  @doc false
  # A name, a state, a role or a word by its spelling; anything else as it is. `new/1`
  # normalizes names with it, and the JSON form (`Macaw.Data.Schema.Form`) writes words.
  @spec spell(term()) :: term()
  def spell(atom) when is_atom(atom) and atom not in @not_names, do: Atom.to_string(atom)
  def spell(value), do: value

  # -- the version (spec/01 §1.10) -------------------------------------------------------

  # The kernel's digest of the schema's term, its normalized fields; never of a
  # representation of it, so the JSON form (`Macaw.Data.Schema.Form`) is not on the way.
  defp hash(fields), do: Document.digest(%{"fields" => fields})

  # -- the JSON form (spec/01 §1.11): an adapter at the edge, `Macaw.Data.Schema.Form` --

  @doc """
  The schema's map form (spec/01 §1.11): the JSON-ready list of `[name, description]`
  pairs, sorted by name, every name, state and role written by its spelling, every word
  of the vocabulary (`type`, `quantity`, `polarity`, `metric_kind`) as its string, and a
  value entry's color in the colors' JSON form (`Macaw.Layers.Color.Form`: a literal as
  `{"$rgb": "#2e7d32"}`, a typed color by its tags, `{"$color": "good"}`).
  """
  @spec to_map(t()) :: [[term()]]
  defdelegate to_map(schema), to: Form

  @doc "The schema's JSON form: `to_map/1`, encoded."
  @spec to_json(t()) :: String.t()
  defdelegate to_json(schema), to: Form

  @doc """
  The schema a map form holds (spec/01 §1.11): `new/1` of what it reads. Each word is read
  through its own closed vocabulary, every name, state and role is a string, and an entry's
  color is read by the colors' own reader (`Macaw.Layers.Color.Form`), so no atom is made.
  A key no description or value entry has stays its string, for `new/1` to refuse by name,
  and a color the reader does not read stays as written, for `new/1` to refuse as no color.
  """
  @spec from_map(term()) :: {:ok, t()} | {:error, [error(), ...]}
  defdelegate from_map(pairs), to: Form

  @doc """
  The schema a JSON document holds: read through the kernel's limits and scan first
  (`Macaw.Layers.Limits`, `Macaw.Layers.Scan`), so a document over a limit is refused
  before it is decoded, then decoded and read by `from_map/1`. `limits:` tightens them.
  """
  @spec from_json(binary(), keyword()) :: {:ok, t()} | {:error, [error(), ...]}
  defdelegate from_json(json, opts \\ []), to: Form

  # -- formatting -----------------------------------------------------------------------

  @doc """
  One fault of `new/1` as a line a person reads.

      iex> Macaw.Data.Schema.format_error({[:latency, :unit], {:invalid_for, :category}})
      "latency.unit: is not a key a :category field takes"
  """
  @spec format_error(error()) :: String.t()
  def format_error({path, reason}), do: "#{format_path(path)}: #{words(reason)}"

  defp format_path([]), do: "schema"

  defp format_path(path) do
    Enum.map_join(path, ".", fn
      i when is_integer(i) -> "[#{i}]"
      k when is_atom(k) or is_binary(k) -> to_string(k)
      other -> inspect(other)
    end)
    |> String.replace(".[", "[")
  end

  defp words({:color_key, key}) do
    "#{inspect(key)} names a color, which a schema never does: describe the meaning " <>
      "(status, order, polarity, quantity) and the theme chooses the color"
  end

  defp words({:type, :schema}), do: "must be a map from field names to descriptions"
  defp words({:type, :name}), do: "must be a name: an atom or a non-empty string"
  defp words({:type, :description}), do: "must be a map of description keys"
  defp words({:type, :unit}), do: "must be a unit: a non-empty string, a UCUM code"

  defp words({:unit, _code, reason}),
    do: "#{Unit.format_error(reason)} (spec/03 §1)"

  defp words({:unknown_quantity, quantity}),
    do: "#{inspect(quantity)} is not a quantity: one of Macaw.Data.Quantity.all/0 (spec/03 §13)"

  defp words({:quantity, quantity, code}),
    do: "unit #{inspect(code)} does not measure #{inspect(quantity)} (spec/03 §13)"

  defp words({:type, :string}), do: "must be a string"
  defp words({:type, :number}), do: "must be a number"

  defp words({:type, :positive}),
    do: "must be a positive number, in the window field's units (seconds for a time)"

  defp words({:type, :boolean}), do: "must be true or false"

  defp words({:type, :bounds}),
    do: "must be [min, max], each a number or nil, min below max when both are given"

  defp words({:type, :order}),
    do: "must be a non-empty list of states: strings, atoms or numbers"

  defp words({:type, :status}), do: "must be a map from a state to a role atom"

  defp words({:type, :values}),
    do:
      "must be a non-empty list of the field's values: strings, atoms or numbers, or " <>
        "entries %{value: v, name: \"Display\", color: c}"

  defp words({:type, :state}),
    do: "must be a value: a string, an atom other than nil, true and false, or a number"

  defp words({:type, :color}),
    do:
      "must be a data color, a color term: a literal %Macaw.Layers.Color{} or a typed " <>
        "color such as {:color, \"good\"} (spec/01 §1.7); a string is never a color: read " <>
        "text with Macaw.Layers.Color.parse!/1, or write ~RGB\"#2e7d32\""

  defp words(:unknown_entry_key),
    do: "is not a value entry's key; the keys are #{Enum.map_join(@entry_keys, ", ", &inspect/1)}"

  defp words({:duplicate_field, name}),
    do: "names the same column as #{inspect(name)}: a field is described once"

  defp words({:duplicate_window, other}),
    do: "is a second window field beside #{inspect(other)}: a feed's windows are over one field"

  defp words(:unknown_key),
    do: "is not a description key; the keys are #{Enum.map_join(@attributes, ", ", &inspect/1)}"

  defp words(:required), do: "is required"
  defp words({:enum, allowed}), do: "must be one of #{Enum.map_join(allowed, ", ", &inspect/1)}"
  defp words({:invalid_for, type}), do: "is not a key a #{inspect(type)} field takes"
  defp words(:duplicate), do: "is listed twice"
  defp words(:not_in_order), do: "is a state the field's order does not list"

  defp words(:not_in_values),
    do: "is a state the field's values do not list: the values are every value there is"
end
