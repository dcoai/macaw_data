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

      iex> Macaw.Data.Quantity.family(:mass, "kg", :us)
      ["[oz_av]", "[lb_av]"]

      iex> Macaw.Data.Quantity.additivity(:data_rate)
      %{across: true, over_time: false}

      iex> Macaw.Data.Quantity.label(%{unit: "{request}"})
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
  `:currency`, whose code the data must say.
  """
  @spec base_unit(t()) :: Unit.code() | nil
  def base_unit(quantity), do: Facts.fetch!(quantity).base

  @doc """
  How a quantity's values combine (spec/03 §9): `:linear`, `:affine` (a temperature),
  `:logarithmic` (a sound level) or `:cyclic` (an angle).

  ## Examples

      iex> Macaw.Data.Quantity.kind(:angle)
      :cyclic

  """
  @spec kind(t()) :: kind()
  def kind(quantity), do: Facts.fetch!(quantity).kind

  @doc """
  Where a quantity's values physically lie, in its base unit, `{min | nil, max | nil}`
  (spec/03 §9): a **display hint** an axis may anchor at, never validation — a value
  outside them is never refused.

  ## Examples

      iex> Macaw.Data.Quantity.bounds(:duration)
      {0, nil}

  """
  @spec bounds(t()) :: {number() | nil, number() | nil}
  def bounds(quantity), do: Facts.fetch!(quantity).bounds

  @doc """
  A quantity's bounds in a unit of it: the base's, converted. A unit without a factor
  (`Cel`) takes the base's bounds as they are.

  ## Examples

      iex> Macaw.Data.Quantity.bounds(:ratio, "%")
      {0.0, 100.0}

  """
  @spec bounds(t(), Unit.code()) :: {number() | nil, number() | nil}
  def bounds(quantity, unit) do
    {min, max} = bounds(quantity)
    base = base_unit(quantity)

    if base == nil or base == unit or Unit.factor(unit) == nil,
      do: {min, max},
      else: {bound(min, base, unit), bound(max, base, unit)}
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
      %{across: true, over_time: false}

      iex> Macaw.Data.Quantity.additivity(:temperature, :counter)
      %{across: false, over_time: false}

  """
  @spec additivity(t() | nil, metric_kind() | nil) :: %{across: boolean(), over_time: boolean()}
  def additivity(quantity, metric_kind \\ nil) when metric_kind in [nil | @metric_kinds] do
    defaults =
      case quantity do
        nil -> %{across: true, over_time: true}
        quantity -> Map.take(Facts.fetch!(quantity), [:across, :over_time])
      end

    case metric_kind do
      nil -> defaults
      :counter -> %{defaults | over_time: defaults.across}
      _gauge_or_rate -> %{defaults | over_time: false}
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
      ["By", "KiBy", "MiBy", "GiBy", "TiBy"]

      iex> Macaw.Data.Quantity.family(:length, "[ft_i]")
      ["[in_i]", "[ft_i]", "[mi_i]"]

  """
  @spec family(t(), Unit.code() | nil) :: [Unit.code()]
  def family(quantity, unit), do: family(quantity, unit, :as_posted)

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
      ["[oz_av]", "[lb_av]", "[stone_av]"]

      iex> Macaw.Data.Quantity.family(:duration, "ms", :us)
      ["ns", "us", "ms", "s", "min", "h", "d"]

      iex> Macaw.Data.Quantity.family(:pressure, "hPa", :us)
      ["[in_i'Hg]"]

  """
  @spec family(t(), Unit.code() | nil, system()) :: [Unit.code()]
  def family(quantity, nil, system) do
    case base_unit(quantity) do
      nil -> []
      base -> family(quantity, base, system)
    end
  end

  def family(quantity, unit, system) when system in @systems do
    families = convention(quantity, unit)

    case List.keyfind(families, system, 0) do
      {^system, ladder} -> ladder
      nil -> own_family(families, unit)
    end
  end

  @doc """
  The quantity a code's dimension implies, or `nil` when none of the list has it. A
  dimensionless code holding `%` is a `:ratio`, any other a `:count`, and a code of one
  currency alone (`{iso4217:USD}`) a `:currency`.

  ## Examples

      iex> Macaw.Data.Quantity.of_unit("kW.h")
      :energy

      iex> Macaw.Data.Quantity.of_unit("{request}")
      :count

  """
  @spec of_unit(Unit.code()) :: t() | nil
  def of_unit(unit) do
    case Unit.dimension(unit) do
      dims when dims == %{} ->
        if atom?(unit, "%"), do: :ratio, else: :count

      dims ->
        if Unit.currency(unit),
          do: :currency,
          else: Enum.find(@all -- @dimensionless, &(Unit.dimension(base_unit(&1)) == dims))
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
        {unit, nil} -> {:ok, %{unit: unit, quantity: of_unit(unit)}}
        {nil, quantity} -> {:ok, %{unit: base_unit(quantity), quantity: quantity}}
        {unit, quantity} -> pair(unit, quantity)
      end
    end
  end

  @doc """
  The label rule (spec/03 §14): **the unit, else the quantity, else nothing** — the
  unit's symbol with its annotations written when it is not empty, else the quantity's
  name with spaces for underscores, else `nil`. Raises `ArgumentError` for a measure
  `resolve/1` refuses.

  ## Examples

      iex> Macaw.Data.Quantity.label(%{unit: "ms"})
      "ms"

      iex> Macaw.Data.Quantity.label(%{quantity: :count})
      "count"

      iex> Macaw.Data.Quantity.label(%{})
      nil

  """
  @spec label(measure()) :: String.t() | nil
  def label(measure) do
    %{unit: unit, quantity: quantity} = resolve!(measure)
    symbol = if unit, do: Unit.symbol(unit, annotations: true), else: ""

    cond do
      symbol != "" -> symbol
      quantity -> quantity |> Atom.to_string() |> String.replace("_", " ")
      true -> nil
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
        quantity when quantity in @dimensionless -> Unit.dimension(unit) == %{}
        quantity -> Unit.dimension(unit) == Unit.dimension(base_unit(quantity))
      end

    if fits?,
      do: {:ok, %{unit: unit, quantity: quantity}},
      else: {:error, {:quantity, quantity, unit}}
  end

  defp resolve!(measure) do
    case resolve(measure) do
      {:ok, resolved} ->
        resolved

      {:error, reason} ->
        raise ArgumentError, "not a measure: #{inspect(measure)} (#{inspect(reason)})"
    end
  end

  # -- scaling --------------------------------------------------------------------------

  # The families of the unit's convention (spec/03 §11, D-158): the first convention
  # claiming its exact code, else the first claiming a code of its shape, else the first.
  # Shape alone cannot choose, since `hPa` and `kPa` are one shape; a quantity of one
  # convention has no choice to make.
  defp convention(quantity, unit) do
    case Facts.fetch!(quantity).conventions do
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

  defp bound(nil, _base, _unit), do: nil
  defp bound(value, base, unit), do: Unit.convert(value, base, unit)

  defp components(unit) do
    {:ok, components} = Unit.parse(unit)
    components
  end
end
