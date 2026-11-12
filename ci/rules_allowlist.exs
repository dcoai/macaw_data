# The uses of a call spec/00 §4.4 of the family (dco-tek/macaw/macaw#280) bans that
# macaw_data keeps, read by ci/rules.exs (#286). Each use names the file, the call, how
# many sites it allows, and why; a test_code entry names a file under lib/ that is test
# code that ships, held to both rules:
#
#   %{file: "test/x_test.exs", call: "Process.sleep", count: 1, reason: "..."}
#   %{test_code: "lib/x/conformance.ex", reason: "..."}
#
# More or fewer sites than `count` fail the check, so the list shrinks as uses go. The
# lib/ entry is a removal waiting on its proposal.
[
  %{
    test_code: "lib/macaw/data/source/conformance.ex",
    reason: "the conformance kit (spec/01 §9): tests a host runs against its own sources"
  },
  %{test_code: "lib/macaw/data/source/conformance/call.ex", reason: "the conformance kit's part"},
  %{
    test_code: "lib/macaw/data/source/conformance/deliveries.ex",
    reason: "the conformance kit's part"
  },
  %{
    test_code: "lib/macaw/data/source/conformance/monitored.ex",
    reason: "the conformance kit's part"
  },
  %{
    test_code: "lib/macaw/data/source/conformance/pushes.ex",
    reason: "the conformance kit's part"
  },
  %{
    test_code: "lib/macaw/data/source/conformance/regions.ex",
    reason: "the conformance kit's part"
  },
  %{
    test_code: "lib/macaw/data/source/conformance/words.ex",
    reason: "the conformance kit's part"
  },
  %{
    file: "lib/macaw/data/source/conformance.ex",
    call: "System.monotonic_time",
    count: 2,
    reason:
      "the deadline of a wait on a source's pushed messages (a receive's `after`): it bounds a wait on messages, it times nothing"
  },
  %{
    file: "lib/macaw/data/source/conformance/pushes.ex",
    call: "System.monotonic_time",
    count: 2,
    reason:
      "the deadline of a wait on a source's pushed messages (a receive's `after`): it bounds a wait on messages, it times nothing"
  },
  %{
    file: "test/macaw/data/operations/filter_native_test.exs",
    call: ":timer.tc",
    count: 1,
    reason:
      "a kernel on a normal scheduler returns within 1 ms (spec/04 §1.7): the bound is a time, and a NIF makes no reductions to count"
  },
  %{
    file: "test/macaw/data/operations/finish_native_test.exs",
    call: ":timer.tc",
    count: 1,
    reason:
      "a kernel on a normal scheduler returns within 1 ms (spec/04 §1.7): the bound is a time, and a NIF makes no reductions to count"
  },
  %{
    file: "test/macaw/data/operations/group_native_test.exs",
    call: ":timer.tc",
    count: 1,
    reason:
      "a kernel on a normal scheduler returns within 1 ms (spec/04 §1.7): the bound is a time, and a NIF makes no reductions to count"
  },
  %{
    file: "test/macaw/data/operations/ladder_native_test.exs",
    call: ":timer.tc",
    count: 1,
    reason:
      "a kernel on a normal scheduler returns within 1 ms (spec/04 §1.7): the bound is a time, and a NIF makes no reductions to count"
  },
  %{
    file: "test/macaw/data/operations/frame_loop_test.exs",
    call: ":timer.tc",
    count: 2,
    reason:
      "a @tag :benchmark test, excluded from the suite, that reports the frame loop's milliseconds beside its counts"
  },
  %{
    file: "test/macaw/data/reduce_test.exs",
    call: ":timer.tc",
    count: 2,
    reason:
      "a @tag :benchmark test, excluded from the suite, that reports 1M points' reduction in milliseconds"
  },
  %{
    file: "lib/macaw/data/native/kernels.ex",
    call: "Application.compile_env",
    count: 5,
    reason:
      "the native: configuration choosing whether the kernels build (spec/04 §1.7); a build setting, not runtime state; removal or a recorded exception is #288"
  }
]
