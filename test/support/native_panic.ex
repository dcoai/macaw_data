# A kernel that panics, for the test that a panic is never silent (spec/04 §1.7): built as
# the kernels are, ReleaseSafe, where the build has the toolchain, and run only in a BEAM
# of its own.
with {:module, toolchain} <- Code.ensure_compiled(Macaw.Data.Native.Toolchain),
     {:ok, exe} <- toolchain.detect() do
  System.put_env("ZIG_EXECUTABLE_PATH", exe)
  root = toolchain.staging_root(Mix.Project.build_path(), System.get_env("ZIGLER_STAGING_ROOT"))
  File.mkdir_p!(root)
  System.put_env("ZIGLER_STAGING_ROOT", root)

  defmodule Macaw.Data.Test.NativePanic do
    @moduledoc false
    use Zig, otp_app: :macaw_data, optimize: :safe

    ~Z"""
    /// Indexes past a slice: ReleaseSafe's bounds check panics.
    pub fn past(n: u32) u32 {
        const held = [_]u32{ 1, 2, 3 };
        const slice: []const u32 = &held;
        return slice[n];
    }
    """
  end
end
