defmodule Macaw.Data.QuantityTest do
  use ExUnit.Case, async: true

  alias Macaw.Data.{Quantity, Unit}

  doctest Macaw.Data.Quantity

  describe "the fixed list" do
    @tag verifies: "quantities-list"
    test "the quantities in order, each with a base unit that reads" do
      assert Quantity.all() == [
               :duration,
               :information,
               :data_rate,
               :frequency,
               :ratio,
               :count,
               :temperature,
               :length,
               :speed,
               :power,
               :energy,
               :pressure,
               :area,
               :volume,
               :mass,
               :pace,
               :angle,
               :currency,
               :electric_potential,
               :electric_current,
               :electric_charge,
               :illuminance,
               :sound_level,
               :mass_concentration,
               :amount_concentration
             ]

      for q <- Quantity.all() -- [:currency],
          do: assert(Unit.valid?(Quantity.base_unit(q)), "#{q}")

      assert Quantity.base_unit(:currency) == nil
    end

    @tag verifies: "quantities-list"
    test "each base unit implies its own quantity; a ratio is the percent" do
      for q <- Quantity.all() -- [:ratio, :currency],
          do: assert(Quantity.of_unit(Quantity.base_unit(q)) == q, "#{q}")

      assert Quantity.of_unit("%") == :ratio
      assert Quantity.of_unit("{request}") == :count
      assert Quantity.of_unit("kW.h") == :energy
      assert Quantity.of_unit("km/h") == :speed
      assert Quantity.of_unit("{request}/s") == :frequency
      assert Quantity.of_unit("K") == :temperature
      assert Quantity.of_unit("g") == :mass
      assert Quantity.of_unit("m2") == :area
      assert Quantity.of_unit("rad/s") == nil
      assert Quantity.of_unit("dB") == nil
      assert Quantity.of_unit("dB[SPL]") == :sound_level
      assert Quantity.of_unit("{iso4217:USD}") == :currency
      assert Quantity.of_unit("mmol/l") == :amount_concentration
      assert Quantity.of_unit("min/km") == :pace
    end

    @tag verifies: "quantities-list"
    test "every family member reads and has its quantity's dimension" do
      units = %{
        information: ["By", "MiBy", "bit"],
        data_rate: ["By/s", "MiBy/s", "bit/s"],
        frequency: ["Hz", "/s"],
        energy: ["J", "kW.h"]
      }

      for q <- Quantity.all(),
          unit <- Map.get(units, q, [Quantity.base_unit(q)]),
          member <- Quantity.family(q, unit) do
        assert Unit.dimension(member) == Unit.dimension(Quantity.base_unit(q)), member
      end
    end

    @tag verifies: "quantities-families-conventions"
    test "the unit picks the family: decimal by default, binary, bits, hertz, watt-hours" do
      assert Quantity.family(:information, "By") == ~w(By kBy MBy GBy TBy)
      assert Quantity.family(:information, "kBy") == ~w(By kBy MBy GBy TBy)
      assert Quantity.family(:information, nil) == ~w(By kBy MBy GBy TBy)
      assert Quantity.family(:information, "MiBy") == ~w(By KiBy MiBy GiBy TiBy)
      assert Quantity.family(:information, "Mbit") == ~w(bit kbit Mbit Gbit Tbit)
      assert Quantity.family(:data_rate, "KiBy/s") == ~w(By/s KiBy/s MiBy/s GiBy/s TiBy/s)
      assert Quantity.family(:frequency, "kHz") == ~w(Hz kHz MHz GHz)
      assert Quantity.family(:frequency, "{request}/s") == ~w(/h /min /s)
      assert Quantity.family(:energy, "kW.h") == ~w(W.h kW.h MW.h GW.h)
      assert Quantity.family(:energy, "J") == ~w(J kJ MJ GJ)

      for q <- [:ratio, :count, :angle, :currency, :sound_level, :mass_concentration],
          do: assert(Quantity.family(q, nil) == [])

      assert Quantity.family(:temperature, "K") == []
      assert Quantity.family(:speed, "m/s") == []
      assert Quantity.family(:pressure, "mbar") == []
      assert Quantity.family(:length, "[nmi_i]") == []
    end
  end

  describe "resolve/1" do
    @tag verifies: "quantities-resolve"
    test "a unit implies its quantity and a quantity its base unit" do
      assert Quantity.resolve(%{unit: "ms"}) == {:ok, %{unit: "ms", quantity: :duration}}
      assert Quantity.resolve(%{quantity: :count}) == {:ok, %{unit: "1", quantity: :count}}
      assert Quantity.resolve(%{unit: "g"}) == {:ok, %{unit: "g", quantity: :mass}}
      assert Quantity.resolve(%{unit: "rad/s"}) == {:ok, %{unit: "rad/s", quantity: nil}}
      assert Quantity.resolve(%{quantity: :currency}) == {:ok, %{unit: nil, quantity: :currency}}
      assert Quantity.resolve(%{}) == {:ok, %{unit: nil, quantity: nil}}
    end

    @tag verifies: "quantities-resolve"
    test "a pair whose dimensions agree resolves, one that does not is refused" do
      assert Quantity.resolve(%{unit: "%", quantity: :ratio}) ==
               {:ok, %{unit: "%", quantity: :ratio}}

      assert Quantity.resolve(%{unit: "1", quantity: :ratio}) ==
               {:ok, %{unit: "1", quantity: :ratio}}

      assert Quantity.resolve(%{unit: "{core}", quantity: :count}) ==
               {:ok, %{unit: "{core}", quantity: :count}}

      assert Quantity.resolve(%{unit: "By", quantity: :duration}) ==
               {:error, {:quantity, :duration, "By"}}

      assert Quantity.resolve(%{unit: "s", quantity: :count}) ==
               {:error, {:quantity, :count, "s"}}
    end

    @tag verifies: "quantities-resolve"
    test "a code that does not read and a quantity not in the list are refused" do
      assert Quantity.resolve(%{unit: "sec"}) == {:error, {:unit, "sec", {:unknown_atom, "sec"}}}
      assert Quantity.resolve(%{quantity: :weight}) == {:error, {:unknown_quantity, :weight}}
    end
  end

  describe "the label rule: the unit, else the quantity, else nothing" do
    @tag verifies: "quantities-label-rule"
    test "the unit's symbol, its annotations written" do
      assert Quantity.label(%{unit: "ms"}) == "ms"
      assert Quantity.label(%{unit: "kW.h", quantity: :energy}) == "kW·h"
      assert Quantity.label(%{unit: "{request}/s"}) == "request/s"
      assert Quantity.label(%{unit: "{request}"}) == "request"
      assert Quantity.label(%{quantity: :duration}) == "s"
    end

    @tag verifies: "quantities-label-rule"
    test "else the quantity's name, else nothing" do
      assert Quantity.label(%{quantity: :count}) == "count"
      assert Quantity.label(%{unit: "1", quantity: :ratio}) == "ratio"
      assert Quantity.label(%{unit: "1"}) == "count"
      assert Quantity.label(%{}) == nil
    end
  end
end
