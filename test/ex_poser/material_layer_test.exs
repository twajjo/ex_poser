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

  test "delete removes the layer", %{c: c, skin: skin} do
    wet = Material.create_layer!(skin, "Wet", server: c)
    assert {:ok, :ok} = MaterialLayer.delete(wet, server: c)

    assert {:ok, layers} = Material.layers(skin, server: c)
    refute "Wet" in Enum.map(layers, & &1.name)
    assert_no_handles(c)
  end

  test "delete! returns :ok", %{c: c, skin: skin} do
    wet = Material.create_layer!(skin, "Wet", server: c)
    assert :ok = MaterialLayer.delete!(wet, server: c)
    assert_no_handles(c)
  end

  test "delete of a missing layer is not_found with its path", %{c: c, skin: skin} do
    nope = %MaterialLayer{material: skin, name: "Nope"}

    assert {:error, %Error{kind: :not_found, details: %{path: path}}} =
             MaterialLayer.delete(nope, server: c)

    assert path == ExPoser.Ref.path(nope)
    assert_no_handles(c)
  end

  test "delete on a missing material is not_found", %{c: c, skin: skin} do
    missing = %Material{owner: skin.owner, name: "Nope"}
    layer = %MaterialLayer{material: missing, name: "Wet"}

    assert {:error, %Error{kind: :not_found}} = MaterialLayer.delete(layer, server: c)
    assert_no_handles(c)
  end

  test "delete of a duplicated name is ambiguous and deletes nothing", %{c: c, skin: skin} do
    dup = Material.create_layer!(skin, "Dup", server: c)
    Material.create_layer!(skin, "Dup", server: c)
    before = length(Material.layers!(skin, server: c))

    assert {:error, %Error{kind: :ambiguous}} = MaterialLayer.delete(dup, server: c)
    assert length(Material.layers!(skin, server: c)) == before
    assert_no_handles(c)
  end

  test "delete sends three batches, six requests with releases", %{c: c, skin: skin} do
    wet = Material.create_layer!(skin, "Wet", server: c)
    before = Client.request_count(server: c)

    assert {:ok, :ok} = MaterialLayer.delete(wet, server: c)
    # Three batches (list, read, delete), each followed by a release of its handles.
    assert Client.request_count(server: c) == before + 6
  end

  defp assert_no_handles(c), do: assert({:ok, %{"handles" => 0}} = Client.stats(server: c))
end
