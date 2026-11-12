defmodule Macaw.Data.Format.Measure do
  @moduledoc """
  A field's default format (spec/05 §6): how a measure's values are written with no
  format given, built by `Macaw.Data.Format.for_measure/2` and written by
  `Macaw.Data.Format.measure/2`.

  It is data: the resolved measure, the way its values are written (`kind`), and the
  d3 formats it writes their numbers with, each a `Macaw.Data.Format`.

      iex> {:ok, bytes} = Macaw.Data.Format.for_measure(%{unit: "By"})
      iex> {bytes.kind, Macaw.Data.Format.measure(bytes, 1_500_000)}
      {:quantity, "1.50 MB"}

  """

  alias Macaw.Data.{Format, Quantity, Unit}
  alias Macaw.Data.Format.{Locale, Number}

  @enforce_keys [:measure, :kind]
  defstruct measure: nil,
            kind: nil,
            precision: 2,
            system: :as_posted,
            style: :compound,
            notation: :auto,
            format: nil,
            fixed: nil,
            locale: %Locale{},
            currency: nil

  @typedoc "How a measure's values are written (spec/05 §6's table)."
  @type kind :: :duration | :currency | :ratio | :count | :quantity | :unit | :number

  @typedoc "A number's notation with no measure; `:fixed` is a precision given alone."
  @type notation :: :auto | :plain | :grouped | :si | {:si, 3..24} | :fixed

  @type t :: %__MODULE__{
          measure: %{unit: Unit.code() | nil, quantity: Quantity.t() | nil},
          kind: kind(),
          precision: 0..20,
          system: :metric | :us | :uk | :as_posted,
          style: :compound | :magnitude,
          notation: notation(),
          format: Format.t() | nil,
          fixed: Format.t(),
          locale: Locale.t(),
          currency: %{code: String.t(), symbol: String.t() | nil, amount: Format.t()} | nil
        }

  @prefixes [{24, "Y"}, {21, "Z"}, {18, "E"}, {15, "P"}, {12, "T"}, {9, "G"}, {6, "M"}, {3, "k"}]
  @notations [:auto, :plain, :grouped, :si] ++ for({e, _symbol} <- @prefixes, do: {:si, e})
  @defaults [precision: nil, system: :as_posted, style: :compound, notation: :auto] ++
              [domain: nil, locale: nil, format: nil]

  # -- building ------------------------------------------------------------------------

  @doc false
  @spec build(term(), term()) :: {:ok, t()} | {:error, [Format.fault(), ...]}
  def build(measure, opts) do
    {measure, measure_faults} = resolve(measure)

    case Macaw.Data.Options.known(opts, @defaults) do
      {:ok, opts} ->
        faults =
          measure_faults ++ Enum.flat_map(@defaults, fn {key, _} -> fault(key, opts[key]) end)

        case faults do
          [] -> {:ok, measure_format(measure, opts)}
          faults -> {:error, faults}
        end

      {:error, faults} ->
        {:error, measure_faults ++ faults}
    end
  end

  defp resolve(measure) when is_map(measure) and not is_struct(measure) do
    case Quantity.resolve(measure) do
      {:ok, resolved} -> {resolved, []}
      {:error, reason} -> {nil, [{[:measure], reason}]}
    end
  end

  defp resolve(_measure), do: {nil, [{[:measure], {:type, :measure}}]}

  defp fault(:precision, nil), do: []
  defp fault(:precision, p) when is_integer(p) and p >= 0 and p <= 20, do: []
  defp fault(:precision, _p), do: [{[:precision], {:type, :precision}}]

  defp fault(:system, system) do
    if system in Quantity.systems(), do: [], else: [{[:system], {:unknown_system, system}}]
  end

  defp fault(:style, style) when style in [:compound, :magnitude], do: []
  defp fault(:style, _style), do: [{[:style], {:enum, [:compound, :magnitude]}}]
  defp fault(:notation, notation) when notation in @notations, do: []
  defp fault(:notation, _notation), do: [{[:notation], {:enum, @notations}}]
  defp fault(:domain, nil), do: []

  defp fault(:domain, domain),
    do: if(Macaw.Data.Lists.proper?(domain), do: [], else: [{[:domain], {:type, :domain}}])

  defp fault(:locale, nil), do: []
  defp fault(:locale, %Locale{}), do: []
  defp fault(:locale, _locale), do: [{[:locale], {:type, :locale}}]
  defp fault(:format, nil), do: []

  defp fault(:format, specifier) do
    case Format.parse(specifier) do
      {:ok, _format} -> []
      {:error, faults} -> for {path, reason} <- faults, do: {[:format | path], reason}
    end
  end

  defp measure_format(measure, opts) do
    locale = opts[:locale] || Locale.english()
    kind = kind(measure)
    precision = opts[:precision] || 2
    format = if opts[:format], do: Format.parse!(opts[:format], locale: locale)

    %__MODULE__{
      measure: measure,
      kind: kind,
      precision: precision,
      system: opts[:system],
      style: opts[:style],
      notation: notation(opts[:notation], opts[:domain], opts[:precision]),
      format: format,
      fixed: fixed(kind, precision, locale),
      locale: locale,
      currency: currency(kind, measure, opts[:precision], locale)
    }
  end

  # A count's integers grouped; every other number to the precision.
  defp fixed(:count, _precision, locale), do: Format.parse!(",d", locale: locale)
  defp fixed(_kind, precision, locale), do: Format.parse!(".#{precision}f", locale: locale)

  defp kind(%{quantity: quantity}) when quantity in [:duration, :currency, :ratio, :count],
    do: quantity

  defp kind(%{quantity: nil, unit: nil}), do: :number
  defp kind(%{quantity: nil}), do: :unit
  defp kind(_measure), do: :quantity

  defp currency(:currency, %{unit: unit}, precision, locale) do
    code = Unit.currency(unit)
    {:ok, minor} = Unit.minor_units(code)
    places = precision || minor || 2

    %{
      code: code,
      symbol: Map.get(locale.symbols, code),
      amount: Format.parse!(",.#{places}f", locale: locale)
    }
  end

  defp currency(_kind, _measure, _precision, _locale), do: nil

  # A domain's notation, chosen once for every value; a precision given alone writes to
  # it, as visualize's one value does; else the notation given.
  defp notation(:auto, nil, nil), do: :auto
  defp notation(:auto, nil, _precision), do: :fixed
  defp notation(:auto, domain, _precision), do: domain |> magnitude() |> auto()
  defp notation(notation, _domain, _precision), do: notation

  defp magnitude(domain),
    do: domain |> Enum.filter(&is_number/1) |> Enum.map(&abs/1) |> Enum.max(fn -> 0 end)

  defp auto(magnitude) when magnitude < 1_000, do: :plain
  defp auto(magnitude) when magnitude < 1_000_000, do: :grouped
  defp auto(magnitude), do: {:si, prefix(magnitude)}

  # The largest prefix whose power of ten is at most the magnitude, a thousand at least.
  defp prefix(magnitude) do
    Enum.find_value(@prefixes, 3, fn {e, _symbol} -> if magnitude >= 10 ** e, do: e end)
  end

  # -- writing -------------------------------------------------------------------------

  @doc false
  @spec write(t(), term()) :: String.t()
  def write(%__MODULE__{} = format, value) when is_number(value), do: written(format, value)
  def write(%__MODULE__{locale: locale}, _value), do: locale.nan

  # A d3 format overrides the number only: a currency's amount and a ratio under `%` or
  # `p` it writes whole.
  defp written(%{format: %Format{} = d3, kind: :currency}, value), do: Format.number(d3, value)

  defp written(%{format: %Format{type: type} = d3, kind: :ratio, measure: m}, value)
       when type in ["%", "p"],
       do: Format.number(d3, convert(value, m.unit, "1"))

  defp written(%{format: %Format{} = d3, measure: m}, value),
    do: Format.number(d3, value) <> suffix(m.unit)

  defp written(%{kind: :duration, measure: m} = format, value) do
    seconds = convert(value, m.unit, "s")

    case format.style do
      :compound -> compound(seconds, format.precision)
      :magnitude -> magnitude_duration(seconds)
    end
  end

  defp written(%{kind: :currency, currency: currency, locale: locale}, value) do
    amount = Format.number(currency.amount, abs(value))
    sign = if value < 0 and not zero_amount?(amount), do: locale.minus, else: ""

    case currency.symbol do
      nil -> sign <> amount <> " " <> currency.code
      symbol -> sign <> symbol <> amount
    end
  end

  defp written(%{kind: :ratio, measure: m, fixed: fixed}, value),
    do: Format.number(fixed, convert(value, m.unit, "%")) <> "%"

  defp written(%{kind: :count, fixed: integers}, value), do: Format.number(integers, value)

  defp written(%{kind: :quantity, measure: m} = format, value) do
    display = display_unit(m, format.system, abs(value))
    Format.number(format.fixed, convert(value, m.unit, display)) <> suffix(display)
  end

  defp written(%{kind: :unit, measure: m, fixed: fixed}, value),
    do: Format.number(fixed, value) <> suffix(m.unit)

  defp written(%{kind: :number, notation: :fixed, fixed: fixed}, value),
    do: Format.number(fixed, value)

  defp written(%{kind: :number, notation: :auto, locale: locale}, value),
    do: notation_label(auto(abs(value)), value, locale)

  defp written(%{kind: :number, notation: notation, locale: locale}, value),
    do: notation_label(notation, value, locale)

  defp zero_amount?(amount), do: not String.match?(amount, ~r/[1-9]/)

  # A value in another unit of its dimension; as it is, should the pair not convert.
  defp convert(value, unit, unit), do: value
  defp convert(value, nil, _to), do: value

  defp convert(value, from, to) do
    case Unit.convert(value, from, to) do
      {:ok, converted} -> converted
      {:error, _reason} -> value
    end
  end

  # What follows a number written in a unit: its symbol after a space, `%`, `°` and a
  # symbol beginning with `/` directly, nothing for no unit or an empty symbol.
  defp suffix(nil), do: ""

  defp suffix(unit) do
    case Unit.symbol(unit) do
      {:ok, ""} -> ""
      {:ok, "%"} -> "%"
      {:ok, "°"} -> "°"
      {:ok, "/" <> _ = symbol} -> symbol
      {:ok, symbol} -> " " <> symbol
      {:error, _reason} -> ""
    end
  end

  # -- the display unit ----------------------------------------------------------------

  # The member of the system's family the magnitude fills to at least 1, else the
  # smallest; a family of one is that member; no family, or a unit with no factor in its
  # own, keeps the unit; zero keeps a unit of the family, else takes the member nearest.
  defp display_unit(%{quantity: quantity, unit: unit}, system, magnitude) do
    case Quantity.family(quantity, unit, system) do
      {:ok, []} -> unit
      {:ok, [member]} -> member
      {:ok, family} -> choose(family, quantity, unit, system, magnitude)
      {:error, _reason} -> unit
    end
  end

  defp choose(family, quantity, unit, system, magnitude) do
    cond do
      Unit.factor(unit) == {:ok, nil} -> unit
      magnitude != 0 -> fit(family, magnitude, unit)
      own_family?(quantity, unit, system, family) -> unit
      true -> Enum.min_by(family, &abs(:math.log10(convert(1, unit, &1))))
    end
  end

  defp own_family?(quantity, unit, system, family),
    do: system == :as_posted or Quantity.family(quantity, unit, :as_posted) == {:ok, family}

  defp fit([smallest | _] = family, magnitude, unit) do
    family
    |> Enum.filter(&(convert(magnitude, unit, &1) >= 1))
    |> List.last(smallest)
  end

  # -- durations -----------------------------------------------------------------------

  # The compound form: two units from a second up, milliseconds and nanoseconds below.
  defp compound(seconds, precision) when seconds < 0, do: "-" <> compound(-seconds, precision)
  defp compound(seconds, _precision) when seconds == 0, do: "0s"

  defp compound(seconds, precision) when seconds < 1.0e-6,
    do: trimmed(seconds * 1.0e9, precision) <> "ns"

  defp compound(seconds, precision) when seconds < 1,
    do: trimmed(seconds * 1000.0, precision) <> "ms"

  defp compound(seconds, _precision) do
    {parts, _left} =
      Enum.reduce([{86_400, "d"}, {3600, "h"}, {60, "m"}, {1, "s"}], {[], trunc(seconds)}, fn
        {size, unit}, {parts, left} ->
          count = div(left, size)
          parts = if count > 0, do: ["#{count}#{unit}" | parts], else: parts
          {parts, rem(left, size)}
      end)

    parts |> Enum.reverse() |> Enum.take(2) |> Enum.join(" ")
  end

  defp trimmed(value, precision) do
    fixed = :erlang.float_to_binary(value * 1.0, decimals: precision)

    if String.contains?(fixed, "."),
      do: fixed |> String.trim_trailing("0") |> String.trim_trailing("."),
      else: fixed
  end

  # visualize's axis form: the unit the magnitude chooses, whole, paired or one decimal.
  defp magnitude_duration(seconds) when seconds < 0, do: "−" <> magnitude_duration(-seconds)
  defp magnitude_duration(seconds) when seconds == 0, do: "0s"

  defp magnitude_duration(seconds) do
    units = [{"d", 86_400}, {"h", 3600}, {"m", 60}, {"s", 1}, {"ms", 0.001}]

    case Enum.drop_while(units, fn {_unit, size} -> seconds < size end) do
      [] ->
        one_decimal(Float.round(seconds * 1000, 1)) <> "ms"

      [{unit, size} | finer] ->
        count = seconds / size

        cond do
          whole?(count) ->
            "#{round(count)}#{unit}"

          finer != [] and unit != "s" and whole?(rest_in(seconds, size, hd(finer))) and
              rest_in(seconds, size, hd(finer)) >= 1 ->
            {finer_unit, _size} = hd(finer)
            "#{trunc(count)}#{unit}#{round(rest_in(seconds, size, hd(finer)))}#{finer_unit}"

          true ->
            one_decimal(Float.round(count * 1.0, 1)) <> unit
        end
    end
  end

  defp rest_in(seconds, size, {_unit, finer_size}),
    do: (seconds - trunc(seconds / size) * size) / finer_size

  defp whole?(count), do: abs(count - round(count)) < 1.0e-9

  defp one_decimal(float) do
    float
    |> :erlang.float_to_binary(decimals: 1)
    |> String.trim_trailing("0")
    |> String.trim_trailing(".")
  end

  # -- a number's notation -------------------------------------------------------------

  defp notation_label(:plain, value, locale), do: plain(value, locale)

  defp notation_label(:grouped, value, locale), do: grouped(plain(value, locale), locale)

  defp notation_label({:si, _e}, value, _locale) when value == 0, do: "0"

  defp notation_label({:si, e}, value, locale) do
    {^e, symbol} = List.keyfind(@prefixes, e, 0)
    plain(value / 10 ** e, locale) <> symbol
  end

  defp notation_label(:si, value, locale) when abs(value) < 1_000, do: plain(value, locale)

  defp notation_label(:si, value, locale),
    do: notation_label({:si, prefix(abs(value))}, value, locale)

  # visualize's default label: at most six decimals, the zeros and a bare point dropped,
  # never `-0`; an integer as it is. A float past 2⁵³ is an integer, written exactly.
  defp plain(value, locale) when is_integer(value),
    do: localized(Integer.to_string(value), locale)

  defp plain(value, locale) when abs(value) >= 9_007_199_254_740_992.0,
    do: localized(Integer.to_string(trunc(value)), locale)

  defp plain(value, locale) do
    (Float.round(value, 6) + 0.0)
    |> :erlang.float_to_binary(decimals: 6)
    |> String.trim_trailing("0")
    |> String.trim_trailing(".")
    |> localized(locale)
  end

  defp localized(label, %{decimal: ".", minus: "-"}), do: label

  defp localized(label, locale) do
    label
    |> String.replace(".", locale.decimal)
    |> then(fn
      "-" <> rest -> locale.minus <> rest
      rest -> rest
    end)
  end

  # The integer digits grouped by the locale, the sign and the fraction untouched.
  defp grouped(label, locale) do
    {sign, digits} =
      case String.split_at(label, String.length(locale.minus)) do
        {sign, rest} when sign == locale.minus -> {sign, rest}
        _other -> {"", label}
      end

    {integer, fraction} =
      case String.split(digits, locale.decimal, parts: 2) do
        [integer, fraction] -> {integer, locale.decimal <> fraction}
        [integer] -> {integer, ""}
      end

    sign <> Number.group_digits(integer, locale) <> fraction
  end
end
