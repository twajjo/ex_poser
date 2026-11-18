defmodule ExPoser.ShaderNodeTest do
  use ExUnit.Case, async: false

  import PoserTest.ClientCase

  alias ExPoser.{Actor, Batch, Client, Figure, Material, ShaderNode, ShaderTree}

  doctest ExPoser.ShaderNode

  setup do
    server = start_standalone()
    c = start_client(server.session)
    fig = %Figure{internal: "figure 1", name: "Figure 1"}
    hip = %Actor{figure: fig, internal: "hip", name: "hip"}
    tree = Material.tree(%Material{owner: hip, name: "Skin"})
    %{c: c, tree: tree}
  end

  test "set a location, then get it as a tuple", %{c: c, tree: tree} do
    img = node(c, tree, "Image_Map")
    assert ShaderNode.set(img, :location, {120, 40}, server: c) == {:ok, :ok}
    assert ShaderNode.get(img, :location, server: c) == {:ok, {120, 40}}
    assert ShaderNode.set!(img, %{location: {1, 2}}, server: c) == :ok
    assert ShaderNode.get!(img, :location, server: c) == {1, 2}
    assert_no_handles(c)
  end

  test "set a name, then get it", %{c: c, tree: tree} do
    img = node(c, tree, "Image_Map")
    assert ShaderNode.set(img, %{name: "Colour map"}, server: c) == {:ok, :ok}
    assert ShaderNode.get(img, :name, server: c) == {:ok, "Colour map"}
    assert ShaderNode.set(img, :name, "Again", server: c) == {:ok, :ok}
    assert ShaderNode.get(img, :name, server: c) == {:ok, "Again"}
    assert_no_handles(c)
  end

  test "get a list of keys gives a map", %{c: c, tree: tree} do
    surface = node(c, tree, "PoserSurface")
    assert {:ok, %{type: type, root: root}} = ShaderNode.get(surface, [:type, :root], server: c)
    assert is_binary(type)
    assert root in [0, 1, true]
    assert_no_handles(c)
  end

  test "bad keys and values raise ArgumentError and send nothing", %{c: c, tree: tree} do
    img = node(c, tree, "Image_Map")
    before = Client.request_count(server: c)

    assert_raise ArgumentError, fn -> ShaderNode.get(img, :nope, server: c) end
    assert_raise ArgumentError, fn -> ShaderNode.get(img, [:name, :nope], server: c) end
    assert_raise ArgumentError, fn -> ShaderNode.get(img, :name, frame: 1) end
    assert_raise ArgumentError, fn -> ShaderNode.set(img, :nope, 1, server: c) end
    assert_raise ArgumentError, fn -> ShaderNode.set(img, :type, "x", server: c) end
    assert_raise ArgumentError, fn -> ShaderNode.set(img, :location, {1.5, 2}, server: c) end
    assert_raise ArgumentError, fn -> ShaderNode.set(img, :name, 1, server: c) end
    assert_raise ArgumentError, fn -> ShaderNode.set(img, :name, "x", frame: 1) end
    assert_raise ArgumentError, fn -> ShaderNode.set(img, %{name: "x", nope: 2}, server: c) end
    assert Client.request_count(server: c) == before
    assert_no_handles(c)
  end

  test "Batch.set_node adds a set op and does not change the tree", %{c: c, tree: tree} do
    img = node(c, tree, "Image_Map")
    before = previews(c, tree)

    b =
      Batch.new()
      |> Batch.set_node(img, :name, "Renamed")
      |> Batch.set_node(img, :location, {5, 6})

    assert Batch.size(b) == 2
    assert [:ok, :ok] = Batch.run!(b, server: c)

    assert ShaderNode.get!(img, [:name, :location], server: c) == %{
             name: "Renamed",
             location: {5, 6}
           }

    assert previews(c, tree) == before
    assert_raise ArgumentError, fn -> Batch.set_node(Batch.new(), img, :nope, 1) end
    assert_raise ArgumentError, fn -> Batch.set_node(Batch.new(), img, :location, {1, 2.5}) end
    assert_no_handles(c)
  end

  test "delete removes the node and refreshes the preview", %{c: c, tree: tree} do
    img = node(c, tree, "Image_Map")
    before = previews(c, tree)

    assert ShaderNode.delete(img, server: c) == {:ok, :ok}
    assert {:ok, nodes} = ShaderTree.nodes(tree, server: c)
    refute Enum.any?(nodes, &(&1.internal == "Image_Map"))
    assert previews(c, tree) == before + 1
    assert_no_handles(c)
  end

  test "delete! returns :ok", %{c: c, tree: tree} do
    img = node(c, tree, "Image_Map")
    assert ShaderNode.delete!(img, server: c) == :ok
    assert_no_handles(c)
  end

  test "an op on a deleted node's input in the same batch is not found; the delete stays",
       %{c: c, tree: tree} do
    img = node(c, tree, "Image_Map")
    offset = ShaderNode.input(img, "U_Offset")

    assert {:error, %ExPoser.Error{kind: :not_found, details: %{index: 1}}} =
             Batch.new()
             |> Batch.delete_node(img)
             |> Batch.set_input(offset, 1.0)
             |> Batch.run(server: c)

    assert {:ok, nodes} = ShaderTree.nodes(tree, server: c)
    refute Enum.any?(nodes, &(&1.internal == "Image_Map"))
    assert_no_handles(c)
  end

  defp assert_no_handles(c), do: assert({:ok, %{"handles" => 0}} = Client.stats(server: c))

  defp node(c, tree, internal), do: ShaderTree.node!(tree, internal, server: c)

  defp previews(c, tree),
    do: Batch.new() |> Batch.call(tree, "PreviewCount") |> Batch.run!(server: c) |> hd()
end
