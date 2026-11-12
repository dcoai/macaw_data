defmodule Macaw.Data.Format.Time do
  @moduledoc """
  A time's format (spec/05 §5): a strftime pattern read once into data, written by
  `Macaw.Data.Format.time/2`.

  The pattern is held as its runs: the directives `Calendar.strftime/3` has, with the
  text between them, as one pattern each, and the directives it lacks or writes otherwise
  (`%L`, `%U`, `%p`, `%w`, `%Z` and `%z`) one by one. A `%` before a character that is no directive is text, as
  is a `%` that ends the pattern.

      iex> {:ok, format} = Macaw.Data.Format.parse_time("%H:%M:%S.%L %Z")
      iex> format.parts
      [{:strftime, "%H:%M:%S."}, :L, {:strftime, " "}, :Z]

  """

  alias Macaw.Data.Format.Locale

  @enforce_keys [:pattern]
  defstruct pattern: nil, parts: [], locale: %Locale{}

  @typedoc "A run of the pattern: one for `Calendar.strftime/3`, or a directive it lacks."
  @type part :: {:strftime | :named, String.t()} | :L | :U | :p | :w | :Z | :z

  @type t :: %__MODULE__{pattern: String.t(), parts: [part()], locale: Locale.t()}

  # The directives strftime writes as visualize does; `%e` is its `%_d`.
  @strftime ~c"YymdjHIMSaAbB"
  @own %{?L => :L, ?U => :U, ?p => :p, ?w => :w, ?Z => :Z, ?z => :z}

  @doc false
  @spec read(String.t(), Locale.t()) :: t()
  def read(pattern, locale),
    do: %__MODULE__{pattern: pattern, parts: parts(pattern, english?(locale)), locale: locale}

  # A run naming a day or a month under another locale than English's names is `:named`,
  # written with the locale's names; any other run is strftime's own, decided once here.
  defp parts(pattern, english?) do
    pattern
    |> tokens([])
    |> Enum.chunk_by(&is_binary/1)
    |> Enum.flat_map(fn
      [text | _] = run when is_binary(text) ->
        named? = not english? and Enum.any?(run, &(&1 in ~w(%a %A %b %B)))
        [{if(named?, do: :named, else: :strftime), IO.iodata_to_binary(run)}]

      own ->
        own
    end)
  end

  @english %Locale{}
  defp english?(locale) do
    Map.take(locale, [:days, :short_days, :months, :short_months]) ==
      Map.take(@english, [:days, :short_days, :months, :short_months])
  end

  # Each directive strftime has stays a directive, escaped text is escaped for it, and
  # each one it lacks is an atom.
  defp tokens("", acc), do: Enum.reverse(acc)

  defp tokens(<<?%, c, rest::binary>>, acc) when c in @strftime,
    do: tokens(rest, [<<?%, c>> | acc])

  defp tokens(<<?%, ?e, rest::binary>>, acc), do: tokens(rest, ["%_d" | acc])
  defp tokens(<<?%, ?%, rest::binary>>, acc), do: tokens(rest, ["%%" | acc])

  defp tokens(<<?%, c, rest::binary>>, acc) when is_map_key(@own, c),
    do: tokens(rest, [Map.fetch!(@own, c) | acc])

  # A `%` before anything else, or at the end, is text: `%%` for strftime.
  defp tokens(<<?%, rest::binary>>, acc), do: tokens(rest, ["%%" | acc])
  defp tokens(<<c::utf8, rest::binary>>, acc), do: tokens(rest, [<<c::utf8>> | acc])
  defp tokens(<<c, rest::binary>>, acc), do: tokens(rest, [<<c>> | acc])

  # -- writing -------------------------------------------------------------------------

  @doc false
  @spec write(t(), term()) :: String.t()
  def write(%__MODULE__{} = format, value) do
    case {fields(value), format.parts} do
      {{:ok, time}, [{:strftime, pattern}]} ->
        Calendar.strftime(time, pattern)

      {{:ok, time}, parts} ->
        parts |> Enum.map(&part(&1, time, format.locale)) |> IO.iodata_to_binary()

      {:error, _parts} ->
        format.locale.nan
    end
  end

  # What strftime reads, for each kind of time: a `DateTime` and a `NaiveDateTime` as they
  # are, a `Date` at midnight, integer Unix microseconds as UTC.
  defp fields(%DateTime{} = time), do: {:ok, time}
  defp fields(%NaiveDateTime{} = time), do: {:ok, time}

  defp fields(%Date{} = date),
    do: {:ok, Map.merge(date, %{hour: 0, minute: 0, second: 0, microsecond: {0, 0}})}

  defp fields(microseconds) when is_integer(microseconds) do
    case DateTime.from_unix(microseconds, :microsecond) do
      {:ok, time} -> {:ok, time}
      {:error, _reason} -> :error
    end
  end

  defp fields(_value), do: :error

  defp part({:strftime, pattern}, time, _locale), do: Calendar.strftime(time, pattern)
  defp part({:named, pattern}, time, locale), do: Calendar.strftime(time, pattern, names(locale))

  defp part(:L, %{microsecond: {us, _precision}}, _locale), do: pad(div(us, 1000), 3)
  # strftime upper-cases its period names; the locale's are written as they are.
  defp part(:p, %{hour: hour}, locale) when hour < 12, do: Enum.at(locale.periods, 0)
  defp part(:p, _time, locale), do: Enum.at(locale.periods, 1)

  defp part(:U, time, _locale),
    do: pad(div(day_of_year(time) + 6 - sunday_weekday(time), 7), 2)

  defp part(:w, time, _locale), do: Integer.to_string(sunday_weekday(time))
  defp part(:Z, %DateTime{zone_abbr: abbr}, _locale), do: abbr

  defp part(:z, %DateTime{} = time, _locale),
    do: offset(time.utc_offset + time.std_offset)

  defp part(zone, _time, _locale) when zone in [:Z, :z], do: ""

  defp day_of_year(%{calendar: calendar, year: y, month: m, day: d}),
    do: calendar.day_of_year(y, m, d)

  # Sunday is 0, as in strftime.
  defp sunday_weekday(%{calendar: calendar, year: y, month: m, day: d}) do
    {day, _first, _last} = calendar.day_of_week(y, m, d, :sunday)
    day - 1
  end

  defp offset(seconds) do
    sign = if seconds < 0, do: "-", else: "+"
    minutes = div(abs(seconds), 60)
    sign <> pad(div(minutes, 60), 2) <> pad(rem(minutes, 60), 2)
  end

  defp pad(n, width), do: n |> Integer.to_string() |> String.pad_leading(width, "0")

  # The locale's names as strftime's options. The locale's days are from Sunday,
  # strftime's day of the week from Monday, 1.
  defp names(locale) do
    [
      day_of_week_names: &Enum.at(locale.days, rem(&1, 7)),
      abbreviated_day_of_week_names: &Enum.at(locale.short_days, rem(&1, 7)),
      month_names: &Enum.at(locale.months, &1 - 1),
      abbreviated_month_names: &Enum.at(locale.short_months, &1 - 1)
    ]
  end
end
