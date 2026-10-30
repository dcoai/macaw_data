import Config

# Whether this build must have the native kernels (spec/04 §1.7): `:optional`, the default,
# builds them when Zig is present and runs the Elixir path otherwise; `:required` fails the
# build without them. A library's own config never reaches an adopter, which sets
# `config :macaw_data, native: :required` in its own. Here CI chooses through
# MACAW_DATA_NATIVE; any other value is refused.
config :macaw_data,
  native:
    (case System.get_env("MACAW_DATA_NATIVE", "optional") do
       "optional" -> :optional
       "required" -> :required
     end)
