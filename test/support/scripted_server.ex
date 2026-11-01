defmodule PoserTest.ScriptedServer do
  @moduledoc """
  A fake bridge on 127.0.0.1 that answers hello, then hands every request
  term to `fun`, which returns `{:reply, term} | {:raw, binary} | :ignore`.
  """

  def start!(fun, opts \\ []) do
    {:ok, listen} =
      :gen_tcp.listen(0, [:binary, packet: 4, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

    {:ok, port} = :inet.port(listen)
    dir = Path.join(System.tmp_dir!(), "poserx-scripted-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    session = Path.join(dir, "session.json")

    File.write!(
      session,
      JSON.encode!(%{port: port, token: "t", protocol: 1, hosts: ["127.0.0.1"]})
    )

    hello =
      opts[:hello] ||
        {:r, 0,
         %{protocol: 1, mode: :dev, poser_version: "scripted", python_version: "-", api_hash: nil}}

    pid = spawn_link(fn -> accept(listen, fun, hello) end)
    :ok = :gen_tcp.controlling_process(listen, pid)
    %{pid: pid, session: session, port: port}
  end

  defp accept(listen, fun, hello) do
    case :gen_tcp.accept(listen) do
      {:ok, sock} ->
        {:ok, _hello} = :gen_tcp.recv(sock, 0)
        # hello: :never leaves the client waiting for the handshake reply
        if hello != :never, do: :ok = :gen_tcp.send(sock, :erlang.term_to_binary(hello))
        serve(sock, fun)
        accept(listen, fun, hello)

      {:error, _} ->
        :ok
    end
  end

  defp serve(sock, fun) do
    case :gen_tcp.recv(sock, 0) do
      {:ok, bin} ->
        case fun.(:erlang.binary_to_term(bin)) do
          {:reply, term} -> :gen_tcp.send(sock, :erlang.term_to_binary(term))
          {:raw, raw} -> :gen_tcp.send(sock, raw)
          :ignore -> :ok
        end

        serve(sock, fun)

      {:error, _} ->
        :ok
    end
  end
end
