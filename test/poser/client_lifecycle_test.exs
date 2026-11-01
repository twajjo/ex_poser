defmodule Poser.ClientLifecycleTest do
  use ExUnit.Case, async: false

  import PoserTest.ClientCase

  alias Poser.{Client, Error, Handle}

  describe "handle ownership" do
    setup do
      server = start_standalone()
      %{c: start_client(server.session)}
    end

    test "handles are released when their owner exits", %{c: c} do
      task = Task.async(fn -> Client.call("Scene", [], server: c) end)
      assert {:ok, %Handle{}} = Task.await(task)
      eventually(fn -> match?({:ok, %{"handles" => 0}}, Client.stats(server: c)) end)
    end

    test "handles stay while their owner lives", %{c: c} do
      {:ok, _scene} = Client.call("Scene", [], server: c)
      assert {:ok, %{"handles" => 1}} = Client.stats(server: c)
    end

    test "explicit release makes the handle stale", %{c: c} do
      {:ok, h} = Client.call("Scene", [], server: c)
      assert Client.release(h, server: c) == {:ok, 1}
      assert {:error, %Error{kind: :stale_handle}} = Client.invoke(h, "Frame", [], server: c)
    end

    test "generation change stales handles and is broadcast", %{c: c} do
      :ok = Poser.Events.subscribe(:generation_changed)
      {:ok, old} = Client.call("Scene", [], server: c)
      assert {:ok, nil} = Client.raw("fake_poser", "NewScene", [], server: c)
      assert_receive {:poser_event, :generation_changed, 1}, 2_000
      assert {:error, %Error{kind: :stale_handle}} = Client.invoke(old, "Frame", [], server: c)
    end
  end

  test "reconnects after the server restarts, and old handles are stale" do
    server = PoserTest.Standalone.start!()
    c = start_client(server.session, backoff_initial: 50, backoff_max: 200)
    :ok = Poser.Events.subscribe(:disconnected)
    {:ok, h} = Client.call("Scene", [], server: c)

    pending = Task.async(fn -> Client.call("Sleep", [5.0], server: c) end)
    # make sure the Sleep request is in flight before the server goes away
    assert {:ok, _} = Client.ping(server: c)
    PoserTest.Standalone.stop!(server)

    assert_receive {:poser_event, :disconnected, %{server: ^c}}, 5_000
    assert {:error, %Error{kind: :disconnected}} = Task.await(pending)
    assert {:error, %Error{kind: :disconnected}} = Client.call("Scene", [], server: c)

    again = PoserTest.Standalone.start!(session: server.session)
    on_exit(fn -> PoserTest.Standalone.stop!(again) end)
    assert_receive {:poser_event, :connected, %{server: ^c}}, 5_000

    assert {:error, %Error{kind: :stale_handle}} = Client.invoke(h, "Frame", [], server: c)
    assert {:ok, %Handle{}} = Client.call("Scene", [], server: c)
  end

  test "a handle from another client is stale, never another object" do
    server = start_standalone()
    c1 = start_client(server.session)
    c2 = start_client(server.session)
    {:ok, scene1} = Client.call("Scene", [], server: c1)
    {:ok, hip} = Client.invoke(scene1, "Actor", ["hip"], server: c1)
    {:ok, scene2} = Client.call("Scene", [], server: c2)
    {:ok, chest} = Client.invoke(scene2, "Actor", ["chest"], server: c2)

    assert hip.epoch != chest.epoch
    assert {:error, %Error{kind: :stale_handle}} = Client.invoke(hip, "Name", [], server: c2)
  end

  @tag :capture_log
  test "heartbeat timeout drops a silent connection" do
    scripted = PoserTest.ScriptedServer.start!(fn _ -> :ignore end)
    :ok = Poser.Events.subscribe(:disconnected)

    c =
      start_client(scripted.session,
        heartbeat_interval: 50,
        heartbeat_timeout: 200,
        backoff_initial: 5_000
      )

    assert_receive {:poser_event, :disconnected, %{server: ^c, reason: :heartbeat_timeout}}, 1_000
    assert Client.status(server: c) == :disconnected
  end

  test "heartbeats keep a quiet but healthy connection up" do
    server = start_standalone()
    :ok = Poser.Events.subscribe(:disconnected)
    c = start_client(server.session, heartbeat_interval: 50, heartbeat_timeout: 200)
    refute_receive {:poser_event, :disconnected, %{server: ^c}}, 600
    assert Client.status(server: c) == :connected
  end

  test "frame events reach subscribers" do
    server = start_standalone(events: 0.1)
    :ok = Poser.Events.subscribe(:frame_changed)
    _c = start_client(server.session)
    assert_receive {:poser_event, :frame_changed, n}, 2_000
    assert is_integer(n)
  end
end
