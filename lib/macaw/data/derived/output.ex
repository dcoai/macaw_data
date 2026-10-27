defmodule Macaw.Data.Derived.Output do
  @moduledoc """
  A derived source's answer read as any source's (spec/02 §8.5): a `Macaw.Data.Source`
  over an engine's last good output at one path, made by `Macaw.Data.Derived.Engine.source/3`.

  - `describe/2` answers the output schema, `supports: []`, no parameters, and
    `viewer_independent` as the owner declared it;
  - `fetch/2` answers the last good output whole, or `{:error, :loading}` before the first.
    It honors nothing, so the runtime finishes it (spec/01 §2.4);
  - it does not push: its owner's engine is what changes it, and the owner tells readers
    (spec/01 §5).

  So a derived source is another derived source's input and a slot's source alike, and the
  conformance kit holds it as it holds any source.
  """
  @behaviour Macaw.Data.Source

  alias Macaw.Data.{Delivery, Schema}
  alias Macaw.Data.Source.Description

  @enforce_keys [:schema]
  defstruct [:schema, delivery: nil, viewer_independent: false]

  @type t :: %__MODULE__{
          schema: Schema.t(),
          delivery: Delivery.t() | nil,
          viewer_independent: boolean()
        }

  @impl true
  def describe(%__MODULE__{schema: schema, viewer_independent: independent}, _context),
    do: Description.new(schema: schema, viewer_independent: independent)

  @impl true
  def fetch(%__MODULE__{delivery: nil}, _request), do: {:error, :loading}
  def fetch(%__MODULE__{delivery: %Delivery{} = delivery}, _request), do: {:ok, delivery}
end
