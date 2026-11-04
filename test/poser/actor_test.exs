defmodule Poser.ActorTest do
  use ExUnit.Case, async: false

  import PoserTest.ClientCase

  alias Poser.{Actor, Client, Error, Figure, Handle, Parameter, Ref}

  @fig %Figure{internal: "figure 1", name: "Figure 1"}
  @hip %Actor{figure: @fig, internal: "hip", name: "hip"}
  @uni %Actor{figure: @fig, internal: "ünïcode 頭", name: "Ünïcode 頭"}
  @ball %Actor{figure: nil, internal: "ball", name: "Ball"}

  setup do
    server = start_standalone()
    %{c: start_client(server.session)}
  end

  defp assert_no_handles(c), do: assert({:ok, %{"handles" => 0}} = Client.stats(server: c))

  test "parameters lists every parm with its actor", %{c: c} do
    assert {:ok, [%Parameter{} = x, %Parameter{} = w]} = Actor.parameters(@hip, server: c)
    assert {x.internal, x.name, x.actor} == {"xtran", "xTran", @hip}
    assert {w.internal, w.name, w.actor} == {"weird", "Weird", @hip}
    assert [_, _] = Actor.parameters!(@hip, server: c)
    assert_no_handles(c)
  end

  test "parameter finds by internal name, then by display name", %{c: c} do
    assert {:ok, %Parameter{internal: "xtran", name: "xTran", actor: @hip}} =
             Actor.parameter(@hip, "xtran", server: c)

    assert {:ok, %Parameter{internal: "xtran", name: "xTran"}} =
             Actor.parameter(@hip, "xTran", server: c)

    assert %Parameter{internal: "weird"} = Actor.parameter!(@hip, "Weird", server: c)
    assert_no_handles(c)
  end

  test "a missing parameter is not_found", %{c: c} do
    assert {:error, %Error{kind: :not_found, details: %{path: path}}} =
             Actor.parameter(@hip, "nope", server: c)

    assert List.last(path) == {:name, "nope"}
    assert_raise Error, fn -> Actor.parameter!(@hip, "nope", server: c) end
    assert_no_handles(c)
  end

  test "a missing actor is not_found from parameter", %{c: c} do
    ghost = %Actor{figure: @fig, internal: "ghost", name: "ghost"}

    assert {:error, %Error{kind: :not_found, details: %{path: path}}} =
             Actor.parameter(ghost, "xtran", server: c)

    assert path == [figure: "figure 1", actor: "ghost"]
    assert_no_handles(c)
  end

  test "get and set round trip", %{c: c} do
    assert {:ok, +0.0} = Actor.get(@hip, "xtran", server: c)
    assert {:ok, :ok} = Actor.set(@hip, "xtran", 2.5, server: c)
    assert {:ok, 2.5} = Actor.get(@hip, "xtran", server: c)
    assert :ok = Actor.set!(@hip, "xtran", 3, server: c)
    assert Actor.get!(@hip, "xtran", server: c) === 3.0
    assert_no_handles(c)
  end

  test "every function rejects unknown opts alike", %{c: c} do
    assert_raise ArgumentError, fn -> Actor.get(@hip, "xtran", bogus: 1, server: c) end
    assert_raise ArgumentError, fn -> Actor.parameters(@hip, bogus: 1, server: c) end
    assert_raise ArgumentError, fn -> Actor.parameter(@hip, "xTran", chunk: 1, server: c) end
    assert_raise ArgumentError, fn -> Actor.parameter(@hip, "nope", frame: 1, server: c) end
    assert_raise ArgumentError, fn -> Actor.values(@hip, bogus: 1, server: c) end
    assert_raise ArgumentError, fn -> Actor.handle(@hip, bogus: 1, server: c) end
    assert_no_handles(c)
  end

  test "to_handle maps a nil lookup to not_found and passes errors through" do
    assert {:error,
            %Error{kind: :not_found, details: %{path: [figure: "figure 1", actor: "hip"]}}} =
             Actor.to_handle({:ok, ["hip", nil]}, @hip)

    err = %Error{kind: :timeout}
    assert {:error, ^err} = Actor.to_handle({:error, err}, @hip)
  end

  test "get of a missing parm is not_found", %{c: c} do
    assert {:error, %Error{kind: :not_found}} = Actor.get(@hip, "nope", server: c)
    assert_no_handles(c)
  end

  test "set with a map is one batch", %{c: c} do
    :erlang.trace(Process.whereis(c), true, [:receive])
    assert {:ok, :ok} = Actor.set(@hip, %{"xtran" => 1.5, "weird" => 2}, server: c)
    :erlang.trace(Process.whereis(c), false, [:receive])
    assert length(batch_requests([])) == 1
    assert {:ok, 1.5} = Actor.get(@hip, "xtran", server: c)
    assert {:ok, 2.0} = Actor.get(@hip, "weird", server: c)
    assert :ok = Actor.set!(@hip, %{"xtran" => +0.0}, server: c)
    assert_no_handles(c)
  end

  defp batch_requests(acc) do
    receive do
      {:trace, _, :receive, {:"$gen_call", _, {:request, {:batch, _}, _}}} ->
        batch_requests([:batch | acc])

      {:trace, _, :receive, _} ->
        batch_requests(acc)
    after
      0 -> acc
    end
  end

  test "values", %{c: c} do
    assert {:ok, %{"xtran" => +0.0, "weird" => :nan}} = Actor.values(@hip, server: c)
    assert %{"xtran" => +0.0} = Actor.values!(@hip, server: c)
    assert_no_handles(c)
  end

  test "the unicode actor inspects and resolves", %{c: c} do
    assert inspect(@uni) == "#Poser.Actor<figure 1/ünïcode 頭>"
    assert {:ok, %Parameter{actor: @uni}} = Actor.parameter(@uni, "xTran", server: c)
    assert {:ok, +0.0} = Actor.get(@uni, "xtran", server: c)
    assert {:ok, %{"xtran" => +0.0}} = Actor.values(@uni, server: c)
    assert_no_handles(c)
  end

  test "a prop resolves without a figure", %{c: c} do
    assert {:ok, %{"xtran" => +0.0}} = Actor.values(@ball, server: c)
    assert_no_handles(c)
  end

  test "handle/2 leaves one handle for the caller", %{c: c} do
    assert {:ok, %Handle{} = h} = Actor.handle(@hip, server: c)
    assert {:ok, %{"handles" => 1}} = Client.stats(server: c)
    assert {:ok, "hip"} = Client.invoke(h, "Name", [], server: c)
    {:ok, _} = Client.release([h], server: c)
    assert_no_handles(c)
    assert %Handle{} = h2 = Actor.handle!(@hip, server: c)
    {:ok, _} = Client.release([h2], server: c)

    assert {:error, %Error{kind: :not_found, details: %{index: nil}}} =
             Actor.handle(%{@hip | internal: "zz"}, server: c)

    assert_no_handles(c)
  end

  test "Ref.find reports ambiguity with the matching structs", %{c: c} do
    build = fn m -> %Actor{figure: nil, internal: m["InternalName"], name: m["Name"]} end

    # two figures are both named "Figure 1"
    assert {:error, %Error{kind: :ambiguous, details: %{matches: [_, _]}}} =
             Ref.find(:scene, "Figures", "Figure 1", build, server: c)

    assert {:error, %Error{kind: :not_found}} =
             Ref.find(:scene, "Figures", "figure 2", build, server: c)

    assert_no_handles(c)
  end

  test "Ref.children errors release every handle", %{c: c} do
    assert {:error, %Error{}} = Ref.children(@hip, "NoSuchMethod", [], server: c)
    assert {:error, %Error{}} = Ref.children(@hip, "Parameters", ["NoSuchMethod"], server: c)
    assert_no_handles(c)
  end
end
