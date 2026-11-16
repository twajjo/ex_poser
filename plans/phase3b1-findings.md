# Phase 3b-1 (lights and cameras): live findings

Run on 2026-11-16 with `mix test --only poser` against a real Poser scene: 13 lights, 80 cameras, figure "AC 2" (Figure 3). Result: 16 passed.

## Output (verbatim)

```
Running ExUnit with seed: 604634, max_cases: 32
Excluding tags: [:test]
Including tags: [:poser]

...lForeArm:1 / Left Forearm on AC 2 (Figure 3); same actor: true; Bend: true; bend: false
...2000-op batch (2000 distinct parms): 390 ms
Actor.values on BODY:1: 17 dials, 4 ms
single op (Scene.frame): 0 ms
........keys [0, 5]; value at 3 (between 0 and 5): 6.480000019073486; key value 10.0
.Light.snapshot_all (13 lights): 105 ms
Light.apply replace (13 lights): 8518 ms
Camera.snapshot_all (80 cameras): 916 ms
Camera.apply (80 cameras): 868 ms
light dial internal names: ["Angle End", "Angle Start", "Dist End", "Dist Start", "KdBlue", "KdGreen", "KdIntensity", "KdRed", "Preview_Light_0_B", "Preview_Light_0_G", "Preview_Light_0_R", "Preview_Light_1", "depthMapSize", "scale", "shadowStrength", "xrot", "xtran", "yrot", "ytran", "zrot", "ztran"]
GetLightIntensity: 1.0; intensity dials: [{"KdIntensity", 1.0}]
.
Finished in 60.5 seconds (0.8s async, 59.7s sync)

Result: 16 passed, 326 excluded
```

## What it shows

1. Every lights-and-cameras behaviour the live tests assert works on real Poser: create, set colour and shadow samples, snapshot, merge applied twice (one new light, reads back equal), replace leaving one light, and switching the current camera and back. The scene's lights and camera were restored afterwards.
2. Timings: `Light.snapshot_all` of 13 lights takes 105 ms. `Light.apply` in replace mode takes 8518 ms, which is slow; most of it is presumably Poser deleting and creating 13 lights. `Camera.snapshot_all` and `Camera.apply` of 80 cameras take 916 ms and 868 ms.
3. Real light dial internal names keep their case and spaces (`KdRed`, `KdIntensity`, `Angle End`, …). The Fake Poser makes them lower case (`kdred`). Code finds the colour dials by parm code, so nothing depends on the case, but the fake doesn't match Poser here.
4. A real light has 21 dials, the fake's 5.
5. `GetLightIntensity` (1.0) agrees with the `KdIntensity` dial (1.0). That's one value, not proof they always agree.

## Follow-ups (not done)

- Make the Fake Poser's light dial internal names match Poser's (case and the extra dials), if a test ever needs it.
- If the replace time matters, measure where the 8.5 s goes. Optimising is out of scope for 3b-1.
