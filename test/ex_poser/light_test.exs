defmodule ExPoser.LightTest do
  use ExUnit.Case, async: true

  alias ExPoser.{Actor, Light, Ref}

  doctest ExPoser.Light

  test "Ref.path/1 and ref?/1 treat a light as its actor" do
    light = %Light{actor: %Actor{figure: nil, internal: "light 1", name: "Key"}}
    assert Ref.path(light) == [actor: "light 1"]
    assert Ref.ref?(light)
  end
end
