defmodule Poser.Transport.TCPTest do
  use ExUnit.Case, async: true

  alias Poser.{Codec, Session}
  alias Poser.Transport.TCP

  setup do
    server = PoserTest.Standalone.start!()
    on_exit(fn -> PoserTest.Standalone.stop!(server) end)
    {:ok, session} = Session.read(server.session)
    {:ok, conn} = TCP.connect("127.0.0.1", session.port, 5_000)

    :ok =
      TCP.send_frame(
        conn,
        Codec.encode({:hello, %{token: session.token, protocol: 1, client: "test"}})
      )

    %{conn: conn}
  end

  test "completes the hello handshake with the standalone server", %{conn: conn} do
    assert {:ok, bin} = TCP.recv_frame(conn, 5_000)
    assert {:ok, {:r, 0, %{mode: :dev, protocol: 1}}} = Codec.decode(bin)
  end

  test "delivers frames as messages once activated", %{conn: conn} do
    {:ok, _hello} = TCP.recv_frame(conn, 5_000)
    :ok = TCP.activate(conn)
    :ok = TCP.send_frame(conn, Codec.encode({:ping, 7}))
    assert_receive msg, 2_000
    assert {:frame, bin} = TCP.handle_message(conn, msg)
    assert Codec.decode(bin) == {:ok, {:r, 7, :pong}}

    :ok = TCP.send_frame(conn, Codec.encode({:ping, 8}))
    assert_receive msg2, 2_000
    assert {:frame, _} = TCP.handle_message(conn, msg2)
  end

  test "reports a closed connection", %{conn: conn} do
    {:ok, _hello} = TCP.recv_frame(conn, 5_000)
    :ok = TCP.activate(conn)
    :ok = TCP.send_frame(conn, Codec.encode({:bogus}))
    assert_receive msg, 2_000
    assert {:closed, _} = TCP.handle_message(conn, msg)
  end

  test "ignores unrelated messages", %{conn: conn} do
    assert TCP.handle_message(conn, :something_else) == :ignore
  end

  test "connect fails cleanly when nothing listens" do
    assert {:error, _} = TCP.connect("127.0.0.1", 1, 1_000)
  end
end
