defmodule Poser.RefTest do
  use ExUnit.Case, async: true

  alias Poser.{Actor, Figure, Parameter, Ref}

  doctest Poser.Figure
  doctest Poser.Actor
  doctest Poser.Parameter
  doctest Poser.Ref

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
    err = %Poser.Error{kind: :timeout}
    assert_raise Poser.Error, fn -> Ref.unwrap!({:error, err}) end
  end
end
