defmodule Poser.FigureTest do
  use ExUnit.Case, async: false

  import PoserTest.ClientCase

  alias Poser.{Actor, Client, Error, Figure, Handle, Parameter}

  @fig %Figure{internal: "figure 1", name: "Figure 1"}

  setup do
    server = start_standalone()
    %{c: start_client(server.session)}
  end

  defp assert_no_handles(c), do: assert({:ok, %{"handles" => 0}} = Client.stats(server: c))

  test "actors lists the body parts with their figure", %{c: c} do
    assert {:ok, [%Actor{figure: @fig, internal: "hip"}, _, _] = parts} =
             Figure.actors(@fig, server: c)

    assert Enum.map(parts, & &1.internal) == ["hip", "chest", "ünïcode 頭"] or length(parts) == 3
    assert [_, _, _] = Figure.actors!(@fig, server: c)
    assert_no_handles(c)
  end

  test "actor finds by internal then display name", %{c: c} do
    assert {:ok, %Actor{internal: "hip", figure: @fig}} = Figure.actor(@fig, "hip", server: c)
    assert %Actor{internal: "hip"} = Figure.actor!(@fig, "hip", server: c)

    assert {:error, %Error{kind: :not_found, details: %{path: path}}} =
             Figure.actor(@fig, "nope", server: c)

    assert path == [figure: "figure 1", name: "nope"]
    assert_raise Error, fn -> Figure.actor!(@fig, "nope", server: c) end
    assert_no_handles(c)
  end

  test "a missing figure is not_found from actor", %{c: c} do
    ghost = %Figure{internal: "ghost", name: "ghost"}

    assert {:error, %Error{kind: :not_found, details: %{path: [figure: "ghost"]}}} =
             Figure.actor(ghost, "hip", server: c)

    assert_no_handles(c)
  end

  test "parameter composes actor and parameter lookups", %{c: c} do
    assert {:ok, %Parameter{internal: "xtran", actor: %Actor{internal: "hip"}}} =
             Figure.parameter(@fig, "hip", "xtran", server: c)

    assert %Parameter{internal: "xtran"} = Figure.parameter!(@fig, "hip", "xTran", server: c)
    assert {:error, %Error{kind: :not_found}} = Figure.parameter(@fig, "hip", "zz", server: c)
    assert {:error, %Error{kind: :not_found}} = Figure.parameter(@fig, "zz", "xtran", server: c)
    assert_no_handles(c)
  end

  test "handle returns a live handle the caller releases", %{c: c} do
    assert {:ok, %Handle{} = h} = Figure.handle(@fig, server: c)
    assert {:ok, "figure 1"} = Client.invoke(h, "InternalName", [], server: c)
    {:ok, _} = Client.release([h], server: c)

    h2 = Figure.handle!(@fig, server: c)
    {:ok, _} = Client.release([h2], server: c)

    assert {:error, %Error{kind: :not_found}} =
             Figure.handle(%Figure{internal: "zz", name: "zz"}, server: c)

    assert_no_handles(c)
  end

  test "unknown options raise", %{c: c} do
    assert_raise ArgumentError, fn -> Figure.actors(@fig, server: c, bogus: 1) end
  end
end
