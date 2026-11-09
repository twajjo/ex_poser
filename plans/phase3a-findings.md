# Phase 3a findings

## Probe

Run with `mix run scripts/phase3a_probe.exs` against Poser 14 with the 9-figure scene (first figure: GUI name "Base", internal name "Figure 1"; probe parm: `yRotate` on `BODY:1`, internal name `yrot`). The scene was left as found: handles == 0, frame 0, value 0.0, no added keys. Frames are 0-based.

1. **Missing names.** Three raise a Python `poser.error` (class `"error"`); one returns `None`.
   - `SceneType.FigureByInternalName("NoSuchName_zz9")` raises "Unknown/invalid figure name".
   - `FigureType.ActorByInternalName(...)` raises "Figure has no actor by that name".
   - `SceneType.ActorByInternalName(...)` raises "Named actor could not be found".
   - `ActorType.InternalParameter(...)` returns `None` (`{:ok, nil}`).
2. **Figure lookup argument.** `FigureByInternalName` takes the internal name only. With `InternalName()` = "Figure 1" it returns the right figure. With the GUI `Name()` = "Base" it raises "Unknown/invalid figure name". The scene has figures whose two names differ, so this was tested directly. No "Figure step: list `Figures` and match `InternalName`" variant is needed.
3. **End of keyframes.** Every Poser parm starts with a key at frame 0 (checked on xRotate, yRotate, zRotate and xTran of BODY:1). The checks below ran on `yRotate`, with keys added at 3 and 7 and deleted afterwards.
   - With no key beyond frame 0, `NextKeyFrame()` returns `None` (`{:ok, nil}`). `PrevKeyFrame()` at frame 0 returns `None` too, even though a key sits at 0: both calls look strictly past or before the current frame.
   - With keys at 3 and 7: `NextKeyFrame()` read at 3 returns 7. Read at 7 it returns `None`. `PrevKeyFrame()` at 7 returns 3. `NextKeyFrame()` at 0 returns 3.
4. **Auto-keying.** `SetValue(v)` at frame 7 creates a keyframe at 7. `NextKeyFrame` read from frame 6 went from `None` to 7. After restoring the value and `DeleteKeyFrame(7)` it was `None` again.
5. **Integer values.** `SetValue(3)` is accepted. The value reads back as `3.0`. `SetValue` returned `0.0` here (the parm's earlier value in this probe); treat its return as not useful. Like fact 4, it is assumed to add a key at the current frame (assumed from fact 4, not checked at frame 0, where every parm already has a key); the probe removes added keys in cleanup.

## Live idiomatic layer

Run with `mix test --only poser` against Poser 14 with the 9-figure scene (2026-11-04, seed 905395): 12 passed, 205 excluded, 21.1 s. Every test ended with handles == 0 and restored what it changed.

1. **Interpolation and hold.** With keys at 0 and 5 (key value 10.0 at frame 5), `Parameter.value_at/3` at frame 3 read 6.48. That is neither the held frame-0 value nor a step, so Poser interpolates between keys. At frames 5, 8 and 12, past the last key, the value equals the key's value, so it holds. Both claims in `lib/poser/parameter.ex` and `guides/frames-and-keyframes.md` are confirmed; no doc change is needed.
2. **The docs' example names.** On figure "AC 2" (internal "Figure 3"), `Figure.actor/3` with "lForeArm:1" (internal) and with "Left Forearm" (display) return the same actor. `Actor.parameter/3` finds "Bend" but not "bend". "Bend" is a display name; "bend" is no dial's internal name. The forearm's dials, internal → display, are `yrot` → Bend, `zrot` → Side-Side and `xrot` → Twist. A second dial, `twistx`, also shows "Twist", so `"Twist"` by display name is `:ambiguous` and only `"xrot"` names that dial reliably. The other forearm dials are `jointy`/`jointz` (fa_jointy/fa_jointz), `taper`, `scale`, `x/y/zScale`, `x/y/zOffset`, `x/y/ztran`, `x/y/zTranB`, a few hand and shoulder helpers, and 100 morph dials (`PBMDC_01..50`, `PBMCC_01..50`) whose display name is "-".
3. **Timings** (WSL → Windows over TCP):
   - A 2000-op `Batch.run` (2000 distinct parms, gets only) took 502 ms, about 0.25 ms per op.
   - `Actor.values/2` on `BODY:1` (17 dials) took 13 ms.
   - A single op (`Scene.frame/1`) took 2 ms.

   One round trip costs about the same as eight batched ops, so batching pays off from about two ops up.
