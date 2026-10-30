defmodule Macaw.Data.Table.Column do
  @moduledoc false
  # One table column's storage (spec/01 §1.1): a type's values packed into Arrow's own
  # buffers where the values allow it, kept as a list where they don't. Packing never
  # changes a value: every form reads back values `==` to those given.
  #
  # Every buffer is little-endian, and every bitmap least-significant-bit first, as Arrow
  # numbers bits: value i is bit (i rem 8) of byte (i div 8), its padding bits 0. A slot
  # whose value is missing holds zeros. Each form, and its Arrow equivalent:
  #
  #   {:int64, data, validity}                  int64
  #   {:float64, data, validity}                float64
  #   {:integral, data, validity, integral}     `macaw.integral`, a struct of the float64
  #                                             values (first) and a bool child, the
  #                                             bitmap of the slots that were integers
  #   {:union, types, offsets, {ints, ints_validity}, floats}
  #                                             a dense union of int64 (type id 0) and
  #                                             float64 (type id 1): per slot an int8 type
  #                                             id and an int32 offset into that child; a
  #                                             missing value is a missing int64 slot
  #   {:utc, us, validity, precision}           timestamp[us, UTC]
  #   {:zoned, us, validity, precision, zones, codes}
  #                                             `macaw.zoned`: UTC microseconds, and an
  #                                             int32 code per value into zones, a tuple of
  #                                             {time_zone, zone_abbr, utc_offset,
  #                                             std_offset}, in first-appearance order
  #   {:naive, us, validity, precision}         timestamp[us] with no zone: wall-clock
  #                                             microseconds since 1970-01-01 00:00:00
  #   {:date, days, validity}                   date32: int32 days since 1970-01-01
  #   {:text, offsets, data, validity}          utf8: n + 1 int32 offsets into data,
  #                                             every string valid UTF-8
  #   {:binary, offsets, data, validity}        binary: the same, a string not UTF-8
  #   {:dictionary, codes, validity, {offsets, data}, booleans}
  #                                             dictionary<int32, utf8>: an int32 code per
  #                                             value into a text column of the distinct
  #                                             strings, in first-appearance order;
  #                                             booleans `nil`, or {kinds, values} bitmaps
  #                                             of the slots holding a boolean and its
  #                                             value: `macaw.category`, a struct of the
  #                                             dictionary (first) and a bool child
  #   {:bool, values, validity}                 bool: the values a bitmap
  #   {:list, values}                           the values as given (`:term`); a
  #                                             category's atom as its string
  #
  # A time's precision, the microsecond's second element, is an integer 0..6 when every
  # value shares it (Arrow field metadata), else a binary of one byte per value (a uint8
  # struct field: `macaw.zoned`'s, or `macaw.precise`'s beside a UTC or naive instant).

  import Bitwise

  alias Macaw.Data.Schema

  @typedoc "A column's storage, one of the forms above."
  @type t :: tuple()

  @s64_min -0x8000000000000000
  @s64_max 0x7FFFFFFFFFFFFFFF
  # A float64 holds every integer within ±2^53 exactly.
  @exact 0x20000000000000
  @s32_max 0x7FFFFFFF
  @utc {"Etc/UTC", "UTC", 0, 0}

  defguardp exact?(v) when is_integer(v) and v >= -@exact and v <= @exact
  defguardp s64?(v) when is_integer(v) and v >= @s64_min and v <= @s64_max

  # -- packing ----------------------------------------------------------------------------

  @doc false
  @spec pack(atom(), [term()], term()) :: {:ok, t()} | {:error, [{list(), term()}, ...]}
  def pack(:number, values, name) do
    case number_form(values, false, false, false) do
      :fault -> {:error, faults(values, name, &is_number/1, :number)}
      form -> {:ok, number(form, values)}
    end
  end

  def pack(:time, values, name) do
    case time_form(values, nil) do
      :fault -> {:error, faults(values, name, &time?/1, :time)}
      form -> {:ok, time(form, values)}
    end
  end

  def pack(:point, values, name) do
    point? = &match?({lon, lat} when is_number(lon) and is_number(lat), &1)

    case faults(values, name, point?, :point) do
      [] -> {:ok, {:list, values}}
      faults -> {:error, faults}
    end
  end

  def pack(:color, values, name) do
    case faults(values, name, &Schema.color?/1, :color) do
      [] -> {:ok, {:list, values}}
      faults -> {:error, faults}
    end
  end

  def pack(:text, values, _name) do
    case text(values, <<0::32>>, [], 0, true) do
      {offsets, data, last, true} when last <= @s32_max ->
        {:ok, {:text, offsets, data, validity(values)}}

      {offsets, data, last, false} when last <= @s32_max ->
        {:ok, {:binary, offsets, data, validity(values)}}

      _ ->
        {:ok, {:list, values}}
    end
  end

  def pack(:category, values, _name),
    do: {:ok, category(category_form(values, false, false), values)}

  def pack(_type, values, _name), do: {:ok, {:list, values}}

  defp faults(values, name, ok?, type) do
    for {v, i} <- Enum.with_index(values), v != nil, not ok?.(v), do: {[name, i], {:type, type}}
  end

  # -- numbers ----------------------------------------------------------------------------

  # The narrowest faithful form of a number column, in one pass: int64 when every value is
  # an integer that fits, float64 when every one is a float, integral when both and every
  # integer is exact as a float, a union when one isn't, a list past int64; `:fault` for a
  # value that is not a number.
  defp number_form([], ints?, floats?, wide?) do
    cond do
      not floats? -> :int64
      not ints? -> :float64
      wide? -> :union
      true -> :integral
    end
  end

  defp number_form([nil | rest], i, f, w), do: number_form(rest, i, f, w)
  defp number_form([v | rest], _i, f, w) when exact?(v), do: number_form(rest, true, f, w)
  defp number_form([v | rest], _i, f, _w) when s64?(v), do: number_form(rest, true, f, true)
  defp number_form([v | rest], i, _f, w) when is_float(v), do: number_form(rest, i, true, w)

  defp number_form([v | rest], _i, _f, _w) when is_integer(v),
    do: if(Enum.all?(rest, &(is_nil(&1) or is_number(&1))), do: :list, else: :fault)

  defp number_form(_values, _i, _f, _w), do: :fault

  defp number(:int64, values),
    do: {:int64, for(v <- values, into: <<>>, do: <<v || 0::signed-little-64>>), validity(values)}

  defp number(:float64, values),
    do:
      {:float64, for(v <- values, into: <<>>, do: <<v || 0.0::float-little-64>>),
       validity(values)}

  defp number(:integral, values) do
    data = for v <- values, into: <<>>, do: <<(v || 0) / 1::float-little-64>>
    {:integral, data, validity(values), bitmap(values, &is_integer/1)}
  end

  defp number(:union, values) do
    {types, offsets, ints, floats} = union(values, <<>>, <<>>, <<>>, <<>>, 0, 0)
    ints_validity = values |> Enum.reject(&is_float/1) |> validity()
    {:union, types, offsets, {ints, ints_validity}, floats}
  end

  defp number(:list, values), do: {:list, values}

  # A dense union in one pass: each slot's type id and offset, and each child's values.
  defp union([], types, offsets, ints, floats, _ni, _nf), do: {types, offsets, ints, floats}

  defp union([v | rest], types, offsets, ints, floats, ni, nf) when is_float(v) do
    union(
      rest,
      <<types::binary, 1>>,
      <<offsets::binary, nf::signed-little-32>>,
      ints,
      <<floats::binary, v::float-little-64>>,
      ni,
      nf + 1
    )
  end

  defp union([v | rest], types, offsets, ints, floats, ni, nf) do
    union(
      rest,
      <<types::binary, 0>>,
      <<offsets::binary, ni::signed-little-32>>,
      <<ints::binary, v || 0::signed-little-64>>,
      floats,
      ni + 1,
      nf
    )
  end

  # -- times ------------------------------------------------------------------------------

  defp time?(%DateTime{}), do: true
  defp time?(%NaiveDateTime{}), do: true
  defp time?(%Date{}), do: true
  defp time?(_), do: false

  # Which kind of time every value is, `DateTime`, `NaiveDateTime` or `Date`, each in the
  # ISO calendar; `:list` when kinds or calendars mix; `:fault` for a value not a time.
  defp time_form([], kind), do: kind || DateTime
  defp time_form([nil | rest], kind), do: time_form(rest, kind)

  defp time_form([%module{calendar: Calendar.ISO} | rest], kind)
       when module in [DateTime, NaiveDateTime, Date] and (kind == nil or kind == module),
       do: time_form(rest, module)

  defp time_form([v | rest], _kind) do
    if time?(v) and Enum.all?(rest, &(is_nil(&1) or time?(&1))), do: :list, else: :fault
  end

  defp time(DateTime, values) do
    {us, precision, codes, zones} = datetimes(values, <<>>, <<>>, <<>>, %{}, nil)

    case Map.keys(zones) do
      keys when keys in [[], [@utc]] ->
        {:utc, us, validity(values), precision}

      _ ->
        zones = zones |> Enum.sort_by(&elem(&1, 1)) |> Enum.map(&elem(&1, 0)) |> List.to_tuple()
        {:zoned, us, validity(values), precision, zones, codes}
    end
  end

  defp time(NaiveDateTime, values) do
    {us, precision} = naives(values, <<>>, <<>>, nil)
    {:naive, us, validity(values), precision}
  end

  defp time(Date, values) do
    days = for d <- values, into: <<>>, do: <<if(d, do: date_days(d), else: 0)::signed-little-32>>
    {:date, days, validity(values)}
  end

  defp time(:list, values), do: {:list, values}

  # A `DateTime` column in one pass: each value's UTC microseconds, precision and zone
  # code, the zones numbered as they first appear. `uniform` is the precision every value
  # so far shares, `:mixed` once two differ.
  defp datetimes([], us, precisions, codes, zones, uniform),
    do: {us, precision(uniform, precisions), codes, zones}

  defp datetimes([nil | rest], us, precisions, codes, zones, uniform),
    do:
      datetimes(
        rest,
        <<us::binary, 0::64>>,
        <<precisions::binary, 0>>,
        <<codes::binary, 0::32>>,
        zones,
        uniform
      )

  defp datetimes([t | rest], us, precisions, codes, zones, uniform) do
    zone = {t.time_zone, t.zone_abbr, t.utc_offset, t.std_offset}

    {code, zones} =
      case zones do
        %{^zone => code} -> {code, zones}
        _ -> {map_size(zones), Map.put(zones, zone, map_size(zones))}
      end

    {_, p} = t.microsecond
    instant = wall_us(t) - (t.utc_offset + t.std_offset) * 1_000_000

    datetimes(
      rest,
      <<us::binary, instant::signed-little-64>>,
      <<precisions::binary, p>>,
      <<codes::binary, code::signed-little-32>>,
      zones,
      same(uniform, p)
    )
  end

  defp naives([], us, precisions, uniform), do: {us, precision(uniform, precisions)}

  defp naives([nil | rest], us, precisions, uniform),
    do: naives(rest, <<us::binary, 0::64>>, <<precisions::binary, 0>>, uniform)

  defp naives([t | rest], us, precisions, uniform) do
    {_, p} = t.microsecond

    naives(
      rest,
      <<us::binary, wall_us(t)::signed-little-64>>,
      <<precisions::binary, p>>,
      same(uniform, p)
    )
  end

  defp same(nil, p), do: p
  defp same(p, p), do: p
  defp same(_uniform, _p), do: :mixed

  # The column's precision: the one every value shares, else one byte per value. A column
  # with no value has microsecond precision, which nothing reads.
  defp precision(nil, _precisions), do: 6
  defp precision(:mixed, precisions), do: precisions
  defp precision(p, _precisions), do: p

  # Wall-clock microseconds since 1970-01-01 00:00:00 from a time's fields, rather than
  # through `DateTime`'s own conversion: a fifth of the work per value (macaw#185).
  # `:calendar` counts days from year 0, so a time before it takes `NaiveDateTime`'s own
  # way; the two agree everywhere.
  @epoch_days :calendar.date_to_gregorian_days(1970, 1, 1)
  @day_us 86_400_000_000
  @year_zero_us -@epoch_days * @day_us
  @epoch ~N[1970-01-01 00:00:00.000000]

  defp wall_us(%{year: y} = t) when y >= 0 do
    {us, _precision} = t.microsecond
    days = :calendar.date_to_gregorian_days(y, t.month, t.day) - @epoch_days
    (days * 86_400 + t.hour * 3600 + t.minute * 60 + t.second) * 1_000_000 + us
  end

  defp wall_us(t) do
    {us, _precision} = t.microsecond

    %NaiveDateTime{
      year: t.year,
      month: t.month,
      day: t.day,
      hour: t.hour,
      minute: t.minute,
      second: t.second,
      microsecond: {us, 6}
    }
    |> NaiveDateTime.diff(@epoch, :microsecond)
  end

  defp date_days(%Date{year: y} = d) when y >= 0,
    do: :calendar.date_to_gregorian_days(y, d.month, d.day) - @epoch_days

  defp date_days(%Date{} = d), do: Date.diff(d, ~D[1970-01-01])

  # A time's fields from its wall-clock microseconds, the inverse of `wall_us/1`.
  defp fields(us) when us >= @year_zero_us do
    days = Integer.floor_div(us, @day_us)
    in_day = us - days * @day_us
    {year, month, day} = :calendar.gregorian_days_to_date(@epoch_days + days)
    seconds = div(in_day, 1_000_000)

    {year, month, day, div(seconds, 3600), rem(div(seconds, 60), 60), rem(seconds, 60),
     rem(in_day, 1_000_000)}
  end

  defp fields(us) do
    t = NaiveDateTime.add(@epoch, us, :microsecond)
    {t.year, t.month, t.day, t.hour, t.minute, t.second, elem(t.microsecond, 0)}
  end

  defp naive(us, p) do
    {year, month, day, hour, minute, second, micro} = fields(us)

    %NaiveDateTime{
      year: year,
      month: month,
      day: day,
      hour: hour,
      minute: minute,
      second: second,
      microsecond: {micro, p},
      calendar: Calendar.ISO
    }
  end

  # Built from the fields directly where the date is from year 0: the common case, and
  # the hot one when rows are read.
  defp datetime(instant, p, {time_zone, zone_abbr, utc_offset, std_offset})
       when instant + (utc_offset + std_offset) * 1_000_000 >= @year_zero_us do
    us = instant + (utc_offset + std_offset) * 1_000_000
    days = Integer.floor_div(us, @day_us)
    in_day = us - days * @day_us
    {year, month, day} = :calendar.gregorian_days_to_date(@epoch_days + days)
    seconds = div(in_day, 1_000_000)

    %DateTime{
      year: year,
      month: month,
      day: day,
      hour: div(seconds, 3600),
      minute: rem(div(seconds, 60), 60),
      second: rem(seconds, 60),
      microsecond: {rem(in_day, 1_000_000), p},
      time_zone: time_zone,
      zone_abbr: zone_abbr,
      utc_offset: utc_offset,
      std_offset: std_offset,
      calendar: Calendar.ISO
    }
  end

  defp datetime(instant, p, {time_zone, zone_abbr, utc_offset, std_offset}) do
    {year, month, day, hour, minute, second, micro} =
      fields(instant + (utc_offset + std_offset) * 1_000_000)

    %DateTime{
      year: year,
      month: month,
      day: day,
      hour: hour,
      minute: minute,
      second: second,
      microsecond: {micro, p},
      time_zone: time_zone,
      zone_abbr: zone_abbr,
      utc_offset: utc_offset,
      std_offset: std_offset,
      calendar: Calendar.ISO
    }
  end

  defp date(days) when days >= -@epoch_days do
    {year, month, day} = :calendar.gregorian_days_to_date(@epoch_days + days)
    %Date{year: year, month: month, day: day, calendar: Calendar.ISO}
  end

  defp date(days), do: Date.add(~D[1970-01-01], days)

  # -- text and categories ----------------------------------------------------------------

  # Strings as Arrow's utf8 buffers, in one pass: the offsets, the data, the last offset,
  # which must fit int32, and whether every string is valid UTF-8; `:list` at a value not
  # a binary. A missing value takes no bytes.
  #
  # Every string is valid exactly when the data is and no string starts with a
  # continuation byte (0b10xxxxxx): a boundary inside a character starts with one. So the
  # data is checked once, not each string.
  defp text([], offsets, data, at, utf8?) do
    data = IO.iodata_to_binary(:lists.reverse(data))
    {offsets, data, at, utf8? and String.valid?(data)}
  end

  defp text([nil | rest], offsets, data, at, utf8?),
    do: text(rest, <<offsets::binary, at::signed-little-32>>, data, at, utf8?)

  defp text([s | rest], offsets, data, at, utf8?) when is_binary(s) do
    at = at + byte_size(s)

    text(
      rest,
      <<offsets::binary, at::signed-little-32>>,
      [s | data],
      at,
      utf8? and not match?(<<0b10::2, _::bitstring>>, s)
    )
  end

  defp text(_values, _offsets, _data, _at, _utf8?), do: :list

  # A category column's form: booleans alone as a bitmap; strings and atoms as one
  # dictionary, an atom as the string that spells it, with any booleans beside them in a
  # side bitmap; values of any other type a list. A column with no value is a dictionary.
  defp category_form([], names?, booleans?) do
    cond do
      booleans? and not names? -> :bool
      true -> {:dictionary, booleans?}
    end
  end

  defp category_form([nil | rest], names?, booleans?),
    do: category_form(rest, names?, booleans?)

  defp category_form([v | rest], names?, _booleans?) when is_boolean(v),
    do: category_form(rest, names?, true)

  defp category_form([v | rest], _names?, booleans?) when is_binary(v) or is_atom(v),
    do: category_form(rest, true, booleans?)

  defp category_form(_values, _names?, _booleans?), do: :list

  defp category(:bool, values),
    do: {:bool, bitmap(values, &(&1 == true)), validity(values)}

  defp category({:dictionary, booleans?}, values) do
    case dictionary(values, <<>>, %{}, [], 0) do
      {codes, strings} ->
        {offsets, data, _last, true} = text(:lists.reverse(strings), <<0::32>>, [], 0, true)

        booleans =
          if booleans?, do: {bitmap(values, &is_boolean/1), bitmap(values, &(&1 == true))}

        {:dictionary, codes, validity(values), {offsets, data}, booleans}

      :invalid ->
        category(:list, values)
    end
  end

  defp category(:list, values), do: {:list, Enum.map(values, &spelled/1)}

  # A category value as the column holds it: an atom as the string that spells it, `nil`,
  # `true` and `false` as themselves.
  defp spelled(v) when is_atom(v) and not is_boolean(v) and v != nil, do: Atom.to_string(v)
  defp spelled(v), do: v

  # Each value's code, the `next` strings numbered as they first appear (`strings`, last
  # first). `seen` holds each string's code, and each atom's beside it, so an atom is
  # spelled out once. A boolean's slot holds code 0 (its value is in the side bitmap); a
  # string not valid UTF-8 is `:invalid`, since the dictionary is Arrow's utf8.
  defp dictionary([], codes, _seen, strings, _next), do: {codes, strings}

  defp dictionary([v | rest], codes, seen, strings, next) when is_boolean(v) or v == nil,
    do: dictionary(rest, <<codes::binary, 0::32>>, seen, strings, next)

  defp dictionary([v | rest], codes, seen, strings, next) when is_map_key(seen, v) do
    code = :erlang.map_get(v, seen)
    dictionary(rest, <<codes::binary, code::little-32>>, seen, strings, next)
  end

  defp dictionary([v | rest], codes, seen, strings, next) do
    s = spelled(v)

    case seen do
      %{^s => code} ->
        seen = Map.put(seen, v, code)
        dictionary(rest, <<codes::binary, code::little-32>>, seen, strings, next)

      _ ->
        if String.valid?(s) do
          seen = seen |> Map.put(s, next) |> Map.put(v, next)
          dictionary(rest, <<codes::binary, next::little-32>>, seen, [s | strings], next + 1)
        else
          :invalid
        end
    end
  end

  # -- reading ----------------------------------------------------------------------------

  @doc false
  # The `n` values of a column, in order, `nil` where one is missing.
  @spec values(t(), non_neg_integer()) :: [term()]
  def values({:list, values}, _n), do: values

  def values({:int64, data, validity}, n),
    do: gaps(for(<<v::signed-little-64 <- data>>, do: v), bits(validity, n))

  def values({:float64, data, validity}, n),
    do: gaps(for(<<v::float-little-64 <- data>>, do: v), bits(validity, n))

  def values({:integral, data, validity, integral}, n) do
    floats = for <<v::float-little-64 <- data>>, do: v
    integrals(floats, bits(integral, n), bits(validity, n))
  end

  def values({:union, types, offsets, ints, floats}, _n) do
    offsets = for <<o::signed-little-32 <- offsets>>, do: o

    for {type, o} <- Enum.zip(:binary.bin_to_list(types), offsets),
        do: slot(type, o, ints, floats)
  end

  def values({:utc, us, validity, precision}, n),
    do: times(us, bits(validity, n), precision, @utc)

  def values({:zoned, us, validity, precision, zones, codes}, n),
    do: zoned(us, bits(validity, n), precision, zones, codes)

  def values({:naive, us, validity, precision}, n),
    do: times(us, bits(validity, n), precision, nil)

  def values({:date, days, validity}, n),
    do: gaps(for(<<d::signed-little-32 <- days>>, do: date(d)), bits(validity, n))

  def values({form, offsets, data, validity}, n) when form in [:text, :binary],
    do: strings(data, for(<<o::signed-little-32 <- offsets>>, do: o), bits(validity, n))

  def values({:dictionary, codes, validity, {offsets, data}, booleans}, n) do
    offsets = for <<o::signed-little-32 <- offsets>>, do: o
    strings = data |> strings(offsets, List.duplicate(1, length(offsets) - 1)) |> List.to_tuple()

    case booleans do
      nil ->
        decode(codes, bits(validity, n), strings)

      {kinds, values} ->
        decode(codes, bits(validity, n), bits(kinds, n), bits(values, n), strings)
    end
  end

  def values({:bool, values, validity}, n),
    do: gaps(Enum.map(bits(values, n), &(&1 == 1)), bits(validity, n))

  defp gaps([v | values], [1 | bits]), do: [v | gaps(values, bits)]
  defp gaps([_ | values], [0 | bits]), do: [nil | gaps(values, bits)]
  defp gaps([], []), do: []

  defp decode(<<c::little-32, codes::binary>>, [1 | bits], strings),
    do: [elem(strings, c) | decode(codes, bits, strings)]

  defp decode(<<_::32, codes::binary>>, [0 | bits], strings),
    do: [nil | decode(codes, bits, strings)]

  defp decode(<<>>, [], _strings), do: []

  # A dictionary with booleans beside it: a slot whose kind bit is set is the boolean its
  # value bit spells.
  defp decode(<<c::little-32, codes::binary>>, [1 | bits], [0 | kinds], [_ | values], strings),
    do: [elem(strings, c) | decode(codes, bits, kinds, values, strings)]

  defp decode(<<_::32, codes::binary>>, [1 | bits], [1 | kinds], [v | values], strings),
    do: [v == 1 | decode(codes, bits, kinds, values, strings)]

  defp decode(<<_::32, codes::binary>>, [0 | bits], [_ | kinds], [_ | values], strings),
    do: [nil | decode(codes, bits, kinds, values, strings)]

  defp decode(<<>>, [], [], [], _strings), do: []

  defp integrals([f | floats], [1 | integral], [1 | bits]),
    do: [trunc(f) | integrals(floats, integral, bits)]

  defp integrals([f | floats], [0 | integral], [1 | bits]),
    do: [f | integrals(floats, integral, bits)]

  defp integrals([_ | floats], [_ | integral], [0 | bits]),
    do: [nil | integrals(floats, integral, bits)]

  defp integrals([], [], []), do: []

  # One union slot, read through its offset into its child.
  defp slot(1, o, _ints, floats) do
    <<v::float-little-64>> = binary_part(floats, o * 8, 8)
    v
  end

  defp slot(0, o, {ints, validity}, _floats) do
    if bit_at(validity, o) == 1 do
      <<v::signed-little-64>> = binary_part(ints, o * 8, 8)
      v
    end
  end

  # A time column's values, walking its buffers together: the microseconds, the validity,
  # and the precision, one for the column or a byte each. Every value is in `zone`, `nil`
  # for naive times; a zoned column's are each in the zone its code names.
  defp times(<<_::64, us::binary>>, [0 | bits], p, zone),
    do: [nil | times(us, bits, rest_precision(p), zone)]

  defp times(<<v::signed-little-64, us::binary>>, [1 | bits], p, nil),
    do: [naive(v, precision_here(p)) | times(us, bits, rest_precision(p), nil)]

  defp times(<<v::signed-little-64, us::binary>>, [1 | bits], p, zone),
    do: [datetime(v, precision_here(p), zone) | times(us, bits, rest_precision(p), zone)]

  defp times(<<>>, [], _p, _zone), do: []

  defp zoned(<<_::64, us::binary>>, [0 | bits], p, zones, <<_::32, codes::binary>>),
    do: [nil | zoned(us, bits, rest_precision(p), zones, codes)]

  defp zoned(
         <<v::signed-little-64, us::binary>>,
         [1 | bits],
         p,
         zones,
         <<c::little-32, codes::binary>>
       ),
       do: [
         datetime(v, precision_here(p), elem(zones, c))
         | zoned(us, bits, rest_precision(p), zones, codes)
       ]

  defp zoned(<<>>, [], _p, _zones, _codes), do: []

  defp precision_here(p) when is_integer(p), do: p
  defp precision_here(<<p, _::binary>>), do: p

  defp rest_precision(p) when is_integer(p), do: p
  defp rest_precision(<<_, rest::binary>>), do: rest

  # Strings by their offsets into `data`; offsets are absolute, so a slice of them reads
  # the same data.
  defp strings(data, [a, b | offsets], [1 | bits]),
    do: [binary_part(data, a, b - a) | strings(data, [b | offsets], bits)]

  defp strings(data, [_ | offsets], [0 | bits]), do: [nil | strings(data, offsets, bits)]
  defp strings(_data, [_last], []), do: []

  # -- slicing ----------------------------------------------------------------------------

  @doc false
  # The `n` values from `first`, as a column of the same form. A buffer is sliced, not
  # copied; a bitmap is shifted to start at its first bit, as Arrow's offset would.
  @spec slice(t(), non_neg_integer(), non_neg_integer()) :: t()
  def slice({:list, values}, first, n), do: {:list, Enum.slice(values, first, n)}

  def slice({form, data, validity}, first, n) when form in [:int64, :float64],
    do: {form, binary_part(data, first * 8, n * 8), slice_bits(validity, first, n)}

  def slice({:date, data, validity}, first, n),
    do: {:date, binary_part(data, first * 4, n * 4), slice_bits(validity, first, n)}

  def slice({:bool, values, validity}, first, n),
    do: {:bool, slice_bits(values, first, n), slice_bits(validity, first, n)}

  def slice({:integral, data, validity, integral}, first, n) do
    {:integral, binary_part(data, first * 8, n * 8), slice_bits(validity, first, n),
     slice_bits(integral, first, n)}
  end

  def slice({:union, types, offsets, ints, floats}, first, n),
    do:
      {:union, binary_part(types, first, n), binary_part(offsets, first * 4, n * 4), ints, floats}

  def slice({form, us, validity, precision}, first, n) when form in [:utc, :naive] do
    {form, binary_part(us, first * 8, n * 8), slice_bits(validity, first, n),
     slice_precision(precision, first, n)}
  end

  def slice({:zoned, us, validity, precision, zones, codes}, first, n) do
    {:zoned, binary_part(us, first * 8, n * 8), slice_bits(validity, first, n),
     slice_precision(precision, first, n), zones, binary_part(codes, first * 4, n * 4)}
  end

  def slice({form, offsets, data, validity}, first, n) when form in [:text, :binary] do
    {form, binary_part(offsets, first * 4, (n + 1) * 4), data, slice_bits(validity, first, n)}
  end

  def slice({:dictionary, codes, validity, dictionary, booleans}, first, n) do
    {:dictionary, binary_part(codes, first * 4, n * 4), slice_bits(validity, first, n),
     dictionary, slice_booleans(booleans, first, n)}
  end

  defp slice_booleans(nil, _first, _n), do: nil

  defp slice_booleans({kinds, values}, first, n),
    do: {slice_bits(kinds, first, n), slice_bits(values, first, n)}

  defp slice_precision(p, _first, _n) when is_integer(p), do: p
  defp slice_precision(precisions, first, n), do: binary_part(precisions, first, n)

  # -- bitmaps ----------------------------------------------------------------------------

  # A bitmap of `values`, a bit set where `bit?` holds, least-significant bit first: eight
  # values a byte, the last byte's padding 0.
  defp bitmap(values, bit?), do: bitmap(values, bit?, <<>>)

  defp bitmap([a, b, c, d, e, f, g, h | rest], bit?, acc) do
    bitmap(
      rest,
      bit?,
      <<acc::binary, bit(bit?, h)::1, bit(bit?, g)::1, bit(bit?, f)::1, bit(bit?, e)::1,
        bit(bit?, d)::1, bit(bit?, c)::1, bit(bit?, b)::1, bit(bit?, a)::1>>
    )
  end

  defp bitmap([], _bit?, acc), do: acc

  defp bitmap(tail, bit?, acc) do
    {byte, _} =
      Enum.reduce(tail, {0, 0}, fn v, {byte, i} -> {byte ||| bit(bit?, v) <<< i, i + 1} end)

    <<acc::binary, byte>>
  end

  defp bit(bit?, v), do: if(bit?.(v), do: 1, else: 0)

  # The validity bitmap, as `bitmap/2` with no function call per value.
  defp validity(values), do: validity(values, <<>>)

  defp validity([a, b, c, d, e, f, g, h | rest], acc) do
    validity(
      rest,
      <<acc::binary, valid(h)::1, valid(g)::1, valid(f)::1, valid(e)::1, valid(d)::1, valid(c)::1,
        valid(b)::1, valid(a)::1>>
    )
  end

  defp validity(tail, acc), do: bitmap(tail, &(&1 != nil), acc)

  defp valid(nil), do: 0
  defp valid(_value), do: 1

  # The first `n` bits of a bitmap, each 0 or 1, in value order.
  defp bits(_bitmap, 0), do: []

  defp bits(<<b7::1, b6::1, b5::1, b4::1, b3::1, b2::1, b1::1, b0::1, rest::binary>>, n)
       when n >= 8,
       do: [b0, b1, b2, b3, b4, b5, b6, b7 | bits(rest, n - 8)]

  defp bits(<<byte, _::binary>>, n), do: for(i <- 0..(n - 1), do: byte >>> i &&& 1)

  defp bit_at(bitmap, i), do: :binary.at(bitmap, div(i, 8)) >>> rem(i, 8) &&& 1

  # Bits `first` to `first + n - 1` as a bitmap of their own, from bit 0.
  defp slice_bits(_bitmap, _first, 0), do: <<>>

  defp slice_bits(bitmap, first, n) do
    start = div(first, 8)
    bytes = div(n + 7, 8)
    source = binary_part(bitmap, start, min(bytes + 1, byte_size(bitmap) - start))
    shifted = shift(source, rem(first, 8), bytes)

    case rem(n, 8) do
      0 ->
        shifted

      r ->
        <<whole::binary-size(^bytes - 1), last>> = shifted
        <<whole::binary, last &&& (1 <<< r) - 1>>
    end
  end

  defp shift(source, 0, bytes), do: binary_part(source, 0, bytes)

  defp shift(source, k, bytes) do
    size = byte_size(source)

    for i <- 0..(bytes - 1), into: <<>> do
      high = if i + 1 < size, do: :binary.at(source, i + 1) <<< (8 - k) &&& 0xFF, else: 0
      <<:binary.at(source, i) >>> k ||| high>>
    end
  end
end
