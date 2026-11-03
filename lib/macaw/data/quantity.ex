defmodule Macaw.Data.Quantity do
  @moduledoc """
  A fixed list of quantities, each with its facts: a base unit, a kind, bounds, additivity,
  and display families by unit system (spec/03 §8–§13).

  A quantity is what a unit measures. A unit (a UCUM code, `Macaw.Data.Unit`) and a
  quantity together are a *measure*, `%{unit: code, quantity: quantity}`, the two facts a
  field description carries. **They are facts about the data, not knobs**: a measure does
  not change a value, it says what the value already is, so a display can choose how to
  show it.

  The list is fixed and grows by proposal: `duration`, `information`, `data_rate`,
  `frequency`, `ratio`, `count`, `temperature`, `length`, `speed`, `power`, `energy`,
  `pressure`, `area`, `volume`, `mass`, `pace`, `angle`, `currency`,
  `electric_potential`, `electric_current`, `electric_charge`, `illuminance`,
  `sound_level`, `mass_concentration` and `amount_concentration`. spec/03 §8–§13 tables each
  one's facts and families.

  - **Kind** is `:linear`, `:affine` (a temperature), `:logarithmic` (a sound level) or
    `:cyclic` (an angle, whose mean is circular).
  - **Bounds** are a display hint, never validation: a difference is legitimately
    negative, so a value outside them is never refused.
  - **Additivity** depends on the aggregation: `additivity/2` refines the quantity's
    defaults across series and over time by the field's metric kind (`:gauge`,
    `:counter`, `:rate`).
  - **Unit systems** are `:metric`, `:us`, `:uk` and `:as_posted`; a system picks the
    family a value is shown in and never touches the data.

  Information is **decimal by default**: UCUM's `kBy` and `Telemetry.Metrics`'
  `:kilobyte` are 1,000 bytes, and a unit written with a binary prefix (`MiBy`) or in
  `bit` belongs to its own family. The data picks it; no setting does.

  How a value is drawn in its family (the display unit, tick formats, a value's label in
  a locale) is the drawing library's: visualize's `Visualize.Quantity` keeps it, over this
  vocabulary.

  The vocabulary half of visualize's `Visualize.Quantity`.

  ## Examples

      iex> Macaw.Data.Quantity.family!(:mass, "kg", :us)
      ["[oz_av]", "[lb_av]"]

      iex> Macaw.Data.Quantity.additivity!(:data_rate)
      %{across: true, over_time: false}

      iex> Macaw.Data.Quantity.label!(%{unit: "{request}"})
      "request"

  """

  alias Macaw.Data.Unit
  alias Macaw.Data.Quantity.Facts

  @typedoc "One of the fixed list of quantities."
  @type t ::
          :duration
          | :information
          | :data_rate
          | :frequency
          | :ratio
          | :count
          | :temperature
          | :length
          | :speed
          | :power
          | :energy
          | :pressure
          | :area
          | :volume
          | :mass
          | :pace
          | :angle
          | :currency
          | :electric_potential
          | :electric_current
          | :electric_charge
          | :illuminance
          | :sound_level
          | :mass_concentration
          | :amount_concentration

  @typedoc "How a quantity's values combine (spec/03 §9)."
  @type kind :: :linear | :affine | :logarithmic | :cyclic

  @typedoc "A unit system: a display preference, never applied to the data."
  @type system :: :metric | :us | :uk | :as_posted

  @typedoc "How a field's values were measured, which refines its quantity's additivity."
  @type metric_kind :: :gauge | :counter | :rate

  @typedoc "A unit and a quantity, either or both; the two facts a field description carries."
  @type measure :: %{optional(:unit) => Unit.code() | nil, optional(:quantity) => t() | nil}

  @typedoc "Why a measure does not resolve."
  @type reason ::
          {:unit, Unit.code(), Unit.reason()}
          | {:quantity, t(), Unit.code()}
          | {:unknown_quantity, term()}

  @all Facts.all()
  @systems [:metric, :us, :uk, :as_posted]
  @metric_kinds [:gauge, :counter, :rate]

  @dimensionless [:ratio, :count, :currency]

  @doc "The fixed list of quantities (spec/03 §8)."
  @spec all() :: [t(), ...]
  def all, do: @all

  @doc "The unit systems a display may prefer (spec/03 §12), `:as_posted` the default."
  @spec systems() :: [system(), ...]
  def systems, do: @systems

  @doc """
  A quantity's base unit, the unit its values are in when no unit is given; `nil` for a
  `:currency`, whose code the data must say. `{:ok, unit}`, or `{:error,
  {:unknown_quantity, quantity}}` for a quantity not in `all/0` (spec/00 §5);
  `base_unit!/1` answers the unit or raises.
  """
  @spec base_unit(t()) :: {:ok, Unit.code() | nil} | {:error, reason()}
  def base_unit(quantity), do: with({:ok, facts} <- facts(quantity), do: {:ok, facts.base})

  @doc "As `base_unit/1`, the unit alone, raising `Macaw.Data.Error` naming the quantity."
  @spec base_unit!(t()) :: Unit.code() | nil
  def base_unit!(quantity) do
    case base_unit(quantity) do
      {:ok, value} -> value
      {:error, reason} -> raise error(reason)
    end
  end

  @doc """
  How a quantity's values combine (spec/03 §9): `:linear`, `:affine` (a temperature),
  `:logarithmic` (a sound level) or `:cyclic` (an angle).

  ## Examples

      iex> Macaw.Data.Quantity.kind(:angle)
      {:ok, :cyclic}

      iex> Macaw.Data.Quantity.kind(:vibes)
      {:error, {:unknown_quantity, :vibes}}

  `{:error, {:unknown_quantity, quantity}}` for a quantity not in `all/0`; `kind!/1`
  answers the kind or raises.
  """
  @spec kind(t()) :: {:ok, kind()} | {:error, reason()}
  def kind(quantity), do: with({:ok, facts} <- facts(quantity), do: {:ok, facts.kind})

  @doc "As `kind/1`, the kind alone, raising `Macaw.Data.Error` naming the quantity."
  @spec kind!(t()) :: kind()
  def kind!(quantity) do
    case kind(quantity) do
      {:ok, value} -> value
      {:error, reason} -> raise error(reason)
    end
  end

  @doc """
  Where a quantity's values physically lie, in its base unit, `{min | nil, max | nil}`
  (spec/03 §9): a **display hint** an axis may anchor at, never validation — a value
  outside them is never refused.

  ## Examples

      iex> Macaw.Data.Quantity.bounds(:duration)
      {:ok, {0, nil}}

  `{:error, {:unknown_quantity, quantity}}` for a quantity not in `all/0`; `bounds!/1`
  answers the bounds or raises.
  """
  @spec bounds(t()) :: {:ok, {number() | nil, number() | nil}} | {:error, reason()}
  def bounds(quantity), do: with({:ok, facts} <- facts(quantity), do: {:ok, facts.bounds})

  @doc "As `bounds/1`, the bounds alone, raising `Macaw.Data.Error` naming the quantity."
  @spec bounds!(t()) :: {number() | nil, number() | nil}
  def bounds!(quantity) do
    case bounds(quantity) do
      {:ok, value} -> value
      {:error, reason} -> raise error(reason)
    end
  end

  @doc """
  A quantity's bounds in a unit of it: the base's, converted, as `{:ok, bounds}`. A unit
  without a factor (`Cel`) takes the base's bounds as they are. A unit that is no code, or
  not of the quantity's dimension, is `Macaw.Data.Unit.convert/3`'s `{:error, reason}`
  (spec/00 §5); `bounds!/2` answers the bounds or raises.

  ## Examples

      iex> Macaw.Data.Quantity.bounds(:ratio, "%")
      {:ok, {0.0, 100.0}}

      iex> Macaw.Data.Quantity.bounds(:ratio, "s")
      {:error, {:dimension, "1", "s"}}

  """
  @spec bounds(t(), Unit.code()) :: {:ok, {number() | nil, number() | nil}} | {:error, term()}
  def bounds(quantity, unit) do
    with {:ok, %{bounds: {min, max}, base: base}} <- facts(quantity),
         {:ok, factor} <- if(base == nil or base == unit, do: {:ok, nil}, else: Unit.factor(unit)) do
      if base == nil or base == unit or factor == nil do
        {:ok, {min, max}}
      else
        with {:ok, low} <- bound(min, base, unit),
             {:ok, high} <- bound(max, base, unit),
             do: {:ok, {low, high}}
      end
    end
  end

  @doc "As `bounds/2`, the bounds alone, raising `Macaw.Data.Error` in `Macaw.Data.Unit.format_error/1`'s words."
  @spec bounds!(t(), Unit.code()) :: {number() | nil, number() | nil}
  def bounds!(quantity, unit) do
    case bounds(quantity, unit) do
      {:ok, value} -> value
      {:error, reason} -> raise error(reason)
    end
  end

  @doc """
  Whether a sum of the quantity's values means anything (spec/03 §10, D-155):
  `%{across: boolean, over_time: boolean}` — summing several series at one instant, and
  summing one series over time. The quantity's physical defaults are refined by the
  field's metric kind: a `:gauge` and a `:rate` never add over time, and a `:counter`'s
  increments add over time when the quantity adds across. No quantity (a plain number)
  defaults to both.

  ## Examples

      iex> Macaw.Data.Quantity.additivity(:count, :gauge)
      {:ok, %{across: true, over_time: false}}

      iex> Macaw.Data.Quantity.additivity!(:temperature, :counter)
      %{across: false, over_time: false}

  `{:error, {:unknown_quantity, quantity}}` for a quantity not in `all/0`, and
  `{:error, {:unknown_metric_kind, kind}}` for a metric kind not `:gauge`, `:counter` or
  `:rate`; `additivity!/2` answers the map or raises.

  """
  @spec additivity(t() | nil, metric_kind() | nil) ::
          {:ok, %{across: boolean(), over_time: boolean()}} | {:error, reason()}
  def additivity(quantity, metric_kind \\ nil)

  def additivity(quantity, metric_kind) when metric_kind in [nil | @metric_kinds] do
    defaults =
      case quantity do
        nil ->
          {:ok, %{across: true, over_time: true}}

        quantity ->
          with {:ok, facts} <- facts(quantity), do: {:ok, Map.take(facts, [:across, :over_time])}
      end

    with {:ok, defaults} <- defaults do
      case metric_kind do
        nil -> {:ok, defaults}
        :counter -> {:ok, %{defaults | over_time: defaults.across}}
        _gauge_or_rate -> {:ok, %{defaults | over_time: false}}
      end
    end
  end

  def additivity(_quantity, metric_kind), do: {:error, {:unknown_metric_kind, metric_kind}}

  @doc "As `additivity/2`, the map alone, raising `Macaw.Data.Error` naming the reason."
  @spec additivity!(t() | nil, metric_kind() | nil) :: %{across: boolean(), over_time: boolean()}
  def additivity!(quantity, metric_kind \\ nil) do
    case additivity(quantity, metric_kind) do
      {:ok, value} -> value
      {:error, reason} -> raise error(reason)
    end
  end

  @doc """
  The display family a unit of the quantity belongs to, smallest first; `[]` for a unit
  of no family's shape (spec/03 §11). Within the unit's convention (`family/3`), a unit
  belongs to the first family holding a member of its shape — its atoms and exponents,
  prefixes aside and a binary prefix kept apart — so the unit picks among a quantity's
  families: bits, binary prefixes, hertz, watt-hours, US lengths. No unit means the base
  unit.

  ## Examples

      iex> Macaw.Data.Quantity.family(:information, "MiBy")
      {:ok, ["By", "KiBy", "MiBy", "GiBy", "TiBy"]}

      iex> Macaw.Data.Quantity.family!(:length, "[ft_i]")
      ["[in_i]", "[ft_i]", "[mi_i]"]

  `{:error, reason}` for a quantity not in `all/0` (`{:unknown_quantity, quantity}`) or a
  unit that is no code (`Macaw.Data.Unit.parse/1`'s reason); `family!/2` raises it.
  """
  @spec family(t(), Unit.code() | nil) :: {:ok, [Unit.code()]} | {:error, term()}
  def family(quantity, unit), do: family(quantity, unit, :as_posted)

  @doc "As `family/2`, the family alone, raising `Macaw.Data.Error` naming the reason."
  @spec family!(t(), Unit.code() | nil) :: [Unit.code()]
  def family!(quantity, unit) do
    case family(quantity, unit) do
      {:ok, value} -> value
      {:error, reason} -> raise error(reason)
    end
  end

  @doc """
  The display family a system shows a unit of the quantity in (spec/03 §11, D-158): the
  family the unit's convention names for `:metric`, `:us` or `:uk` when it names one,
  else the unit's own (`family/2`), which is what `:as_posted` always is.

  A quantity read in several conventions — a pressure is gauge, barometric or clinical —
  picks the unit's by its exact code first, then by its shape, else the first, so a
  system chooses within a convention and never across: a barometric `hPa` is shown in
  inches of mercury under `:us`, and a blood pressure in `mm[Hg]` stays in it under every
  system.

  ## Examples

      iex> Macaw.Data.Quantity.family(:mass, "kg", :uk)
      {:ok, ["[oz_av]", "[lb_av]", "[stone_av]"]}

      iex> Macaw.Data.Quantity.family!(:duration, "ms", :us)
      ["ns", "us", "ms", "s", "min", "h", "d"]

      iex> Macaw.Data.Quantity.family!(:pressure, "hPa", :us)
      ["[in_i'Hg]"]

      iex> Macaw.Data.Quantity.family(:mass, "kg", :imperial)
      {:error, {:unknown_system, :imperial}}

  A quantity, a unit or a system none of `systems/0` is `{:error, reason}`, as `family/2`
  answers, `{:unknown_system, system}` for the system; `family!/3` raises it.

  """
  @spec family(t(), Unit.code() | nil, system()) :: {:ok, [Unit.code()]} | {:error, term()}
  def family(_quantity, _unit, system) when system not in @systems,
    do: {:error, {:unknown_system, system}}

  def family(quantity, nil, system) do
    case base_unit(quantity) do
      {:ok, nil} -> {:ok, []}
      {:ok, base} -> family(quantity, base, system)
      {:error, _reason} = error -> error
    end
  end

  def family(quantity, unit, system) do
    with {:ok, facts} <- facts(quantity),
         {:ok, _components} <-
           if(is_binary(unit), do: Unit.parse(unit), else: {:error, {:syntax, inspect(unit)}}) do
      families = convention(facts, unit)

      case List.keyfind(families, system, 0) do
        {^system, ladder} -> {:ok, ladder}
        nil -> {:ok, own_family(families, unit)}
      end
    end
  end

  @doc "As `family/3`, the family alone, raising `Macaw.Data.Error` naming the reason."
  @spec family!(t(), Unit.code() | nil, system()) :: [Unit.code()]
  def family!(quantity, unit, system) do
    case family(quantity, unit, system) do
      {:ok, value} -> value
      {:error, reason} -> raise error(reason)
    end
  end

  # A quantity's facts, or the reason it has none (spec/03 §8).
  defp facts(quantity) when quantity in @all, do: {:ok, Facts.fetch!(quantity)}
  defp facts(quantity), do: {:error, {:unknown_quantity, quantity}}

  # What the bang twins raise: their twin's reason, and its words (spec/00 §5).
  defp error(reason), do: Macaw.Data.Error.exception(reason: reason, message: words(reason))

  defp words({:unknown_quantity, quantity}),
    do: "#{inspect(quantity)} is not a quantity of Macaw.Data.Quantity.all/0"

  defp words({:unknown_system, system}),
    do: "#{inspect(system)} is not a unit system of Macaw.Data.Quantity.systems/0"

  defp words({:unknown_metric_kind, kind}),
    do: "#{inspect(kind)} is not a metric kind: :gauge, :counter or :rate"

  defp words(reason), do: Unit.format_error(reason)

  @doc """
  The quantity a code's dimension implies, or `nil` when none of the list has it. A
  dimensionless code holding `%` is a `:ratio`, any other a `:count`, and a code of one
  currency alone (`{iso4217:USD}`) a `:currency`.

  ## Examples

      iex> Macaw.Data.Quantity.of_unit("kW.h")
      {:ok, :energy}

      iex> Macaw.Data.Quantity.of_unit!("{request}")
      :count

  """
  @spec of_unit(Unit.code()) :: {:ok, t() | nil} | {:error, term()}
  def of_unit(unit) do
    case Unit.dimension(unit) do
      {:ok, dims} when dims == %{} ->
        {:ok, if(atom?(unit, "%"), do: :ratio, else: :count)}

      {:ok, dims} ->
        if Unit.currency(unit),
          do: {:ok, :currency},
          else:
            {:ok, Enum.find(@all -- @dimensionless, &(Unit.dimension!(base_unit!(&1)) == dims))}

      {:error, _reason} = error ->
        error
    end
  end

  @doc "As `of_unit/1`, the quantity alone, raising `Macaw.Data.Error` in `Macaw.Data.Unit.format_error/1`'s words."
  @spec of_unit!(Unit.code()) :: t() | nil
  def of_unit!(unit) do
    case of_unit(unit) do
      {:ok, quantity} ->
        quantity

      {:error, reason} ->
        raise Macaw.Data.Error, reason: reason, message: Unit.format_error(reason)
    end
  end

  @doc """
  A measure completed and checked (spec/03 §13): a unit alone implies its quantity, a
  quantity alone means its base unit, and a unit whose dimension is not its quantity's is
  refused. A `:ratio` or a `:count` takes any dimensionless unit, and a `:currency` a
  code of one currency alone.

  ## Examples

      iex> Macaw.Data.Quantity.resolve(%{quantity: :duration})
      {:ok, %{unit: "s", quantity: :duration}}

      iex> Macaw.Data.Quantity.resolve(%{unit: "By", quantity: :duration})
      {:error, {:quantity, :duration, "By"}}

  """
  @spec resolve(measure()) ::
          {:ok, %{unit: Unit.code() | nil, quantity: t() | nil}} | {:error, reason()}
  def resolve(measure) when is_map(measure) do
    unit = Map.get(measure, :unit)
    quantity = Map.get(measure, :quantity)

    with :ok <- check_unit(unit),
         :ok <- check_quantity(quantity) do
      case {unit, quantity} do
        {nil, nil} -> {:ok, %{unit: nil, quantity: nil}}
        {unit, nil} -> {:ok, %{unit: unit, quantity: of_unit!(unit)}}
        {nil, quantity} -> {:ok, %{unit: base_unit!(quantity), quantity: quantity}}
        {unit, quantity} -> pair(unit, quantity)
      end
    end
  end

  @doc """
  The label rule (spec/03 §14): **the unit, else the quantity, else nothing** — the
  unit's symbol with its annotations written when it is not empty, else the quantity's
  name with spaces for underscores, else `nil`, as `{:ok, label}`. A measure `resolve/1`
  refuses is its `{:error, reason}` (spec/00 §5); `label!/1` answers the label or raises.

  ## Examples

      iex> Macaw.Data.Quantity.label(%{unit: "ms"})
      {:ok, "ms"}

      iex> Macaw.Data.Quantity.label!(%{quantity: :count})
      "count"

      iex> Macaw.Data.Quantity.label!(%{})
      nil

      iex> Macaw.Data.Quantity.label(%{unit: "By", quantity: :duration})
      {:error, {:quantity, :duration, "By"}}

  """
  @spec label(measure()) :: {:ok, String.t() | nil} | {:error, reason()}
  def label(measure) when is_map(measure) do
    with {:ok, %{unit: unit, quantity: quantity}} <- resolve(measure) do
      symbol = if unit, do: Unit.symbol!(unit, annotations: true), else: ""

      cond do
        symbol != "" -> {:ok, symbol}
        quantity -> {:ok, quantity |> Atom.to_string() |> String.replace("_", " ")}
        true -> {:ok, nil}
      end
    end
  end

  @doc "As `label/1`, the label alone, raising `Macaw.Data.Error` naming the reason."
  @spec label!(measure()) :: String.t() | nil
  def label!(measure) do
    case label(measure) do
      {:ok, label} ->
        label

      {:error, reason} ->
        raise Macaw.Data.Error, reason: reason, message: "not a measure: " <> words(reason)
    end
  end

  # -- resolving ------------------------------------------------------------------------

  defp check_unit(nil), do: :ok

  defp check_unit(unit) when is_binary(unit) do
    case Unit.parse(unit) do
      {:ok, _components} -> :ok
      {:error, reason} -> {:error, {:unit, unit, reason}}
    end
  end

  defp check_unit(unit), do: {:error, {:unit, unit, {:syntax, inspect(unit)}}}

  defp check_quantity(nil), do: :ok
  defp check_quantity(quantity) when quantity in @all, do: :ok
  defp check_quantity(quantity), do: {:error, {:unknown_quantity, quantity}}

  defp pair(unit, quantity) do
    fits? =
      case quantity do
        :currency -> Unit.currency(unit) != nil
        quantity when quantity in @dimensionless -> Unit.dimension!(unit) == %{}
        quantity -> Unit.dimension!(unit) == Unit.dimension!(base_unit!(quantity))
      end

    if fits?,
      do: {:ok, %{unit: unit, quantity: quantity}},
      else: {:error, {:quantity, quantity, unit}}
  end

  # -- scaling --------------------------------------------------------------------------

  # The families of the unit's convention (spec/03 §11, D-158): the first convention
  # claiming its exact code, else the first claiming a code of its shape, else the first.
  # Shape alone cannot choose, since `hPa` and `kPa` are one shape; a quantity of one
  # convention has no choice to make.
  defp convention(facts, unit) do
    case facts.conventions do
      [{_name, only}] ->
        Keyword.fetch!(only, :families)

      [{_name, first} | _] = conventions ->
        claims = for {_name, convention} <- conventions, do: {claimed(convention), convention}
        shape = shape(unit)

        {_claimed, convention} =
          Enum.find(claims, &(unit in elem(&1, 0))) ||
            Enum.find(claims, {[], first}, fn {claimed, _} ->
              Enum.any?(claimed, &(shape(&1) == shape))
            end)

        Keyword.fetch!(convention, :families)
    end
  end

  # Every code a convention claims: its ladders' members and the codes it holds without
  # a ladder for them.
  defp claimed(convention) do
    Enum.flat_map(Keyword.fetch!(convention, :families), &elem(&1, 1)) ++
      Keyword.fetch!(convention, :also)
  end

  # The first family holding a member of the unit's shape, else none.
  defp own_family(families, unit) do
    shape = shape(unit)

    Enum.find_value(families, [], fn {_system, ladder} ->
      if Enum.any?(ladder, &(shape(&1) == shape)), do: ladder
    end)
  end

  # A unit's atoms and exponents, prefixes aside but a binary one kept apart, annotations
  # and integer factors aside: `kBy` and `By` are one shape, `MiBy` another.
  defp shape(unit) do
    unit
    |> components()
    |> Enum.filter(& &1.atom)
    |> Enum.map(&{&1.atom, &1.exponent, &1.prefix in ["Ki", "Mi", "Gi", "Ti"]})
    |> Enum.sort()
  end

  defp atom?(unit, atom), do: unit |> components() |> Enum.any?(&(&1.atom == atom))

  defp bound(nil, _base, _unit), do: {:ok, nil}
  defp bound(value, base, unit), do: Unit.convert(value, base, unit)

  defp components(unit) do
    {:ok, components} = Unit.parse(unit)
    components
  end
end
