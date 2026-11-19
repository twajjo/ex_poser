defmodule ExPoser.MaterialLayerTest do
  use ExUnit.Case, async: false

  import PoserTest.ClientCase

  alias ExPoser.{Actor, Batch, Client, Error, Figure, Material, MaterialLayer, ShaderTree}

  setup do
    server = start_standalone()
    c = start_client(server.session)
    fig = %Figure{internal: "figure 1", name: "Figure 1"}
    hip = %Actor{figure: fig, internal: "hip", name: "hip"}
    %{c: c, skin: %Material{owner: hip, name: "Skin"}}
  end

  test "create_layer adds a listed layer whose tree resolves", %{c: c, skin: skin} do
    wet = %MaterialLayer{material: skin, name: "Wet"}
    assert {:ok, ^wet} = Material.create_layer(skin, "Wet", server: c)

    assert {:ok, layers} = Material.layers(skin, server: c)
    assert "Wet" in Enum.map(layers, & &1.name)

    assert {:ok, nodes} = wet |> MaterialLayer.tree() |> ShaderTree.nodes(server: c)
    assert is_list(nodes)
    assert_no_handles(c)
  end

  test "create_layer! returns the struct", %{c: c, skin: skin} do
    assert %MaterialLayer{material: ^skin, name: "Wet"} =
             Material.create_layer!(skin, "Wet", server: c)

    assert_no_handles(c)
  end

  test "create_layer on a missing material is not_found", %{c: c, skin: skin} do
    missing = %Material{owner: skin.owner, name: "Nope"}

    assert {:error, %Error{kind: :not_found}} =
             Material.create_layer(missing, "Wet", server: c)

    assert_no_handles(c)
  end

  test "Batch.create_layer compiles to one CreateLayer on the material", %{skin: skin} do
    b = Batch.new() |> Batch.create_layer(skin, "Wet")
    assert [{wire, _roles}] = Batch.compile(b, chunk: 2000)

    assert [
             {:call, "Scene", []},
             {:invoke, {:result, 0}, "FigureByInternalName", ["figure 1"]},
             {:invoke, {:result, 1}, "ActorByInternalName", ["hip"]},
             {:invoke, {:result, 2}, "Material", ["Skin"]},
             {:invoke, {:result, 3}, "CreateLayer", ["Wet"]}
           ] = wire
  end

  defp assert_no_handles(c), do: assert({:ok, %{"handles" => 0}} = Client.stats(server: c))
end
