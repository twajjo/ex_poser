defmodule Poser.Gen.GeneratedFakeTest do
  # Not async: events go through one global registry.
  use ExUnit.Case, async: false

  import PoserTest.ClientCase

  alias Poser.{Error, Handle, NDArray}
  alias PoserTest.GenApi
  alias PoserTest.GenApi.{ActorType, GeomType, ImageType, ParmType, SceneObjectType, SceneType}

  setup do
    server = start_standalone()
    %{c: start_client(server.session)}
  end

  test "generated code compiled without warnings" do
    assert PoserTest.GenFixture.diagnostics() == []
  end

  test "module functions and methods", %{c: c} do
    assert {:ok, %Handle{class: "SceneType"} = scene} = GenApi.scene(server: c)
    assert SceneType.set_frame(scene, 3, server: c) == {:ok, nil}
    assert SceneType.frame(scene, server: c) == {:ok, 3}
    assert {:error, %Error{kind: :python}} = SceneType.set_frame(scene, 99, server: c)

    {:ok, actor} = SceneType.actor(scene, "hip", server: c)
    {:ok, parm} = ActorType.parameter(actor, "xTran", server: c)
    assert {:ok, v} = ParmType.value(parm, server: c)
    assert is_float(v)
  end

  test "an inherited method accepts a subclass handle", %{c: c} do
    {:ok, scene} = GenApi.scene(server: c)
    {:ok, actor} = SceneType.actor(scene, "hip", server: c)
    assert SceneObjectType.name(actor, server: c) == {:ok, "hip"}
  end

  test "a handle of the wrong class raises FunctionClauseError", %{c: c} do
    {:ok, scene} = GenApi.scene(server: c)
    {:ok, actor} = SceneType.actor(scene, "hip", server: c)
    assert_raise FunctionClauseError, fn -> SceneType.frame(actor, server: c) end
  end

  test "a constructor", %{c: c} do
    assert {:ok, %Handle{class: "ImageType"} = img} = ImageType.new("C:/x.png", server: c)
    assert ImageType.path(img, server: c) == {:ok, "C:/x.png"}
  end

  test "a variadic function passes its argument list", %{c: c} do
    {:ok, scene} = GenApi.scene(server: c)
    {:ok, actor} = SceneType.actor(scene, "hip", server: c)
    assert ActorType.odd(actor, [1, 2], server: c) == {:ok, 2}
  end

  @tag :numpy
  test "an NDArray round trip", %{c: c} do
    {:ok, scene} = GenApi.scene(server: c)
    {:ok, actor} = SceneType.actor(scene, "hip", server: c)
    {:ok, geom} = ActorType.geometry(actor, server: c)

    a = %NDArray{
      dtype: "<f8",
      shape: {1, 3},
      data: <<1.0::float-little, 2.0::float-little, 3.0::float-little>>
    }

    assert GeomType.set_vertex_positions(geom, a, server: c) == {:ok, nil}
    assert GeomType.vertex_positions(geom, server: c) == {:ok, a}
  end
end
