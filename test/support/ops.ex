defmodule Macaw.Data.Test.Ops do
  @moduledoc false
  # A host's package of operations (spec/04 §2), for the registry's and the sandbox's
  # tests: a table transform, one needing a frame, one with a frame-bound option, a
  # reducer, and two aggregates, one streaming and one with an option.

  def __members__,
    do: [
      __MODULE__.Double,
      __MODULE__.Layout,
      __MODULE__.Every,
      __MODULE__.Spread,
      __MODULE__.Scaled,
      __MODULE__.Stamp
    ]

  defmodule Double do
    @moduledoc false
    @behaviour Macaw.Data.Transform
    alias Macaw.Data.Operations
    alias Macaw.Data.Operations.Option
    alias Macaw.Data.Table

    @impl true
    def name, do: "double"

    @impl true
    def options do
      [
        {"field", %Option{type: :field, required: true, doc: "the column doubled"}},
        {"as", %Option{type: :name, default: "double", doc: "the column it is put in"}}
      ]
    end

    @impl true
    def needs, do: []

    @impl true
    def outputs(%{"as" => as}, columns), do: columns ++ [{as, :number}]

    @impl true
    def run(%{"field" => field, "as" => as} = node, table, _context) do
      rows = for row <- Table.rows(table), do: Map.put(row, as, 2 * Table.get(row, field))
      Operations.table(rows, outputs(node, Operations.columns(table)))
    end
  end

  defmodule Layout do
    @moduledoc false
    @behaviour Macaw.Data.Transform
    alias Macaw.Data.Operations
    alias Macaw.Data.Operations.Option
    alias Macaw.Data.Table

    @impl true
    def name, do: "layout"

    @impl true
    def options, do: [{"padding", %Option{type: :number, default: 0}}]

    @impl true
    def needs, do: [:frame]

    @impl true
    def outputs(_node, columns), do: columns ++ [{"x", :number}]

    @impl true
    def run(node, table, %{frame: %{width: width}}) do
      n = max(Table.size(table), 1)

      rows =
        for {row, i} <- Enum.with_index(Table.rows(table)), do: Map.put(row, "x", i * width / n)

      Operations.table(rows, outputs(node, Operations.columns(table)))
    end
  end

  # Every n-th row: a reducer whose count is frame-bound.
  defmodule Every do
    @moduledoc false
    @behaviour Macaw.Data.Transform
    alias Macaw.Data.Operations
    alias Macaw.Data.Operations.Option
    alias Macaw.Data.Table

    @impl true
    def name, do: "every"

    @impl true
    def options do
      [
        {"fields", %Option{type: {:pair, :field}, required: true}},
        {"n", %Option{type: {:integer, 2}, required: true, frame: :width}}
      ]
    end

    @impl true
    def needs, do: []

    @impl true
    def reduces, do: {"n", 1}

    @impl true
    def outputs(_node, columns), do: columns

    @impl true
    def run(%{"n" => n}, table, _context) do
      rows = Table.rows(table)
      size = length(rows)

      kept =
        if size <= n,
          do: rows,
          else: for(i <- 0..(n - 1), do: Enum.at(rows, round(i * (size - 1) / (n - 1))))

      Operations.table(kept, Operations.columns(table))
    end
  end

  # The context's now and the count of its schema's fields, as columns.
  defmodule Stamp do
    @moduledoc false
    @behaviour Macaw.Data.Transform
    alias Macaw.Data.Operations
    alias Macaw.Data.Table

    @impl true
    def name, do: "stamp"
    @impl true
    def options, do: []
    @impl true
    def needs, do: []
    @impl true
    def outputs(_node, columns), do: columns ++ [{"now", :time}, {"fields", :number}]

    @impl true
    def run(node, table, context) do
      fields = map_size(context.schema.fields)

      rows =
        for row <- Table.rows(table),
            do: Map.merge(row, %{"now" => context.now, "fields" => fields})

      Operations.table(rows, outputs(node, Operations.columns(table)))
    end
  end

  defmodule Spread do
    @moduledoc false
    @behaviour Macaw.Data.Aggregate

    @impl true
    def name, do: "spread"
    @impl true
    def options, do: []
    @impl true
    def output(type, _options), do: type
    @impl true
    def keeps_unit?, do: true

    @impl true
    def reduce([], _options), do: nil
    def reduce(values, _options), do: Enum.max(values) - Enum.min(values)

    @impl true
    def init(_options), do: nil
    @impl true
    def step(nil, value, _options), do: {value, value}
    def step({low, high}, value, _options), do: {min(low, value), max(high, value)}
    @impl true
    def finish(nil, _options), do: nil
    def finish({low, high}, _options), do: high - low
  end

  defmodule Scaled do
    @moduledoc false
    @behaviour Macaw.Data.Aggregate
    alias Macaw.Data.Operations.Option

    @impl true
    def name, do: "scaled"
    @impl true
    def options, do: [{"scale", %Option{type: :number, required: true}}]
    @impl true
    def output(_type, _options), do: :number
    @impl true
    def keeps_unit?, do: false
    @impl true
    def reduce(values, %{"scale" => scale}), do: Enum.sum(values) * scale
  end
end

defmodule Macaw.Data.Test.Ops.Twin do
  @moduledoc false
  # A package naming a transform another package names.
  def __members__, do: [__MODULE__.Double]

  defmodule Double do
    @moduledoc false
    @behaviour Macaw.Data.Transform
    def name, do: "double"
    def options, do: []
    def needs, do: []
    def outputs(_node, columns), do: columns
    def run(_node, table, _context), do: table
  end
end

defmodule Macaw.Data.Test.Ops.Greedy do
  @moduledoc false
  # A package whose aggregate declares a step's key as its own option.
  def __members__, do: [__MODULE__.ByField]

  defmodule ByField do
    @moduledoc false
    @behaviour Macaw.Data.Aggregate
    alias Macaw.Data.Operations.Option
    def name, do: "by_field"
    def options, do: [{"field", %Option{type: :field}}]
    def output(type, _options), do: type
    def keeps_unit?, do: true
    def reduce(values, _options), do: length(values)
  end
end

defmodule Macaw.Data.Test.Ops.Stray do
  @moduledoc false
  # A package listing a module that implements no behavior.
  def __members__, do: [String]
end
