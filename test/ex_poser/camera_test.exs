defmodule ExPoser.CameraTest do
  use ExUnit.Case, async: true

  alias ExPoser.{Actor, Camera, Ref}

  doctest ExPoser.Camera

  test "Ref.path/1 and ref?/1 treat a camera as its actor" do
    camera = %Camera{actor: %Actor{figure: nil, internal: "MAIN_CAMERA", name: "Main Camera"}}
    assert Ref.path(camera) == [actor: "MAIN_CAMERA"]
    assert Ref.ref?(camera)
  end
end
