defmodule Macaw.Data.MixProject do
  use Mix.Project

  @source_url "https://github.com/dcoai/macaw_data"
  @version "0.8.1"

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
      docs: [
        main: "readme",
        extras: ["README.md", "CHANGELOG.md"],
        source_ref: "v#{@version}",
        logo: "brand/logo/macaw_scarlet.svg",
        assets: %{"brand/logo" => "brand/logo"}
      ]
    ]
  end

  # The application decides once, at start, whether the native kernels loaded (spec/04 §1.7).
  def application, do: [mod: {Macaw.Data.Application, []}, extra_applications: [:logger]]

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
      files: ~w(lib spec mix.exs README.md LICENSE CHANGELOG.md .formatter.exs .tool-versions),
      # Zigler writes its copy of a module's Zig source beside it at compile time
      # (`.Elixir.<Module>.zig`, gitignored), so a package built from a checkout that compiled
      # the kernels would carry it (macaw_data#76). ci/adopter_boot.exs refuses any.
      exclude_patterns: [~r"(^|/)\.Elixir\.[^/]*$"]
    ]
  end

  defp deps do
    [
      # The document kernel (macaw_compose spec/00 §4): names, vocabularies, the scan and
      # limits a schema's JSON is read through, and the digest that is its version.
      {:macaw_layers, "~> 0.4.0"},
      # Optional readers at the table's edge (spec/01 §1.1): a host that has either gets
      # its tensors or `Table.Reader` sources read into a table; one that has neither never
      # fetches them.
      {:table, "~> 0.1.2", optional: true},
      {:nx, "~> 1.0", optional: true},
      # The optional native kernels (spec/04 §1.7), Zig built through Zigler at compile time
      # when a Zig of the version Zigler targets is present; a build tool only, nothing of it
      # runs. 0.16.0 targets Zig 0.16.0 (`.tool-versions`). Optional, so an adopter opts in
      # by listing it: its zig_doc pins ex_doc to 0.39.1, which no adopter should inherit.
      {:zigler, "~> 0.16.0", runtime: false, optional: true},
      {:stream_data, "~> 1.1", only: :test},
      # Docs for Hex (macaw_compose#155). Zigler's zig_doc needs it wherever Zigler compiles,
      # so dev and test, at the version zig_doc pins (`override`: ours stays dev/test only).
      {:ex_doc, "~> 0.34", only: [:dev, :test], runtime: false, override: true},
      # Spec, tests and code kept aligned (macaw_compose spec/00 §4.1); dev/test only.
      {:surfex, "~> 0.11.0", only: [:dev, :test], runtime: false}
    ]
  end
end
