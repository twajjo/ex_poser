defmodule ExPoser.Gen.RealDumpTest do
  use ExUnit.Case, async: true

  alias ExPoser.Gen.{Overrides, Signature}

  test "every function and method parses, after overrides, or is skipped with a reason" do
    dump = PoserTest.ApiDump.dump()
    overrides = Overrides.load()

    entries =
      Enum.map(dump["functions"], &{"poser.#{&1["name"]}", &1}) ++
        for {class, v} <- dump["classes"], m <- v["methods"], do: {"#{class}.#{m["name"]}", m}

    results =
      for {key, m} <- entries do
        {key, Signature.for_entry(key, m["name"], m["doc"], overrides, dump["constants"])}
      end

    assert length(results) == 1109
    assert [] == for({key, {:error, reason}} <- results, do: {key, reason})

    for {_key, {:skip, reason}} <- results, do: assert(is_binary(reason) and reason != "")

    assert Enum.count(results, &match?({_, {:ok, _, :override}}, &1)) ==
             map_size(overrides["signatures"])
  end

  test "an override replaces the docstring" do
    o = %{"signatures" => %{"X.F" => "<IntType> F(<IntType> a)"}, "skip" => %{}}

    assert {:ok, %{params: [%{name: "a"}]}, :override} =
             Signature.for_entry("X.F", "F", "junk", o, %{})

    assert {:ok, %{params: []}, :docstring} =
             Signature.for_entry("X.G", "G", "<IntType> G()", o, %{})

    assert {:skip, "why"} =
             Signature.for_entry("X.H", "H", nil, %{o | "skip" => %{"X.H" => "why"}}, %{})

    assert {:error, _} = Signature.for_entry("X.J", "J", "nothing", o, %{})
  end
end
