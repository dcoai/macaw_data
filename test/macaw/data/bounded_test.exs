defmodule Macaw.Data.BoundedTest do
  # A raise the bounded runner answers logs nothing at error level (spec/02 §6.4,
  # macaw_data#79). Not async: a capture holds every process's events while it runs, and
  # only a module run alone can say that no event in it came from somewhere else.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Macaw.Data.Bounded
  alias Macaw.Data.Derived.Sandbox
  alias Macaw.Data.Source.Conformance
  alias Macaw.Data.Test.Sources.Broken

  # The call's events, its runtime's report included. A raw process's crash report reaches
  # the handlers through the logger's proxy, after the caller has its answer; asked its
  # state, the proxy has handled every event sent to it before.
  defp logged(fun) do
    capture_log([level: :debug], fn ->
      send(self(), {:answer, fun.()})
      _ = :sys.get_state(:logger_proxy)
    end)
  end

  defp answer do
    receive do
      {:answer, answer} -> answer
    end
  end

  describe "a raise" do
    @tag verifies: "derived-runner-quiet-raise"
    test "a raise in a call, in a compile and in the bounded runner itself logs no error" do
      # A stored function's raises: arithmetic, a map read on an atom, a missing clause.
      for {source, args, module} <- [
            {"fn x -> 1 / x end", [0], ArithmeticError},
            {"fn m -> m.halt end", [:erlang], BadMapError},
            {"fn 1 -> 1 end", [2], FunctionClauseError}
          ] do
        {:ok, compiled} = Sandbox.compile(source)
        log = logged(fn -> Sandbox.run(compiled, args) end)

        assert answer() == {:error, :raised, module}
        refute log =~ "[error]", "#{source} logged:\n#{log}"
      end

      # A source the checker passes and the compiler refuses raises in the runner too.
      log = logged(fn -> Sandbox.compile("fn x -> <<x::utf8-size(8)>> end") end)
      assert {:error, [{nil, {:compile, message}}]} = answer()
      assert is_binary(message)
      refute log =~ "[error]", log

      # The runner itself, as the conformance kit calls it: a raise and a throw keep the
      # exit reason a raw process has, the exception and its stack.
      log = logged(fn -> Bounded.run(fn -> :erlang.error(:badarith) end, timeout: 1_000) end)
      assert {:down, {:badarith, [_ | _]}} = answer()
      refute log =~ "[error]", log

      log = logged(fn -> Bounded.run(fn -> throw(:x) end, timeout: 1_000) end)
      assert {:down, {{:nocatch, :x}, [_ | _]}} = answer()
      refute log =~ "[error]", log
    end

    @tag verifies: "conformance-errors"
    test "a source raising in the conformance kit is a finding, with no error logged" do
      log = logged(fn -> Conformance.check(:errors, Broken.new(:raises), []) end)

      assert [{:errors, {:raised, {:fetch, {:unreadable, _}}, {%ArgumentError{}, _}}} | _] =
               answer()

      refute log =~ "[error]", log
    end
  end
end
