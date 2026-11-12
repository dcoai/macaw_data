defmodule Macaw.Data.FormatMeasureTest do
  @moduledoc """
  A field's default format, from its measure (spec/05 §6, #255). The conformance set is
  visualize's: `Visualize.Format.currency/2` by code and `Visualize.Format.duration/1,2`
  (`test/visualize/unit/currency_test.exs`, `axis_format_test.exs` and the doctests),
  `Visualize.Format.Auto`'s notations and default label (`format_auto_test.exs`,
  `axis_format_test.exs`) and `Visualize.Quantity.format/3`'s examples
  (`unit/metresis_parity_test.exs`, `quantity/facts_test.exs` and the doctests), each
  written here byte for byte as visualize writes it.
  """
  use ExUnit.Case, async: true

  alias Macaw.Data.{Error, Format}
  alias Macaw.Data.Format.Locale

  doctest Macaw.Data.Format.Measure

  defp write(measure, value, opts \\ []),
    do: Format.measure(Format.for_measure!(measure, opts), value)

  defp money(value, code, opts \\ []), do: write(%{unit: "{iso4217:#{code}}"}, value, opts)

  describe "conformance with visualize's cases" do
    @tag verifies: "format-default-conformance"
    test "Format.currency/2 by code: the minor units, the symbol before the number, else the code after it" do
      assert money(1240, "USD") == "$1,240.00"
      assert money(1240, "EUR") == "€1,240.00"
      assert money(1240, "GBP") == "£1,240.00"
      assert money(1240, "JPY") == "¥1,240"
      assert money(1240, "BHD") == "1,240.000 BHD"
      assert money(1240, "XAU") == "1,240.00 XAU"
      assert money(-9.5, "EUR") == "-€9.50"
      assert money(-0.001, "USD") == "$0.00"
      assert money(1_234_567.891, "USD", precision: 0) == "$1,234,568"
      assert money(1240, "USD", locale: Locale.english()) == "$1,240.00"
      assert money(-9.5, "JPY") == "-¥10"
    end

    @tag verifies: "format-default-conformance"
    test "Format.duration/1: the unit follows the magnitude, pairs with the next finer one when whole, else one decimal" do
      cases = [
        {45, "45s"},
        {150, "2m30s"},
        {3600, "1h"},
        {5400, "1h30m"},
        {5430, "1.5h"},
        {90_000, "1d1h"},
        {3660, "1h1m"},
        {2.5, "2.5s"},
        {0.25, "250ms"},
        {0.0005, "0.5ms"},
        {0, "0s"},
        {-90, "−1m30s"}
      ]

      for {seconds, label} <- cases,
          do: assert(write(%{unit: "s"}, seconds, style: :magnitude) == label, inspect(seconds))
    end

    @tag verifies: "format-default-conformance"
    test "Format.duration/2's compound form: two units from a second up, milliseconds and nanoseconds below" do
      cases = [
        {5040, "1h 24m"},
        {3603, "1h 3s"},
        {90_061, "1d 1h"},
        {45, "45s"},
        {172_800, "2d"},
        {59.9, "59s"},
        {0.84, "840ms"},
        {0.0005, "0.5ms"},
        {0.00125, "1.25ms"},
        {1.0e-7, "100ns"},
        {0, "0s"},
        {-0.0, "0s"},
        {-90, "-1m 30s"}
      ]

      for {seconds, label} <- cases,
          do: assert(write(%{unit: "s"}, seconds) == label, inspect(seconds))

      assert write(%{unit: "s"}, 0.0012346, precision: 3) == "1.235ms"
      assert write(%{unit: "s"}, 5430, style: :compound) == write(%{unit: "s"}, 5430)
    end

    @tag verifies: "format-default-conformance"
    test "Format.Auto: plain, grouped and SI by a domain's greatest magnitude, negatives included" do
      by = fn domain, values -> Enum.map(values, &write(%{}, &1, domain: domain)) end

      assert by.([0, 900], [0, 450, 900]) == ["0", "450", "900"]
      assert by.([0, 90_000], [0, 45_000, 90_000]) == ["0", "45,000", "90,000"]
      assert by.([0, 9_000_000], [0, 4_500_000, 9_000_000]) == ["0", "4.5M", "9M"]
      assert by.([-1500, 10], [-1500]) == ["-1,500"]
      assert by.([-2.0e9, 0], [-2.0e9]) == ["-2G"]
      assert by.([999.9, 0], [999.9]) == ["999.9"]
      assert by.([1_000_000, 0], [1_000_000]) == ["1M"]
      assert by.([], [12]) == ["12"]
    end

    @tag verifies: "format-default-conformance"
    test "Format.Auto: one prefix across an axis, grouping keeps the sign and fraction, :si per value" do
      si6 = fn v -> write(%{}, v, notation: {:si, 6}) end
      assert Enum.map([500_000, 1_000_000, 1_500_000], si6) == ["0.5M", "1M", "1.5M"]
      assert si6.(-2_500_000) == "-2.5M"
      assert write(%{}, 3.2e12, notation: {:si, 12}) == "3.2T"

      grouped = fn v -> write(%{}, v, notation: :grouped) end

      assert Enum.map([-1_234_567, 12_500.5, 100, 1000.0], grouped) == [
               "-1,234,567",
               "12,500.5",
               "100",
               "1,000"
             ]

      assert Enum.map([0.01, 1, 100, 1000, 1.0e4, 1.0e6, 2.0e9], &write(%{}, &1, notation: :si)) ==
               ["0.01", "1", "100", "1k", "10k", "1M", "2G"]
    end

    @tag verifies: "format-default-conformance"
    test "the default label: six places at most, trimmed, never -0" do
      plain = fn v -> write(%{}, v, notation: :plain) end
      assert plain.(1000.0) == "1000"
      assert plain.(1500.0) == "1500"
      assert plain.(1.0e7) == "10000000"
      assert plain.(0.00001) == "0.00001"
      assert plain.(2.0) == "2"
      assert plain.(0.1 + 0.2) == "0.3"
      assert plain.(-0.0) == "0"
      assert plain.(7) == "7"
    end

    @tag verifies: "format-default-conformance"
    test "Visualize.Quantity.format/3: 1h 24m, 840ms, $1,240.00, ¥1,240, 350°, 176.37 lb, 29.92 inHg" do
      assert write(%{unit: "s"}, 5040) == "1h 24m"
      assert write(%{unit: "s"}, 0.84) == "840ms"
      assert write(%{unit: "{iso4217:USD}"}, 1240) == "$1,240.00"
      assert write(%{unit: "{iso4217:JPY}"}, 1240) == "¥1,240"
      assert write(%{unit: "deg"}, 350, precision: 0) == "350°"
      assert write(%{unit: "kg"}, 80, system: :us) == "176.37 lb"
      assert write(%{unit: "hPa"}, 1013.25, system: :us) == "29.92 inHg"

      for value <- [0, 1, 0.84, 91.4, 1234.5, -3.25, 5040, 90_061], precision <- [0, 2] do
        expected = :erlang.float_to_binary(value * 1.0, decimals: precision)
        assert write(%{}, value, precision: precision) == expected
        assert write(%{quantity: :count}, value) == visualize_count(value)
      end
    end
  end

  # visualize's count: rounded, grouped in threes.
  defp visualize_count(value) do
    n = round(value)

    digits =
      n
      |> abs()
      |> Integer.to_string()
      |> String.reverse()
      |> String.graphemes()
      |> Enum.chunk_every(3)

    grouped = digits |> Enum.map(&Enum.join/1) |> Enum.join(",") |> String.reverse()
    if n < 0, do: "-" <> grouped, else: grouped
  end

  describe "a measure's default" do
    @tag verifies: "format-default-measure"
    test "a ratio is a percent from any dimensionless unit; a count is rounded and grouped" do
      assert write(%{quantity: :ratio}, 0.914) == "91.40%"
      assert write(%{unit: "%"}, 91.4) == "91.40%"
      assert write(%{unit: "1", quantity: :ratio}, 0.5, precision: 0) == "50%"
      assert write(%{quantity: :count}, 1240.4) == "1,240"
      assert write(%{unit: "{request}"}, 1_234_567) == "1,234,567"
    end

    @tag verifies: "format-default-measure"
    test "a quantity with a family is rescaled within it, decimal and binary bytes apart, under each system" do
      assert write(%{unit: "By"}, 1_500_000) == "1.50 MB"
      assert write(%{unit: "By"}, 999) == "999.00 B"
      assert write(%{unit: "kBy"}, 0.5) == "500.00 B"
      assert write(%{unit: "MiBy"}, 3) == "3.00 MiB"
      assert write(%{unit: "KiBy"}, 3072) == "3.00 MiB"
      assert write(%{unit: "By/s"}, 2_500_000) == "2.50 MB/s"
      assert write(%{unit: "m"}, 1500) == "1.50 km"
      assert write(%{unit: "m"}, 1500, system: :us) == "4921.26 ft"
      assert write(%{unit: "m"}, 5000, system: :us) == "3.11 mi"
      assert write(%{unit: "Cel"}, 21.5) == "21.50 °C"
      assert write(%{unit: "Cel"}, 21.5, system: :us) == "70.70 °F"
      assert write(%{unit: "By"}, 0) == "0.00 B"
      assert write(%{unit: "bar"}, 3) == "3.00 bar"
    end

    @tag verifies: "format-default-measure"
    test "a unit alone is written to its precision with its suffix, by the suffix rules" do
      assert write(%{unit: "rad/s"}, 3.5) == "3.50 rad/s"
      assert write(%{unit: "{request}/s"}, 12) == "12.00/s"
      assert write(%{unit: "W"}, 1500) == "1.50 kW"
      assert write(%{unit: "deg"}, 12.25, precision: 1) == "12.3°"
      assert write(%{unit: "W"}, -0.001) == "0.00 W"
    end

    @tag verifies: "format-default-measure"
    test "a d3 format overrides the number only; a value that is no number is NaN" do
      assert write(%{unit: "By"}, 1_500_000, format: ",.0f") == "1,500,000 B"
      assert write(%{unit: "{iso4217:USD}"}, 1240, format: "$,.0f") == "$1,240"
      assert write(%{quantity: :ratio}, 0.914, format: ".1%") == "91.4%"
      assert write(%{unit: "%"}, 91.4, format: ".1%") == "91.4%"
      assert write(%{unit: "%"}, 91.4, format: ".1f") == "91.4%"
      assert write(%{unit: "s"}, 5040, format: ",d") == "5,040 s"
      assert write(%{}, 1234.5, format: ".2s") == "1.2k"

      for value <- [nil, "12", :x, [1]], do: assert(write(%{unit: "By"}, value) == "NaN")
      assert write(%{}, nil, locale: Locale.new!(nan: "—")) == "—"
    end

    @tag verifies: "format-default-measure"
    test "another locale writes the separators, symbols and minus" do
      de = Locale.new!(decimal: ",", thousands: ".", symbols: %{"EUR" => "€"}, minus: "−")
      assert money(-1234.5, "EUR", locale: de) == "−€1.234,50"
      assert money(1234.5, "USD", locale: de) == "1.234,50 USD"
      assert write(%{unit: "By"}, 1_500_000, locale: de) == "1,50 MB"
      assert write(%{}, -1_234_567.5, notation: :grouped, locale: de) == "−1.234.567,5"
      assert write(%{quantity: :count}, 1_234_567, locale: de) == "1.234.567"
    end
  end

  describe "faults" do
    @tag verifies: "format-default-faults"
    test "each fault at its key" do
      assert Format.for_measure(%{unit: "By", quantity: :duration}) ==
               {:error, [{[:measure], {:quantity, :duration, "By"}}]}

      assert Format.for_measure(%{unit: "zz"}) |> elem(1) |> hd() |> elem(0) == [:measure]

      assert Format.for_measure(%{quantity: :speedy}) ==
               {:error, [{[:measure], {:unknown_quantity, :speedy}}]}

      assert Format.for_measure(unit: "s") == {:error, [{[:measure], {:type, :measure}}]}
      assert Format.for_measure(%URI{}) == {:error, [{[:measure], {:type, :measure}}]}

      assert Format.for_measure(%{},
               precision: 21,
               system: :imperial,
               style: :long,
               notation: :wide,
               domain: [1 | 2],
               format: "..2f",
               locale: :fr,
               typo: 1
             ) == {:error, [{[:typo], :unknown_key}]}

      assert {:error, faults} =
               Format.for_measure(%{},
                 precision: 21,
                 system: :imperial,
                 style: :long,
                 notation: :wide,
                 domain: [1 | 2],
                 format: "..2f",
                 locale: :fr
               )

      assert Enum.map(faults, &elem(&1, 0)) == [
               [:precision],
               [:system],
               [:style],
               [:notation],
               [:domain],
               [:locale],
               [:format]
             ]

      assert {[:system], {:unknown_system, :imperial}} in faults
      assert {[:format], {:specifier, "..2f"}} in faults
      assert {[:style], {:enum, [:compound, :magnitude]}} in faults
      assert Format.for_measure(%{}, [1]) == {:error, [{[], {:type, :keyword}}]}

      assert Format.for_measure(%{}, precision: 2.0) ==
               {:error, [{[:precision], {:type, :precision}}]}
    end

    @tag verifies: "format-default-faults"
    test "for_measure!/2 raises them, worded" do
      error =
        assert_raise Error, fn ->
          Format.for_measure!(%{unit: "By", quantity: :duration}, precision: -1)
        end

      assert error.reason == [
               {[:measure], {:quantity, :duration, "By"}},
               {[:precision], {:type, :precision}}
             ]

      assert Exception.message(error) ==
               "not a measure's format: measure: By does not measure duration; precision: must be an integer from 0 to 20"

      error = assert_raise Error, fn -> Format.for_measure!(:none, system: :x, domain: :all) end
      refute Exception.message(error) =~ "{:"
    end
  end
end
