defmodule ExPoser.BatchTest do
  use ExUnit.Case, async: false

  import PoserTest.ClientCase

  alias ExPoser.{
    Actor,
    Batch,
    Client,
    Error,
    Figure,
    Material,
    Parameter,
    ShaderInput,
    ShaderNode
  }

  alias ExPoser.Api.ActorType

  doctest ExPoser
  doctest ExPoser.Batch

  @fig %Figure{internal: "figure 1", name: "Figure 1"}
  @hip %Actor{figure: @fig, internal: "hip", name: "hip"}
  @chest %Actor{figure: @fig, internal: "chest", name: "chest"}
  @ball %Actor{figure: nil, internal: "ball", name: "Ball"}
  @p %Parameter{actor: @hip, internal: "xtran", name: "xTran"}
  @chest_p %Parameter{actor: @chest, internal: "xtran", name: "xTran"}
  @ball_p %Parameter{actor: @ball, internal: "xtran", name: "xTran"}
  @missing %Parameter{actor: @hip, internal: "nope", name: "nope"}

  @scene {:call, "Scene", []}
  @lookups [
    {:invoke, {:result, 0}, "FigureByInternalName", ["figure 1"]},
    {:invoke, {:result, 1}, "ActorByInternalName", ["hip"]},
    {:invoke, {:result, 2}, "InternalParameter", ["xtran"]}
  ]

  describe "compile/2" do
    test "shared lookups" do
      b = Enum.reduce(1..100, Batch.new(), &Batch.set(&2, @p, &1))
      assert Batch.size(b) == 100

      assert [{wire, roles}] = Batch.compile(b, chunk: 2000)
      assert length(wire) == 104
      assert Enum.take(wire, 4) == [@scene | @lookups]
      assert Enum.at(wire, 4) == {:invoke, {:result, 3}, "SetValue", [1.0]}
      assert Enum.count(wire, &match?({:invoke, {:result, 3}, "SetValue", [_]}, &1)) == 100

      assert roles[0] == {:lookup, [], 0}
      assert roles[3] == {:lookup, ExPoser.Ref.path(@p), 0}
      assert roles[103] == {:caller, 99}
    end

    test "a scene-level actor skips the figure step" do
      assert [{wire, _roles}] = Batch.new() |> Batch.get(@ball_p) |> Batch.compile(chunk: 10)

      assert wire == [
               @scene,
               {:invoke, {:result, 0}, "ActorByInternalName", ["ball"]},
               {:invoke, {:result, 1}, "InternalParameter", ["xtran"]},
               {:invoke, {:result, 2}, "Value", []}
             ]
    end

    test "frames: read once, set only on change, restore at the end" do
      b =
        Batch.new()
        |> Batch.set(@p, 1.0, frame: 5)
        |> Batch.get(@p, frame: 5)
        |> Batch.get(@p)

      assert [{wire, roles}] = Batch.compile(b, chunk: 2000)

      assert wire ==
               [@scene, {:invoke, {:result, 0}, "Frame", []}] ++
                 Enum.map(@lookups, fn {:invoke, {:result, n}, m, a} ->
                   {:invoke, {:result, if(n == 0, do: 0, else: n + 1)}, m, a}
                 end) ++
                 [
                   {:invoke, {:result, 0}, "SetFrame", [5]},
                   {:invoke, {:result, 4}, "SetValue", [1.0]},
                   {:invoke, {:result, 4}, "Value", []},
                   {:invoke, {:result, 0}, "SetFrame", [{:result, 1}]},
                   {:invoke, {:result, 4}, "Value", []},
                   {:invoke, {:result, 0}, "SetFrame", [{:result, 1}]}
                 ]

      assert roles[1] == {:frame, 0}
      assert roles[5] == {:frame, 0}
      assert roles[8] == {:frame, 2}
    end

    test "keyframe ops pass the frame as an argument and never move the frame" do
      b = Batch.new() |> Batch.add_keyframe(@p, 7) |> Batch.delete_keyframe(@p, 7)
      assert [{wire, _}] = Batch.compile(b, chunk: 2000)

      assert Enum.drop(wire, 4) == [
               {:invoke, {:result, 3}, "AddKeyFrame", [7]},
               {:invoke, {:result, 3}, "DeleteKeyFrame", [7]}
             ]
    end

    test "chunks never exceed the limit, each does its own lookups" do
      b = Enum.reduce(1..10, Batch.new(), &Batch.set(&2, @ball_p, &1))
      chunks = Batch.compile(b, chunk: 4)
      assert length(chunks) >= 3
      assert Enum.all?(chunks, fn {wire, _} -> length(wire) <= 4 end)
      assert Enum.all?(chunks, fn {[first | _], _} -> first == @scene end)
    end

    test "later chunks use the original frame as a literal placeholder" do
      b =
        Batch.new()
        |> Batch.set(@p, 1.0, frame: 5)
        |> Batch.get(@p)
        |> Batch.set(@p, 2.0, frame: 6)

      assert [{c1, _}, {c2, _}, {c3, _}] = Batch.compile(b, chunk: 7)
      assert Enum.at(c1, 1) == {:invoke, {:result, 0}, "Frame", []}
      refute Enum.member?(c2, {:invoke, {:result, 0}, "Frame", []})
      assert {:invoke, {:result, 0}, "SetFrame", [:original_frame]} in c2
      assert List.last(c3) == {:invoke, {:result, 0}, "SetFrame", [:original_frame]}
    end

    test "an op that cannot fit an empty chunk raises" do
      assert_raise ArgumentError, fn ->
        Batch.new() |> Batch.get(@p) |> Batch.compile(chunk: 4)
      end
    end
  end

  describe "compile/2 with UpdatePreview" do
    test "two set_input ops on one tree emit one UpdatePreview, last" do
      {tree, [i1, i2 | _]} = tree_inputs()

      b = Batch.new() |> Batch.set_input(i1, 1.0) |> Batch.set_input(i2, 2.0)
      assert [{wire, roles}] = Batch.compile(b, chunk: 2000)
      assert {:invoke, {:result, t}, "UpdatePreview", []} = List.last(wire)
      assert roles[t] == {:lookup, ExPoser.Ref.path(tree), 0}
      assert roles[length(wire) - 1] == {:preview, 1}
      assert Enum.count(wire, &match?({:invoke, _, "UpdatePreview", _}, &1)) == 1
    end

    test "ops on two trees emit two, in first-change order" do
      {_, [i1 | _]} = tree_inputs()
      other = %Material{owner: @hip, name: "Hair"} |> Material.tree()
      node = %ShaderNode{tree: other, internal: "Image_Map"}
      i2 = %ShaderInput{node: node, internal: "U_Offset"}

      b = Batch.new() |> Batch.set_input(i1, 1.0) |> Batch.set_input(i2, 1.0)
      assert [{wire, roles}] = Batch.compile(b, chunk: 2000)
      previews = Enum.filter(0..(length(wire) - 1), &match?({:preview, _}, roles[&1]))
      assert Enum.map(previews, &roles[&1]) == [{:preview, 0}, {:preview, 1}]
      assert Enum.take(wire, -2) == for(i <- previews, do: Enum.at(wire, i))
    end

    test "each chunk gets its own preview" do
      {_, [i1, i2 | _]} = tree_inputs()

      b =
        Enum.reduce(1..4, Batch.new(), fn n, b ->
          Batch.set_input(b, if(rem(n, 2) == 1, do: i1, else: i2), n)
        end)

      # 8 lookups (7 shared, 1 for the second input), 2 calls and 1 preview fill a chunk of exactly 11.
      chunks = Batch.compile(b, chunk: 11)
      assert length(chunks) == 2

      for {wire, _} <- chunks do
        assert length(wire) == 11
        assert Enum.count(wire, &match?({:invoke, _, "SetFloat", _}, &1)) == 2
        assert Enum.count(wire, &match?({:invoke, _, "UpdatePreview", _}, &1)) == 1
        assert match?({:invoke, _, "UpdatePreview", _}, List.last(wire))
      end
    end

    test "delete_node forgets the node's memo keys; other nodes stay memoized" do
      {tree, [i1, _]} = tree_inputs()
      other = %ShaderNode{tree: tree, internal: "Image_Map"}
      keep = %ShaderInput{node: other, internal: "U_Offset"}
      node = i1.node

      b =
        Batch.new()
        |> Batch.set_input(i1, 1.0)
        |> Batch.set_input(keep, 1.0)
        |> Batch.delete_node(node)
        |> Batch.set_input(i1, 2.0)
        |> Batch.set_input(keep, 2.0)

      assert [{wire, roles}] = Batch.compile(b, chunk: 2000)
      lookups = for {i, {:lookup, prefix, k}} <- roles, k >= 3, do: {i, prefix, k}
      # op 3 looks the deleted node and its input up again; op 4 reuses the other node's.
      got = lookups |> Enum.map(fn {_, prefix, k} -> {List.last(prefix), k} end) |> Enum.sort()
      assert got == [{{:input, "Diffuse_Value"}, 3}, {{:node, "PoserSurface"}, 3}]

      assert Enum.count(wire, &match?({:invoke, _, "Delete", []}, &1)) == 1
    end

    test "a batch without a delete compiles as before" do
      {_, [i1, i2]} = tree_inputs()
      b = Batch.new() |> Batch.set_input(i1, 1.0) |> Batch.set_input(i2, 2.0)
      assert [{wire, _}] = Batch.compile(b, chunk: 2000)

      assert wire == [
               {:call, "Scene", []},
               {:invoke, {:result, 0}, "FigureByInternalName", ["figure 1"]},
               {:invoke, {:result, 1}, "ActorByInternalName", ["hip"]},
               {:invoke, {:result, 2}, "Material", ["Skin"]},
               {:invoke, {:result, 3}, "ShaderTree", []},
               {:invoke, {:result, 4}, "NodeByInternalName", ["PoserSurface"]},
               {:invoke, {:result, 5}, "InputByInternalName", ["Diffuse_Value"]},
               {:invoke, {:result, 6}, "SetFloat", [1.0]},
               {:invoke, {:result, 5}, "InputByInternalName", ["Bump"]},
               {:invoke, {:result, 8}, "SetFloat", [2.0]},
               {:invoke, {:result, 4}, "UpdatePreview", []}
             ]
    end

    test "reads and flat ops emit no preview" do
      {tree, _} = tree_inputs()
      skin = %Material{owner: @hip, name: "Skin"}

      b =
        Batch.new()
        |> Batch.call(tree, "PreviewCount")
        |> Batch.set_material(skin, :ns, 1.0)

      assert [{wire, _}] = Batch.compile(b, chunk: 2000)
      refute Enum.any?(wire, &match?({:invoke, _, "UpdatePreview", _}, &1))
    end
  end

  describe "run/2 options" do
    test "an unknown option raises" do
      assert_raise ArgumentError, fn -> Batch.new() |> Batch.get(@p) |> Batch.run(chunks: 4) end
    end

    test "a chunk that isn't an integer raises" do
      assert_raise ArgumentError, ~r/positive integer/, fn ->
        Batch.new() |> Batch.get(@p) |> Batch.run(chunk: "x")
      end
    end

    test "a chunk of 0 raises, even for an empty batch" do
      assert_raise ArgumentError, ~r/positive integer/, fn -> Batch.run(Batch.new(), chunk: 0) end
    end
  end

  describe "run/2" do
    setup :connect

    test "an empty batch sends nothing", %{c: c} do
      assert Batch.run(Batch.new(), server: c) == {:ok, []}
    end

    test "get and set in one batch", %{c: c} do
      assert {:ok, [:ok, 5.0]} =
               ExPoser.batch(fn b -> b |> Batch.set(@p, 5) |> Batch.get(@p) end, server: c)

      assert_no_handles(c)
    end

    test "call/5 returns the value; its handles belong to the caller", %{c: c} do
      assert {:ok, [30, %ExPoser.Handle{} = fig]} =
               ExPoser.batch(
                 fn b ->
                   b
                   |> Batch.call(:scene, "NumFrames", [])
                   |> Batch.call(@fig, "ActorByInternalName", ["hip"])
                 end,
                 server: c
               )

      assert {:ok, %{"handles" => 1}} = Client.stats(server: c)
      {:ok, _} = Client.release([fig], server: c)
    end

    test "a struct argument is resolved in the same request", %{c: c} do
      aux = %Actor{figure: nil, internal: "AUX_CAMERA", name: "Aux Camera"}

      assert {:ok, [nil, %ExPoser.Handle{} = cam]} =
               Batch.new()
               |> Batch.call(:scene, "SetCurrentCamera", [aux])
               |> Batch.call(:scene, "CurrentCamera", [])
               |> Batch.run(server: c)

      assert ActorType.internal_name(cam, server: c) == {:ok, "AUX_CAMERA"}
      {:ok, _} = Client.release([cam], server: c)
      assert_no_handles(c)
    end

    test "a missing struct argument is not_found", %{c: c} do
      nope = %Actor{figure: nil, internal: "nope", name: "nope"}

      assert {:error, %Error{kind: :not_found, details: %{path: [actor: "nope"], index: 1}}} =
               Batch.new()
               |> Batch.call(:scene, "NumFrames", [])
               |> Batch.call(:scene, "SetCurrentCamera", [nope])
               |> Batch.run(server: c)

      assert_no_handles(c)
    end

    test "argument lookups count toward chunk size", %{c: c} do
      aux = %Actor{figure: nil, internal: "AUX_CAMERA", name: "Aux Camera"}
      main = %Actor{figure: nil, internal: "MAIN_CAMERA", name: "Main Camera"}

      b =
        Batch.new()
        |> Batch.call(:scene, "SetCurrentCamera", [aux])
        |> Batch.call(:scene, "SetCurrentCamera", [main])

      assert length(Batch.compile(b, chunk: 3)) == 2
      assert Batch.run(b, server: c, chunk: 3) == {:ok, [nil, nil]}
      assert_no_handles(c)
    end

    test "frame is restored", %{c: c} do
      set_frame(c, 3)
      assert {:ok, [:ok]} = ExPoser.batch(&Batch.set(&1, @p, 2.0, frame: 5), server: c)
      assert frame(c) == 3
      assert value(c, @p, 5) == {:ok, [2.0]}
      assert value(c, @p, 3) == {:ok, [0.0]}
      assert_no_handles(c)
    end

    test "op without frame runs at the original frame", %{c: c} do
      assert {:ok, [:ok, +0.0, 1.0]} =
               ExPoser.batch(
                 fn b ->
                   b
                   |> Batch.set(@p, 1.0, frame: 5)
                   |> Batch.get(@p)
                   |> Batch.get(@p, frame: 5)
                 end,
                 server: c
               )

      assert frame(c) == 0
      assert_no_handles(c)
    end

    test "chunk boundary", %{c: c} do
      b =
        Enum.reduce(1..10, Batch.new(), fn i, b ->
          b |> Batch.set(@ball_p, i) |> Batch.get(@ball_p)
        end)

      assert length(Batch.compile(b, chunk: 4)) >= 3
      expected = Enum.flat_map(1..10, &[:ok, &1 * 1.0])
      assert Batch.run(b, server: c, chunk: 4) == {:ok, expected}
      assert_no_handles(c)
    end

    test "frames across chunks", %{c: c} do
      set_frame(c, 3)

      b =
        Batch.new()
        |> Batch.set(@p, 1.0, frame: 5)
        |> Batch.get(@p)
        |> Batch.set(@p, 2.0, frame: 6)

      assert length(Batch.compile(b, chunk: 7)) == 3
      assert Batch.run(b, server: c, chunk: 7) == {:ok, [:ok, 0.0, :ok]}
      assert frame(c) == 3
      assert value(c, @p, 6) == {:ok, [2.0]}
      assert_no_handles(c)
    end

    test "failure in a middle chunk", %{c: c} do
      set_frame(c, 3)

      b =
        Batch.new()
        |> Batch.set(@p, 1.0, frame: 5)
        |> Batch.set(@missing, 2.0, frame: 5)
        |> Batch.set(@chest_p, 3.0)

      assert length(Batch.compile(b, chunk: 7)) == 3

      assert {:error, %Error{kind: :not_found, details: details} = err} =
               Batch.run(b, server: c, chunk: 7)

      assert details.path == ExPoser.Ref.path(@missing)
      assert details.index == 1
      assert %Error{kind: :python} = details.cause
      assert Exception.message(err) == "not_found: figure 1/hip/nope"

      assert frame(c) == 3
      assert value(c, @p, 5) == {:ok, [1.0]}
      assert value(c, @chest_p, 3) == {:ok, [0.0]}
      assert_no_handles(c)
    end

    test "missing figure raises in Python, still not_found", %{c: c} do
      fig = %Figure{internal: "no such figure", name: "x"}

      parm = %Parameter{
        actor: %Actor{figure: fig, internal: "hip", name: "hip"},
        internal: "xtran",
        name: "xTran"
      }

      assert {:error, %Error{kind: :not_found, details: details}} =
               ExPoser.batch(&Batch.get(&1, parm, frame: 4), server: c)

      assert details.path == [{:figure, "no such figure"}]
      assert details.index == 0
      assert %Error{kind: :python, class: "error"} = details.cause

      actor = %Actor{figure: @fig, internal: "no such actor", name: "x"}
      parm = %Parameter{actor: actor, internal: "xtran", name: "xTran"}

      assert {:error, %Error{kind: :not_found, details: %{index: 1, path: path}}} =
               ExPoser.batch(fn b -> b |> Batch.get(@p) |> Batch.get(parm) end, server: c)

      assert path == [{:figure, "figure 1"}, {:actor, "no such actor"}]
      assert frame(c) == 0
      assert_no_handles(c)
    end

    test "Python error keeps class and gains index", %{c: c} do
      assert {:error, %Error{kind: :python, class: "ValueError", details: %{index: 0}}} =
               ExPoser.batch(&Batch.call(&1, :scene, "SetFrame", [999]), server: c)

      assert {:error, %Error{kind: :python, class: "ValueError", details: %{index: 1}}} =
               ExPoser.batch(
                 fn b -> b |> Batch.get(@p) |> Batch.call(:scene, "SetFrame", [999]) end,
                 server: c
               )

      assert_no_handles(c)
    end

    test "not_allowed keeps details.op as the sub-kind and gains index", %{c: c} do
      assert {:error, %Error{kind: :not_allowed, message: "_hidden", details: details}} =
               ExPoser.batch(
                 fn b -> b |> Batch.get(@p) |> Batch.call(:scene, "_hidden", []) end,
                 server: c
               )

      assert details.op == :invoke
      assert details.index == 1
      assert_no_handles(c)
    end

    test "a failing chunk releases handles from earlier chunks' results", %{c: c} do
      b =
        Batch.new()
        |> Batch.call(@fig, "ActorByInternalName", ["hip"])
        |> Batch.set(@missing, 1.0)

      assert [{c1, _}, {_c2, _}] = Batch.compile(b, chunk: 5)
      assert List.last(c1) == {:invoke, {:result, 1}, "ActorByInternalName", ["hip"]}

      assert {:error, %Error{kind: :not_found, details: %{index: 1}}} =
               Batch.run(b, server: c, chunk: 5)

      assert_no_handles(c)
    end

    test "run!/2 returns the results or raises", %{c: c} do
      assert Batch.new() |> Batch.set(@p, 5) |> Batch.get(@p) |> Batch.run!(server: c) ==
               [:ok, 5.0]

      assert_raise Error, "not_found: figure 1/hip/nope", fn ->
        Batch.new() |> Batch.get(@missing) |> Batch.run!(server: c)
      end

      assert_no_handles(c)
    end

    test "ExPoser.batch!/2 returns the results or raises", %{c: c} do
      assert ExPoser.batch!(&Batch.call(&1, :scene, "NumFrames", []), server: c) == [30]

      assert_raise Error, ~r/ValueError/, fn ->
        ExPoser.batch!(&Batch.call(&1, :scene, "SetFrame", [999]), server: c)
      end

      assert_no_handles(c)
    end
  end

  # the session file is briefly missing while the server restarts
  @tag :capture_log
  test "a struct survives a server restart" do
    server = PoserTest.Standalone.start!()
    c = start_client(server.session, backoff_initial: 50, backoff_max: 200)
    :ok = ExPoser.Events.subscribe(:disconnected)

    assert {:ok, [:ok]} = ExPoser.batch(&Batch.set(&1, @p, 4.0), server: c)
    PoserTest.Standalone.stop!(server)
    assert_receive {:poser_event, :disconnected, %{server: ^c}}, 5_000

    again = PoserTest.Standalone.start!(session: server.session)
    on_exit(fn -> PoserTest.Standalone.stop!(again) end)
    assert_receive {:poser_event, :connected, %{server: ^c}}, 5_000

    # a fresh server has a fresh scene; the struct still resolves by name
    assert {:ok, [+0.0]} = ExPoser.batch(&Batch.get(&1, @p), server: c)
    assert_no_handles(c)
  end

  defp assert_no_handles(c), do: assert({:ok, %{"handles" => 0}} = Client.stats(server: c))

  defp connect(_ctx) do
    server = start_standalone()
    %{c: start_client(server.session)}
  end

  defp frame(c) do
    {:ok, [scene, f]} = Client.batch([@scene, {:invoke, {:result, 0}, "Frame", []}], server: c)
    {:ok, _} = Client.release([scene], server: c)
    f
  end

  defp set_frame(c, n) do
    {:ok, [scene, nil]} =
      Client.batch([@scene, {:invoke, {:result, 0}, "SetFrame", [n]}], server: c)

    {:ok, _} = Client.release([scene], server: c)
  end

  defp tree_inputs do
    tree = Material.tree(%Material{owner: @hip, name: "Skin"})
    node = %ShaderNode{tree: tree, internal: "PoserSurface"}

    {tree, for(n <- ["Diffuse_Value", "Bump"], do: %ShaderInput{node: node, internal: n})}
  end

  defp value(c, parm, frame),
    do: ExPoser.batch(&Batch.get(&1, parm, frame: frame), server: c)
end
