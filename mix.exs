defmodule ExPoser.MixProject do
  use Mix.Project

  def project do
    [
      app: :ex_poser,
      version: "0.1.0",
      elixir: "~> 1.20",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps(),
      name: "ExPoser",
      source_url: "https://github.com/twajjo/ex_poser",
      docs: docs()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger],
      mod: {ExPoser.Application, []}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp docs do
    [
      main: "getting-started",
      extras: [
        "guides/getting-started.md",
        "guides/concepts.md",
        {"guides/posing.md", filename: "posing"},
        "guides/frames-and-keyframes.md",
        "guides/batching.md",
        "guides/errors.md",
        "guides/generated-api.md",
        "guides/idiomatic-api.cheatmd",
        {"guides/posing.livemd", filename: "posing-livebook", title: "Posing tour"},
        "guides/setup.md",
        "guides/limitations.md"
      ],
      groups_for_extras: [
        Introduction: ["guides/getting-started.md", "guides/concepts.md"],
        Guides: [
          "guides/posing.md",
          "guides/frames-and-keyframes.md",
          "guides/batching.md",
          "guides/errors.md",
          "guides/generated-api.md"
        ],
        Cheatsheets: ["guides/idiomatic-api.cheatmd"],
        Livebook: ["guides/posing.livemd"],
        Reference: ["guides/setup.md", "guides/limitations.md"]
      ],
      groups_for_modules: [
        "Idiomatic API": [
          ExPoser,
          ExPoser.Scene,
          ExPoser.Figure,
          ExPoser.Actor,
          ExPoser.Parameter,
          ExPoser.Batch
        ],
        Errors: [ExPoser.Error],
        "Generated API": [~r/^ExPoser\.Api/, ExPoser.Const],
        Connection: [
          ExPoser.Client,
          ExPoser.Session,
          ExPoser.Transport,
          ExPoser.Transport.TCP,
          ExPoser.Events,
          ExPoser.Handle
        ],
        Internals: [
          ExPoser.Ref,
          ExPoser.Codec,
          ExPoser.Call,
          ~r/^ExPoser\.Gen\./,
          ExPoser.Smoke,
          ExPoser.NDArray
        ]
      ]
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:nx, "~> 1.0", optional: true},
      {:ex_doc, "~> 0.40", only: :dev, runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false}
    ]
  end
end
