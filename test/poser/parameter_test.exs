defmodule Poser.ParameterTest do
  use ExUnit.Case, async: false

  import PoserTest.ClientCase

  alias Poser.{Actor, Client, Error, Figure, Handle, Parameter}

  @fig %Figure{internal: "figure 1", name: "Figure 1"}
  @hip %Actor{figure: @fig, internal: "hip", name: "hip"}
  @p %Parameter{actor: @hip, internal: "xtran", name: "xTran"}
  @missing %Parameter{actor: @hip, internal: "nope", name: "nope"}

  setup do
    server = start_standalone()
    %{c: start_client(server.session)}
  end

  defp assert_no_handles(c), do: assert({:ok, %{"handles" => 0}} = Client.stats(server: c))

  defp current_frame(c) do
    {:ok, [scene, f]} =
      Client.batch([{:call, "Scene", []}, {:invoke, {:result, 0}, "Frame", []}], server: c)

    {:ok, _} = Client.release([scene], server: c)
    f
  end

  test "value round trip, integers read back as floats", %{c: c} do
    assert {:ok, :ok} = Parameter.set_value(@p, 2.5, server: c)
    assert {:ok, 2.5} = Parameter.value(@p, server: c)
    assert :ok = Parameter.set_value!(@p, 3, server: c)
    assert Parameter.value!(@p, server: c) === 3.0
    assert_no_handles(c)
  end

  test "value_at and set_value at a frame do not move the frame", %{c: c} do
    before = current_frame(c)
    assert {:ok, :ok} = Parameter.set_value(@p, 9, frame: 4, server: c)
    assert {:ok, 9.0} = Parameter.value_at(@p, 4, server: c)
    assert Parameter.value_at!(@p, 4, server: c) === 9.0
    assert current_frame(c) == before
    assert_no_handles(c)
  end

  test "min_max", %{c: c} do
    assert {:ok, {-180.0, 180.0}} = Parameter.min_max(@p, server: c)
    assert {-180.0, 180.0} = Parameter.min_max!(@p, server: c)
    assert_no_handles(c)
  end

  test "keyframes", %{c: c} do
    before = current_frame(c)
    assert {:ok, :ok} = Parameter.add_keyframe(@p, 3, server: c)
    assert :ok = Parameter.add_keyframe!(@p, 7, server: c)
    assert {:ok, [0, 3, 7]} = Parameter.keyframes(@p, server: c)
    assert {:ok, :ok} = Parameter.delete_keyframe(@p, 3, server: c)
    assert [0, 7] = Parameter.keyframes!(@p, server: c)
    assert :ok = Parameter.delete_keyframe!(@p, 7, server: c)
    assert current_frame(c) == before
    assert_no_handles(c)
  end

  test "a key at frame 0 is listed", %{c: c} do
    assert {:ok, [0]} = Parameter.keyframes(@p, server: c)
  end

  test "handle/2 leaves one handle for the caller", %{c: c} do
    assert {:ok, %Handle{} = h} = Parameter.handle(@p, server: c)
    assert {:ok, %{"handles" => 1}} = Client.stats(server: c)
    assert {:ok, _} = Client.release([h], server: c)
    assert_no_handles(c)
    assert %Handle{} = h2 = Parameter.handle!(@p, server: c)
    {:ok, _} = Client.release([h2], server: c)
    assert_no_handles(c)
  end

  test "a missing parm is not_found", %{c: c} do
    assert {:error, %Error{kind: :not_found, details: %{path: path}}} =
             Parameter.value(@missing, server: c)

    assert path == Poser.Ref.path(@missing)

    assert {:error, %Error{kind: :not_found, details: %{index: nil}}} =
             Parameter.handle(@missing, server: c)

    gone = %{@missing | actor: %{@missing.actor | internal: "zz"}}

    assert {:error, %Error{kind: :not_found, details: %{index: nil}}} =
             Parameter.handle(gone, server: c)

    assert {:error, %Error{kind: :not_found}} = Parameter.keyframes(@missing, server: c)
    assert_raise Error, fn -> Parameter.value!(@missing, server: c) end
    assert_raise Error, fn -> Parameter.min_max!(@missing, server: c) end
    assert_no_handles(c)
  end
end
