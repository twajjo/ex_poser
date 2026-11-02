defmodule Poser.SmokeTest do
  # Not async: events go through one global registry.
  use ExUnit.Case, async: false

  import PoserTest.ClientCase

  alias Poser.{Client, Smoke}

  setup do
    server = start_standalone()
    %{c: start_client(server.session), manifest: PoserTest.GenFixture.model().manifest}
  end

  test "getters are called and outcomes recorded", %{c: c, manifest: m} do
    report = Smoke.run(m, server: c)
    g = report["getters"]

    assert %{"calls" => 1, "outcomes" => %{"ok" => 1}} = g["poser.Scene"]
    assert g["SceneType.Frame"]["outcomes"]["ok"] == 1
    assert g["SceneType.Frame"]["module"] == "PoserTest.GenApi.SceneType"
    assert g["SceneType.Frame"]["function"] == "frame"
    assert g["ActorType.BrokenGetter"]["outcomes"]["python"] == %{"RuntimeError" => 3}
    assert g["ActorType.Name"]["outcomes"]["ok"] == 3
    # plus 3 AttributeErrors: the fake ParmType lacks the InternalName the fixture declares
    assert report["summary"]["python"] == 6
    assert report["getters"]["ParmType.InternalName"]["outcomes"]["python"] == %{"AttributeError" => 3}
    assert report["summary"]["bad_request"] == 0
  end

  test "every handle is released afterwards", %{c: c, manifest: m} do
    Smoke.run(m, server: c)
    assert {:ok, %{"handles" => 0}} = Client.stats(server: c)
  end

  test "per_class bounds how many objects of a class are explored", %{c: c, manifest: m} do
    report = Smoke.run(m, server: c, per_class: 1)
    assert Enum.all?(report["explored"], fn {_class, n} -> n <= 1 end)
    assert report["explored"]["ActorType"] == 1
    assert report["getters"]["ActorType.Name"]["calls"] == 1
  end

  test "heavy getters are skipped unless asked for", %{c: c, manifest: m} do
    report = Smoke.run(m, server: c)
    assert report["getters"]["GeomType.Vertices"]["skipped"] =~ "one handle per element"
    assert report["getters"]["GeomType.Vertices"]["calls"] == 0

    report = Smoke.run(m, server: c, include_heavy: true)
    assert report["getters"]["GeomType.Vertices"]["outcomes"]["ok"] >= 1
    assert report["explored"]["VertexType"] >= 1
  end
end
