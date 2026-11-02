defmodule Poser.Gen.RenderTest do
  use ExUnit.Case, async: true

  alias Poser.Gen.Render

  setup_all do
    model = PoserTest.GenFixture.model()

    %{
      model: model,
      files: Map.new(Render.files(model), fn {p, c} -> {p, IO.iodata_to_binary(c)} end)
    }
  end

  test "file paths follow the module names", %{files: files} do
    assert Map.has_key?(files, "poser_test/gen_api.ex")
    assert Map.has_key?(files, "poser_test/gen_api/actor_type.ex")
    refute Map.has_key?(files, "poser_test/gen_api/error.ex")
  end

  test "output is stable", %{model: model, files: files} do
    again = Map.new(Render.files(model), fn {p, c} -> {p, IO.iodata_to_binary(c)} end)
    assert again == files
  end

  test "a method", %{files: files} do
    src = files["poser_test/gen_api/actor_type.ex"]
    assert src =~ ~s(@accepts ["ActorType"])
    assert src =~ "@type t :: Poser.Handle.t()"

    assert src =~
             "def parameter(%Poser.Handle{class: c} = handle, parm_name, opts \\\\ []) when c in @accepts"

    assert src =~ ~S|Poser.Call.method(handle, "Parameter", [parm_name], [], opts)|
    assert src =~ "@spec parameter(Poser.Handle.t(), String.t(), keyword()) ::"
    assert src =~ "Python: `ActorType.Parameter`"
  end

  test "docstrings with triple quotes and interpolation stay inert", %{files: files} do
    src = files["poser_test/gen_api/actor_type.ex"]

    assert src =~ ~S(\"""quoted\"""  or #{interpolated}) or
             src =~ ~S(\"""quoted\""" or #{interpolated})

    assert PoserTest.GenFixture.diagnostics() == []
    {:docs_v1, _, _, _, _, _, docs} = Code.fetch_docs(PoserTest.GenFixture.beam(PoserTest.GenApi.ActorType))

    {_, _, _, %{"en" => doc}, _} =
      Enum.find(docs, &match?({{:function, :parameter, 3}, _, _, _, _}, &1))

    assert doc =~ ~S("""quoted""" or #{interpolated})
  end

  test "module functions, optionals and the variadic shape", %{files: files} do
    src = files["poser_test/gen_api.ex"]
    assert src =~ ~S|def scene(opts \\ []), do: Poser.Call.function("Scene", [], [], opts)|

    assert src =~
             ~S|Poser.Call.function("CloseDocument", [], [discard_changes: {:default, 0}], opts)|

    odd = files["poser_test/gen_api/actor_type.ex"]
    assert odd =~ "def odd(%Poser.Handle{class: c} = handle, args \\\\ [], opts \\\\ [])"
    assert odd =~ "signature not parsed"
  end

  test "a constructor renders as new/N", %{files: files} do
    src = files["poser_test/gen_api/image_type.ex"]
    assert src =~ ~S|def new(full_image_path, opts \\ []),|
    assert src =~ ~S|Poser.Call.function("ImageType", [full_image_path], [], opts)|
  end
end
