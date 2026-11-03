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
5. **Integer values.** `SetValue(3)` is accepted. The value reads back as `3.0`. `SetValue` returned `0.0` here (the parm's earlier value in this probe); treat its return as not useful. Like fact 4, it also adds a key at the current frame (the probe removes it in cleanup, except the frame 0 key every parm already has).
