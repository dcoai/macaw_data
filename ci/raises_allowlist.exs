# The raises macaw_data keeps, read by ci/raises.exs, the family's vendored guard
# (spec/00 §5, macaw_data#130, #160). Each entry names one function that raises, its
# class and why:
#
#   %{at: {Module, :fun, arity}, class: :bang | :compile | :mix_task | :invariant, reason: "..."}
#
#   :bang       a `!` twin: raises exactly where its value twin answers {:error, reason}
#   :compile    a macro or a module body refusing bad code while it compiles
#   :invariant  a case no input can reach, kept with the reason it can't
#
# A raise outside the list fails the check, and so does an entry that matches no raise.
# Bad input is never a class: a function answers it with {:error, reason}.
[
  %{
    at: {Macaw.Data.Format, :parse!, 2},
    class: :bang,
    reason: "parse/2's twin: raises the faults parse/2 answers, as Macaw.Data.Error"
  },
  %{
    at: {Macaw.Data.Format, :for_measure!, 2},
    class: :bang,
    reason: "for_measure/2's twin: raises the faults for_measure/2 answers, as Macaw.Data.Error"
  },
  %{
    at: {Macaw.Data.Format, :parse_time!, 2},
    class: :bang,
    reason: "parse_time/2's twin: raises the faults parse_time/2 answers, as Macaw.Data.Error"
  },
  %{
    at: {Macaw.Data.Format.Locale, :new!, 1},
    class: :bang,
    reason: "new/1's twin: raises the faults new/1 answers, as Macaw.Data.Error"
  },
  %{
    at: {Macaw.Data.Derived, :from_map!, 2},
    class: :bang,
    reason: "from_map/2's twin: raises the faults from_map/2 answers, as Macaw.Data.Error"
  },
  %{
    at: {Macaw.Data.Schema, :from_map!, 1},
    class: :bang,
    reason: "from_map/1's twin: raises the faults from_map/1 answers, as Macaw.Data.Error"
  },
  %{
    at: {Macaw.Data.Schema, :from_json!, 2},
    class: :bang,
    reason: "from_json/2's twin: raises the faults from_json/2 answers, as Macaw.Data.Error"
  },
  %{
    at: {Macaw.Data.Table, :from!, 2},
    class: :bang,
    reason: "from/2's twin: raises the faults from/2 answers, as Macaw.Data.Error"
  },
  %{
    at: {Macaw.Data.Delivery, :named_rows!, 1},
    class: :bang,
    reason: "named_rows/1's twin: raises the faults named_rows/1 answers, as Macaw.Data.Error"
  },
  %{
    at: {Macaw.Data.Delivery, :new!, 2},
    class: :bang,
    reason: "new/2's twin: raises the faults new/2 answers, as Macaw.Data.Error"
  },
  %{
    at: {Macaw.Data.Delivery, :rows!, 1},
    class: :bang,
    reason: "rows/1's twin: raises the faults rows/1 answers, as Macaw.Data.Error"
  },
  %{
    at: {Macaw.Data.Delivery, :table!, 2},
    class: :bang,
    reason: "table/2's twin: raises the faults table/2 answers, as Macaw.Data.Error"
  },
  %{
    at: {Macaw.Data.Derived.Columns, :column!, 2},
    class: :bang,
    reason: "column/2's twin: raises the faults column/2 answers, as Macaw.Data.Error"
  },
  %{
    at: {Macaw.Data.Derived.Columns, :count!, 2},
    class: :bang,
    reason: "count/2's twin: raises the faults count/2 answers, as Macaw.Data.Error"
  },
  %{
    at: {Macaw.Data.Derived.Columns, :instants!, 2},
    class: :bang,
    reason: "instants/2's twin: raises the faults instants/2 answers, as Macaw.Data.Error"
  },
  %{
    at: {Macaw.Data.Derived.Columns, :max!, 2},
    class: :bang,
    reason: "max/2's twin: raises the faults max/2 answers, as Macaw.Data.Error"
  },
  %{
    at: {Macaw.Data.Derived.Columns, :mean!, 2},
    class: :bang,
    reason: "mean/2's twin: raises the faults mean/2 answers, as Macaw.Data.Error"
  },
  %{
    at: {Macaw.Data.Derived.Columns, :min!, 2},
    class: :bang,
    reason: "min/2's twin: raises the faults min/2 answers, as Macaw.Data.Error"
  },
  %{
    at: {Macaw.Data.Derived.Columns, :names!, 1},
    class: :bang,
    reason: "names/1's twin: raises the faults names/1 answers, as Macaw.Data.Error"
  },
  %{
    at: {Macaw.Data.Derived.Columns, :numbers!, 2},
    class: :bang,
    reason: "numbers/2's twin: raises the faults numbers/2 answers, as Macaw.Data.Error"
  },
  %{
    at: {Macaw.Data.Derived.Columns, :rows!, 1},
    class: :bang,
    reason: "rows/1's twin: raises the faults rows/1 answers, as Macaw.Data.Error"
  },
  %{
    at: {Macaw.Data.Derived.Columns, :size!, 1},
    class: :bang,
    reason: "size/1's twin: raises the faults size/1 answers, as Macaw.Data.Error"
  },
  %{
    at: {Macaw.Data.Derived.Columns, :slice!, 3},
    class: :bang,
    reason: "slice/3's twin: raises the faults slice/3 answers, as Macaw.Data.Error"
  },
  %{
    at: {Macaw.Data.Derived.Columns, :sum!, 2},
    class: :bang,
    reason: "sum/2's twin: raises the faults sum/2 answers, as Macaw.Data.Error"
  },
  %{
    at: {Macaw.Data.Derived.Columns, :take!, 2},
    class: :bang,
    reason: "take/2's twin: raises the faults take/2 answers, as Macaw.Data.Error"
  },
  %{
    at: {Macaw.Data.Derived.Columns, :time_kind!, 2},
    class: :bang,
    reason: "time_kind/2's twin: raises the faults time_kind/2 answers, as Macaw.Data.Error"
  },
  %{
    at: {Macaw.Data.Derived.Columns, :type!, 2},
    class: :bang,
    reason: "type/2's twin: raises the faults type/2 answers, as Macaw.Data.Error"
  },
  %{
    at: {Macaw.Data.Derived.Columns, :valid!, 2},
    class: :bang,
    reason: "valid/2's twin: raises the faults valid/2 answers, as Macaw.Data.Error"
  },
  %{
    at: {Macaw.Data.Derived.Engine, :source!, 3},
    class: :bang,
    reason: "source/3's twin: raises the faults source/3 answers, as Macaw.Data.Error"
  },
  %{
    at: {Macaw.Data.Derived.Functions, :__before_compile__, 1},
    class: :compile,
    reason: "defsource: two arities of one name fail the build (spec/02 §7)"
  },
  %{
    at: {Macaw.Data.Derived.Functions, :defsource, 2},
    class: :compile,
    reason:
      "defsource: a head of another arity, or a body that is not a do block, fails the build (spec/02 §7)"
  },
  %{
    at: {Macaw.Data.Derived.Functions, :registry!, 1},
    class: :bang,
    reason: "registry/1's twin: raises the faults registry/1 answers, as Macaw.Data.Error"
  },
  %{
    at: {Macaw.Data.Derived, :new!, 1},
    class: :bang,
    reason: "new/1's twin: raises the faults new/1 answers, as Macaw.Data.Error"
  },
  %{
    at: {Macaw.Data.Derived.Sandbox.Runtime, :column!, 2},
    class: :bang,
    reason: "column/2's twin: raises the faults column/2 answers, as Macaw.Data.Error"
  },
  %{
    at: {Macaw.Data.Derived.Sandbox.Runtime, :count!, 2},
    class: :bang,
    reason: "count/2's twin: raises the faults count/2 answers, as Macaw.Data.Error"
  },
  %{
    at: {Macaw.Data.Derived.Sandbox.Runtime, :get, 2},
    class: :invariant,
    reason:
      "a stored function's field read on a table: the sandbox's rewrite of a map read raises as Map.fetch! does, and the bounded runner answers it as :raised (spec/02 §6, #107); nothing outside a stored function calls it"
  },
  %{
    at: {Macaw.Data.Derived.Sandbox.Runtime, :instants!, 2},
    class: :bang,
    reason: "instants/2's twin: raises the faults instants/2 answers, as Macaw.Data.Error"
  },
  %{
    at: {Macaw.Data.Derived.Sandbox.Runtime, :max!, 2},
    class: :bang,
    reason: "max/2's twin: raises the faults max/2 answers, as Macaw.Data.Error"
  },
  %{
    at: {Macaw.Data.Derived.Sandbox.Runtime, :mean!, 2},
    class: :bang,
    reason: "mean/2's twin: raises the faults mean/2 answers, as Macaw.Data.Error"
  },
  %{
    at: {Macaw.Data.Derived.Sandbox.Runtime, :min!, 2},
    class: :bang,
    reason: "min/2's twin: raises the faults min/2 answers, as Macaw.Data.Error"
  },
  %{
    at: {Macaw.Data.Derived.Sandbox.Runtime, :names!, 1},
    class: :bang,
    reason: "names/1's twin: raises the faults names/1 answers, as Macaw.Data.Error"
  },
  %{
    at: {Macaw.Data.Derived.Sandbox.Runtime, :numbers!, 2},
    class: :bang,
    reason: "numbers/2's twin: raises the faults numbers/2 answers, as Macaw.Data.Error"
  },
  %{
    at: {Macaw.Data.Derived.Sandbox.Runtime, :rows!, 1},
    class: :bang,
    reason: "rows/1's twin: raises the faults rows/1 answers, as Macaw.Data.Error"
  },
  %{
    at: {Macaw.Data.Derived.Sandbox.Runtime, :size!, 1},
    class: :bang,
    reason: "size/1's twin: raises the faults size/1 answers, as Macaw.Data.Error"
  },
  %{
    at: {Macaw.Data.Derived.Sandbox.Runtime, :slice!, 3},
    class: :bang,
    reason: "slice/3's twin: raises the faults slice/3 answers, as Macaw.Data.Error"
  },
  %{
    at: {Macaw.Data.Derived.Sandbox.Runtime, :sum!, 2},
    class: :bang,
    reason: "sum/2's twin: raises the faults sum/2 answers, as Macaw.Data.Error"
  },
  %{
    at: {Macaw.Data.Derived.Sandbox.Runtime, :take!, 2},
    class: :bang,
    reason: "take/2's twin: raises the faults take/2 answers, as Macaw.Data.Error"
  },
  %{
    at: {Macaw.Data.Derived.Sandbox.Runtime, :type!, 2},
    class: :bang,
    reason: "type/2's twin: raises the faults type/2 answers, as Macaw.Data.Error"
  },
  %{
    at: {Macaw.Data.Derived.Sandbox.Runtime, :valid!, 2},
    class: :bang,
    reason: "valid/2's twin: raises the faults valid/2 answers, as Macaw.Data.Error"
  },
  %{
    at: {Macaw.Data.Derived.Sandbox, :tightened!, 1},
    class: :bang,
    reason: "tightened/1's twin: raises the faults tightened/1 answers, as Macaw.Data.Error"
  },
  %{
    at: {Macaw.Data.FFT, :fft!, 1},
    class: :bang,
    reason: "fft/1's twin: raises the faults fft/1 answers, as Macaw.Data.Error"
  },
  %{
    at: {Macaw.Data.FFT, :spectrum!, 3},
    class: :bang,
    reason: "spectrum/3's twin: raises the faults spectrum/3 answers, as Macaw.Data.Error"
  },
  %{
    at: {Macaw.Data.FFT, :magnitudes!, 1},
    class: :bang,
    reason: "magnitudes/1's twin: raises the faults magnitudes/1 answers, as Macaw.Data.Error"
  },
  %{
    at: {Macaw.Data.FFT, :window!, 2},
    class: :bang,
    reason: "window/2's twin: raises the faults window/2 answers, as Macaw.Data.Error"
  },
  %{
    at: {Macaw.Data.Reduce, :lttb!, 3},
    class: :bang,
    reason: "lttb/3's twin: raises the faults lttb/3 answers, as Macaw.Data.Error"
  },
  %{
    at: {Macaw.Data.Reduce, :m4!, 3},
    class: :bang,
    reason: "m4/3's twin: raises the faults m4/3 answers, as Macaw.Data.Error"
  },
  %{
    at: {Macaw.Data.Native, :fault!, 3},
    class: :invariant,
    reason:
      "a native kernel's fault other than out of memory: every buffer, view and piece a kernel reads is packed by this library's own Elixir side and checked there, so a short buffer, a term that is no binary, a malformed piece or an unknown form is a defect in that packing, never an input's (spec/04 §1.7, macaw_data#101)"
  },
  %{
    at: {Macaw.Data.Native, :scope!, 2},
    class: :bang,
    reason:
      "scope/2's twin: passes on the raise, throw or exit that ended the function's own process, as scope/2 answers it (spec/04 §1.7, macaw_data#101)"
  },
  %{
    at: {Macaw.Data.Native.Kernels, nil, nil},
    class: :compile,
    reason: "native: :required without a toolchain fails the build (spec/04 §1.7)"
  },
  %{
    at: {Macaw.Data.Operations.Aggregates, :wrong!, 3},
    class: :invariant,
    reason:
      "a reading an aggregate does not read: Operations.aggregate/4 and the grouping steps check every reading with Aggregate.reads/1 before reducing, and answer {:reads, kind}; reduce/2 and step/3 take readings as reads/0 declares (spec/04 §3.1, §5)"
  },
  %{
    at: {Macaw.Data.Operations, :apply!, 4},
    class: :bang,
    reason: "apply/4's twin: raises the faults apply/4 answers, as Macaw.Data.Error"
  },
  %{
    at: {Macaw.Data.Operations.Cache, :run!, 5},
    class: :bang,
    reason: "run/5's twin: raises the faults run/5 answers, as Macaw.Data.Error"
  },
  %{
    at: {Macaw.Data.Operations, :registry!, 1},
    class: :bang,
    reason: "registry/1's twin: raises the faults registry/1 answers, as Macaw.Data.Error"
  },
  %{
    at: {Macaw.Data.Operations, :step_digest!, 2},
    class: :bang,
    reason: "step_digest/2's twin: raises the faults step_digest/2 answers, as Macaw.Data.Error"
  },
  %{
    at: {Macaw.Data.Operations.Step, :parts!, 4},
    class: :bang,
    reason: "parts/4's twin: raises the faults parts/4 answers, as Macaw.Data.Error"
  },
  %{
    at: {Macaw.Data.Operations.Step, :run!, 4},
    class: :bang,
    reason: "run/4's twin: raises the faults run/4 answers, as Macaw.Data.Error"
  },
  %{
    at: {Macaw.Data.Operations.Transforms, :not_a!, 4},
    class: :invariant,
    reason:
      "a reading of the wrong kind inside a step: each step's bind/3 checks its columns with Transforms.readings/3 before any chunk is read, and answers {:reads, kind} (spec/04 §3.1)"
  },
  %{
    at: {Macaw.Data.Ops, :aggregate!, 3},
    class: :bang,
    reason: "aggregate/3's twin: raises the faults aggregate/3 answers, as Macaw.Data.Error"
  },
  %{
    at: {Macaw.Data.Ops, :__run__!, 5},
    class: :bang,
    reason: "__run__/5's twin: raises the faults __run__/5 answers, as Macaw.Data.Error"
  },
  %{
    at: {Macaw.Data.Ops, :transform!, 3},
    class: :bang,
    reason: "transform/3's twin: raises the faults transform/3 answers, as Macaw.Data.Error"
  },
  %{
    at: {Macaw.Data.Quantity, :additivity!, 2},
    class: :bang,
    reason: "additivity/2's twin: raises the faults additivity/2 answers, as Macaw.Data.Error"
  },
  %{
    at: {Macaw.Data.Quantity, :base_unit!, 1},
    class: :bang,
    reason: "base_unit/1's twin: raises the faults base_unit/1 answers, as Macaw.Data.Error"
  },
  %{
    at: {Macaw.Data.Quantity, :bounds!, 1},
    class: :bang,
    reason: "bounds/1's twin: raises the faults bounds/1 answers, as Macaw.Data.Error"
  },
  %{
    at: {Macaw.Data.Quantity, :bounds!, 2},
    class: :bang,
    reason: "bounds/2's twin: raises the faults bounds/2 answers, as Macaw.Data.Error"
  },
  %{
    at: {Macaw.Data.Quantity, :family!, 2},
    class: :bang,
    reason: "family/2's twin: raises the faults family/2 answers, as Macaw.Data.Error"
  },
  %{
    at: {Macaw.Data.Quantity, :family!, 3},
    class: :bang,
    reason: "family/3's twin: raises the faults family/3 answers, as Macaw.Data.Error"
  },
  %{
    at: {Macaw.Data.Quantity, :kind!, 1},
    class: :bang,
    reason: "kind/1's twin: raises the faults kind/1 answers, as Macaw.Data.Error"
  },
  %{
    at: {Macaw.Data.Quantity, :label!, 1},
    class: :bang,
    reason: "label/1's twin: raises the faults label/1 answers, as Macaw.Data.Error"
  },
  %{
    at: {Macaw.Data.Quantity, :of_unit!, 1},
    class: :bang,
    reason: "of_unit/1's twin: raises the faults of_unit/1 answers, as Macaw.Data.Error"
  },
  %{
    at: {Macaw.Data.Schema, :new!, 1},
    class: :bang,
    reason: "new/1's twin: raises the faults new/1 answers, as Macaw.Data.Error"
  },
  %{
    at: {Macaw.Data.Source.Conformance, :__using__, 1},
    class: :compile,
    reason: "the conformance kit's options are checked as the test module compiles (spec/01 §9)"
  },
  %{
    at: {Macaw.Data.Source.Description, :new!, 1},
    class: :bang,
    reason: "new/1's twin: raises the faults new/1 answers, as Macaw.Data.Error"
  },
  %{
    at: {Macaw.Data.Source.Finish, :ceiling!, 2},
    class: :bang,
    reason: "ceiling/2's twin: raises the faults ceiling/2 answers, as Macaw.Data.Error"
  },
  %{
    at: {Macaw.Data.Source.Finish, :finish!, 4},
    class: :bang,
    reason: "finish/4's twin: raises the faults finish/4 answers, as Macaw.Data.Error"
  },
  %{
    at: {Macaw.Data.Source.Finish, :reduce!, 5},
    class: :bang,
    reason: "reduce/5's twin: raises the faults reduce/5 answers, as Macaw.Data.Error"
  },
  %{
    at: {Macaw.Data.Source.Order, :sort!, 3},
    class: :bang,
    reason: "sort/3's twin: raises the faults sort/3 answers, as Macaw.Data.Error"
  },
  %{
    at: {Macaw.Data.Source.Push, :new!, 3},
    class: :bang,
    reason: "new/3's twin: raises the faults new/3 answers, as Macaw.Data.Error"
  },
  %{
    at: {Macaw.Data.Source.Push, :trim!, 2},
    class: :bang,
    reason: "trim/2's twin: raises the faults trim/2 answers, as Macaw.Data.Error"
  },
  %{
    at: {Macaw.Data.Source.Request, :new!, 1},
    class: :bang,
    reason: "new/1's twin: raises the faults new/1 answers, as Macaw.Data.Error"
  },
  %{
    at: {Macaw.Data.Stack, :generate!, 2},
    class: :bang,
    reason: "generate/2's twin: raises the faults generate/2 answers, as Macaw.Data.Error"
  },
  %{
    at: {Macaw.Data.Stack, :stacked!, 2},
    class: :bang,
    reason: "stacked/2's twin: raises the faults stacked/2 answers, as Macaw.Data.Error"
  },
  %{
    at: {Macaw.Data.Table.Digest, :built_not_data, 1},
    class: :invariant,
    reason:
      "a term this library built is not data in the kernel's digest or encoding (macaw_layers 0.5.0 answers it as a value): a table's header holds its names and types, and a column's value no packed form holds was judged by Digest.data?/1 (as the kernel's encoder judges it, a struct by its canonical term) when Table.new/2 built the column ({[name, i], :not_data}), a chunk's derivation and combined id hold only digests, step keys and ids, Table.new/2 refuses an origin source or resolution that is not data, a step's node is checked by Operations.validate/3 (a :term option holds data only) and Step.parts/4 answers a node's own as {key, :not_data}, a registry holds names and modules, a schema's fields are judged by Schema.new/1 (spec/01 §1.1.3, §1.10; spec/04 §2)"
  },
  %{
    at: {Macaw.Data.Table, :column_types!, 1},
    class: :bang,
    reason: "column_types/1's twin: raises the faults column_types/1 answers, as Macaw.Data.Error"
  },
  %{
    at: {Macaw.Data.Table, :new!, 2},
    class: :bang,
    reason: "new/2's twin: raises the faults new/2 answers, as Macaw.Data.Error"
  },
  %{
    at: {Macaw.Data.Table, :rows!, 1},
    class: :bang,
    reason: "rows/1's twin: raises the faults rows/1 answers, as Macaw.Data.Error"
  },
  %{
    at: {Macaw.Data.Table, :rows_at!, 2},
    class: :bang,
    reason: "rows_at/2's twin: raises the faults rows_at/2 answers, as Macaw.Data.Error"
  },
  %{
    at: {Macaw.Data.Table, :time_columns!, 1},
    class: :bang,
    reason: "time_columns/1's twin: raises the faults time_columns/1 answers, as Macaw.Data.Error"
  },
  %{
    at: {Macaw.Data.Unit, :convert!, 3},
    class: :bang,
    reason: "convert/3's twin: raises the faults convert/3 answers, as Macaw.Data.Error"
  },
  %{
    at: {Macaw.Data.Unit, :dimension!, 1},
    class: :bang,
    reason: "dimension/1's twin: raises the faults dimension/1 answers, as Macaw.Data.Error"
  },
  %{
    at: {Macaw.Data.Unit, :factor!, 1},
    class: :bang,
    reason: "factor/1's twin: raises the faults factor/1 answers, as Macaw.Data.Error"
  },
  %{
    at: {Macaw.Data.Unit, :kind!, 1},
    class: :bang,
    reason: "kind/1's twin: raises the faults kind/1 answers, as Macaw.Data.Error"
  },
  %{
    at: {Macaw.Data.Unit, :minor_units!, 1},
    class: :bang,
    reason: "minor_units/1's twin: raises the faults minor_units/1 answers, as Macaw.Data.Error"
  },
  %{
    at: {Macaw.Data.Unit, :symbol!, 2},
    class: :bang,
    reason: "symbol/2's twin: raises the faults symbol/2 answers, as Macaw.Data.Error"
  }
]
