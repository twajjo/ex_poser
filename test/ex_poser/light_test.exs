defmodule ExPoser.LightTest do
  use ExUnit.Case, async: false

  import PoserTest.ClientCase

  alias ExPoser.{Actor, Camera, Client, Light, Ref, Scene}

  doctest ExPoser.Light

  test "Ref.path/1 and ref?/1 treat a light as its actor" do
    light = %Light{actor: %Actor{figure: nil, internal: "light 1", name: "Key"}}
    assert Ref.path(light) == [actor: "light 1"]
    assert Ref.ref?(light)
  end

  setup do
    server = start_standalone()
    c = start_client(server.session)
    %{c: c, key: Scene.light!("Key", server: c), fill2: Scene.light!("light 2", server: c)}
  end

  defp assert_no_handles(c), do: assert({:ok, %{"handles" => 0}} = Client.stats(server: c))

  test "props table names exist in priv/poser_api.json" do
    methods =
      "priv/poser_api.json"
      |> File.read!()
      |> JSON.decode!()
      |> get_in(["classes", "ActorType", "methods"])
      |> Enum.map(& &1["name"])

    props = Light.props()
    assert map_size(props) == 16

    for {_atom, {getter, setter}} <- props do
      assert getter in methods
      assert setter in methods
    end
  end

  test "get reads the type as an atom", %{c: c, key: key, fill2: fill2} do
    assert {:ok, :spot} = Light.get(key, :type, server: c)
    assert Light.get!(fill2, :type, server: c) == :infinite
    assert_no_handles(c)
  end

  test "set then get round trips dials, enums and integers", %{c: c, key: key} do
    attrs = %{:type => :area, :shadow_samples => 8, "xtran" => 0.5}
    assert {:ok, :ok} = Light.set(key, attrs, server: c)

    assert {:ok, ^attrs} = Light.get(key, [:type, :shadow_samples, "xtran"], server: c)
    assert {:ok, :ok} = Light.set(key, :attenuation, :inverse_square, server: c)
    assert Light.get!(key, :attenuation, server: c) == :inverse_square
    assert :ok = Light.set!(key, :type, 7, server: c)
    assert Light.get!(key, :type, server: c) == 7
    assert_no_handles(c)
  end

  test "set then get round trips :color", %{c: c, key: key} do
    assert {:ok, :ok} = Light.set(key, :color, {1.0, 0.5, 0.25}, server: c)
    assert {:ok, {1.0, 0.5, 0.25}} = Light.get(key, :color, server: c)

    assert %{color: {1.0, 0.5, 0.25}, on: 1} = Light.get!(key, [:color, :on], server: c)
    assert_no_handles(c)
  end

  test "unknown property or enum atoms raise ArgumentError", %{c: c, key: key} do
    assert_raise ArgumentError, fn -> Light.set(key, %{shaddow: true}, server: c) end
    assert_raise ArgumentError, fn -> Light.set(key, :type, :laser, server: c) end
    assert_raise ArgumentError, fn -> Light.get(key, :shaddow, server: c) end
    assert_raise ArgumentError, fn -> Light.get(key, [:type, :shaddow], server: c) end
    assert_no_handles(c)
  end

  test "a map with one bad entry changes nothing", %{c: c, key: key} do
    before = Light.get!(key, [:on, :color, :type], server: c)

    assert_raise ArgumentError, fn -> Light.set(key, %{on: 0, shaddow: true}, server: c) end

    assert_raise ArgumentError, fn ->
      Light.set(key, %{color: {0.1, 0.2, 0.3}, type: :laser}, server: c)
    end

    assert Light.get!(key, [:on, :color, :type], server: c) == before
    assert_no_handles(c)
  end

  test "set/2 and set/3 take a map or a key and value, nothing else", %{c: c, key: key} do
    # apply/3 keeps the compiler's type checker from rejecting the bad calls
    assert_raise FunctionClauseError, fn -> apply(Light, :set, [key, :on]) end
    assert_raise FunctionClauseError, fn -> apply(Light, :set, [key, :on, [frame: 1]]) end
    assert_raise FunctionClauseError, fn -> apply(Light, :set!, [key, :on]) end
    assert {:ok, :ok} = Light.set(key, :on, 0, server: c)
  end

  test "an unknown attenuation code stays an integer", %{c: c, key: key} do
    assert :ok = Light.set!(key, :attenuation, 9, server: c)
    assert Light.get!(key, :attenuation, server: c) == 9
  end

  test "set applies :type before the other keys", %{c: c, key: key} do
    assert {:ok, :ok} = Light.set(key, %{shadow_samples: 4, type: :point, on: 0}, server: c)

    assert %{type: :point, shadow_samples: 4, on: 0} =
             Light.get!(key, [:type, :shadow_samples, :on], server: c)
  end

  test "the wrong struct raises FunctionClauseError", %{c: c} do
    camera = Scene.current_camera!(server: c)
    assert %Camera{} = camera
    assert_raise FunctionClauseError, fn -> Light.set(camera, :on, 1, server: c) end
    assert_raise FunctionClauseError, fn -> Light.get(camera, :on, server: c) end
    assert_no_handles(c)
  end

  test "frame: sets a dial at that frame and leaves the scene frame", %{c: c, key: key} do
    assert {:ok, :ok} = Light.set(key, "xtran", 2.5, frame: 3, server: c)
    assert Light.get!(key, "xtran", frame: 3, server: c) == 2.5
    assert Light.get!(key, "xtran", frame: 0, server: c) == 0.0
    assert Scene.frame!(server: c) == 0

    assert {:ok, :ok} = Light.set(key, :color, {0.1, 0.2, 0.3}, frame: 3, server: c)
    assert Light.get!(key, :color, frame: 3, server: c) == {0.1, 0.2, 0.3}
    assert Light.get!(key, :color, frame: 0, server: c) == {1.0, 1.0, 1.0}
    assert_no_handles(c)
  end

  test "create makes a spot light", %{c: c} do
    assert {:ok, %Light{} = light} = Light.create(server: c)
    assert Light.get!(light, :type, server: c) == :spot
    assert length(Scene.lights!(server: c)) == 4
    assert_no_handles(c)
  end

  test "create with attrs, then find it by name", %{c: c} do
    attrs = %{name: "Rim", type: :point, color: {0.2, 0.4, 1.0}}
    assert {:ok, %Light{}} = Light.create(attrs, server: c)

    rim = Scene.light!("Rim", server: c)
    assert %{type: :point, color: {0.2, 0.4, 1.0}} = Light.get!(rim, [:type, :color], server: c)
    assert %Light{} = Light.create!(%{name: "Back"}, server: c)
    assert_no_handles(c)
  end

  test "create with a bad attr raises and creates nothing", %{c: c} do
    assert_raise ArgumentError, fn -> Light.create(%{type: :laser}, server: c) end
    assert_raise ArgumentError, fn -> Light.create(%{shaddow: true}, server: c) end
    assert length(Scene.lights!(server: c)) == 3
    assert_no_handles(c)
  end

  test "create whose set step fails still releases its handles", %{c: c} do
    assert {:error, %ExPoser.Error{kind: :not_found}} = Light.create(%{"nope" => 1.0}, server: c)
    assert length(Scene.lights!(server: c)) == 4
    assert_no_handles(c)
  end

  test "delete removes the light", %{c: c} do
    {:ok, rim} = Light.create(%{name: "Rim"}, server: c)
    assert {:ok, :ok} = Light.delete(rim, server: c)
    assert {:error, %ExPoser.Error{kind: :not_found}} = Scene.light("Rim", server: c)
    assert length(Scene.lights!(server: c)) == 3

    other = Light.create!(%{name: "Gone"}, server: c)
    assert :ok = Light.delete!(other, server: c)
    assert_no_handles(c)
  end

  test "create with a non-string name raises and creates nothing", %{c: c} do
    assert_raise ArgumentError, fn -> Light.create(%{name: 42}, server: c) end
    assert length(Scene.lights!(server: c)) == 3
    assert_no_handles(c)
  end

  test "create with keyword attributes raises, since a list is options", %{c: c} do
    assert_raise ArgumentError, fn -> Light.create(name: "Rim", server: c) end
    assert length(Scene.lights!(server: c)) == 3
    assert_no_handles(c)
  end

  test "create with a malformed colour raises and creates nothing", %{c: c} do
    assert_raise ArgumentError, fn -> Light.create(%{color: {1.0, 0.5}}, server: c) end
    assert length(Scene.lights!(server: c)) == 3
    assert_no_handles(c)
  end

  test "an unknown option raises ArgumentError on create and delete", %{c: c, key: key} do
    assert_raise ArgumentError, fn -> Light.create(%{}, server: c, frame: 1) end
    assert_raise ArgumentError, fn -> Light.delete(key, server: c, frame: 1) end
    assert length(Scene.lights!(server: c)) == 3
    assert_no_handles(c)
  end

  test "delete given a camera raises FunctionClauseError", %{c: c} do
    camera = Scene.current_camera!(server: c)
    assert_raise FunctionClauseError, fn -> apply(Light, :delete, [camera, [server: c]]) end
    assert_no_handles(c)
  end

  test "create! raises when the set step fails", %{c: c} do
    assert_raise ExPoser.Error, fn -> Light.create!(%{"nope" => 1.0}, server: c) end
    assert_no_handles(c)
  end

  describe "snapshots" do
    test "snapshot reads name, type, dials and props", %{c: c, key: key} do
      assert {:ok, %Light.Snapshot{name: "Key", type: :spot} = snap} =
               Light.snapshot(key, server: c)

      assert snap.dials |> Map.keys() |> Enum.sort() ==
               ["kdblue", "kdgreen", "kdintensity", "kdred", "xtran"]

      assert snap.props |> Map.keys() |> Enum.sort() ==
               Light.props() |> Map.keys() |> List.delete(:type) |> Enum.sort()

      assert map_size(snap.props) == 15
      assert snap.props.on == 1
      assert snap.props.attenuation == :poser
      assert_no_handles(c)
    end

    test "snapshot_all returns every light in Scene.lights order", %{c: c} do
      names = c |> then(&Scene.lights!(server: &1)) |> Enum.map(& &1.actor.name)
      assert {:ok, snaps} = Light.snapshot_all(server: c)
      assert length(snaps) == 3
      assert Enum.map(snaps, & &1.name) == names
      assert_no_handles(c)
    end

    test "frame: reads dials at that frame and leaves the scene frame", %{c: c, key: key} do
      frame = Scene.frame!(server: c)
      :ok = Light.set!(key, "xtran", 0.75, frame: 2, server: c)

      assert Light.snapshot!(key, frame: 2, server: c).dials["xtran"] == 0.75
      assert Light.snapshot!(key, frame: 0, server: c).dials["xtran"] == 0.0
      assert Scene.frame!(server: c) == frame
      assert_no_handles(c)
    end

    test "snapshot_all takes the same number of requests for 3 lights as for 4", %{c: c} do
      pid = Process.whereis(c)

      count = fn ->
        :erlang.trace(pid, true, [:receive])

        try do
          Light.snapshot_all!(server: c)
        after
          :erlang.trace(pid, false, [:receive])
        end

        drain_requests(0)
      end

      three = count.()
      Light.create!(%{name: "Rim"}, server: c)
      four = count.()

      # 5 batches: lights list (2), dial names via children_many (2), the
      # read (1); each is followed by a :release request, 5 more.
      assert three == 10
      assert three == four
      assert_no_handles(c)
    end

    test "a deleted light gives an error and leaves no handles", %{c: c} do
      rim = Light.create!(%{name: "Rim"}, server: c)
      :ok = Light.delete!(rim, server: c)

      assert {:error, %ExPoser.Error{kind: kind}} = Light.snapshot(rim, server: c)
      assert kind == :not_found
      assert_raise ExPoser.Error, fn -> Light.snapshot!(rim, server: c) end
      assert_no_handles(c)
    end

    test "an unknown type code stays an integer", %{c: c, key: key} do
      :ok = Light.set!(key, :type, 7, server: c)

      assert %Light.Snapshot{type: 7} = Light.snapshot!(key, server: c)
      assert [%Light.Snapshot{type: 7} | _] = Light.snapshot_all!(server: c)
      assert_no_handles(c)
    end

    test "an unknown option raises ArgumentError", %{c: c, key: key} do
      assert_raise ArgumentError, fn -> Light.snapshot(key, frame: 1, bad: 1, server: c) end
      assert_raise ArgumentError, fn -> Light.snapshot_all(bad: 1, server: c) end
      assert_no_handles(c)
    end

    test "the bang variants return the bare value", %{c: c, key: key} do
      assert %Light.Snapshot{name: "Key"} = Light.snapshot!(key, server: c)

      assert [%Light.Snapshot{}, %Light.Snapshot{}, %Light.Snapshot{}] =
               Light.snapshot_all!(server: c)

      assert_no_handles(c)
    end
  end

  defp drain_requests(n) do
    receive do
      {:trace, _pid, :receive, {:"$gen_call", _from, {:request, _req, _timeout}}} ->
        drain_requests(n + 1)

      {:trace, _pid, :receive, _other} ->
        drain_requests(n)
    after
      0 -> n
    end
  end
end
