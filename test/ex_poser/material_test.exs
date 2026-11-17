defmodule ExPoser.MaterialTest do
  use ExUnit.Case, async: false

  import PoserTest.ClientCase

  alias ExPoser.{Actor, Client, Error, Figure, Material, MaterialLayer}

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

  test "listings reject unknown options", %{c: c, fig: fig} do
    assert_raise ArgumentError, fn -> Figure.materials(fig, frame: 1) end
    assert_raise ArgumentError, fn -> Figure.material(fig, "Skin", frame: 1) end
    assert_no_handles(c)
  end

  defp assert_no_handles(c), do: assert({:ok, %{"handles" => 0}} = Client.stats(server: c))
end
