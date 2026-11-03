# The sites in lib/ allowed to raise (spec/00 §5), read by `elixir ci/raises.exs`. A
# public `name!` whose module defines `name` of the same arity is the bang twin and is
# never listed. Every other site is listed here by the function it sits in, with how many
# sites that function holds, its class and why:
#
#   :bang       a private helper the bang twins share to raise their twin's reason
#   :compile    a macro's misuse, which fails the build: there is no caller to answer
#   :invariant  a broken internal invariant: a bug in this library, never bad input
#
# Bad input has no class: a function answers it with {:error, reason} (spec/00 §5).
#
# An entry whose function holds a different number of sites fails the check too.
[
  %{
    site: "Macaw.Data.Derived.Columns.value!/1",
    count: 1,
    class: :bang,
    reason: "the Columns bang twins' one raise: their twin's reason in format_error/1's words"
  },
  %{
    site: "Macaw.Data.Derived.Functions.arity!/3",
    count: 1,
    class: :compile,
    reason: "defsource: two arities of one name fail the build (spec/02 §7)"
  },
  %{
    site: "Macaw.Data.Derived.Functions.head!/2",
    count: 1,
    class: :compile,
    reason: "defsource: a head of another arity fails the build (spec/02 §7)"
  },
  %{
    site: "Macaw.Data.Derived.Functions.body!/2",
    count: 1,
    class: :compile,
    reason: "defsource: a body that is not a do block fails the build (spec/02 §7)"
  },
  %{
    site: "Macaw.Data.Derived.Sandbox.Runtime.get/2",
    count: 1,
    class: :invariant,
    reason:
      "a stored function's field read on a table: the sandbox's rewrite of a map read raises as Map.fetch! does, and the bounded runner answers it as :raised (spec/02 §6, #107); nothing outside a stored function calls it"
  },
  %{
    site: "Macaw.Data.Derived.Sandbox.Runtime.value!/1",
    count: 1,
    class: :bang,
    reason: "the Runtime bang twins' one raise: their twin's reason in format_error/1's words"
  },
  %{
    site: "lib/macaw/data/native/kernels.ex (file body)",
    count: 1,
    class: :compile,
    reason: "native: :required without a toolchain fails the build (spec/04 §1.7)"
  },
  %{
    site: "Macaw.Data.Operations.Aggregates.wrong!/3",
    count: 1,
    class: :invariant,
    reason:
      "a reading an aggregate does not read: Operations.aggregate/4 and the grouping steps check every reading with Aggregate.reads/1 before reducing, and answer {:reads, kind}; reduce/2 and step/3 take readings as reads/0 declares (spec/04 §3.1, §5)"
  },
  %{
    site: "Macaw.Data.Operations.Transforms.not_a!/4",
    count: 1,
    class: :invariant,
    reason:
      "a reading of the wrong kind inside a step: each step's bind/3 checks its columns with Transforms.readings/3 before any chunk is read, and answers {:reads, kind} (spec/04 §3.1)"
  },
  %{
    site: "Macaw.Data.Source.Conformance.__using__/1",
    count: 2,
    class: :compile,
    reason: "the conformance kit's options are checked as the test module compiles (spec/01 §9)"
  },
  %{
    site: "Macaw.Data.Table.Digest.not_data/1",
    count: 1,
    class: :invariant,
    reason:
      "a value that is not data in a digest: Table.new/2 refuses one ({[name, i], :not_data}) before any chunk is built, so a chunk's canonical form never holds one (spec/01 §1.1.2)"
  },
  %{
    site: "Macaw.Data.Ops.value!/2",
    count: 1,
    class: :bang,
    reason:
      "the Ops bang twins' one raise (aggregate!/2,3, transform!/2,3, and __run__/5's ! kinds): their twin's faults in format_error/1's words"
  },
  %{
    site: "Macaw.Data.FFT.value!/1",
    count: 1,
    class: :bang,
    reason:
      "the FFT bang twins' one raise (fft!/1, spectrum!/3): their twin's reason in format_error/1's words"
  },
  %{
    site: "Macaw.Data.Unit.value!/1",
    count: 1,
    class: :bang,
    reason:
      "the Unit bang twins' one raise (dimension!/1, factor!/1, kind!/1, symbol!/2, convert!/3, minor_units!/1): their twin's reason in format_error/1's words"
  },
  %{
    site: "Macaw.Data.Quantity.value!/1",
    count: 1,
    class: :bang,
    reason:
      "the Quantity bang twins' one raise (base_unit!/1, kind!/1, bounds!/1,2, additivity!/2, family!/2,3): their twin's reason, worded"
  }
]
