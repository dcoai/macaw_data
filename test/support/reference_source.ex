defmodule Macaw.Data.Test.Reference do
  @moduledoc """
  A reference source for the contract's tests: a clock-free table of `t` and
  `v` over a numeric window field, a `scale` parameter, and every capability it is asked
  to declare. It honors the window and the budget itself; it does not push.
  """
  @behaviour Macaw.Data.Source

  alias Macaw.Data.{Delivery, Schema}
  alias Macaw.Data.Source.Description

  defstruct rows: 20, supports: [:window, :budget], viewer_independent: true

  @schema Schema.new!(%{
            "t" => %{type: :number, window: true},
            "v" => %{type: :number, unit: "ms"},
            "who" => %{type: :text}
          })

  @impl true
  def describe(%__MODULE__{} = source, _context) do
    Description.new(
      schema: @schema,
      params: %{"scale" => %{type: :number, default: 1, doc: "multiplies v"}},
      supports: source.supports,
      viewer_independent: source.viewer_independent
    )
  end

  @impl true
  def fetch(%__MODULE__{rows: n}, request) do
    scale = request.params["scale"]

    all =
      for t <- 1..n//1, within?(t, request.window) do
        %{"t" => t, "v" => t * scale, "who" => viewer_name(request.viewer)}
      end

    rows = if request.budget, do: Enum.take(all, request.budget), else: all

    {:ok,
     Delivery.new(rows,
       types: %{"t" => :number, "v" => :number, "who" => :text},
       schema: Schema.version(@schema),
       served: [
         window: request.window,
         reduced_by: if(length(rows) < length(all), do: :source)
       ]
     )}
  end

  defp within?(_t, nil), do: true
  defp within?(t, [from, to]), do: (from == nil or t >= from) and (to == nil or t <= to)

  # A viewer-independent source answers every viewer the same, whoever asks.
  defp viewer_name(_viewer), do: "anyone"
end
