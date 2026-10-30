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

      use Zig, otp_app: :macaw_data, zig_code_path: "kernels.zig", optimize: :safe

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
    end

  {:fail, message} ->
    raise CompileError, description: message
end
