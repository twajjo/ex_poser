defmodule ExPoser.CameraTest do
  use ExUnit.Case, async: false

  import PoserTest.ClientCase

  alias ExPoser.{Actor, Batch, Call, Camera, Client, Figure, Light, Parameter, Ref, Scene}

  doctest ExPoser.Camera

  test "Ref.path/1 and ref?/1 treat a camera as its actor" do
    camera = %Camera{actor: %Actor{figure: nil, internal: "MAIN_CAMERA", name: "Main Camera"}}
    assert Ref.path(camera) == [actor: "MAIN_CAMERA"]
    assert Ref.ref?(camera)
  end

  setup do
    server = start_standalone()
    c = start_client(server.session)

    %{
      c: c,
      main: Scene.camera!("Main Camera", server: c),
      key: Scene.light!("Key", server: c)
    }
  end

  defp assert_no_handles(c), do: assert({:ok, %{"handles" => 0}} = Client.stats(server: c))

  defp target_internal(owner, c) do
    {:ok, handle} = Actor.handle(owner.actor, server: c)
    {:ok, target} = Call.method(handle, "PointAtTarget", [], [], server: c)
    internal = target && elem(Call.method(target, "InternalName", [], [], server: c), 1)
    Client.release([handle | List.wrap(target)], server: c)
    internal
  end

  test "set then get round trips a dial", %{c: c, main: main} do
    assert {:ok, :ok} = Camera.set(main, "focal", 50.0, server: c)
    assert {:ok, 50.0} = Camera.get(main, "focal", server: c)
    assert :ok = Camera.set!(main, %{"focal" => 60.0}, server: c)
    assert %{"focal" => 60.0} = Camera.get!(main, ["focal"], server: c)
    assert_no_handles(c)
  end

  test "a non-string key raises ArgumentError", %{c: c, main: main} do
    assert_raise ArgumentError, fn -> Camera.get(main, :on, server: c) end
    assert_raise ArgumentError, fn -> Camera.get(main, ["focal", :on], server: c) end
    assert_raise ArgumentError, fn -> Camera.set(main, :on, 1, server: c) end
    assert_raise ArgumentError, fn -> Camera.set(main, %{"focal" => 1, on: 1}, server: c) end
    assert {:ok, 55.0} = Camera.get(main, "focal", server: c)
    assert_no_handles(c)
  end

  test "set takes a map or a key and value, nothing else", %{main: main} do
    assert_raise FunctionClauseError, fn -> apply(Camera, :set, [main, "focal"]) end
    assert_raise FunctionClauseError, fn -> apply(Camera, :set, [main, "focal", [frame: 1]]) end
    assert_raise FunctionClauseError, fn -> apply(Camera, :set!, [main, "focal"]) end
  end

  test "point_at aims a camera at a light, then clears", %{c: c, main: main, key: key} do
    assert {:ok, :ok} = Camera.point_at(main, key, server: c)
    assert target_internal(main, c) == "light 1"
    assert :ok = Camera.point_at!(main, nil, server: c)
    assert target_internal(main, c) == nil
    assert_no_handles(c)
  end

  test "point_at rejects a non-ref target", %{c: c, main: main} do
    assert_raise ArgumentError, fn -> Camera.point_at(main, "hip", server: c) end
    assert_no_handles(c)
  end

  test "point_at rejects :frame and unknown options", %{c: c, main: main, key: key} do
    assert_raise ArgumentError, fn -> Camera.point_at(main, key, frame: 1, server: c) end
    assert_raise ArgumentError, fn -> Camera.point_at(main, key, foo: 1, server: c) end
    assert_raise ArgumentError, fn -> Light.point_at(key, main, frame: 1, server: c) end
    assert_raise ArgumentError, fn -> Light.point_at(key, main, foo: 1, server: c) end
    assert_no_handles(c)
  end

  test "get and set reject unknown options", %{c: c, main: main} do
    assert_raise ArgumentError, fn -> Camera.get(main, "focal", foo: 1, server: c) end
    assert_raise ArgumentError, fn -> Camera.set(main, "focal", 1.0, foo: 1, server: c) end
  end

  test "multi-key get and set", %{c: c, main: main} do
    assert {:ok, :ok} = Camera.set(main, %{"focal" => 40.0, "xtran" => 0.5}, server: c)

    assert {:ok, %{"focal" => 40.0, "xtran" => 0.5}} =
             Camera.get(main, ["focal", "xtran"], server: c)

    assert_no_handles(c)
  end

  test "get and set at a frame leave the scene frame alone", %{c: c, main: main} do
    assert {:ok, :ok} = Camera.set(main, "focal", 70.0, frame: 3, server: c)
    assert {:ok, 70.0} = Camera.get(main, "focal", frame: 3, server: c)
    assert Scene.frame!(server: c) == 0
    assert_no_handles(c)
  end

  test "point_at takes a figure or a parameter", %{c: c, main: main} do
    figure = %Figure{internal: "figure 1", name: "Andy"}
    hip = %Actor{figure: figure, internal: "hip", name: "Hip"}
    xrot = %Parameter{actor: hip, internal: "xrot", name: "xRotate"}
    assert {:ok, :ok} = Camera.point_at(main, figure, server: c)
    assert {:ok, :ok} = Camera.point_at(main, xrot, server: c)
    assert_no_handles(c)
  end

  test "point_at aims a light at an actor", %{c: c, key: key} do
    hip = %Actor{
      figure: %Figure{internal: "figure 1", name: "Andy"},
      internal: "hip",
      name: "Hip"
    }

    assert {:ok, :ok} = Light.point_at(key, hip, server: c)
    assert target_internal(key, c) == "hip"
    assert :ok = Light.point_at!(key, nil, server: c)
    assert_no_handles(c)
  end

  describe "snapshots" do
    test "snapshot reads the camera's name and every dial", %{c: c, main: main} do
      assert %Camera.Snapshot{name: "Main Camera", dials: dials} =
               Camera.snapshot!(main, server: c)

      assert dials == %{"focal" => 55.0, "xtran" => 0.0}
      assert_no_handles(c)
    end

    test "snapshot_all returns every camera in Scene.cameras order", %{c: c} do
      assert {:ok, snapshots} = Camera.snapshot_all(server: c)

      assert Enum.map(snapshots, & &1.name) ==
               Enum.map(Scene.cameras!(server: c), & &1.actor.name)

      assert length(snapshots) == 2
      assert_no_handles(c)
    end

    test "frame: reads dials at that frame and leaves the scene frame", %{c: c, main: main} do
      :ok = Camera.set!(main, "focal", 70.0, frame: 2, server: c)

      assert Camera.snapshot!(main, frame: 2, server: c).dials["focal"] == 70.0
      assert Scene.frame!(server: c) == 0
      assert Camera.snapshot!(main, frame: 0, server: c).dials["focal"] == 55.0
      assert Scene.frame!(server: c) == 0
      assert_no_handles(c)
    end

    test "request counts", %{c: c, main: main} do
      count = fn fun ->
        before = Client.request_count(server: c)
        fun.()
        Client.request_count(server: c) - before
      end

      # The fake can't add cameras, so there is no 2-vs-3 comparison here.
      # snapshot_all: 5 batches (cameras list (2), dial names via
      # children_many (2), the read (1)), each followed by a :release request.
      assert count.(fn -> Camera.snapshot_all!(server: c) end) == 10

      # snapshot: 3 batches (dial names (2), the read (1)), each followed by
      # a :release request.
      assert count.(fn -> Camera.snapshot!(main, server: c) end) == 6

      assert_no_handles(c)
    end

    test "an unknown option raises ArgumentError before any request", %{c: c, main: main} do
      before = Client.request_count(server: c)
      assert_raise ArgumentError, fn -> Camera.snapshot(main, bad: 1, server: c) end
      assert_raise ArgumentError, fn -> Camera.snapshot_all(bad: 1, server: c) end
      assert Client.request_count(server: c) == before
      assert_no_handles(c)
    end

    test "the bang variants return the bare value", %{c: c, main: main} do
      assert %Camera.Snapshot{name: "Main Camera"} = Camera.snapshot!(main, server: c)
      assert [%Camera.Snapshot{}, %Camera.Snapshot{}] = Camera.snapshot_all!(server: c)
      assert_no_handles(c)
    end

    test "a missing camera gives an error and leaves no handles", %{c: c} do
      bogus = %Camera{actor: %Actor{figure: nil, internal: "NOPE", name: "Nope"}}
      before = Client.request_count(server: c)

      assert {:error, %ExPoser.Error{kind: :not_found, details: %{path: [actor: "NOPE"]}}} =
               Camera.snapshot(bogus, server: c)

      # The dial-name lookup fails in its first batch: 1 batch + 1 :release.
      assert Client.request_count(server: c) - before == 2
      assert_raise ExPoser.Error, fn -> Camera.snapshot!(bogus, server: c) end
      assert_no_handles(c)
    end
  end

  describe "apply" do
    test "round trips: changed dials come back", %{c: c, main: main} do
      s = Camera.snapshot_all!(server: c)
      :ok = Camera.set!(main, %{"focal" => 90.0, "xtran" => 3.0}, server: c)
      refute Camera.snapshot_all!(server: c) == s

      assert %{skipped: []} = Camera.apply!(s, server: c)
      assert Camera.snapshot_all!(server: c) == s
      assert_no_handles(c)
    end

    test "is idempotent", %{c: c} do
      s = Camera.snapshot_all!(server: c)
      assert {:ok, %{skipped: []}} = Camera.apply(s, server: c)
      assert {:ok, %{skipped: []}} = Camera.apply(s, server: c)
      assert Camera.snapshot_all!(server: c) == s
      assert_no_handles(c)
    end

    test "takes one snapshot as well as a list", %{c: c, main: main} do
      snap = Camera.snapshot!(main, server: c)
      :ok = Camera.set!(main, "focal", 80.0, server: c)
      assert {:ok, %{skipped: []}} = Camera.apply(snap, server: c)
      assert Camera.get!(main, "focal", server: c) == 55.0
      assert_no_handles(c)
    end

    test "a missing camera is :not_found and changes nothing", %{c: c} do
      s = Camera.snapshot_all!(server: c)
      nope = %Camera.Snapshot{name: "Nope", dials: %{"focal" => 1.0}}
      valid = %{hd(s) | dials: %{"focal" => 99.0}}

      assert {:error, %ExPoser.Error{kind: :not_found, details: %{path: [name: "Nope"]}}} =
               Camera.apply([nope], server: c)

      assert {:error, %ExPoser.Error{kind: :not_found}} = Camera.apply([valid, nope], server: c)
      assert Camera.snapshot_all!(server: c) == s
      assert_raise ExPoser.Error, fn -> Camera.apply!([nope], server: c) end
      assert_no_handles(c)
    end

    test "a name shared by two cameras is :ambiguous and changes nothing", %{c: c} do
      aux = Scene.camera!("Aux Camera", server: c)

      {:ok, _} =
        Batch.new()
        |> Batch.call(aux, "SetName", ["Main Camera"])
        |> Batch.run(server: c)

      before = Camera.snapshot_all!(server: c)
      snap = %Camera.Snapshot{name: "Main Camera", dials: %{"focal" => 99.0}}

      assert {:error, %ExPoser.Error{kind: :ambiguous, details: %{matches: [_, _]}}} =
               Camera.apply(snap, server: c)

      assert Camera.snapshot_all!(server: c) == before
      assert_no_handles(c)
    end

    test "a dial the camera lacks is skipped, the rest is written", %{c: c, main: main} do
      snap = %Camera.Snapshot{
        name: "Main Camera",
        dials: %{"focal" => 70.0, "nodial" => 1.0, "alsono" => 2.0}
      }

      assert {:ok, %{skipped: [{"Main Camera", "alsono"}, {"Main Camera", "nodial"}]}} =
               Camera.apply(snap, server: c)

      assert Camera.get!(main, "focal", server: c) == 70.0
      assert_no_handles(c)
    end

    test "frame: sets the dials at that frame and leaves the scene frame", %{c: c, main: main} do
      snap = %Camera.Snapshot{name: "Main Camera", dials: %{"focal" => 77.0}}

      assert {:ok, %{skipped: []}} = Camera.apply(snap, frame: 3, server: c)
      assert Camera.get!(main, "focal", frame: 3, server: c) == 77.0
      assert Camera.get!(main, "focal", frame: 0, server: c) == 55.0
      assert Scene.frame!(server: c) == 0
      assert_no_handles(c)
    end

    test "bad input raises ArgumentError before any request", %{c: c, main: main} do
      good = Camera.snapshot!(main, server: c)
      before = Client.request_count(server: c)

      bad_inputs = [
        [:not_a_snapshot],
        [%{good | name: :main}],
        [%{good | dials: %{focal: 1.0}}],
        [%{good | dials: %{"focal" => "x"}}],
        [good, good]
      ]

      for input <- bad_inputs do
        assert_raise ArgumentError, fn -> Camera.apply(input, server: c) end
      end

      assert_raise ArgumentError, fn -> Camera.apply([good], bad: 1, server: c) end
      assert_raise ArgumentError, fn -> Camera.apply([good], mode: :merge, server: c) end

      for frame <- [-1, 1.5] do
        assert_raise ArgumentError, fn -> Camera.apply([good], frame: frame, server: c) end
        assert_raise ArgumentError, fn -> Camera.snapshot(main, frame: frame, server: c) end
        assert_raise ArgumentError, fn -> Camera.snapshot_all(frame: frame, server: c) end
      end

      assert Client.request_count(server: c) == before
      assert_no_handles(c)
    end

    test "request counts", %{c: c} do
      count = fn fun ->
        before = Client.request_count(server: c)
        fun.()
        Client.request_count(server: c) - before
      end

      [one, two] = Camera.snapshot_all!(server: c)

      # 5 batches, each followed by a :release request: the cameras list (2),
      # the dial names via children_many (2), the write (1).
      assert count.(fn -> Camera.apply!([one], server: c) end) == 10
      assert count.(fn -> Camera.apply!([one, two], server: c) end) == 10

      # An empty list sends nothing.
      assert count.(fn -> Camera.apply!([], server: c) end) == 0
      assert_no_handles(c)
    end
  end
end
