defmodule ExPoser.RefTest do
  use ExUnit.Case, async: true

  alias ExPoser.{Actor, Figure, Parameter, Ref}

  doctest ExPoser.Figure
  doctest ExPoser.Actor
  doctest ExPoser.Parameter
  doctest ExPoser.Ref

  @fig %Figure{internal: "figure 1", name: "Andy"}
  @actor %Actor{figure: @fig, internal: "lforearm", name: "Left Forearm"}
  @prop %Actor{figure: nil, internal: "ball", name: "Ball"}

  test "path/1" do
    assert Ref.path(:scene) == []
    assert Ref.path(@fig) == [{:figure, "figure 1"}]
    assert Ref.path(@actor) == [{:figure, "figure 1"}, {:actor, "lforearm"}]
    assert Ref.path(@prop) == [{:actor, "ball"}]

    parm = %Parameter{actor: @actor, internal: "bend", name: "Bend"}
    assert Ref.path(parm) == [{:figure, "figure 1"}, {:actor, "lforearm"}, {:parm, "bend"}]

    prop_parm = %Parameter{actor: @prop, internal: "xTran", name: "xTran"}
    assert Ref.path(prop_parm) == [{:actor, "ball"}, {:parm, "xTran"}]
  end

  test "lookup_op/3" do
    assert Ref.lookup_op({:figure, "figure 1"}, {:result, 0}, :scene) ==
             {:invoke, {:result, 0}, "FigureByInternalName", ["figure 1"]}

    assert Ref.lookup_op({:actor, "lforearm"}, {:result, 1}, :figure) ==
             {:invoke, {:result, 1}, "ActorByInternalName", ["lforearm"]}

    assert Ref.lookup_op({:actor, "ball"}, {:result, 0}, :scene) ==
             {:invoke, {:result, 0}, "ActorByInternalName", ["ball"]}

    assert Ref.lookup_op({:parm, "bend"}, {:result, 2}, :figure) ==
             {:invoke, {:result, 2}, "InternalParameter", ["bend"]}
  end

  test "unwrap!/1" do
    assert Ref.unwrap!({:ok, 5}) == 5
    err = %ExPoser.Error{kind: :timeout}
    assert_raise ExPoser.Error, fn -> Ref.unwrap!({:error, err}) end
  end
end

defmodule ExPoser.RefChildrenManyTest do
  use ExUnit.Case, async: false

  import PoserTest.ClientCase

  alias ExPoser.{Client, Ref, Scene}

  setup do
    server = start_standalone()
    c = start_client(server.session)
    %{c: c, light1: Scene.light!("Key", server: c), light2: Scene.light!("light 2", server: c)}
  end

  defp assert_no_handles(c), do: assert({:ok, %{"handles" => 0}} = Client.stats(server: c))

  test "children_many reads the children of every parent", %{c: c, light1: l1, light2: l2} do
    assert {:ok, [rows1, rows2]} = Ref.children_many([l1, l2], "Parameters", [], server: c)
    assert length(rows1) == 5
    assert length(rows2) == 5
    assert Enum.all?(rows1 ++ rows2, &Map.has_key?(&1, "InternalName"))

    assert Enum.map(rows1, & &1["InternalName"]) == [
             "xtran",
             "kdred",
             "kdgreen",
             "kdblue",
             "kdintensity"
           ]

    assert_no_handles(c)
  end

  test "the result order follows the parents", %{c: c} do
    [fig1, fig2] = Scene.figures!(server: c)
    assert {:ok, [rows1, rows2]} = Ref.children_many([fig1, fig2], "Actors", [], server: c)
    assert {length(rows1), length(rows2)} == {3, 1}

    assert {:ok, [swapped2, swapped1]} = Ref.children_many([fig2, fig1], "Actors", [], server: c)
    assert swapped1 == rows1
    assert swapped2 == rows2
    assert_no_handles(c)
  end

  test "a failed child read releases every handle", %{c: c, light1: l1, light2: l2} do
    assert {:error, %ExPoser.Error{}} =
             Ref.children_many([l1, l2], "Parameters", ["NoSuchMethod"], server: c)

    assert_no_handles(c)
  end

  test "children_many of no parents is {:ok, []}", %{c: c} do
    assert {:ok, []} = Ref.children_many([], "Parameters", [], server: c)
    assert_no_handles(c)
  end

  test "children/4 still returns one flat list", %{c: c, light1: l1} do
    assert {:ok, rows} = Ref.children(l1, "Parameters", ["Value"], server: c)
    assert length(rows) == 5
    assert %{"InternalName" => _, "Name" => _, "Value" => _} = hd(rows)
    assert_no_handles(c)
  end
end
