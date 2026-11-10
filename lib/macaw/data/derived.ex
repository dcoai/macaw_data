defmodule Macaw.Data.Derived do
  @moduledoc """
  A derived source: a source computed from other sources by a function, rows in and rows
  out by default, or read as columns under `input: :columns` (spec/02 §2.2). Ported from visualize's `Visualize.VirtualSource` (visualize#643, D-194).

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

  import Macaw.Data.Lists, only: [is_proper_list: 1]

  alias Macaw.Data.{Delivery, Schema, Table, Window}
  alias Macaw.Data.Derived.{Form, Last, Sandbox}
  alias Macaw.Data.Derived.Sandbox.Names, as: Spelling
  alias Macaw.Data.Source.{Description, Finish, Order, Request}
  alias Macaw.Layers.Names

  @keys [:id, :from, :schema, :elixir, :function, :per, :input]
  @request_keys [:window, :box, :region, :latest]
  @not_names [nil, true, false]

  @enforce_keys [:id, :from, :schema]
  defstruct [:id, :from, :schema, elixir: nil, function: nil, per: nil, input: :rows]

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
          per: nil | :identity | {:identity, name()},
          input: :rows | :columns
        }

  @typedoc "A fault: the path from the source to the value, and why (spec/02 §1.1)."
  @type error :: {list(), term()}

  @typedoc """
  An input as its owner read it (spec/02 §1.3, §2.2): its name, its rows in its window,
  its schema, and the delivery it came in.
  """
  @type input :: %{
          required(:name) => name(),
          required(:rows) => [map()] | Table.t(),
          required(:schema) => Schema.t(),
          optional(:delivery) => Delivery.t()
        }

  # -- construction (spec/02 §1.1) ---------------------------------------------------------

  @doc """
  A derived source of its value, a keyword list or a map of its fields as terms, checked
  alone (spec/02 §1.1): `{:ok, derived}`, or `{:error, errors}` with every fault by path.
  Its keys are atoms, and a string key is none of them: a map form is refused key by key
  as `:unknown_key`, since it is read by `from_map/2`, never guessed at here.
  """
  @spec new(map() | keyword()) :: {:ok, t()} | {:error, [error(), ...]}
  def new(source) when is_list(source) do
    if Keyword.keyword?(source),
      do: new(Map.new(source)),
      else: {:error, [{[], {:type, :derived}}]}
  end

  def new(source) when is_map(source) and not is_struct(source), do: checked(source)

  def new(_other), do: {:error, [{[], {:type, :derived}}]}

  defp checked(source) do
    source = named(source)

    errors =
      for(key <- Map.keys(source), key not in @keys, do: {[key], :unknown_key}) ++
        id(source) ++
        from(Map.get(source, :from)) ++
        schema(source) ++
        function(source) ++
        per(Map.get(source, :per), Map.get(source, :from)) ++
        input_mode(Map.get(source, :input) || :rows)

    case Enum.sort_by(errors, &elem(&1, 0)) do
      [] ->
        {:ok,
         %__MODULE__{
           id: source.id,
           from: source.from,
           schema: source.schema,
           elixir: Map.get(source, :elixir),
           function: Map.get(source, :function),
           per: Map.get(source, :per),
           input: Map.get(source, :input) || :rows
         }}

      errors ->
        {:error, errors}
    end
  end

  @doc "The derived source, or `Macaw.Data.Error` naming every fault."
  @spec new!(map() | keyword()) :: t()
  def new!(source) do
    case new(source) do
      {:ok, source} ->
        source

      {:error, errors} ->
        raise Macaw.Data.Error,
          reason: errors,
          message:
            "not a derived source:\n" <>
              Enum.map_join(errors, "\n", &("  " <> format_error(&1)))
    end
  end

  # A source's names are strings (spec/02 §1.1): its id, its inputs' names and paths, its
  # identity input, its function and its output's schema's (`Schema.new/1`'s), so an atom
  # and a string of one spelling are one name.
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

  defp named_inputs(inputs) when is_proper_list(inputs) do
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

  defp input([_ | _] = path) when is_proper_list(path), do: Enum.map(path, &name/1)
  defp input({:source, name}), do: {:source, name(name)}
  defp input(name), do: name(name)

  defp named_per({:identity, name}), do: {:identity, input(name)}
  defp named_per(other), do: other

  # The schema as built: a `%Schema{}` as given, fields by `Schema.new/1`, which holds every
  # name, state and role as its string. No form is written or read.
  defp named_schema(%Schema{} = schema), do: schema

  defp named_schema(fields) when is_map(fields) and not is_struct(fields) do
    case Schema.new(fields) do
      {:ok, schema} -> schema
      {:error, _errors} -> fields
    end
  end

  defp named_schema(other), do: other

  defp id(%{id: id}) when is_binary(id) and id != "", do: []
  defp id(%{id: _id}), do: [{[:id], {:type, :name}}]
  defp id(_source), do: [{[:id], :required}]

  defp from(nil), do: [{[:from], :required}]

  defp from([_ | _] = inputs) when is_proper_list(inputs) do
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

  defp input_name([_ | _] = path, i) when is_proper_list(path) do
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
      {elixir, nil} -> elixir(elixir, operations: nil)
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

  defp per({:identity, name}, from) when is_proper_list(from) do
    if Enum.any?(from, &match?({^name, _window}, &1)),
      do: [],
      else: [{[:per], {:per, {:unknown_input, name}}}]
  end

  defp per({:identity, _name}, _from), do: []
  defp per(_other, _from), do: [{[:per], {:enum, [:identity]}}]

  # How the function reads its inputs (spec/02 §2.2): as rows, the default, or as tables.
  defp input_mode(mode) when mode in [:rows, :columns], do: []
  defp input_mode(_other), do: [{[:input], {:enum, [:rows, :columns]}}]

  # -- in context (spec/02 §1.1) -----------------------------------------------------------

  @doc """
  `:ok`, or every fault of the source given what it reads (spec/02 §1.1): `inputs:`, a map
  from an input's key (or name) to its `%Macaw.Data.Schema{}` where it is known, and
  `functions:`, the host functions' registry (`Macaw.Data.Derived.Functions.registry/1`),
  or `nil` to leave the name unchecked, and `operations:`, the registry a stored
  function's `Macaw.Data.Ops` calls are held to (`Macaw.Data.Operations.registry/1`), or
  `nil` to hold their names only to being literals (spec/04 §6.1). An option it does not
  take is `{[key], :unknown_key}` (spec/00 §5).
  """
  @spec validate(t(), keyword()) :: :ok | {:error, [error(), ...]}
  def validate(%__MODULE__{} = source, opts \\ []) do
    case Macaw.Data.Options.known(opts, inputs: %{}, functions: nil, operations: nil) do
      {:ok, opts} -> validated(source, opts)
      {:error, _faults} = error -> error
    end
  end

  defp validated(source, opts) do
    inputs = opts[:inputs]

    errors =
      elixir_check(source, inputs, opts[:operations]) ++
        functions_check(source, opts[:functions]) ++
        windows_check(source, inputs) ++ identity_check(source, inputs)

    case Enum.sort_by(errors, &elem(&1, 0)) do
      [] -> :ok
      errors -> {:error, errors}
    end
  end

  # With every input's schema known, a map read names one of their fields or the output's.
  defp elixir_check(%{elixir: nil}, _inputs, _operations), do: []

  defp elixir_check(source, inputs, operations) do
    if Enum.all?(source.from, fn {name, _window} -> fetch_input(inputs, name) != :error end) do
      fields =
        Enum.flat_map(source.from, fn {name, _window} ->
          {:ok, schema} = fetch_input(inputs, name)
          Map.keys(schema.fields)
        end) ++ Map.keys(source.schema.fields)

      elixir(source.elixir, fields: fields, operations: operations)
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
  def key([_ | _] = path) when is_proper_list(path), do: path |> List.last() |> Names.name()
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
  An input in its window (spec/02 §2.2), a table or a list of rows: `nil` every row and
  `%{last: n}` each identity's newest `n` rows by the window field, else the newest `n`,
  each in the input's form; a request the rows its window, box, region and latest select,
  finished by `Macaw.Data.Source.Finish`, also in the input's form: a table finished on
  its columns stays a table (macaw_data#105).

  The window field orders by its type's key (`order_key/2`): a `:time` by its instant
  (`Macaw.Data.Source.Order.instant/1`, every kind of time on one scale), a `:number` by
  its value, stably; when a row has no key, the rows are left as they came. A table is
  windowed on its columns, by `last: n` and by a request alike, and no row is made: the
  kept rows are views of its chunks or gathered from them.

      iex> schema = Macaw.Data.Schema.new!(%{t: %{type: :number, window: true}, v: %{type: :number}})
      iex> rows = for t <- 1..5, do: %{t: t, v: t * 10}
      iex> Macaw.Data.Derived.window(rows, %{last: 2}, schema)
      [%{t: 4, v: 40}, %{t: 5, v: 50}]
      iex> Macaw.Data.Derived.window(rows, %{window: [2, 3]}, schema)
      [%{t: 2, v: 20}, %{t: 3, v: 30}]
      iex> table = Macaw.Data.Table.from(rows) |> elem(1)
      iex> Macaw.Data.Derived.window(table, %{last: 2}, schema) |> Macaw.Data.Table.column(:v)
      [40, 50]
      iex> Macaw.Data.Derived.window(table, %{window: [2, 3]}, schema) |> Macaw.Data.Table.column(:v)
      [20, 30]
  """
  @spec window(Table.t() | [map()], window(), Schema.t()) :: Table.t() | [map()]
  def window(subject, nil, _schema), do: subject

  def window(%Table{} = table, %{last: n}, schema), do: Last.window(table, n, schema)

  def window(rows, %{last: n}, schema) when is_list(rows) do
    rows = in_order(rows, schema)

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

  # A request is finished as the runtime finishes a delivery, a table on its columns
  # (spec/01 §2.4, macaw_data#105), in the input's form.
  def window(subject, %{} = window, schema) when is_list(subject) or is_struct(subject, Table) do
    {:ok, request} = request(window)
    description = %Description{schema: schema}
    %Delivery{rows: finished} = Finish.finish!(Delivery.new!(subject), description, request)
    finished
  end

  @doc """
  The type a window field orders by under `last: n` (spec/02 §2.2): `{:ok, :time}` or
  `{:ok, :number}`, keyed by `Macaw.Data.Source.Order.key/2`; `:error` for a field of
  another type, or none, whose rows keep their order.
  """
  @spec order_key(Schema.t(), name() | atom()) :: {:ok, :time | :number} | :error
  def order_key(%Schema{} = schema, field) do
    case Schema.fetch(schema, field, :type) do
      {:ok, type} when type in [:time, :number] -> {:ok, type}
      _other -> :error
    end
  end

  # In the window field's order by its key, ties kept where they stand; rows with a key
  # missing are left as they came.
  defp in_order(rows, schema) do
    with field when field != nil <- Schema.window_field(schema),
         {:ok, type} <- order_key(schema, field) do
      key = Order.key(type)
      keyed = Enum.map(rows, &{key.(Table.get(&1, field)), &1})

      if Enum.any?(keyed, &(elem(&1, 0) == nil)),
        do: rows,
        else: keyed |> then(&:lists.keysort(1, &1)) |> Enum.map(&elem(&1, 1))
    else
      _none -> rows
    end
  end

  @doc """
  The first argument a function is called with (spec/02 §2.2): the inputs as one map from
  key to rows. A stored function reads a key, a row's field and a row's category value as
  it reads its own literals, a word's atom, else the string; a host's function reads each
  key as its string and each row as its source gave it. Under `input: :columns` each key
  holds the input's table, as the engine hands it (spec/02 §8.2).
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

  A source that reads its inputs as columns (`input: :columns`) may also answer a
  `Macaw.Data.Table` or a column map, `%{field => [values]}`, held to the schema column by
  column and answered as the output table, packed under the schema and never made into
  rows: `{:ok, table}`. A fault of a whole column (`:undescribed`, `:duplicate`,
  `:not_a_column`, `{:length, n}`, a table column's `{:type, type}`) has index `nil`;
  any other is the lowest row index at fault, an identity gap before a value fault at one
  index, fields in name order.

      iex> source = Macaw.Data.Derived.new!(id: :c, from: [in: nil], input: :columns,
      ...>   schema: %{n: %{type: :number}, s: %{type: :category, values: [:ok]}}, function: :f)
      iex> {:ok, table} = Macaw.Data.Derived.conform(source, %{n: [1, 2], s: [:ok, nil]})
      iex> Macaw.Data.Table.rows!(table)
      [%{"n" => 1, "s" => "ok"}, %{"n" => 2, "s" => nil}]
      iex> Macaw.Data.Derived.conform(source, %{n: [1, "two"]})
      {:error, {1, "n", {:type, :number}}}
      iex> Macaw.Data.Derived.conform(source, %{n: [1], s: []})
      {:error, {nil, "s", {:length, 1}}}
  """
  @spec conform(t(), term()) ::
          {:ok, [map()] | Table.t()}
          | {:error, {non_neg_integer() | nil, String.t() | nil, term()}}
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

  def conform(%__MODULE__{input: :columns, schema: schema}, %Table{} = table),
    do: conform_table(schema, table)

  def conform(%__MODULE__{input: :columns, schema: schema}, columns)
      when is_map(columns) and not is_struct(columns),
      do: conform_map(schema, columns)

  def conform(%__MODULE__{}, _other), do: {:error, {nil, nil, :not_a_list}}

  # -- a columnar answer (spec/02 §1.2, macaw_data#107) ------------------------------------

  # A column map: every key a described field, by either spelling, once, its value a list,
  # every list of one length; then each column's values as a row's would be held.
  defp conform_map(schema, columns) do
    named =
      columns
      |> Enum.map(fn {key, values} -> {field_name(key), key, values} end)
      |> Enum.sort_by(fn {name, key, _values} -> {name || "", inspect(key)} end)

    with :ok <- whole_columns(named, schema),
         n = size_of(named),
         :ok <-
           rows_fault(schema, n, Map.new(named, fn {name, _key, values} -> {name, values} end)) do
      packed(schema, n, fn name ->
        case List.keyfind(named, name, 0) do
          {_name, _key, values} -> values
          nil -> nil
        end
      end)
    end
  end

  defp whole_columns(named, schema) do
    n = size_of(named)

    Enum.reduce_while(named, {:ok, MapSet.new()}, fn {name, key, values}, {:ok, seen} ->
      cond do
        not (is_atom(key) or is_binary(key)) or Schema.fetch(schema, key) == :error ->
          {:halt, {:error, {nil, name, :undescribed}}}

        MapSet.member?(seen, name) ->
          {:halt, {:error, {nil, name, :duplicate}}}

        not is_list(values) ->
          {:halt, {:error, {nil, name, :not_a_column}}}

        length(values) != n ->
          {:halt, {:error, {nil, name, {:length, n}}}}

        true ->
          {:cont, {:ok, MapSet.put(seen, name)}}
      end
    end)
    |> case do
      {:ok, _seen} -> :ok
      error -> error
    end
  end

  defp size_of([{_name, _key, values} | _]) when is_list(values), do: length(values)
  defp size_of(_named), do: 0

  # A table: every column a described field, once, of the field's type; then the columns
  # a table's type does not hold to the schema's (text and category hold any value) and
  # the identity read as a row's would be.
  defp conform_table(schema, table) do
    names = Table.names(table)

    whole =
      Enum.reduce_while(names, {:ok, MapSet.new()}, fn column, {:ok, seen} ->
        name = field_name(column)

        cond do
          name == nil or Schema.fetch(schema, column) == :error ->
            {:halt, {:error, {nil, name, :undescribed}}}

          MapSet.member?(seen, name) ->
            {:halt, {:error, {nil, name, :duplicate}}}

          Table.column_type(table, column) != Schema.fetch(schema, column, :type) |> elem(1) ->
            {:halt, {:error, {nil, name, {:type, elem(Schema.fetch(schema, column, :type), 1)}}}}

          true ->
            {:cont, {:ok, MapSet.put(seen, name)}}
        end
      end)

    with {:ok, _seen} <- whole,
         columns = Map.new(names, &{Names.name(&1), &1}),
         n = Table.size(table),
         read = fn name ->
           Map.get(columns, name) && Table.column(table, Map.fetch!(columns, name))
         end,
         :ok <- rows_fault(schema, n, fn name -> checked_column(schema, name, read) end) do
      if laid_out?(schema, table),
        do: {:ok, table},
        else: packed(schema, n, read)
    end
  end

  # A table column whose type holds every value the schema's does is read only where the
  # schema asks more of it: a category's declared values, an identity's gaps.
  defp checked_column(schema, name, read) do
    {:ok, description} = Schema.fetch(schema, name)

    if description.type in [:text, :category] or Schema.values(schema, name) != nil or
         name in Enum.map(Schema.identity(schema), &Names.name/1),
       do: read.(name),
       else: :unread
  end

  # A conforming table is the output as it is when it is already in its layout: a column a
  # field, named by its string, of its type, in name order (spec/02 §8.2).
  defp laid_out?(%Schema{fields: fields}, table) do
    header = for {name, %{type: type}} <- Enum.sort(fields), do: {name, type}
    Enum.map(Table.names(table), &{&1, Table.column_type(table, &1)}) == header
  end

  # The lowest row index at fault over the columns: `columns` a map, or a function, from a
  # field's string to its values, `nil` for an absent column, `:unread` for one the type
  # already holds.
  defp rows_fault(%Schema{fields: fields} = schema, n, columns) do
    read = if is_map(columns), do: &Map.get(columns, &1), else: columns
    identity = Enum.map(Schema.identity(schema), &Names.name/1)

    faults =
      for {name, _description} <- Enum.sort(fields),
          fault = column_fault(schema, name, name in identity, read.(name), n),
          fault != nil,
          do: fault

    case Enum.min_by(faults, fn {i, rank, name, _reason} -> {i, rank, name} end, fn -> nil end) do
      nil -> :ok
      {i, _rank, name, reason} -> {:error, {i, name, reason}}
    end
  end

  defp column_fault(_schema, name, true, nil, n) when n > 0, do: {0, 0, name, :no_identity}
  defp column_fault(_schema, _name, _identity?, nil, _n), do: nil
  defp column_fault(_schema, _name, false, :unread, _n), do: nil

  # A column's first fault, its field's type and declared values read once: each value
  # held as `value_fault/3` holds a row's.
  defp column_fault(schema, name, identity?, values, _n) do
    {:ok, %{type: type}} = Schema.fetch(schema, name)

    declared =
      case Schema.values(schema, name) do
        nil -> nil
        values -> {MapSet.new(values, &Names.category/1), values}
      end

    scan(values, 0, {name, type, declared, identity?})
  end

  defp scan([], _i, _field), do: nil

  defp scan([nil | rest], i, {name, _type, _declared, identity?} = field),
    do: if(identity?, do: {i, 0, name, :no_identity}, else: scan(rest, i + 1, field))

  defp scan([value | rest], i, {name, type, declared, _identity?} = field) do
    cond do
      not typed?(type, value) -> {i, 1, name, {:type, type}}
      not declared?(declared, value) -> {i, 1, name, :not_in_values}
      true -> scan(rest, i + 1, field)
    end
  end

  # A category value is one of the declared ones by its spelling (`member?/2`): a set
  # lookup, else the comparison `Macaw.Layers.Names.same?/2` makes (`1` and `1.0`).
  defp declared?(nil, _value), do: true

  defp declared?({set, values}, value),
    do: MapSet.member?(set, Names.category(value)) or member?(values, value)

  # The output table of a conforming columnar answer: a column a field, named by its
  # string, of its type, in name order, `nil` where the answer has no column.
  defp packed(%Schema{fields: fields}, n, values) do
    columns =
      for {name, %{type: type}} <- Enum.sort(fields) do
        case values.(name) do
          nil -> {name, type, List.duplicate(nil, n)}
          list -> {name, type, list}
        end
      end

    {:ok, table} = Table.new(columns)
    {:ok, table}
  end

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
    join_answers(answers, Schema.identity(source.schema), source.input)
  end

  # A table's entities (`input: :columns`): each row's identity read from the identity
  # columns alone, as `Schema.identity/2` reads it from a row, and each entity's rows
  # gathered from the table's chunks as a table of their own (`Last.rows_at/2`).
  defp entities(%Table{} = table, schema) do
    fields = Schema.identity(schema)
    names = Table.names(table)

    values =
      Enum.map(fields, fn field ->
        case Enum.find(names, &Names.same?(&1, field)) do
          nil -> List.duplicate(nil, Table.size(table))
          name -> Table.column(table, name)
        end
      end)

    ids =
      case {fields, values} do
        {[_one], [column]} -> column
        _several -> Enum.zip_with(values, &composite_identity(fields, &1))
      end

    {order, groups} =
      ids
      |> Enum.with_index()
      |> Enum.reduce({[], %{}}, fn
        {nil, _i}, acc ->
          acc

        {id, i}, {order, groups} ->
          if Map.has_key?(groups, id),
            do: {order, Map.update!(groups, id, &[i | &1])},
            else: {[id | order], Map.put(groups, id, [i])}
      end)

    for id <- Enum.reverse(order),
        do: {id, Last.rows_at(table, Enum.reverse(groups[id]))}
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

  # `Schema.identity/2`'s composite identity: a map of the fields to their values, `nil`
  # when one is missing.
  defp composite_identity(fields, values) do
    if nil in values,
      do: nil,
      else: fields |> Enum.zip(values) |> Map.new()
  end

  defp join_answers(answers, fields, input) do
    answers
    |> Enum.reduce_while({:ok, []}, fn {identity, answer}, {:ok, acc} ->
      case entity_rows(answer, input) do
        {:ok, rows} -> {:cont, {:ok, acc ++ Enum.map(rows, &{identity, &1})}}
        :error -> {:halt, {:error, :nonconforming, {nil, nil, :not_a_list}}}
      end
    end)
    |> case do
      {:ok, pairs} -> identify(pairs, fields)
      error -> error
    end
  end

  # Under `input: :columns` an entity may answer a table, read as its rows: they are
  # stamped with the entity's identity and joined as any entity's rows are (spec/02 §1.3).
  defp entity_rows(%Table{} = table, :columns), do: Table.rows(table)
  defp entity_rows(row, _input) when is_map(row) and not is_struct(row), do: {:ok, [row]}
  defp entity_rows(rows, _input) when is_list(rows), do: {:ok, rows}
  defp entity_rows(_other, _input), do: :error

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
  The source's map form (spec/02 §1.5), JSON-ready, written by `macaw_layers`' JSON adapter
  (`Macaw.Layers.Form`) under the kernel's tags and the source's own, its schema by
  `Macaw.Data.Schema.to_map/1`: `{:ok, map}`, or every value without a form, by path (a
  window's time not in `Etc/UTC` is `{:type, :term}`). `from_map(map) == {:ok, derived}`.
  """
  @spec to_map(t()) :: {:ok, map()} | {:error, [error(), ...]}
  def to_map(%__MODULE__{} = source), do: Form.to_map(source)

  @doc "The source's JSON form: `to_map/1`, stamped `\"$version\"` and encoded."
  @spec to_json(t()) :: {:ok, String.t()} | {:error, [error(), ...]}
  def to_json(%__MODULE__{} = source), do: Form.to_json(source)

  @doc """
  The derived source a map form holds: through `macaw_layers`' gates
  (`Macaw.Layers.Form.gates/3`: the depth and item limits, the version), read by its tag
  table and keys, making no atom, its schema by `Macaw.Data.Schema.from_map/1`, then
  judged by `new/1`. `limits:` tightens the limits. A derived source holds no URL: one the
  document holds (a `$url` at a window's bound) is `{path, {:url, reason}}`, under the
  kernel's closed policy (`Macaw.Layers.Url.Policy.new!([])`).
  """
  @spec from_map(map(), keyword()) :: {:ok, t()} | {:error, [error(), ...]}
  def from_map(map, opts \\ []) when is_map(map), do: read(map, opts)

  @doc "As `from_map/2`, raising `Macaw.Data.Error` naming every fault."
  @spec from_map!(map(), keyword()) :: t()
  def from_map!(map, opts \\ []) do
    case from_map(map, opts) do
      {:ok, source} ->
        source

      {:error, errors} ->
        raise Macaw.Data.Error,
          reason: errors,
          message:
            "not a derived source:\n" <>
              Enum.map_join(errors, "\n", &("  " <> format_error(&1)))
    end
  end

  @doc """
  The derived source a JSON document holds: as `from_map/2`, its bytes and nesting held to
  the limits before it is decoded.
  """
  @spec from_json(binary(), keyword()) :: {:ok, t()} | {:error, [error(), ...]}
  def from_json(json, opts \\ []) when is_binary(json), do: read(json, opts)

  defp read(input, opts) do
    with {:ok, value} <- Form.read(input, opts),
         {:ok, source} <- new(value),
         do: Form.no_url(source)
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
  defp words({:enum, [:rows, :columns]}), do: "must be :rows or :columns"

  defp words({:per, :ambiguous}),
    do: "is :identity over several inputs: name the input, {:identity, input}"

  defp words({:per, {:unknown_input, name}}), do: "names #{inspect(name)}, which is no input"

  defp words({:per, :no_identity}),
    do: "is per identity, and its identity input's schema declares no identity"

  defp words({:per, {:identity, input, output}}),
    do: "declares identity #{inspect(output)}, which must be its input's, #{inspect(input)}"

  defp words({:per, {:identity_type, field, input, output}}),
    do: "#{inspect(field)} is #{inspect(output)} here and #{inspect(input)} in its input"

  defp words(reason), do: kernel_words(reason)

  # The kernel's own reasons, read by its adapter (an unknown tag or atom, a limit, a newer
  # version, a URL refused), in the kernel's words (`Macaw.Layers.Fault`), which never quote
  # a URL; a reason it does not know either is shown with `inspect/1`.
  defp kernel_words(reason) do
    ": " <> words = Macaw.Layers.Fault.format({[], reason}, root: "")
    words
  end

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
