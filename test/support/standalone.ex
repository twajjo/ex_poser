defmodule PoserTest.Standalone do
  @moduledoc """
  Runs python/standalone_server.py (fake poser) for a test. The server exits
  when its stdin closes, i.e. when the owning process stops.
  """

  @doc """
  Options: `mode: :dev | :strict`, `session: path` (reuse a session file
  path), `events: seconds` (fake frame_changed interval, default off).
  """
  def start!(opts \\ []) do
    session = opts[:session] || tmp_session()
    parent = self()
    ref = make_ref()
    pid = spawn_link(fn -> run(parent, ref, session, opts) end)

    receive do
      {^ref, :ready} -> %{pid: pid, session: session}
      {^ref, {:failed, output}} -> raise "standalone server did not start:\n#{output}"
    after
      10_000 -> raise "standalone server did not start within 10 s"
    end
  end

  def stop!(%{pid: pid}) do
    ref = Process.monitor(pid)
    send(pid, :stop)

    receive do
      {:DOWN, ^ref, _, _, _} -> :ok
    after
      5_000 -> raise "standalone server did not stop"
    end
  end

  defp tmp_session do
    dir = Path.join(System.tmp_dir!(), "ex_poser-test-#{System.unique_integer([:positive])}")
    Path.join(dir, "session.json")
  end

  defp run(parent, ref, session, opts) do
    File.rm(session)

    args =
      [Path.join(PoserTest.Python.root(), "python/standalone_server.py")] ++
        ["--port", "0", "--session", session, "--exit-on-stdin-eof"] ++
        ["--events", to_string(opts[:events] || 0)] ++ mode_args(opts[:mode] || :dev)

    port =
      Port.open({:spawn_executable, PoserTest.Python.path()}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        {:line, 4096},
        args: args
      ])

    wait_ready(parent, ref, port, [])
  end

  defp mode_args(:dev), do: ["--mode", "dev"]

  defp mode_args(:strict),
    do: [
      "--mode",
      "strict",
      "--api",
      Path.join(PoserTest.Python.root(), "python/tests/fixtures/mini_api.json")
    ]

  defp wait_ready(parent, ref, port, lines) do
    receive do
      {^port, {:data, {:eol, "session file " <> _}}} ->
        send(parent, {ref, :ready})
        loop(port)

      {^port, {:data, {_, line}}} ->
        wait_ready(parent, ref, port, [line | lines])

      {^port, {:exit_status, _}} ->
        send(parent, {ref, {:failed, lines |> Enum.reverse() |> Enum.join("\n")}})
    end
  end

  # Drain output until told to stop; closing the port closes the server's stdin.
  defp loop(port) do
    receive do
      :stop -> Port.close(port)
      {^port, {:exit_status, _}} -> :ok
      {^port, _} -> loop(port)
    end
  end
end
