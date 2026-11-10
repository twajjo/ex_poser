defmodule ExPoser.ClientTest do
  # Not async: events go through one global registry.
  use ExUnit.Case, async: false

  import PoserTest.ClientCase

  alias ExPoser.{Client, Error, Handle}

  @uni "Ünïcode 頭"

  describe "against the standalone server" do
    setup do
      server = start_standalone()
      %{c: start_client(server.session)}
    end

    test "call and invoke round trip", %{c: c} do
      assert {:ok, %Handle{class: "SceneType"} = scene} = Client.call("Scene", [], server: c)
      assert Client.invoke(scene, "Frame", [], server: c) == {:ok, 0}
      assert {:ok, %{mode: :dev, protocol: 1}} = Client.info(server: c)
      assert Client.status(server: c) == :connected
    end

    test "kwargs are passed by name", %{c: c} do
      {:ok, scene} = Client.call("Scene", [], server: c)
      assert {:ok, nil} = Client.invoke(scene, "SetFrame", [], server: c, kw: [n: 3])
      assert Client.invoke(scene, "Frame", [], server: c) == {:ok, 3}
    end

    test "unicode names round trip", %{c: c} do
      {:ok, scene} = Client.call("Scene", [], server: c)
      assert {:ok, %Handle{label: @uni} = a} = Client.invoke(scene, "Actor", [@uni], server: c)
      assert Client.invoke(a, "Name", [], server: c) == {:ok, @uni}
    end

    test "python errors come back as ExPoser.Error", %{c: c} do
      {:ok, scene} = Client.call("Scene", [], server: c)

      assert {:error, %Error{kind: :python, class: "ValueError", message: "frame out of range"}} =
               Client.invoke(scene, "SetFrame", [99], server: c)
    end

    test "get_attr reads attributes", %{c: c} do
      {:ok, scene} = Client.call("Scene", [], server: c)
      {:ok, a} = Client.invoke(scene, "Actor", ["hip"], server: c)
      assert Client.get_attr(a, "visible", server: c) == {:ok, true}
    end

    test "batch with result references", %{c: c} do
      assert {:ok, [%Handle{class: "SceneType"}, 30]} =
               Client.batch([{:call, "Scene", []}, {:invoke, {:result, 0}, "NumFrames", []}],
                 server: c
               )
    end

    test "batch failures report the failing index", %{c: c} do
      assert {:error, %Error{kind: :batch_failed, details: %{index: 1, partial: [%Handle{}]}}} =
               Client.batch([{:call, "Scene", []}, {:invoke, {:result, 0}, "SetFrame", [99]}],
                 server: c
               )
    end

    test "raw calls work in dev mode", %{c: c} do
      assert Client.raw("math", "sqrt", [16], server: c) == {:ok, 4.0}
    end

    test "a blocked main thread times out the caller but ping still answers", %{c: c} do
      slow = Task.async(fn -> Client.call("Sleep", [1.0], server: c, timeout: 200) end)
      assert {:error, %Error{kind: :timeout}} = Task.await(slow)
      assert {:ok, us} = Client.ping(server: c)
      assert us < 200_000
      assert Client.call("AppVersion", [], server: c) == {:ok, "fake-14"}
    end

    test "late reply handles are released", %{c: c} do
      assert {:error, %Error{kind: :timeout}} =
               Client.call("SleepThenScene", [0.5], server: c, timeout: 100)

      eventually(fn -> match?({:ok, %{"handles" => 0}}, Client.stats(server: c)) end)
    end

    test "late batch failure handles are released", %{c: c} do
      ops = [{:call, "SleepThenScene", [0.5]}, {:invoke, {:result, 0}, "SetFrame", [99]}]
      assert {:error, %Error{kind: :timeout}} = Client.batch(ops, server: c, timeout: 100)

      eventually(fn -> match?({:ok, %{"handles" => 0}}, Client.stats(server: c)) end)
    end

    test "invalid arguments return bad_request and the client survives", %{c: c} do
      for {req, opts} <- [
            {fn o -> Client.batch([{:bogus}], o) end, []},
            {fn o -> Client.call("AppVersion", [~D[2020-01-01]], o) end, []},
            {fn o -> Client.call("AppVersion", [self()], o) end, []},
            {fn o -> Client.call("AppVersion", [<<255, 254>>], o) end, []},
            {fn o -> Client.call("AppVersion", [], o) end, [kw: :not_a_keyword]},
            {fn o -> Client.call("AppVersion", [], o) end, [timeout: "soon"]}
          ] do
        assert {:error, %Error{kind: :bad_request}} = req.([server: c] ++ opts)
      end

      assert Client.call("AppVersion", [], server: c) == {:ok, "fake-14"}
    end

    test "release frees handles", %{c: c} do
      {:ok, scene} = Client.call("Scene", [], server: c)
      assert {:ok, %{"handles" => 1}} = Client.stats(server: c)
      assert Client.release(scene, server: c) == {:ok, 1}
      assert {:ok, %{"handles" => 0}} = Client.stats(server: c)
    end
  end

  test "strict mode rejects raw calls" do
    server = start_standalone(mode: :strict)
    c = start_client(server.session)
    assert {:error, %Error{kind: :not_allowed}} = Client.raw("math", "sqrt", [4], server: c)
    assert {:ok, %{mode: :strict, api_hash: "mini"}} = Client.info(server: c)
  end

  @tag :capture_log
  test "undecodable frames are dropped and the client survives" do
    bad_atom = "zz_never_an_atom_#{System.unique_integer([:positive])}"

    scripted =
      PoserTest.ScriptedServer.start!(fn
        {:C, _id, _, _, _} -> {:raw, <<131, 119, byte_size(bad_atom), bad_atom::binary>>}
        {:ping, id} -> {:reply, {:r, id, :pong}}
        _ -> :ignore
      end)

    c = start_client(scripted.session)

    assert {:error, %Error{kind: :timeout}} = Client.call("Scene", [], server: c, timeout: 200)
    assert {:ok, _} = Client.ping(server: c)
    assert Client.status(server: c) == :connected
  end

  describe "await_connected/1" do
    test "returns :ok once a freshly started client has connected" do
      server = start_standalone()
      name = :"poser_client_#{System.unique_integer([:positive])}"
      start_supervised!({Client, name: name, session: server.session})

      assert Client.await_connected(server: name) == :ok
      assert Client.status(server: name) == :connected
    end

    @tag :capture_log
    test "times out while the client can't connect" do
      name = :"poser_client_#{System.unique_integer([:positive])}"
      start_supervised!({Client, name: name, session: "/nonexistent/session.json"})

      t0 = System.monotonic_time(:millisecond)

      assert {:error, %Error{kind: :timeout}} =
               Client.await_connected(server: name, timeout: 200)

      assert (System.monotonic_time(:millisecond) - t0) in 200..1_000
    end

    test "rejects bad options" do
      assert_raise ArgumentError, fn -> Client.await_connected(timeout: :soon) end
      assert_raise ArgumentError, fn -> Client.await_connected(wait: 10) end
    end
  end

  test "requests fail fast while a handshake is stuck" do
    scripted = PoserTest.ScriptedServer.start!(fn _ -> :ignore end, hello: :never)
    name = :"poser_client_#{System.unique_integer([:positive])}"
    start_supervised!({Client, name: name, session: scripted.session, connect_timeout: 5_000})

    t0 = System.monotonic_time(:millisecond)
    assert {:error, %Error{kind: :disconnected}} = Client.ping(server: name)
    assert Client.status(server: name) == :disconnected
    assert System.monotonic_time(:millisecond) - t0 < 100
  end

  @tag :capture_log
  test "the last connect error is reported" do
    name = :"poser_client_#{System.unique_integer([:positive])}"

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        start_supervised!({Client, name: name, session: "/nonexistent/session.json"})

        eventually(fn ->
          match?(
            {:error, %Error{kind: :disconnected, details: %{reason: {:session, :enoent}}}},
            Client.call("Scene", [], server: name)
          )
        end)
      end)

    assert log =~ "ex_poser: cannot connect"
  end

  @tag :capture_log
  test "a protocol mismatch is reported as the connect error" do
    scripted =
      PoserTest.ScriptedServer.start!(fn _ -> :ignore end,
        hello: {:e, 0, {:protocol_mismatch, 2, 1}}
      )

    name = :"poser_client_#{System.unique_integer([:positive])}"
    start_supervised!({Client, name: name, session: scripted.session})

    eventually(fn ->
      match?(
        {:error,
         %Error{kind: :disconnected, details: %{reason: %Error{kind: :protocol_mismatch}}}},
        Client.ping(server: name)
      )
    end)
  end

  @tag :capture_log
  test "requests while disconnected fail fast" do
    name = :"poser_client_#{System.unique_integer([:positive])}"
    start_supervised!({Client, name: name, session: "/nonexistent/session.json"})
    t0 = System.monotonic_time(:millisecond)
    assert {:error, %Error{kind: :disconnected}} = Client.call("Scene", [], server: name)
    assert System.monotonic_time(:millisecond) - t0 < 50
    assert Client.status(server: name) == :disconnected

    # let the first connect attempt finish inside the log capture
    eventually(fn ->
      match?({:error, %Error{details: %{reason: {:session, _}}}}, Client.ping(server: name))
    end)
  end
end
