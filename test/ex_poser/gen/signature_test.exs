defmodule ExPoser.Gen.SignatureTest do
  use ExUnit.Case, async: true

  import PoserTest.ApiDump, only: [doc: 2]

  alias ExPoser.Gen.Signature

  @constants %{"kMirrorTypeNone" => -1}

  defp parse(class, name), do: Signature.parse(name, doc(class, name), @constants)

  test "an optional parameter with a default" do
    assert {:ok, %{returns: "NoneType", params: [p]}} = parse("poser", "CloseDocument")
    assert p == %{name: "discardChanges", type: "IntType", optional: true, default: {:default, 0}}
  end

  test "an optional parameter without a default" do
    assert {:ok, %{params: [%{name: "frame", optional: true, default: :none}]}} =
             parse("ActorType", "AddKeyFrame")
  end

  test "no parameters" do
    assert {:ok, %{returns: "StringType", params: []}} = parse("poser", "AppVersion")
  end

  test "required parameters" do
    assert {:ok,
            %{
              returns: "ParmType",
              params: [%{name: "parmName", type: "StringType", optional: false}]
            }} =
             parse("ActorType", "Parameter")
  end

  test "defaults: false and a poser constant" do
    line =
      "<TupleType> CopyMorphsFromFigure(<FigureType> sourceFigure, <TupleType> morphTargetsTuple, " <>
        "{<BoolType> iUseSetupRefGeom = false, <IntType> iMirrorOption = poser.kMirrorTypeNone, " <>
        "<BoolType> iSkipExisting = false, <BoolType> iOnlyExisting = false})"

    assert {:ok, %{params: params}} = Signature.parse("CopyMorphsFromFigure", line, @constants)
    assert Enum.map(params, & &1.optional) == [false, false, true, true, true, true]

    assert Enum.map(params, & &1.default) == [
             :none,
             :none,
             {:default, false},
             {:default, -1},
             {:default, false},
             {:default, false}
           ]
  end

  test "an unknown constant default is an error" do
    assert {:error, _} =
             Signature.parse("F", "<NoneType> F({<IntType> a = poser.kNope})", @constants)
  end

  test "tuple returns" do
    assert {:ok, %{returns: {:tuple, ["FloatType", "FloatType", "FloatType"]}}} =
             parse("ActorType", "AlignmentRotationXYZ")

    assert {:ok, %{returns: {:tuple, [{:tuple, ["IntType", "IntType"]}, "ParmType"]}}} =
             Signature.parse("F", "((<IntType>, <IntType>), <ParmType> p) F()", %{})
  end

  test "malformed docstrings are errors" do
    assert {:error, _} = parse("ParmType", "SetValue")
    assert {:error, _} = parse("CredManagerType", "GetPassword")
    assert {:error, _} = parse("poser", "PrefsLocation")
    assert {:error, _} = parse("FigureType", "CopyMorphsFromFigure")
    assert {:error, _} = parse("ActorType", "SetGimbal")
    assert {:error, _} = parse("ActorType", "GetLightIntensity")
    assert {:error, _} = Signature.parse("F", "<NoneType> F(<IntType> a", %{})
    assert {:error, _} = Signature.parse("F", "<NoneType> F({<IntType> a)", %{})
    assert {:error, _} = Signature.parse("F", "<NoneType> F(<IntType size)", %{})
    assert {:error, _} = Signature.parse("F", "<NoneType> F(<IntType>)", %{})
  end

  test "the signature line is the last line with a type, not an example" do
    assert {:ok, %{returns: "list Palettes", params: []}} = parse("poser", "Palettes")
  end

  test "several signature lines with the same parameters union their returns" do
    assert {:ok,
            %{
              returns:
                {:union,
                 ["FloatType", {:tuple, ["FloatType", "FloatType", "FloatType"]}, "StringType"]}
            }} =
             parse("ShaderNodeInputType", "Value")
  end

  test "list return types keep their text" do
    assert {:ok, %{returns: "ActorType List"}} = parse("SceneType", "Actors")
  end

  test "a missing docstring is an error" do
    assert {:error, _} = Signature.parse("F", nil, %{})
  end
end
