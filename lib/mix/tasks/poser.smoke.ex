defmodule Mix.Tasks.Poser.Smoke do
  @shortdoc "Calls every generated getter against the running Poser"
  @moduledoc """
  Connects to Poser, walks the open scene through every generated getter
  (see `Poser.Smoke`), writes a JSON report and prints a summary.

      mix poser.smoke [--per-class N] [--include-heavy] [--timeout MS]
                      [--out PATH] [--manifest PATH] [--session PATH]

  Defaults: 3 objects per class, 30 000 ms per call,
  `tmp/poser_smoke.json`, `priv/poser_api_manifest.json`, and the usual
  session file. Python errors are outcomes, not failures; the task exits 0
  whenever the walk completes.
  """

  use Mix.Task

  @switches [
    per_class: :integer,
    include_heavy: :boolean,
    timeout: :integer,
    out: :string,
    manifest: :string,
    session: :string
  ]

  @impl true
  def run(argv) do
    {opts, _} = OptionParser.parse!(argv, strict: @switches)
    Mix.Task.run("app.start")

    manifest =
      opts
      |> Keyword.get(:manifest, "priv/poser_api_manifest.json")
      |> File.read!()
      |> JSON.decode!()

    out = Keyword.get(opts, :out, "tmp/poser_smoke.json")
    name = :poser_smoke_client
    session = Keyword.get(opts, :session, Poser.Session.default_path())
    {:ok, _} = Poser.Client.start_link(name: name, session: session)
    wait_connected(name, 50)

    smoke_opts = [server: name] ++ Keyword.take(opts, [:per_class, :include_heavy, :timeout])
    {us, report} = :timer.tc(fn -> Poser.Smoke.run(manifest, smoke_opts) end)

    File.mkdir_p!(Path.dirname(out))
    File.write!(out, Poser.Gen.Render.json(report))
    print(report, out, div(us, 1000))
  end

  defp wait_connected(name, 0),
    do:
      Mix.raise(
        "poser.smoke: cannot connect to Poser: #{inspect(Poser.Client.ping(server: name))}"
      )

  defp wait_connected(name, n) do
    if Poser.Client.status(server: name) == :connected do
      :ok
    else
      Process.sleep(200)
      wait_connected(name, n - 1)
    end
  end

  defp print(report, out, ms) do
    s = report["summary"]
    getters = report["getters"]

    python =
      getters
      |> Enum.flat_map(fn {_, e} -> Map.to_list(e["outcomes"]["python"] || %{}) end)
      |> Enum.reduce(%{}, fn {class, n}, acc -> Map.update(acc, class, n, &(&1 + n)) end)
      |> Enum.sort_by(&elem(&1, 1), :desc)

    slowest = getters |> Enum.sort_by(fn {_, e} -> -e["max_ms"] end) |> Enum.take(10)

    problems =
      for {key, e} <- Enum.sort(getters),
          Enum.any?(~w(timeout stale_handle bad_request other), &Map.has_key?(e["outcomes"], &1)),
          do: "  #{key}: #{inspect(Map.drop(e["outcomes"], ["ok", "python"]))}"

    Mix.shell().info("""
    poser.smoke: #{s["calls"]} calls to #{s["getters"]} getters in #{ms} ms (report: #{out})
      ok #{s["ok"]}, python errors #{s["python"]}, timeouts #{s["timeout"]}, stale #{s["stale_handle"]}, bad requests #{s["bad_request"]}, other #{s["other"]}
      getters that returned ok at least once: #{s["getters_ok"]}; skipped: #{s["skipped"]}
      explored: #{report["explored"] |> Enum.sort() |> Enum.map_join(", ", fn {c, n} -> "#{c} #{n}" end)}
      classes not in the dump: #{Enum.join(report["unknown_classes"], ", ")}
    python errors by class: #{Enum.map_join(python, ", ", fn {c, n} -> "#{c} #{n}" end)}
    slowest getters:
    #{Enum.map_join(slowest, "\n", fn {k, e} -> "  #{k} #{e["max_ms"]} ms" end)}
    problems:
    #{if problems == [], do: "  none", else: Enum.join(problems, "\n")}
    """)
  end
end
