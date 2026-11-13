defmodule Macaw.Data.Test.PreloadTest do
  # macaw_data#289: the suite runs with every module loaded, as a release does, so no call
  # waits on the code server to load its module. `:telemetry`'s ETS table module, which
  # the handler table first calls inside an attach's 5 s deadline, is one of them.
  use ExUnit.Case, async: true

  alias Macaw.Data.Test.Preload

  test "every module of the suite's applications is loaded before the first test" do
    modules = Preload.modules()
    assert length(modules) > 1_000
    assert Enum.reject(modules, &:code.is_loaded/1) == []
    assert :telemetry_ets in modules and :code.is_loaded(:telemetry_ets)
  end

  test "the applications are OTP's and Elixir's the suite uses, this one and its dependencies" do
    apps = Preload.apps()
    assert [:kernel, :stdlib, :compiler, :elixir, :ex_unit, :macaw_data, :telemetry] -- apps == []
  end
end
