defmodule Macaw.Data.Format.Locale do
  @moduledoc """
  How a locale writes numbers (spec/05 §3): a d3-format locale definition, as data.

  | Field | English | What it is |
  |---|---|---|
  | `decimal` | `"."` | the decimal point |
  | `thousands` | `","` | the group separator |
  | `grouping` | `[3]` | the group sizes from the right, used in turn and again from the first |
  | `currency` | `{"$", ""}` | what the `$` symbol writes before and after the number |
  | `minus` | `"-"` | the minus sign (d3's default is `−`, U+2212) |
  | `nan` | `"NaN"` | a value that is no number |
  | `percent` | `"%"` | the percent sign of the `%` and `p` types |
  | `symbols` | `USD` `$`, `EUR` `€`, `GBP` `£`, `JPY` `¥` | the ISO 4217 codes written by a symbol |

  A locale is the viewer's choice, as the unit system is: nothing is derived from it.

      iex> {:ok, german} = Macaw.Data.Format.Locale.new(decimal: ",", thousands: ".", currency: {"", " €"})
      iex> Macaw.Data.Format.number(Macaw.Data.Format.parse!("$,.2f", locale: german), 1234.5)
      "1.234,50 €"

  """

  alias Macaw.Data.{Error, Format, Options, Unit}

  @english %{"EUR" => "€", "GBP" => "£", "JPY" => "¥", "USD" => "$"}

  defstruct decimal: ".",
            thousands: ",",
            grouping: [3],
            currency: {"$", ""},
            minus: "-",
            nan: "NaN",
            percent: "%",
            symbols: @english

  @type t :: %__MODULE__{
          decimal: String.t(),
          thousands: String.t(),
          grouping: [pos_integer()],
          currency: {String.t(), String.t()},
          minus: String.t(),
          nan: String.t(),
          percent: String.t(),
          symbols: %{String.t() => String.t()}
        }

  @texts [:decimal, :thousands, :minus, :nan, :percent]
  @keys [:decimal, :thousands, :grouping, :currency, :minus, :nan, :percent, :symbols]

  @doc """
  English, the default: `.` and `,`, groups of three, `$`, the hyphen-minus.

      iex> Macaw.Data.Format.Locale.english().grouping
      [3]

  """
  @spec english() :: t()
  def english, do: %__MODULE__{}

  @doc """
  A locale from a keyword list or a map of the fields in the table, each one absent being
  English's (spec/05 §3): `{:ok, locale}` or `{:error, faults}`.

  A key it does not take is `{[key], :unknown_key}`; a field of the wrong kind
  `{[key], {:type, kind}}`, `kind` being `:text`, `:grouping`, `:currency` or `:symbols`; a
  symbol under a code not in the ISO table `{[:symbols, code], {:unknown_currency, code}}`;
  fields that are neither a keyword list nor a map `{[], {:type, :keyword}}`.

      iex> Macaw.Data.Format.Locale.new(%{decimal: 1, grouping: [0]})
      {:error, [{[:decimal], {:type, :text}}, {[:grouping], {:type, :grouping}}]}

  """
  @spec new(keyword() | map()) :: {:ok, t()} | {:error, [{[term()], term()}, ...]}
  def new(fields) when is_list(fields) or is_map(fields) do
    with {:ok, fields} <- Options.fields(fields) do
      faults = fields |> Enum.sort_by(&key_order/1) |> Enum.flat_map(&field_faults/1)

      case faults do
        [] -> {:ok, struct(english(), with_pair(fields))}
        faults -> {:error, faults}
      end
    end
  end

  @doc "As `new/1`, the locale alone, raising `Macaw.Data.Error` with the faults in `Macaw.Data.Format.format_error/1`'s words."
  @spec new!(keyword() | map()) :: t()
  def new!(fields) do
    case new(fields) do
      {:ok, locale} ->
        locale

      {:error, faults} ->
        raise Error, reason: faults, what: "not a locale", words: &Format.words/1
    end
  end

  # The faults of the table's order, then every other key's.
  defp key_order({key, _value}) do
    case Enum.find_index(@keys, &(&1 == key)) do
      nil -> {1, inspect(key)}
      i -> {0, i}
    end
  end

  defp field_faults({key, value}) when key in @texts,
    do: if(is_binary(value), do: [], else: [{[key], {:type, :text}}])

  defp field_faults({:grouping, value}) do
    if Macaw.Data.Lists.proper?(value) and Enum.all?(value, &(is_integer(&1) and &1 > 0)),
      do: [],
      else: [{[:grouping], {:type, :grouping}}]
  end

  defp field_faults({:currency, value}) do
    case pair(value) do
      {prefix, suffix} when is_binary(prefix) and is_binary(suffix) -> []
      _other -> [{[:currency], {:type, :currency}}]
    end
  end

  defp field_faults({:symbols, value}) when is_map(value) and not is_struct(value) do
    Enum.uniq(
      for {code, symbol} <- Enum.sort(value), fault = symbol_fault(code, symbol), do: fault
    )
  end

  defp field_faults({:symbols, _value}), do: [{[:symbols], {:type, :symbols}}]
  defp field_faults({key, _value}), do: [{[key], :unknown_key}]

  defp symbol_fault(code, symbol) when is_binary(code) and is_binary(symbol) do
    case Unit.minor_units(code) do
      {:ok, _units} -> nil
      {:error, reason} -> {[:symbols, code], reason}
    end
  end

  defp symbol_fault(_code, _symbol), do: {[:symbols], {:type, :symbols}}

  defp with_pair(%{currency: currency} = fields), do: %{fields | currency: pair(currency)}
  defp with_pair(fields), do: fields

  # d3 writes the currency as a two-element array; a pair or a two-element list.
  defp pair({prefix, suffix}), do: {prefix, suffix}
  defp pair([prefix, suffix]), do: {prefix, suffix}
  defp pair(other), do: other
end
