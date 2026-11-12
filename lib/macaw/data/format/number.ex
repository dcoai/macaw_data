defmodule Macaw.Data.Format.Number do
  @moduledoc false
  # Writes a number by a parsed format, as d3-format's `format` closure does (spec/05 §2):
  # the type's digits of the magnitude, trimmed, the sign and affixes, the integer digits
  # grouped, then padding and alignment. The digits are JavaScript's: a tie rounds away
  # from zero on the double's exact value.

  alias Macaw.Data.Format

  @prefixes ~w(y z a f p n µ m) ++ [""] ++ ~w(k M G T P E Z Y)
  # The integers a double holds without overflowing: past this, JavaScript's infinity.
  @max_float trunc(1.7976931348623157e308)
  @infinity "Infinity"
  # Every double from here on is an integer, so its digits are exact as an integer's.
  @exact 9_007_199_254_740_992.0

  @spec write(Format.t(), term()) :: String.t()
  # -- the common formats, through the BIFs (spec/05 §4) -------------------------------

  # `f`, `%` and `d` with no width, no `~` and the `-` sign: the BIF's digits, the integer
  # digits grouped by slicing them. A float past 2⁵³ takes the general path, whose
  # digits are exact (the BIF writes at most 256 characters).
  def write(%Format{type: "f", width: nil, trim: false, sign: "-", precision: p} = format, value)
      when is_float(value) and value < @exact and value > -@exact,
      do: fast(:erlang.float_to_binary(value, decimals: p), fraction(p), format)

  def write(%Format{type: "%", width: nil, trim: false, sign: "-", precision: p} = format, value)
      when is_float(value) and value < @exact / 100 and value > -@exact / 100,
      do: fast(:erlang.float_to_binary(value * 100, decimals: p), fraction(p), format)

  def write(%Format{type: "d", width: nil, trim: false, sign: "-"} = format, value)
      when is_integer(value),
      do: fast(Integer.to_string(value), 0, format)

  def write(%Format{type: "d", width: nil, trim: false, sign: "-"} = format, value)
      when is_float(value) and value < @exact and value > -@exact,
      do: fast(Integer.to_string(round(value)), 0, format)

  def write(%Format{type: "c"} = format, value),
    do: assemble(format, format.prefix, "", text(value, format.locale) <> format.suffix)

  def write(%Format{} = format, value) when is_number(value) do
    negative? = negative?(value)
    {body, si} = body(format.type, value, format.precision)
    body = if format.trim, do: trim(body), else: body

    # A negative that rounds to zero shows no sign unless a plus sign was asked for.
    negative? = negative? and not (zero?(body) and format.sign != "+")
    sign = sign(negative?, format.sign, format.locale.minus)
    close = if negative? and format.sign == "(", do: ")", else: ""
    value_suffix = si_prefix(format.type, si) <> format.suffix <> close
    {digits, value_suffix} = split(format.type, body, value_suffix, format.locale.decimal)
    assemble(format, sign <> format.prefix, digits, value_suffix)
  end

  def write(%Format{} = format, _value) do
    sign = if format.sign in ["-", "("], do: "", else: format.sign
    {digits, suffix} = split(format.type, format.locale.nan, format.suffix, format.locale.decimal)
    assemble(format, sign <> format.prefix, digits, suffix)
  end

  # -- sign, affixes, digits -----------------------------------------------------------

  # A float's sign bit, so negative zero is negative, as d3's `1 / value < 0` reads it.
  defp negative?(value) when is_integer(value), do: value < 0

  defp negative?(value) do
    <<sign::1, _rest::bitstring>> = <<value::float>>
    sign == 1
  end

  defp sign(true, "(", _minus), do: "("
  defp sign(true, _sign, minus), do: minus
  defp sign(false, sign, _minus) when sign in ["-", "("], do: ""
  defp sign(false, sign, _minus), do: sign

  defp si_prefix("s", si), do: Enum.at(@prefixes, 8 + div(si, 3))
  defp si_prefix(_type, _si), do: ""

  # d3's `+value === 0` of the written digits: nothing but zeros, points and an exponent's
  # sign. `Infinity` and hexadecimal digits are not zero.
  defp zero?(<<c, rest::binary>>) when c in [?0, ?., ?e, ?+, ?-], do: zero?(rest)
  defp zero?(<<>>), do: true
  defp zero?(_body), do: false

  # The integer digits that can be grouped, from the fraction or exponent that cannot; the
  # point becomes the locale's decimal.
  defp split(type, body, suffix, decimal) when type in ~w(d e f g p r s %) do
    case leading_digits(body, 0) do
      n when n == byte_size(body) ->
        {body, suffix}

      n ->
        <<digits::binary-size(^n), rest::binary>> = body

        case rest do
          "." <> fraction -> {digits, decimal <> fraction <> suffix}
          rest -> {digits, rest <> suffix}
        end
    end
  end

  defp split(_type, body, suffix, _decimal), do: {body, suffix}

  defp leading_digits(<<d, rest::binary>>, n) when d in ?0..?9, do: leading_digits(rest, n + 1)
  defp leading_digits(_rest, n), do: n

  # The `c` type: a string, a number or an atom as text, any other term not-a-number.
  defp text(value, _locale) when is_binary(value), do: value
  defp text(value, _locale) when is_number(value) or is_atom(value), do: to_string(value)
  defp text(_value, locale), do: locale.nan

  # -- the common formats' digits ------------------------------------------------------

  # The bytes after the integer digits: a point and `p` decimals, or none.
  defp fraction(0), do: 0
  defp fraction(p), do: p + 1

  # A negative that rounds to zero is written without its sign.
  defp fast(<<?-, magnitude::binary>>, fraction, format) do
    if :binary.first(magnitude) == ?0 and zero?(magnitude),
      do: digits(magnitude, fraction, "", format),
      else: digits(magnitude, fraction, format.locale.minus, format)
  end

  defp fast(magnitude, fraction, format), do: digits(magnitude, fraction, "", format)

  # The BIF's digits, `n` integer digits then for `f` and `%` a point and the fraction,
  # written as one binary built from slices of known sizes. Each build starts with an
  # empty literal segment: a build that starts with a binary variable takes the
  # compiler's append path, which allocates a writable binary and costs more than the
  # BIF itself.
  defp digits(text, fraction, sign, %{
         comma: comma,
         prefix: prefix,
         suffix: suffix,
         locale: locale
       }) do
    n = byte_size(text) - fraction
    text = decimal(text, n, fraction, locale.decimal)

    cond do
      comma -> grouped(text, n, sign, prefix, suffix, locale)
      sign == "" and prefix == "" and suffix == "" -> text
      true -> <<0::size(0), sign::binary, prefix::binary, text::binary, suffix::binary>>
    end
  end

  defp decimal(text, _n, 0, _decimal), do: text
  defp decimal(text, _n, _fraction, "."), do: text

  defp decimal(text, n, _fraction, decimal) do
    <<integer::binary-size(^n), ?., decimals::binary>> = text
    <<0::size(0), integer::binary, decimal::binary, decimals::binary>>
  end

  # Threes from the right, up to the 15 digits of a double below 2⁵³ but its largest,
  # one match and one build per size; any other grouping, and a longer integer, by §2's
  # path.
  defp grouped(text, n, sign, prefix, suffix, %{grouping: [3]}) when n <= 3,
    do: <<0::size(0), sign::binary, prefix::binary, text::binary, suffix::binary>>

  defp grouped(text, n, sign, prefix, suffix, %{grouping: [3], thousands: s}) when n <= 6 do
    h = n - 3
    <<a::binary-size(^h), b::binary-size(3), rest::binary>> = text

    <<0::size(0), sign::binary, prefix::binary, a::binary, s::binary, b::binary, rest::binary,
      suffix::binary>>
  end

  defp grouped(text, n, sign, prefix, suffix, %{grouping: [3], thousands: s}) when n <= 9 do
    h = n - 6
    <<a::binary-size(^h), b::binary-size(3), c::binary-size(3), rest::binary>> = text

    <<0::size(0), sign::binary, prefix::binary, a::binary, s::binary, b::binary, s::binary,
      c::binary, rest::binary, suffix::binary>>
  end

  defp grouped(text, n, sign, prefix, suffix, %{grouping: [3], thousands: s}) when n <= 12 do
    h = n - 9

    <<a::binary-size(^h), b::binary-size(3), c::binary-size(3), d::binary-size(3), rest::binary>> =
      text

    <<0::size(0), sign::binary, prefix::binary, a::binary, s::binary, b::binary, s::binary,
      c::binary, s::binary, d::binary, rest::binary, suffix::binary>>
  end

  defp grouped(text, n, sign, prefix, suffix, %{grouping: [3], thousands: s}) when n <= 15 do
    h = n - 12

    <<a::binary-size(^h), b::binary-size(3), c::binary-size(3), d::binary-size(3),
      e::binary-size(3), rest::binary>> = text

    <<0::size(0), sign::binary, prefix::binary, a::binary, s::binary, b::binary, s::binary,
      c::binary, s::binary, d::binary, s::binary, e::binary, rest::binary, suffix::binary>>
  end

  defp grouped(text, n, sign, prefix, suffix, locale) do
    <<integer::binary-size(^n), rest::binary>> = text
    sign <> prefix <> group(integer, :infinity, locale) <> rest <> suffix
  end

  # -- grouping, padding, alignment ----------------------------------------------------

  defp assemble(format, prefix, digits, suffix) do
    digits =
      if format.comma and not format.zero,
        do: group(digits, :infinity, format.locale),
        else: digits

    length = String.length(prefix) + String.length(digits) + String.length(suffix)
    pad = if format.width && length < format.width, do: format.width - length, else: 0

    # With zero fill the grouping is applied after padding, within the width.
    {digits, pad} =
      if format.comma and format.zero do
        limit = if pad > 0, do: format.width - String.length(suffix), else: :infinity
        {group(String.duplicate("0", pad) <> digits, limit, format.locale), 0}
      else
        {digits, pad}
      end

    case format.align do
      "<" ->
        prefix <> digits <> suffix <> fill(format, pad)

      "=" ->
        prefix <> fill(format, pad) <> digits <> suffix

      "^" ->
        half = div(pad, 2)
        fill(format, half) <> prefix <> digits <> suffix <> fill(format, pad - half)

      _right ->
        fill(format, pad) <> prefix <> digits <> suffix
    end
  end

  defp fill(_format, 0), do: ""
  defp fill(format, n), do: String.duplicate(format.fill, n)

  # d3's `formatGroup`: groups from the right, the sizes used in turn and again from the
  # first; with a finite width the groups shrink so the grouped digits fit it.
  defp group(digits, _width, %{grouping: []}), do: digits

  defp group(digits, width, %{grouping: [g | _] = grouping, thousands: thousands}) do
    digits
    |> groups(byte_size(digits), g, grouping, 1, 0, width, [])
    |> Enum.join(thousands)
  end

  defp groups(_digits, i, _g, _grouping, _j, _length, _width, acc) when i <= 0, do: acc

  defp groups(digits, i, g, grouping, j, length, width, acc) do
    g = if width != :infinity and length + g + 1 > width, do: max(1, width - length), else: g
    i = i - g
    start = max(i, 0)
    acc = [binary_part(digits, start, i + g - start) | acc]
    length = length + g + 1

    if width != :infinity and length > width do
      acc
    else
      next = Enum.at(grouping, rem(j, length(grouping)))
      groups(digits, i, next, grouping, j + 1, length, width, acc)
    end
  end

  # -- the types, over the magnitude ---------------------------------------------------

  # `{digits, si_exponent}`. An integer keeps its exact digits under the integer types,
  # and is a double under the others, infinity past a double's range.
  defp body(type, value, _p) when type in ~w(d b o x X) and is_integer(value),
    do: {integer(type, abs(value)), 0}

  defp body(type, value, _p) when type in ~w(d b o x X), do: {integer(type, round(abs(value))), 0}

  defp body(_type, value, _p) when is_integer(value) and abs(value) > @max_float,
    do: {@infinity, 0}

  defp body(type, value, p), do: float_body(type, abs(value) * 1.0, p)

  defp integer("d", n), do: Integer.to_string(n)
  defp integer("b", n), do: Integer.to_string(n, 2)
  defp integer("o", n), do: Integer.to_string(n, 8)
  defp integer("x", n), do: n |> Integer.to_string(16) |> String.downcase()
  defp integer("X", n), do: Integer.to_string(n, 16)

  defp float_body("%", x, p), do: {percent(x, p, &fixed/2), 0}
  defp float_body("p", x, p), do: {percent(x, p, &rounded/2), 0}
  defp float_body("f", x, p), do: {fixed(x, p), 0}
  defp float_body("e", x, p), do: {exponential(x, p), 0}
  defp float_body("g", x, p), do: {general(x, p), 0}
  defp float_body("r", x, p), do: {rounded(x, p), 0}
  defp float_body("s", x, p), do: prefix_auto(x, p)

  # A hundred times a magnitude past a double's range is JavaScript's infinity.
  defp percent(x, _p, _write) when x > @max_float / 100, do: @infinity
  defp percent(x, p, write), do: write.(x * 100, p)

  # Past 2⁵³ a double is an integer, written from its exact digits: the BIF writes at most
  # 256 characters, and a double past 10²⁵⁵ has more.
  defp fixed(x, p) when x >= @exact, do: Integer.to_string(trunc(x)) <> point_zeros(p)
  defp fixed(x, p), do: :erlang.float_to_binary(x, decimals: p)

  defp point_zeros(0), do: ""
  defp point_zeros(p), do: "." <> zeros(p)

  # JavaScript's `toExponential(p)`: `d.ddde+X`, the exponent unpadded.
  defp exponential(x, p) do
    {coefficient, exponent} = decimal_parts(x, p + 1)
    mantissa(coefficient) <> "e" <> exponent_text(exponent)
  end

  defp mantissa(<<first, rest::binary>>) when rest != "", do: <<first, ?.>> <> rest
  defp mantissa(coefficient), do: coefficient

  defp exponent_text(e) when e < 0, do: "-" <> Integer.to_string(-e)
  defp exponent_text(e), do: "+" <> Integer.to_string(e)

  # JavaScript's `toPrecision(p)`: exponential when the exponent is below −6 or at least
  # `p`, fixed with `p` significant digits otherwise.
  defp general(x, p) do
    {coefficient, exponent} = decimal_parts(x, p)

    cond do
      exponent < -6 or exponent >= p ->
        mantissa(coefficient) <> "e" <> exponent_text(exponent)

      exponent >= 0 ->
        point(coefficient, exponent + 1)

      true ->
        "0." <> zeros(-exponent - 1) <> coefficient
    end
  end

  # d3's `formatRounded`: `p` significant digits in plain notation.
  defp rounded(x, p) do
    {coefficient, exponent} = decimal_parts(x, p)
    n = byte_size(coefficient)

    cond do
      exponent < 0 -> "0." <> zeros(-exponent - 1) <> coefficient
      n > exponent + 1 -> point(coefficient, exponent + 1)
      true -> coefficient <> zeros(exponent - n + 1)
    end
  end

  # d3's `formatPrefixAuto`: the mantissa under the SI prefix of the value's thousands
  # exponent (a multiple of 3 in [−24, 24]), and that exponent.
  defp prefix_auto(x, p) do
    {coefficient, exponent} = decimal_parts(x, p)
    si = (exponent |> Integer.floor_div(3) |> max(-8) |> min(8)) * 3
    i = exponent - si + 1
    n = byte_size(coefficient)

    mantissa =
      cond do
        i == n -> coefficient
        i > n -> coefficient <> zeros(i - n)
        i > 0 -> point(coefficient, i)
        # Below a yocto: the digits that fit, as many as needed when none does.
        true -> "0." <> zeros(-i) <> elem(decimal_parts(x, max(0, p + i - 1)), 0)
      end

    {mantissa, si}
  end

  defp point(coefficient, i) do
    <<int::binary-size(^i), fraction::binary>> = coefficient
    if fraction == "", do: int, else: int <> "." <> fraction
  end

  defp zeros(n) when n > 0, do: String.duplicate("0", n)
  defp zeros(_n), do: ""

  # d3's `formatDecimalParts`: the `p` significant digits of `x` (no point) and its decimal
  # exponent, as JavaScript's `toExponential(p − 1)` gives them, a tie rounded away from
  # zero on the double's exact value; `p` 0 is `toExponential()`, the shortest digits that
  # read back as `x`.
  defp decimal_parts(+0.0, p), do: {zeros(max(p, 1)), 0}
  defp decimal_parts(x, 0), do: shortest(x)

  defp decimal_parts(x, p) do
    e0 = exponent10(x)
    decimals = p - 1 - e0

    digits =
      cond do
        decimals > 253 ->
          # So far below 1 that no tie can fall at `p` digits: the scientific digits are exact.
          x |> :erlang.float_to_binary(scientific: p - 1) |> scientific_digits()

        decimals >= 0 ->
          x
          |> :erlang.float_to_binary(decimals: decimals)
          |> String.replace(".", "")
          |> String.trim_leading("0")

        true ->
          # An integer part rounded to a power of ten, its fraction only breaking a tie,
          # which an exact half already rounds away from zero.
          unit = Integer.pow(10, -decimals)
          n = trunc(x)
          q = div(n, unit)
          Integer.to_string(if 2 * rem(n, unit) >= unit, do: q + 1, else: q)
      end

    # Rounding up to the next power of ten gives one digit more, a zero.
    if byte_size(digits) > p,
      do: {binary_part(digits, 0, p), e0 + 1},
      else: {digits, e0}
  end

  # The decimal exponent of a positive double: 17 significant digits never round it up to
  # the next power of ten.
  defp exponent10(x) do
    [_mantissa, exponent] = x |> :erlang.float_to_binary(scientific: 16) |> String.split("e")
    String.to_integer(exponent)
  end

  defp scientific_digits(text) do
    [mantissa, _exponent] = String.split(text, "e")
    String.replace(mantissa, ".", "")
  end

  # The shortest digits that read back as `x`, and their exponent.
  defp shortest(x) do
    {mantissa, shift} =
      case String.split(:erlang.float_to_binary(x, [:short]), "e") do
        [mantissa, exponent] -> {mantissa, String.to_integer(exponent)}
        [mantissa] -> {mantissa, 0}
      end

    [int, fraction] = String.split(mantissa, ".")
    all = String.trim_leading(int <> fraction, "0")
    leading = byte_size(int <> fraction) - byte_size(all)
    exponent = byte_size(int) - 1 - leading + shift

    case String.trim_trailing(all, "0") do
      "" -> {"0", exponent}
      digits -> {digits, exponent}
    end
  end

  # -- trimming ------------------------------------------------------------------------

  # d3's `formatTrim`: the insignificant zeros after the point dropped, and the point when
  # nothing follows it, stopping at the first character that is no digit (an exponent).
  defp trim(text), do: trim(text, 1, -1, -1, byte_size(text))

  defp trim(text, i, i0, i1, n) when i < n do
    case :binary.at(text, i) do
      ?. ->
        trim(text, i + 1, i, i, n)

      ?0 ->
        trim(text, i + 1, if(i0 == 0, do: i, else: i0), i, n)

      d when d in ?1..?9 ->
        trim(text, i + 1, if(i0 > 0, do: 0, else: i0), i1, n)

      _other ->
        cut(text, i0, i1)
    end
  end

  defp trim(text, _i, i0, i1, _n), do: cut(text, i0, i1)

  defp cut(text, i0, i1) when i0 > 0,
    do: binary_part(text, 0, i0) <> binary_part(text, i1 + 1, byte_size(text) - i1 - 1)

  defp cut(text, _i0, _i1), do: text
end
