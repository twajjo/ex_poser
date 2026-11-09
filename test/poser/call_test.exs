defmodule Poser.CallTest do
  use ExUnit.Case, async: false

  import PoserTest.ClientCase

  alias Poser.{Call, Error, Handle}

  describe "build_args/3" do
    @optional [a: :none, b: {:default, 0}]

    test "trailing omitted optionals are dropped" do
      assert Call.build_args([1], @optional, []) == {[1], []}
      assert Call.build_args([1], @optional, a: 2) == {[1, 2], []}
    end

    test "a gap is filled with the known default" do
      assert Call.build_args([], [a: {:default, 7}, b: :none], b: 5) == {[7, 5], []}
    end

    test "a gap without a known default raises naming the missing option" do
      assert_raise ArgumentError, ~r/:a/, fn -> Call.build_args([1], @optional, b: 5) end
    end

    test "unknown keys raise naming the key" do
      assert_raise ArgumentError, ~r/:c/, fn -> Call.build_args([1], @optional, c: 1) end
    end

    test "client options are split off" do
      assert Call.build_args([], @optional, a: 1, server: :s, timeout: 5) ==
               {[1], [server: :s, timeout: 5]}
    end
  end

  describe "against the standalone server" do
    setup do
      server = start_standalone()
      %{c: start_client(server.session)}
    end

    test "function and method", %{c: c} do
      assert {:ok, %Handle{class: "SceneType"} = scene} =
               Call.function("Scene", [], [], server: c)

      assert Call.method(scene, "SetFrame", [3], [], server: c) == {:ok, nil}
      assert Call.method(scene, "Frame", [], [], server: c) == {:ok, 3}

      assert {:error, %Error{kind: :python}} =
               Call.method(scene, "SetFrame", [], [n: :none], server: c, n: 99)
    end
  end
end
