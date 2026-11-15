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
      count = fn fun ->
        before = Client.request_count(server: c)
        fun.()
        Client.request_count(server: c) - before
      end

      three = count.(fn -> Light.snapshot_all!(server: c) end)
      Light.create!(%{name: "Rim"}, server: c)
      four = count.(fn -> Light.snapshot_all!(server: c) end)

      # 5 batches: lights list (2), dial names via children_many (2), the
      # read (1); each is followed by a :release request, 5 more.
      assert three == 10
      assert three == four

      assert_no_handles(c)
    end

    test "snapshot of one light takes 6 requests", %{c: c, key: key} do
      before = Client.request_count(server: c)
      Light.snapshot!(key, server: c)

      # 3 batches, each followed by a :release request.
      assert Client.request_count(server: c) - before == 6

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

  describe "apply (merge onto existing lights)" do
    alias ExPoser.{Batch, Error}

    # The seed scene has two lights named Fill, so snapshot_all holds a
    # duplicate name. Rename `light 3` so every light can be applied.
    defp rename_third(c) do
      third = Scene.light!("light 3", server: c)
      {:ok, _} = Batch.new() |> Batch.call(third, "SetName", ["Back"]) |> Batch.run(server: c)
      third
    end

    defp requests(c, fun) do
      before = Client.request_count(server: c)
      result = fun.()
      {result, Client.request_count(server: c) - before}
    end

    test "is idempotent", %{c: c} do
      rename_third(c)
      s = Light.snapshot_all!(server: c)

      assert {:ok, %{skipped: []}} = Light.apply(s, server: c)
      assert {:ok, %{skipped: []}} = Light.apply(s, server: c)
      assert Light.snapshot_all!(server: c) == s
      assert length(s) == 3
      assert_no_handles(c)
    end

    test "updates a light by name", %{c: c, key: key} do
      snap = Light.snapshot!(key, server: c)
      snap = %{snap | props: %{snap.props | shadow_samples: 8}}

      assert {:ok, %{skipped: []}} = Light.apply(snap, server: c)
      assert Light.get!(key, :shadow_samples, server: c) == 8
      assert_no_handles(c)
    end

    test "an ambiguous name returns :ambiguous and changes nothing", %{c: c} do
      before = Light.snapshot_all!(server: c)
      snap = %Light.Snapshot{name: "Fill", type: :point, dials: %{}, props: %{on: 0}}

      assert {:error, %Error{kind: :ambiguous, details: %{matches: [%Light{}, %Light{}]}}} =
               Light.apply([snap], server: c)

      assert Light.snapshot_all!(server: c) == before
      assert_no_handles(c)
    end

    test "a missing name returns :not_found and changes nothing", %{c: c, key: key} do
      before = Light.snapshot_all!(server: c)
      key_snap = Light.snapshot!(key, server: c)
      rim = %Light.Snapshot{name: "Rim", type: :point, dials: %{}, props: %{}}
      changed = %{key_snap | props: %{key_snap.props | shadow_samples: 8}}

      assert {:error, %Error{kind: :not_found, details: %{path: [name: "Rim"]}}} =
               Light.apply([changed, rim], server: c)

      assert {:error, %Error{details: %{path: path}}} = Scene.light("Rim", server: c)
      assert path == [name: "Rim"]
      assert Light.snapshot_all!(server: c) == before
      assert_no_handles(c)
    end

    test "a dial the light lacks is skipped and the rest applied", %{c: c, key: key} do
      snap = Light.snapshot!(key, server: c)
      snap = %{snap | dials: snap.dials |> Map.put("nope", 1.0) |> Map.put("xtran", 0.5)}

      assert {:ok, %{skipped: [{"Key", "nope"}]}} = Light.apply(snap, server: c)
      assert Light.get!(key, "xtran", server: c) == 0.5
      assert_no_handles(c)
    end

    test "the first error in snapshot order is returned", %{c: c} do
      rim = %Light.Snapshot{name: "Rim", type: :point, dials: %{}, props: %{}}
      fill = %Light.Snapshot{name: "Fill", type: :point, dials: %{}, props: %{}}

      assert {:error, %Error{kind: :not_found}} = Light.apply([rim, fill], server: c)
      assert {:error, %Error{kind: :ambiguous}} = Light.apply([fill, rim], server: c)
      assert_no_handles(c)
    end

    test "props: %{} writes no props", %{c: c, key: key} do
      :ok = Light.set!(key, :shadow_samples, 5, server: c)
      snap = %Light.Snapshot{name: "Key", type: :spot, dials: %{}, props: %{}}

      assert {:ok, %{skipped: []}} = Light.apply(snap, server: c)
      assert Light.get!(key, :shadow_samples, server: c) == 5
      assert_no_handles(c)
    end

    test "a type change reads back", %{c: c, key: key} do
      snap = %{Light.snapshot!(key, server: c) | type: :point}

      assert {:ok, _} = Light.apply(snap, server: c)
      assert Light.get!(key, :type, server: c) == :point
      assert_no_handles(c)
    end

    test "skipped follows snapshot order, then dial order", %{c: c, key: key} do
      rename_third(c)
      key_snap = Light.snapshot!(key, server: c)
      back_snap = Light.snapshot!(Scene.light!("Back", server: c), server: c)
      key_snap = %{key_snap | dials: Map.put(key_snap.dials, "nope", 1.0)}

      back_snap = %{
        back_snap
        | dials: back_snap.dials |> Map.put("zzz", 1.0) |> Map.put("abc", 1.0)
      }

      assert {:ok, %{skipped: [{"Key", "nope"}, {"Back", "abc"}, {"Back", "zzz"}]}} =
               Light.apply([key_snap, back_snap], server: c)

      assert_no_handles(c)
    end

    test "a name that isn't a string raises before any request", %{c: c} do
      snap = %Light.Snapshot{name: :key, type: :spot, dials: %{}, props: %{}}
      before = Client.request_count(server: c)

      assert_raise ArgumentError, ~r/name must be a string/, fn ->
        Light.apply(snap, server: c)
      end

      assert Client.request_count(server: c) == before
      assert_no_handles(c)
    end

    test "duplicate snapshot names raise before any request", %{c: c, key: key} do
      snap = Light.snapshot!(key, server: c)
      before = Client.request_count(server: c)

      assert_raise ArgumentError, fn -> Light.apply([snap, snap], server: c) end
      assert Client.request_count(server: c) == before
      assert_no_handles(c)
    end

    test "an empty list sends no request", %{c: c} do
      before = Client.request_count(server: c)

      assert {:ok, %{skipped: []}} = Light.apply([], server: c)
      assert Client.request_count(server: c) == before
      assert_no_handles(c)
    end

    test "frame: applies dials at that frame and leaves the scene frame", %{c: c, key: key} do
      snap = Light.snapshot!(key, frame: 0, server: c)
      :ok = Light.set!(key, "xtran", 9.0, frame: 4, server: c)

      assert {:ok, _} = Light.apply(snap, frame: 4, server: c)
      assert Light.get!(key, "xtran", frame: 4, server: c) == snap.dials["xtran"]
      assert Scene.frame!(server: c) == 0
      assert_no_handles(c)
    end

    test "an integer type passes through", %{c: c, key: key} do
      snap = %{Light.snapshot!(key, server: c) | type: 7}

      assert {:ok, _} = Light.apply(snap, server: c)
      assert Light.snapshot!(key, server: c).type == 7
      assert_no_handles(c)
    end

    test "takes the same number of requests for 1 and 2 snapshots", %{c: c, key: key} do
      rename_third(c)
      one = [Light.snapshot!(key, server: c)]
      two = Enum.take(Light.snapshot_all!(server: c), 2)

      {_, n1} = requests(c, fn -> Light.apply!(one, server: c) end)
      {_, n2} = requests(c, fn -> Light.apply!(two, server: c) end)

      # 5 batches, each followed by a :release request: the lights list (2),
      # the dial names via children_many (2), and the one mutate batch (1).
      assert n1 == 10
      assert n2 == n1
      assert_no_handles(c)
    end

    test "a bad option and an unknown prop raise ArgumentError", %{c: c, key: key} do
      snap = Light.snapshot!(key, server: c)
      bad = %{snap | props: Map.put(snap.props, :shaddow, true)}

      assert_raise ArgumentError, fn -> Light.apply(snap, bad: 1, server: c) end
      assert_raise ArgumentError, fn -> Light.apply(snap, mode: :replace, server: c) end
      assert_raise ArgumentError, fn -> Light.apply(bad, server: c) end
      assert_raise ArgumentError, fn -> Light.apply(%{snap | type: :laser}, server: c) end
      assert_no_handles(c)
    end

    test ":color in props raises before any request", %{c: c, key: key} do
      snap = Light.snapshot!(key, server: c)
      bad = %{snap | props: Map.put(snap.props, :color, {1.0, 0.0, 0.0})}
      before = Client.request_count(server: c)

      assert_raise ArgumentError, ~r/can't hold :color/, fn -> Light.apply(bad, server: c) end
      assert Client.request_count(server: c) == before
      assert_no_handles(c)
    end

    test "a bad dial key or value raises before any request", %{c: c, key: key} do
      snap = Light.snapshot!(key, server: c)
      atom_key = %{snap | dials: Map.put(snap.dials, :xtran, 1.0)}
      bad_value = %{snap | dials: Map.put(snap.dials, "xtran", "high")}
      before = Client.request_count(server: c)

      assert_raise ArgumentError, ~r/snapshot dials/, fn -> Light.apply(atom_key, server: c) end
      assert_raise ArgumentError, ~r/snapshot dials/, fn -> Light.apply(bad_value, server: c) end
      assert Client.request_count(server: c) == before
      assert_no_handles(c)
    end

    test ":type in props raises before any request", %{c: c, key: key} do
      snap = Light.snapshot!(key, server: c)
      bad = %{snap | props: Map.put(snap.props, :type, :point)}
      before = Client.request_count(server: c)

      assert_raise ArgumentError, ~r/can't hold :type/, fn -> Light.apply(bad, server: c) end
      assert Client.request_count(server: c) == before
      assert_no_handles(c)
    end

    test "a bad frame raises before any request, even with no dials", %{c: c, key: key} do
      snap = Light.snapshot!(key, server: c)
      no_dials = %{snap | dials: %{}}
      before = Client.request_count(server: c)

      assert_raise ArgumentError, fn -> Light.apply(snap, frame: -1, server: c) end
      assert_raise ArgumentError, fn -> Light.apply(no_dials, frame: -1, server: c) end
      assert_raise ArgumentError, fn -> Light.apply(no_dials, frame: 1.5, server: c) end
      assert Client.request_count(server: c) == before
      assert_no_handles(c)
    end

    test "apply! returns the bare map and raises on error", %{c: c, key: key} do
      snap = Light.snapshot!(key, server: c)
      assert %{skipped: []} = Light.apply!(snap, server: c)

      assert_raise Error, fn -> Light.apply!(%{snap | name: "Rim"}, server: c) end
      assert_no_handles(c)
    end
  end
end
