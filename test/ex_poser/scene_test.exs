defmodule ExPoser.SceneTest do
  use ExUnit.Case, async: false

  import PoserTest.ClientCase

  alias ExPoser.{Actor, Camera, Client, Error, Figure, Light, Scene}

  setup do
    server = start_standalone()
    %{c: start_client(server.session)}
  end

  defp assert_no_handles(c), do: assert({:ok, %{"handles" => 0}} = Client.stats(server: c))

  test "figures lists both", %{c: c} do
    assert {:ok, [%Figure{internal: "figure 1"}, %Figure{internal: "figure 2"}]} =
             Scene.figures(server: c)

    assert [_, _] = Scene.figures!(server: c)
    assert_no_handles(c)
  end

  test "figure finds by internal name, and internal wins", %{c: c} do
    assert {:ok, %Figure{internal: "figure 2"}} = Scene.figure("figure 2", server: c)
    assert {:ok, %Figure{internal: "figure 1"}} = Scene.figure("figure 1", server: c)
    assert %Figure{internal: "figure 1"} = Scene.figure!("figure 1", server: c)
    assert_no_handles(c)
  end

  test "figure by shared display name is ambiguous", %{c: c} do
    assert {:error, %Error{kind: :ambiguous, details: %{matches: [a, b]}}} =
             Scene.figure("Figure 1", server: c)

    assert {a.internal, b.internal} == {"figure 1", "figure 2"}
    assert_raise Error, fn -> Scene.figure!("Figure 1", server: c) end
    assert_no_handles(c)
  end

  test "figure not found", %{c: c} do
    assert {:error, %Error{kind: :not_found, details: %{path: [name: "Nope"]}}} =
             Scene.figure("Nope", server: c)

    assert_no_handles(c)
  end

  test "actors returns scene-level actors only", %{c: c} do
    assert {:ok, [%Actor{figure: nil, internal: "ball", name: "Ball"} | lights_and_cameras]} =
             Scene.actors(server: c)

    assert Enum.map(lights_and_cameras, & &1.internal) ==
             ["light 1", "light 2", "light 3", "MAIN_CAMERA", "AUX_CAMERA"]

    assert [_ | _] = Scene.actors!(server: c)
    assert_no_handles(c)
  end

  test "actor finds by internal then display name, never body parts", %{c: c} do
    assert {:ok, %Actor{internal: "ball", figure: nil}} = Scene.actor("ball", server: c)
    assert {:ok, %Actor{internal: "ball"}} = Scene.actor("Ball", server: c)
    assert %Actor{internal: "ball"} = Scene.actor!("ball", server: c)
    assert {:error, %Error{kind: :not_found}} = Scene.actor("hip", server: c)
    assert {:error, %Error{kind: :not_found}} = Scene.actor("nope", server: c)
    assert_no_handles(c)
  end

  test "lights lists the three lights", %{c: c} do
    assert {:ok, [%Light{actor: %Actor{internal: "light 1"}} | _] = lights} =
             Scene.lights(server: c)

    assert length(lights) == 3
    assert [_, _, _] = Scene.lights!(server: c)
    assert_no_handles(c)
  end

  test "light finds by internal then display name", %{c: c} do
    assert {:ok, %Light{actor: %Actor{internal: "light 1", name: "Key"}}} =
             Scene.light("Key", server: c)

    assert {:ok, %Light{actor: %Actor{internal: "light 2"}}} = Scene.light("light 2", server: c)
    assert %Light{} = Scene.light!("light 2", server: c)
    assert_no_handles(c)
  end

  test "light by shared display name is ambiguous", %{c: c} do
    assert {:error, %Error{kind: :ambiguous, details: %{matches: [_, _]}}} =
             Scene.light("Fill", server: c)

    assert_raise Error, fn -> Scene.light!("Fill", server: c) end
    assert_no_handles(c)
  end

  test "light rejects a name that is not a light", %{c: c} do
    assert {:error, %Error{kind: :not_found}} = Scene.light("Ball", server: c)
    assert {:error, %Error{kind: :not_found}} = Scene.light("ball", server: c)
    assert {:error, %Error{kind: :not_found}} = Scene.light("MAIN_CAMERA", server: c)
    assert_no_handles(c)
  end

  test "cameras and camera", %{c: c} do
    assert {:ok, [%Camera{}, %Camera{}] = cameras} = Scene.cameras(server: c)
    assert Enum.map(cameras, & &1.actor.internal) == ["MAIN_CAMERA", "AUX_CAMERA"]
    assert [_, _] = Scene.cameras!(server: c)

    assert {:ok, %Camera{actor: %Actor{internal: "MAIN_CAMERA"}}} =
             Scene.camera("Main Camera", server: c)

    assert %Camera{actor: %Actor{internal: "AUX_CAMERA"}} = Scene.camera!("AUX_CAMERA", server: c)
    assert {:error, %Error{kind: :not_found}} = Scene.camera("light 1", server: c)
    assert_no_handles(c)
  end

  test "current_camera and set_current_camera", %{c: c} do
    assert {:ok, %Camera{actor: %Actor{internal: "MAIN_CAMERA", name: "Main Camera"}}} =
             Scene.current_camera(server: c)

    aux = Scene.camera!("AUX_CAMERA", server: c)
    assert {:ok, :ok} = Scene.set_current_camera(aux, server: c)
    assert %Camera{actor: %Actor{internal: "AUX_CAMERA"}} = Scene.current_camera!(server: c)
    assert :ok = Scene.set_current_camera!(Scene.camera!("MAIN_CAMERA", server: c), server: c)
    assert %Camera{actor: %Actor{internal: "MAIN_CAMERA"}} = Scene.current_camera!(server: c)
    assert_no_handles(c)
  end

  test "frame, set_frame, num_frames and fps", %{c: c} do
    assert {:ok, 0} = Scene.frame(server: c)

    try do
      assert {:ok, _} = Scene.set_frame(4, server: c)
      assert {:ok, 4} = Scene.frame(server: c)
      assert 4 = Scene.frame!(server: c)
    after
      Scene.set_frame!(0, server: c)
    end

    assert {:ok, 0} = Scene.frame(server: c)
    assert {:ok, n} = Scene.num_frames(server: c)
    assert n > 4 and Scene.num_frames!(server: c) == n
    assert {:ok, 30} = Scene.fps(server: c)
    assert 30 = Scene.fps!(server: c)
    assert {:error, %Error{}} = Scene.set_frame(10_000, server: c)
    assert_no_handles(c)
  end

  test "unknown options raise", %{c: c} do
    assert_raise ArgumentError, fn -> Scene.frame(server: c, bogus: 1) end
  end
end
