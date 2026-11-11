# Phase 3b-1: Lights and Cameras Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add `ExPoser.Light` and `ExPoser.Camera` to the idiomatic layer. They cover listing, get and set (dials plus the method-only light properties, including a `:color` convenience), the current camera, `point_at`, light create and delete, and rig snapshots applied back with `mode: :merge | :replace`.

**Architecture:** `%Light{actor}` and `%Camera{actor}` wrap a 3a `%Actor{}` with `figure: nil`. `ExPoser.Ref.path/1` delegates to the actor, so every op runs through the existing `ExPoser.Batch` (lookups in the same request, no handles kept). Two infrastructure additions make this possible:
- `Batch` arguments may be structs, resolved to `{:result, n}` in the same request, which `point_at` and `SetCurrentCamera` need.
- `Ref.children_many/4` lists children of many parents in two round trips, so a snapshot's cost doesn't grow with the number of lights.

**Tech Stack:** Elixir 1.18+, ExUnit with `PoserTest.ClientCase` (standalone Python bridge on `python/fake_poser.py`), Python 3 `unittest` for Fake Poser, and jj for commits.

**Spec:** `plans/phase3b1-lights-cameras-design.md`

## Global Constraints

- Every public function returns `{:ok, _} | {:error, %ExPoser.Error{}}` and has a `!` variant that raises (via `Ref.unwrap!/1`).
- Opts are validated with `Keyword.validate!`: `:server` and `:timeout` everywhere, `:frame` on snapshot, apply and get/set, and `:mode` on `Light.apply` only.
- Structs never hold a `%ExPoser.Handle{}`. Every test ends with `assert_no_handles(c)` (`Client.stats` reports `"handles" => 0`).
- Light types: `:infinite` 0, `:spot` 1, `:point` 2, `:image` 3, `:area` 4. Attenuation: `:poser` 0, `:inverse_linear` 1, `:inverse_square` 2. An unknown code read from Poser stays an integer.
- Colour dials are parm codes 23, 24 and 25 (`kParmCodeKDRED`, `KDGREEN`, `KDBLUE`), and intensity is 29 (`kParmCodeKDINTENSITY`). `:intensity` is not a property.
- An unknown property atom or enum atom raises `ArgumentError`. A wrong struct raises `FunctionClauseError`.
- Module layout (the user's rule): attributes, aliases, struct and types first; then every `def` A–Z by name then arity; then `@impl` callbacks A–Z; then every `defp` A–Z. An anonymous function bound to a variable spans several lines.
- Each idiomatic public function gets `@doc group:` and an *Examples* section. Doctests are used where no Poser is needed.
- Checks for each task: `mix format --check-formatted`, `mix compile --warnings-as-errors`, `mix credo --strict` on the changed files, `mix test`, and `python3 -m unittest discover python/tests`.
- Commits use `jj commit -m "<message>"` with no Claude credit. Bookmarks and pushes happen only at the PR boundaries below, after the user's OK.

## Review Focus

1. **Duplicate names in the rig itself** (two snapshots both named "Fill"): `Light.apply` raises `ArgumentError` before any request, in both modes. The test goes in Task 8.
2. **An empty rig:** merge is a no-op returning `{:ok, %{skipped: []}}`, and replace deletes every light. The tests go in Task 8.
3. **Snapshotting at one frame and applying at another:** the values land at the apply frame, and the scene's current frame is unchanged afterwards. The test goes in Task 8.
4. **An unknown type code round trip:** a snapshot holding `type: 7` applies `SetLightType(7)` unchanged. The test goes in Task 8.
5. **Handles from a create when a later step fails:** `Light.create(%{type: :laser})` raises before creating anything, and a create whose later set fails still leaves `handles == 0`. The test goes in Task 6.

## PR boundaries (stacked, each on the one before)

| PR | Tasks | Bookmark |
|---|---|---|
| 1 | Task 1 | `3b1-1-fake-poser` |
| 2 | Task 2 | `3b1-2-batch-ref-args` |
| 3 | Task 3 | `3b1-3-structs-scene` |
| 4 | Tasks 4–5 | `3b1-4-get-set` |
| 5 | Task 6 | `3b1-5-create-delete` |
| 6 | Task 7 | `3b1-6-snapshots` |
| 7 | Task 8 | `3b1-7-apply` |
| 8 | Tasks 9–10 | `3b1-8-live-docs` |

---

### Task 1: Fake Poser lights and cameras

**Files:**
- Modify: `python/fake_poser.py`
- Test: `python/tests/test_fake_poser.py`
- Modify: `test/ex_poser/scene_test.exs`, wherever `Scene.actors` expectations change because lights and cameras are now scene actors

**Interfaces:**
- Produces, as the seed scene: lights `Key` (internal `light 1`, spot), `Fill` (`light 2`, infinite) and `Fill` (`light 3`, point); cameras `Main Camera` (`MAIN_CAMERA`) and `Aux Camera` (`AUX_CAMERA`). The current camera is `MAIN_CAMERA`. All of them are in `SceneType.Actors()` with `IsBodyPart() == 0`.
- Each light has dials `xTran`, `KdRed`, `KdGreen`, `KdBlue` and `KdIntensity`, with parm codes 1, 23, 24, 25 and 29, plus every getter and setter from the spec's property table, storing values with these defaults: on 1, preview 1, attenuation 0, shadow 1, casts_shadows 1, ray_trace_shadows 0, the floats 0.0, shadow_samples 0, ambient_occlusion 0. Each camera has dials `xTran` and `Focal` (codes 1 and 4).
- `ActorType`: `IsLight()`, `IsCamera()`, `ParameterByCode(code)` (None on a miss), `PointAt(target)` (stores the target, read back through `PointAtTarget()`, which exists only in the fake), and `Delete()`, which removes the actor from its scene.
- `SceneType`: `Lights()`, `Cameras()`, `CurrentCamera()`, `SetCurrentCamera(actor)` and `CreateLight()`. `CreateLight()` appends a spot light named `Light N`, internal `light N`, where N is the next free number.
- `ParmType.__init__` gains `code=0`, and `ParmType.Code()` returns it.

- [ ] **Step 1: Write the failing Python tests** in `python/tests/test_fake_poser.py`:
  - `test_lights_and_cameras_seeded`: the light names are `["Key", "Fill", "Fill"]`, the camera internal names are `["MAIN_CAMERA", "AUX_CAMERA"]`, and `CurrentCamera().InternalName() == "MAIN_CAMERA"`;
  - `test_light_properties_round_trip`: `SetLightType(4)` then `LightType() == 4`, and the same for `SetShadowSamples(8)`;
  - `test_parameter_by_code`: `ParameterByCode(23).InternalName() == "kdred"`, and `ParameterByCode(999) is None`;
  - `test_create_and_delete_light`: `CreateLight()` returns a light with `LightType() == 1` and `Name() == "Light 4"`; after `Delete()` it is in neither `Lights()` nor `Actors()`;
  - `test_set_current_camera`, `test_point_at`.
- [ ] **Step 2: Run the tests and confirm they fail.** Run `python3 -m unittest python.tests.test_fake_poser -v`. Expected: the new tests fail with `AttributeError`.
- [ ] **Step 3: Implement the interfaces above in `python/fake_poser.py`.** Lights and cameras are `ActorType(body_part=False)` instances with a `kind` of `"light"` or `"camera"`. Light properties live in a dict on the instance, and their getter and setter methods are explicit `def`s, because the strict policy lists real method names.
- [ ] **Step 4: Run the Python tests, then `mix test`, and confirm they pass.** Fix any `scene_test.exs` and `actor_test.exs` expectations that list scene actors (the lights and cameras now appear after `Ball`). Expected: all tests pass.
- [ ] **Step 5: Commit** with `jj commit -m "Fake Poser: lights, cameras, ParameterByCode, CreateLight and Delete"`.

### Task 2: Struct arguments in `Batch`

**Files:**
- Modify: `lib/ex_poser/batch/compiler.ex`, `lib/ex_poser/batch.ex` (the moduledoc and the `call/5` doc)
- Test: `test/ex_poser/batch_test.exs`

**Interfaces:**
- Consumes: `Ref.path/1`.
- Produces: in `Batch.call(b, ref, method, args, opts)`, any element of `args` for which `ExPoser.Ref.ref?/1` is true is compiled into lookup ops (sharing the path memo with the targets) and sent as `{:result, i}`. Add `@spec ref?(term()) :: boolean()` to `lib/ex_poser/ref.ex`; it's true for `%Figure{}`, `%Actor{}` and `%Parameter{}`, and Task 3 adds Light and Camera. Only top-level argument elements are resolved, not nested ones.

- [ ] **Step 1: Write the failing tests** in `batch_test.exs`:
  - `"a struct argument is resolved in the same request"`: with `aux = %Actor{figure: nil, internal: "AUX_CAMERA", name: "Aux Camera"}`, `Batch.new() |> Batch.call(:scene, "SetCurrentCamera", [aux]) |> Batch.call(:scene, "CurrentCamera", [])` is run, and the second result's `InternalName`, read through `ExPoser.Api.ActorType.internal_name/2`, is `"AUX_CAMERA"`. Release the handle, then `assert_no_handles`.
  - `"a missing struct argument is not_found"`: an argument with internal `"nope"` returns `{:error, %Error{kind: :not_found, details: %{path: [actor: "nope"], index: 0}}}`.
  - `"argument lookups count toward chunk size"`: with `chunk: 3`, a batch of two ops that each take a struct argument splits into two chunks and still returns both results.
- [ ] **Step 2: Run `mix test test/ex_poser/batch_test.exs` and confirm the new tests fail.** Expected: a FAIL, because the struct reaches the wire unresolved and gives a `bad_request` error.
- [ ] **Step 3: Implement `Ref.ref?/1` and the argument resolution in `Compiler`.** In `place`, resolve each struct argument's path the same way as the target's (the same memo and the same cost accounting), then substitute `{:result, memo[path]}`. A missing-argument error maps to the caller's op index exactly as a missing target does.
- [ ] **Step 4: Run `mix test` and confirm it passes.** Expected: all tests pass.
- [ ] **Step 5: Commit** with `jj commit -m "Batch: resolve struct arguments to in-request lookups"`.

### Task 3: `Light` and `Camera` structs, and the `Scene` additions

**Files:**
- Create: `lib/ex_poser/light.ex`, `lib/ex_poser/camera.ex` (only the struct, the type, `Inspect` and `handle/2` for now)
- Modify: `lib/ex_poser/ref.ex` (`path/1` and `ref?/1` clauses, the `ref` type), `lib/ex_poser/scene.ex`
- Test: `test/ex_poser/light_test.exs`, `test/ex_poser/camera_test.exs`, `test/ex_poser/scene_test.exs`

**Interfaces:**
- Produces:
  - `%ExPoser.Light{actor: Actor.t()}` and `%ExPoser.Camera{actor: Actor.t()}`, each with `@type t`. `Inspect` prints `#ExPoser.Light<Key>` (the actor's display name).
  - `Ref.path(%Light{actor: a})` and `Ref.path(%Camera{actor: a})` return `Ref.path(a)`. `Ref.ref?/1` and the `Ref.ref` type gain both, so `Batch.call/get/set` accept them as targets and arguments.
  - `Scene.lights(opts) :: {:ok, [Light.t()]}`, `Scene.light(name, opts)`, `Scene.cameras(opts)`, `Scene.camera(name, opts)`, `Scene.current_camera(opts) :: {:ok, Camera.t()}` and `Scene.set_current_camera(camera, opts) :: {:ok, :ok}`, each with a `!` variant.
  - `Light.handle(light, opts)` and `Camera.handle(camera, opts)` delegate to `Actor.handle/2`.
- `light/2` and `camera/2` reuse `Ref.lookup/8`. The list method is `"Lights"` or `"Cameras"`, the extra is `["IsLight"]` or `["IsCamera"]`, and `keep` requires it to be truthy, so a name that resolves to a non-light is `:not_found`.
- `current_camera/1` sends one raw `Client.batch`: `Scene`, `CurrentCamera`, then `InternalName` and `Name` on `{:result, 1}`. It releases the returned handles.

- [ ] **Step 1: Write the failing tests:**
  - `Scene.lights` returns three `%Light{}`s, with `"light 1"` first;
  - `Scene.light("Key")` and `Scene.light("light 2")` find their lights;
  - `Scene.light("Fill")` gives `:ambiguous` with two matches;
  - `Scene.light("Ball")` gives `:not_found`;
  - `Scene.cameras`, `Scene.camera("Main Camera")`;
  - `current_camera` returns `MAIN_CAMERA`; after `set_current_camera(aux)`, `current_camera` returns `AUX_CAMERA`;
  - a doctest of `inspect(%Light{...})` returns `"#ExPoser.Light<Key>"`;
  - `Ref.path(%Light{actor: %Actor{figure: nil, internal: "light 1"}})` returns `[actor: "light 1"]`;
  - the `!` variants;
  - `assert_no_handles` in each test.
- [ ] **Step 2: Run them and confirm they fail.** Run `mix test test/ex_poser/light_test.exs test/ex_poser/camera_test.exs test/ex_poser/scene_test.exs`. Expected: a compile error or undefined function.
- [ ] **Step 3: Implement the interfaces above.** Put the `Scene` functions under `@doc group: "Lights and cameras"`.
- [ ] **Step 4: Run `mix test` and confirm it passes.**
- [ ] **Step 5: Commit** with `jj commit -m "Light and Camera structs; Scene lights, cameras and current camera"`.

### Task 4: Light properties: `get` and `set`, including `:color`

**Files:**
- Modify: `lib/ex_poser/light.ex`
- Test: `test/ex_poser/light_test.exs`

**Interfaces:**
- Produces:
  - `@props`, a map from atom to `{getter, setter}` holding the 16 atoms of the spec's property table (with no `:intensity`; `:color` is handled separately), and `@doc false def props/0`, which returns it for tests.
  - `Light.get(light, key_or_keys, opts)`: a string key reads a dial, an atom key reads a property, `:color` returns `{r, g, b}`, and a list of keys returns a map from each key to its value. `:type` and `:attenuation` decode to atoms (or stay as integers).
  - `Light.set(light, key, value, opts)` and `Light.set(light, %{key => value}, opts)` return `{:ok, :ok}`. Atoms for `:type` and `:attenuation` are encoded, and integers pass through.
  - Everything runs in one `Batch`: properties as `Batch.call(b, light, getter_or_setter, args)`, dials as `Batch.get` and `Batch.set` on `%Parameter{actor: light.actor, internal: name}`.
  - `:color` first resolves the three KD dials' internal names in one raw `Client.batch` (`Scene`, `ActorByInternalName`, then `ParameterByCode` 23, 24 and 25, then `InternalName` on each; release the handles). It then treats them as ordinary dials in the main `Batch`, so `frame:` works. That makes two requests when `:color` is among the keys, and one otherwise.
- [ ] **Step 1: Write the failing tests:**
  - `"props table names exist in priv/poser_api.json"`: every getter and setter in `Light.props()` is a name in `classes["ActorType"]["methods"]` of `priv/poser_api.json` (read with `JSON.decode!/1`);
  - `get(key, :type)` returns `:spot`, and `get(fill2, :type)` returns `:infinite`;
  - `set(key, %{type: :area, shadow_samples: 8, "xTran" => 0.5})` then `get(key, [:type, :shadow_samples, "xTran"])` returns `%{type: :area, shadow_samples: 8, "xTran" => 0.5}`;
  - `set(key, :color, {1.0, 0.5, 0.25})` then `get(key, :color)` returns `{1.0, 0.5, 0.25}`;
  - `set(key, %{shaddow: true})` raises `ArgumentError`, and so does `set(key, :type, :laser)`;
  - `Light.set(camera_struct, :on, 1)` raises `FunctionClauseError`;
  - with `frame: 3`, a dial is set at frame 3 and the scene's frame is unchanged;
  - `assert_no_handles`.
- [ ] **Step 2: Run `mix test test/ex_poser/light_test.exs` and confirm the new tests fail.**
- [ ] **Step 3: Implement `get/3` and `set/3,4` in `lib/ex_poser/light.ex`,** with the `!` variants, `@doc group: "Properties"` and examples.
- [ ] **Step 4: Run `mix test` and confirm it passes.**
- [ ] **Step 5: Commit** with `jj commit -m "Light.get/set: dials, method properties and :color"`.

### Task 5: `Camera.get/set` and `point_at` for both

**Files:**
- Modify: `lib/ex_poser/camera.ex`, `lib/ex_poser/light.ex`
- Test: `test/ex_poser/camera_test.exs`, `test/ex_poser/light_test.exs`

**Interfaces:**
- Consumes: the Task 2 struct arguments, and Task 4's dial handling. Reuse it: move the shared dial get/set code into `@doc false` helpers in `Light`, or a small internal module, rather than copying it.
- Produces: `Camera.get(camera, name_or_names, opts)` and `Camera.set(camera, name_or_map, value_or_opts)`, which take dials only (a non-string key raises `ArgumentError`). `Light.point_at(light, target, opts)` and `Camera.point_at(camera, target, opts)` return `{:ok, :ok}`; the target is any struct `Ref.ref?/1` accepts, or `nil` to clear it.
- [ ] **Step 1: Write the failing tests:**
  - `Camera.set(main, "Focal", 50.0)` then `Camera.get(main, "Focal")` returns `50.0`;
  - `Camera.get(main, :on)` raises `ArgumentError`;
  - `Light.point_at(key, hip_actor)`, then the fake's `PointAtTarget` read through `ExPoser.Api.ActorType` on `Light.handle` is the hip; release it;
  - `Camera.point_at(main, key_light)`;
  - `assert_no_handles`.
- [ ] **Step 2: Run the tests and confirm they fail.**
- [ ] **Step 3: Implement the interfaces above,** with the `!` variants.
- [ ] **Step 4: Run `mix test` and confirm it passes.**
- [ ] **Step 5: Commit** with `jj commit -m "Camera.get/set; point_at for lights and cameras"`.

### Task 6: `Light.create` and `Light.delete`

**Files:**
- Modify: `lib/ex_poser/light.ex`
- Test: `test/ex_poser/light_test.exs`

**Interfaces:**
- Produces:
  - `Light.create(opts)` and `Light.create(attrs, opts)` return `{:ok, Light.t()}`. `attrs` is a map that may hold `:name` plus any keys `set/3` accepts.
  - Step 1 is one raw `Client.batch` (`Scene`, `CreateLight`, `SetName` if `:name` is given, `InternalName`, `Name`) that releases the handle. Step 2, when there are any remaining attrs, is `set/3` on the new struct.
  - `attrs` is validated (property atoms, enum atoms) before step 1, so an invalid attr creates nothing.
  - `Light.delete(light, opts)` returns `{:ok, :ok}`, via `Batch.call(light, "Delete", [])`.
- [ ] **Step 1: Write the failing tests:**
  - `create()` returns `%Light{}` with type `:spot`;
  - `create(%{name: "Rim", type: :point, color: {0.2, 0.4, 1.0}})`, then `Scene.light("Rim")`, then `get(rim, [:type, :color])` matches;
  - `create(%{type: :laser})` raises `ArgumentError`, and `Scene.lights` is still 3 (Review Focus 5);
  - `delete(rim)`, then `Scene.light("Rim")` is `:not_found`;
  - `assert_no_handles`.
- [ ] **Step 2: Run the tests and confirm they fail.**
- [ ] **Step 3: Implement `create/1,2` and `delete/2`,** with the `!` variants. Use `@doc group: "Create and delete"`.
- [ ] **Step 4: Run `mix test` and confirm it passes.**
- [ ] **Step 5: Commit** with `jj commit -m "Light.create and Light.delete"`.

### Task 7: Snapshots

**Files:**
- Create: `lib/ex_poser/light/snapshot.ex`, `lib/ex_poser/camera/snapshot.ex`
- Modify: `lib/ex_poser/ref.ex` (`children_many/4`), `lib/ex_poser/light.ex`, `lib/ex_poser/camera.ex`
- Test: `test/ex_poser/ref_test.exs`, `test/ex_poser/light_test.exs`, `test/ex_poser/camera_test.exs`

**Interfaces:**
- Produces:
  - `%Light.Snapshot{name: String.t(), type: atom() | integer(), dials: %{String.t() => number()}, props: %{atom() => term()}}`, where `props` holds every table property except `:type`. `%Camera.Snapshot{name, dials}`. Both get `@type t` and `Inspect` from the default derive.
  - `Ref.children_many(parents, list_method, extra, opts) :: {:ok, [[row]]}`: one `Batch` calls `list_method` on every parent (one round trip), then one raw read of `InternalName`, `Name` and the extras on every child (a second). The result is one row list per parent, in order, and every handle is released. `Ref.children/4` becomes `children_many([parent], …)`.
  - `Light.snapshot(light, opts)`, `Light.snapshot_all(opts)`, `Camera.snapshot(camera, opts)` and `Camera.snapshot_all(opts)`; opts are `:server`, `:timeout` and `:frame`. Each takes a fixed number of round trips: list (2, for `snapshot_all`), dial names via `children_many` (2), then one `Batch` of property calls and `Batch.get(parm, frame:)`.
- [ ] **Step 1: Write the failing tests:**
  - `children_many([light1, light2], "Parameters", [], opts)` returns two row lists of 5 rows each;
  - `snapshot(key)` returns `%Light.Snapshot{name: "Key", type: :spot, dials: %{"xtran" => _, "kdred" => _, ...}, props: %{on: 1, shadow_samples: 0, ...}}` with exactly the 15 non-type property keys;
  - `snapshot_all()` returns 3 snapshots;
  - after a dial is set at frame 2, `snapshot(key, frame: 2)` sees the frame-2 value, and the scene frame is unchanged;
  - `Camera.snapshot_all()` returns 2;
  - a round-trip-count test: `Client.stats` request counts are equal for `snapshot_all` with 3 lights and with 4 (after `create`);
  - `assert_no_handles`.
- [ ] **Step 2: Run the tests and confirm they fail.**
- [ ] **Step 3: Implement the interfaces above,** with the `!` variants and `@doc group: "Snapshots"`.
- [ ] **Step 4: Run `mix test` and confirm it passes.**
- [ ] **Step 5: Commit** with `jj commit -m "Light and camera snapshots; Ref.children_many"`.

### Task 8: `apply`

**Files:**
- Modify: `lib/ex_poser/light.ex`, `lib/ex_poser/camera.ex`
- Test: `test/ex_poser/light_test.exs`, `test/ex_poser/camera_test.exs`

**Interfaces:**
- Consumes: `Scene.lights` and `Scene.cameras`, `Ref.children_many/4`, the raw create step from Task 6 (factored into a `@doc false` helper that creates N lights in one request), and `Batch`.
- Produces:
  - `Light.apply(snapshot_or_list, opts) :: {:ok, %{skipped: [{String.t(), String.t()}]}}`, with opts `:server`, `:timeout`, `:frame` and `mode: :merge | :replace` (default `:merge`).
  - `Camera.apply(snapshot_or_list, opts)` has the same result and no `:mode`.
  - The order of work:
    1. Validate (duplicate snapshot names raise `ArgumentError`).
    2. List the lights.
    3. Match by display name (merge), or delete them all (replace, which goes in the create request).
    4. Create the missing lights in one request.
    5. List dial names for every target with `children_many`.
    6. Send one mutate `Batch`: for each light, the type, then the properties, then the dials that exist. Snapshot dials missing on the target go into `skipped`.
- [ ] **Step 1: Write the failing tests:**
  - merge, idempotent: `s = snapshot_all()`, `apply(s)` twice, and `Scene.lights` still holds 3 with values unchanged;
  - merge creates: `apply([%Light.Snapshot{name: "Rim", type: :point, dials: %{}, props: %{}}])` brings the lights to 4, and `Rim` is `:point`;
  - merge updates by name: change `Key`'s snapshot `props.shadow_samples` to 8, apply, then `get(key, :shadow_samples)` is 8;
  - merge onto an ambiguous name: a snapshot named `"Fill"` returns `:ambiguous`, and nothing changes (compare `snapshot_all` before and after);
  - replace: `apply([rim_snapshot], mode: :replace)` leaves exactly `["Rim"]`;
  - skipped: a snapshot with dial `"nope"` returns `{:ok, %{skipped: [{"Key", "nope"}]}}`;
  - duplicate names raise `ArgumentError` (Review Focus 1);
  - empty merge is `{:ok, %{skipped: []}}`, and empty replace leaves no lights (Review Focus 2);
  - snapshot at frame 0, apply with `frame: 4`: the values are at frame 4 and the current frame is unchanged (Review Focus 3);
  - `type: 7` round trips (Review Focus 4);
  - `Camera.apply` of a snapshot named `"Nope"` returns `:not_found`, and nothing changes;
  - `Camera.apply` round trip;
  - `assert_no_handles`.
- [ ] **Step 2: Run the tests and confirm they fail.**
- [ ] **Step 3: Implement `apply/2`,** with the `!` variants and `@doc group: "Snapshots"`.
- [ ] **Step 4: Run `mix test` and confirm it passes.**
- [ ] **Step 5: Commit** with `jj commit -m "Light.apply (merge and replace) and Camera.apply"`.

### Task 9: Live tests

**Files:**
- Modify: `test/live/live_poser_test.exs`
- Create: `plans/phase3b1-findings.md`

**Interfaces:**
- Consumes: everything above.
- [ ] **Step 1: Add a `describe "lights and cameras"` block** tagged `:poser`. `setup` takes `Light.snapshot_all!()` and `Scene.current_camera!()`, and `on_exit` runs `Light.apply!(orig, mode: :replace)` and `Scene.set_current_camera!(cam)`. The tests:
  - create `"ExPoser Test"` with `type: :point`, set colour and shadow samples, snapshot it, and apply it twice in merge mode; the light count goes up by exactly 1;
  - apply in replace mode with only the test light, then check that `Scene.lights` holds 1;
  - switch the current camera and switch it back;
  - time `snapshot_all` and `apply` (`IO.puts` the milliseconds);
  - print the colour dials' internal names (`Light.snapshot` dial keys), and `GetLightIntensity` against the `KdIntensity` dial value through `ExPoser.Api`.
- [ ] **Step 2: Run `mix compile --warnings-as-errors` and `mix test`** (the live tests are excluded by default). Expected: all tests pass.
- [ ] **Step 3: Give the user the exact live command,** `mix test --only poser`, and record their pasted output word for word in `plans/phase3b1-findings.md` and in the ledger.
- [ ] **Step 4: Commit** with `jj commit -m "Live tests for lights and cameras; findings"`.

### Task 10: Docs

**Files:**
- Create: `guides/lights-and-cameras.md`
- Modify: `guides/concepts.md` (concept-map rows), `guides/idiomatic-api.cheatmd` (a Lights & Cameras section), `mix.exs` (`extras`, and `groups_for_modules`: `ExPoser.Light`, `ExPoser.Camera` and the two `Snapshot` modules under Idiomatic API), and the moduledocs of `Light` and `Camera`
- [ ] **Step 1: Write the guide:**
  - rigs, and finding lights and cameras;
  - properties versus dials, and `:color`;
  - snapshots: one frame and plain data;
  - merge versus replace, with a `{: .warning}` that replace deletes lights;
  - skipped dials;
  - no rollback, with a `{: .warning}`;
  - round trips, with a `{: .info}` that apply takes a fixed number however big the rig.

  Don't restate function names, and don't explain general Elixir.
- [ ] **Step 2: Add the concept-map rows** from the spec and the cheatsheet section (idiomatic next to `ExPoser.Api`).
- [ ] **Step 3: Run `mix docs` and confirm it builds with no warnings.**
- [ ] **Step 4: Commit** with `jj commit -m "Docs: lights and cameras guide, concept map, cheatsheet"`.
