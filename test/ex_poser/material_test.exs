defmodule ExPoser.MaterialTest do
  use ExUnit.Case, async: false

  import PoserTest.ClientCase

  alias ExPoser.{Actor, Batch, Client, Error, Figure, Material, MaterialLayer}

  setup do
    server = start_standalone()
    c = start_client(server.session)
    fig = %Figure{internal: "figure 1", name: "Figure 1"}
    hip = %Actor{figure: fig, internal: "hip", name: "hip"}
    ball = %Actor{figure: nil, internal: "ball", name: "Ball"}
    %{c: c, fig: fig, hip: hip, ball: ball, skin: %Material{owner: hip, name: "Skin"}}
  end

  test "Figure.materials lists the figure's materials", %{c: c, fig: fig} do
    assert {:ok, [%Material{owner: ^fig} | _] = materials} = Figure.materials(fig, server: c)
    assert Enum.map(materials, & &1.name) == ["Skin", "Hair"]
    assert [_, _] = Figure.materials!(fig, server: c)
    assert_no_handles(c)
  end

  test "Actor.materials lists the actor's materials", %{c: c, hip: hip} do
    assert {:ok, [%Material{owner: ^hip, name: "Skin"}]} = Actor.materials(hip, server: c)
    assert [_] = Actor.materials!(hip, server: c)
    assert_no_handles(c)
  end

  test "Figure.material and Actor.material look a material up by name", %{
    c: c,
    fig: fig,
    ball: ball
  } do
    assert {:ok, %Material{owner: ^fig, name: "Hair"}} = Figure.material(fig, "Hair", server: c)
    assert %Material{name: "Hair"} = Figure.material!(fig, "Hair", server: c)

    assert {:ok, %Material{owner: ^ball, name: "Preview"}} =
             Actor.material(ball, "Preview", server: c)

    assert %Material{name: "Preview"} = Actor.material!(ball, "Preview", server: c)
    assert_no_handles(c)
  end

  test "a missing material is not_found", %{c: c, fig: fig, ball: ball} do
    assert {:error, %Error{kind: :not_found, details: %{path: path}}} =
             Figure.material(fig, "Nope", server: c)

    assert List.last(path) == {:material, "Nope"}
    assert {:error, %Error{kind: :not_found}} = Actor.material(ball, "Nope", server: c)
    assert_raise Error, fn -> Actor.material!(ball, "Nope", server: c) end
    assert_no_handles(c)
  end

  test "Material.layers lists the layers", %{c: c, skin: skin} do
    assert {:ok, [%MaterialLayer{material: ^skin}] = layers} = Material.layers(skin, server: c)
    assert Enum.map(layers, & &1.name) == ["Layer_1"]
    assert [_] = Material.layers!(skin, server: c)
    assert_no_handles(c)
  end

  test "Material.layer looks a layer up by name", %{c: c, skin: skin} do
    assert {:ok, %MaterialLayer{material: ^skin, name: "Layer_1"}} =
             Material.layer(skin, "Layer_1", server: c)

    assert %MaterialLayer{} = Material.layer!(skin, "Layer_1", server: c)

    assert {:error, %Error{kind: :not_found, details: %{path: path}}} =
             Material.layer(skin, "Nope", server: c)

    assert List.last(path) == {:layer, "Nope"}
    assert_no_handles(c)
  end

  test "Material.props lists the flat keys" do
    assert :diffuse_color in Material.props()
    assert :selected in Material.props()
    assert length(Material.props()) == 18
  end

  test "set then get a colour", %{c: c, skin: skin} do
    assert {:ok, :ok} = Material.set(skin, :diffuse_color, {0.1, 0.2, 0.3}, server: c)
    assert {:ok, {0.1, 0.2, 0.3}} = Material.get(skin, :diffuse_color, server: c)
    assert :ok = Material.set!(skin, :ns, 20, server: c)
    assert Material.get!(skin, :ns, server: c) == 20.0
    assert_no_handles(c)
  end

  test "a map set of a string and a float reads back", %{c: c, skin: skin} do
    assert {:ok, :ok} =
             Material.set(skin, %{texture_map: "skin.png", bump_strength: 0.5}, server: c)

    assert %{texture_map: "skin.png", bump_strength: 0.5} =
             Material.get!(skin, [:texture_map, :bump_strength], server: c)

    assert :ok = Material.set!(skin, %{selected: 1}, server: c)
    assert Material.get!(skin, :selected, server: c) == 1
    assert_no_handles(c)
  end

  test "get with a list returns a map", %{c: c, skin: skin} do
    assert {:ok, %{ns: 50.0, selected: 0}} = Material.get(skin, [:ns, :selected], server: c)
    assert_no_handles(c)
  end

  test "bad keys and values raise ArgumentError and send nothing", %{c: c, skin: skin} do
    before = Client.request_count(server: c)

    assert_raise ArgumentError, fn -> Material.set(skin, :nope, 1, server: c) end
    assert_raise ArgumentError, fn -> Material.set(skin, :diffuse_color, {1, 2}, server: c) end
    assert_raise ArgumentError, fn -> Material.set(skin, :texture_map, 1, server: c) end
    assert_raise ArgumentError, fn -> Material.set(skin, :ns, "x", server: c) end

    assert_raise ArgumentError, fn ->
      Material.set(skin, %{ns: 1.0, nope: 2}, server: c)
    end

    assert_raise ArgumentError, fn -> Material.get(skin, :nope, server: c) end
    assert_raise ArgumentError, fn -> Material.get(skin, [:ns, :nope], server: c) end
    assert_raise ArgumentError, fn -> Material.set(skin, :ns, 1.0, frame: 1) end
    assert_raise ArgumentError, fn -> Material.get(skin, :ns, frame: 1) end
    assert Client.request_count(server: c) == before
    assert Material.get!(skin, :ns, server: c) == 50.0
    assert_no_handles(c)
  end

  test "a flat set does not change the tree's PreviewCount", %{c: c, skin: skin} do
    count = fn ->
      Batch.new()
      |> Batch.call(Material.tree(skin), "PreviewCount")
      |> Batch.run!(server: c)
    end

    before = count.()
    Material.set!(skin, %{diffuse_color: {0.5, 0.5, 0.5}, ns: 10.0}, server: c)
    assert count.() == before
    assert_no_handles(c)
  end

  test "Batch.set_material adds a set op", %{c: c, skin: skin} do
    b =
      Batch.new()
      |> Batch.set_material(skin, :bump_strength, 2)
      |> Batch.set_material(skin, :ns, 5)

    assert Batch.size(b) == 2
    assert [:ok, :ok] = Batch.run!(b, server: c)
    assert Material.get!(skin, :bump_strength, server: c) == 2.0
    assert_raise ArgumentError, fn -> Batch.set_material(Batch.new(), skin, :nope, 1) end
    assert_no_handles(c)
  end

  test "Batch.set_material with a bad value raises before any request", %{c: c, skin: skin} do
    before = Client.request_count(server: c)

    assert_raise ArgumentError, fn ->
      Batch.set_material(Batch.new(), skin, :diffuse_color, {1, 2})
    end

    assert Client.request_count(server: c) == before
    assert_no_handles(c)
  end

  test "listings reject unknown options", %{c: c, fig: fig} do
    assert_raise ArgumentError, fn -> Figure.materials(fig, frame: 1) end
    assert_raise ArgumentError, fn -> Figure.material(fig, "Skin", frame: 1) end
    assert_no_handles(c)
  end

  defp assert_no_handles(c), do: assert({:ok, %{"handles" => 0}} = Client.stats(server: c))
end
