defmodule Macaw.Data.Transform do
  @moduledoc """
  The transform behavior (spec/04 §1.1): one step of a data pipeline, a table in and a
  table out, declared once so the validator, a drawer's forms and vocabulary, the JSON
  forms and the sandbox all read the same declaration (visualize#886).

      defmodule MyApp.Ops.Clip do
        @behaviour Macaw.Data.Transform
        alias Macaw.Data.Operations.Option

        @impl true
        def name, do: "clip"
        @impl true
        def options, do: [{"field", %Option{type: :field, required: true}}]
        @impl true
        def needs, do: []
        @impl true
        def outputs(_node, columns), do: columns
        @impl true
        def run(node, table, _context), do: ...
      end

  A member is pure and deterministic: no processes, ETS, NIFs, `Regex`, clock or
  randomness. `run/3` and `outputs/2` are given the node checked
  (`Macaw.Data.Operations.validate/3`): its keys strings, every option present with its
  default filled in, an enum value its atom, a frame-bound `"plot"` already a number.
  """

  alias Macaw.Data.Operations.Option
  alias Macaw.Data.Table

  @typedoc "A checked node: the op's options by their strings, each holding its value."
  @type node_map :: %{String.t() => term()}

  @typedoc "Columns in order, each with its `Macaw.Data.Table` type."
  @type columns :: [{Table.name(), Table.type()}]

  @typedoc "Context a transform may need beyond the data: a drawer's frame, projection, text."
  @type need :: :frame | :projection | :text

  @doc "The op a node names, unique in a registry."
  @callback name() :: String.t()

  @doc "Every key the op reads, in order, each declared."
  @callback options() :: [{String.t(), Option.t()}]

  @doc "The context the op requires beyond the data: `[]` for a table operation."
  @callback needs() :: [need()]

  @doc "The columns `run/3` answers for the node over input `columns`."
  @callback outputs(node_map(), columns()) :: columns()

  @doc "The step: the table after it."
  @callback run(node_map(), Table.t(), map()) :: Table.t()

  @doc "A reducer's count option and the rows each unit of it keeps at most (spec/04 §7)."
  @callback reduces() :: {String.t(), pos_integer()}

  @doc "Computed once per design and shared by its marks, under the context's `prepared`."
  @callback prepare([node_map()], Table.t(), map()) :: term()

  @typedoc "A step's class (spec/04 §1.4), which decides its merge."
  @type class :: :row | :combine | :global

  @doc """
  A column-native step's class for the node (spec/04 §1.4): `:row`, each chunk worked by
  itself and merged by concatenation; `:combine`, partials merged associatively; `:global`,
  a merge over the whole input. `Macaw.Data.Operations.Step` runs it.
  """
  @callback class(node_map()) :: class()

  @doc "The keys of the caller's context the step reads; no other key reaches it."
  @callback reads() :: [atom()]

  @doc """
  The declared context resolved over the whole input, once: a map the step's `resolve/3`
  is given. Without it the declared context is given as it is.
  """
  @callback bind(node_map(), Table.t(), map()) :: map()

  @doc """
  The context as it resolves for one chunk's view, given the bound context and the view's
  place (`:at`, its first row in the input, and `:rows`, the input's count). Part of the
  chunk's step key.
  """
  @callback resolve(node_map(), Table.view(), map()) :: term()

  @doc "One chunk's part, from its view and the context resolved for it."
  @callback chunk(node_map(), Table.view(), term()) :: term()

  @optional_callbacks reduces: 0, prepare: 3, class: 1, reads: 0, bind: 3, resolve: 3, chunk: 3
end
