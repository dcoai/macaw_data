defmodule Macaw.Data.NativeAllocationsTest do
  # Every allocation a kernel makes is counted, and each can be failed in turn: whichever
  # fails, the kernel answers out of memory and holds no block when it returns (spec/04
  # §1.7, macaw_data#101). The probes exist in this project's test build alone.
  use ExUnit.Case, async: true

  alias Macaw.Data.Native
  alias Macaw.Data.Native.Kernels
  alias Macaw.Data.Operations.Transforms.Ladder
  alias Macaw.Data.Table

  @n 8_192

  # Each kernel that allocates, with arguments that reach every allocation it makes:
  # growing lists past their first size, and group_sum's index past its first size.
  defp cases do
    xs = for i <- 0..(@n - 1), into: <<>>, do: <<i::signed-little-64>>
    ys = for i <- 0..(@n - 1), into: <<>>, do: <<:math.sin(i / 7) * 100::float-little-64>>
    ones = :binary.copy(<<255>>, div(@n, 8))
    every_other = Enum.to_list(0..(@n - 1)//2)

    # 40 groups, each value of its own binary exponent: past the sums' first 32 entries and
    # the index's first 64 slots at half full.
    groups = 40
    codes = for i <- 0..(@n - 1), into: <<>>, do: <<rem(i, groups)::signed-little-32>>

    values =
      for i <- 0..(@n - 1),
          into: <<>>,
          do: <<:math.pow(2.0, rem(i, groups)) * 1.5::float-little-64>>

    table =
      Table.new!([
        {"t", :number, Enum.to_list(0..(@n - 1))},
        {"v", :number, for(i <- 0..(@n - 1), do: :math.sin(i / 7) * 100)}
      ])

    [view] = Table.chunks(table)
    bound = %{x: "t", y: "v", x_name: "t", y_name: "v", kind: :linear}
    {k, _views, pieces} = Ladder.partial(view, bound, 3, "m4")

    [
      {:ladder, [0, xs, ones, 1, ys, ones, 0, @n, 0, 3]},
      {:m4_finish, [pieces, k, 0, 0, 0, 100]},
      {:lttb_finish, [pieces, 50]},
      {:group_sum, [1, values, ones, true, codes, ones, groups, 0, @n, 0]},
      {:filter_mask, [2, ys, ones, 0, @n, 4, 0.0, false, false, <<>>, 0]},
      {:take, [ys, 8, every_other]},
      {:take_bits, [ones, every_other]}
    ]
  end

  @tag verifies: "operations-native-allocations"
  test "whichever allocation fails, each kernel answers out of memory and holds no block when it returns" do
    if Native.loaded?() do
      for {name, args} <- cases() do
        probe = :"#{name}_probe"
        plain = apply(Kernels, name, args)

        # Nothing failed: the kernel's own answer, every block freed.
        assert {^plain, allocations, 0} = apply(Kernels, probe, [0 | args]), "#{name}"
        assert allocations > 1, "#{name} made #{allocations} allocations"

        for fail_at <- 1..allocations do
          assert apply(Kernels, probe, [fail_at | args]) ==
                   {{:fault, :out_of_memory}, fail_at, 0},
                 "#{name} with allocation #{fail_at} of #{allocations} failed"
        end
      end
    end
  end
end
