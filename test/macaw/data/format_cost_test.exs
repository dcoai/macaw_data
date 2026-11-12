defmodule Macaw.Data.FormatCostTest do
  @moduledoc """
  The common formats write through the BIFs (spec/05 §4, #253): the same string as the
  general path of §2, at a few times the bare BIF's cost.
  """
  # Counted work: no other test loads or purges code meanwhile (`Macaw.Data.Test.Work`).
  use ExUnit.Case, async: false
  use ExUnitProperties

  alias Macaw.Data.Format
  alias Macaw.Data.Format.Locale
  alias Macaw.Data.Test.Work

  # Reductions for writing 1,000 values: measured 13,300, 10,314, 12,008 and 13,301 in #253
  # (spec/05 §4's table), against 116,195, 62,310, 58,629 and 122,023 by §2's path.
  @budgets %{",.2f" => 16_000, "d" => 13_000, ".0%" => 15_000, "$,.2f" => 16_000}

  # A width of 0 pads nothing, so it writes what no width writes, by §2's path.
  defp general(format), do: %{format | width: 0}

  defp shapes do
    for type <- ~w(f % d),
        symbol <- ["", "$"],
        comma <- ["", ","],
        zero <- ["", "0"],
        precision <- ["", ".0", ".2", ".7"],
        do: symbol <> zero <> comma <> precision <> type
  end

  defp locales do
    [
      Locale.english(),
      Locale.new!(decimal: ",", thousands: ".", currency: {"", " €"}, percent: " %"),
      Locale.new!(thousands: " ", grouping: [3, 2], minus: "−"),
      Locale.new!(grouping: [])
    ]
  end

  defp value do
    one_of([
      float(),
      integer(),
      float(min: -1.0e-3, max: 1.0e-3),
      member_of([0.0, -0.0, -0.004, -0.005, -0.5, 0.5, 2.5, -2.5, 1.0e21, -1.0e21, 9.995]),
      member_of([1.0e300, -1.0e300, 1.7976931348623157e308, 10 ** 400, -(10 ** 400), 2 ** 60])
    ])
  end

  @tag verifies: "format-cost-identical"
  property "each common format writes what the general path writes" do
    formats = for shape <- shapes(), locale <- locales(), do: Format.parse!(shape, locale: locale)

    check all(values <- list_of(value(), min_length: 1, max_length: 8), max_runs: 300) do
      for format <- formats, v <- values do
        assert Format.number(format, v) == Format.number(general(format), v),
               "#{format.specifier} of #{inspect(v)}"
      end
    end
  end

  @tag verifies: "format-cost-budget"
  test "1,000 values by each common format cost at most their budget" do
    :rand.seed(:exsss, {2, 5, 3})
    floats = for _ <- 1..1000, do: (:rand.uniform() - 0.3) * 1.0e6
    ints = for _ <- 1..1000, do: :rand.uniform(10_000_000) - 3_000_000
    ratios = for _ <- 1..1000, do: :rand.uniform()
    values = %{",.2f" => floats, "d" => ints, ".0%" => ratios, "$,.2f" => floats}

    counts =
      for {specifier, budget} <- @budgets do
        format = Format.parse!(specifier)
        list = Map.fetch!(values, specifier)
        {work, :ok} = Work.reductions(fn -> Enum.each(list, &Format.number(format, &1)) end)
        {specifier, work, budget}
      end

    assert Enum.filter(counts, fn {_s, work, budget} -> work > budget end) == [], inspect(counts)
  end
end
