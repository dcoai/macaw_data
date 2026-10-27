# The sites in lib/ allowed to make an atom from a string (spec/02 §6.5), read by
# `elixir ci/atoms.exs`. Each entry is one file, a fragment of the lines it allows, how
# many lines of the file hold that fragment, the site's class and why:
#
#   (a)      a closed library vocabulary: the bound is the vocabulary's size
#   (a-host) a vocabulary host code registers: the bound is the host's registry
#   (d)      bounded by the library: the bound is stated
#
# A name a document or a client declares (b), or one derived from such names (c), is a
# string and has no entry here: the check refuses one. An entry that matches no line, or a
# different number of lines, fails the check too.
[
  %{
    file: "lib/macaw/data/derived/sandbox/names.ex",
    match: ~S|:"sandbox_v#{n}"|,
    count: 1,
    class: :d,
    reason: "the checker's pool of plain variable atoms, 256, made when the library compiles"
  },
  %{
    file: "lib/macaw/data/derived/sandbox/names.ex",
    match: ~S|:"_sandbox_v#{n}"|,
    count: 1,
    class: :d,
    reason: "the checker's pool of _-prefixed variable atoms, 256, made when the library compiles"
  }
]
