defmodule Poserx.MixProject do
  use Mix.Project

  def project do
    [
      app: :poserx,
      version: "0.1.0",
      elixir: "~> 1.20",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps(),
      name: "Poserx",
      source_url: "https://github.com/twajjo/poserx",
      docs: docs()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger],
      mod: {Poserx.Application, []}
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
          Poser,
          Poser.Scene,
          Poser.Figure,
          Poser.Actor,
          Poser.Parameter,
          Poser.Batch
        ],
        Errors: [Poser.Error],
        "Generated API": [~r/^Poser\.Api/, Poser.Const],
        Connection: [
          Poser.Client,
          Poser.Session,
          Poser.Transport,
          Poser.Transport.TCP,
          Poser.Events,
          Poser.Handle
        ],
        Internals: [
          Poser.Ref,
          Poser.Codec,
          Poser.Call,
          ~r/^Poser\.Gen\./,
          Poser.Smoke,
          Poser.NDArray
        ]
      ]
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:nx, "~> 1.0", optional: true},
      {:ex_doc, "~> 0.40", only: :dev, runtime: false}
    ]
  end
end
