defmodule ExPoser.SceneTest do
  use ExUnit.Case, async: false

  import PoserTest.ClientCase

  alias ExPoser.{Actor, Client, Error, Figure, Scene}

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
    assert {:ok, [%Actor{figure: nil, internal: "ball", name: "Ball"}]} =
             Scene.actors(server: c)

    assert [_] = Scene.actors!(server: c)
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
