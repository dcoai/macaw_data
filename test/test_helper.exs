# Every module loaded first, as a release loads them (macaw_data#289): a call into one not
# yet loaded waits on the busy code server, which under load outlasts a 5 s deadline.
:ok = Macaw.Data.Test.Preload.all()

# `:benchmark` tests state a timing and gate nothing: `mix test --only benchmark`.
ExUnit.start(exclude: [:benchmark], formatters: [ExUnit.CLIFormatter, Surfex.ExUnitFormatter])
