defmodule Macaw.Data.FormatTest do
  @moduledoc """
  A format is data, the d3-format notation and the locale (spec/05 §1 to §3, #251).

  The conformance set is visualize's: every case of `Visualize.Format.formatter/1` in
  visualize's `test/visualize/axis_format_test.exs` (outputs from d3-format's
  documentation and reference implementation), copied as written there, each written
  here byte for byte as visualize writes it.
  """
  use ExUnit.Case, async: true

  alias Macaw.Data.{Error, Format}
  alias Macaw.Data.Format.Locale

  doctest Format
  doctest Locale

  # visualize's `Format.formatter/1` cases, in its order.
  @conformance [
    {".2s", 1_234_567, "1.2M"},
    {".3s", 42_000_000, "42.0M"},
    {".3s", 0.000042, "42.0µ"},
    {"s", 0, "0.00000"},
    {",.0f", 1_234_567, "1,234,567"},
    {".2f", 3.14159, "3.14"},
    {"f", 2, "2.000000"},
    {".0f", 2.5, "3"},
    {".1%", 0.123, "12.3%"},
    {"+.1%", 0.123, "+12.3%"},
    {".0%", -0.5, "-50%"},
    {"p", 0.123456, "12.3456%"},
    {".2e", 1234, "1.23e+3"},
    {".2e", 0.001234, "1.23e-3"},
    {"e", 0, "0.000000e+0"},
    {"d", 42.7, "43"},
    {",d", 1_234_567, "1,234,567"},
    {"d", -3, "-3"},
    {".3r", 123.456, "123"},
    {".3r", 0.00123456, "0.00123"},
    {".2r", 12_345, "12000"},
    {".3g", 123_456, "1.23e+5"},
    {".3g", 12.3456, "12.3"},
    {".3g", 0.000001234, "0.00000123"},
    {".3g", 0.0000001234, "1.23e-7"},
    {"g", 1234.5, "1234.50"},
    {"", 1234.5, "1234.5"},
    {"", 0.1 + 0.2, "0.3"},
    {"", 1_000_000_000_000_000, "1e+15"},
    {"~s", 1_500_000, "1.5M"},
    {"~f", 1.5, "1.5"},
    {"~f", 2, "2"},
    {".3~g", 1.10, "1.1"},
    {"n", 1234.5, "1,234.50"},
    {"$.2f", 1234.5, "$1234.50"},
    {"$,.2f", 1234.5, "$1,234.50"},
    {"($.2f", -12.5, "($12.50)"},
    {"($.2f", 12.5, "$12.50"},
    {"+d", 5, "+5"},
    {"+d", -5, "-5"},
    {" d", 5, " 5"},
    {" d", -5, "-5"},
    {"08.2f", 3.14159, "00003.14"},
    {"08.2f", -3.14159, "-0003.14"},
    {"8.2f", 3.14159, "    3.14"},
    {"<8.2f", 3.14159, "3.14    "},
    {"^8.2f", 3.14159, "  3.14  "},
    {"^9.2f", 3.14159, "  3.14   "},
    {"*>8d", 42, "******42"},
    {"*=+8d", 42, "+*****42"},
    {"010,.0f", 1_234_567, "01,234,567"},
    {"012,d", 1_234_567, "0,001,234,567"},
    {"b", 5, "101"},
    {"#b", 5, "0b101"},
    {"o", 8, "10"},
    {"#o", 8, "0o10"},
    {"x", 255, "ff"},
    {"#x", 255, "0xff"},
    {"#X", 255, "0xFF"},
    {"c", 42, "42"},
    {"5c", "ab", "   ab"},
    {"+.1f", -0.01, "-0.0"},
    {".1f", -0.01, "0.0"},
    {".2s", 0.0000000000000000000000001, "0.1y"}
  ]

  defp write(specifier, value), do: Format.number(Format.parse!(specifier), value)

  describe "conformance with visualize's d3-format cases" do
    @tag verifies: "format-notation-conformance"
    test "every case writes byte for byte what visualize writes" do
      failures =
        for {specifier, value, expected} <- @conformance,
            (got = write(specifier, value)) != expected,
            do: {specifier, value, expected, got}

      assert failures == []
      assert length(@conformance) == 64
    end

    @tag verifies: "format-notation-conformance"
    test "precision is clamped, NaN is padded, and the two invalid specifiers are refused" do
      assert write(".30f", 1) == "1." <> String.duplicate("0", 20)
      assert write(".0r", 123.456) == "100"
      assert write(".2f", nil) == "NaN"
      assert write(">6.2f", nil) == "   NaN"
      assert Format.parse("..2f") == {:error, [{[], {:specifier, "..2f"}}]}
      assert Format.parse("q!") == {:error, [{[], {:specifier, "q!"}}]}
    end

    @tag verifies: "format-notation-conformance"
    test "visualize's smoke case: .2s of a million writes M" do
      assert write(".2s", 1_234_567) =~ "M"
    end
  end

  describe "the digits" do
    @tag verifies: "format-notation-digits"
    test "a tie rounds away from zero on the exact double, as JavaScript does" do
      # 0.125, 125 and 2.5 are exact doubles at a tie; 1.005 is just below one.
      assert write(".1e", 0.125) == "1.3e-1"
      assert write(".2s", 125) == "130"
      assert write(".0e", 2.5) == "3e+0"
      assert write(".2r", 0.125) == "0.13"
      assert write(".2f", 0.125) == "0.13"
      assert write(".2f", 1.005) == "1.00"
      assert write(".3g", 0.0001255) == "0.000125"
      assert write(".2r", 99_999) == "100000"
      assert write(".2r", 12_500) == "13000"
      assert write(".2r", 12_500.000001) == "13000"
      assert write(".1r", 9.96) == "10"
      assert write(".2s", 999_999) == "1.0M"
      assert write(".1s", 1.234e-25) == "0.1234y"
    end

    @tag verifies: "format-notation-digits"
    test "a negative that rounds to zero and negative zero lose the sign unless it is +" do
      assert write(".1f", -0.01) == "0.0"
      assert write("+.1f", -0.01) == "-0.0"
      assert write("d", -0.0) == "0"
      assert write("+d", -0.0) == "-0"
      assert write("($.2f", -0.001) == "$0.00"
      assert write("+.2e", -0.0) == "-0.00e+0"
    end

    @tag verifies: "format-notation-digits"
    test "integers keep their exact digits; past a double's range they are Infinity" do
      big = 12_345_678_901_234_567_891
      assert write("d", big) == "12345678901234567891"
      assert write(",d", -big) == "-12,345,678,901,234,567,891"
      assert write("x", 2 ** 70) == "400000000000000000"
      assert write("d", 1.0e22) == "10000000000000000000000"

      huge = 10 ** 400
      assert write(".2f", huge) == "Infinity"
      assert write(".2f", -huge) == "-Infinity"
      assert write(".1%", huge) == "Infinity%"
      assert write(".1%", 1.0e307) == "Infinity%"
      assert write(".3s", huge) == "Infinity"
      assert write("d", huge) == "1" <> String.duplicate("0", 400)

      # Past 10²⁵⁵ a double has more digits than the BIF writes (#253).
      assert write(".2f", 1.0e300) == Integer.to_string(trunc(1.0e300)) <> ".00"
      assert write(",.0%", -1.0e300) =~ ~r/^-100,000,000,0[\d,]+%$/
    end

    @tag verifies: "format-notation-digits"
    test "c writes strings, numbers and atoms as text, and NaN for any other term" do
      assert write("c", "abc") == "abc"
      assert write("c", 1.5) == "1.5"
      assert write("c", :ok) == "ok"
      assert write("c", {1, 2}) == "NaN"
      assert write("c", %{a: 1}) == "NaN"
      assert write("$c", "x") == "$x"
      assert write(".2f", "12") == "NaN"
      assert write("+$.2f", nil) == "+$NaN"
      assert write(".0%", :x) == "NaN%"
      assert write("f", 1.0e21) == "1000000000000000000000.000000"
    end
  end

  describe "a format is data" do
    @tag verifies: "format-data-parse"
    test "parse/2 answers a struct with no function in it, equal for one text under one locale" do
      {:ok, format} = Format.parse("*^+$012,.3~%")
      assert format == Format.parse!("*^+$012,.3~%")
      assert format.specifier == "*^+$012,.3~%"
      refute Enum.any?(Map.values(Map.from_struct(format)), &is_function/1)
      assert :erlang.term_to_binary(format) |> :erlang.binary_to_term() == format

      # Zero fill wins over the fill and align written; n is ,g; no type is ~g at 12.
      assert {format.fill, format.align, format.zero, format.comma} == {"0", "=", true, true}
      assert %Format{type: "g", comma: true, precision: 6} = Format.parse!("n")
      assert %Format{type: "g", trim: true, precision: 12} = Format.parse!("")
      assert %Format{type: "g", trim: true, precision: 3} = Format.parse!(".3q")
      assert %Format{fill: "€", align: "<", width: 6} = Format.parse!("€<6d")
    end

    @tag verifies: "format-data-parse"
    test "what is no specifier, no string, too wide or an unknown option is a fault" do
      assert Format.parse(",.2f\n") == {:error, [{[], {:specifier, ",.2f\n"}}]}
      assert Format.parse("\n>8d") == {:error, [{[], {:specifier, "\n>8d"}}]}
      assert Format.parse(".2ff") == {:error, [{[], {:specifier, ".2ff"}}]}
      assert Format.parse(3) == {:error, [{[], {:type, :specifier}}]}
      assert Format.parse(nil) == {:error, [{[], {:type, :specifier}}]}
      assert {:ok, %Format{width: 1024}} = Format.parse("1024d")
      assert Format.parse("1025d") == {:error, [{[], {:width, 1024}}]}
      assert Format.parse("99999999999999999999d") == {:error, [{[], {:width, 1024}}]}

      assert Format.parse("d", locale: :fr) == {:error, [{[:locale], {:type, :locale}}]}
      assert Format.parse("d", typo: 1) == {:error, [{[:typo], :unknown_key}]}
      assert Format.parse("d", [1 | 2]) == {:error, [{[], {:type, :keyword}}]}

      assert Format.parse(1, typo: 1) ==
               {:error, [{[], {:type, :specifier}}, {[:typo], :unknown_key}]}
    end

    @tag verifies: "format-data-parse"
    test "format_error/1 words every reason parse/2 and Locale.new/1 answer" do
      assert Format.format_error({:specifier, "q!"}) == ~s("q!" is no d3-format specifier)
      assert Format.format_error({:type, :specifier}) == "must be a d3-format specifier, a string"
      assert Format.format_error({:type, :locale}) == "must be a Macaw.Data.Format.Locale"
      assert Format.format_error({:type, :grouping}) =~ "positive integers"
      assert Format.format_error({:type, :currency}) == "must be {prefix, suffix}, two strings"
      assert Format.format_error({:type, :symbols}) =~ "ISO 4217"
      assert Format.format_error({:unknown_currency, "ZZZ"}) =~ "ZZZ"
      assert Format.format_error([{[:typo], :unknown_key}]) == "typo: is not a key it takes"
    end

    @tag verifies: "format-data-parse"
    test "parse!/2 raises the faults in words" do
      error = assert_raise Error, fn -> Format.parse!("..2f") end
      assert error.reason == [{[], {:specifier, "..2f"}}]
      assert Exception.message(error) == ~s(not a format: value: "..2f" is no d3-format specifier)

      error = assert_raise Error, fn -> Format.parse!("2000d", locale: 1) end
      assert error.reason == [{[], {:width, 1024}}, {[:locale], {:type, :locale}}]
      refute Exception.message(error) =~ "{:"
    end

    @tag verifies: "format-data-parse"
    test "number/2 writes any term, a non-number as NaN with the format's padding" do
      format = Format.parse!("^7,.1f")

      for value <- [nil, "1", :one, [1], %{}, {1}, make_ref(), self()],
          do: assert(Format.number(format, value) == "  NaN  ")

      assert Format.number(format, 1234) == "1,234.0"
    end
  end

  describe "the locale" do
    @tag verifies: "format-locale-definition"
    test "english/0 is the table's English" do
      assert %Locale{
               decimal: ".",
               thousands: ",",
               grouping: [3],
               currency: {"$", ""},
               minus: "-",
               nan: "NaN",
               percent: "%",
               symbols: %{"USD" => "$", "EUR" => "€", "GBP" => "£", "JPY" => "¥"}
             } = Locale.english()

      assert Locale.new([]) == {:ok, Locale.english()}
      assert Locale.new(%{}) == {:ok, Locale.english()}
    end

    @tag verifies: "format-locale-definition"
    test "another locale writes d3's outputs for it" do
      # d3-format's fr-FR, de-CH and en-IN definitions, and an invented one for the rest.
      fr =
        Locale.new!(
          decimal: ",",
          thousands: " ",
          grouping: [3],
          currency: ["", " €"],
          percent: " %"
        )

      de_ch = Locale.new!(decimal: ",", thousands: "'", grouping: [3], currency: ["", " CHF"])

      en_in =
        Locale.new!(%{
          decimal: ".",
          thousands: ",",
          grouping: [3, 2, 2, 2, 2, 2, 2, 2, 2, 2],
          currency: ["₹", ""]
        })

      odd = Locale.new!(minus: "−", nan: "n/a", grouping: [1, 2])

      write = fn locale, specifier, value ->
        Format.number(Format.parse!(specifier, locale: locale), value)
      end

      assert write.(fr, "$,.2f", 1_234_567.891) == "1 234 567,89 €"
      assert write.(fr, ".1%", 0.123) == "12,3 %"
      assert write.(de_ch, "$,.2f", -1234.5) == "-1'234,50 CHF"
      assert write.(en_in, "$,.0f", 123_456_789) == "₹12,34,56,789"
      assert write.(en_in, ",d", 1000) == "1,000"
      assert write.(odd, ",d", -1_234_567) == "−1,23,4,56,7"
      assert write.(odd, ".2f", nil) == "n/a"
      assert write.(Locale.new!(grouping: []), ",d", 1_234_567) == "1234567"
      assert write.(fr, "012,.1f", 1234.5) == "00 001 234,5"
    end

    @tag verifies: "format-locale-definition"
    test "a key it does not take, a wrong field, an unknown code and no fields are faults" do
      assert Locale.new(typo: 1) == {:error, [{[:typo], :unknown_key}]}
      assert Locale.new(%{"decimal" => ","}) == {:error, [{["decimal"], :unknown_key}]}

      assert Locale.new(thousands: 1, grouping: [3, 0], currency: {"$"}, symbols: [], nan: nil) ==
               {:error,
                [
                  {[:thousands], {:type, :text}},
                  {[:grouping], {:type, :grouping}},
                  {[:currency], {:type, :currency}},
                  {[:nan], {:type, :text}},
                  {[:symbols], {:type, :symbols}}
                ]}

      assert Locale.new(grouping: [3 | 2]) == {:error, [{[:grouping], {:type, :grouping}}]}

      assert Locale.new(symbols: %{"ZZZ" => "z", "USD" => "$", 1 => "x"}) ==
               {:error,
                [{[:symbols], {:type, :symbols}}, {[:symbols, "ZZZ"], {:unknown_currency, "ZZZ"}}]}

      assert Locale.new([1, 2]) == {:error, [{[], {:type, :keyword}}]}
      assert Locale.new(%URI{}) == {:error, [{[], {:type, :keyword}}]}

      error = assert_raise Error, fn -> Locale.new!(grouping: :three) end
      assert error.reason == [{[:grouping], {:type, :grouping}}]

      assert Exception.message(error) ==
               "not a locale: grouping: must be a list of positive integers, the group sizes"
    end
  end
end
