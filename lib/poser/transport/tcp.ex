defmodule Poser.Transport.TCP do
  @moduledoc "Plain TCP transport (`packet: 4`), for loopback and the WSL adapter."

  @behaviour Poser.Transport

  @max_frame 64 * 1024 * 1024

  @impl true
  def connect(host, port, timeout) do
    opts = [:binary, packet: 4, packet_size: @max_frame, active: false, nodelay: true]
    :gen_tcp.connect(String.to_charlist(host), port, opts, timeout)
  end

  @impl true
  def send_frame(sock, data), do: :gen_tcp.send(sock, data)

  @impl true
  def recv_frame(sock, timeout), do: :gen_tcp.recv(sock, 0, timeout)

  @impl true
  def activate(sock), do: :inet.setopts(sock, active: :once)

  @impl true
  def handle_message(sock, {:tcp, sock, data}) do
    _ = :inet.setopts(sock, active: :once)
    {:frame, data}
  end

  def handle_message(sock, {:tcp_closed, sock}), do: {:closed, :closed}
  def handle_message(sock, {:tcp_error, sock, reason}), do: {:closed, reason}
  def handle_message(_sock, _msg), do: :ignore

  @impl true
  def close(sock), do: :gen_tcp.close(sock)
end
