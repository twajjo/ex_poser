# Phase 3a probe: live facts about lookups and keyframes. Rerun on a new Poser version.
#   mix run scripts/phase3a_probe.exs
# Each check restores the scene (values, keyframes, frame).
alias Poser.Client
alias Poser.Api.{SceneType, FigureType, ActorType, ParmType}

name = :phase3a_probe
{:ok, _} = Client.start_link(name: name, session: Poser.Session.default_path())

wait = fn wait, n ->
  cond do
    Client.status(server: name) == :connected -> :ok
    n == 0 -> raise "cannot connect"
    true -> Process.sleep(100); wait.(wait, n - 1)
  end
end

wait.(wait, 50)
o = [server: name]
ok! = fn
  {:ok, v} -> v
  other -> raise "unexpected: #{inspect(other)}"
end

fact = fn n, text -> IO.puts("FACT #{n}: #{text}") end
held = :ets.new(:held, [:public])
keep = fn h -> :ets.insert(held, {h}); h end

scene = Client.call("Scene", [], o) |> ok!.() |> keep.()
figs = SceneType.figures(scene, o) |> ok!.()
Enum.each(figs, keep)
fig = hd(figs)
fig_iname = FigureType.internal_name(fig, o) |> ok!.()
fig_name = FigureType.name(fig, o) |> ok!.()
IO.puts("figure: name=#{inspect(fig_name)} internal_name=#{inspect(fig_iname)}")

# Fact 1: missing names
missing = "NoSuchName_zz9"
show = fn
  {:ok, nil} -> "returns None"
  {:ok, other} -> "returned #{inspect(other)}"
  {:error, e} -> "raises #{e.class}: #{e.message}"
end

# need an actor handle for ActorType.InternalParameter
actors = FigureType.actors(fig, o) |> ok!.()
Enum.each(actors, keep)

r1 = SceneType.figure_by_internal_name(scene, missing, o)
r2 = FigureType.actor_by_internal_name(fig, missing, o)
r3 = SceneType.actor_by_internal_name(scene, missing, o)
r4 = ActorType.internal_parameter(hd(actors), missing, o)
for r <- [r1, r2, r3, r4], match?({:ok, %Poser.Handle{}}, r), do: keep.(elem(r, 1))

fact.(1, "SceneType.FigureByInternalName: #{show.(r1)}; FigureType.ActorByInternalName: #{show.(r2)}; SceneType.ActorByInternalName: #{show.(r3)}; ActorType.InternalParameter: #{show.(r4)}")

# Fact 2: figure lookup argument; prefer a figure whose names differ
diff =
  Enum.find_value(figs, fn f ->
    i = FigureType.internal_name(f, o) |> ok!.()
    n = FigureType.name(f, o) |> ok!.()
    if i != n, do: {f, i, n}
  end)

{tf, ti, tn, differ} =
  case diff do
    {f, i, n} -> {f, i, n, true}
    nil -> {fig, fig_iname, fig_name, false}
  end

byi = SceneType.figure_by_internal_name(scene, ti, o)
byn = SceneType.figure_by_internal_name(scene, tn, o)
for r <- [byi, byn], match?({:ok, %Poser.Handle{}}, r), do: keep.(elem(r, 1))

same = fn
  {:ok, %Poser.Handle{} = h} ->
    (FigureType.internal_name(h, o) |> ok!.()) == ti
  _ -> false
end

desc = fn r -> "#{show.(r |> then(fn {:ok, %Poser.Handle{}} -> {:ok, :handle}; x -> x end))}#{if same.(r), do: " (the right figure)", else: ""}" end

fact.(2, "names #{if differ, do: "differ", else: "do not differ in this scene"} (internal=#{inspect(ti)}, name=#{inspect(tn)}); by internal name: #{desc.(byi)}; by GUI name: #{desc.(byn)}")
_ = tf

# Find body part with a yRotate parm
{actor, parm} =
  Enum.find_value(actors, fn a ->
    case ActorType.parameter(a, "yRotate", o) do
      {:ok, %Poser.Handle{} = p} -> {a, keep.(p)}
      _ -> nil
    end
  end) || raise "no yRotate parm"

IO.puts("actor=#{inspect(ActorType.internal_name(actor, o))} parm=#{inspect(ParmType.internal_name(parm, o))}")

frame0 = SceneType.frame(scene, o) |> ok!.()
orig = ParmType.value(parm, o) |> ok!.()
IO.puts("start frame=#{frame0} value=#{inspect(orig)}")

# Fact 3: keyframe ends, at a frame with no keys beyond
SceneType.set_frame(scene, 0, o) |> ok!.()
prev0 = ParmType.prev_key_frame(parm, o)
nextf = ParmType.next_key_frame(parm, o)
SceneType.set_frame(scene, frame0, o) |> ok!.()
fact.(3, "PrevKeyFrame at frame 0: #{inspect(prev0)}; NextKeyFrame with no later key (from frame 0): #{inspect(nextf)}")

# Fact 4: auto-keying at frame n
n = 7
SceneType.set_frame(scene, n - 1, o) |> ok!.()
before = ParmType.next_key_frame(parm, o)
SceneType.set_frame(scene, n, o) |> ok!.()
orig_n = ParmType.value(parm, o) |> ok!.()
setr = ParmType.set_value(parm, orig_n + 5.0, o)
SceneType.set_frame(scene, n - 1, o) |> ok!.()
after_ = ParmType.next_key_frame(parm, o)
SceneType.set_frame(scene, n, o) |> ok!.()
# restore
ParmType.set_value(parm, orig_n, o)
SceneType.set_frame(scene, n - 1, o) |> ok!.()
mid = ParmType.next_key_frame(parm, o)
SceneType.set_frame(scene, n, o) |> ok!.()
if mid == {:ok, n} and before != {:ok, n}, do: ParmType.delete_key_frame(parm, [frame: n] ++ o) |> IO.inspect(label: "delete_key_frame")
SceneType.set_frame(scene, n - 1, o) |> ok!.()
final = ParmType.next_key_frame(parm, o)
fact.(4, "SetValue at frame #{n} -> #{inspect(setr)}; NextKeyFrame from #{n - 1} before=#{inspect(before)} after=#{inspect(after_)}; after restore+delete=#{inspect(final)}")

# Fact 5: integer value
SceneType.set_frame(scene, frame0, o) |> ok!.()
cur = ParmType.value(parm, o) |> ok!.()
int_r = ParmType.set_value(parm, 3, o)
now = ParmType.value(parm, o)
ParmType.set_value(parm, cur, o)
fact.(5, "SetValue(3) -> #{inspect(int_r)}; value read back #{inspect(now)}")

SceneType.set_frame(scene, frame0, o) |> ok!.()
IO.puts("end frame=#{SceneType.frame(scene, o) |> ok!.()} value=#{inspect(ParmType.value(parm, o))} (started #{inspect(orig)})")

hs = :ets.tab2list(held) |> Enum.map(&elem(&1, 0))
IO.inspect(Client.release(hs, o), label: "release")
IO.inspect(Client.stats(o), label: "stats")
IO.inspect(Client.ping(o), label: "ping")
