# Phase 3b-1: lights and cameras (design)

Status: design approved in conversation on 2026-11-10, awaiting review of this spec.
Builds on Phase 3a (`plans/phase3a-idiomatic-core-design.md`). Phase 3b is split into 3b-1 (this spec: lights and cameras) and 3b-2 (materials), and each has its own spec, plan and PRs.

## Intent

| | |
|---|---|
| First use | Light rigs and camera setups: list, read and change them, create and delete lights, and capture a whole rig as data and put it back. |
| Downstream | Scene presets and the Postgres catalogue (see the catalogue use case). 3b-1 provides the snapshot data. The preset format, parameters and storage are designed in that later phase. |
| Success | A rig is read and applied in a fixed number of round trips (about five or six), however many lights it has. Applying the same rig twice changes nothing the second time. A snapshot holds no handles and survives a reconnect. The 3a conventions hold throughout. |

## Concept map additions

| Poser | Elixir | Notes |
|---|---|---|
| Light (an actor with no figure) | `%ExPoser.Light{actor: %ExPoser.Actor{}}` | Its dials are reached through `light.actor` and the 3a `Actor` functions. Its method-only properties are reached through `Light.get/set`. |
| Camera (an actor with no figure) | `%ExPoser.Camera{actor: %ExPoser.Actor{}}` | Its settings (focal length, DOF, position) are all dials. Poser can't create or delete cameras. |
| The scene's current camera | `Scene.current_camera/1`, `Scene.set_current_camera/2` | |
| A light rig or camera at one frame | `%ExPoser.Light.Snapshot{}`, `%ExPoser.Camera.Snapshot{}` | Plain data with no handles. Keyframes aren't captured (see Phase 6). |

## Design

### 1. Modules and functions

The 3a conventions apply throughout: `{:ok, _} | {:error, %ExPoser.Error{}}` with a `!` variant, trailing `opts` (`:server` and `:timeout`, plus `:frame` where time applies), plain structs with `Inspect` (`#ExPoser.Light<Light 1>`), and `handle/1` as the escape hatch, whose handle the caller releases.

| Module | Functions |
|---|---|
| `ExPoser.Scene` (additions) | `lights/1`, `light/2`, `cameras/1`, `camera/2`, `current_camera/1`, `set_current_camera/2` |
| `ExPoser.Light` | `create/1`, `create/2` (with `type:` and other properties), `delete/2`, `get/2`, `set/3`, `point_at/3`, `snapshot/2`, `snapshot_all/1`, `apply/2`, `handle/1` |
| `ExPoser.Camera` | `get/2`, `set/3`, `point_at/3`, `snapshot/2`, `snapshot_all/1`, `apply/2`, `handle/1` |
| `ExPoser.Light.Snapshot` | `%{name, type, dials: %{internal => value}, props: %{atom => value}}` |
| `ExPoser.Camera.Snapshot` | `%{name, dials: %{internal => value}}` |
| `ExPoser.Ref` (internal) | `path/1` gains `%Light{}` and `%Camera{}` clauses, which delegate to the actor. |

`get/2` takes a dial name (string), a property (atom) or a list mixing both. `set/3` takes one name and value, or a map mixing dials and properties. All of it runs in one batch, with the properties sent as `Batch.call/5` ops. `Camera.get/set` take dial names only, since cameras have no property table.

The `Light` and `Camera` functions guard on their own struct, so passing a camera to `Light.set/3` raises `FunctionClauseError`.

### 2. Light properties

There is one table in `ExPoser.Light`, mapping each atom to its PoserPython getter and setter:

| Atom | Getter / setter |
|---|---|
| `:type` | `LightType` / `SetLightType` (enum, below) |
| `:attenuation` | `LightAttenType` / `SetLightAttenType` (enum, below) |
| `:on` | `LightOn` / `SetLightOn` |
| `:preview` | `LightPreview` / `SetLightPreview` |
| `:shadow` | `Shadow` / `SetShadow` |
| `:casts_shadows` | `CastsShadows` / `SetCastsShadows` |
| `:ray_trace_shadows` | `RayTraceShadows` / `SetRayTraceShadows` |
| `:shadow_bias_min`, `:shadow_bias_max` | `ShadowBiasMin`, `ShadowBiasMax` / `Set…` |
| `:shadow_blur_radius` | `ShadowBlurRadius` / `SetShadowBlurRadius` |
| `:shadow_raytrace_softness` | `ShadowRaytraceSoftness` / `SetShadowRaytraceSoftness` |
| `:shadow_samples` | `ShadowSamples` / `SetShadowSamples` |
| `:ambient_occlusion` | `AmbientOcclusion` / `SetAmbientOcclusion` |
| `:ambient_occlusion_bias`, `:ambient_occlusion_distance`, `:ambient_occlusion_strength` | `AmbientOcclusion…` / `SetAmbientOcclusion…` |

The enums, using the `kLightCode*` constants:
- `type`: `:infinite` (0), `:spot` (1), `:point` (2, which is also `kLightCodeLOCAL`), `:image` (3), `:area` (4).
- `attenuation`: `:poser` (0), `:inverse_linear` (1), `:inverse_square` (2).

A code that Poser returns but isn't in these lists stays an integer, and applying it writes the integer back.

**Colour and intensity are dials.** A light's colour is three dials, `kParmCodeKDRED`, `kParmCodeKDGREEN` and `kParmCodeKDBLUE` (parm codes 23–25), and `ActorType` has no colour method. Intensity is a dial too (`kParmCodeKDINTENSITY`, 29). Snapshots capture them with every other dial.
- `:color` is a convenience property: `Light.get(l, :color)` returns `{r, g, b}`, and `Light.set(l, %{color: {r, g, b}})` sets all three. It finds the dials with `ParameterByCode` (23, 24, 25), so it doesn't depend on their internal names. Snapshots don't use it, because the dials already hold the colour.
- `GetLightIntensity`/`SetLightIntensity` aren't in the table, so the intensity dial is the only source. The live check records whether the method and the dial ever disagree.

A unit test checks every getter and setter name in the table against `priv/poser_api.json`.

### 3. Creating and deleting lights

- `CreateLight()` takes no arguments and always makes a spot light. `create/2` runs create, `SetName` (if `name:` is given), the type, the properties and the dials in one batch, and returns the `%Light{}`.
- `delete/2` calls `ActorType.Delete` on the light.

### 4. Snapshots and apply

- **`snapshot/2` and `snapshot_all/1`** take a fixed number of round trips (listing the lights, listing their dials, then one batch that reads each light's name, type, every dial (the 3a `values` op) and every property in the table). Cameras read their name and dials. `frame:` reads at that frame and restores the current frame.
- **`apply(snapshots, mode: :merge)`** (the default) takes a fixed number of round trips:
  1. One listing reads the scene's lights (or cameras) and their names. Then one request creates any missing lights, and one listing reads every target's dial names (for `skipped`).
  2. In Elixir, the snapshots are matched to scene lights by display name. A matched light is updated. An unmatched light is created (with `SetName`) in the create request. A snapshot name that matches two scene lights returns `:ambiguous` before anything changes.
  3. One batch makes every change. For each light, the type is set first, then the properties, then the dials, because a type change can reset dials.
- **`apply(snapshots, mode: :replace)`** deletes every light in the scene, then creates the rig's lights, in the same request pattern. Lights only.
- **Cameras** are always applied by name and only have their values set. A missing camera returns `:not_found` before anything changes.
- **`frame:`** applies the dials at that frame. Properties don't vary over time.
- **Result:** `{:ok, %{skipped: [{light_or_camera_name, dial_name}]}}`. A dial in the snapshot that the scene's light or camera lacks is skipped and listed, not treated as an error.

### 5. Errors and edge cases

| Case | Result |
|---|---|
| A name that matches no light or camera | `:not_found` with `details.path` |
| A display name that matches two lights | `:ambiguous` with `matches`, and nothing changes |
| An unknown property atom, or an unknown enum atom (`type: :laser`) | `ArgumentError` raised at the call site |
| The wrong struct | `FunctionClauseError` |
| An unknown type or attenuation code read from Poser | Kept as an integer |
| A dial missing on the scene's light or camera | Skipped and reported in `skipped` |
| A failure during the apply batch | The usual 3a `Batch` error with the caller's op `index`. The ops before it stay applied (no rollback) |

## Testing

- **Fake Poser** (`python/fake_poser.py`) gains `Lights`, `Cameras`, `CurrentCamera`, `SetCurrentCamera`, `CreateLight` (spot), `Delete`, `ParameterByCode`, the table's light methods with stored values, light and camera dials stored per frame, and two lights with the same display name. Python tests cover the additions.
- **Elixir unit tests** run against the standalone server with `ClientCase`:
  - every public function and its `!` variant;
  - the property table against `priv/poser_api.json`;
  - `:color` reads and sets the three KD dials;
  - `snapshot` then `apply` on a fresh scene reproduces the rig;
  - applying twice in merge mode creates no duplicates;
  - replace mode removes stray lights;
  - skipped dials are reported;
  - `:not_found` and `:ambiguous` change nothing;
  - `frame:` is restored;
  - `handles == 0` after every operation.
- **Live tests** (`@tag :poser`) take a `snapshot_all` at the start, then:
  - create a light, set it, snapshot it, and apply it twice in merge mode (the light count is unchanged);
  - apply in replace mode;
  - switch the current camera and switch it back;
  - time a full-rig snapshot and apply;
  - record the colour dials' internal names and compare `GetLightIntensity` with the intensity dial.

  They finish by applying the original snapshot in replace mode, which restores the scene.

## Documentation

- A new guide, `guides/lights-and-cameras.md`: rigs, snapshots, merge vs replace, and why apply isn't atomic.
- Concept-map rows in `guides/concepts.md` (above), and a Lights & Cameras section in `guides/idiomatic-api.cheatmd`.
- Moduledocs with function groups: *Properties*, *Snapshots*, *Escape hatch*.
- A `{: .warning}` that replace mode deletes lights.
- No Livebook this phase.

## PR split (stacked)

The plan (`plans/phase3b1-lights-cameras.md`) refines this into eight PRs:
1. Fake Poser.
2. `Batch` struct arguments, which `point_at` and `SetCurrentCamera` need, since the bridge already resolves `{:result, n}` in arguments.
3. The structs and the `Scene` additions.
4. `get/set` and `point_at`.
5. `create` and `delete`.
6. Snapshots.
7. `apply`.
8. The live tests and docs.

## Verification

- `mix test`, the Python tests and `mix test --only poser` pass.
- `mix compile --warnings-as-errors` and `mix format --check-formatted` are clean, and Credo is clean.
- `mix docs` builds with no warnings.
- `plans/phase3b1-findings.md` records the live timings.

## Out of scope for 3b-1

- Materials and shader trees (3b-2), and render and IO (3c).
- Keyframes in snapshots, and animated rigs (Phase 6).
- Storing snapshots (JSON, `jsonb`), preset parameters and catalogue asset references (the catalogue phase).
- Library light and camera files (`LoadLibraryLight`, `SaveLibraryLight`, …), which belong to 3c IO.
- Add-on protocol changes. None are needed: everything uses the existing batch, `invoke` and lookup ops.
