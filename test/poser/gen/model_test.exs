defmodule Poser.Gen.ModelTest do
  use ExUnit.Case, async: true

  alias Poser.Gen.{Model, Overrides}

  setup_all do
    dump = "test/fixtures/gen_api.json" |> File.read!() |> JSON.decode!()
    overrides = Overrides.load("test/fixtures/gen_overrides.json")
    %{model: Model.build(dump, overrides, PoserTest.GenApi)}
  end

  defp mod(model, class), do: Enum.find(model.modules, &(&1.py_class == class))
  defp fun(model, class, name), do: Enum.find(mod(model, class).funs, &(&1.name == name))

  test "one module per class, module functions in the namespace", %{model: model} do
    assert mod(model, "ActorType").module == PoserTest.GenApi.ActorType
    assert model.functions.module == PoserTest.GenApi
    assert Enum.any?(model.functions.funs, &(&1.name == :scene and &1.kind == :function))
    refute mod(model, "error")
  end

  test "a base class accepts its subclasses", %{model: model} do
    assert mod(model, "SceneObjectType").accepts == [
             "ActorType",
             "FigureType",
             "ParmType",
             "SceneObjectType"
           ]

    assert mod(model, "ActorType").accepts == ["ActorType"]
  end

  test "snake_case names and parameters", %{model: model} do
    f = fun(model, "ActorType", :parameter)
    assert f.py_name == "Parameter"
    assert f.kind == :method
    assert [%{name: "parmName", var: :parm_name}] = f.required
    assert f.source == :docstring

    assert %{optional: [discard_changes: {:default, 0}], required: []} =
             Enum.find(model.functions.funs, &(&1.name == :close_document))
  end

  test "a lowercase alias that collides is skipped", %{model: model} do
    assert fun(model, "GeomType", :num_vertices).py_name == "NumVertices"
    assert model.manifest["entries"]["GeomType.numVertices"]["reason"] =~ "alias of NumVertices"
  end

  test "a Kernel name is excluded from the module's Kernel import", %{model: model} do
    # GeomType.node/2,3 don't overlap Kernel.node/0,1; a 1..2 range would
    assert fun(model, "GeomType", :node)
    assert mod(model, "GeomType").kernel_except == []
    assert Model.kernel_clashes(:node, 1..2) == [node: 1]
    assert Model.kernel_clashes(:frame, 1..2) == []
  end

  test "callbacks and exception classes are skipped with reasons", %{model: model} do
    refute fun(model, "ActorType", :set_update_callback)
    assert model.manifest["entries"]["ActorType.SetUpdateCallback"]["reason"] =~ "callback"
    assert model.manifest["entries"]["error.with_traceback"]["reason"] =~ "exception"
  end

  test "a documented constructor becomes new/N", %{model: model} do
    assert %{kind: :function, py_name: "ImageType", required: [%{var: :full_image_path}]} =
             mod(model, "ImageType").constructor
  end

  test "getters", %{model: model} do
    assert fun(model, "SceneType", :frame).getter?
    refute fun(model, "SceneType", :set_frame).getter?
    refute fun(model, "SceneType", :actor).getter?
    assert Enum.find(model.functions.funs, &(&1.name == :scene)).getter?
    refute Enum.find(model.functions.funs, &(&1.name == :new_scene)).getter?
  end

  test "an unparseable docstring falls back to a variadic function", %{model: model} do
    f = fun(model, "ActorType", :odd)
    assert f.source == :variadic
    refute f.getter?
    assert model.manifest["entries"]["ActorType.Odd"]["source"] == "variadic"
  end

  test "the manifest counts every entry", %{model: model} do
    s = model.manifest["summary"]
    assert s["generated"] + s["skipped"] == 39
    assert s["skipped"] == 3
    assert s["variadic"] == 1

    assert model.manifest["entries"]["ActorType.Parameter"]["module"] ==
             "PoserTest.GenApi.ActorType"

    assert model.manifest["entries"]["ActorType.Parameter"]["function"] == "parameter"
    assert model.manifest["entries"]["GeomType.Vertices"]["returns"] == "VertexType List"
    assert "VertexType" in Map.keys(model.manifest["classes"])
  end
end
