defmodule Macaw.Data.Derived do
  @moduledoc """
  A derived source: a source computed from other sources by a function, rows in and rows
  out (spec/02). Ported from visualize's `Visualize.VirtualSource` (visualize#643, D-194).

  It is **data**: `id`, its inputs (`from`), its output's `schema`, and its function as
  source text (`elixir`, checked by `Macaw.Data.Derived.Sandbox`) or a host function's
  name (`function`, defined with `defsource`, spec/02 §7), so a document holds it and its
  forms write it. With `per:` the function runs once per entity of one input and its rows
  are joined back by that input's declared identity. Every name is a string.

      iex> {:ok, health} =
      ...>   Macaw.Data.Derived.new(
      ...>     id: :health,
      ...>     from: [hosts: %{last: 20}],
      ...>     per: :identity,
      ...>     schema: %{
      ...>       host: %{type: :category, identity: true},
      ...>       state: %{type: :category, values: [:ok, :warning, :error]}
      ...>     },
      ...>     elixir: "fn rows -> %{state: :ok} end"
      ...>   )
      iex> {health.id, health.from}
      {"health", [{"hosts", %{last: 20}}]}
      iex> Macaw.Data.Derived.conform(health, [%{host: "a", state: :ok}])
      {:ok, [%{"host" => "a", "state" => :ok}]}
      iex> Macaw.Data.Derived.conform(health, [%{host: "a", state: :unknown}])
      {:error, {0, "state", :not_in_values}}
      iex> Macaw.Data.Derived.resolve([["health"], ["ops", "health"]], [:ops], :health)
      {:ok, ["ops", "health"]}
  """

  alias Macaw.Data.{Delivery, Schema, Table, Window}
  alias Macaw.Data.Derived.{Form, Sandbox}
  alias Macaw.Data.Derived.Sandbox.Names, as: Spelling
  alias Macaw.Data.Source.{Description, Finish, Request}
  alias Macaw.Layers.Names

  @keys [:id, :from, :schema, :elixir, :function, :per]
  @request_keys [:window, :box, :region, :latest]
  @not_names [nil, true, false]

  @enforce_keys [:id, :from, :schema]
  defstruct [:id, :from, :schema, elixir: nil, function: nil, per: nil]

  @typedoc "What an input names (spec/02 §2.1): a short id, a source, or a path."
  @type name :: String.t() | {:source, String.t()} | [String.t(), ...]

  @typedoc "How much of an input the function needs (spec/02 §2.2)."
  @type window ::
          nil
          | %{last: pos_integer()}
          | %{
              optional(:window) => list(),
              optional(:box) => map(),
              optional(:region) => map(),
              optional(:latest) => boolean()
            }

  @type t :: %__MODULE__{
          id: String.t(),
          from: [{name(), window()}, ...],
          schema: Schema.t(),
          elixir: String.t() | nil,
          function: String.t() | nil,
          per: nil | :identity | {:identity, name()}
        }

  @typedoc "A fault: the path from the source to the value, and why (spec/02 §1.1)."
  @type error :: {list(), term()}

  @typedoc """
  An input as its owner read it (spec/02 §1.3, §2.2): its name, its rows in its window,
  its schema, and the delivery it came in.
  """
  @type input :: %{
          required(:name) => name(),
          required(:rows) => [map()],
          required(:schema) => Schema.t(),
          optional(:delivery) => Delivery.t()
        }

  # -- construction (spec/02 §1.1) ---------------------------------------------------------

  @doc """
  A derived source of a keyword list, a map with atom keys, or its map form (spec/02
  §1.5), checked alone (spec/02 §1.1): `{:ok, derived}`, or `{:error, errors}` with every
  fault by path.
  """
  @spec new(map() | keyword()) :: {:ok, t()} | {:error, [error(), ...]}
  def new(source) when is_list(source) do
    if Keyword.keyword?(source),
      do: new(Map.new(source)),
      else: {:error, [{[], {:type, :derived}}]}
  end

  def new(source) when is_map(source) and not is_struct(source) do
    case Form.read(source) do
      {:ok, source} -> checked(source)
      {:error, errors} -> {:error, errors}
    end
  end

  def new(_other), do: {:error, [{[], {:type, :derived}}]}

  defp checked(source) do
    source = named(source)

    errors =
      for(key <- Map.keys(source), key not in @keys, do: {[key], :unknown_key}) ++
        id(source) ++
        from(Map.get(source, :from)) ++
        schema(source) ++
        function(source) ++
        per(Map.get(source, :per), Map.get(source, :from))

    case Enum.sort_by(errors, &elem(&1, 0)) do
      [] ->
        {:ok,
         %__MODULE__{
           id: source.id,
           from: source.from,
           schema: source.schema,
           elixir: Map.get(source, :elixir),
           function: Map.get(source, :function),
           per: Map.get(source, :per)
         }}

      errors ->
        {:error, errors}
    end
  end

  @doc "The derived source, or `ArgumentError` naming every fault."
  @spec new!(map() | keyword()) :: t()
  def new!(source) do
    case new(source) do
      {:ok, source} ->
        source

      {:error, errors} ->
        raise ArgumentError,
              "not a derived source:\n" <>
                Enum.map_join(errors, "\n", &("  " <> format_error(&1)))
    end
  end

  # A source's names are strings (spec/02 §1.1): its id, its inputs' names and paths, its
  # identity input, its function and its output's schema, read through its map form, so
  # an atom and a string of one spelling are one name.
  defp named(source) do
    Enum.reduce(
      [
        id: &name/1,
        from: &named_inputs/1,
        per: &named_per/1,
        function: &name/1,
        schema: &named_schema/1
      ],
      source,
      fn {key, fun}, source ->
        if Map.has_key?(source, key), do: Map.update!(source, key, fun), else: source
      end
    )
  end

  defp name(name) when is_atom(name) and name not in @not_names, do: Names.name(name)
  defp name(name), do: name

  defp named_inputs(inputs) when is_list(inputs) do
    Enum.map(inputs, fn
      {name, window} -> {input(name), named_window(window)}
      other -> other
    end)
  end

  defp named_inputs(other), do: other

  # A request window's region is keyed by its input's fields, their strings.
  defp named_window(%{region: region} = window) when is_map(region) and not is_struct(region),
    do: %{window | region: Names.keys(region)}

  defp named_window(window), do: window

  defp input([_ | _] = path), do: Enum.map(path, &name/1)
  defp input({:source, name}), do: {:source, name(name)}
  defp input(name), do: name(name)

  defp named_per({:identity, name}), do: {:identity, input(name)}
  defp named_per(other), do: other

  # The schema as its map form reads it back: every field name and category value a string.
  defp named_schema(%Schema{} = schema), do: schema

  defp named_schema(fields) when is_map(fields) and not is_struct(fields) do
    with {:ok, schema} <- Schema.new(fields),
         {:ok, schema} <- Schema.from_map(Schema.to_map(schema)) do
      schema
    else
      {:error, _errors} -> fields
    end
  end

  defp named_schema(other), do: other

  defp id(%{id: id}) when is_binary(id) and id != "", do: []
  defp id(%{id: _id}), do: [{[:id], {:type, :name}}]
  defp id(_source), do: [{[:id], :required}]

  defp from(nil), do: [{[:from], :required}]

  defp from([_ | _] = inputs) do
    each =
      inputs
      |> Enum.with_index()
      |> Enum.flat_map(fn
        {{name, window}, i} -> input_name(name, i) ++ window_faults(window, [:from, i, :window])
        {_other, i} -> [{[:from, i], {:type, :input}}]
      end)

    each ++ duplicate_keys(inputs)
  end

  defp from(_other), do: [{[:from], {:type, :inputs}}]

  defp input_name(name, _i) when is_binary(name) and name != "", do: []
  defp input_name({:source, name}, _i) when is_binary(name) and name != "", do: []

  defp input_name([_ | _] = path, i) do
    if Enum.all?(path, &(is_binary(&1) and &1 != "")),
      do: [],
      else: [{[:from, i], {:type, :input_name}}]
  end

  defp input_name(_name, i), do: [{[:from, i], {:type, :input_name}}]

  defp window_faults(nil, _path), do: []

  defp window_faults(%{last: last} = window, path) when map_size(window) == 1 do
    if is_integer(last) and last > 0, do: [], else: [{path ++ [:last], {:type, :pos_integer}}]
  end

  # A request window's own faults are its input's schema's to find, in context
  # (`validate/2`); alone, it is a map of request fields `Request.new/1` reads.
  defp window_faults(window, path) when is_map(window) and not is_struct(window) do
    keys = Map.keys(window)

    cond do
      keys == [] or keys -- @request_keys != [] ->
        [{path, {:type, :window}}]

      true ->
        case Request.new(Map.to_list(window) ++ [now: DateTime.from_unix!(0)]) do
          {:ok, _request} -> []
          {:error, faults} -> for {at, reason} <- faults, do: {path ++ at, reason}
        end
    end
  end

  defp window_faults(_other, path), do: [{path, {:type, :window}}]

  # Two inputs read under one key: the function could not tell them apart.
  defp duplicate_keys(inputs) do
    inputs
    |> Enum.with_index()
    |> Enum.reduce({MapSet.new(), []}, fn
      {{name, _window}, i}, {seen, errors} ->
        case key(name) do
          nil ->
            {seen, errors}

          key ->
            if MapSet.member?(seen, key),
              do: {seen, [{[:from, i], {:duplicate_input, key}} | errors]},
              else: {MapSet.put(seen, key), errors}
        end

      _other, acc ->
        acc
    end)
    |> elem(1)
  end

  defp schema(%{schema: %Schema{}}), do: []

  defp schema(%{schema: fields}) when is_map(fields) and not is_struct(fields) do
    case Schema.new(fields) do
      {:ok, _schema} -> []
      {:error, errors} -> Enum.map(errors, fn {path, reason} -> {[:schema | path], reason} end)
    end
  end

  defp schema(%{schema: _other}), do: [{[:schema], {:type, :schema}}]
  defp schema(_source), do: [{[:schema], :required}]

  # One function: stored source text, checked; or a host function's name.
  defp function(source) do
    case {Map.get(source, :elixir), Map.get(source, :function)} do
      {nil, nil} -> [{[:elixir], :required}]
      {elixir, nil} -> elixir(elixir, [])
      {nil, name} when is_binary(name) and name != "" -> []
      {nil, _name} -> [{[:function], {:type, :name}}]
      {_elixir, _name} -> [{[:function], {:exclusive, :elixir}}]
    end
  end

  defp elixir(elixir, opts) when is_binary(elixir) do
    case Sandbox.check(elixir, opts) do
      {:ok, _quoted} -> []
      {:error, faults} -> for {line, reason} <- faults, do: {[:elixir], {:check, line, reason}}
    end
  end

  defp elixir(_other, _opts), do: [{[:elixir], {:type, :string}}]

  defp per(nil, _from), do: []
  defp per(:identity, [_, _ | _]), do: [{[:per], {:per, :ambiguous}}]
  defp per(:identity, _from), do: []

  defp per({:identity, name}, from) when is_list(from) do
    if Enum.any?(from, &match?({^name, _window}, &1)),
      do: [],
      else: [{[:per], {:per, {:unknown_input, name}}}]
  end

  defp per({:identity, _name}, _from), do: []
  defp per(_other, _from), do: [{[:per], {:enum, [:identity]}}]

  # -- in context (spec/02 §1.1) -----------------------------------------------------------

  @doc """
  `:ok`, or every fault of the source given what it reads (spec/02 §1.1): `inputs:`, a map
  from an input's key (or name) to its `%Macaw.Data.Schema{}` where it is known, and
  `functions:`, the host functions' registry (`Macaw.Data.Derived.Functions.registry/1`),
  or `nil` to leave the name unchecked.
  """
  @spec validate(t(), keyword()) :: :ok | {:error, [error(), ...]}
  def validate(%__MODULE__{} = source, opts \\ []) do
    opts = Keyword.validate!(opts, inputs: %{}, functions: nil)
    inputs = opts[:inputs]

    errors =
      elixir_check(source, inputs) ++
        functions_check(source, opts[:functions]) ++
        windows_check(source, inputs) ++ identity_check(source, inputs)

    case Enum.sort_by(errors, &elem(&1, 0)) do
      [] -> :ok
      errors -> {:error, errors}
    end
  end

  # With every input's schema known, a map read names one of their fields or the output's.
  defp elixir_check(%{elixir: nil}, _inputs), do: []

  defp elixir_check(source, inputs) do
    if Enum.all?(source.from, fn {name, _window} -> fetch_input(inputs, name) != :error end) do
      fields =
        Enum.flat_map(source.from, fn {name, _window} ->
          {:ok, schema} = fetch_input(inputs, name)
          Map.keys(schema.fields)
        end) ++ Map.keys(source.schema.fields)

      elixir(source.elixir, fields: fields)
    else
      []
    end
  end

  # An input's schema by its key's spelling: an owner keys `inputs:` by atom or string.
  defp fetch_input(inputs, name) do
    spelled = to_string(key(name))

    case Enum.find(inputs, fn {k, _v} -> to_string(key(input(k)) || k) == spelled end) do
      nil -> :error
      {_k, schema} -> {:ok, schema}
    end
  end

  defp functions_check(%{function: nil}, _functions), do: []
  defp functions_check(_source, nil), do: []

  defp functions_check(%{function: name}, functions) do
    if Names.key(functions, name) != :error,
      do: [],
      else: [{[:function], {:undeclared, :function, name}}]
  end

  defp windows_check(source, inputs) do
    source.from
    |> Enum.with_index()
    |> Enum.flat_map(fn
      {{name, %{} = window}, i} when not is_map_key(window, :last) ->
        case fetch_input(inputs, name) do
          {:ok, schema} -> request_faults(window, schema, [:from, i, :window])
          :error -> []
        end

      _other ->
        []
    end)
  end

  defp request_faults(window, schema, path) do
    with {:ok, request} <- request(window),
         :ok <- Window.check(request, schema) do
      []
    else
      {:error, faults} -> for {at, reason} <- faults, do: {path ++ at, reason}
    end
  end

  # A request window as a request: finishing reads no clock, so `now` is a fixed instant.
  defp request(window), do: Request.new(Map.to_list(window) ++ [now: DateTime.from_unix!(0)])

  # Per identity, the output's identity is the input's: the same fields, of the same types.
  defp identity_check(%{per: nil}, _inputs), do: []

  defp identity_check(source, inputs) do
    case fetch_input(inputs, identity_input(source)) do
      {:ok, input} -> same_identity(input, source.schema)
      :error -> []
    end
  end

  defp same_identity(input, output) do
    ours = Schema.identity(input)
    theirs = Schema.identity(output)
    names = fn fields -> fields |> Enum.map(&to_string/1) |> Enum.sort() end

    cond do
      ours == [] ->
        [{[:per], {:per, :no_identity}}]

      names.(ours) != names.(theirs) ->
        [{[:schema], {:per, {:identity, names.(ours), names.(theirs)}}}]

      true ->
        for field <- theirs,
            {:ok, a} = Schema.fetch(input, field, :type),
            {:ok, b} = Schema.fetch(output, field, :type),
            a != b,
            do: {[:schema, field], {:per, {:identity_type, field, a, b}}}
    end
  end

  # -- inputs (spec/02 §2) -----------------------------------------------------------------

  @doc """
  The key an input is read under (spec/02 §2.1): a short id, a source's name, or a path's
  last name, its string.

      iex> Macaw.Data.Derived.key(["ops", "health"])
      "health"
      iex> Macaw.Data.Derived.key({:source, "vm.memory.total"})
      "vm.memory.total"
  """
  @spec key(name() | atom()) :: String.t() | nil
  def key([_ | _] = path), do: path |> List.last() |> Names.name()
  def key({:source, name}), do: Names.name(name)

  def key(name) when is_binary(name) or (is_atom(name) and name not in @not_names),
    do: Names.name(name)

  def key(_other), do: nil

  @doc """
  The name of the input a `per` source's entities come from: the only input under
  `:identity`, the one named under `{:identity, input}`; `nil` without `per` (spec/02 §1.3).
  """
  @spec identity_input(t()) :: name() | nil
  def identity_input(%__MODULE__{per: nil}), do: nil
  def identity_input(%__MODULE__{per: :identity, from: [{name, _window} | _]}), do: name
  def identity_input(%__MODULE__{per: {:identity, name}}), do: name

  @doc """
  An input's rows in its window (spec/02 §2.2): `nil` every row; `%{last: n}` each
  identity's newest `n` rows by the window field, else the newest `n`; a request the rows
  its window, box, region and latest select, finished by `Macaw.Data.Source.Finish`.

      iex> schema = Macaw.Data.Schema.new!(%{t: %{type: :number, window: true}, v: %{type: :number}})
      iex> rows = for t <- 1..5, do: %{t: t, v: t * 10}
      iex> Macaw.Data.Derived.window(rows, %{last: 2}, schema)
      [%{t: 4, v: 40}, %{t: 5, v: 50}]
      iex> Macaw.Data.Derived.window(rows, %{window: [2, 3]}, schema)
      [%{t: 2, v: 20}, %{t: 3, v: 30}]
  """
  @spec window([map()], window(), Schema.t()) :: [map()]
  def window(rows, nil, _schema), do: rows

  def window(rows, %{last: n}, schema) do
    rows = in_time_order(rows, schema)

    case Schema.identity(schema) do
      [] ->
        Enum.take(rows, -n)

      _identity ->
        keep =
          rows
          |> Enum.with_index()
          |> Enum.group_by(fn {row, _i} -> Schema.identity(schema, row) end, fn {_row, i} -> i end)
          |> Enum.reject(fn {identity, _indices} -> identity == nil end)
          |> Enum.flat_map(fn {_identity, indices} -> Enum.take(indices, -n) end)
          |> MapSet.new()

        for {row, i} <- Enum.with_index(rows), MapSet.member?(keep, i), do: row
    end
  end

  def window(rows, %{} = window, schema) do
    {:ok, request} = request(window)
    description = %Description{schema: schema}

    rows
    |> Delivery.new()
    |> Finish.finish(description, request)
    |> Delivery.rows()
  end

  # In the window field's order, ties kept where they stand; rows with a time missing are
  # left as they came.
  defp in_time_order(rows, schema) do
    case Schema.window_field(schema) do
      nil ->
        rows

      field ->
        if Enum.all?(rows, &(Window.position(Table.get(&1, field)) != nil)),
          do: Enum.sort_by(rows, &Window.position(Table.get(&1, field))),
          else: rows
    end
  end

  @doc """
  The first argument a function is called with (spec/02 §2.2): the inputs as one map from
  key to rows. A stored function reads a key, a row's field and a row's category value as
  it reads its own literals, a word's atom, else the string; a host's function reads each
  key as its string and each row as its source gave it.
  """
  @spec argument(t(), [input()]) :: map()
  def argument(%__MODULE__{} = source, inputs) when is_list(inputs),
    do: Map.new(inputs, &{argument_key(source, &1.name), argument_rows(source, &1.rows)})

  defp argument_key(%{elixir: elixir}, name) when is_binary(elixir),
    do: Spelling.spelling(key(name))

  defp argument_key(_source, name), do: key(name)

  defp argument_rows(%{elixir: elixir}, rows) when is_binary(elixir) and is_list(rows),
    do: Enum.map(rows, &spelled/1)

  defp argument_rows(_source, rows), do: rows

  defp spelled(row) when is_map(row) and not is_struct(row),
    do: Map.new(row, fn {k, v} -> {Spelling.spelling(k), Spelling.spelling(v)} end)

  defp spelled(row), do: row

  # -- the output (spec/02 §1.2, §1.3) -----------------------------------------------------

  @doc """
  An answer held to the source's schema (spec/02 §1.2): `{:ok, rows}`, the rows keyed by
  their fields' strings, or `{:error, {index, field, reason}}` for the first row that does
  not hold, never the value.
  """
  @spec conform(t(), term()) ::
          {:ok, [map()]} | {:error, {non_neg_integer() | nil, String.t() | nil, term()}}
  def conform(%__MODULE__{schema: schema}, rows) when is_list(rows) do
    identity = Schema.identity(schema)

    fault =
      rows
      |> Enum.with_index()
      |> Enum.find_value(fn {row, i} ->
        case row_fault(row, schema, identity) do
          nil -> nil
          {field, reason} -> {:error, {i, field, reason}}
        end
      end)

    fault || {:ok, Enum.map(rows, &keyed/1)}
  end

  def conform(%__MODULE__{}, _other), do: {:error, {nil, nil, :not_a_list}}

  defp keyed(row), do: Map.new(row, fn {k, v} -> {Names.name(k), v} end)

  defp row_fault(row, _schema, _identity) when not is_map(row) or is_struct(row),
    do: {nil, :not_a_row}

  defp row_fault(row, schema, identity) do
    undescribed(row, schema) || missing_identity(row, identity) ||
      Enum.find_value(row, fn {key, value} -> value_fault(schema, key, value) end)
  end

  defp undescribed(row, schema) do
    Enum.find_value(Map.keys(row), fn key ->
      if (is_atom(key) or is_binary(key)) and Schema.fetch(schema, key) != :error,
        do: nil,
        else: {field_name(key), :undescribed}
    end)
  end

  defp field_name(key) when is_atom(key) or is_binary(key), do: Names.name(key)
  defp field_name(_key), do: nil

  defp missing_identity(row, identity) do
    Enum.find_value(identity, fn field ->
      if Table.get(row, field) == nil, do: {Names.name(field), :no_identity}
    end)
  end

  defp value_fault(_schema, _key, nil), do: nil

  defp value_fault(schema, key, value) do
    {:ok, description} = Schema.fetch(schema, key)

    cond do
      not typed?(description.type, value) -> {Names.name(key), {:type, description.type}}
      not member?(Schema.values(schema, key), value) -> {Names.name(key), :not_in_values}
      true -> nil
    end
  end

  defp typed?(:number, value), do: is_number(value)
  defp typed?(:time, value), do: Window.instant?(value)
  defp typed?(:text, value), do: is_binary(value)
  defp typed?(:color, value), do: Schema.color?(value)
  defp typed?(:point, {lon, lat}), do: is_number(lon) and is_number(lat)
  defp typed?(:point, _value), do: false

  defp typed?(:category, value),
    do: is_binary(value) or is_number(value) or (is_atom(value) and not is_boolean(value))

  # A category value is one whichever spelling the function or the schema gives it.
  defp member?(nil, _value), do: true
  defp member?(values, value), do: Enum.any?(values, &Names.same?(&1, value))

  @doc """
  A `per` source's batch over read inputs (spec/02 §1.3): `call` is the function applied to
  one entity's argument (`argument/2`'s map, or the entity's rows alone when the source
  has one input), called once per entity of the identity input in its order of first
  appearance, a row with no identity dropped. Each answer, a row or a list of rows, is
  given its entity's identity and the answers joined: `{:ok, rows}`, or
  `{:error, :nonconforming, {index, field, reason}}` for an answer that is not rows or a
  row naming another identity. The caller runs the whole batch as one bounded call.
  """
  @spec per(t(), [input()], (term() -> term())) ::
          {:ok, [map()]} | {:error, :nonconforming, {term(), term(), term()}}
  def per(%__MODULE__{} = source, inputs, call) when is_function(call, 1) do
    name = identity_input(source)
    identity_input = Enum.find(inputs, &(&1.name == name))
    groups = entities(identity_input.rows, identity_input.schema)

    argument = fn rows ->
      case inputs do
        [_one] ->
          argument_rows(source, rows)

        _several ->
          argument(
            source,
            Enum.map(inputs, fn input ->
              if input.name == name, do: %{input | rows: rows}, else: input
            end)
          )
      end
    end

    answers = Enum.map(groups, fn {identity, rows} -> {identity, call.(argument.(rows))} end)
    join_answers(answers, Schema.identity(source.schema))
  end

  defp entities(rows, schema) do
    {order, groups} =
      Enum.reduce(rows, {[], %{}}, fn row, {order, groups} ->
        case Schema.identity(schema, row) do
          nil ->
            {order, groups}

          identity ->
            if Map.has_key?(groups, identity),
              do: {order, Map.update!(groups, identity, &[row | &1])},
              else: {[identity | order], Map.put(groups, identity, [row])}
        end
      end)

    for identity <- Enum.reverse(order), do: {identity, Enum.reverse(groups[identity])}
  end

  defp join_answers(answers, fields) do
    answers
    |> Enum.reduce_while({:ok, []}, fn {identity, answer}, {:ok, acc} ->
      case entity_rows(answer) do
        {:ok, rows} -> {:cont, {:ok, acc ++ Enum.map(rows, &{identity, &1})}}
        :error -> {:halt, {:error, :nonconforming, {nil, nil, :not_a_list}}}
      end
    end)
    |> case do
      {:ok, pairs} -> identify(pairs, fields)
      error -> error
    end
  end

  defp entity_rows(row) when is_map(row) and not is_struct(row), do: {:ok, [row]}
  defp entity_rows(rows) when is_list(rows), do: {:ok, rows}
  defp entity_rows(_other), do: :error

  # Each row given its entity's identity; a row that names another value for one does not
  # conform.
  defp identify(pairs, fields) do
    pairs
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {{identity, row}, i}, {:ok, acc} ->
      case stamp(row, identity, fields) do
        {:ok, row} -> {:cont, {:ok, [row | acc]}}
        {:error, field} -> {:halt, {:error, :nonconforming, {i, field, :identity}}}
      end
    end)
    |> case do
      {:ok, rows} -> {:ok, Enum.reverse(rows)}
      error -> error
    end
  end

  defp stamp(row, _identity, _fields) when not is_map(row) or is_struct(row), do: {:ok, row}

  defp stamp(row, identity, fields) do
    row = Map.new(row, fn {k, v} -> {field_name(k) || k, v} end)

    Enum.reduce_while(fields, {:ok, row}, fn field, {:ok, row} ->
      name = Names.name(field)
      given = identity_value(identity, field, fields)

      case Map.fetch(row, name) do
        {:ok, value} when value != nil ->
          if Names.same?(value, given),
            do: {:cont, {:ok, row}},
            else: {:halt, {:error, name}}

        _absent ->
          {:cont, {:ok, Map.put(row, name, given)}}
      end
    end)
  end

  # `Schema.identity/2` answers a single field's value alone, and a composite identity as a
  # map of its fields.
  defp identity_value(identity, _field, [_one]), do: identity
  defp identity_value(identity, field, _fields), do: Table.get(identity, field)

  # -- scoping (spec/02 §3) ----------------------------------------------------------------

  @doc """
  A path shown dotted (spec/02 §3).

      iex> Macaw.Data.Derived.dotted(["ops", "health"])
      "ops.health"
  """
  @spec dotted([String.t() | atom()]) :: String.t()
  def dotted(path) when is_list(path), do: Enum.map_join(path, ".", &Names.name/1)

  @doc """
  What a reference names (spec/02 §3), given every definition's path (a list, or a map
  keyed by path) and the scope it is read from: a short id from the inside out, a full
  path exactly. `{:ok, path}` or `:error`; `{:source, name}` is never resolved.

      iex> paths = [["health"], ["ops", "health"], ["ops", "box", "load"]]
      iex> Macaw.Data.Derived.resolve(paths, ["ops", "box"], "health")
      {:ok, ["ops", "health"]}
      iex> Macaw.Data.Derived.resolve(paths, ["other"], :health)
      {:ok, ["health"]}
      iex> Macaw.Data.Derived.resolve(paths, [], ["ops", "box", "load"])
      {:ok, ["ops", "box", "load"]}
      iex> Macaw.Data.Derived.resolve(paths, ["ops"], {:source, "health"})
      :error
  """
  @spec resolve([list()] | map(), list(), term()) :: {:ok, [String.t()]} | :error
  def resolve(paths, scope, ref) when is_map(paths), do: resolve(Map.keys(paths), scope, ref)

  def resolve(paths, scope, ref)
      when is_list(paths) and is_list(scope) and
             (is_binary(ref) or (is_atom(ref) and ref not in @not_names)) do
    ref = Names.name(ref)
    scope = Enum.map(scope, &Names.name/1)
    known = MapSet.new(paths, &spelled_path/1)

    Enum.find_value(length(scope)..0//-1, :error, fn n ->
      path = Enum.take(scope, n) ++ [ref]
      if MapSet.member?(known, path), do: {:ok, path}
    end)
  end

  def resolve(paths, _scope, [_ | _] = ref) when is_list(paths) do
    ref = spelled_path(ref)
    if ref in Enum.map(paths, &spelled_path/1), do: {:ok, ref}, else: :error
  end

  def resolve(_paths, _scope, _ref), do: :error

  defp spelled_path(path) when is_list(path), do: Enum.map(path, &Names.name/1)
  defp spelled_path(other), do: other

  @doc """
  Every cycle among definitions whose inputs are resolved (spec/02 §3): `reads` maps each
  path to the paths it reads. Each strongly connected component that holds a cycle, a
  source that reads itself included, is its members' paths, sorted; the cycles are sorted
  too. Sources downstream of a cycle are in none.

      iex> Macaw.Data.Derived.cycles(%{["a"] => [["b"]], ["b"] => [["a"]], ["c"] => [["a"]], ["d"] => [["d"]]})
      [[["a"], ["b"]], [["d"]]]
  """
  @spec cycles(%{list() => [list()]}) :: [[list(), ...]]
  def cycles(reads) when is_map(reads) do
    graph = :digraph.new()

    for {path, inputs} <- reads do
      :digraph.add_vertex(graph, path)

      for input <- inputs do
        :digraph.add_vertex(graph, input)
        :digraph.add_edge(graph, path, input)
      end
    end

    cycles =
      graph
      |> :digraph_utils.cyclic_strong_components()
      |> Enum.map(&Enum.sort/1)
      |> Enum.sort()

    :digraph.delete(graph)
    cycles
  end

  # -- forms (spec/02 §1.5) ----------------------------------------------------------------

  @doc """
  The source's map form (spec/02 §1.5), JSON-ready with every name a string:
  `new(to_map(derived)) == {:ok, derived}`.
  """
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = source), do: Form.to_map(source)

  @doc "The source's JSON form: `to_map/1`, encoded."
  @spec to_json(t()) :: String.t()
  def to_json(%__MODULE__{} = source), do: JSON.encode!(to_map(source))

  @doc """
  The derived source a JSON document holds: read through `macaw_layers`' limits and scan
  first, so input over a limit is refused before it is decoded (`limits:` tightens them),
  then decoded and read by `new/1`.
  """
  @spec from_json(binary(), keyword()) :: {:ok, t()} | {:error, [error(), ...]}
  def from_json(json, opts \\ []) when is_binary(json) do
    case Form.decode(json, opts) do
      {:ok, map} -> new(map)
      {:error, errors} -> {:error, errors}
    end
  end

  # -- words -------------------------------------------------------------------------------

  @doc """
  One fault as a line a person reads, the root named `derived source` (spec/02 §1.1).

      iex> Macaw.Data.Derived.format_error({[:per], {:per, :ambiguous}})
      "per: is :identity over several inputs: name the input, {:identity, input}"
  """
  @spec format_error(error()) :: String.t()
  def format_error({[:schema | path], reason}) when path != [],
    do: "schema: " <> Schema.format_error({path, reason})

  def format_error({path, reason}), do: "#{path_text(path)}: #{words(reason)}"

  defp path_text([]), do: "derived source"
  defp path_text(path), do: Enum.map_join(path, ".", &to_string/1)

  defp words({:type, :derived}), do: "is neither a map nor a keyword list"
  defp words(:unknown_key), do: "is not a key of a derived source"
  defp words(:required), do: "is required"
  defp words({:type, expected}), do: "must be #{type_words(expected)}"
  defp words({:exclusive, :elixir}), do: "is given beside elixir: a source has one function"
  defp words({:duplicate_input, key}), do: "reads a second input under the key #{inspect(key)}"

  defp words({:check, line, reason}),
    do: Sandbox.format_error({line, reason})

  defp words({:undeclared, :function, name}),
    do: "names #{inspect(name)}, which no registered host module defines"

  defp words({:enum, [:identity]}), do: "must be nil, :identity or {:identity, input}"

  defp words({:per, :ambiguous}),
    do: "is :identity over several inputs: name the input, {:identity, input}"

  defp words({:per, {:unknown_input, name}}), do: "names #{inspect(name)}, which is no input"

  defp words({:per, :no_identity}),
    do: "is per identity, and its identity input's schema declares no identity"

  defp words({:per, {:identity, input, output}}),
    do: "declares identity #{inspect(output)}, which must be its input's, #{inspect(input)}"

  defp words({:per, {:identity_type, field, input, output}}),
    do: "#{inspect(field)} is #{inspect(output)} here and #{inspect(input)} in its input"

  defp words(reason), do: inspect(reason)

  defp type_words(:name), do: "a name: a non-empty string or an atom"
  defp type_words(:inputs), do: "a non-empty list of {name, window}"
  defp type_words(:input), do: "a {name, window} pair"
  defp type_words(:input_name), do: "a short id, {:source, name}, or a path of names"
  defp type_words(:string), do: "a string of Elixir source"
  defp type_words(:schema), do: "a map of field descriptions"
  defp type_words(:window), do: "nil, %{last: n}, or a map of window, box, region and latest"
  defp type_words(:pos_integer), do: "a positive integer"
  defp type_words(other), do: inspect(other)
end
