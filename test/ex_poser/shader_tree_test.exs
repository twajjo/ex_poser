defmodule ExPoser.ShaderTreeTest do
  use ExUnit.Case, async: false

  import PoserTest.ClientCase

  alias ExPoser.{
    Actor,
    Batch,
    Client,
    Error,
    Figure,
    Material,
    ShaderInput,
    ShaderNode,
    ShaderOutput
  }

  alias ExPoser.ShaderTree

  setup do
    server = start_standalone()
    c = start_client(server.session)
    fig = %Figure{internal: "figure 1", name: "Figure 1"}
    hip = %Actor{figure: fig, internal: "hip", name: "hip"}
    tree = Material.tree(%Material{owner: hip, name: "Skin"})
    %{c: c, tree: tree}
  end

  test "nodes lists the tree's nodes", %{c: c, tree: tree} do
    assert {:ok, [%ShaderNode{tree: ^tree} | _] = nodes} = ShaderTree.nodes(tree, server: c)
    assert Enum.map(nodes, & &1.internal) == ["PoserSurface", "Image_Map"]
    assert Enum.all?(nodes, &is_binary(&1.name))
    assert [_, _] = ShaderTree.nodes!(tree, server: c)
    assert_no_handles(c)
  end

  test "node finds by internal name or display name", %{c: c, tree: tree} do
    assert {:ok, %ShaderNode{internal: "Image_Map", tree: ^tree} = node} =
             ShaderTree.node(tree, "Image_Map", server: c)

    assert {:ok, _} =
             Batch.new() |> Batch.call(node, "SetName", ["Color Map"]) |> Batch.run(server: c)

    assert {:ok, %ShaderNode{internal: "Image_Map", name: "Color Map"}} =
             ShaderTree.node(tree, "Color Map", server: c)

    assert %ShaderNode{} = ShaderTree.node!(tree, "Image_Map", server: c)
    assert_no_handles(c)
  end

  test "a missing node is not_found", %{c: c, tree: tree} do
    assert {:error, %Error{kind: :not_found}} = ShaderTree.node(tree, "Nope", server: c)
    assert_raise Error, fn -> ShaderTree.node!(tree, "Nope", server: c) end
    assert_no_handles(c)
  end

  test "inputs and outputs list the node's sockets", %{c: c, tree: tree} do
    surface = ShaderTree.node!(tree, "PoserSurface", server: c)

    assert {:ok, [%ShaderInput{node: ^surface} | _] = inputs} =
             ShaderNode.inputs(surface, server: c)

    assert Enum.map(inputs, & &1.internal) == ["Diffuse_Color", "Diffuse_Value", "Bump"]
    assert [_, _, _] = ShaderNode.inputs!(surface, server: c)

    image = ShaderTree.node!(tree, "Image_Map", server: c)

    assert {:ok, [%ShaderOutput{node: ^image, internal: "Color"}]} =
             ShaderNode.outputs(image, server: c)

    assert ["Color"] = image |> ShaderNode.outputs!(server: c) |> Enum.map(& &1.internal)
    assert_no_handles(c)
  end

  test "root reads the renderer's root node", %{c: c, tree: tree} do
    assert {:ok, %ShaderNode{internal: "PoserSurface", tree: ^tree}} =
             ShaderTree.root(tree, :firefly, server: c)

    before = Client.request_count(server: c)
    assert {:ok, %ShaderNode{}} = ShaderTree.root(tree, :firefly, server: c)
    assert Client.request_count(server: c) == before + 4
    assert ShaderTree.root(tree, :superfly, server: c) == {:ok, nil}
    assert ShaderTree.root!(tree, 1, server: c).internal == "PoserSurface"
    assert_no_handles(c)
  end

  test "set_root sets it, and bumps the preview count", %{c: c, tree: tree} do
    img = ShaderTree.node!(tree, "Image_Map", server: c)
    before = previews(c, tree)
    assert ShaderTree.set_root(img, :superfly, server: c) == {:ok, :ok}
    assert {:ok, %{internal: "Image_Map"}} = ShaderTree.root(tree, :superfly, server: c)
    assert previews(c, tree) == before + 1
    assert ShaderTree.set_root!(img, 3, server: c) == :ok
    assert previews(c, tree) == before + 2
    assert_no_handles(c)
  end

  test "an unknown renderer atom raises before any request", %{c: c, tree: tree} do
    img = ShaderTree.node!(tree, "Image_Map", server: c)
    before = Client.request_count(server: c)
    assert_raise ArgumentError, fn -> ShaderTree.set_root(img, :bogus, server: c) end
    assert_raise ArgumentError, fn -> ShaderTree.root(tree, :bogus, server: c) end
    assert_raise ArgumentError, fn -> Batch.set_root(Batch.new(), img, :bogus) end
    assert Client.request_count(server: c) == before
    assert_no_handles(c)
  end

  test "link and set_root in one batch refresh the preview once", %{c: c, tree: tree} do
    diffuse = %ShaderInput{
      node: ShaderTree.node!(tree, "PoserSurface", server: c),
      internal: "Diffuse_Color"
    }

    img = ShaderTree.node!(tree, "Image_Map", server: c)
    before = previews(c, tree)

    assert {:ok, [:ok, :ok, :ok]} =
             Batch.new()
             |> Batch.unlink(diffuse)
             |> Batch.link(img, diffuse)
             |> Batch.set_root(img, :poser4)
             |> Batch.run(server: c)

    assert previews(c, tree) == before + 1
    assert_no_handles(c)
  end

  test "create_node makes a node, refreshes the preview and leaves no handles", %{
    c: c,
    tree: tree
  } do
    before = previews(c, tree)

    assert {:ok, %ShaderNode{tree: ^tree, internal: "image_map", name: "image_map"}} =
             ShaderTree.create_node(tree, "image_map", server: c)

    assert {:ok, nodes} = ShaderTree.nodes(tree, server: c)
    assert "image_map" in Enum.map(nodes, & &1.internal)
    assert previews(c, tree) == before + 1
    assert_no_handles(c)
  end

  test "create_node! returns the node", %{c: c, tree: tree} do
    assert %ShaderNode{internal: "image_map"} =
             ShaderTree.create_node!(tree, "image_map", server: c)

    assert_no_handles(c)
  end

  test "create_node with an unknown type is Poser's error", %{c: c, tree: tree} do
    assert {:error, %Error{}} = ShaderTree.create_node(tree, "nope", server: c)
    assert_no_handles(c)
  end

  defp assert_no_handles(c), do: assert({:ok, %{"handles" => 0}} = Client.stats(server: c))

  defp previews(c, tree),
    do: Batch.new() |> Batch.call(tree, "PreviewCount") |> Batch.run!(server: c) |> hd()
end
