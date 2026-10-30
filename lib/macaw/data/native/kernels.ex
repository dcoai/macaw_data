alias Macaw.Data.Native.Toolchain

# The native kernels (spec/04 §1.7), compiled from kernels.zig when this build has the
# toolchain (`Toolchain.detect/0`), else a module of the same functions, never called, as
# `Macaw.Data.Native.loaded?/0` is false. Which one is decided at compile time, under
# `config :macaw_data, native:`, and decided again when the toolchain changes.
case Toolchain.decide(
       Toolchain.detect(),
       Application.compile_env(:macaw_data, :native, :optional)
     ) do
  :build ->
    {:ok, exe} = Toolchain.detect()
    # Zigler runs Zig from a staging directory; it is given the executable itself.
    System.put_env("ZIG_EXECUTABLE_PATH", exe)

    defmodule Macaw.Data.Native.Kernels do
      @moduledoc false
      @mode Application.compile_env(:macaw_data, :native, :optional)
      @toolchain Toolchain.detect()

      # Each `_dirty` kernel is its namesake on a dirty CPU scheduler, for a call past what a
      # normal scheduler takes within 1 ms (`Macaw.Data.Native.scheduler/1`, spec/04 §1.7).
      use Zig,
        otp_app: :macaw_data,
        zig_code_path: "kernels.zig",
        optimize: :safe,
        nifs: [
          abi: [],
          ladder: [],
          ladder_dirty: [alias: :ladder, concurrency: :dirty_cpu],
          m4_finish: [],
          m4_finish_dirty: [alias: :m4_finish, concurrency: :dirty_cpu],
          lttb_finish: [],
          lttb_finish_dirty: [alias: :lttb_finish, concurrency: :dirty_cpu]
        ]

      @doc false
      def built?, do: true

      @doc false
      def mode, do: @mode

      @doc false
      def __mix_recompile__?, do: Toolchain.detect() != @toolchain
    end

  {:skip, warning} ->
    # Printed, not a compiler diagnostic: an adopter's `--warnings-as-errors` build without
    # Zig is a supported build, not a failed one.
    IO.puts(:stderr, "warning: " <> warning)

    defmodule Macaw.Data.Native.Kernels do
      @moduledoc false
      @mode Application.compile_env(:macaw_data, :native, :optional)
      @toolchain Toolchain.detect()

      @doc false
      def built?, do: false

      @doc false
      def mode, do: @mode

      @doc false
      def __mix_recompile__?, do: Toolchain.detect() != @toolchain

      @doc false
      def abi, do: :erlang.nif_error(:not_built)

      @doc false
      def ladder(_xf, _xd, _xv, _yf, _yd, _yv, _first, _count, _kind, _k),
        do: :erlang.nif_error(:not_built)

      @doc false
      def ladder_dirty(_xf, _xd, _xv, _yf, _yd, _yv, _first, _count, _kind, _k),
        do: :erlang.nif_error(:not_built)

      @doc false
      def m4_finish(_pieces, _k, _extent, _lo, _hi, _width), do: :erlang.nif_error(:not_built)

      @doc false
      def m4_finish_dirty(_pieces, _k, _extent, _lo, _hi, _width),
        do: :erlang.nif_error(:not_built)

      @doc false
      def lttb_finish(_pieces, _n), do: :erlang.nif_error(:not_built)

      @doc false
      def lttb_finish_dirty(_pieces, _n), do: :erlang.nif_error(:not_built)
    end

  {:fail, message} ->
    raise CompileError, description: message
end
