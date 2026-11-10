# Phase 0 spike client for the ExPoser bridge.
#
#   elixir scripts/phase0_ping.exs [--session PATH] [--host IP] [--samples N]
#                                  [--listen SECONDS] [--bad-token]
#
# Reads the session file the add-on writes, does the hello handshake, measures
# ping (reader thread only) and ping_main (through wx.CallAfter) latency, calls
# a spike helper and an erroring function, then prints events for a while.

defmodule Phase0Ping do
  # Atoms the bridge may send; they must exist for binary_to_term(..., [:safe]).
  @known_atoms [:r, :e, :M, :pong, :frame_changed, :python, :obj, :bytes, :bad_request] ++
                 [:protocol_mismatch, :protocol, :mode, :dev, :strict] ++
                 [:poser_version, :python_version, :api_hash, :client, :poser_obj]

  def main(argv) do
    {opts, _rest, _invalid} =
      OptionParser.parse(argv,
        strict: [session: :string, host: :string, samples: :integer, listen: :integer, bad_token: :boolean]
      )

    path = opts[:session] || default_session_path()
    %{"port" => port, "token" => token, "hosts" => hosts} = path |> File.read!() |> JSON.decode!()
    host = opts[:host] || pick_host(hosts)
    token = if opts[:bad_token], do: "not-the-token", else: token

    IO.puts("session #{path}\nconnecting to #{host}:#{port}")

    {:ok, sock} =
      :gen_tcp.connect(String.to_charlist(host), port, [:binary, packet: 4, active: false, nodelay: true], 5_000)

    send_term(sock, {:hello, %{token: token, protocol: 1}})

    case recv(sock, 5_000) do
      {:ok, {:r, 0, info}} ->
        IO.puts("hello: #{inspect(info)}")

      other ->
        IO.puts("handshake failed: #{inspect(other)}")
        System.halt(1)
    end

    samples = opts[:samples] || 200
    report("ping      (reader thread)", time_requests(sock, :ping, samples))
    report("ping_main (wx.CallAfter) ", time_requests(sock, :ping_main, samples))

    IO.puts("scene_summary: #{inspect(call(sock, {:X, "ex_poser_bridge.spike", "scene_summary", []}))}")

    case call(sock, {:X, "math", "sqrt", [-1]}) do
      {:e, _id, {:python, class, msg, tb}} ->
        IO.puts("error path ok: #{class}: #{msg} (#{length(tb)} traceback lines)")

      other ->
        IO.puts("error path FAILED: #{inspect(other)}")
    end

    listen = opts[:listen] || 10
    IO.puts("listening for events for #{listen}s (scrub the timeline in Poser)...")
    listen_events(sock, System.monotonic_time(:millisecond) + listen * 1_000)
    :gen_tcp.close(sock)
  end

  def known_atoms, do: @known_atoms

  defp default_session_path do
    appdata =
      with {out, 0} <- System.cmd("cmd.exe", ["/c", "echo %APPDATA%"], cd: "/mnt/c", stderr_to_stdout: true),
           {path, 0} <- System.cmd("wslpath", ["-u", String.trim(out)]) do
        String.trim(path)
      else
        _ -> "/mnt/c/Users/Jeff/AppData/Roaming"
      end

    Path.join([appdata, "PoserBridge", "session.json"])
  rescue
    ErlangError -> "/mnt/c/Users/Jeff/AppData/Roaming/PoserBridge/session.json"
  end

  # The add-on binds 127.0.0.1 plus the WSL adapter; from WSL only the adapter works.
  defp pick_host(hosts) do
    case Enum.reject(hosts, &(&1 == "127.0.0.1")) do
      [host | _] -> host
      [] -> default_gateway()
    end
  end

  defp default_gateway do
    {out, 0} = System.cmd("ip", ["route", "show", "default"])
    [_, gw] = Regex.run(~r/default via (\S+)/, out)
    gw
  end

  defp time_requests(sock, op, n) do
    for _ <- 1..n do
      t0 = System.monotonic_time(:microsecond)
      {:r, _id, :pong} = call(sock, {op})
      System.monotonic_time(:microsecond) - t0
    end
  end

  defp report(label, times) do
    sorted = Enum.sort(times)
    n = length(sorted)
    at = fn q -> Enum.at(sorted, min(n - 1, trunc(q * n))) end

    IO.puts(
      "#{label}: n=#{n} min=#{hd(sorted)}us median=#{at.(0.5)}us p95=#{at.(0.95)}us max=#{List.last(sorted)}us"
    )
  end

  # Sends `request` (a tuple without id) and waits for the matching reply,
  # printing any events that arrive in between.
  defp call(sock, request, timeout \\ 30_000) do
    id = System.unique_integer([:positive])
    send_term(sock, request |> Tuple.insert_at(1, id))
    await(sock, id, timeout)
  end

  defp await(sock, id, timeout) do
    case recv(sock, timeout) do
      {:ok, {tag, ^id, _} = reply} when tag in [:r, :e] -> reply
      {:ok, {:M, event}} ->
        IO.puts("event: #{inspect(event)}")
        await(sock, id, timeout)

      {:ok, other} -> raise "unexpected frame: #{inspect(other)}"
      {:error, reason} -> raise "recv failed: #{inspect(reason)}"
    end
  end

  defp listen_events(sock, deadline) do
    left = deadline - System.monotonic_time(:millisecond)

    if left > 0 do
      case recv(sock, left) do
        {:ok, {:M, event}} -> IO.puts("event: #{inspect(event)}")
        {:ok, other} -> IO.puts("unexpected frame: #{inspect(other)}")
        {:error, :timeout} -> :ok
        {:error, reason} -> raise "recv failed: #{inspect(reason)}"
      end

      listen_events(sock, deadline)
    end
  end

  defp send_term(sock, term), do: :ok = :gen_tcp.send(sock, :erlang.term_to_binary(term))

  defp recv(sock, timeout) do
    with {:ok, bin} <- :gen_tcp.recv(sock, 0, timeout) do
      {:ok, :erlang.binary_to_term(bin, [:safe])}
    end
  end
end

Phase0Ping.main(System.argv())
