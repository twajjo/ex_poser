defmodule Poser.LivePoserTest do
  @moduledoc """
  Runs against a real Poser with the add-on deployed and a scene with a figure
  loaded. Excluded by default; run with `mix test --only poser`.
  """
  use ExUnit.Case, async: false

  import PoserTest.ClientCase

  alias Poser.{Client, Handle}

  @moduletag :poser

  setup do
    %{c: start_client(Poser.Session.default_path())}
  end

  test "scene, frames and figures", %{c: c} do
    assert {:ok, %Handle{class: "SceneType"} = scene} = Client.call("Scene", [], server: c)
    assert {:ok, n} = Client.invoke(scene, "NumFrames", [], server: c)
    assert is_integer(n) and n > 0

    assert {:ok, [%Handle{class: "FigureType", label: label} | _]} =
             Client.invoke(scene, "Figures", [], server: c)

    assert is_binary(label)
  end

  test "batch", %{c: c} do
    assert {:ok, [%Handle{}, frame]} =
             Client.batch([{:call, "Scene", []}, {:invoke, {:result, 0}, "Frame", []}], server: c)

    assert is_integer(frame)
  end

  test "module function", %{c: c} do
    assert {:ok, version} = Client.call("AppVersion", [], server: c)
    assert is_binary(version)
  end

  test "handles are counted and released", %{c: c} do
    {:ok, scene} = Client.call("Scene", [], server: c)
    {:ok, figures} = Client.invoke(scene, "Figures", [], server: c)
    assert {:ok, %{"handles" => held}} = Client.stats(server: c)
    assert held > 0
    assert {:ok, _} = Client.release([scene | figures], server: c)
    assert {:ok, %{"handles" => 0}} = Client.stats(server: c)
  end

  test "ping answers quickly", %{c: c} do
    assert {:ok, us} = Client.ping(server: c)
    assert us < 50_000
  end
end
