# Phase 3a probe: live facts about lookups and keyframes. Rerun on a new Poser version.
#   mix run scripts/phase3a_probe.exs
# The `after` block always restores the value, deletes keys the probe added,
# restores the frame and releases every handle. Exits non-zero on a leak.
alias ExPoser.Client
alias ExPoser.Api.{SceneType, FigureType, ActorType, ParmType}

name = :phase3a_probe
{:ok, _} = Client.start_link(name: name, session: ExPoser.Session.default_path())

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

# State shared with `after`: held handles, scene/parm/frame/value, pre-existing keys.
st = :ets.new(:st, [:public, :set])
put = fn k, v -> :ets.insert(st, {k, v}); v end
get = fn k -> case :ets.lookup(st, k) do [{_, v}] -> v; [] -> nil end end
keep = fn h -> put.(:held, [h | get.(:held) || []]); h end
put.(:held, [])

frames = [0, 3, 7]

# Is there a key at frame f on parm? Leaves the scene on some other frame.
has_key? = fn scene, parm, f ->
  if f == 0 do
    SceneType.set_frame(scene, 1, o) |> ok!.()
    ParmType.prev_key_frame(parm, o) |> ok!.() == 0
  else
    SceneType.set_frame(scene, f - 1, o) |> ok!.()
    ParmType.next_key_frame(parm, o) |> ok!.() == f
  end
end

show = fn
  {:ok, nil} -> "returns None"
  {:ok, %ExPoser.Handle{}} -> "returns a handle"
  {:ok, other} -> "returned #{inspect(other)}"
  {:error, e} -> "raises #{e.class}: #{e.message}"
end

try do
  scene = Client.call("Scene", [], o) |> ok!.() |> keep.()
  put.(:scene, scene)
  put.(:frame0, SceneType.frame(scene, o) |> ok!.())
  figs = SceneType.figures(scene, o) |> ok!.()
  Enum.each(figs, keep)
  fig = hd(figs)
  fig_iname = FigureType.internal_name(fig, o) |> ok!.()
  fig_name = FigureType.name(fig, o) |> ok!.()
  IO.puts("figure: name=#{inspect(fig_name)} internal_name=#{inspect(fig_iname)}")

  actors = FigureType.actors(fig, o) |> ok!.()
  Enum.each(actors, keep)

  # Fact 1: missing names
  missing = "NoSuchName_zz9"
  r1 = SceneType.figure_by_internal_name(scene, missing, o)
  r2 = FigureType.actor_by_internal_name(fig, missing, o)
  r3 = SceneType.actor_by_internal_name(scene, missing, o)
  r4 = ActorType.internal_parameter(hd(actors), missing, o)
  for r <- [r1, r2, r3, r4], match?({:ok, %ExPoser.Handle{}}, r), do: keep.(elem(r, 1))

  fact.(1, "SceneType.FigureByInternalName: #{show.(r1)}; FigureType.ActorByInternalName: #{show.(r2)}; SceneType.ActorByInternalName: #{show.(r3)}; ActorType.InternalParameter: #{show.(r4)}")

  # Fact 2: figure lookup argument; prefer a figure whose names differ
  {ti, tn, differ} =
    Enum.find_value(figs, fn f ->
      i = FigureType.internal_name(f, o) |> ok!.()
      n = FigureType.name(f, o) |> ok!.()
      if i != n, do: {i, n, true}
    end) || {fig_iname, fig_name, false}

  byi = SceneType.figure_by_internal_name(scene, ti, o)
  byn = SceneType.figure_by_internal_name(scene, tn, o)
  for r <- [byi, byn], match?({:ok, %ExPoser.Handle{}}, r), do: keep.(elem(r, 1))

  desc = fn r ->
    right =
      case r do
        {:ok, %ExPoser.Handle{} = h} -> if (FigureType.internal_name(h, o) |> ok!.()) == ti, do: " (the right figure)", else: " (the WRONG figure)"
        _ -> ""
      end

    show.(r) <> right
  end

  fact.(2, "names #{if differ, do: "differ", else: "do not differ in this scene"} (internal=#{inspect(ti)}, name=#{inspect(tn)}); by internal name: #{desc.(byi)}; by GUI name: #{desc.(byn)}")

  # Find body part with a yRotate parm
  {actor, parm} =
    Enum.find_value(actors, fn a ->
      case ActorType.parameter(a, "yRotate", o) do
        {:ok, %ExPoser.Handle{} = p} -> {a, keep.(p)}
        _ -> nil
      end
    end) || raise "no yRotate parm"

  IO.puts("actor=#{inspect(ActorType.internal_name(actor, o))} parm=#{inspect(ParmType.internal_name(parm, o))}")

  # Record the starting state; the first stored key makes `after` restore it.
  frame0 = get.(:frame0)
  orig = ParmType.value(parm, o) |> ok!.()
  pre = Map.new(frames, fn f -> {f, has_key?.(scene, parm, f)} end)
  SceneType.set_frame(scene, frame0, o) |> ok!.()
  put.(:orig, orig)
  put.(:pre, pre)
  put.(:parm, parm)
  IO.puts("start frame=#{frame0} value=#{inspect(orig)} pre-existing keys at #{inspect(frames)}: #{inspect(pre)}")

  # Poser parms start with a key at frame 0; only frames 3 and 7 must be free.
  if pre[3] or pre[7], do: raise("test parm already has a key at frame 3 or 7; pick another")

  at = fn f -> SceneType.set_frame(scene, f, o) |> ok!.() end

  # Fact 3: keyframe ends. First with no keys, then with keys at 3 and 7.
  at.(0)
  prev0 = ParmType.prev_key_frame(parm, o)
  next_none = ParmType.next_key_frame(parm, o)
  at.(3)
  ParmType.add_key_frame(parm, [frame: 3] ++ o) |> ok!.()
  at.(7)
  ParmType.add_key_frame(parm, [frame: 7] ++ o) |> ok!.()
  at.(3)
  next_at3 = ParmType.next_key_frame(parm, o)
  at.(7)
  next_at7 = ParmType.next_key_frame(parm, o)
  prev_at7 = ParmType.prev_key_frame(parm, o)
  at.(0)
  prev_at0 = ParmType.prev_key_frame(parm, o)
  next_at0 = ParmType.next_key_frame(parm, o)
  # remove both keys now so fact 4 starts clean
  ParmType.delete_key_frame(parm, [frame: 3] ++ o) |> ok!.()
  ParmType.delete_key_frame(parm, [frame: 7] ++ o) |> ok!.()

  fact.(3, "no keys: PrevKeyFrame at 0=#{inspect(prev0)}, NextKeyFrame at 0=#{inspect(next_none)}; keys at 3 and 7: NextKeyFrame at 3=#{inspect(next_at3)}, at 7=#{inspect(next_at7)}, PrevKeyFrame at 7=#{inspect(prev_at7)}, at 0=#{inspect(prev_at0)}, NextKeyFrame at 0=#{inspect(next_at0)}")

  # Fact 4: auto-keying at frame n
  n = 7
  at.(n - 1)
  before = ParmType.next_key_frame(parm, o)
  at.(n)
  setr = ParmType.set_value(parm, orig + 5.0, o)
  at.(n - 1)
  after_ = ParmType.next_key_frame(parm, o)
  fact.(4, "SetValue at frame #{n} -> #{inspect(setr)}; NextKeyFrame from #{n - 1} before=#{inspect(before)} after=#{inspect(after_)} (key removed in cleanup)")

  # Fact 5: integer value (cleanup restores the value and any key it made)
  at.(frame0)
  int_r = ParmType.set_value(parm, 3, o)
  now = ParmType.value(parm, o)
  fact.(5, "SetValue(3) -> #{inspect(int_r)}; value read back #{inspect(now)}")
after
  # Every cleanup step is wrapped by `step`: it never raises, and a failure is
  # recorded in ETS. The exit status is decided after the try, below.
  step = fn label, fun ->
    try do
      case fun.() do
        {:error, _} = e -> put.({:fail, label}, e)
        _ -> :ok
      end
    rescue
      e -> put.({:fail, label}, {:raised, Exception.message(e)})
    catch
      kind, v -> put.({:fail, label}, {kind, v})
    end
  end

  # Non-raising key probe: true | false | :error
  key_at? = fn scene, parm, f ->
    try do
      has_key?.(scene, parm, f)
    rescue
      _ -> :error
    end
  end

  scene = get.(:scene)
  parm = get.(:parm)
  frame0 = get.(:frame0) || 0

  if scene && parm do
    pre = get.(:pre)

    for f <- frames, not pre[f] do
      step.({:delete_key, f}, fn ->
        case key_at?.(scene, parm, f) do
          true -> SceneType.set_frame(scene, f, o); ParmType.delete_key_frame(parm, [frame: f] ++ o)
          false -> :ok
          :error -> {:error, :key_check_failed}
        end
      end)
    end

    # SetValue at the start frame may add a key; delete it again if it was not there before.
    step.(:restore_frame_for_value, fn -> SceneType.set_frame(scene, frame0, o) end)
    step.(:restore_value, fn -> ParmType.set_value(parm, get.(:orig), o) end)

    if not pre[frame0] do
      step.({:delete_key, frame0}, fn ->
        case key_at?.(scene, parm, frame0) do
          true -> SceneType.set_frame(scene, frame0, o); ParmType.delete_key_frame(parm, [frame: frame0] ++ o)
          false -> :ok
          :error -> {:error, :key_check_failed}
        end
      end)
    end

    step.(:restore_frame, fn -> SceneType.set_frame(scene, frame0, o) end)

    step.(:verify_value, fn ->
      orig = get.(:orig)

      case ParmType.value(parm, o) do
        {:ok, v} when v == orig -> :ok
        other -> {:error, {:value_not_restored, other, orig}}
      end
    end)

    step.(:verify_frame, fn ->
      case SceneType.frame(scene, o) do
        {:ok, ^frame0} -> :ok
        other -> {:error, {:frame_not_restored, other, frame0}}
      end
    end)
  else
    if scene, do: step.(:restore_frame, fn -> SceneType.set_frame(scene, frame0, o) end)
  end

  step.(:release, fn -> IO.inspect(Client.release(get.(:held) || [], o), label: "release") end)

  step.(:stats, fn ->
    stats = Client.stats(o)
    IO.inspect(stats, label: "stats")

    case stats do
      {:ok, %{"handles" => 0}} -> :ok
      _ -> put.(:leaked, true)
    end
  end)

  step.(:ping, fn -> IO.inspect(Client.ping(o), label: "ping") end)
end

# Exit status is decided here, outside `after`, so output and exceptions are not cut off.
fails = :ets.match_object(st, {{:fail, :_}, :_})

if get.(:leaked) do
  IO.puts("FAIL: handles leaked")
end

for {{:fail, label}, why} <- fails, do: IO.puts("FAIL: cleanup step #{inspect(label)}: #{inspect(why)}")

if get.(:leaked) || fails != [], do: System.halt(1)
