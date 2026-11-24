defmodule ExPoser.ShaderTreeSnapshotTest do
  use ExUnit.Case, async: false

  import PoserTest.ClientCase

  alias ExPoser.{Actor, Client, Error, Figure, Material, ShaderInput, ShaderOutput, ShaderTree}
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

    assert_no_handles(c)
  end

  test "snapshot reads inputs with their links", %{c: c, skin: skin} do
    assert {:ok, %Snapshot{nodes: [surface, image]}} =
             skin |> Material.tree() |> ShaderTree.snapshot(server: c)

    assert [diffuse, value, bump] = surface.inputs

    assert %{internal: "Diffuse_Color", name: "Diffuse_Color", from: {"Image_Map", "Color"}} =
             diffuse

    assert diffuse.type == 1
    assert diffuse.value == {0.0, 0.0, 0.0}
    assert %{internal: "Diffuse_Value", from: nil, type: 0} = value
    assert value.value == 0.0
    assert %{internal: "Bump", from: nil} = bump
    assert [%{internal: "Image_Source", from: nil}, %{internal: "U_Offset"}] = image.inputs
    assert_no_handles(c)
  end

  test "snapshot pairs each linked input with its own source", %{c: c, skin: skin} do
    tree = Material.tree(skin)
    surface = ShaderTree.node!(tree, "PoserSurface", server: c)
    extra = ShaderTree.create_node!(tree, "image_map", server: c)
    bump = %ShaderInput{node: surface, internal: "Bump"}
    ShaderInput.link!(bump, %ShaderOutput{node: extra, internal: "Color"}, server: c)

    assert {:ok, %Snapshot{nodes: [snap_surface | _]}} = ShaderTree.snapshot(tree, server: c)
    assert [diffuse, _value, snap_bump] = snap_surface.inputs
    assert diffuse.from == {"Image_Map", "Color"}
    assert snap_bump.from == {extra.internal, "Color"}
    assert_no_handles(c)
  end

  test "snapshot reads outputs", %{c: c, skin: skin} do
    assert {:ok, %Snapshot{nodes: [surface, image]}} =
             skin |> Material.tree() |> ShaderTree.snapshot(server: c)

    assert [%{internal: "Color", name: "Color"}] = image.outputs
    assert [%{internal: "out"}] = surface.outputs
    assert_no_handles(c)
  end

  test "snapshot of a tree with no links sends no link request", %{c: c} do
    tree = %ShaderTree{owner: :background}
    before = Client.request_count(server: c)
    assert {:ok, %Snapshot{nodes: nodes}} = ShaderTree.snapshot(tree, server: c)
    assert [_ | _] = nodes
    assert Enum.all?(nodes, fn node -> Enum.all?(node.inputs, &(&1.from == nil)) end)
    assert Client.request_count(server: c) == before + 6
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

  test "snapshot takes eight requests however many nodes", %{c: c, skin: skin} do
    tree = Material.tree(skin)
    before = Client.request_count(server: c)
    assert {:ok, _} = ShaderTree.snapshot(tree, server: c)
    assert Client.request_count(server: c) == before + 8

    for _ <- 1..5, do: ShaderTree.create_node!(tree, "image_map", server: c)

    before = Client.request_count(server: c)
    assert {:ok, %Snapshot{nodes: nodes}} = ShaderTree.snapshot(tree, server: c)
    assert length(nodes) == 7
    assert Client.request_count(server: c) == before + 8
    assert_no_handles(c)
  end

  defp assert_no_handles(c), do: assert({:ok, %{"handles" => 0}} = Client.stats(server: c))
end
