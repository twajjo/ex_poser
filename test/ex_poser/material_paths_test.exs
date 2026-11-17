defmodule ExPoser.MaterialPathsTest do
  use ExUnit.Case, async: false

  import PoserTest.ClientCase

  alias ExPoser.{
    Actor,
    Batch,
    Client,
    Error,
    Figure,
    Material,
    MaterialLayer,
    Ref,
    Scene,
    ShaderNode,
    ShaderTree
  }

  setup do
    server = start_standalone()
    c = start_client(server.session)
    fig = %Figure{internal: "figure 1", name: "Figure 1"}
    hip = %Actor{figure: fig, internal: "hip", name: "hip"}
    skin = %Material{owner: hip, name: "Skin"}
    %{c: c, skin: skin}
  end

  test "Batch.call on a material input reads its value", %{c: c, skin: skin} do
    node = %ShaderNode{tree: Material.tree(skin), internal: "PoserSurface"}
    input = ShaderNode.input(node, "Diffuse_Color")

    assert {:ok, [{r, g, b}]} = Batch.new() |> Batch.call(input, "Value") |> Batch.run(server: c)
    assert is_number(r) and is_number(g) and is_number(b)
    assert_no_handles(c)
  end

  test "a layer's tree resolves", %{c: c, skin: skin} do
    layer = %MaterialLayer{material: skin, name: "Layer_1"}
    tree = MaterialLayer.tree(layer)

    assert Ref.path(tree) == Ref.path(layer) ++ [tree: :main]
    assert {:ok, [n]} = Batch.new() |> Batch.call(tree, "NumNodes") |> Batch.run(server: c)
    assert is_integer(n)
    assert_no_handles(c)
  end

  test "a missing layer is not_found with its path", %{c: c, skin: skin} do
    layer = %MaterialLayer{material: skin, name: "Nope"}

    assert {:error, %Error{kind: :not_found, details: %{path: path}}} =
             Batch.new() |> Batch.call(layer, "Name") |> Batch.run(server: c)

    assert List.last(path) == {:layer, "Nope"}
    assert_no_handles(c)
  end

  test "the atmosphere tree resolves", %{c: c} do
    atmo = Scene.atmosphere_tree()
    assert Ref.path(atmo) == [tree: :atmosphere]

    assert {:ok, [1]} = Batch.new() |> Batch.call(atmo, "NumNodes") |> Batch.run(server: c)
    assert_no_handles(c)
  end

  test "the background tree resolves", %{c: c} do
    bg = Scene.background_tree()
    assert Ref.path(bg) == [tree: :background]

    assert {:ok, [1]} = Batch.new() |> Batch.call(bg, "NumNodes") |> Batch.run(server: c)
    assert_no_handles(c)
  end

  test "handle/2 gives a live handle for each struct and releases cleanly", %{c: c, skin: skin} do
    tree = Material.tree(skin)
    node = %ShaderNode{tree: tree, internal: "PoserSurface"}
    input = ShaderNode.input(node, "Diffuse_Color")
    image = %ShaderNode{tree: tree, internal: "Image_Map"}
    output = ShaderNode.output(image, "Color")

    for {module, struct} <- [
          {Material, skin},
          {ShaderTree, tree},
          {ShaderTree, Scene.atmosphere_tree()},
          {ShaderTree, Scene.background_tree()},
          {ShaderNode, node},
          {ExPoser.ShaderInput, input},
          {ExPoser.ShaderOutput, output},
          {MaterialLayer, %MaterialLayer{material: skin, name: "Layer_1"}}
        ] do
      assert {:ok, %ExPoser.Handle{} = h} = module.handle(struct, server: c)
      Client.release([h], server: c)
    end

    assert {:error, %Error{kind: :not_found}} =
             Material.handle(%Material{owner: skin.owner, name: "Nope"}, server: c)

    assert_no_handles(c)
  end

  defp assert_no_handles(c), do: assert({:ok, %{"handles" => 0}} = Client.stats(server: c))
end
