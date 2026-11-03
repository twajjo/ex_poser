# Phase 3a: idiomatic core (design)

Status: design approved in conversation on 2026-11-02, awaiting review of this spec.
Builds on Phase 2 (`plans/phase2-findings.md`). Overall plan: `plans/elixir-poser-bridge-plan.md`, section 5, Phase 3.

## Intent

| | |
|---|---|
| First use | Animation and posing: find figures and body parts by name, read and set dials, work across frames and keyframes. |
| Lifetimes | Both scripts and iex sessions now, and a long-running supervised app later (Phase 6 live control). References must survive a Poser restart or reconnect. |
| Scope | Full depth eventually for all nine modules in the overall plan, delivered in three sub-phases (below). This spec covers 3a only. |
| Success | Posing code reads like Poser concepts in Elixir terms. A many-dial, many-frame pose costs a few round trips. Nothing goes stale across a reconnect. Lookup handles never leak. The HexDocs teach the model, not just the API. |

### Sequencing
- **3a (this spec):** the name-path core, `Poser.batch`, the `:not_found` and `:ambiguous` errors, `Scene`, `Figure`, `Actor` and `Parameter` in depth, and the documentation structure.
- **3b:** `Poser.Camera`, `Poser.Light` and `Poser.Material`. Cameras and lights are actors with no figure, so they reuse the 3a path and batch machinery. Material paths go actor → material → shader tree → node → input.
- **3c:** `Poser.Render` and `Poser.IO`, including the async render pattern from the risks table, so renders don't stall the bridge.

Each sub-phase gets its own spec and plan.

## Concept map: Poser ↔ Elixir

This table is the backbone of the docs (see Documentation). It must stay accurate as 3b and 3c land.

| Poser | Elixir | Notes |
|---|---|---|
| The open scene, with its single global current frame | `Poser.Scene` functions (no struct; there is one scene) | Poser has one current frame per scene. The Elixir side never leaves it changed: `frame:` sets it, does the work, then restores it. |
| Figure (in the GUI's figure menu, e.g. "Figure 1") | `%Poser.Figure{internal, name}` | `internal` is the key. `name` is the GUI label and can be renamed or repeated. |
| Actor: a body part, prop, camera or light | `%Poser.Actor{figure, internal, name}` | Body parts have `figure` set. Props, cameras and lights have `figure: nil` and are found at scene level. |
| Dial / parameter ("parm" in PoserPython) | `%Poser.Parameter{actor, internal, name}` | Looked up by internal name (`InternalParameter`), e.g. `"xRotate"`, `"Bend"`. |
| Frame number | An integer, starting at 0 as in PoserPython | GUI frame 1 is `frame: 0`. The docs show both numbers wherever a frame appears. |
| Keyframe on a dial | A frame number in `Parameter.keyframes/1` | Phase 6 adds a keyframe DSL; 3a reads, adds and deletes. |
| PoserPython object (`ActorType`, `ParmType`, …) | `%Poser.Handle{}`, which you reach through `handle/1` | A handle is a live, server-side reference that goes stale on reconnect. Idiomatic structs never hold one. |
| One Python main-thread turn | One batch chunk | Poser's UI is busy while a chunk runs, which is why chunks are capped. |
| Python exception | `{:error, %Poser.Error{kind: :python, class, message, traceback}}` | Unchanged from Phase 1. |

## Design

### 1. Modules and functions

| Module | Functions |
|---|---|
| `Poser.Scene` | `frame/1`, `set_frame/2`, `num_frames/1`, `fps/1`, `figures/1`, `figure/2`, `actors/1` (scene-level actors: props, cameras, lights), `actor/2` |
| `Poser.Figure` | `actors/1` (body parts), `actor/2`, `parameter/3` (actor name plus parm name) |
| `Poser.Actor` | `parameters/1`, `parameter/2`, `get/2`, `set/3` (a single name, or a map for several), `values/1` |
| `Poser.Parameter` | `value/2`, `set_value/3`, `min_max/1`, `keyframes/1`, `add_keyframe/2`, `delete_keyframe/2`, `value_at/2` |
| `Poser.Batch`, `Poser.batch/2` | `new/0`, `get/3`, `set/4`, `add_keyframe/3`, `delete_keyframe/3`, `run/2` |
| `Poser.Ref` (internal) | compiles struct paths into batch ops |

Every function has these conventions:
- It returns `{:ok, value} | {:error, %Poser.Error{}}`, and has a `!` variant that raises `Poser.Error`.
- It takes trailing `opts`: `:server` and `:timeout` as in `Poser.Client`, and `:frame` on anything time-based.
- `handle/1` on `Figure`, `Actor` and `Parameter` returns a live `%Poser.Handle{}` for `Poser.Api`. The caller releases it.

On top of that, each struct implements `Inspect` (`#Poser.Parameter<Figure 1/lForeArm/Bend>`), and the structs are plain data: comparable, storable, and safe to send between processes.

### 2. Resolution

- Each struct compiles to lookup ops that run in the same batch as the operation:
  1. `{:call, "Scene", []}`
  2. `{:invoke, {:result, 0}, "FigureByInternalName", [fig]}`
  3. `{:invoke, {:result, 1}, "ActorByInternalName", [actor]}`
  4. `{:invoke, {:result, 2}, "InternalParameter", [parm]}`

  Then comes the operation, e.g. `{:invoke, {:result, 3}, "SetValue", [30.0]}`.
- Scene-level actors use `SceneType.ActorByInternalName` and skip the figure step.
- No handle is ever cached, so nothing goes stale.
- **Lookups by name** (`Scene.figure/2`, `Scene.actor/2`, `Figure.actor/2`, `Actor.parameter/2`) accept an internal name first, then a display name.
  - Exactly one display-name match resolves to that object.
  - More than one returns `%Poser.Error{kind: :ambiguous, details: %{matches: [structs]}}`.
  - None returns `%Poser.Error{kind: :not_found, details: %{path: …}}`.
- **To verify live (first task):** whether `FigureByInternalName`, `ActorByInternalName` and `InternalParameter` raise or return `None` for a missing name, and whether `FigureByInternalName` really takes the internal name (its docstring says it takes the GUI name). Both outcomes map to `:not_found`. If it takes the GUI name, the figure step switches to listing figures and matching `InternalName`.

### 3. Batching

```elixir
Poser.batch(fn b ->
  b
  |> Poser.Batch.set(bend, 30.0, frame: 5)
  |> Poser.Batch.set(twist, -10.0, frame: 5)
  |> Poser.Batch.get(bend, frame: 12)
end)
#=> {:ok, [:ok, :ok, 0.0]}
```

- **One-op batches:** every single-object function is a one-op batch, so single calls and batches behave identically.
- **Shared lookups:** within a chunk, each path prefix resolves once. 500 sets on one dial share one lookup chain, and a figure's 80 actors share one scene lookup and one figure lookup.
- **Frames:**
  - The batch reads the current frame first.
  - An op without `frame:` runs at the batch's original frame, never at the frame a previous op left behind.
  - `SetFrame(n)` is emitted only when an op's frame (its `frame:` or the original) differs from the previous op's frame.
  - The original frame is restored as the last op of the last chunk, and again as a separate request if the batch failed.
  - Ops are never reordered, so the caller controls how often the frame changes.
- **Chunks:** at most `chunk:` ops each (default 2 000, counting lookups). Each chunk does its own lookups.
- **Results:** one entry per op the caller added, in order. Setters give `:ok`, and lookup and housekeeping ops are left out.
- **Cleanup:** every handle a chunk creates (all lookup results) is released after the chunk, including a failed chunk's partial results.
- **No rollback.** Poser has no transactions, so ops before a failure stay applied. This is documented on `Poser.batch/2` with a warning admonition.

### 4. Listing and values

- **Listings take two requests:** `Scene.figures/1`, `Scene.actors/1`, `Figure.actors/1` and `Actor.parameters/1`.
  1. A batch resolves the parent and fetches the handle list.
  2. A second batch reads `InternalName` and `Name` for each handle.

  Then everything is released, and you get structs back.
- `Actor.values/1` returns `%{internal_name => float}` in one listing plus one read batch.
- `Actor.get/2` and `Actor.set/3` take internal parm names only, so each is a single batch with no fallback lookup. `Actor.parameter/2` accepts either kind of name.
- `Actor.set/3` with a map writes several dials in one batch.
- `Parameter.value/2` returns a float. `set_value/3` takes a number, and integers are converted to floats.
- `min_max/1` returns `{min, max}`.
- `keyframes/1` steps `NextKeyFrame` from frame 0 until `nil`, one request per key. The docs say so.
- `value_at(p, n)` is `value(p, frame: n)`.

### 5. Errors

`%Poser.Error{}` gains two kinds:
- `:not_found`: `details.path` is the struct path that failed to resolve, and `details.op` is the caller's op index in a batch.
- `:ambiguous`: `details.matches` lists the matching structs.

A Python error inside a batch keeps its class, message and traceback, and gains `details.op` (the caller's index, not the wire index).

## Testing

- **Fake Poser** (`python/fake_poser.py`) gains:
  - `FigureByInternalName` and `ActorByInternalName` at scene and figure level;
  - `InternalParameter`;
  - parm keyframes (`AddKeyFrame`, `DeleteKeyFrame`, `NextKeyFrame`);
  - values stored per frame;
  - two figures with the same display name.

  Python tests cover the additions.
- **Elixir unit tests** run against the standalone server, using `PoserTest.ClientCase`:
  - `Poser.Ref` path compilation and shared lookups (pure);
  - chunk boundaries;
  - the frame is restored after success and after failure;
  - error mapping to `details.op`;
  - `:not_found` and `:ambiguous`;
  - every public function and its `!` variant;
  - `Client.stats` reports `handles == 0` after every operation, including failed batches.
- **Live tests** (`@tag :poser`, 9-figure scene). Each one leaves the scene as it found it:
  - list the figures, and read every dial on one body part;
  - set a dial at a frame, read it back, then restore both the value and the frame;
  - time a 2 000-op batch;
  - pin the behaviour for missing names (the Resolution item above).

## Documentation

Docs must map Poser concepts onto Elixir ones (the concept map above) and must not state the obvious. Don't write docs that restate a function's name, and don't explain general Elixir.

### Teaching order
Each sub-phase updates this list:
1. **You name things; you don't hold them.** Structs are paths, so they survive restarts.
2. **Every call is a batch.** Batching by hand is "more of the same".
3. **Time is an option.** `frame:` reads or writes at a frame and restores Poser's current frame.
4. **Failures are values,** and there is no rollback.
5. **There's always a way down:** `handle/1` and `Poser.Api`.

### ExDoc
`ex_doc` becomes a dev dependency in 3a. The sidebar is organised like this:

| Group | Pages |
|---|---|
| Introduction | `guides/getting-started.md` (connect, find a figure, bend an arm), `guides/concepts.md` (the concept map and the teaching order, one short example each) |
| Guides | `guides/posing.md`, `guides/frames-and-keyframes.md`, `guides/batching.md`, `guides/errors.md`, `guides/generated-api.md` (moved out of `setup.md`) |
| Cheatsheets | `guides/idiomatic-api.cheatmd`: tasks shown side by side, idiomatic versus `Poser.Api` |
| Livebook | `guides/posing.livemd`: a runnable tour against a live Poser |
| Reference | `guides/setup.md`, `guides/limitations.md` |

Module documentation follows these rules:
- **Module groups:** `groups_for_modules` uses Idiomatic API, Errors, Generated API (`Poser.Api.*`, `Poser.Const`), Connection (`Client`, `Session`, `Transport*`, `Events`) and Internals.
- **Moduledocs:** each idiomatic `@moduledoc` covers the Poser concept the module represents, how to obtain one, common tasks, and links to the guides.
- **Function groups:** for example, `Parameter` has *Values*, *Keyframes* and *Escape hatch*.
- **Examples:** every public function has an *Examples* section. The parts that don't need Poser are doctests (paths, `inspect`, building a batch). Examples that need Poser are plain iex sessions.
- **Admonitions:** "no rollback" is a `{: .warning}`, and "listings take two requests" is a `{: .info}`.

## Verification
- `mix test`, the Python tests and `mix test --only poser` pass.
- `mix compile --warnings-as-errors` and `mix format --check-formatted` (on the files that changed) are clean.
- `mix docs` builds with no warnings.
- `plans/phase3a-findings.md` records the live timings and the missing-name behaviour.

## Out of scope for 3a
- Cameras, lights and materials (3b); render and IO (3c).
- Events (Phase 4) and the keyframe DSL or interpolation (Phase 6).
- Caching handles.
- Add-on protocol changes. None are needed: lookups use the existing batch and `{:result, n}` ops.
