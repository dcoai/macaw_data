defmodule Macaw.Data.Operations.Option do
  @moduledoc """
  An operation's option declaration and the check of a value against it (spec/04 §1.3).

  An option is `%Option{type: type, default: value, required: boolean, frame: :width | nil,
  doc: text}`. A required option has no default; an optional one's `default` is filled in
  when a node omits it. `frame: :width` makes it frame-bound: a node may write `"plot"`,
  the plot's width in whole pixels, resolved before the step runs (spec/04 §3.2).

  | Type | Holds |
  |---|---|
  | `:field` | a column name, a string or an atom |
  | `{:list, type}` | a list of `type` |
  | `{:pair, type}` | a two-element list of `type` |
  | `:name` | the name of a column a step adds, a string or an atom |
  | `:number`, `{:number, low, high}` | any number; one in `low..high`, both inclusive |
  | `:positive` | a number above zero |
  | `:integer`, `{:integer, min}` | any integer; one at least `min` |
  | `:power_of_two` | a positive integer power of two |
  | `:boolean` | `true` or `false` |
  | `{:enum, atoms}` | one of `atoms`, written as the atom or its string |
  | `{:keys, type}` | a fixed order: `{:keys, list}`, or a map whose one key is `keys` |
  | `{:one_of, types}` | a value of the first of `types` that holds it |
  | `:duration` | `[n, unit]`, `unit` one of `units/0` by spelling |
  | `:aggregate` | the name of an aggregate in the registry, checked to its module |
  | `:term` | any value |

  No atom is ever made: an enum value or a unit is matched against the declaration's own
  atoms by their strings.
  """

  alias Macaw.Data.Operations.Registry

  @enforce_keys [:type]
  defstruct [:type, default: nil, required: false, frame: nil, doc: ""]

  @type type ::
          :field
          | :name
          | :number
          | {:number, number(), number()}
          | :positive
          | :integer
          | {:integer, integer()}
          | :power_of_two
          | :boolean
          | {:enum, [atom()]}
          | {:keys, type()}
          | {:list, type()}
          | {:pair, type()}
          | {:one_of, [type()]}
          | :duration
          | :aggregate
          | :term

  @type t :: %__MODULE__{
          type: type(),
          default: term(),
          required: boolean(),
          frame: :width | nil,
          doc: String.t()
        }

  # A duration's units, each the seconds it names: an extent of time, never a calendar
  # walk, so a :day is 86,400 seconds and a :year 365 of those (spec/04 §4.3).
  @units [second: 1, minute: 60, hour: 3_600, day: 86_400, week: 604_800, year: 31_536_000]

  @doc "A duration's units and the seconds each names, in order."
  @spec units() :: [{atom(), pos_integer()}]
  def units, do: @units

  @doc """
  The value as a step is given it, or `{:error, reason}`: `{:type, type}` for a value the
  type does not hold, `{:unknown, :aggregate, name}` for an aggregate the registry lacks.

      iex> alias Macaw.Data.Operations.Option
      iex> Option.check(:term, {:enum, [:ascending, :descending]}, "descending")
      {:ok, :descending}
      iex> Option.check(:term, {:integer, 0}, -1)
      {:error, {:type, {:integer, 0}}}
  """
  @spec check(Registry.t() | term(), t() | type(), term()) :: {:ok, term()} | {:error, term()}
  def check(registry, %__MODULE__{type: type}, value), do: check(registry, type, value)

  def check(_registry, :term, value), do: {:ok, value}

  def check(_registry, type, value) when type in [:field, :name] do
    if (is_atom(value) and value not in [nil, true, false]) or is_binary(value),
      do: {:ok, value},
      else: refuse(type)
  end

  def check(_registry, :number, value) when is_number(value), do: {:ok, value}

  def check(_registry, {:number, low, high} = type, value) do
    if is_number(value) and value >= low and value <= high, do: {:ok, value}, else: refuse(type)
  end

  def check(_registry, :positive, value) when is_number(value) and value > 0, do: {:ok, value}
  def check(_registry, :integer, value) when is_integer(value), do: {:ok, value}

  def check(_registry, {:integer, min} = type, value) do
    if is_integer(value) and value >= min, do: {:ok, value}, else: refuse(type)
  end

  def check(_registry, :power_of_two, value)
      when is_integer(value) and value > 0 and Bitwise.band(value, value - 1) == 0,
      do: {:ok, value}

  def check(_registry, :boolean, value) when is_boolean(value), do: {:ok, value}

  def check(_registry, {:enum, atoms} = type, value) do
    case spelled(atoms, value) do
      nil -> refuse(type)
      atom -> {:ok, atom}
    end
  end

  def check(registry, {:keys, inner} = type, value) do
    listed =
      case value do
        {:keys, list} -> {:ok, list}
        %{keys: list} when map_size(value) == 1 -> {:ok, list}
        %{"keys" => list} when map_size(value) == 1 -> {:ok, list}
        _other -> :error
      end

    with {:ok, list} <- listed,
         {:ok, list} <- check(registry, inner, list) do
      {:ok, {:keys, list}}
    else
      _ -> refuse(type)
    end
  end

  def check(registry, {:list, inner} = type, value) when is_list(value) do
    checked = Enum.map(value, &check(registry, inner, &1))

    if Enum.all?(checked, &match?({:ok, _}, &1)),
      do: {:ok, Enum.map(checked, &elem(&1, 1))},
      else: refuse(type)
  end

  def check(registry, {:pair, inner} = type, [_, _] = value) do
    case check(registry, {:list, inner}, value) do
      {:ok, pair} -> {:ok, pair}
      {:error, _} -> refuse(type)
    end
  end

  def check(registry, {:one_of, types} = type, value) do
    Enum.find_value(types, refuse(type), fn inner ->
      case check(registry, inner, value) do
        {:ok, checked} -> {:ok, checked}
        {:error, _} -> nil
      end
    end)
  end

  def check(_registry, :duration, [n, unit]) when is_number(n) do
    case spelled(Keyword.keys(@units), unit) do
      nil -> refuse(:duration)
      atom -> {:ok, [n, atom]}
    end
  end

  def check(%Registry{} = registry, :aggregate, name) when is_binary(name) or is_atom(name) do
    spelling = if is_atom(name), do: Atom.to_string(name), else: name

    case Registry.aggregate(registry, spelling) do
      {:ok, module} -> {:ok, module}
      :error -> {:error, {:unknown, :aggregate, spelling}}
    end
  end

  def check(_registry, type, _value), do: refuse(type)

  defp refuse(type), do: {:error, {:type, type}}

  # The atom of `atoms` that `value` spells, or nil: the atom itself, or its string.
  defp spelled(atoms, value) when is_atom(value), do: if(value in atoms, do: value)

  defp spelled(atoms, value) when is_binary(value),
    do: Enum.find(atoms, &(Atom.to_string(&1) == value))

  defp spelled(_atoms, _value), do: nil
end
