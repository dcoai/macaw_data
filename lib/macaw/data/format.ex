defmodule Macaw.Data.Format do
  @moduledoc """
  How a value is written for a person (spec/05): a format is data, read once from the text
  it is written in and applied to any number of values.

  A number's format is a d3-format specifier, `[[fill]align][sign][symbol][0][width][,][.precision][~][type]`
  (spec/05 §2), read by `parse/2` into a `%Macaw.Data.Format{}` that holds no function, so
  it can be compared, digested and carried, and written by `number/2`:

      iex> {:ok, format} = Macaw.Data.Format.parse(",.2f")
      iex> Macaw.Data.Format.number(format, 1234567.891)
      "1,234,567.89"

      iex> Macaw.Data.Format.number(Macaw.Data.Format.parse!(".3s"), 42_000_000)
      "42.0M"

      iex> Macaw.Data.Format.number(Macaw.Data.Format.parse!("($,.2f"), -1234.5)
      "($1,234.50)"

      iex> Macaw.Data.Format.parse("..2f")
      {:error, [{[], {:specifier, "..2f"}}]}

  The digits are d3's, byte for byte over visualize's conformance set, which carries
  d3's own cases; where this differs from d3 (an integer's exact digits, a width bound),
  spec/05 §2 says so. The locale is a `Macaw.Data.Format.Locale`, English by default.
  """

  alias Macaw.Data.{Error, Fault, Options, Unit}
  alias Macaw.Data.Format.{Locale, Measure, Number, Time}

  @enforce_keys [:specifier]
  defstruct specifier: nil,
            fill: " ",
            align: ">",
            sign: "-",
            symbol: "",
            zero: false,
            width: nil,
            comma: false,
            precision: 6,
            trim: false,
            type: "g",
            prefix: "",
            suffix: "",
            locale: %Locale{}

  @typedoc """
  A parsed format: the text it was read from, each part of the grammar as d3 normalizes
  it, the affixes its symbol and type write under its locale, and the locale.
  """
  @type t :: %__MODULE__{
          specifier: String.t(),
          fill: String.t(),
          align: String.t(),
          sign: String.t(),
          symbol: String.t(),
          zero: boolean(),
          width: non_neg_integer() | nil,
          comma: boolean(),
          precision: non_neg_integer(),
          trim: boolean(),
          type: String.t(),
          prefix: String.t(),
          suffix: String.t(),
          locale: Locale.t()
        }

  @typedoc "A fault at a place (spec/00 §5)."
  @type fault :: {[term()], term()}

  @max_width 1024
  @types ~w(e f g r s % p d b o x X c)

  @doc """
  Reads a d3-format specifier (spec/05 §1, §2): `{:ok, format}` or `{:error, faults}`.

  A string that is no specifier is `{[], {:specifier, text}}`, a term that is no string
  `{[], {:type, :specifier}}`, a width over 1,024 `{[], {:width, 1024}}`.

  ## Options

  - `:locale` - a `Macaw.Data.Format.Locale`, default `Macaw.Data.Format.Locale.english/0`

  ## Examples

      iex> {:ok, format} = Macaw.Data.Format.parse("+.1%")
      iex> {format.sign, format.precision, format.type, format.suffix}
      {"+", 1, "%", "%"}

      iex> Macaw.Data.Format.parse("08.2f") == Macaw.Data.Format.parse("08.2f")
      true

  """
  @spec parse(term(), keyword()) :: {:ok, t()} | {:error, [fault(), ...]}
  def parse(specifier, opts \\ []) do
    {locale, option_faults} = locale(opts)

    case {read(specifier), option_faults} do
      {{:ok, parts}, []} -> {:ok, build(specifier, parts, locale)}
      {{:ok, _parts}, faults} -> {:error, faults}
      {{:error, fault}, faults} -> {:error, [fault | faults]}
    end
  end

  @doc "As `parse/2`, the format alone, raising `Macaw.Data.Error` with the faults in `format_error/1`'s words."
  @spec parse!(term(), keyword()) :: t()
  def parse!(specifier, opts \\ []) do
    case parse(specifier, opts) do
      {:ok, format} -> format
      {:error, faults} -> raise Error, reason: faults, what: "not a format", words: &words/1
    end
  end

  @doc """
  Writes a value by a format (spec/05 §1): a string, whatever the value.

  A value that is no number is the locale's not-a-number, `NaN` in English, padded and
  aligned as the format says; under the `c` type a string, a number or an atom is
  written as text.

      iex> Macaw.Data.Format.number(Macaw.Data.Format.parse!(">6.2f"), nil)
      "   NaN"

  """
  @spec number(t(), term()) :: String.t()
  def number(%__MODULE__{} = format, value), do: Number.write(format, value)

  @doc """
  Reads a strftime pattern into a time's format (spec/05 §5): `{:ok, format}`, or
  `{:error, faults}` for a term that is no string (`{[], {:type, :pattern}}`) or options
  `parse/2` refuses. Every string is a pattern: a `%` before a character that is no
  directive is written as it stands.

  ## Options

  - `:locale` - a `Macaw.Data.Format.Locale`, default `Macaw.Data.Format.Locale.english/0`

  ## Examples

      iex> {:ok, format} = Macaw.Data.Format.parse_time("%Y-%m-%d %H:%M")
      iex> Macaw.Data.Format.time(format, ~U[2026-11-12 08:05:00Z])
      "2026-11-12 08:05"

  """
  @spec parse_time(term(), keyword()) :: {:ok, Time.t()} | {:error, [fault(), ...]}
  def parse_time(pattern, opts \\ []) do
    {locale, option_faults} = locale(opts)

    case {is_binary(pattern), option_faults} do
      {true, []} -> {:ok, Time.read(pattern, locale)}
      {true, faults} -> {:error, faults}
      {false, faults} -> {:error, [{[], {:type, :pattern}} | faults]}
    end
  end

  @doc "As `parse_time/2`, the format alone, raising `Macaw.Data.Error` with the faults in `format_error/1`'s words."
  @spec parse_time!(term(), keyword()) :: Time.t()
  def parse_time!(pattern, opts \\ []) do
    case parse_time(pattern, opts) do
      {:ok, format} -> format
      {:error, faults} -> raise Error, reason: faults, what: "not a time format", words: &words/1
    end
  end

  @doc """
  Writes a time by a time's format (spec/05 §5), as visualize's `Visualize.Format.time/2`
  writes it: a `DateTime` by its own wall clock and zone, a `NaiveDateTime` and a `Date`
  (at midnight) with no zone, an integer as Unix microseconds in UTC. Any other value,
  and an integer past a `DateTime`'s range, is the locale's not-a-number.

      iex> format = Macaw.Data.Format.parse_time!("%a %e %b %I:%M %p [%Z]")
      iex> Macaw.Data.Format.time(format, ~N[2024-03-03 14:05:09])
      "Sun  3 Mar 02:05 PM []"
      iex> Macaw.Data.Format.time(format, 1_709_474_709_000_000)
      "Sun  3 Mar 02:05 PM [UTC]"

  """
  @spec time(Time.t(), term()) :: String.t()
  def time(%Time{} = format, value), do: Time.write(format, value)

  @doc """
  A field's default format, from its measure (spec/05 §6): `{:ok, format}` or
  `{:error, faults}`, each fault at its key.

  The measure, `%{unit: code, quantity: quantity}` with either or both absent, is
  completed by `Macaw.Data.Quantity.resolve/1`, and its quantity chooses the writing: a
  duration compound, a currency by its code, a ratio a percent, a count rounded and
  grouped, any other quantity rescaled within its unit's family, a number with no measure
  by its notation.

  ## Options

  - `:precision` - decimals, 0 to 20, default 2 (a currency's: its code's minor units)
  - `:system` - one of `Macaw.Data.Quantity.systems/0`, default `:as_posted`
  - `:style` - a duration's, `:compound` (default) or `:magnitude`
  - `:notation` - a number's with no measure: `:auto` (default), `:plain`, `:grouped`,
    `:si` or `{:si, e}`
  - `:domain` - numbers whose greatest magnitude chooses the `:auto` notation for every value
  - `:format` - a d3 specifier that overrides the number
  - `:locale` - a `Macaw.Data.Format.Locale`, default English

  ## Examples

      iex> {:ok, format} = Macaw.Data.Format.for_measure(%{unit: "s"})
      iex> Macaw.Data.Format.measure(format, 5040)
      "1h 24m"

      iex> Macaw.Data.Format.measure(Macaw.Data.Format.for_measure!(%{unit: "{iso4217:JPY}"}), 1240)
      "¥1,240"

      iex> Macaw.Data.Format.measure(Macaw.Data.Format.for_measure!(%{unit: "kg"}, system: :us), 80)
      "176.37 lb"

      iex> Macaw.Data.Format.measure(Macaw.Data.Format.for_measure!(%{}, domain: [0, 9_000_000]), 4_500_000)
      "4.5M"

      iex> Macaw.Data.Format.for_measure(%{unit: "By", quantity: :duration}, precision: -1)
      {:error, [{[:measure], {:quantity, :duration, "By"}}, {[:precision], {:type, :precision}}]}

  """
  @spec for_measure(term(), keyword()) :: {:ok, Measure.t()} | {:error, [fault(), ...]}
  def for_measure(measure, opts \\ []), do: Measure.build(measure, opts)

  @doc "As `for_measure/2`, the format alone, raising `Macaw.Data.Error` with the faults in `format_error/1`'s words."
  @spec for_measure!(term(), keyword()) :: Measure.t()
  def for_measure!(measure, opts \\ []) do
    case for_measure(measure, opts) do
      {:ok, format} ->
        format

      {:error, faults} ->
        raise Error, reason: faults, what: "not a measure's format", words: &words/1
    end
  end

  @doc """
  Writes a value by a measure's format (spec/05 §6): a string, whatever the value; a
  value that is no number is the locale's not-a-number.

      iex> Macaw.Data.Format.measure(Macaw.Data.Format.for_measure!(%{quantity: :ratio}), 0.914)
      "91.40%"

  """
  @spec measure(Measure.t(), term()) :: String.t()
  def measure(%Measure{} = format, value), do: Measure.write(format, value)

  @doc """
  The words of a reason this module answers, for a person (spec/00 §5).

      iex> Macaw.Data.Format.format_error({:width, 1024})
      "is wider than 1024 characters, the most a format writes"

  """
  @spec format_error(term()) :: String.t()
  def format_error(reason), do: words(reason) || Fault.sentence(reason)

  @doc false
  # This module's words for a reason, `nil` for one the library's vocabulary words.
  @spec words(term()) :: String.t() | nil
  def words({:specifier, text}), do: "#{inspect(text)} is no d3-format specifier"
  def words({:width, max}), do: "is wider than #{max} characters, the most a format writes"
  def words({:type, :specifier}), do: "must be a d3-format specifier, a string"
  def words({:type, :locale}), do: "must be a Macaw.Data.Format.Locale"
  def words({:type, :grouping}), do: "must be a list of positive integers, the group sizes"
  def words({:type, :currency}), do: "must be {prefix, suffix}, two strings"
  def words({:type, :symbols}), do: "must be a map of ISO 4217 codes to strings"
  def words({:unknown_currency, _code} = reason), do: Unit.format_error(reason)
  def words({:type, :measure}), do: "must be a measure, a map of a unit and a quantity"
  def words({:type, :precision}), do: "must be an integer from 0 to 20"
  def words({:type, :domain}), do: "must be a list of numbers"
  def words({:unknown_system, _system}), do: "must be one of :metric, :us, :uk or :as_posted"

  def words({:unknown_quantity, q}),
    do: "#{inspect(q)} is no quantity of Macaw.Data.Quantity.all/0"

  def words({:quantity, q, unit}), do: "#{unit} does not measure #{q}"
  def words({:unit, code, reason}), do: "unit #{inspect(code)}: " <> Unit.format_error(reason)

  def words({:names, n}),
    do: "must be a list of #{n} strings"

  def words({:type, :pattern}), do: "must be a strftime pattern, a string"
  def words(_reason), do: nil

  # -- options -------------------------------------------------------------------------

  defp locale(opts) do
    case Options.known(opts, locale: Locale.english()) do
      {:ok, opts} ->
        case opts[:locale] do
          %Locale{} = locale -> {locale, []}
          _other -> {Locale.english(), [{[:locale], {:type, :locale}}]}
        end

      {:error, faults} ->
        {Locale.english(), faults}
    end
  end

  # -- the grammar ---------------------------------------------------------------------

  # `[[fill]align][sign][symbol][0][width][,][.precision][~][type]`, as d3's expression
  # reads it: each part optional, in this order, and nothing after the type.
  defp read(text) when is_binary(text) do
    {fill, align, rest} = fill_align(text)
    {sign, rest} = one_of(rest, ["+", "-", "(", " "])
    {symbol, rest} = one_of(rest, ["$", "#"])
    {zero, rest} = one_of(rest, ["0"])
    {width, rest} = digits(rest)
    {comma, rest} = one_of(rest, [","])

    with {:ok, precision, rest} <- precision(rest),
         {trim, rest} = one_of(rest, ["~"]),
         {type, ""} <- type(rest),
         :ok <- width_ok(width) do
      {:ok,
       %{
         fill: fill,
         align: align,
         sign: sign,
         symbol: symbol,
         zero: zero == "0",
         width: width,
         comma: comma == ",",
         precision: precision,
         trim: trim == "~",
         type: type
       }}
    else
      {:width, max} -> {:error, {[], {:width, max}}}
      _no -> {:error, {[], {:specifier, text}}}
    end
  end

  defp read(_text), do: {:error, {[], {:type, :specifier}}}

  @aligns [?<, ?>, ?=, ?^]
  # A fill is any one character but a line terminator, which JavaScript's `.` excludes.
  @terminators [?\n, ?\r, 0x2028, 0x2029]

  defp fill_align(<<fill::utf8, align, rest::binary>>)
       when align in @aligns and fill not in @terminators,
       do: {<<fill::utf8>>, <<align>>, rest}

  defp fill_align(<<align, rest::binary>>) when align in @aligns, do: {nil, <<align>>, rest}
  defp fill_align(rest), do: {nil, nil, rest}

  defp one_of(text, choices) do
    case Enum.find(choices, &String.starts_with?(text, &1)) do
      nil -> {nil, text}
      choice -> {choice, binary_part(text, 1, byte_size(text) - 1)}
    end
  end

  defp digits(text), do: digits(text, 0, nil)

  defp digits(<<d, rest::binary>>, n, _seen) when d in ?0..?9,
    do: digits(rest, n * 10 + d - ?0, true)

  defp digits(rest, n, true), do: {n, rest}
  defp digits(rest, _n, nil), do: {nil, rest}

  defp precision("." <> rest) do
    case digits(rest) do
      {nil, _rest} -> :error
      {precision, rest} -> {:ok, precision, rest}
    end
  end

  defp precision(rest), do: {:ok, nil, rest}

  defp type(<<c, rest::binary>>) when c in ?a..?z or c in ?A..?Z or c == ?%, do: {<<c>>, rest}
  defp type(rest), do: {"", rest}

  defp width_ok(width) when is_integer(width) and width > @max_width, do: {:width, @max_width}
  defp width_ok(_width), do: :ok

  # d3's normalization: `n` is `,g`; no type, or an unknown one, is `~g` at 12; zero fill
  # is fill `0` aligned `=`; the precision is clamped by type.
  defp build(specifier, parts, locale) do
    parts =
      cond do
        parts.type == "n" ->
          %{parts | comma: true, type: "g"}

        parts.type not in @types ->
          %{parts | precision: parts.precision || 12, trim: true, type: "g"}

        true ->
          parts
      end

    parts =
      if parts.zero or (parts.fill == "0" and parts.align == "="),
        do: %{parts | zero: true, fill: "0", align: "="},
        else: parts

    precision =
      case {parts.precision, parts.type} do
        {nil, _type} -> 6
        {p, type} when type in ~w(g p r s) -> p |> max(1) |> min(21)
        {p, _type} -> p |> max(0) |> min(20)
      end

    {currency_prefix, currency_suffix} = locale.currency

    prefix =
      cond do
        parts.symbol == "$" -> currency_prefix
        parts.symbol == "#" and parts.type in ~w(b o x X) -> "0" <> String.downcase(parts.type)
        true -> ""
      end

    suffix =
      cond do
        parts.symbol == "$" -> currency_suffix
        parts.type in ["%", "p"] -> locale.percent
        true -> ""
      end

    %__MODULE__{
      specifier: specifier,
      fill: parts.fill || " ",
      align: parts.align || ">",
      sign: parts.sign || "-",
      symbol: parts.symbol || "",
      zero: parts.zero,
      width: parts.width,
      comma: parts.comma,
      precision: precision,
      trim: parts.trim,
      type: parts.type,
      prefix: prefix,
      suffix: suffix,
      locale: locale
    }
  end
end
