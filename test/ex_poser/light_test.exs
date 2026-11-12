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
end
