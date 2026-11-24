defmodule ExPoser.LivePoserTest do
  @moduledoc """
  Runs against a real Poser with the add-on deployed and a scene with a figure
  loaded. Excluded by default; run with `mix test --only poser`.
  """
  use ExUnit.Case, async: false

  import PoserTest.ClientCase

  alias ExPoser.{Actor, Api.MaterialType, Batch, Camera, Client, Error, Figure, Handle, Light}
  alias ExPoser.{Material, Parameter, Scene, ShaderInput, ShaderNode, ShaderTree}

  @moduletag :poser

  setup do
    %{c: start_client(ExPoser.Session.default_path())}
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

  @tag timeout: 600_000
  test "every generated getter runs against the scene without protocol problems", %{c: c} do
    manifest = "priv/poser_api_manifest.json" |> File.read!() |> JSON.decode!()
    report = ExPoser.Smoke.run(manifest, server: c, per_class: 2)
    s = report["summary"]

    problems =
      for {key, e} <- report["getters"],
          Enum.any?(~w(bad_request stale_handle other), &Map.has_key?(e["outcomes"], &1)),
          do: {key, e["outcomes"]}

    assert problems == []
    assert s["getters_ok"] >= 300, inspect(s)
    assert {:ok, %{"handles" => 0}} = Client.stats(server: c)
  end

  describe "idiomatic layer" do
    test "figures are listed and Actor.values works on the first body part", %{c: c} do
      assert {:ok, [fig | _]} = Scene.figures(server: c)
      assert {:ok, [part | _]} = Figure.actors(fig, server: c)
      assert {:ok, values} = Actor.values(part, server: c)
      assert map_size(values) > 0
      assert Enum.all?(Map.values(values), &(is_float(&1) or is_atom(&1)))
      assert_no_handles(c)
    end

    test "set_value at frame 5 reads back and is restored", %{c: c} do
      {_fig, _body, parm} = probe(c)

      with_key_at_5(parm, c, fn saved ->
        assert {:ok, keys} = Parameter.keyframes(parm, server: c)
        assert 5 in keys
        assert {:ok, v} = Parameter.value_at(parm, 5, server: c)
        assert_in_delta v, saved.v, 1.0e-6
        assert {:ok, v2} = Parameter.value(parm, frame: 5, server: c)
        assert_in_delta v2, saved.v, 1.0e-6
        assert {:ok, frame} = Scene.frame(server: c)
        assert frame == saved.frame0
      end)

      assert_no_handles(c)
    end

    test "the value holds after the last key", %{c: c} do
      {_fig, _body, parm} = probe(c)

      with_key_at_5(parm, c, fn saved ->
        {:ok, keys} = Parameter.keyframes(parm, server: c)
        {:ok, v3} = Parameter.value_at(parm, 3, server: c)

        IO.puts(
          "keys #{inspect(keys)}; value at 3 (between 0 and 5): #{v3}; key value #{saved.v}"
        )

        if List.last(keys) == 5 do
          for f <- [5, 8, 12] do
            assert {:ok, got} = Parameter.value_at(parm, f, server: c)
            assert_in_delta got, saved.v, 1.0e-6, "frame #{f}: #{got} != #{saved.v}"
          end
        else
          IO.puts("last key is #{List.last(keys)}, not 5: hold not asserted")
        end
      end)

      assert_no_handles(c)
    end

    @tag timeout: 300_000
    test "a 2000-op batch finishes", %{c: c} do
      {:ok, figs} = Scene.figures(server: c)

      parms =
        figs
        |> Stream.flat_map(fn fig -> elem(Figure.actors(fig, server: c), 1) end)
        |> Stream.flat_map(fn a -> elem(Actor.parameters(a, server: c), 1) end)
        |> Enum.take(2000)

      assert parms != []
      ops = parms |> Stream.cycle() |> Enum.take(2000)
      batch = Enum.reduce(ops, Batch.new(), &Batch.get(&2, &1))

      {us, result} = :timer.tc(fn -> Batch.run(batch, server: c, timeout: 120_000) end)
      assert {:ok, results} = result
      assert length(results) == 2000
      IO.puts("2000-op batch (#{length(parms)} distinct parms): #{div(us, 1000)} ms")

      {:ok, [fig | _]} = Scene.figures(server: c)
      {:ok, [part | _]} = Figure.actors(fig, server: c)
      {us, {:ok, vals}} = :timer.tc(fn -> Actor.values(part, server: c) end)
      IO.puts("Actor.values on #{part.internal}: #{map_size(vals)} dials, #{div(us, 1000)} ms")

      {us, {:ok, _}} = :timer.tc(fn -> Scene.frame(server: c) end)
      IO.puts("single op (Scene.frame): #{div(us, 1000)} ms")
      assert_no_handles(c)
    end

    test "a missing figure, actor and parameter give :not_found", %{c: c} do
      {fig, body, _parm} = probe(c)
      assert {:error, %Error{kind: :not_found}} = Scene.figure("NoSuchFigure_zz9", server: c)
      assert {:error, %Error{kind: :not_found}} = Figure.actor(fig, "NoSuchActor_zz9", server: c)

      assert {:error, %Error{kind: :not_found}} =
               Actor.parameter(body, "NoSuchParm_zz9", server: c)

      assert {:error, %Error{kind: :not_found}} = Scene.actor("NoSuchProp_zz9", server: c)
      assert_no_handles(c)
    end

    test "the docs' example names, observed", %{c: c} do
      {:ok, figs} = Scene.figures(server: c)

      found =
        Enum.find_value(figs, fn fig ->
          with {:ok, arm} <- Figure.actor(fig, "lForeArm:1", server: c),
               {:ok, %Actor{} = by_display} <- Figure.actor(fig, "Left Forearm", server: c) do
            {fig, arm, by_display}
          else
            _ -> nil
          end
        end)

      case found do
        nil ->
          IO.puts("no figure has both lForeArm:1 and Left Forearm; skipped")

        {fig, arm, by_display} ->
          bend = Actor.parameter(arm, "Bend", server: c)
          bend_lc = Actor.parameter(arm, "bend", server: c)

          IO.puts(
            "lForeArm:1 / Left Forearm on #{fig.name} (#{fig.internal}); same actor: " <>
              "#{by_display.internal == arm.internal}; Bend: #{inspect(match?({:ok, _}, bend))}; " <>
              "bend: #{inspect(match?({:ok, _}, bend_lc))}"
          )

          # The docs say "Twist" labels both xrot and twistx on a forearm.
          if match?({:ok, _}, Actor.parameter(arm, "twistx", server: c)) do
            assert {:error, %Error{kind: :ambiguous}} =
                     Actor.parameter(arm, "Twist", server: c)
          else
            IO.puts("lForeArm:1 has no twistx dial; \"Twist\" ambiguity not asserted")
          end
      end

      assert_no_handles(c)
    end
  end

  describe "lights and cameras" do
    test "a created light round trips through merge, and merge doesn't add it twice",
         %{c: c} do
      restoring_rig(c, fn ->
        before = length(Scene.lights!(server: c))
        light = Light.create!(%{name: "ExPoser Test", type: :point}, server: c)
        :ok = Light.set!(light, %{color: {0.2, 0.4, 1.0}, shadow_samples: 8}, server: c)
        snap = Light.snapshot!(light, server: c)

        assert %{skipped: []} = Light.apply!(snap, server: c)
        assert %{skipped: []} = Light.apply!(snap, server: c)
        assert length(Scene.lights!(server: c)) == before + 1
        assert Light.snapshot!(Scene.light!("ExPoser Test", server: c), server: c) == snap
      end)

      assert_no_handles(c)
    end

    test "replace leaves only the given light", %{c: c} do
      restoring_rig(c, fn ->
        key = hd(Scene.lights!(server: c))
        snap = %{Light.snapshot!(key, server: c) | name: "ExPoser Test"}

        assert %{skipped: []} = Light.apply!(snap, mode: :replace, server: c)
        assert Enum.map(Scene.lights!(server: c), & &1.actor.name) == ["ExPoser Test"]
      end)

      assert_no_handles(c)
    end

    test "the current camera switches and switches back", %{c: c} do
      restoring_rig(c, fn ->
        current = Scene.current_camera!(server: c)

        other =
          Enum.find(Scene.cameras!(server: c), &(&1.actor.internal != current.actor.internal))

        :ok = Scene.set_current_camera!(other, server: c)
        assert Scene.current_camera!(server: c).actor.internal == other.actor.internal
        :ok = Scene.set_current_camera!(current, server: c)
        assert Scene.current_camera!(server: c).actor.internal == current.actor.internal
      end)

      assert_no_handles(c)
    end

    test "snapshot and apply timings, colour dials and light intensity, observed",
         %{c: c} do
      restoring_rig(c, fn ->
        {us, snaps} = :timer.tc(fn -> Light.snapshot_all!(server: c) end)
        IO.puts("Light.snapshot_all (#{length(snaps)} lights): #{div(us, 1000)} ms")

        {us, _} = :timer.tc(fn -> Light.apply!(snaps, mode: :replace, server: c) end)
        IO.puts("Light.apply replace (#{length(snaps)} lights): #{div(us, 1000)} ms")

        {us, cams} = :timer.tc(fn -> Camera.snapshot_all!(server: c) end)
        IO.puts("Camera.snapshot_all (#{length(cams)} cameras): #{div(us, 1000)} ms")

        {us, _} = :timer.tc(fn -> Camera.apply!(cams, server: c) end)
        IO.puts("Camera.apply (#{length(cams)} cameras): #{div(us, 1000)} ms")

        light = hd(Scene.lights!(server: c))
        dials = Light.snapshot!(light, server: c).dials
        IO.puts("light dial internal names: #{inspect(Enum.sort(Map.keys(dials)))}")

        {:ok, handle} = Light.handle(light, server: c)
        {:ok, method} = ExPoser.Api.ActorType.get_light_intensity(handle, server: c)
        {:ok, _} = Client.release([handle], server: c)
        intensity = for {k, v} <- dials, k =~ ~r/intensity/i, do: {k, v}
        IO.puts("GetLightIntensity: #{inspect(method)}; intensity dials: #{inspect(intensity)}")
      end)

      assert_no_handles(c)
    end
  end

  describe "materials" do
    test "the first figure's materials are listed and looked up by name", %{c: c} do
      fig = hd(Scene.figures!(server: c))
      mats = Figure.materials!(fig, server: c)
      assert [_ | _] = mats
      assert Figure.material!(fig, hd(mats).name, server: c) == hd(mats)

      for m <- Enum.take(mats, 5), do: probe_1(fig, m, c)
      probe_2(hd(mats), c)

      assert_no_handles(c)
    end

    test "a flat colour is set, read back and restored", %{c: c} do
      m = hd(Figure.materials!(hd(Scene.figures!(server: c)), server: c))
      orig = Material.get!(m, :diffuse_color, server: c)

      new =
        if close?(orig, {0.1, 0.7, 0.3}), do: {0.9, 0.2, 0.5}, else: {0.1, 0.7, 0.3}

      try do
        :ok = Material.set!(m, :diffuse_color, new, server: c)
        assert close?(Material.get!(m, :diffuse_color, server: c), new)
      after
        Material.set!(m, :diffuse_color, orig, server: c)
      end

      assert close?(Material.get!(m, :diffuse_color, server: c), orig)
      assert_no_handles(c)
    end

    test "the first material's tree snapshots, observed", %{c: c} do
      m = hd(Figure.materials!(hd(Scene.figures!(server: c)), server: c))
      tree = Material.tree(m)

      {us, snap} = :timer.tc(fn -> ShaderTree.snapshot!(tree, server: c) end)
      IO.puts("ShaderTree.snapshot (#{length(snap.nodes)} nodes): #{div(us, 1000)} ms")
      IO.puts("node types: #{inspect(Enum.map(snap.nodes, & &1.type))}")
      IO.puts("roots: #{inspect(snap.roots)}")

      assert ShaderTree.snapshot!(tree, server: c) == snap
      assert_no_handles(c)
    end

    # The crash regression test for #83: the node is gone by the end of the
    # batch, so it checks only the result shapes and that the tree is restored.
    test "one batch creates an image_map, sets its source, links it and deletes it", %{c: c} do
      tree = Material.tree(hd(Figure.materials!(hd(Scene.figures!(server: c)), server: c)))

      before =
        restoring_tree(tree, c, fn snap ->
          input = chosen_input(tree, snap)
          path = image_path(snap)

          build = fn ->
            b = Batch.create_node(Batch.new(), tree, "image_map")
            node = Batch.created(b)

            b
            |> Batch.set_input(ShaderNode.input(node, "Image_Source"), path)
            |> Batch.link(ShaderNode.output(node, "Color"), input)
            |> Batch.delete_node(node)
          end

          names = Enum.map(ShaderTree.nodes!(tree, server: c), & &1.internal)
          IO.puts("probe 3: tree nodes before the run: #{inspect(names)}")

          assert {:ok, [%ShaderNode{} = made, :ok, :ok, :ok]} = Batch.run(build.(), server: c)

          IO.puts("probe 3: first run created internal=#{inspect(made.internal)}")
          IO.puts("probe 3: first run created name=#{inspect(made.name)}")

          assert {:ok, [%ShaderNode{} = again, :ok, :ok, :ok]} = Batch.run(build.(), server: c)
          IO.puts("probe 3: second run created internal=#{inspect(again.internal)}")
          IO.puts("probe 3: internal names equal: #{made.internal == again.internal}")
        end)

      assert ShaderTree.snapshot!(tree, server: c) == before
      assert_no_handles(c)
    end

    test "linking a node uses which output, observed", %{c: c} do
      tree = Material.tree(hd(Figure.materials!(hd(Scene.figures!(server: c)), server: c)))

      before =
        restoring_tree(tree, c, fn snap ->
          input = chosen_input(tree, snap)
          node = ShaderTree.create_node!(tree, "image_map", server: c)
          :ok = ShaderInput.link!(input, node, server: c)

          after_link = ShaderTree.snapshot!(tree, server: c)
          from = linked_from(after_link, input)
          outputs = after_link.nodes |> Enum.find(&(&1.internal == node.internal)) |> outputs_of()

          IO.puts("probe 4: input #{input.internal} from=#{inspect(from)}")
          IO.puts("probe 4: new node #{node.internal} outputs in order: #{inspect(outputs)}")

          :ok = ShaderNode.delete!(node, server: c)
        end)

      assert ShaderTree.snapshot!(tree, server: c) == before
      assert_no_handles(c)
    end
  end

  defp assert_no_handles(c), do: assert({:ok, %{"handles" => 0}} = Client.stats(server: c))

  # The first input of the root node, other than Diffuse_Color, that is
  # unlinked and has Diffuse_Color's type, so linking it leaves the usual
  # colour slot alone.
  defp chosen_input(tree, snap) do
    root = Enum.find(snap.nodes, &(&1.internal == snap.roots.preview))
    diffuse = Enum.find(root.inputs, &(&1.internal == "Diffuse_Color"))
    assert diffuse, "#{root.internal} has no Diffuse_Color input"

    chosen =
      Enum.find(root.inputs, fn i ->
        i.internal != "Diffuse_Color" and i.from == nil and i.type == diffuse.type
      end)

    assert chosen, "no unlinked input of type #{inspect(diffuse.type)} on #{root.internal}"
    IO.puts("chosen input: #{chosen.internal} on #{root.internal}")

    ShaderNode.input(
      %ShaderNode{tree: tree, internal: root.internal, name: root.name},
      chosen.internal
    )
  end

  defp close?({r1, g1, b1}, {r2, g2, b2}),
    do: abs(r1 - r2) < 1.0e-3 and abs(g1 - g2) < 1.0e-3 and abs(b1 - b2) < 1.0e-3

  # The Image_Source value of an existing node, so no path is guessed.
  defp image_path(snap) do
    sources =
      for n <- snap.nodes,
          i <- n.inputs,
          i.internal == "Image_Source",
          is_binary(i.value) and i.value != "",
          do: i.value

    assert [path | _] = sources, "no node in the tree has a non-empty Image_Source"
    IO.puts("image path: #{inspect(path)}")
    path
  end

  defp linked_from(snap, input) do
    node = Enum.find(snap.nodes, &(&1.internal == input.node.internal))
    Enum.find_value(node.inputs, &(&1.internal == input.internal && &1.from))
  end

  defp outputs_of(node_map), do: Enum.map(node_map.outputs, & &1.internal)

  defp probe(c) do
    {:ok, [fig | _]} = Scene.figures(server: c)
    {:ok, body} = Figure.actor(fig, "BODY:1", server: c)
    {:ok, parm} = Actor.parameter(body, "yRotate", server: c)
    {fig, body, parm}
  end

  defp probe_1(fig, m, c) do
    h = Material.handle!(m, server: c)

    try do
      {:ok, name} = MaterialType.name(h, server: c)
      {:ok, ext} = MaterialType.ext_name(h, server: c)

      found =
        case Figure.material(fig, ext, server: c) do
          {:ok, _} -> "ok"
          {:error, %Error{kind: k, message: msg}} -> "error #{inspect(k)} #{inspect(msg)}"
        end

      IO.puts(
        "probe 1: name=#{inspect(name)} ext_name=#{inspect(ext)} lookup by ext_name: #{found}"
      )
    after
      Client.release([h], server: c)
    end
  end

  defp probe_2(m, c) do
    h = Material.handle!(m, server: c)

    try do
      {:ok, n} = MaterialType.num_layers(h, server: c)

      if n == 0 do
        IO.puts("probe 2: no layers")
      else
        for i <- 0..(n - 1), do: probe_2_layer(h, i, c)
      end
    after
      Client.release([h], server: c)
    end
  end

  defp probe_2_layer(h, i, c) do
    {:ok, name} = MaterialType.layer_name(h, i, server: c)
    {:ok, ext} = MaterialType.layer_ext_name(h, i, server: c)

    found =
      case MaterialType.layer_by_name(h, ext, server: c) do
        {:ok, %Handle{} = lh} ->
          Client.release([lh], server: c)
          "handle"

        other ->
          "no handle (#{inspect(other)})"
      end

    IO.puts(
      "probe 2: layer #{i} name=#{inspect(name)} ext_name=#{inspect(ext)} by ext_name: #{found}"
    )
  end

  defp restore_5(parm, %{frame0: frame0, keys0: keys0, orig5: orig5}, c) do
    o = [server: c]

    step = fn name, fun ->
      try do
        case fun.() do
          {:error, _} = err -> [{name, err}]
          _ -> []
        end
      rescue
        e -> [{name, e}]
      catch
        kind, why -> [{name, {kind, why}}]
      end
    end

    check = fn name, got, want ->
      if got == want, do: [], else: [{name, {:expected, want, :got, got}}]
    end

    near = fn name, got, want ->
      case got do
        {:ok, g} when is_number(g) and abs(g - want) <= 1.0e-6 -> []
        other -> [{name, {:expected, want, :got, other}}]
      end
    end

    step.(:set_back, fn -> Parameter.set_value(parm, orig5, [frame: 5] ++ o) end) ++
      step.(:delete_key, fn ->
        if 5 in keys0, do: :ok, else: Parameter.delete_keyframe(parm, 5, o)
      end) ++
      step.(:frame, fn -> Scene.set_frame(frame0, o) end) ++
      step.(:check_keys, fn -> check.(:keys, Parameter.keyframes(parm, o), {:ok, keys0}) end) ++
      step.(:check_value, fn -> near.(:value, Parameter.value_at(parm, 5, o), orig5) end) ++
      step.(:check_frame, fn -> check.(:frame, Scene.frame(o), {:ok, frame0}) end)
  end

  # Runs `fun` and then puts the scene's lights and current camera back.
  # The restore is done here, not in on_exit, because the client is a
  # supervised child that is stopped before on_exit runs.
  defp restoring_rig(c, fun) do
    lights = Light.snapshot_all!(server: c)
    camera = Scene.current_camera!(server: c)

    try do
      fun.()
    after
      Light.apply!(lights, mode: :replace, server: c)
      Scene.set_current_camera!(camera, server: c)
    end
  end

  # Snapshots the tree, runs `fun` with the snapshot, then deletes every node
  # that wasn't in it. Returns the snapshot, for the caller to compare with.
  # A body failure is re-raised after the cleanup, so a cleanup failure (such
  # as a dead Poser) never hides it.
  defp restoring_tree(tree, c, fun) do
    snap = ShaderTree.snapshot!(tree, server: c)
    known = MapSet.new(snap.nodes, & &1.internal)

    body =
      try do
        fun.(snap)
        :ok
      catch
        kind, why -> {:raised, kind, why, __STACKTRACE__}
      end

    failures =
      try do
        case ShaderTree.nodes(tree, server: c) do
          {:ok, nodes} ->
            for node <- nodes,
                node.internal not in known,
                {:error, _} = err <- [ShaderNode.delete(node, server: c)],
                do: {node.internal, err}

          {:error, _} = err ->
            [{:nodes, err}]
        end
      catch
        kind, why -> [{:cleanup, {kind, why}}]
      end

    case body do
      {:raised, kind, why, st} ->
        if failures != [], do: IO.puts("cleanup also failed: #{inspect(failures)}")
        :erlang.raise(kind, why, st)

      :ok ->
        assert failures == [], "cleanup failed: #{inspect(failures)}"
    end

    snap
  end

  # Snapshots frame, keys and the value at 5, sets a distinct value at frame 5
  # inside the protected body, runs `fun` with the snapshot (plus `:v`), then
  # restores every step independently. A body failure is re-raised after the
  # restore, so a restore failure never hides it.
  defp with_key_at_5(parm, c, fun) do
    o = [server: c]
    {:ok, frame0} = Scene.frame(o)
    {:ok, keys0} = Parameter.keyframes(parm, o)
    {:ok, orig5} = Parameter.value_at(parm, 5, o)
    {:ok, {min, max}} = Parameter.min_max(parm, o)
    saved = %{frame0: frame0, keys0: keys0, orig5: orig5}

    body =
      try do
        v = if orig5 + 10.0 <= max, do: orig5 + 10.0, else: max(orig5 - 10.0, min)
        {:ok, :ok} = Parameter.set_value(parm, v, [frame: 5] ++ o)
        fun.(Map.put(saved, :v, v))
        :ok
      catch
        kind, why -> {:raised, kind, why, __STACKTRACE__}
      end

    failures = restore_5(parm, saved, c)

    case body do
      {:raised, kind, why, st} ->
        if failures != [], do: IO.puts("restore also failed: #{inspect(failures)}")
        :erlang.raise(kind, why, st)

      :ok ->
        assert failures == [], "restore failed: #{inspect(failures)}"
    end
  end
end
