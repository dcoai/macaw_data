# The sites in lib/ allowed to raise (spec/00 §5), read by `elixir ci/raises.exs`. A
# public `name!` whose module defines `name` of the same arity is the bang twin and is
# never listed. Every other site is listed here by the function it sits in, with how many
# sites that function holds, its class and why:
#
#   :bang       a private helper the bang twins share to raise their twin's reason
#   :compile    a macro's misuse, which fails the build: there is no caller to answer
#   :invariant  a broken internal invariant: a bug in this library, never bad input
#   :convert    bad input still answered with a raise; the reason names the work item
#               of the "Errors are values" milestone (#114) that converts it
#
# An entry whose function holds a different number of sites fails the check too.
[
  %{
    site: "Macaw.Data.Delivery.new/2",
    count: 1,
    class: :convert,
    reason: "bad input it answers with a raise; #117 converts it"
  },
  %{
    site: "Macaw.Data.Delivery.named_rows/1",
    count: 1,
    class: :convert,
    reason: "bad input it answers with a raise; #117 converts it"
  },
  %{
    site: "Macaw.Data.Delivery.named!/2",
    count: 1,
    class: :convert,
    reason: "bad input it answers with a raise; #117 converts it"
  },
  %{
    site: "Macaw.Data.Delivery.source!/1",
    count: 2,
    class: :convert,
    reason: "bad input it answers with a raise; #117 converts it"
  },
  %{
    site: "Macaw.Data.Delivery.names/1",
    count: 2,
    class: :convert,
    reason: "bad input it answers with a raise; #117 converts it"
  },
  %{
    site: "Macaw.Data.Delivery.types/1",
    count: 1,
    class: :convert,
    reason: "bad input it answers with a raise; #117 converts it"
  },
  %{
    site: "Macaw.Data.Delivery.served/1",
    count: 2,
    class: :convert,
    reason: "bad input it answers with a raise; #117 converts it"
  },
  %{
    site: "Macaw.Data.Delivery.check/2",
    count: 3,
    class: :convert,
    reason: "bad input it answers with a raise; #117 converts it"
  },
  %{
    site: "Macaw.Data.Delivery.schema/1",
    count: 1,
    class: :convert,
    reason: "bad input it answers with a raise; #117 converts it"
  },
  %{
    site: "Macaw.Data.Delivery.retracted/1",
    count: 2,
    class: :convert,
    reason: "bad input it answers with a raise; #117 converts it"
  },
  %{
    site: "Macaw.Data.Delivery.replace/1",
    count: 1,
    class: :convert,
    reason: "bad input it answers with a raise; #117 converts it"
  },
  %{
    site: "Macaw.Data.Delivery.replacement/1",
    count: 2,
    class: :convert,
    reason: "bad input it answers with a raise; #117 converts it"
  },
  %{
    site: "Macaw.Data.Delivery.origin/1",
    count: 2,
    class: :convert,
    reason: "bad input it answers with a raise; #117 converts it"
  },
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
    site: "Macaw.Data.Derived.Functions.functions!/1",
    count: 1,
    class: :convert,
    reason: "bad input it answers with a raise; #120 converts it"
  },
  %{
    site: "Macaw.Data.Derived.Functions.register/3",
    count: 1,
    class: :convert,
    reason: "bad input it answers with a raise; #120 converts it"
  },
  %{
    site: "Macaw.Data.Derived.Sandbox.compile/2",
    count: 1,
    class: :convert,
    reason: "bad input it answers with a raise; #120 converts it"
  },
  %{
    site: "Macaw.Data.Derived.Sandbox.tightened!/1",
    count: 1,
    class: :convert,
    reason: "bad input it answers with a raise; #120 converts it"
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
    site: "Macaw.Data.Exact.to_float/1",
    count: 1,
    class: :convert,
    reason: "bad input it answers with a raise; #120 converts it"
  },
  %{
    site: "Macaw.Data.FFT.fft/1",
    count: 1,
    class: :convert,
    reason: "bad input it answers with a raise; #120 converts it"
  },
  %{
    site: "Macaw.Data.FFT.spectrum/3",
    count: 2,
    class: :convert,
    reason: "bad input it answers with a raise; #120 converts it"
  },
  %{
    site: "lib/macaw/data/native/kernels.ex (file body)",
    count: 1,
    class: :compile,
    reason: "native: :required without a toolchain fails the build (spec/04 §1.7)"
  },
  %{
    site: "Macaw.Data.Operations.step_digest/2",
    count: 1,
    class: :convert,
    reason: "bad input it answers with a raise; #118 converts it"
  },
  %{
    site: "Macaw.Data.Operations.run/4",
    count: 1,
    class: :convert,
    reason: "bad input it answers with a raise; #118 converts it"
  },
  %{
    site: "Macaw.Data.Operations.table!/1",
    count: 1,
    class: :convert,
    reason: "bad input it answers with a raise; #118 converts it"
  },
  %{
    site: "Macaw.Data.Operations.Aggregates.wrong!/3",
    count: 1,
    class: :convert,
    reason: "bad input it answers with a raise; #118 converts it"
  },
  %{
    site: "Macaw.Data.Operations.Registry.build/2",
    count: 1,
    class: :convert,
    reason: "bad input it answers with a raise; #118 converts it"
  },
  %{
    site: "Macaw.Data.Operations.Registry.members!/1",
    count: 1,
    class: :convert,
    reason: "bad input it answers with a raise; #118 converts it"
  },
  %{
    site: "Macaw.Data.Operations.Registry.kind/2",
    count: 1,
    class: :convert,
    reason: "bad input it answers with a raise; #118 converts it"
  },
  %{
    site: "Macaw.Data.Operations.Registry.named/2",
    count: 1,
    class: :convert,
    reason: "bad input it answers with a raise; #118 converts it"
  },
  %{
    site: "Macaw.Data.Operations.Transforms.not_a!/4",
    count: 1,
    class: :convert,
    reason: "bad input it answers with a raise; #118 converts it"
  },
  %{
    site: "Macaw.Data.Operations.Transforms.Ladder.kind!/3",
    count: 1,
    class: :convert,
    reason: "bad input it answers with a raise; #118 converts it"
  },
  %{
    site: "Macaw.Data.Operations.Transforms.Filter.at/4",
    count: 1,
    class: :convert,
    reason: "bad input it answers with a raise; #118 converts it"
  },
  %{
    site: "Macaw.Data.Operations.Transforms.Spectrum.names/1",
    count: 1,
    class: :convert,
    reason: "bad input it answers with a raise; #118 converts it"
  },
  %{
    site: "Macaw.Data.Operations.Transforms.Window.identity!/2",
    count: 2,
    class: :convert,
    reason: "bad input it answers with a raise; #118 converts it"
  },
  %{
    site: "Macaw.Data.Ops.__run__/5",
    count: 3,
    class: :convert,
    reason: "bad input it answers with a raise; #118 converts it"
  },
  %{
    site: "Macaw.Data.Quantity.resolve!/1",
    count: 1,
    class: :convert,
    reason: "bad input it answers with a raise; #120 converts it"
  },
  %{
    site: "Macaw.Data.Source.Conformance.__using__/1",
    count: 2,
    class: :compile,
    reason: "the conformance kit's options are checked as the test module compiles (spec/01 §9)"
  },
  %{
    site: "Macaw.Data.Source.Conformance.check/3",
    count: 1,
    class: :convert,
    reason: "bad input it answers with a raise; #120 converts it"
  },
  %{
    site: "Macaw.Data.Source.Conformance.settled/1",
    count: 1,
    class: :convert,
    reason: "bad input it answers with a raise; #120 converts it"
  },
  %{
    site: "Macaw.Data.Source.Finish.finish/4",
    count: 1,
    class: :convert,
    reason: "bad input it answers with a raise; #119 converts it"
  },
  %{
    site: "Macaw.Data.Source.Finish.reducer!/2",
    count: 1,
    class: :convert,
    reason: "bad input it answers with a raise; #119 converts it"
  },
  %{
    site: "Macaw.Data.Source.Order.schema_key/2",
    count: 2,
    class: :convert,
    reason: "bad input it answers with a raise; #119 converts it"
  },
  %{
    site: "Macaw.Data.Table.Digest.not_data/1",
    count: 1,
    class: :convert,
    reason: "bad input it answers with a raise; #119 converts it"
  },
  %{
    site: "Macaw.Data.Table.Edge.column_rows/1",
    count: 1,
    class: :convert,
    reason: "bad input it answers with a raise; #119 converts it"
  },
  %{
    site: "Macaw.Data.Table.Edge.tensor_rows/2",
    count: 1,
    class: :convert,
    reason: "bad input it answers with a raise; #119 converts it"
  },
  %{
    site: "Macaw.Data.Unit.convert/3",
    count: 1,
    class: :convert,
    reason: "bad input it answers with a raise; #120 converts it"
  },
  %{
    site: "Macaw.Data.Unit.parse!/1",
    count: 1,
    class: :convert,
    reason: "bad input it answers with a raise; #120 converts it"
  },
  %{
    site: "Macaw.Data.Unit.Currency.minor_units/1",
    count: 1,
    class: :convert,
    reason: "bad input it answers with a raise; #120 converts it"
  }
]
