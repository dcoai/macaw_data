defmodule Macaw.Data.MixProject do
  use Mix.Project

  @version "0.1.0"

  def project do
    [
      app: :macaw_data,
      version: @version,
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description:
        "Macaw's data layer: the interaction event, the data model, the source contract and derived sources.",
      package: [licenses: ["MIT"]],
      docs: [main: "readme", extras: ["README.md"]]
    ]
  end

  def application, do: [extra_applications: [:logger]]

  # `test/support` holds the metresis parity table (spec/03), compiled in test only.
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:stream_data, "~> 1.1", only: :test},
      # Spec, tests and code kept aligned (macaw_compose spec/00 §4.1); dev/test only.
      {:surfex, "~> 0.10.0", only: [:dev, :test], runtime: false}
    ]
  end
end
