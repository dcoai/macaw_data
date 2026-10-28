defmodule Macaw.Data.MixProject do
  use Mix.Project

  @source_url "https://github.com/dcoai/macaw_data"
  @version "0.5.3"

  def project do
    [
      app: :macaw_data,
      version: @version,
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description:
        "Macaw's data layer: the interaction event, the data model, the source contract, derived sources, and the transforms and aggregates they share with designs.",
      source_url: @source_url,
      package: package(),
      docs: [main: "readme", extras: ["README.md", "CHANGELOG.md"], source_ref: "v#{@version}"]
    ]
  end

  def application, do: [extra_applications: [:logger]]

  # `test/support` holds the metresis parity table (spec/03), compiled in test only.
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Published on Hex from its public home, mirrored from GitLab (dco-tek/macaw/macaw#155).
  defp package do
    [
      licenses: ["MIT"],
      links: %{
        "GitHub" => @source_url,
        "Changelog" => "https://hexdocs.pm/macaw_data/changelog.html"
      },
      files: ~w(lib spec mix.exs README.md LICENSE CHANGELOG.md .formatter.exs)
    ]
  end

  defp deps do
    [
      # The document kernel (macaw_compose spec/00 §4): names, vocabularies, the scan and
      # limits a schema's JSON is read through, and the digest that is its version.
      {:macaw_layers, "~> 0.2.2"},
      # Optional readers at the table's edge (spec/01 §1.1): a host that has either gets
      # its tensors or `Table.Reader` sources read into a table; one that has neither never
      # fetches them.
      {:table, "~> 0.1.2", optional: true},
      {:nx, "~> 1.0", optional: true},
      {:stream_data, "~> 1.1", only: :test},
      # Docs for Hex (macaw_compose#155); dev only.
      {:ex_doc, "~> 0.34", only: :dev, runtime: false},
      # Spec, tests and code kept aligned (macaw_compose spec/00 §4.1); dev/test only.
      {:surfex, "~> 0.10.0", only: [:dev, :test], runtime: false}
    ]
  end
end
