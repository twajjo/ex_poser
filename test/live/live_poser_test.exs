defmodule Poser.LivePoserTest do
  @moduledoc """
  Runs against a real Poser with the add-on deployed and a scene with a figure
  loaded. Excluded by default; run with `mix test --only poser`.
  """
  use ExUnit.Case, async: false

  import PoserTest.ClientCase

  alias Poser.{Actor, Batch, Client, Error, Figure, Handle, Parameter, Scene}

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

  @tag timeout: 600_000
  test "every generated getter runs against the scene without protocol problems", %{c: c} do
    manifest = "priv/poser_api_manifest.json" |> File.read!() |> JSON.decode!()
    report = Poser.Smoke.run(manifest, server: c, per_class: 2)
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
    defp probe(c) do
      {:ok, [fig | _]} = Scene.figures(server: c)
      {:ok, body} = Figure.actor(fig, "BODY:1", server: c)
      {:ok, parm} = Actor.parameter(body, "yRotate", server: c)
      {fig, body, parm}
    end

    defp assert_no_handles(c), do: assert({:ok, %{"handles" => 0}} = Client.stats(server: c))

    # Sets a distinct value at frame 5 and returns what is needed to undo it.
    defp key_at_5(parm, c) do
      o = [server: c]
      {:ok, frame0} = Scene.frame(o)
      {:ok, keys0} = Parameter.keyframes(parm, o)
      {:ok, orig5} = Parameter.value_at(parm, 5, o)
      v = orig5 + 10.0
      {:ok, :ok} = Parameter.set_value(parm, v, [frame: 5] ++ o)
      %{frame0: frame0, keys0: keys0, orig5: orig5, v: v}
    end

    defp restore_5(parm, %{frame0: frame0, keys0: keys0, orig5: orig5}, c) do
      o = [server: c]
      {:ok, :ok} = Parameter.set_value(parm, orig5, [frame: 5] ++ o)
      if 5 not in keys0, do: {:ok, :ok} = Parameter.delete_keyframe(parm, 5, o)
      assert {:ok, ^keys0} = Parameter.keyframes(parm, o)
      assert {:ok, ^orig5} = Parameter.value_at(parm, 5, o)
      assert {:ok, ^frame0} = Scene.frame(o)
    end

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
      saved = key_at_5(parm, c)

      try do
        assert {:ok, keys} = Parameter.keyframes(parm, server: c)
        assert 5 in keys
        assert {:ok, v} = Parameter.value_at(parm, 5, server: c)
        assert v == saved.v
        assert {:ok, ^v} = Parameter.value(parm, frame: 5, server: c)
        assert {:ok, frame} = Scene.frame(server: c)
        assert frame == saved.frame0
      after
        restore_5(parm, saved, c)
      end

      assert_no_handles(c)
    end

    test "the value holds after the last key", %{c: c} do
      {_fig, _body, parm} = probe(c)
      saved = key_at_5(parm, c)

      try do
        {:ok, keys} = Parameter.keyframes(parm, server: c)
        {:ok, v3} = Parameter.value_at(parm, 3, server: c)

        IO.puts(
          "keys #{inspect(keys)}; value at 3 (between 0 and 5): #{v3}; key value #{saved.v}"
        )

        if List.last(keys) == 5 do
          for f <- [5, 8, 12] do
            assert {:ok, got} = Parameter.value_at(parm, f, server: c)
            assert got == saved.v, "frame #{f}: #{got} != #{saved.v}"
          end
        else
          IO.puts("last key is #{List.last(keys)}, not 5: hold not asserted")
        end
      after
        restore_5(parm, saved, c)
      end

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
      end

      assert_no_handles(c)
    end
  end
end
