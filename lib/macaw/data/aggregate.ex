defmodule Macaw.Data.Aggregate do
  @moduledoc """
  The aggregate behavior (spec/04 §1.2): a statistic, one column's readings reduced to one
  value (visualize#909).

  `reduce/2` is given the readings with every `nil` dropped, since a gap is absence, never
  zero (spec/01 §1.1). An aggregate may also give the streaming form, `init/1`, `step/3`
  and `finish/2` together, over the same readings in the same order:

      finish(Enum.reduce(values, init(options), &step(&2, &1, options)), options)
      == reduce(values, options)

  An aggregate with the streaming form may also give the combining form, `merge/3`: the
  state of two runs of readings from each run's state, associative, so a table's chunks
  are reduced one by one and their states merged (spec/04 §1.4).

  Its options are checked as a transform's are (`Macaw.Data.Operations.Option`), and may
  not be a key of a step that names it (`Macaw.Data.Operations.step_keys/0`): the registry
  refuses one that is.
  """

  alias Macaw.Data.Operations.Option
  alias Macaw.Data.Table

  @typedoc "Checked options: each declared option by its string, its default filled in."
  @type options :: %{String.t() => term()}

  @doc "The name a node's `fn` or a stored function names, unique in a registry."
  @callback name() :: String.t()

  @doc "The keys the aggregate reads."
  @callback options() :: [{String.t(), Option.t()}]

  @doc "The output's table type for an input column of `type`."
  @callback output(Table.type(), options()) :: Table.type()

  @doc "Whether the input's unit and quantity carry to the output."
  @callback keeps_unit?() :: boolean()

  @doc "The value of the readings, `nil`s already dropped."
  @callback reduce([term()], options()) :: term()

  @doc "The streaming form's first state."
  @callback init(options()) :: term()

  @doc "The streaming form's state after one more reading."
  @callback step(term(), term(), options()) :: term()

  @doc "The streaming form's value of its state."
  @callback finish(term(), options()) :: term()

  @doc """
  The combining form (spec/04 §1.2): the state of two runs of readings, the first
  before the second, from each run's state. Associative, so a step's per-chunk partials
  merge under any grouping: `merge(state(a), state(b)) == state(a ++ b)` by value.
  """
  @callback merge(term(), term(), options()) :: term()

  @doc """
  The inverse of the combining form, where it is exact (spec/04 §1.2, §1.5): the state of
  a run of readings with some of them removed, from the run's state and the removed
  readings' state, `{:ok, state}`; `:inexact` where the subtraction could differ from
  the state of the remaining readings, as a floating-point sum's would.
  """
  @callback retract(term(), term(), options()) :: {:ok, term()} | :inexact

  @optional_callbacks init: 1, step: 3, finish: 2, merge: 3, retract: 3
end
