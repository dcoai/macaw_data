defmodule RaiseGateTest do
  @moduledoc "The raise guard, `ci/raises.exs` (spec/00 §5): errors are values."
  use ExUnit.Case, async: true

  Application.put_env(:ci, :ci_no_main, true)
  Code.require_file("ci/raises.exs")

  @moduletag :tmp_dir

  defp lib(dir, text) do
    File.mkdir_p!(Path.join(dir, "lib"))
    File.write!(Path.join(dir, "lib/x.ex"), text)
  end

  defp entry(site, count, class \\ :invariant, reason \\ "an invariant"),
    do: %{site: site, count: count, class: class, reason: reason}

  @tag verifies: "data-errors-guard"
  test "the library holds no raise the allowlist does not" do
    assert RaiseGate.run(File.cwd!()) == []
  end

  @tag verifies: "data-errors-guard"
  test "a raise outside a bang twin fails at its line, a twin passes", %{tmp_dir: dir} do
    lib(dir, """
    defmodule X do
      @moduledoc "raise in a doc is no site"
      def new(a), do: if(a, do: {:ok, a}, else: {:error, :no})

      def new!(a) do
        {:ok, v} = new(a)
        v || raise ArgumentError, "no"
      end

      # raise ArgumentError in a comment is no site
      def read(a) do
        if a, do: a, else: raise(ArgumentError, "bad input")
      end

      defp check!(a), do: a || Kernel.raise("no")
      def other!(a), do: throw(check!(a))
    end
    """)

    assert RaiseGate.run(dir, []) == [
             "lib/x.ex:12: X.read/1 raises; answer {:error, reason} instead",
             "lib/x.ex:15: X.check!/1 raises; answer {:error, reason} instead",
             "lib/x.ex:16: X.other!/1 raises; answer {:error, reason} instead"
           ]
  end

  @tag verifies: "data-errors-guard"
  test "a raise in a nested module or a file's own code is named by where it is",
       %{tmp_dir: dir} do
    lib(dir, """
    case :build do
      :build -> defmodule X.Y do
        defmodule Z do
          def f, do: raise "no"
        end
      end
      other -> raise CompileError, description: inspect(other)
    end
    """)

    assert RaiseGate.run(dir, []) == [
             "lib/x.ex:7: lib/x.ex (file body) raises; answer {:error, reason} instead",
             "lib/x.ex:4: X.Y.Z.f/0 raises; answer {:error, reason} instead"
           ]
  end

  @tag verifies: "data-errors-guard"
  test "an allowlisted site passes, and an entry whose count is stale fails", %{tmp_dir: dir} do
    lib(dir, "defmodule X do\n  def f(a), do: a || raise(\"no\")\nend\n")

    assert RaiseGate.run(dir, [entry("X.f/1", 1)]) == []
    assert [stale] = RaiseGate.run(dir, [entry("X.f/1", 2)])
    assert stale =~ "X.f/1 holds 1 raise(s), the entry says 2"
    assert [_unallowed, _stale] = RaiseGate.run(dir, [entry("X.g/1", 1)])
  end

  @tag verifies: "data-errors-guard"
  test "an entry of an unknown class, with no site, or of the retired :convert class fails and allows nothing",
       %{tmp_dir: dir} do
    lib(dir, "defmodule X do\n  def f(a), do: a || raise(\"no\")\nend\n")

    assert [unknown, _unallowed] = RaiseGate.run(dir, [entry("X.f/1", 1, :later)])
    assert unknown =~ "an entry needs site, count, a class of"
    # Bad input is no class: the milestone's :convert class is refused now it is done.
    assert [convert, _unallowed] = RaiseGate.run(dir, [entry("X.f/1", 1, :convert, "#117")])
    assert convert =~ "a class of [:bang, :compile, :invariant]"
    assert [malformed, unallowed] = RaiseGate.run(dir, [%{class: :invariant}])
    assert malformed =~ "an entry needs site"
    assert unallowed =~ "X.f/1 raises"
  end
end
