defmodule Poser.Gen.RealGeneratedTest do
  use ExUnit.Case, async: true

  test "the committed generated files are up to date" do
    assert ExUnit.CaptureIO.capture_io(fn -> Mix.Tasks.Poser.Gen.run(["--check"]) end) =~
             "up to date"
  end

  test "the manifest covers every function and method" do
    m = "priv/poser_api_manifest.json" |> File.read!() |> JSON.decode!()
    s = m["summary"]
    assert s["total"] == 1109
    assert s["generated"] + s["skipped"] == 1109
    assert s["variadic"] == 0
    assert is_list(s["unknown_types"])

    for {key, %{"status" => "skipped"} = e} <- m["entries"] do
      assert is_binary(e["reason"]) and e["reason"] != "", "#{key} skipped without a reason"
    end
  end

  test "spot checks" do
    for {mod, fun, arity} <- [
          {Poser.Api, :scene, 1},
          {Poser.Api.ParmType, :set_value, 3},
          {Poser.Api.SceneType, :actors, 2},
          {Poser.Api.ImageType, :new, 2},
          {Poser.Api.ShaderTreeType, :node, 3}
        ] do
      assert Code.ensure_loaded?(mod)
      assert function_exported?(mod, fun, arity), "#{inspect(mod)}.#{fun}/#{arity}"
    end

    assert Poser.Const.parm_code(:xscale) == 7
    assert Poser.Const.fetch("kParmCodeXSCALE") == {:ok, 7}
  end
end
