# Phase 2 findings

Implementation plan: `plans/phase2-code-generation.md`.

## Coverage (`priv/poser_api_manifest.json`, api_hash `4ebd1aa06734`)

| | count |
|---|---|
| Entries in the dump | 1109 |
| Generated | 1098 (1054 from docstrings, 44 from signature overrides, 0 variadic) |
| Skipped | 11 |
| Getters (zero-argument, read-only) | 486 |
| Constructors | 5 |

Docstring return types the generator doesn't know (Poser typos and prose) map to `term()`: `BoundingBoxTuppel`, `NodeMangerType`, `Palettes`, `actor-list`, `per-actor-vertex-info-list`, `FigureType, ActorType, or ParmType`, `class 'wx._core.App'`.

## Live Poser (2026-11-02)

The add-on was redeployed and Poser 14 was restarted with the 9-figure scene loaded.

### Setup issue: the firewall rule stopped matching after a reboot
At first, all 6 live tests failed: the client never connected. Poser was listening on `172.22.192.1:47800`, but nothing from WSL got through. The most likely cause: Windows recreates `vEthernet (WSL)` at boot, and the allow rule, which was scoped to that interface, stopped matching the new adapter. Rescoping the rule by address (`-InterfaceAlias Any -LocalAddress 172.22.192.1 -RemoteAddress 172.22.192.0/20`) fixed it, and address scoping doesn't depend on which adapter instance exists.

### Live tests
`mix test --only poser`: 6 tests, 0 failures, about 5 s. The new test runs the smoke walk with `per_class: 2`.

### `mix poser.smoke` (per_class 3)
- 858 calls to 403 getters in 1.8 s. 7 getters were skipped (credentials, and heavy getters that return one handle per element).
- Outcomes: 790 ok, 68 Python errors, and 0 timeouts, stale handles, bad requests or other outcomes.
- 372 getters returned ok at least once.
- Every remaining Python error is Poser correctly rejecting the call for that object:

  | count | message |
  |---|---|
  | 51 | `Object is not a light` (light getters on other actors) |
  | 6 | `Object must be a Magnet` |
  | 3 | `Object is not a deformer` |
  | 3 | `Object is not a measurement` |
  | 3 | `Invalid deformer object` |
  | 1 | `No sound has been set` (`SceneType.SoundRange`) |
  | 1 | `SystemError: … TextureCacheSize … returned NULL without setting an error`. This is a Poser bug in `TempestOptionsType.TextureCacheSize`. |

- Slowest getters: `GeomType.TexSets` 366 ms, `GeomType.Sets` 361 ms, `FigureType.UnimeshInfo` 140 ms, `FigureType.SubdivGeometry` 34 ms, `SceneType.Actors` 14 ms. Everything else took under 10 ms.

### Surprises and the overrides they needed
1. **Gimbal parms took all the parm slots.** At first, all 114 `ParmType` calls failed with `Invalid Parameter object`. `ActorType.Gimbal` is the first getter, alphabetically, that returns parms. Poser rejects the gimbal pseudo-parms it returns, and they filled the walk's 3 `ParmType` slots before real parms from `Parameters` arrived. Called directly on a parm from `Parameters`, the same getters worked.
   - **Fix:** a new `smoke_no_follow` override, "call this getter but don't explore what it returns", set for `ActorType.Gimbal`.
   - **Result:** every `ParmType` getter now returns ok.
2. **`ParmType.NumMorphTargetDeltas` crashes Poser.** On a live parm that isn't a morph target (`yRotate`), the call took down the whole Poser process, and the client saw a heartbeat timeout. The other 10 parm getters that come after it alphabetically were then probed one per run on the same parm, and all returned normally.
   - **Fix:** added to `smoke_skip`.
   - **Still exposed:** the generated `Poser.Api.ParmType.num_morph_target_deltas/2` remains callable. Call it only on morph-target parms.
3. **Python error messages are now in the report.** The smoke report now keeps one Python error message per getter (`python_example`). Without it, cause 1 would have been invisible.

## Automated suites
- Elixir: `mix test`, 130 passed, 6 excluded (the live tests). `mix poser.gen --check` reports the generated files are up to date. `mix compile --warnings-as-errors` is clean.
- Python 3.7.9: `mise exec -- python -m unittest discover -s python/tests -t python`, 65 tests OK.

## Deferred
- Four test files that were committed earlier are not `mix format` clean: `constants_test.exs`, `real_generated_test.exs`, `model_test.exs` and `poser_gen_test.exs`.
- Make the walk explore more varied actors. It takes the first three actors it meets, starting with background actors such as `BackgroundMaterialActor` and `BackgroundSphereActor`. That is why so many actor getters end in "not a light" errors and so few actor kinds get explored.
