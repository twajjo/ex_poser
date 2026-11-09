defmodule Poser.Gen.TypesTest do
  use ExUnit.Case, async: true

  alias Poser.Gen.Types

  @classes MapSet.new(["ActorType", "Palette"])

  defp spec(t, dir \\ :return), do: t |> Types.spec(dir, @classes) |> Macro.to_string()

  test "scalars" do
    for t <- ["IntType", "LongType", "EnumType"], do: assert(spec(t) == "integer()")
    assert spec("FloatType", :arg) == "number()"
    assert spec("FloatValue") == "float()"

    for t <- ["StringType", "String", "StringValue", "String Type"],
        do: assert(spec(t) == "String.t()")

    assert spec("BoolType", :arg) == "boolean()"
    assert spec("boolType") == "boolean() | integer()"
    assert spec("NoneType") == "nil"
  end

  test "classes become handles" do
    assert spec("ActorType") == "Poser.Handle.t()"
    assert spec("Palette") == "Poser.Handle.t()"
  end

  test "lists" do
    assert spec("ActorType List") == "[Poser.Handle.t()]"
    assert spec("StringType list") == "[String.t()]"
    assert spec("List of StringType") == "[String.t()]"
    assert spec("list IntType") == "[integer()]"
    assert spec("List of IntType Lists") == "[[integer()]]"
  end

  test "tuples, unions, arrays and containers" do
    assert spec({:tuple, ["IntType", "FloatType"]}) == "{integer(), float()}"
    assert spec({:union, ["FloatType", "StringType"]}) == "float() | String.t()"
    assert spec("FloatType nx3 Numeric.Array", :arg) == "Poser.NDArray.t()"
    assert spec("DictType") == "map()"
    assert spec("ListType") == "list()"
    assert spec("TupleType") == "tuple()"
    assert spec("FloatType 4x4 Tuple") == "tuple()"
  end

  test "unknown types become term() and are reported" do
    assert spec("list Palettes") == "[term()]"
    assert spec("object") == "term()"
    assert Types.unknowns("list Palettes", @classes) == ["Palettes"]
    assert Types.unknowns({:tuple, ["Weird", "IntType"]}, @classes) == ["Weird"]
    assert Types.unknowns("object", @classes) == []
  end
end
