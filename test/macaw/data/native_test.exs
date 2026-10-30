defmodule Macaw.Data.NativeTest do
  # Not async: the panic test starts a second BEAM, whose load would stretch the async
  # tests that trace calls into the window of #37's race.
  use ExUnit.Case, async: false

  alias Macaw.Data.Native
  alias Macaw.Data.Native.Toolchain

  # The panicking kernel exists where the build has the toolchain.
  @panics Code.ensure_loaded?(Macaw.Data.Test.NativePanic)

  describe "loading" do
    @tag verifies: "operations-native-loaded"
    test "loaded? is decided at start and held in persistent_term, true exactly when built" do
      assert is_boolean(Native.loaded?())
      assert Native.loaded?() == :persistent_term.get({Native, :loaded?})
      assert Native.loaded?() == Native.built?()
      assert Native.mode() in [:optional, :required]

      # Built under `:required`, as CI's toolchain job is, the kernels must have loaded.
      if Native.mode() == :required, do: assert(Native.loaded?())

      # A start whose probe fails: `:required` refuses, `:optional` runs the Elixir path.
      assert Native.settle({:error, :boom}, :required) == {:error, {:native_kernels, :boom}}
      assert Native.settle({:error, {:not_built, []}}, :optional) == :ok
      assert Native.settle(:ok, :required) == :ok
    end
  end

  describe "the native: setting" do
    @tag verifies: "operations-native-config"
    test "the toolchain and the setting decide the build: built, skipped with a warning, or failed" do
      assert Toolchain.decide({:ok, "/zig"}, :optional) == :build
      assert Toolchain.decide({:ok, "/zig"}, :required) == :build

      assert {:skip, warning} = Toolchain.decide({:absent, "no Zig"}, :optional)
      assert warning =~ "Elixir path" and warning =~ "no Zig"

      assert {:fail, message} = Toolchain.decide({:absent, "no Zig"}, :required)
      assert message =~ "native: :required" and message =~ "no Zig"

      assert {:fail, _} = Toolchain.decide({:ok, "/zig"}, :fast)

      # The toolchain this build found answers in the same shape.
      assert match?({:ok, _}, Toolchain.detect()) or match?({:absent, _}, Toolchain.detect())
      assert match?({:ok, _}, Toolchain.detect()) == Native.built?()
    end
  end

  describe "the scheduler" do
    @tag verifies: "operations-native-scheduler"
    test "a call over at most sync_rows rows runs on a normal scheduler, a larger one dirty" do
      assert Native.sync_rows() == 16_384
      assert Native.scheduler(0) == :normal
      assert Native.scheduler(8192) == :normal
      assert Native.scheduler(16_384) == :normal
      assert Native.scheduler(16_385) == :dirty
    end
  end

  describe "a panic" do
    @tag verifies: "operations-native-panic"
    test "a kernel's panic takes its node down with the panic's message, never silently" do
      # Without the toolchain there is no kernel to panic: the test kernel isn't built either.
      assert @panics == Native.built?()

      if @panics do
        ebin = Path.dirname(:code.which(Macaw.Data.Test.NativePanic))
        elixir = System.find_executable("elixir")
        call = "Macaw.Data.Test.NativePanic.past(7)"

        {out, status} = System.cmd(elixir, ["-pa", ebin, "-e", call], stderr_to_stdout: true)

        assert status != 0
        assert out =~ "panic: index out of bounds: index 7, len 3"
      end
    end
  end
end
