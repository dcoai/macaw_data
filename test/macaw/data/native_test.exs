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

  describe "the staging directory" do
    @tag verifies: "operations-native-staged"
    test "a build stages the kernels under its own build path unless ZIGLER_STAGING_ROOT names a root" do
      assert Toolchain.staging_root("/b/_build/test", nil) == "/b/_build/test/zigler"
      assert Toolchain.staging_root("/b/_build/test", "") == "/b/_build/test/zigler"
      assert Toolchain.staging_root("/b/_build/test", "/cache/zigler") == "/cache/zigler"

      # Built with the toolchain, this build staged its kernels in its own path.
      if Native.built?() do
        root =
          Toolchain.staging_root(Mix.Project.build_path(), System.get_env("ZIGLER_STAGING_ROOT"))

        assert File.regular?(Path.join([root, "Elixir.Macaw.Data.Native.Kernels", "build.zig"]))
      end
    end
  end

  describe "the scheduler" do
    @tag verifies: "operations-native-scheduler"
    test "a call over at most sync_rows rows, one canonical chunk, runs on a normal scheduler, a larger one dirty" do
      assert Native.sync_rows() == 8192
      assert Native.scheduler(0) == :normal
      assert Native.scheduler(8192) == :normal
      assert Native.scheduler(8193) == :dirty
      assert Native.scheduler(16_384) == :dirty
    end
  end

  describe "the Elixir path on request" do
    @tag verifies: "operations-native-elixir"
    test "inside elixir/1 no step runs a kernel, so reductions count the step's whole work" do
      assert Native.active?() == Native.loaded?()
      assert Native.elixir(fn -> Native.active?() end) == false
      assert Native.active?() == Native.loaded?()

      table =
        Macaw.Data.Table.new!([
          {"t", :number, Enum.to_list(1..2000)},
          {"v", :number, List.duplicate(1.0, 2000)}
        ])

      [view] = Macaw.Data.Table.chunks(table)
      bound = %{x: "t", y: "v", x_name: "t", y_name: "v", kind: :linear}
      partial = fn -> Macaw.Data.Operations.Transforms.Ladder.partial(view, bound, 3, "m4") end

      {elixir, walked} = Macaw.Data.Test.Work.reductions(fn -> Native.elixir(partial) end)
      {native, answered} = Macaw.Data.Test.Work.reductions(partial)
      assert walked == answered

      # The walk counts a few reductions a row; the kernel, a call.
      assert elixir > 2000
      if Native.loaded?(), do: assert(native < 200), else: assert(native > 2000)
    end
  end

  describe "on normal schedulers on request" do
    @tag verifies: "operations-native-normal-schedulers"
    test "inside normal_schedulers/1 every kernel call is on a normal scheduler, so its count is fixed" do
      big = Native.sync_rows() + 1
      buckets = Native.finish_buckets() + 1

      assert Native.normal_schedulers(fn ->
               {Native.scheduler(big), Native.finish_scheduler(buckets), Native.entry_limit()}
             end) == {:normal, :normal, 0}

      assert {Native.scheduler(big), Native.finish_scheduler(buckets)} == {:dirty, :dirty}
      assert Native.entry_limit() == Native.sync_entries()

      if Native.loaded?() do
        # The bits of a bitmap of `big` bits at every index: a gather past sync_rows/0, made
        # dirty outside the scope. Counted dirty, the call is charged by its time and the
        # count refused; counted inside the scope, it is the gather's plumbing and a call's
        # fixed few reductions, the same every time.
        bitmap = :binary.copy(<<0b10101010>>, div(big, 8) + 1)
        indexes = Enum.to_list(0..(big - 1))
        take = fn -> Macaw.Data.Table.Bitmap.take(bitmap, indexes, nil) end

        assert_raise RuntimeError, ~r/dirty scheduler.*normal_schedulers/, fn ->
          Macaw.Data.Test.Work.reductions(take)
        end

        counted = fn ->
          Macaw.Data.Test.Work.reductions(fn -> Native.normal_schedulers(take) end)
        end

        {once, bits} = counted.()
        assert bits == take.()
        assert for(_ <- 1..5, do: elem(counted.(), 0)) == List.duplicate(once, 5)
        assert once < 1_000, "the gather counted #{once}"
      end
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
