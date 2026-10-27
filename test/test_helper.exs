# `:benchmark` tests state a timing and gate nothing: `mix test --only benchmark`.
ExUnit.start(exclude: [:benchmark], formatters: [ExUnit.CLIFormatter, Surfex.ExUnitFormatter])
