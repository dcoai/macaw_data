defmodule Macaw.Data.Quantity.FactsTest do
  # The facts every quantity carries and the unit systems (spec/03 §8–§13, D-155).
  use ExUnit.Case, async: true

  alias Macaw.Data.{Quantity, Unit}

  describe "every quantity has every fact" do
    @tag verifies: "quantities-list"
    test "a base unit of its own dimension, a kind, bounds and additivity" do
      for q <- Quantity.all() do
        assert Quantity.kind(q) in [:linear, :affine, :logarithmic, :cyclic], "#{q}"
        assert {min, max} = Quantity.bounds(q)
        assert min == nil or is_number(min)
        assert max == nil or is_number(max)
        assert %{across: across, over_time: over_time} = Quantity.additivity(q)
        assert is_boolean(across) and is_boolean(over_time)

        if q != :currency do
          base = Quantity.base_unit(q)
          assert Quantity.resolve(%{unit: base, quantity: q}) == {:ok, %{unit: base, quantity: q}}
        end
      end
    end

    @tag verifies: "quantities-kind-bounds"
    test "the kinds: a temperature is affine, a sound level logarithmic, an angle cyclic" do
      kinds = Map.new(Quantity.all(), &{&1, Quantity.kind(&1)})
      assert kinds.temperature == :affine
      assert kinds.sound_level == :logarithmic
      assert kinds.angle == :cyclic

      assert kinds
             |> Map.drop([:temperature, :sound_level, :angle])
             |> Map.values()
             |> Enum.uniq() ==
               [:linear]
    end

    @tag verifies: "quantities-list"
    test "every family member reads, has its quantity's dimension and one shape in its family" do
      for q <- Quantity.all(), q != :currency, system <- Quantity.systems() do
        family = Quantity.family(q, nil, system)

        for member <- family do
          assert Unit.dimension(member) == Unit.dimension(Quantity.base_unit(q)),
                 "#{q} #{system} #{member}"
        end

        if Quantity.kind(q) != :affine do
          factors = Enum.map(family, &Unit.convert(1, &1, Quantity.base_unit(q)))
          assert factors == Enum.sort(factors), "#{q} #{system}: smallest first"
        end
      end
    end
  end

  describe "bounds are a display hint" do
    @tag verifies: "quantities-kind-bounds"
    test "in the base unit, and converted into another unit of the quantity" do
      assert Quantity.bounds(:angle) == {0, 360}
      assert Quantity.bounds(:angle, "rad") == {0.0, 2 * :math.pi()}
      assert Quantity.bounds(:ratio) == {0, 1}
      assert Quantity.bounds(:ratio, "%") == {0.0, 100.0}
      assert Quantity.bounds(:duration, "ms") == {0.0, nil}
      assert Quantity.bounds(:temperature, "[degF]") == {nil, nil}
      assert Quantity.bounds(:currency, "{iso4217:USD}") == {nil, nil}
    end
  end

  describe "additivity depends on the aggregation" do
    @tag verifies: "quantities-additivity-defaults"
    test "the physical defaults" do
      across_only = [:data_rate, :frequency, :power, :electric_current]
      both = [:duration, :information, :count, :length, :energy, :area, :volume, :mass]
      both = both ++ [:currency, :electric_charge]

      for q <- across_only,
          do: assert(Quantity.additivity(q) == %{across: true, over_time: false})

      for q <- both, do: assert(Quantity.additivity(q) == %{across: true, over_time: true})

      for q <- Quantity.all() -- (across_only ++ both),
          do: assert(Quantity.additivity(q) == %{across: false, over_time: false}, "#{q}")
    end

    @tag verifies: "quantities-additivity-defaults"
    test "a metric kind refines the sum over time and never the sum across" do
      for q <- [nil | Quantity.all()] do
        %{across: across} = Quantity.additivity(q)
        assert Quantity.additivity(q, :gauge) == %{across: across, over_time: false}
        assert Quantity.additivity(q, :rate) == %{across: across, over_time: false}
        assert Quantity.additivity(q, :counter) == %{across: across, over_time: across}
      end

      assert Quantity.additivity(nil) == %{across: true, over_time: true}
      assert Quantity.additivity(:count, :gauge) == %{across: true, over_time: false}
      assert Quantity.additivity(:data_rate, :counter) == %{across: true, over_time: true}
    end
  end

  describe "unit systems" do
    @tag verifies: "quantities-systems-pick"
    test "the four systems" do
      assert Quantity.systems() == [:metric, :us, :uk, :as_posted]
    end

    @tag verifies: "quantities-systems-pick"
    test "a system shows a quantity in its own family, US and UK apart" do
      cases = [
        {"kg", :us, ~w([oz_av] [lb_av])},
        {"kg", :uk, ~w([oz_av] [lb_av] [stone_av])},
        {"[lb_av]", :metric, ~w(mg g kg t)},
        {"l", :us, ~w([foz_us] [pt_us] [gal_us])},
        {"l", :uk, ~w([foz_br] [pt_br] [gal_br])},
        {"m", :us, ~w([in_i] [ft_i] [mi_i])},
        {"m", :uk, ~w([in_i] [ft_i] [mi_i])},
        {"[mi_i]", :metric, ~w(mm cm m km)},
        {"Cel", :us, ~w([degF])},
        {"Cel", :uk, ~w(Cel)},
        {"[degF]", :metric, ~w(Cel)},
        {"km/h", :us, ~w([mi_i]/h)},
        {"min/km", :us, ~w(min/[mi_i])},
        {"[psi]", :metric, ~w(Pa kPa MPa)},
        {"m2", :us, ~w([ft_i]2 [acr_us] [mi_i]2)},
        {"ms", :us, ~w(ns us ms s min h d)},
        {"By", :uk, ~w(By kBy MBy GBy TBy)}
      ]

      for {unit, system, family} <- cases do
        assert Quantity.family(Quantity.of_unit(unit), unit, system) == family,
               inspect({unit, system})
      end
    end

    @tag verifies: "quantities-systems-pick"
    test "as posted, a value keeps its unit's own family" do
      assert Quantity.family(:mass, "[oz_av]", :as_posted) == ~w([oz_av] [lb_av])
      assert Quantity.family(:length, "[ft_i]", :as_posted) == ~w([in_i] [ft_i] [mi_i])
      assert Quantity.family(:volume, "[gal_br]", :as_posted) == ~w([foz_br] [pt_br] [gal_br])
      assert Quantity.family(:mass, "g", :as_posted) == ~w(mg g kg t)
      assert Quantity.family(:electric_charge, "mA.h", :as_posted) == ~w(mA.h A.h)

      # No family holds these: they are shown as given.
      for {quantity, unit} <- [pressure: "mbar", length: "[nmi_i]", temperature: "K"],
          do: assert(Quantity.family(quantity, unit, :as_posted) == [], unit)
    end

    @tag verifies: "quantities-systems-pick"
    test "a preference across dimensions is not a system: glucose stays as given" do
      for system <- Quantity.systems() do
        assert Quantity.family(:mass_concentration, "mg/dl", system) == []
        assert Quantity.family(:amount_concentration, "mmol/l", system) == []
      end

      # A speed is never shown as a pace, nor a pace as a speed.
      assert Quantity.family(:speed, "km/h", :us) == ~w([mi_i]/h)
      assert Quantity.family(:pace, "min/km", :us) == ~w(min/[mi_i])
    end
  end

  describe "conventions: a system picks within one, never across" do
    @tag verifies: "quantities-families-conventions"
    test "the proposal's four calls" do
      assert Quantity.family(:pressure, "hPa", :us) == ~w([in_i'Hg])
      assert Quantity.family(:pressure, "mm[Hg]", :metric) == ~w(mm[Hg])
      assert Quantity.family(:pressure, "mm[Hg]", :us) == ~w(mm[Hg])
      assert Quantity.family(:pressure, "kPa", :us) == ~w([psi])
    end

    @tag verifies: "quantities-families-conventions"
    test "barometric: hPa and mbar are hPa under metric and UK, inches of mercury under US" do
      assert Quantity.family(:pressure, "mbar", :metric) == ~w(hPa)
      assert Quantity.family(:pressure, "mbar", :uk) == ~w(hPa)
      assert Quantity.family(:pressure, "mbar", :us) == ~w([in_i'Hg])
      assert Quantity.family(:pressure, "hPa", :uk) == ~w(hPa)
      assert Quantity.family(:pressure, "[in_i'Hg]", :metric) == ~w(hPa)
      assert Quantity.family(:pressure, "[in_i'Hg]", :us) == ~w([in_i'Hg])
    end

    @tag verifies: "quantities-families-conventions"
    test "as posted keeps the unit's own ladder inside its convention" do
      assert Quantity.family(:pressure, "hPa", :as_posted) == ~w(hPa)
      assert Quantity.family(:pressure, "Pa", :as_posted) == ~w(Pa kPa MPa)
      assert Quantity.family(:pressure, "mm[Hg]", :as_posted) == ~w(mm[Hg])
      # bar and mbar are claimed by a convention but held by no ladder.
      assert Quantity.family(:pressure, "bar", :as_posted) == []
      assert Quantity.family(:pressure, "mbar", :as_posted) == []
    end

    @tag verifies: "quantities-families-conventions"
    test "gauge: bar is gauge's but out of the metric ladder, so it is shown in kPa" do
      assert Quantity.family(:pressure, "bar", :metric) == ~w(Pa kPa MPa)
      assert Quantity.family(:pressure, "bar", :us) == ~w([psi])
      assert Quantity.family(:pressure, "[psi]", :metric) == ~w(Pa kPa MPa)
    end

    @tag verifies: "quantities-families-conventions"
    test "exact code first, then shape: a prefix no convention lists falls back to gauge" do
      assert Quantity.family(:pressure, "hPa", :metric) == ~w(hPa)
      assert Quantity.family(:pressure, "kPa", :metric) == ~w(Pa kPa MPa)
      assert Quantity.family(:pressure, "dPa", :metric) == ~w(Pa kPa MPa)
      assert Quantity.family(:pressure, "dPa", :us) == ~w([psi])
      assert Quantity.family(:pressure, "dPa") == ~w(Pa kPa MPa)
      assert Quantity.family(:pressure, nil, :us) == ~w([psi])
    end

    @tag verifies: "quantities-families-conventions"
    test "clinical: mm[Hg] keeps its unit in every system" do
      for system <- Quantity.systems() do
        assert Quantity.family(:pressure, "mm[Hg]", system) == ~w(mm[Hg])
      end
    end

    # Every family/3 answer of every other quantity as origin/main gave it before D-158,
    # computed there over each quantity's base unit, every family member and some units
    # of no family: `{quantity, units, [metric, us, uk, as_posted]}`.
    @before [
      {:duration, [nil, "s", "ns", "us", "ms", "min", "h", "d", "ks"],
       [
         ~w(ns us ms s min h d),
         ~w(ns us ms s min h d),
         ~w(ns us ms s min h d),
         ~w(ns us ms s min h d)
       ]},
      {:information, [nil, "By", "kBy", "MBy", "GBy", "TBy"],
       [
         ~w(By kBy MBy GBy TBy),
         ~w(By kBy MBy GBy TBy),
         ~w(By kBy MBy GBy TBy),
         ~w(By kBy MBy GBy TBy)
       ]},
      {:information, ["KiBy", "MiBy", "GiBy", "TiBy"],
       [
         ~w(By KiBy MiBy GiBy TiBy),
         ~w(By KiBy MiBy GiBy TiBy),
         ~w(By KiBy MiBy GiBy TiBy),
         ~w(By KiBy MiBy GiBy TiBy)
       ]},
      {:information, ["bit", "kbit", "Mbit", "Gbit", "Tbit"],
       [
         ~w(bit kbit Mbit Gbit Tbit),
         ~w(bit kbit Mbit Gbit Tbit),
         ~w(bit kbit Mbit Gbit Tbit),
         ~w(bit kbit Mbit Gbit Tbit)
       ]},
      {:data_rate, [nil, "By/s", "kBy/s", "MBy/s", "GBy/s", "TBy/s"],
       [
         ~w(By/s kBy/s MBy/s GBy/s TBy/s),
         ~w(By/s kBy/s MBy/s GBy/s TBy/s),
         ~w(By/s kBy/s MBy/s GBy/s TBy/s),
         ~w(By/s kBy/s MBy/s GBy/s TBy/s)
       ]},
      {:data_rate, ["KiBy/s", "MiBy/s", "GiBy/s", "TiBy/s"],
       [
         ~w(By/s KiBy/s MiBy/s GiBy/s TiBy/s),
         ~w(By/s KiBy/s MiBy/s GiBy/s TiBy/s),
         ~w(By/s KiBy/s MiBy/s GiBy/s TiBy/s),
         ~w(By/s KiBy/s MiBy/s GiBy/s TiBy/s)
       ]},
      {:data_rate, ["bit/s", "kbit/s", "Mbit/s", "Gbit/s", "Tbit/s"],
       [
         ~w(bit/s kbit/s Mbit/s Gbit/s Tbit/s),
         ~w(bit/s kbit/s Mbit/s Gbit/s Tbit/s),
         ~w(bit/s kbit/s Mbit/s Gbit/s Tbit/s),
         ~w(bit/s kbit/s Mbit/s Gbit/s Tbit/s)
       ]},
      {:frequency, [nil, "Hz", "kHz", "MHz", "GHz"],
       [~w(Hz kHz MHz GHz), ~w(Hz kHz MHz GHz), ~w(Hz kHz MHz GHz), ~w(Hz kHz MHz GHz)]},
      {:frequency, ["/h", "/min", "/s"],
       [~w(/h /min /s), ~w(/h /min /s), ~w(/h /min /s), ~w(/h /min /s)]},
      {:ratio, [nil, "1"], [[], [], [], []]},
      {:count, [nil, "1"], [[], [], [], []]},
      {:temperature, [nil, "Cel"], [~w(Cel), ~w([degF]), ~w(Cel), ~w(Cel)]},
      {:temperature, ["[degF]"], [~w(Cel), ~w([degF]), ~w(Cel), ~w([degF])]},
      {:temperature, ["K"], [~w(Cel), ~w([degF]), ~w(Cel), []]},
      {:length, [nil, "m", "mm", "cm", "km", "dm"],
       [~w(mm cm m km), ~w([in_i] [ft_i] [mi_i]), ~w([in_i] [ft_i] [mi_i]), ~w(mm cm m km)]},
      {:length, ["[in_i]", "[ft_i]", "[mi_i]"],
       [
         ~w(mm cm m km),
         ~w([in_i] [ft_i] [mi_i]),
         ~w([in_i] [ft_i] [mi_i]),
         ~w([in_i] [ft_i] [mi_i])
       ]},
      {:length, ["[nmi_i]"],
       [~w(mm cm m km), ~w([in_i] [ft_i] [mi_i]), ~w([in_i] [ft_i] [mi_i]), []]},
      {:speed, [nil, "m/s"], [~w(km/h), ~w([mi_i]/h), ~w([mi_i]/h), []]},
      {:speed, ["km/h"], [~w(km/h), ~w([mi_i]/h), ~w([mi_i]/h), ~w(km/h)]},
      {:speed, ["[mi_i]/h"], [~w(km/h), ~w([mi_i]/h), ~w([mi_i]/h), ~w([mi_i]/h)]},
      {:power, [nil, "W", "kW", "MW", "GW"],
       [~w(W kW MW GW), ~w(W kW MW GW), ~w(W kW MW GW), ~w(W kW MW GW)]},
      {:energy, [nil, "J", "kJ", "MJ", "GJ"],
       [~w(J kJ MJ GJ), ~w(J kJ MJ GJ), ~w(J kJ MJ GJ), ~w(J kJ MJ GJ)]},
      {:energy, ["W.h", "kW.h", "MW.h", "GW.h"],
       [
         ~w(W.h kW.h MW.h GW.h),
         ~w(W.h kW.h MW.h GW.h),
         ~w(W.h kW.h MW.h GW.h),
         ~w(W.h kW.h MW.h GW.h)
       ]},
      {:energy, ["cal", "kcal"], [~w(cal kcal), ~w(cal kcal), ~w(cal kcal), ~w(cal kcal)]},
      {:area, [nil, "m2", "cm2", "har", "km2"],
       [
         ~w(cm2 m2 har km2),
         ~w([ft_i]2 [acr_us] [mi_i]2),
         ~w([ft_i]2 [acr_us] [mi_i]2),
         ~w(cm2 m2 har km2)
       ]},
      {:area, ["[ft_i]2", "[acr_us]", "[mi_i]2"],
       [
         ~w(cm2 m2 har km2),
         ~w([ft_i]2 [acr_us] [mi_i]2),
         ~w([ft_i]2 [acr_us] [mi_i]2),
         ~w([ft_i]2 [acr_us] [mi_i]2)
       ]},
      {:volume, [nil, "l", "ml", "m3", "dl"],
       [~w(ml l m3), ~w([foz_us] [pt_us] [gal_us]), ~w([foz_br] [pt_br] [gal_br]), ~w(ml l m3)]},
      {:volume, ["[foz_us]", "[pt_us]", "[gal_us]"],
       [
         ~w(ml l m3),
         ~w([foz_us] [pt_us] [gal_us]),
         ~w([foz_br] [pt_br] [gal_br]),
         ~w([foz_us] [pt_us] [gal_us])
       ]},
      {:volume, ["[foz_br]", "[pt_br]", "[gal_br]"],
       [
         ~w(ml l m3),
         ~w([foz_us] [pt_us] [gal_us]),
         ~w([foz_br] [pt_br] [gal_br]),
         ~w([foz_br] [pt_br] [gal_br])
       ]},
      {:mass, [nil, "g", "mg", "kg", "t"],
       [~w(mg g kg t), ~w([oz_av] [lb_av]), ~w([oz_av] [lb_av] [stone_av]), ~w(mg g kg t)]},
      {:mass, ["[oz_av]", "[lb_av]"],
       [~w(mg g kg t), ~w([oz_av] [lb_av]), ~w([oz_av] [lb_av] [stone_av]), ~w([oz_av] [lb_av])]},
      {:mass, ["[stone_av]"],
       [
         ~w(mg g kg t),
         ~w([oz_av] [lb_av]),
         ~w([oz_av] [lb_av] [stone_av]),
         ~w([oz_av] [lb_av] [stone_av])
       ]},
      {:pace, [nil, "s/m"], [~w(min/km), ~w(min/[mi_i]), ~w(min/[mi_i]), []]},
      {:pace, ["min/km"], [~w(min/km), ~w(min/[mi_i]), ~w(min/[mi_i]), ~w(min/km)]},
      {:pace, ["min/[mi_i]"], [~w(min/km), ~w(min/[mi_i]), ~w(min/[mi_i]), ~w(min/[mi_i])]},
      {:angle, [nil, "deg"], [[], [], [], []]},
      {:electric_potential, [nil, "V", "mV", "kV"],
       [~w(mV V kV), ~w(mV V kV), ~w(mV V kV), ~w(mV V kV)]},
      {:electric_current, [nil, "A", "mA"], [~w(mA A), ~w(mA A), ~w(mA A), ~w(mA A)]},
      {:electric_charge, [nil, "C"], [[], [], [], []]},
      {:electric_charge, ["mA.h", "A.h"],
       [~w(mA.h A.h), ~w(mA.h A.h), ~w(mA.h A.h), ~w(mA.h A.h)]},
      {:illuminance, [nil, "lx", "klx"], [~w(lx klx), ~w(lx klx), ~w(lx klx), ~w(lx klx)]},
      {:sound_level, [nil, "dB[SPL]"], [[], [], [], []]},
      {:mass_concentration, [nil, "g/l"], [[], [], [], []]},
      {:amount_concentration, [nil, "mol/l"], [[], [], [], []]}
    ]

    @tag verifies: "quantities-families-conventions"
    test "every other quantity's family/3 answers are unchanged" do
      for {quantity, units, answers} <- @before,
          unit <- units,
          {system, answer} <- Enum.zip(Quantity.systems(), answers) do
        assert Quantity.family(quantity, unit, system) == answer,
               inspect({quantity, unit, system})
      end

      assert @before |> Enum.map(&elem(&1, 0)) |> Enum.uniq() ==
               Quantity.all() -- [:pressure, :currency]
    end
  end
end
