defmodule ExPoser.ShaderTreeSnapshotTest do
  use ExUnit.Case, async: false

  import PoserTest.ClientCase

  alias ExPoser.{Actor, Client, Error, Figure, Material, ShaderTree}
  alias ExPoser.ShaderTree.Snapshot

  setup do
    server = start_standalone()
    c = start_client(server.session)
    fig = %Figure{internal: "figure 1", name: "Figure 1"}
    hip = %Actor{figure: fig, internal: "hip", name: "hip"}
    %{c: c, skin: %Material{owner: hip, name: "Skin"}}
  end

  test "snapshot reads Skin's nodes", %{c: c, skin: skin} do
    tree = Material.tree(skin)
    assert {:ok, %Snapshot{tree: ^tree, nodes: nodes}} = ShaderTree.snapshot(tree, server: c)

    assert [
             %{internal: "PoserSurface", name: "PoserSurface", type: "PoserSurface"},
             %{internal: "Image_Map", name: "Image_Map", type: "image_map"}
           ] = nodes

    for node <- nodes do
      assert node.inputs == []
      assert node.outputs == []
    end

    assert_no_handles(c)
  end

  test "snapshot reads each node's location and root flag", %{c: c, skin: skin} do
    assert {:ok, %Snapshot{nodes: [surface, image]}} =
             skin |> Material.tree() |> ShaderTree.snapshot(server: c)

    assert surface.location == image.location
    assert surface.root == 1
    assert image.root == 0
    assert_no_handles(c)
  end

  test "snapshot names the root per renderer", %{c: c, skin: skin} do
    assert {:ok, %Snapshot{roots: roots}} =
             skin |> Material.tree() |> ShaderTree.snapshot(server: c)

    assert roots == %{
             preview: nil,
             firefly: "PoserSurface",
             poser4: nil,
             sketch: nil,
             superfly: nil
           }

    assert_no_handles(c)
  end

  test "snapshot names each renderer's own root", %{c: c, skin: skin} do
    tree = Material.tree(skin)
    img = ShaderTree.node!(tree, "Image_Map", server: c)
    ShaderTree.set_root!(img, :preview, server: c)
    ShaderTree.set_root!(img, :superfly, server: c)

    assert {:ok, %Snapshot{roots: roots}} = ShaderTree.snapshot(tree, server: c)

    assert roots == %{
             preview: "Image_Map",
             firefly: "PoserSurface",
             poser4: nil,
             sketch: nil,
             superfly: "Image_Map"
           }

    assert_no_handles(c)
  end

  test "snapshot takes the atmosphere tree", %{c: c} do
    tree = %ShaderTree{owner: :atmosphere}

    assert {:ok, %Snapshot{tree: ^tree, nodes: nodes, roots: roots}} =
             ShaderTree.snapshot(tree, server: c)

    assert is_list(nodes)
    assert Map.keys(roots) |> Enum.sort() == [:firefly, :poser4, :preview, :sketch, :superfly]
    assert_no_handles(c)
  end

  test "snapshot of a missing material's tree is not_found", %{c: c, skin: skin} do
    tree = Material.tree(%Material{owner: skin.owner, name: "Nope"})
    assert {:error, %Error{kind: :not_found}} = ShaderTree.snapshot(tree, server: c)
    assert_no_handles(c)
  end

  test "snapshot! returns the struct", %{c: c, skin: skin} do
    assert %Snapshot{nodes: [_, _]} = skin |> Material.tree() |> ShaderTree.snapshot!(server: c)
    assert_no_handles(c)
  end

  test "snapshot takes four requests with releases", %{c: c, skin: skin} do
    before = Client.request_count(server: c)
    assert {:ok, _} = skin |> Material.tree() |> ShaderTree.snapshot(server: c)
    assert Client.request_count(server: c) == before + 4
  end

  defp assert_no_handles(c), do: assert({:ok, %{"handles" => 0}} = Client.stats(server: c))
end
