# Phase 3a: Idiomatic Core — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Hand-written `Poser.Scene`, `Poser.Figure`, `Poser.Actor` and `Poser.Parameter` modules over name-path structs, a `Poser.batch/2` builder that resolves those paths inside the same wire batch, and HexDocs that teach the model.

**Architecture:**
- The structs hold internal-name paths and never a handle.
- `Poser.Ref` compiles a path into lookup ops.
- `Poser.Batch` turns the caller's ops into chunked `Poser.Client.batch/2` calls. It shares lookups, manages the frame, releases lookup handles, and maps failures back to the caller's op index.
- Every single-object function is a one-op batch.

**Tech Stack:** Elixir 1.20 / OTP 29, the Phase 1 `Poser.Client` (`batch/2` with `{:result, n}` refs). Python 3.7.9 for the fake Poser. ExDoc `~> 0.40` (dev only).

**Spec:** `plans/phase3a-idiomatic-core-design.md`. Read it first; this plan doesn't repeat it.

## Global Constraints

- **Return shape:** every public idiomatic function returns `{:ok, value} | {:error, %Poser.Error{}}`, and has a `!` variant that raises `Poser.Error`.
- **Options:** every function takes trailing `opts`: `:server` and `:timeout` (as in `Poser.Client`), and `:frame` on time-based functions.
- **Path keys are internal names at every level:** figure, actor, parm.
- **Lookup methods:**
  - figures: `SceneType.FigureByInternalName`;
  - body parts: `FigureType.ActorByInternalName`;
  - props, cameras and lights: `SceneType.ActorByInternalName`;
  - parms: `ActorType.InternalParameter`.

  Task 1 can change the figure step.
- **Frames:** numbers start at 0, as in PoserPython. Every batch that uses `frame:` restores the original frame.
- **Chunks:** the default size is 2 000 wire ops, lookups included, and `chunk:` overrides it.
- **No add-on protocol changes.**
- **No handle leaks:** after every idiomatic call, successful or not, `Poser.Client.stats/1` reports `handles == 0`, except for handles the caller explicitly asked for (`handle/1`, and handles in `Poser.Batch.call/5` results).
- **Docs:**
  - Map Poser concepts onto Elixir ones, using the concept map in the spec.
  - Don't state the obvious: no docs that restate a function's name, and no general Elixir explanations.
  - Every public function has an *Examples* section.
- **Authorship:** no Claude credit in commits or files.
- **Version control:** commit with `jj commit <paths> -m "…"`.
- **Commands for the user:** give them as single lines.

## Review Focus

1. **A struct kept across a reconnect.** A `%Poser.Parameter{}` built before the server restarted must still work afterwards, with no `stale_handle`. That's the main promise of name paths. Pinned in Task 4.
2. **An op without `frame:` after one with `frame:`.** It must run at the batch's original frame, not at the frame the previous op left behind. Pinned in Task 4.
3. **A lookup that returns `None` instead of raising.** The next op then fails with an `AttributeError` on `NoneType`. That must surface as `:not_found` with the right path, not as a Python error. Pinned in Task 4: the fake raises for a missing figure and returns `None` for a missing parm.
4. **A failure in chunk 2 of 3.** Chunk 1 stays applied, chunk 3 never runs, the frame is restored, and `handles == 0`. Pinned in Task 4.
5. **Unicode internal names** (the fake's `Ünïcode 頭` actor). Lookups, `inspect` and map keys must all work. Pinned in Task 6.

---

### Task 1: Live probe of the lookup and keyframe methods

Poser is running with the 9-figure scene loaded. The probe runs from a scratch script, and each check leaves the scene as it found it.

**Files:**
- Create: `scripts/phase3a_probe.exs` (kept, so the probe can be rerun on a new Poser version)
- Create: `plans/phase3a-findings.md` (a "Probe" section)

**Interfaces:**
- Produces: the facts that Tasks 2 and 3 encode. Each one is recorded in the findings as one line, with the call that showed it.
  1. **Missing names:** for `SceneType.FigureByInternalName`, `FigureType.ActorByInternalName`, `SceneType.ActorByInternalName` and `ActorType.InternalParameter` called with a name that doesn't exist, does Poser raise (and which class) or return `None`?
  2. **The figure lookup's argument:** does `FigureByInternalName` accept `FigureType.InternalName()`, the GUI name (`Name()`), or both? Test this on a figure whose two names differ, if the scene has one. Otherwise compare the two values and record them.
  3. **The end of the keyframes:** what does `ParmType.NextKeyFrame()` return when no later keyframe exists (`None`, `-1`, or an error)? What does `PrevKeyFrame()` return at frame 0?
  4. **Auto-keying:** does `SetValue(v)` at frame `n` create a keyframe at `n`? Read `NextKeyFrame` from `n - 1` before and after. Then restore the value and delete any key that was added.
  5. **Integer values:** does `SetValue` accept an integer argument?

- [ ] **Step 1:** Write `scripts/phase3a_probe.exs`.
  - Use `Poser.Client.batch/2` and `Poser.Api` directly; the idiomatic layer doesn't exist yet.
  - Pick the first figure, its first body part with a `yRotate` parm, and that parm.
  - Print one `FACT n: …` line per question.
  - Release every handle, then print the result of `Poser.Client.stats/1`.
- [ ] **Step 2:** Run `mix run scripts/phase3a_probe.exs`. Expected: five `FACT` lines, `handles == 0`, and Poser still answering `Poser.Client.ping/1`.
- [ ] **Step 3:** Record the facts in `plans/phase3a-findings.md`.
  - If fact 2 shows `FigureByInternalName` only takes the GUI name, add a line to the findings: "Figure step: list `Figures` and match `InternalName`". Task 3 then uses that variant.
- [ ] **Step 4:** Commit: `jj commit scripts/phase3a_probe.exs plans/phase3a-findings.md -m "Phase 3a probe: lookup misses, figure lookup argument, keyframe ends, auto-keying"`

### Task 2: Fake Poser for the idiomatic layer

**Files:**
- Modify: `python/fake_poser.py`
- Test: `python/tests/test_fake_poser.py` (create)

**Interfaces:**
- Consumes: Task 1's facts.
- Produces: the fake scene the Elixir tests rely on.
  - **Figures:** `"Figure 1"`, as before, with actors `hip`, `chest` and `Ünïcode 頭`. Add a second figure with internal name `"figure 2"` and display name `"Figure 1"`, with actor `head`, so display-name lookups of `"Figure 1"` are ambiguous.
  - **Scene-level actors:** add a prop `"Ball"` (internal `"ball"`, `IsBodyPart() == 0`). Body parts return `IsBodyPart() == 1`.
  - **Constructors:** `FigureType(name, actors, internal=None)` and `ActorType(name, internal=None)`. When `internal` is given, it overrides the `name.lower()` default.
  - **`SceneType.FigureByInternalName(s)`** raises `poser.error`, or follows Task 1's fact 1 if that differs.
  - **`SceneType.ActorByInternalName(s)`** and **`FigureType.ActorByInternalName(s)`** also raise `poser.error`, or follow fact 1.
  - **`ActorType.InternalParameter(s)`** **returns `None`** for a missing name. This deliberately differs from the figure lookup, so the Elixir side handles both, whatever Poser does. Note this in a comment.
  - **Per-frame values:** `ParmType` takes `(name, value, scene_frame)`, where `scene_frame` is a zero-argument callable. `Value()` and `SetValue(v)` use the value keyed at the current frame, falling back to the nearest earlier keyframe, then the initial value. `SetValue` creates or does not create a key, following fact 4.
  - **Keyframe methods:** `ParmType.AddKeyFrame(frame=None)`, `DeleteKeyFrame(frame=None)`, `NextKeyFrame()` and `PrevKeyFrame()`, relative to the current frame, with end values from fact 3.
  - **`ParmType.MinValue()` / `MaxValue()`** return `-180.0` and `180.0`.
  - **`ParmType.InternalName()`** returns the internal name passed in. Existing parms keep `name.lower()`.
  - **`SceneType.FramesPerSecond()`** returns `30`.

- [ ] **Step 1:** Write the failing tests in `python/tests/test_fake_poser.py`:
  - `test_lookup_by_internal_name` covers a hit and the miss behaviour for each lookup.
  - `test_internal_parameter_missing_returns_none`.
  - `test_values_are_per_frame`: set 10.0 at frame 5. Frame 5 reads 10.0, and frame 0 reads the initial value (or follows fact 4).
  - `test_keyframes_walk`: add keys at 3 and 7. `NextKeyFrame` from 0 is 3, from 3 is 7, and from 7 is the end value.
  - `test_duplicate_display_names`: two figures have `Name() == "Figure 1"`.
  - `test_prop_is_not_a_body_part`.
- [ ] **Step 2:** Run `mise exec -- python -m unittest python.tests.test_fake_poser -v` from the repo root (using `-t python -s python/tests`, as in `guides/setup.md`). Expected: FAIL.
- [ ] **Step 3:** Implement the fake changes.
- [ ] **Step 4:** Run the full Python suite (`mise exec -- python -m unittest discover -s python/tests -t python`) and then `mix test`. Expected: PASS.
  - If an existing Elixir test asserted on the old scene contents (actor or figure counts), update the expected value in that test, and say which test and why in the commit message.
- [ ] **Step 5:** Commit: `jj commit python test -m "Fake Poser: internal-name lookups, per-frame values, keyframes, a prop, duplicate figure names"`

### Task 3: Structs, `Poser.Ref` and the new error kinds

**Files:**
- Create: `lib/poser/figure.ex`, `lib/poser/actor.ex` and `lib/poser/parameter.ex`. In this task they hold only `defstruct`, `@type t`, the `Inspect` implementation and a placeholder moduledoc; Tasks 5–7 add the functions.
- Create: `lib/poser/ref.ex`
- Modify: `lib/poser/error.ex`
- Test: `test/poser/ref_test.exs` and `test/poser/error_test.exs` (extend it if it exists)

**Interfaces:**
- Produces:
  - **`%Poser.Figure{internal: String.t(), name: String.t()}`**
  - **`%Poser.Actor{figure: Poser.Figure.t() | nil, internal: String.t(), name: String.t()}`**
  - **`%Poser.Parameter{actor: Poser.Actor.t(), internal: String.t(), name: String.t()}`**
  - **`Inspect` output:**
    - `#Poser.Figure<figure 1>`
    - `#Poser.Actor<figure 1/lforearm>`, or `#Poser.Actor<ball>` for a scene-level actor
    - `#Poser.Parameter<figure 1/lforearm/bend>`

    These use internal names, joined with `/`.
  - **`@type Poser.Ref.ref :: :scene | Poser.Figure.t() | Poser.Actor.t() | Poser.Parameter.t()`**
  - **`Poser.Ref.path(ref) :: [{:figure, String.t()} | {:actor, String.t()} | {:parm, String.t()}]`.** `:scene` gives `[]`.
  - **`Poser.Ref.lookup_op(step, parent_ref_term, scope)`** gives one wire op for one path step. `parent_ref_term` is `{:result, n}`. `scope` is `:scene` or `:figure` and decides which `ActorByInternalName` is used. It is `@doc false`, and Task 4 uses it.
  - **`Poser.Ref.unwrap!({:ok, v} | {:error, e})`** returns `v` or raises `e`. It is `@doc false`, and the `!` variants use it.
  - **`Poser.Error` gains `:not_found` and `:ambiguous`** in `@type kind` and in the moduledoc list.
    - `:not_found` details: `%{path: [step], op: non_neg_integer() | nil, cause: Poser.Error.t() | nil}`.
    - `:ambiguous` details: `%{matches: [struct]}`.
    - `message/1` for `:not_found` renders the path, e.g. `not_found: figure 1/lforearm/bend`.

- [ ] **Step 1:** Write the failing tests:
  - `path/1` for each struct and for `:scene`.
  - `lookup_op/3` gives `{:invoke, {:result, 0}, "FigureByInternalName", ["figure 1"]}` for a figure step. It gives `"ActorByInternalName"` for an actor step under both scopes, and `"InternalParameter"` for a parm step.
  - Doctests in `Poser.Ref` and the structs' moduledocs pin the `inspect` output.
  - `Poser.Error.message/1` for `:not_found`.
  - `unwrap!/1` raises the error it's given.
- [ ] **Step 2:** Run `mix test test/poser/ref_test.exs test/poser/error_test.exs`. Expected: FAIL.
- [ ] **Step 3:** Implement.
  - If Task 1 recorded the "Figure step: list `Figures`" variant, `lookup_op` for a figure step can't be a single op. In that case, make `Poser.Ref.figure_ops/2` return the op list (a `Figures` op followed by a match done client-side in Task 4), and note it in the module doc.
- [ ] **Step 4:** Run the tests. Expected: PASS.
- [ ] **Step 5:** Commit: `jj commit lib test -m "Name-path structs, Poser.Ref, not_found and ambiguous errors"`

### Task 4: `Poser.Batch` and `Poser.batch/2`

**Files:**
- Create: `lib/poser/batch.ex`, and `lib/poser.ex` (only `Poser.batch/2` and a placeholder moduledoc)
- Test: `test/poser/batch_test.exs`

**Interfaces:**
- Consumes: Task 3 (`Poser.Ref.path/1`, `lookup_op/3`, `unwrap!/1`, the error kinds).
- Produces:
  - **`Poser.Batch.new() :: Poser.Batch.t()`**
  - **`Poser.Batch.get(b, Poser.Parameter.t(), opts) :: t()`.** `opts` may contain `:frame`.
  - **`Poser.Batch.set(b, Poser.Parameter.t(), number(), opts) :: t()`.** Integers are sent as floats, unless Task 1 fact 5 makes that unnecessary. Even then, keep the conversion for consistency.
  - **`Poser.Batch.add_keyframe(b, Poser.Parameter.t(), frame :: non_neg_integer()) :: t()`** and **`delete_keyframe/3`**. These pass the frame as the method's argument, so the frame never moves.
  - **`Poser.Batch.call(b, Poser.Ref.ref(), method :: String.t(), args :: list(), opts) :: t()`.** This is the general op. Handles it returns belong to the caller.
  - **`Poser.Batch.run(b, opts) :: {:ok, [term()]} | {:error, Poser.Error.t()}`.** `opts` are `:server`, `:timeout` and `:chunk` (default 2000). Results come back one per caller op, in order: `set`, `add_keyframe` and `delete_keyframe` give `:ok`, and `get` and `call` give the value.
  - **`Poser.batch(fun, opts)`** runs `fun.(Poser.Batch.new())` and passes the result to `Poser.Batch.run/2`.
  - **`Poser.Batch.size(b)`** returns the number of caller ops.
  - **`Poser.Batch.compile(b, chunk: n)`** returns `[{wire_ops, roles}]`. It is `@doc false`, and the tests use it to inspect the wire ops.

**Compiling** happens per chunk:
- Wire op 0 is `{:call, "Scene", []}`.
- When any op in the whole batch has `:frame`, chunk 1's wire op 1 is `{:invoke, {:result, 0}, "Frame", []}`. Its value is the original frame, and later chunks use it as a literal.
- Lookups for a path prefix are emitted on first use and memoised for the rest of the chunk.
- Each op's target frame is its `:frame` or the original frame. `{:invoke, {:result, 0}, "SetFrame", [n]}` is emitted only when that differs from the frame currently set.
- The last chunk ends with `SetFrame(original)` when the frame was ever moved.
- A chunk closes before an op whose lookups plus the op itself would push it past `chunk:`.
- Each chunk keeps a role table, wire index → `{:lookup, path_prefix, caller_op}`, `{:caller, k}` or `{:frame, caller_op}`, used for result and error mapping.

**After each chunk:**
- Release every handle in the lookup results. On failure, release those in the `partial` results instead.
- Caller-op results are returned as they are.

**Mapping a failure** (`{:error, %Poser.Error{kind: :batch_failed, details: %{index: i, cause: c, partial: p}}}`):
- A **lookup** at index `i` gives `:not_found` with that lookup's path prefix, `op:` set to the caller op that needed it, and `cause: c`.
- A **caller op or frame op** whose target is `{:result, j}`, where `p[j]` is `nil` and `j` is a lookup, gives `:not_found` for lookup `j`'s path. This covers Review Focus 3.
- **Any other failure** gives `c`, with `details` merged with `%{op: k}`.

Then:
- If the frame was moved, the frame is restored in a separate `Client.batch` (`[Scene, SetFrame(orig)]`). Its result is ignored.
- Later chunks don't run.
- Errors other than `batch_failed` (`:timeout`, `:disconnected`) pass through unchanged, and the frame restore is still attempted.

- [ ] **Step 1:** Write the failing tests against the standalone server (`PoserTest.ClientCase`). Parms are built directly as struct literals, e.g. `%Poser.Parameter{actor: %Poser.Actor{figure: %Poser.Figure{internal: "figure 1", name: "Figure 1"}, internal: "hip", name: "hip"}, internal: "xtran", name: "xTran"}`.
  - `test "get and set in one batch"`: results are `[:ok, 5.0]`.
  - `test "shared lookups"`: `Poser.Batch.compile(b, chunk: 2000)`, which is `@doc false` and returns `[{wire_ops, roles}]`, shows 100 sets on one parm compiling to `Scene` + 3 lookups + 100 `SetValue` ops in one chunk. The chunking tests use `compile/2` too.
  - `test "frame is restored"`: after a batch with `frame: 5`, `Client.batch([{:call, "Scene", []}, {:invoke, {:result, 0}, "Frame", []}])` reads the original frame. Release the scene handle in the test.
  - `test "op without frame runs at the original frame"`: start at frame 0 with this order: `set(p, 1.0, frame: 5)`, then `get(p)`, then `get(p, frame: 5)`. The results are the frame-0 value, then 1.0 (Review Focus 2).
  - `test "chunk boundary"`: 10 sets with `chunk: 4` produce 3+ chunks, all results arrive in order, and `handles == 0`.
  - `test "failure in a middle chunk"`:
    - 3 chunks, where chunk 2 has a set to a missing parm;
    - chunk 1's values are applied, and chunk 3's are not;
    - the error is `:not_found` with the parm path and the right `op`;
    - the frame is restored, and `handles == 0` (Review Focus 3 and 4).
  - `test "missing figure raises in Python, still not_found"`.
  - `test "Python error keeps class and gains op"`: use `SetFrame(999)` through `call(:scene, "SetFrame", [999])`, which gives `ValueError` with `op: 0`.
  - `test "a struct survives a server restart"`: follow the pattern in `test/poser/client_lifecycle_test.exs:42`. Restart the server, wait for `:connected`, and the same struct still reads with no `stale_handle` (Review Focus 1).
  - `test "handles are released"`: after success and after every failure test above, `Client.stats` shows `handles == 0`.
- [ ] **Step 2:** Run `mix test test/poser/batch_test.exs`. Expected: FAIL.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** Run the tests. Expected: PASS. Then run `mix test`. Expected: PASS.
- [ ] **Step 5:** Commit: `jj commit lib test -m "Poser.Batch: name-path resolution in one frame, shared lookups, frames, chunks, error mapping"`

### Task 5: `Poser.Parameter`

**Files:**
- Modify: `lib/poser/parameter.ex`
- Test: `test/poser/parameter_test.exs`

**Interfaces:**
- Consumes: Task 4's `Poser.Batch`.
- Produces: the following functions, each with a `!` variant.

  | Function | Returns | How |
  |---|---|---|
  | `value(p, opts)` | `{:ok, float}` | one `get` |
  | `set_value(p, number, opts)` | `{:ok, :ok}`; the bang returns `:ok` | one `set` |
  | `value_at(p, frame, opts \\ [])` | as `value/2` | `value(p, Keyword.put(opts, :frame, frame))` |
  | `min_max(p, opts)` | `{:ok, {min, max}}` | one batch with two `call`s, `MinValue` and `MaxValue` |
  | `add_keyframe(p, frame, opts)` | `{:ok, :ok}` | |
  | `delete_keyframe(p, frame, opts)` | `{:ok, :ok}` | |
  | `keyframes(p, opts)` | `{:ok, [non_neg_integer()]}` | see below |
  | `handle(p, opts)` | `{:ok, Poser.Handle.t()}` | the final lookup's handle, owned by the caller; every other handle is released |

  How `keyframes(p, opts)` works:
  1. It checks frame 0, at frame 1, with `PrevKeyFrame` (using Task 1 fact 3).
  2. It then steps `NextKeyFrame` from each key with `call(p, "NextKeyFrame", [], frame: k)`, one request per key, until the end value from fact 3.
  3. It returns the keys sorted, and the frame is restored.

- [ ] **Step 1:** Write the failing tests:
  - a value round trip;
  - an integer set reads back as a float;
  - `value_at` doesn't move the frame;
  - `min_max` returns `{-180.0, 180.0}`;
  - after adding keys at 3 and 7, `keyframes` returns `[3, 7]`; after deleting 3, it returns `[7]`;
  - a key at frame 0 is listed;
  - `handle/1` leaves `handles == 1`, and 0 after release;
  - a `!` variant raises `Poser.Error` with `kind: :not_found` for a missing parm.

  Each function's `@doc` has an *Examples* section (iex style; not doctests, since they need a server).
- [ ] **Step 2:** Run `mix test test/poser/parameter_test.exs`. Expected: FAIL.
- [ ] **Step 3:** Implement. Use `@doc group: "Values" | "Keyframes" | "Escape hatch"` (ExDoc function groups).
- [ ] **Step 4:** Run the tests. Expected: PASS.
- [ ] **Step 5:** Commit: `jj commit lib test -m "Poser.Parameter: values, frames, keyframes, min/max, handle"`

### Task 6: Listing, and `Poser.Actor`

**Files:**
- Modify: `lib/poser/ref.ex` (add the listing helper) and `lib/poser/actor.ex`
- Test: `test/poser/actor_test.exs`

**Interfaces:**
- Consumes: Task 4's `Poser.Batch` and Task 5's `Poser.Parameter`.
- Produces:
  - **`Poser.Ref.children(parent :: Poser.Ref.ref(), list_method :: String.t(), extra :: [String.t()], opts) :: {:ok, [%{String.t() => term()}]}`.** It is `@doc false`.
    - It takes two requests: a batch that resolves `parent` and calls `list_method`, then a batch reading `InternalName`, `Name` and each `extra` method for every returned handle.
    - It releases every handle, and returns maps keyed by method name, in Poser's order.
  - **`Poser.Ref.find(parent, list_method, name, build :: (map -> struct), opts) :: {:ok, struct} | {:error, Poser.Error.t()}`.** It is `@doc false` and implements display-name matching: exactly one `Name` match gives that struct, several give `:ambiguous` with the structs, and none gives `:not_found`.
  - **`Poser.Actor` functions,** each with a `!` variant:

    | Function | Returns | How |
    |---|---|---|
    | `parameters(a, opts)` | `{:ok, [Poser.Parameter.t()]}` | |
    | `parameter(a, name, opts)` | `{:ok, Poser.Parameter.t()}` | tries the internal name first (one batch calling `InternalName` and `Name` on the resolved parm), then `Ref.find(a, "Parameters", name, …)` on `:not_found` |
    | `get(a, internal, opts)` | `{:ok, float}` | |
    | `set(a, internal, value, opts)` | `{:ok, :ok}` | |
    | `set(a, %{internal => value}, opts)` | `{:ok, :ok}` | one batch |
    | `values(a, opts)` | `{:ok, %{internal => float}}` | `children(a, "Parameters", ["Value"], opts)` |
    | `handle(a, opts)` | `{:ok, Poser.Handle.t()}` | |

    `set/4` takes one name and `set/3` takes a map, so the clauses are distinguished by arity and guards.

- [ ] **Step 1:** Write the failing tests:
  - `parameters` of `hip` returns `xTran` and `Weird` structs with the right `actor`;
  - `parameter(a, "xtran")` finds by internal name, and `parameter(a, "xTran")` finds by display name;
  - a missing name gives `:not_found`;
  - `get` and `set` round-trip;
  - `set` with a two-key map sends one batch;
  - `values` returns `%{"xtran" => 0.0, "weird" => :nan}`. The codec sends NaN as the atom `:nan`, and the idiomatic layer passes it through. Document `float() | :nan | :infinity | :neg_infinity` as the value type;
  - the `Ünïcode 頭` actor's struct inspects and resolves correctly (Review Focus 5);
  - `handles == 0` after every call.
- [ ] **Step 2:** Run `mix test test/poser/actor_test.exs`. Expected: FAIL.
- [ ] **Step 3:** Implement. Use the function groups *Parameters*, *Values* and *Escape hatch*.
- [ ] **Step 4:** Run the tests. Expected: PASS.
- [ ] **Step 5:** Commit: `jj commit lib test -m "Poser.Actor and listing: parameters, lookups by either name, values, multi-set"`

### Task 7: `Poser.Figure` and `Poser.Scene`

**Files:**
- Modify: `lib/poser/figure.ex`
- Create: `lib/poser/scene.ex`
- Test: `test/poser/figure_test.exs` and `test/poser/scene_test.exs`

**Interfaces:**
- Consumes: Tasks 4–6.
- Produces the functions below, each with a `!` variant.
  - **`Poser.Figure`:**
    - `actors(f, opts)` returns body parts as `%Poser.Actor{figure: f}`.
    - `actor(f, name, opts)` tries the internal name, then the display name.
    - `parameter(f, actor_name, parm_name, opts)`.
    - `handle(f, opts)`.
  - **`Poser.Scene`:**
    - `frame(opts)`, `set_frame(n, opts)`, `num_frames(opts)` and `fps(opts)` are single `Batch.call(:scene, …)` ops. `set_frame` is the one deliberate exception to restoring the frame.
    - `figures(opts)` and `figure(name, opts)`. `figure` tries the internal name, then the display name, where `"Figure 1"` is `:ambiguous` in the fake.
    - `actors(opts)` returns scene-level actors only (`IsBodyPart() == 0`, read through `children(:scene, "Actors", ["IsBodyPart"], opts)`), as `%Poser.Actor{figure: nil}`.
    - `actor(name, opts)` works the same way, at scene level.

- [ ] **Step 1:** Write the failing tests:
  - `figures` returns both fake figures;
  - `figure("figure 2")` finds by internal name. `figure("Figure 1")` gives `:ambiguous` with both structs: internal names are case-sensitive, so `"Figure 1"` doesn't match `"figure 1"`, and two figures share the display name. `figure("Nope")` gives `:not_found`;
  - an internal-name hit always wins. Assert that `Scene.figure("figure 1")` returns the first figure with no `:ambiguous`, even though its display name is shared;
  - `Scene.actors` returns `[Ball]` only;
  - `Figure.actors` returns the three body parts;
  - `Figure.parameter(f, "hip", "xtran")` resolves;
  - `set_frame(4)` followed by `frame()` returns 4, then reset it to 0;
  - `fps` returns 30;
  - `handles == 0` throughout.
- [ ] **Step 2:** Run `mix test test/poser/figure_test.exs test/poser/scene_test.exs`. Expected: FAIL.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** Run `mix test`. Expected: PASS.
- [ ] **Step 5:** Commit: `jj commit lib test python -m "Poser.Figure and Poser.Scene"`

### Task 8: HexDocs

**Files:**
- Modify: `mix.exs` (add `{:ex_doc, "~> 0.40", only: :dev, runtime: false}` and a `docs/0` config), `README.md`, `guides/setup.md` (move the "Generated API" section out)
- Create:
  - `guides/getting-started.md`, `guides/concepts.md`, `guides/posing.md`, `guides/frames-and-keyframes.md`, `guides/batching.md`, `guides/errors.md` and `guides/generated-api.md`;
  - `guides/idiomatic-api.cheatmd` and `guides/posing.livemd`.
- Modify: the moduledocs of `Poser`, `Poser.Scene`, `Poser.Figure`, `Poser.Actor`, `Poser.Parameter` and `Poser.Batch`.

**Interfaces:**
- **`docs/0`:**
  - `main: "getting-started"`.
  - `extras:` the pages in the spec's ExDoc table.
  - `groups_for_extras:` Introduction, Guides, Cheatsheets, Livebook, Reference.
  - `groups_for_modules:` Idiomatic API, Errors, Generated API (`~r/^Poser\.Api/` and `Poser.Const`), Connection, Internals (`Poser.Ref`, `Poser.Codec`, `Poser.Call`, `Poser.Gen.*`, `Poser.Smoke`, `Poser.NDArray`).
- **Content rules:** the spec's Documentation section and this plan's Global Constraints.
  - `concepts.md` opens with the concept map table, then gives the five teaching-order ideas, each with one short example.
  - Wherever a frame appears in prose, the GUI frame number is given too, e.g. "`frame: 0` (GUI frame 1)".
  - `batching.md` has the "no rollback" warning admonition (`> #### No rollback {: .warning}`), and `posing.md` has the "listings take two requests" info admonition.
  - The cheatsheet shows each task twice, idiomatic and `Poser.Api`: get a figure, read a dial, set a dial at a frame, set many dials, list keyframes, get a handle.
  - `posing.livemd` uses `Mix.install([{:poserx, path: "…"}])` with the repo path written as a variable, and runs against a live Poser.
- **Moduledocs:** each idiomatic moduledoc covers the Poser concept it represents (from the map), how to get one, common tasks, and links to the guides. Pure examples are doctests: `inspect` output, `Poser.Ref.path/1`, `Poser.Batch.size/1` after building.

- [ ] **Step 1:** Run `mix deps.get`, then `mix docs`. Expected: the docs build. Record every warning; they're the to-do list for this task.
- [ ] **Step 2:** Write the pages and moduledocs.
- [ ] **Step 3:** Run `mix docs 2>&1 | grep -i warning`. Expected: no output. Run `mix test`. Expected: PASS, with the doctests included.
- [ ] **Step 4:** Open `doc/index.html` and check:
  - the sidebar groups match the spec;
  - the cheatsheet renders in two columns;
  - the function groups show in `Poser.Parameter`.

  Record anything off in the findings.
- [ ] **Step 5:** Commit: `jj commit mix.exs mix.lock README.md guides lib -m "HexDocs: getting started, concepts, guides, cheatsheet, Livebook, grouped modules"`

### Task 9: Live check, findings and push

**Files:**
- Modify: `test/live/live_poser_test.exs` and `plans/phase3a-findings.md`

- [ ] **Step 1:** Add the live tests (`@tag :poser`). Each leaves the scene as it was:
  - `Scene.figures` is non-empty, and `Actor.values` works on the first figure's first body part;
  - `set_value` at frame 5 then `value_at` 5 reads the value back. Then the original value is restored, any key created is deleted (per Task 1 fact 4), and the frame is unchanged;
  - a 2 000-op batch (`get` on 2 000 parm reads spread over the figures' dials) finishes. Record its time;
  - a missing figure, actor and parm each give `:not_found`;
  - `handles == 0` at the end.
- [ ] **Step 2:** Run `mix test --only poser` against the 9-figure scene. Expected: PASS. Poser is running, so run this directly. If the port is closed, give the user the single-line check from `plans/phase2-findings.md`.
- [ ] **Step 3:** Complete `plans/phase3a-findings.md`:
  - the live timings (single op, 2 000-op batch, `values/1` on a large actor);
  - surprises, and any spec changes they forced;
  - the teaching-order list, updated if writing the docs changed it.
- [ ] **Step 4:** Run `mix test`, the Python tests, `mix compile --warnings-as-errors --force`, `mix format --check-formatted` on the changed files, and `mix docs` (no warnings). Expected: all clean.
- [ ] **Step 5:**
  1. Commit with `jj commit test plans/phase3a-findings.md -m "Phase 3a findings: live idiomatic layer"`.
  2. Run `jj bookmark create phase-3a -r @-`.
  3. Run `jj git push --bookmark phase-3a`.
  4. Update the phase-status memory. The user opens the PR.
