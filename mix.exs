defmodule Macaw.Data.MixProject do
  use Mix.Project

  @version "0.1.0"

  def project do
    [
      app: :macaw_data,
      version: @version,
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description:
        "Macaw's data layer: the interaction event, the data model, the source contract and derived sources.",
      package: [licenses: ["MIT"]],
      docs: [main: "readme", extras: ["README.md"]]
    ]
  end

  def application, do: [extra_applications: [:logger]]

  defp deps, do: [{:stream_data, "~> 1.1", only: :test}]
end
