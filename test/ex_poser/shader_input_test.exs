defmodule ExPoser.ShaderInputTest do
  use ExUnit.Case, async: false

  import PoserTest.ClientCase

  alias ExPoser.{Actor, Batch, Client, Error, Figure, Material, ShaderInput, ShaderTree}

  doctest ExPoser.ShaderInput

  setup do
    server = start_standalone()
    c = start_client(server.session)
    fig = %Figure{internal: "figure 1", name: "Figure 1"}
    hip = %Actor{figure: fig, internal: "hip", name: "hip"}
    tree = Material.tree(%Material{owner: hip, name: "Skin"})
    %{c: c, tree: tree}
  end

  test "set a string, then get it; the tree's preview refreshed once", %{c: c, tree: tree} do
    input = input(c, tree, "Image_Map", "Image_Source")
    before = previews(c, tree)

    assert ShaderInput.set(input, "C:/tex/a.png", server: c) == {:ok, :ok}
    assert ShaderInput.get(input, server: c) == {:ok, "C:/tex/a.png"}
    assert previews(c, tree) == before + 1
    assert ShaderInput.get!(input, server: c) == "C:/tex/a.png"
    assert ShaderInput.set!(input, "b.png", server: c) == :ok
    assert_no_handles(c)
  end

  test "a colour is set from a tuple and read back as one", %{c: c, tree: tree} do
    input = input(c, tree, "PoserSurface", "Diffuse_Color")
    assert ShaderInput.set(input, {1, 0, 0}, server: c) == {:ok, :ok}
    assert ShaderInput.get(input, server: c) == {:ok, {1.0, 0.0, 0.0}}
    assert_no_handles(c)
  end

  test "a number is set as a float", %{c: c, tree: tree} do
    input = input(c, tree, "PoserSurface", "Diffuse_Value")
    assert ShaderInput.set(input, 2, server: c) == {:ok, :ok}
    assert ShaderInput.get(input, server: c) == {:ok, 2.0}
    assert_no_handles(c)
  end

  test "a value of another shape raises before any request", %{c: c, tree: tree} do
    input = input(c, tree, "PoserSurface", "Diffuse_Value")
    before = Client.request_count(server: c)
    assert_raise ArgumentError, fn -> ShaderInput.set(input, :bad, server: c) end
    assert_raise ArgumentError, fn -> Batch.set_input(Batch.new(), input, {1, 2}) end
    assert_raise ArgumentError, fn -> ShaderInput.set(input, 1.0, frame: 1) end
    assert Client.request_count(server: c) == before
    assert_no_handles(c)
  end

  test "a string on a colour input is Poser's error", %{c: c, tree: tree} do
    input = input(c, tree, "PoserSurface", "Diffuse_Color")

    assert {:error, %Error{details: %{index: 0}}} =
             ShaderInput.set(input, "x.png", server: c)

    assert_no_handles(c)
  end

  test "type names the input's type", %{c: c, tree: tree} do
    color = input(c, tree, "PoserSurface", "Diffuse_Color")
    assert ShaderInput.type(color, server: c) == {:ok, :color}
    assert ShaderInput.type!(color, server: c) == :color
    float = input(c, tree, "PoserSurface", "Diffuse_Value")
    assert ShaderInput.type(float, server: c) == {:ok, :float}
    string = input(c, tree, "Image_Map", "Image_Source")
    assert ShaderInput.type(string, server: c) == {:ok, :string}
    assert_no_handles(c)
  end

  test "a batch whose second op fails keeps the first op applied", %{c: c, tree: tree} do
    good = input(c, tree, "PoserSurface", "Diffuse_Value")
    bad = input(c, tree, "PoserSurface", "Diffuse_Color")
    before = previews(c, tree)

    assert {:error, %Error{details: %{index: 1}}} =
             Batch.new()
             |> Batch.set_input(good, 3.0)
             |> Batch.set_input(bad, "x.png")
             |> Batch.run(server: c)

    assert ShaderInput.get(good, server: c) == {:ok, 3.0}
    assert previews(c, tree) == before
    assert_no_handles(c)
  end

  test "unlink, then link by node or by output, restores the source", %{c: c, tree: tree} do
    diffuse = input(c, tree, "PoserSurface", "Diffuse_Color")
    img = ShaderTree.node!(tree, "Image_Map", server: c)
    before = previews(c, tree)

    assert {:ok, %ExPoser.ShaderOutput{internal: "Color", node: %{internal: "Image_Map"}} = out} =
             ShaderInput.source(diffuse, server: c)

    assert out.node.tree == tree
    assert ShaderInput.unlink(diffuse, server: c) == {:ok, :ok}
    assert ShaderInput.source(diffuse, server: c) == {:ok, nil}
    assert previews(c, tree) == before + 1

    assert ShaderInput.link(diffuse, img, server: c) == {:ok, :ok}
    assert {:ok, %{internal: "Color"}} = ShaderInput.source(diffuse, server: c)
    assert previews(c, tree) == before + 2

    assert ShaderInput.unlink!(diffuse, server: c) == :ok
    assert ShaderInput.link!(diffuse, out, server: c) == :ok
    assert ShaderInput.source!(diffuse, server: c).internal == "Color"
    assert previews(c, tree) == before + 4
    assert_no_handles(c)
  end

  test "source takes two requests and their releases", %{c: c, tree: tree} do
    diffuse = input(c, tree, "PoserSurface", "Diffuse_Color")
    before = Client.request_count(server: c)
    assert {:ok, %{internal: "Color"}} = ShaderInput.source(diffuse, server: c)
    assert Client.request_count(server: c) == before + 4
    assert_no_handles(c)
  end

  defp assert_no_handles(c), do: assert({:ok, %{"handles" => 0}} = Client.stats(server: c))

  defp input(c, tree, node, internal) do
    node = ShaderTree.node!(tree, node, server: c)
    %ShaderInput{node: node, internal: internal}
  end

  defp previews(c, tree),
    do: Batch.new() |> Batch.call(tree, "PreviewCount") |> Batch.run!(server: c) |> hd()
end
