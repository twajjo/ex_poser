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

  defp assert_no_handles(c), do: assert({:ok, %{"handles" => 0}} = Client.stats(server: c))
end
