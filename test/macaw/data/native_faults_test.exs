defmodule Macaw.Data.NativeFaultsTest do
  # A kernel answers a fault as a term, never as a Zig error, whose trace Zigler builds in
  # unsynchronized globals (spec/04 §1.7, macaw_data#101).
  use ExUnit.Case, async: true

  alias Macaw.Data.Native

  # Each kernel with arguments it can't read, and the fault it answers.
  @cases [
    {:ladder, [0, <<>>, <<>>, 0, <<>>, <<>>, 0, 10, 0, 3], :short_buffer},
    {:ladder, [0, :no_binary, <<>>, 0, <<>>, <<>>, 0, 0, 0, 3], :not_a_binary},
    {:m4_finish, [[:no_piece], 3, 0, 0, 0, 10], :not_a_piece},
    {:lttb_finish, [[:no_piece], 3], :not_a_piece},
    {:group_sum, [0, <<>>, <<>>, false, <<>>, <<>>, 0, 0, 10, 0], :short_buffer},
    {:group_sum, [9, <<>>, <<>>, false, <<>>, <<>>, 0, 0, 0, 0], :unknown_form},
    {:filter_mask, [0, <<>>, <<>>, 0, 10, 0, 0, true, false, <<>>, 0], :short_buffer},
    {:take, [<<1, 2, 3, 4, 5, 6, 7, 8>>, 8, [5]], :short_buffer},
    {:take, [<<1, 2, 3, 4, 5, 6, 7, 8>>, 0, [0]], :unknown_form},
    {:take, [:no_binary, 8, [0]], :not_a_binary},
    {:take_bits, [<<0>>, [100]], :short_buffer},
    {:extremes, [9, <<>>, <<>>, 0, 0], :unknown_form},
    {:extremes, [0, <<>>, <<>>, 0, 10], :short_buffer}
  ]

  @tag verifies: "operations-native-faults"
  test "every kernel answers what it can't read as {:fault, reason}, on either scheduler" do
    if Native.loaded?() do
      for {name, args, reason} <- @cases,
          kernel <- [name, :"#{name}_dirty"] do
        assert apply(Macaw.Data.Native.Kernels, kernel, args) == {:fault, reason},
               "#{kernel} with #{inspect(args)}"
      end
    end
  end

  @tag verifies: "operations-native-faults"
  test "Native.kernel/3 answers out of memory by the Elixir path and raises any other fault naming the kernel" do
    assert Native.answer(:ladder, {:fault, :out_of_memory}, []) == :fallback
    assert Native.answer(:ladder, :fallback, []) == :fallback
    assert Native.answer(:take, <<1, 2>>, []) == <<1, 2>>

    error =
      assert_raise RuntimeError, fn ->
        Native.answer(:take, {:fault, :short_buffer}, [<<1, 2, 3>>, 8, [5, 6]])
      end

    assert error.message =~ "native kernel take answered the fault :short_buffer"
    assert error.message =~ "[{:binary, 3}, 8, {:list, 2}]"

    if Native.loaded?() do
      assert_raise RuntimeError,
                   ~r/native kernel take_bits answered the fault :short_buffer/,
                   fn ->
                     Native.kernel(:take_bits, [<<0>>, [100]], :normal)
                   end
    end
  end
end
