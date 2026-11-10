defmodule ExPoser.Gen.ConstantsTest do
  use ExUnit.Case, async: true

  alias ExPoser.Gen.{Model, Render}

  test "grouped constants become functions keyed by atoms" do
    assert PoserTest.Const.parm_code(:xscale) == "xScale"
    assert PoserTest.Const.parm_code(:xtran) == "xTran"
    assert PoserTest.Const.parm_code_keys() == [:xscale, :xtran]
    assert PoserTest.Const.tiff(:lzw) == 5
    # apply/3: a literal bad key is a compile-time type warning
    assert_raise FunctionClauseError, fn -> apply(PoserTest.Const, :parm_code, [:nope]) end
  end

  test "the longest prefix wins" do
    assert PoserTest.Const.node_type_code_cycles(:mix) == "cmix"
    assert PoserTest.Const.node_type_code(:blender) == "blender"
    assert PoserTest.Const.node_type_code_keys() == [:blender]
  end

  test "every constant is reachable by its Python name" do
    assert PoserTest.Const.fetch("kLoner") == {:ok, 7}
    assert PoserTest.Const.fetch("kParmCodeXSCALE") == {:ok, "xScale"}
    assert PoserTest.Const.fetch("kNope") == :error
    assert map_size(PoserTest.Const.all()) == 6
  end

  test "two constants with the same key in a group fail generation, naming both" do
    model = PoserTest.GenFixture.model()

    dump = %{
      "meta" => %{},
      "functions" => [],
      "classes" => %{},
      "constants" => %{"kParmCodeFooBar" => 1, "kParmCodeFOO_BAR" => 2}
    }

    overrides = ExPoser.Gen.Overrides.load("test/fixtures/gen_overrides.json")

    e = assert_raise ArgumentError, fn -> Model.build(dump, overrides, PoserTest.GenApi) end
    assert e.message =~ "kParmCodeFooBar"
    assert e.message =~ "kParmCodeFOO_BAR"
    assert Enum.any?(Render.files(model), fn {p, _} -> p == "poser_test/const.ex" end)
  end
end

defmodule ExPoser.Gen.ConstantAliasTest do
  use ExUnit.Case, async: true

  test "two constants with the same key and value are one key" do
    dump = %{
      "meta" => %{},
      "functions" => [],
      "classes" => %{},
      "constants" => %{"kParmCodeFooBar" => 1, "kParmCodeFOO_BAR" => 1}
    }

    overrides = ExPoser.Gen.Overrides.load("test/fixtures/gen_overrides.json")
    model = ExPoser.Gen.Model.build(dump, overrides, PoserTest.GenApi)
    assert [%{name: :parm_code, keys: [{:foo_bar, 1, _}]}] = model.const.groups
  end
end
