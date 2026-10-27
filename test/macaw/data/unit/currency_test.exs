defmodule Macaw.Data.Unit.CurrencyTest do
  # The currency extension (spec/03 §1–§7, D-155).
  use ExUnit.Case, async: true

  alias Macaw.Data.{Quantity, Unit}
  alias Macaw.Data.Unit.Currency

  describe "the ISO 4217 table" do
    @tag verifies: "units-currency-code"
    test "list one, 178 codes, each with its minor units" do
      assert length(Currency.table()) == 178

      assert Enum.map(~w(USD EUR GBP JPY BHD KWD CLF ISK XAU XXX), &Unit.minor_units/1) ==
               [2, 2, 2, 0, 3, 3, 4, 0, nil, nil]

      for {code, minor, name} <- Currency.table() do
        assert code =~ ~r/\A[A-Z]{3}\z/
        assert minor == nil or minor in 0..4
        assert name != ""
      end

      assert_raise ArgumentError, ~r/"ZZZ"/, fn -> Unit.minor_units("ZZZ") end
    end
  end

  describe "{iso4217:XXX} is a dimension per code" do
    @tag verifies: "units-currency-code"
    test "each code its own dimension, composed like any unit" do
      assert Unit.dimension("{iso4217:USD}") == %{{:currency, "USD"} => 1}
      assert Unit.dimension("{iso4217:USD}/h") == %{{:currency, "USD"} => 1, time: -1}

      assert Unit.dimension("{iso4217:EUR}/kW/h") ==
               %{{:currency, "EUR"} => 1, mass: -1, length: -2, time: 2}

      assert Unit.dimension("{iso4217:EUR}/{iso4217:USD}") ==
               %{{:currency, "EUR"} => 1, {:currency, "USD"} => -1}

      refute Unit.dimension("{iso4217:USD}") == Unit.dimension("{iso4217:EUR}")
      assert Unit.factor("{iso4217:USD}/kW/h") == {1, 3_600_000_000}
    end

    @tag verifies: "units-currency-code"
    test "a code not in the table is refused, a plain annotation is still the unity" do
      assert Unit.parse("{iso4217:ZZZ}") == {:error, {:unknown_currency, "ZZZ"}}
      assert Unit.parse("{iso4217:usd}") == {:error, {:unknown_currency, "usd"}}
      assert Unit.dimension("{USD}") == %{}
      assert Unit.format_error({:unknown_currency, "ZZZ"}) =~ "ISO 4217"
    end

    @tag verifies: "units-currency-code"
    test "two currencies never convert; mixing them is refused" do
      assert Unit.conversion("{iso4217:USD}", "{iso4217:EUR}") ==
               {:error, {:currency, "{iso4217:USD}", "{iso4217:EUR}"}}

      assert Unit.conversion("{iso4217:EUR}/kW/h", "{iso4217:EUR}/MW/h") ==
               {:ok, {{1000, 1}, {0, 1}}}

      assert Quantity.resolve(%{unit: "{iso4217:EUR}", quantity: :currency}) ==
               {:ok, %{unit: "{iso4217:EUR}", quantity: :currency}}

      assert Quantity.resolve(%{unit: "{iso4217:EUR}", quantity: :count}) ==
               {:error, {:quantity, :count, "{iso4217:EUR}"}}

      assert Quantity.resolve(%{unit: "{iso4217:EUR}/h", quantity: :currency}) ==
               {:error, {:quantity, :currency, "{iso4217:EUR}/h"}}

      assert Quantity.resolve(%{unit: "1", quantity: :currency}) ==
               {:error, {:quantity, :currency, "1"}}
    end

    @tag verifies: "units-currency-code"
    test "the code alone is the currency; its symbol is the code" do
      assert Unit.currency("{iso4217:GBP}") == "GBP"
      assert Unit.currency("{iso4217:GBP}/h") == nil
      assert Unit.currency("kg") == nil
      assert Unit.currency("sec") == nil
      assert Quantity.of_unit("{iso4217:GBP}") == :currency
      assert Quantity.of_unit("{iso4217:GBP}/h") == nil

      assert Unit.symbol("{iso4217:USD}") == "USD"
      assert Unit.symbol("{iso4217:USD}/h") == "USD/h"
      assert Unit.symbol("{iso4217:EUR}/kW/h") == "EUR/(kW·h)"
      assert Unit.symbol("{iso4217:EUR}/kW.h") == "EUR·h/kW"
      assert Quantity.label(%{unit: "{iso4217:USD}"}) == "USD"
    end

    @tag verifies: "units-alias-read"
    test "a person's currency: a code in capitals, €, £; $ and ¥ name their choices" do
      assert Unit.parse_alias("USD") == {:ok, "{iso4217:USD}"}
      assert Unit.parse_alias("CHF") == {:ok, "{iso4217:CHF}"}
      assert Unit.parse_alias("€") == {:ok, "{iso4217:EUR}"}
      assert Unit.parse_alias("£") == {:ok, "{iso4217:GBP}"}
      assert Unit.parse_alias("ZZZ") == {:error, {:unknown_alias, "ZZZ"}}

      {:error, {:ambiguous, "$", dollars}} = Unit.parse_alias("$")
      assert "{iso4217:USD}" in Enum.map(dollars, &elem(&1, 0))
      assert length(dollars) == 6

      {:error, {:ambiguous, "¥", yen}} = Unit.parse_alias("¥")
      assert Enum.map(yen, &elem(&1, 0)) == ["{iso4217:JPY}", "{iso4217:CNY}"]
    end
  end
end
