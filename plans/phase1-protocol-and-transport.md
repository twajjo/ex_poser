# Phase 1: Protocol and Transport Core Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the Phase 0 spike with the real bridge. The add-on serves the full v1 request set (`C`/`I`/`G`/`B`/`R`/`X`) with a handle table and dev/strict policy. On the Elixir side, `Poser.Client` handles timeouts, handle ownership, heartbeats and reconnects.

**Architecture:** The Python add-on stays split into Poser-free modules (`codec`, `handles`, `policy`, `dispatch`, `server`, `net`), with Poser- and wx-specific code only in `addon.py`. All handle-table and Poser API work runs on the main thread through `submit`. On the Elixir side, `Poser.Transport` (TCP now) carries frames, `Poser.Codec` converts terms, `Poser.Client` (a GenServer) owns the connection, and `Poser.Events` (a Registry) fans out events. Tests run against `python/standalone_server.py` with a fake `poser` module. Live-Poser tests are tagged `:poser`.

**Tech Stack:** Python 3.7.9, stdlib only (mise), `unittest`; Elixir 1.20.4 / OTP 29, no Hex dependencies; jj.

**Spec:** `plans/elixir-poser-bridge-plan.md` (§3 Architecture and wire protocol, §5 Phase 1, §8 environment), adjusted by `plans/phase0-findings.md` ("Live Poser").

## Global Constraints

- Python code must run on 3.7.9: no walrus operator, no `socket.create_server`, no positional-only parameters. Stdlib only. Follow the existing `%` formatting style.
- Only `python/poser_bridge/addon.py` may import `poser`, `poseraddon` or `wx`. Every other module receives the `poser` module as an argument.
- The `HandleTable` and every Poser API call are only touched on the main thread, meaning inside a `submit`ted function. The reader thread only decodes frames, answers `ping`, and submits work.
- The wire format is unchanged: a 4-byte big-endian length followed by ETF. The maximum frame size is 64 MiB on both sides. `PROTOCOL = 1`; the hello reply gains fields, but the version stays 1 because nothing has been published.
- Dev port `47800`. Session file `%APPDATA%\PoserBridge\session.json` holds `{port, token, protocol, hosts}`, written atomically as it is now.
- No Hex dependencies. Use the built-in `JSON` module.
- Default call timeout is **120 000 ms**. The 30 s timeout in the main plan is too short: texture loading blocked the main thread for more than 30 s.
- Heartbeat: `ping` (answered on the reader thread) every **5 000 ms**. Treat the connection as dead after **15 000 ms** without any inbound frame.
- Reconnect backoff starts at **250 ms**, doubles, caps at **10 000 ms**, and resets after a successful handshake. **Re-read the session file on every attempt**, because the token changes when Poser restarts.
- Commit with jj, not git: `jj commit <paths> -m "<message>"` after each task. **No Claude attribution lines** in commit messages or PR text. When all tasks are done, run `jj bookmark create phase-1 -r @-` then `jj git push --bookmark phase-1`.
- Python tests: `mise exec -- python -m unittest discover -s python/tests -t python -v` from the repo root. Elixir tests: `mix test`.

## Wire protocol v1 (as built in this phase)

Requests (Elixir → Python). Each `id` is a positive integer. `kwargs` is a map with binary keys.

| Term | Runs on | Reply value |
|---|---|---|
| `{:hello, %{token, protocol: 1, client: "poserx 0.1.0"}}` | reader | `{:r, 0, %{protocol: 1, mode: :dev \| :strict, poser_version, python_version, api_hash}}` |
| `{:ping, id}` | reader | `:pong` |
| `{:ping_main, id}` | main | `:pong` |
| `{:C, id, name, args, kwargs}` | main | `poser.<name>(*args, **kwargs)`, wrapped |
| `{:I, id, handle, method, args, kwargs}` | main | `obj.<method>(*args, **kwargs)`, wrapped |
| `{:G, id, handle, attr}` | main | `getattr(obj, attr)`, wrapped |
| `{:B, id, [op, ...]}` | main | list of wrapped results. `op` is `{:C, name, args, kwargs}`, `{:I, handle, method, args, kwargs}` or `{:G, handle, attr}`. `{:result, n}` in any argument means the raw result of op `n` (0-based, `n` < current index). |
| `{:R, id, [handle, ...]}` | main | count of entries removed |
| `{:S, id}` | main | `%{"handles" => n, "generation" => g}` |
| `{:X, id, module, function, args}` | main | dev mode only, wrapped |

- **Handle:** `{:poser_obj, class_name, id, generation, label}`, the same tuple in both directions. `label` is `obj.Name()` when that works, otherwise `nil`.
- **numpy arrays:** `{:ndarray, dtype_str, shape_tuple, bytes}`.
- **Non-finite floats:** become the atoms `:nan`, `:infinity` and `:neg_infinity`.
- **Error reasons** (`{:e, id, reason}`):
  - `{:python, class, message, traceback_lines}`
  - `{:stale_handle, id, generation}`
  - `{:not_allowed, :call | :invoke | :get_attr | :raw, name}`
  - `{:bad_request, repr}`
  - `{:batch_failed, index, reason, partial_results}`
  - `{:protocol_mismatch, ours, theirs}`, at handshake only, with id 0
- **Events** (`{:M, {name, payload}}`): `{:frame_changed, n}` and `{:generation_changed, g}`.
- **Atom set.** Every atom Python can send must be in `Poser.Codec.known_atoms/0`, because Elixir decodes with `[:safe]`:
  - message tags: `r e M`
  - values: `pong poser_obj ndarray result nil true false nan infinity neg_infinity obj bytes`
  - error kinds: `python stale_handle not_allowed bad_request batch_failed protocol_mismatch`
  - `not_allowed` sub-kinds: `call invoke get_attr raw`
  - event names: `frame_changed generation_changed`
  - modes: `dev strict`
  - hello-reply keys: `protocol mode poser_version python_version api_hash`

## Review Focus

1. **A handle from before a reconnect or a Poser restart** must give `:stale_handle` and never resolve to a different object. Covered by the epoch test in Task 9.
2. **The main thread blocked longer than the call timeout.** The caller gets a `:timeout` error, the connection stays up (the heartbeat keeps succeeding), and the late reply is dropped with its handles released. Covered by the timeout tests in Tasks 8 and 9.
3. **A frame Elixir can't decode** (unknown atom, garbage bytes) is logged and dropped. The client must not crash, and other calls keep working. Covered by the scripted-server test in Task 8.
4. **Non-ASCII names** (Poser strings are Unicode) round-trip both ways. Covered by the dispatcher test in Task 4 and the client test in Task 8.
5. **NaN or infinite floats, and replies that can't be encoded,** come back as values or an error reply, never as a silently dropped reply that leaves the caller hanging. Covered by the codec test in Task 1 and the server test in Task 5.

---

### Task 1: Python test harness, fake `poser` module, codec edge cases

**Files:**
- Create: `python/tests/__init__.py` (empty), `python/fake_poser.py`, `python/tests/test_codec.py`
- Modify: `python/poser_bridge/codec.py` (`to_wire`)

**Interfaces:**
- Produces `fake_poser.install() -> module`. It builds a fresh fake module, registers it as `sys.modules["poser"]`, and returns it. Contents (class names must match Poser's):
  - `SceneType`: `Frame()`, `SetFrame(n)` (raises `ValueError("frame out of range")` unless `0 <= n < 30`), `NumFrames()` → 30, `Figures()`, `Actors()`, `Actor(name)` (raises the module's `error` exception for an unknown name), `Figure(name)`.
  - One `FigureType` named `"Figure 1"` with actors `hip`, `chest` and `Ünïcode 頭`.
  - `ActorType`: `Name()`, `InternalName()`, `Parameter(name)` → `ParmType` or `None`, `Parameters()`.
  - `ParmType`: `Name()`, `Value()`, `SetValue(v)`. Each actor has `xTran` = 0.0 and `Weird` = `float("nan")`.
  - Module functions: `Scene()` (singleton), `AppVersion()` → `"fake-14"`, `Sleep(seconds)` → `time.sleep`, returns `None`, `SleepThenScene(seconds)` → sleeps, then returns `Scene()`, `Cyclic()` → returns a list that contains itself, `NewScene()` → replaces the scene and calls the module hook `on_new_scene()` (a no-op until the server sets it).
  - Class `error(Exception)`. Constant `kParmCodeXTRAN = 1`.
- Produces in `codec.to_wire`: `float('nan')` → `Atom(b"nan")`, `+inf` → `Atom(b"infinity")`, `-inf` → `Atom(b"neg_infinity")`.

- [ ] **Step 1: Write failing tests** in `python/tests/test_codec.py`:

```python
class CodecTest(unittest.TestCase):
    def test_bool_and_nil_round_trip(self):
        self.assertIs(codec.decode(codec.encode(True)), True)
        self.assertIsNone(codec.decode(codec.encode(None)))
    def test_unicode_str_round_trip(self):
        self.assertEqual(codec.decode(codec.encode("Ünïcode 頭")), "Ünïcode 頭")
    def test_non_finite_floats_become_atoms(self):
        self.assertEqual(codec.to_wire(float("nan")), Atom(b"nan"))
        self.assertEqual(codec.to_wire(float("inf")), Atom(b"infinity"))
        self.assertEqual(codec.to_wire(float("-inf")), Atom(b"neg_infinity"))
    def test_fake_poser_installs_fresh_module(self):
        p = fake_poser.install()
        self.assertIs(sys.modules["poser"], p)
        self.assertEqual(type(p.Scene()).__name__, "SceneType")
        self.assertIsNot(fake_poser.install().Scene(), p.Scene())
```

- [ ] **Step 2: Run** `mise exec -- python -m unittest discover -s python/tests -t python -v`. Expected: the non-finite test and the fake-poser test FAIL.
- [ ] **Step 3: Implement** `fake_poser.py` and the non-finite branch in `to_wire` (check with `math.isnan` / `math.isinf` before returning a float).
- [ ] **Step 4: Run the tests.** Expected: all PASS.
- [ ] **Step 5: Commit** `jj commit python/tests python/fake_poser.py python/poser_bridge/codec.py -m "Python test harness, fake poser module, non-finite floats"`

### Task 2: Handle table (`handles.py`)

**Files:**
- Create: `python/poser_bridge/handles.py`, `python/tests/test_handles.py`

**Interfaces:**
- Produces:
  - `POSER_OBJ = Atom(b"poser_obj")`, `NDARRAY = Atom(b"ndarray")`, `RESULT = Atom(b"result")`
  - `class StaleHandle(Exception)` with attributes `.id` and `.generation`
  - `class BadRequest(Exception)`
  - `class HandleTable(current_generation: Callable[[], int], cap: int = 10000)`, with methods:
    - `wrap(value) -> wire-ready value`
    - `resolve(term, refs: list | None = None) -> python value`
    - `release(handle_terms: list) -> int`
    - `clear() -> None`
    - `__len__`
- Rules for `wrap`:
  - `None`, `bool`, `str`, `bytes`, `Atom` and `numbers.Number` pass through unchanged.
  - `list` and `tuple` keep their type, and each element is wrapped.
  - `dict` values are wrapped; keys are left as they are.
  - An object whose type is named `ndarray` and that has `dtype`, `shape` and `tobytes` becomes `(NDARRAY, a.dtype.str, tuple(a.shape), a.tobytes())`.
  - Anything else is stored under the next id (a per-table `itertools.count(1)`) and becomes `(POSER_OBJ, type(obj).__name__, id, current_generation(), label)`.
  - Nesting deeper than 100 levels raises `ValueError("value nested too deeply")`.
- Rules for `resolve`:
  - A 5-tuple tagged `POSER_OBJ` is looked up by id. A missing id, or a generation that isn't the current one, raises `StaleHandle(id, gen)`.
  - `(RESULT, n)` returns `refs[n]`. It raises `BadRequest` if `refs is None` or `n` is out of range.
  - Lists, tuples and dicts are resolved recursively.
- Storage is an LRU: an `OrderedDict`, where a lookup moves the entry to the end and an insert beyond `cap` evicts the oldest entry.

- [ ] **Step 1: Write failing tests:**
  - `test_plain_values_pass_through`: `wrap([1, 2.5, "a", None, True, {"k": (1,)}])` returns its input unchanged.
  - `test_object_becomes_handle_and_resolves`: `h = wrap(actor)`, so `h[0] == POSER_OBJ`, `h[1] == "ActorType"`, `h[2] == 1`, `h[4] == "hip"`, and `resolve([h])[0] is actor`.
  - `test_label_none_when_name_raises`
  - `test_ndarray_duck_type`: a fake class named `ndarray` with `dtype.str == "<f4"`, `shape == (2, 3)` and `tobytes() == b"x"*24` wraps to `(NDARRAY, "<f4", (2, 3), b"x"*24)`.
  - `test_stale_after_generation_change`: bump the generation callable's value, then `resolve(h)` raises `StaleHandle` with `.id == h[2]`.
  - `test_release_counts_and_forgets`: `release([h, h]) == 1` and `len(table) == 0`.
  - `test_lru_evicts_oldest`: with `cap=2`, wrap three objects; resolving the first raises `StaleHandle`.
  - `test_result_ref`: `resolve([(RESULT, 0)], refs=["x"]) == ["x"]`, and with `refs=None` it raises `BadRequest`.
  - `test_cyclic_value_raises`: `wrap(fake.Cyclic())` raises `ValueError`.
- [ ] **Step 2: Run the tests.** Expected: FAIL (`ImportError`).
- [ ] **Step 3: Implement `handles.py`** following the rules above.
- [ ] **Step 4: Run the tests.** Expected: PASS.
- [ ] **Step 5: Commit** `jj commit python/poser_bridge/handles.py python/tests/test_handles.py -m "Handle table with generations and LRU cap"`

### Task 3: Dev and strict policy (`policy.py`)

**Files:**
- Create: `python/poser_bridge/policy.py`, `python/tests/test_policy.py`, `python/tests/fixtures/mini_api.json`

**Interfaces:**
- Produces:
  - `class NotAllowed(Exception)` with attributes `.kind` (one of `"call"`, `"invoke"`, `"get_attr"`, `"raw"`) and `.name`.
  - `class Policy`:
    - `mode` is `"dev"` or `"strict"`; `api_hash` is a str or `None`.
    - `Policy.dev() -> Policy`
    - `Policy.load(mode: str, api_path: str) -> Policy`. In strict mode a missing or unreadable file raises `OSError` or `ValueError`. In dev mode the file is optional and only supplies `api_hash`.
    - `check_call(name)`, `check_method(obj, name)`, `check_attr(obj, name)`, `check_raw(module, function)`. Each raises `NotAllowed` or returns `None`.
- Dev rules: any name starting with `_` is rejected for call, invoke and get_attr. Everything else is allowed, including raw.
- Strict rules:
  - `check_call`: only names in `functions[].name`.
  - `check_method`: only methods listed for `type(obj).__name__` or any class reachable through `bases`. An unknown class is rejected.
  - `check_attr`: same idea, using `attributes`.
  - `check_raw`: always rejected.
- `mini_api.json` uses the same layout as `priv/poser_api.json` (`meta.api_hash`, `functions`, `classes{name: {bases, methods[{name}], attributes}}`) and contains:
  - functions `Scene` and `AppVersion`;
  - `SceneObjectType` with methods `Name` and `InternalName`;
  - `ActorType` (bases `SceneObjectType`) with `Parameter`;
  - `SceneType` with `Frame`, `NumFrames`, `Figures`, `Actors` and `Actor`, but **not `SetFrame`**;
  - `ParmType` with `Value`;
  - `api_hash` set to `"mini"`.

- [ ] **Step 1: Write failing tests:**
  - `test_dev_allows_public_rejects_underscore`: `check_method(actor, "__class__")` raises `NotAllowed` with `kind == "invoke"`.
  - `test_strict_allows_listed_function`
  - `test_strict_rejects_unlisted_method`: `check_method(scene, "SetFrame")` raises with `.name == "SetFrame"`.
  - `test_strict_inherits_through_bases`: `check_method(actor, "Name")` is allowed.
  - `test_strict_rejects_unknown_class`
  - `test_strict_rejects_raw`
  - `test_strict_missing_file_raises`
  - `test_api_hash_loaded`: `== "mini"`.
- [ ] **Step 2: Run the tests.** Expected: FAIL.
- [ ] **Step 3: Implement `policy.py`.** Precompute `{class_name: frozenset(methods including bases)}` once at load time.
- [ ] **Step 4: Run the tests.** Expected: PASS.
- [ ] **Step 5: Commit** `jj commit python/poser_bridge/policy.py python/tests/test_policy.py python/tests/fixtures -m "Dev and strict policy with allowlist from the API dump"`

### Task 4: Request dispatcher (`dispatch.py`)

**Files:**
- Create: `python/poser_bridge/dispatch.py`, `python/tests/test_dispatch.py`
- Modify: `python/poser_bridge/server.py` (move `raw_call` into `dispatch.py`)

**Interfaces:**
- Consumes: `HandleTable`, `StaleHandle`, `BadRequest` (Task 2); `Policy`, `NotAllowed` (Task 3).
- Produces `class Dispatcher(poser, handles: HandleTable, policy: Policy)`, with these methods:
  - `run(msg: tuple) -> tuple` runs on the main thread, **never raises**, and returns `(A_R, id, value)` or `(A_E, id, reason)` using the wire shapes above.
  - `stats() -> dict` returns `{"handles": len(handles), "generation": current}`.
- Produces `raw_call(module, function, args)`, unchanged in behaviour.
- Tags are the atoms `C I G B R S X`. A wrong arity or a wrong type raises `BadRequest`, which becomes `(bad_request, repr(msg))`.
- Error mapping:
  - `StaleHandle` → `(stale_handle, id, gen)`
  - `NotAllowed` → `(not_allowed, Atom(kind), name)`
  - any other exception → `(python, class_name, str(e), traceback.format_exception(...) lines)`
- Batch: run the ops in order and keep each raw result for `(result, n)` references. If op `k` fails, reply `(batch_failed, k, reason, [wrapped results 0..k-1])`.

- [ ] **Step 1: Write failing tests** against `fake_poser.install()` and `Policy.dev()` (and the strict fixture where noted):
  - `test_call_returns_handle`: `run((C, 1, "Scene", [], {}))` gives `r[0] == A_R`, `r[2][1] == "SceneType"`.
  - `test_invoke_on_handle`: `Frame` gives `0`; `SetFrame(5)` followed by `Frame` gives `5`.
  - `test_kwargs_passed`: `I ... "SetFrame", [], {"n": 3}` (fake `SetFrame(n)`) gives frame 3.
  - `test_unicode_actor_name_round_trip`: `I scene "Actor" ["Ünïcode 頭"]`, then `Name` returns `"Ünïcode 頭"`.
  - `test_python_error_shape`: `SetFrame(99)` gives `(python, "ValueError", "frame out of range", tb)` with `len(tb) > 0`.
  - `test_get_attr`
  - `test_stale_handle_error`
  - `test_not_allowed_in_strict`: `SetFrame` gives `(not_allowed, invoke, "SetFrame")`.
  - `test_raw_rejected_in_strict`
  - `test_batch_with_result_refs`: `[(C,"Scene",[],{}), (I,(RESULT,0),"Frame",[],{})]` returns `[handle, 0]`.
  - `test_batch_failure_partial`: the second op raises, so the reply is `(batch_failed, 1, (python, ...), [handle])`.
  - `test_release_and_stats`: `R` returns 1, then `S` gives `handles == 0`.
  - `test_malformed_is_bad_request`: `run((C, 1))`.
- [ ] **Step 2: Run the tests.** Expected: FAIL.
- [ ] **Step 3: Implement `dispatch.py`.** Each op resolves its args through `handles.resolve`, checks the policy, calls, then wraps the result.
- [ ] **Step 4: Run the tests.** Expected: PASS.
- [ ] **Step 5: Commit** `jj commit python/poser_bridge/dispatch.py python/poser_bridge/server.py python/tests/test_dispatch.py -m "Dispatcher for C/I/G/B/R/S/X ops"`

### Task 5: Server integration, add-on wiring, standalone server

**Files:**
- Modify:
  - `python/poser_bridge/server.py`
  - `python/poser_bridge/addon.py`
  - `python/poser_bridge/net.py` (add `read_config`)
  - `python/standalone_server.py`
  - `scripts/deploy_addon.sh`
  - `scripts/phase0_ping.exs` (add `:api_hash, :client, :poser_obj` to `@known_atoms`)
- Create: `python/tests/test_server.py`

**Interfaces:**
- Consumes: `Dispatcher` (Task 4), `HandleTable` (Task 2), `Policy` (Task 3), `fake_poser` (Task 1).
- Produces:
  - `Server(hosts, port, token, submit, info=None, log=print, poser=None, policy=None)`. `policy` defaults to `Policy.dev()`. `port=0` binds an ephemeral port, and `self.port` is updated to the real port after the first bind.
  - `Server.generation` (int, starts at 0), `Server.current_generation() -> int`, and `Server.new_generation()`. The last runs on the main thread: it increments the counter, clears every connection's table, and sends the `generation_changed` event.
  - `Connection.dispatcher` is created after a successful handshake.
  - `Connection.reply(term)`: if encoding fails, it sends `(e, term[1], (python, "EncodeError", str(e), []))` instead of dropping the reply.
  - The hello reply adds `mode` (the policy mode as an atom) and `api_hash`, and logs the client string.
  - `net.read_config() -> dict` reads `<session_dir>/config.json` and returns `{}` if the file is missing.
- `addon.py`:
  - Mode is `read_config().get("mode", "dev")`. The policy comes from `Policy.load(mode, <package dir>/poser_api.json)`. If strict mode fails to load, log `poser_bridge: strict mode needs poser_api.json: ...` and don't start.
  - Pass `poser=poser`.
  - `sceneCreated(self, scene)` and `sceneDeleting(self, scene)` call `self.server.new_generation()`.
- `standalone_server.py`:
  - New flags `--mode {dev,strict}`, `--api PATH` and `--exit-on-stdin-eof`. The last starts a daemon thread that blocks on `sys.stdin.read()` and calls `os._exit(0)` at EOF, so a crashed test run leaves no orphan process.
  - Uses `fake_poser.install()` and sets `fake.on_new_scene = lambda: work.put(server.new_generation)`.
  - Prints `session file <path>` only after `server.start()`, with the real port.
- `deploy_addon.sh`: after the rsync, `cp priv/poser_api.json "$addons/poser_bridge/poser_api.json"`.

- [ ] **Step 1: Write failing tests** in `test_server.py`. Start a `Server` on `127.0.0.1` port 0 with a queue-based main thread (the same pattern as `standalone_server.py`, run in a daemon thread), set `fake.on_new_scene` to queue `server.new_generation` as the standalone server does, connect with a raw socket using `codec.write_frame` and `codec.read_frame`, and test:
  - `test_hello_reports_mode_and_api_hash`: a strict server with `mini_api.json` gives `reply[2][atom("mode")] == atom("strict")` and `api_hash == "mini"`.
  - `test_call_round_trip_over_socket`: `C Scene` returns a handle.
  - `test_ping_answered_while_main_blocked`: send `C Sleep [1.0]`, then `ping`. The `pong` arrives within 0.3 s, before the `Sleep` reply.
  - `test_generation_change_stales_handles_and_emits_event`: `X fake_poser NewScene []` produces an `M generation_changed 1` frame, and invoking the old handle then gives `stale_handle`.
  - `test_unencodable_reply_becomes_error`: patch `codec.encode` to raise for one reply; the client receives `(e, id, (python, "EncodeError", ...))`.
  - `test_nan_parameter_value_arrives_as_atom`: `Value` on parameter `Weird` gives `Atom(b"nan")`.
  - `test_stop_frees_port`: after `stop()`, a new `Server` binds the same port.
- [ ] **Step 2: Run the tests.** Expected: FAIL.
- [ ] **Step 3: Implement the server, add-on, net, standalone and deploy changes.**
- [ ] **Step 4: Run all Python tests.** Expected: PASS. Then check the standalone server by hand: run `mise exec -- python python/standalone_server.py --port 0 --session /tmp/poserx-s.json --events 0` and `elixir scripts/phase0_ping.exs --session /tmp/poserx-s.json --samples 20 --listen 1`. Expected: the hello line shows `api_hash`, `scene_summary` prints, and "error path ok".
- [ ] **Step 5: Commit** `jj commit python scripts -m "Server uses dispatcher, generations, strict mode config, standalone flags"`

### Task 6: Elixir application, data types, codec, events

**Files:**
- Modify: `mix.exs` (`mod: {Poserx.Application, []}`; `elixirc_paths(:test) -> ["lib", "test/support"]`), `test/test_helper.exs` (`ExUnit.start(exclude: [:poser])`)
- Delete: `lib/poserx.ex`, `test/poserx_test.exs`
- Create:
  - `lib/poserx/application.ex`
  - `lib/poser/handle.ex`, `lib/poser/nd_array.ex`, `lib/poser/error.ex`, `lib/poser/codec.ex`, `lib/poser/events.ex`
  - `test/poser/codec_test.exs`, `test/poser/error_test.exs`, `test/poser/events_test.exs`

**Interfaces:**
- `Poserx.Application` starts `{Registry, keys: :duplicate, name: Poser.Events.Registry}`.
- `%Poser.Handle{class: String.t(), id: pos_integer(), generation: non_neg_integer(), label: String.t() | nil, epoch: non_neg_integer() | nil}`
- `%Poser.NDArray{dtype: String.t(), shape: tuple(), data: binary()}`
- `Poser.Error`:
  - `defexception [:kind, :class, :message, :traceback, :details]`. `kind` is one of `:python | :stale_handle | :not_allowed | :bad_request | :batch_failed | :timeout | :disconnected | :protocol_mismatch | :handshake_failed`.
  - `Poser.Error.from_wire(reason_term) :: t()`. For `batch_failed`, `details` is `%{index: i, cause: %Poser.Error{}, partial: list}`. For `stale_handle`, it is `%{id: id, generation: g}`. For `not_allowed`, it is `%{op: kind}` with `class: nil` and `message: name`.
  - `message/1` returns `"<kind>: <class>: <message>"`, leaving out any part that is nil.
- `Poser.Codec`:
  - `known_atoms() :: [atom()]` returns the atom set from the protocol section.
  - `to_wire(term) :: term()`:
    - `%Handle{}` becomes the handle tuple.
    - `nil`, `true` and `false` stay as they are.
    - Other atoms become `Atom.to_string/1`.
    - `{:bytes, bin}` passes through.
    - `{:result, n}` passes through.
    - Lists, tuples and map keys/values are converted recursively.
  - `from_wire(term, epoch) :: term()`:
    - The handle tuple becomes `%Handle{epoch: epoch}`.
    - The ndarray tuple becomes `%NDArray{}`.
    - Everything else stays as it is.
  - `encode(term) :: binary()` runs `to_wire` and then `:erlang.term_to_binary/1`.
  - `decode(binary) :: {:ok, term()} | {:error, :undecodable}` uses `binary_to_term(bin, [:safe])` and rescues `ArgumentError`.
  - `handles_in(term) :: [Handle.t()]` walks the whole term.
- `Poser.Events`:
  - `subscribe(event :: atom()) :: :ok` and `unsubscribe(event) :: :ok`.
  - `dispatch(event, payload) :: :ok` sends `{:poser_event, event, payload}` to every subscriber.

- [ ] **Step 1: Write failing tests:**
  - `test "handle round-trips through the wire"`: `from_wire(to_wire(h), 3) == %{h | epoch: 3}`.
  - `test "atoms other than nil/true/false become strings"`: `to_wire([:x, nil, true]) == ["x", nil, true]`.
  - `test "decode rejects unknown atoms"`: `decode(:erlang.term_to_binary(:"never_seen_#{System.unique_integer()}"))`. Build that binary by hand (`<<131, 119, len, name::binary>>`) so the atom isn't created first; the result is `{:error, :undecodable}`.
  - `test "known atoms exist"`: `Enum.all?(known_atoms(), &is_atom/1)`.
  - `test "handles_in finds nested handles"`
  - `test "batch_failed error nests its cause"`
  - `test "subscribers receive dispatched events"`
- [ ] **Step 2: Run** `mix test`. Expected: FAIL (compile errors or failing tests).
- [ ] **Step 3: Implement the modules.**
- [ ] **Step 4: Run** `mix test`. Expected: PASS, no warnings (`mix compile --warnings-as-errors`).
- [ ] **Step 5: Commit** `jj commit mix.exs lib test -m "Elixir app skeleton, handle and error types, codec, events"`

### Task 7: Session file, transport behaviour, TCP transport, test servers

**Files:**
- Create:
  - `lib/poser/session.ex`, `lib/poser/transport.ex`, `lib/poser/transport/tcp.ex`
  - `test/support/python.ex`, `test/support/standalone.ex`, `test/support/scripted_server.ex`
  - `test/poser/session_test.exs`, `test/poser/transport/tcp_test.exs`

**Interfaces:**
- `Poser.Session`:
  - `read(path) :: {:ok, %{port: integer, token: String.t, protocol: integer, hosts: [String.t]}} | {:error, term}`
  - `default_path() :: String.t`. Precedence:
    1. the `POSERX_SESSION` environment variable;
    2. in WSL, `%APPDATA%` (through `cmd.exe` and `wslpath`, as `scripts/phase0_ping.exs` does) joined with `PoserBridge/session.json`;
    3. on Windows, `APPDATA`;
    4. otherwise `~/.config/PoserBridge/session.json`.
  - `pick_host(hosts) :: String.t` returns the first non-`"127.0.0.1"` host, or `"127.0.0.1"`.
- `Poser.Transport` behaviour callbacks:
  - `connect(host :: String.t, port :: integer, timeout :: timeout) :: {:ok, conn} | {:error, term}`
  - `send_frame(conn, iodata) :: :ok | {:error, term}`
  - `recv_frame(conn, timeout) :: {:ok, binary} | {:error, term}`
  - `activate(conn) :: :ok`
  - `handle_message(conn, msg :: term) :: {:frame, binary} | {:closed, term} | :ignore`
  - `close(conn) :: :ok`
- `Poser.Transport.TCP`:
  - Socket options: `:gen_tcp` with `[:binary, packet: 4, packet_size: 64 * 1024 * 1024, active: false, nodelay: true]`.
  - `activate/1` sets `active: :once`.
  - `handle_message/2` re-arms `active: :once` after each frame.
- Test support:
  - `PoserTest.Python.path() :: String.t` returns `POSERX_PYTHON`, or `mise which python` run from the repo root.
  - `PoserTest.Standalone.start!(opts \\ []) :: %{port: integer, session: String.t, os_port: port}`:
    - Options are `mode: :dev | :strict`, and `session:`, a path to reuse.
    - Runs `standalone_server.py --port 0 --session <tmp>/session.json --events 0 --exit-on-stdin-eof`, adding `--mode strict --api python/tests/fixtures/mini_api.json` for strict mode.
    - Waits up to 10 s for the `session file` line.
  - `PoserTest.Standalone.stop!(s)`.
  - `PoserTest.ScriptedServer.start!(fun) :: %{session: path, pid: pid}`:
    - Listens on 127.0.0.1:0 and writes a session file with token `"t"`.
    - Accepts one connection and answers `hello` with `{:r, 0, %{protocol: 1, mode: :dev, poser_version: "scripted", python_version: "-", api_hash: nil}}`.
    - Then calls `fun.(term)` for each received frame. The callback returns `{:reply, term} | {:raw, binary} | :ignore`.

- [ ] **Step 1: Write failing tests:**
  - `test "read/1 parses the session file"`, using a temp file.
  - `test "read/1 reports a missing file"`.
  - `test "pick_host prefers the WSL adapter"`: `pick_host(["127.0.0.1", "172.22.192.1"]) == "172.22.192.1"`, and `pick_host(["127.0.0.1"]) == "127.0.0.1"`.
  - `test "TCP transport completes the hello handshake with the standalone server"`: connect, send `Codec.encode({:hello, %{token: t, protocol: 1, client: "test"}})`, `recv_frame`, then decode to `{:r, 0, %{mode: :dev}}`.
  - `test "TCP transport delivers frames as messages once activated"`: send `{:ping, 7}`, receive `{:tcp, ...}`, and `handle_message` returns `{:frame, bin}` that decodes to `{:r, 7, :pong}`.
- [ ] **Step 2: Run** `mix test`. Expected: FAIL.
- [ ] **Step 3: Implement the modules and the test support.**
- [ ] **Step 4: Run** `mix test`. Expected: PASS, and no leftover `standalone_server.py` processes (`pgrep -f standalone_server` prints nothing).
- [ ] **Step 5: Commit** `jj commit lib test -m "Session file, transport behaviour, TCP transport, test servers"`

### Task 8: `Poser.Client` core: connect, requests, timeouts, bad frames

**Files:**
- Create: `lib/poser/client.ex`, `test/poser/client_test.exs`

**Interfaces:**
- Consumes: Tasks 6–7.
- `start_link(opts)`. Options and defaults:
  - `:name` (`Poser.Client`)
  - `:session` (`Session.default_path()`)
  - `:host`, `:port`, `:token` (each overrides the session file)
  - `:transport` (`Poser.Transport.TCP`)
  - `:call_timeout` (120_000)
  - `:connect_timeout` (5_000)
  - `:heartbeat_interval` (5_000)
  - `:heartbeat_timeout` (15_000)
  - `:backoff_initial` (250)
  - `:backoff_max` (10_000)
- Public functions. Every one accepts `opts` with `:server` (default `Poser.Client`), `:timeout`, and `:kw` (a keyword list, sent as a map with binary keys):
  - `call(name, args \\ [], opts \\ []) :: {:ok, term} | {:error, Poser.Error.t}`
  - `invoke(%Handle{}, method, args \\ [], opts \\ [])`
  - `get_attr(%Handle{}, attr, opts \\ [])`
  - `batch(ops, opts \\ []) :: {:ok, [term]} | {:error, Poser.Error.t}`. Each op is one of:
    - `{:call, name, args}` or `{:call, name, args, kw}`
    - `{:invoke, h, method, args}` or `{:invoke, h, method, args, kw}`
    - `{:get_attr, h, attr}`
  - `release(handle_or_handles, opts \\ []) :: {:ok, non_neg_integer} | {:error, Poser.Error.t}`
  - `raw(module, function, args \\ [], opts \\ [])`
  - `ping(opts \\ []) :: {:ok, microseconds} | {:error, Poser.Error.t}`
  - `stats(opts \\ []) :: {:ok, %{"handles" => n, "generation" => g}} | {:error, Poser.Error.t}`
  - `info(opts \\ []) :: {:ok, map} | {:error, Poser.Error.t}`
  - `status(opts \\ []) :: :connected | :disconnected`
- Behaviour:
  - **Connecting:** `init` returns `{:ok, state, {:continue, :connect}}`. The handshake is synchronous (`recv_frame` with `connect_timeout`), then `activate`. On success, increment `epoch` and dispatch the `:connected` event with the hello info. On failure, schedule a retry with backoff.
  - **While disconnected,** requests return `{:error, %Poser.Error{kind: :disconnected}}` at once.
  - **Request ids** come from a counter. `pending` is `%{id => %{from: from | nil, timer: ref | nil}}`.
  - **Timeouts:** callers use `GenServer.call(..., :infinity)`. The client runs its own timer per request (`:timeout` option, else `call_timeout`; `:infinity` means no timer). When the timer fires, it replies `kind: :timeout` and drops the pending entry.
  - **Replies for unknown ids** (late, after a timeout) are dropped. Any handles inside them are released with a fire-and-forget `R`.
  - **Handles from an older epoch** in the arguments return `kind: :stale_handle` without being sent.
  - **Events:** `{:M, {name, payload}}` is passed to `Poser.Events.dispatch/2`.
  - **Undecodable frames:** `Logger.warning("poserx: dropped undecodable frame (N bytes)")`, and the client keeps running.

- [ ] **Step 1: Write failing tests** against `PoserTest.Standalone` (start a client with `session: s.session`, and wait for `:connected` with `Poser.Events.subscribe(:connected)`):
  - `test "call and invoke round trip"`: `{:ok, %Handle{class: "SceneType"} = s} = call("Scene")`, then `invoke(s, "Frame") == {:ok, 0}`.
  - `test "kwargs are passed by name"`
  - `test "unicode names round trip"`: `invoke(scene, "Actor", ["Ünïcode 頭"])` then `invoke(a, "Name") == {:ok, "Ünïcode 頭"}`.
  - `test "python errors come back as Poser.Error"`: `kind: :python, class: "ValueError"`.
  - `test "batch with result references"`: `batch([{:call, "Scene", []}, {:invoke, {:result, 0}, "NumFrames", []}])` gives `{:ok, [%Handle{}, 30]}`. `{:result, 0}` is allowed where a handle is expected.
  - `test "a blocked main thread times out the caller but ping still answers"`: `call("Sleep", [1.0], timeout: 200)` gives `{:error, %{kind: :timeout}}`, `ping()` returns `{:ok, _}` while the sleep is still running, and then `call("AppVersion")` gives `{:ok, "fake-14"}`.
  - `test "late reply handles are released"`: `call("SleepThenScene", [0.5], timeout: 100)` times out. After 1 s, `stats()["handles"] == 0`.
  - `test "strict mode rejects raw calls"`: start the standalone server with `mode: :strict`; `raw("math", "sqrt", [4])` gives `kind: :not_allowed`, and `info()` shows `mode: :strict, api_hash: "mini"`.
  - `test "undecodable frames are dropped and the client survives"`: a `ScriptedServer` replies with `{:raw, <<131, 119, 5, "zzzzz">>}` to the first request and correctly to `ping`. The first call times out (`timeout: 200`), `ping()` then gives `{:ok, _}`, and `status() == :connected`.
  - `test "requests while disconnected fail fast"`: a client pointed at a nonexistent session file returns `kind: :disconnected` within 50 ms.
- [ ] **Step 2: Run** `mix test test/poser/client_test.exs`. Expected: FAIL.
- [ ] **Step 3: Implement `Poser.Client`.**
- [ ] **Step 4: Run** `mix test`. Expected: PASS.
- [ ] **Step 5: Commit** `jj commit lib test -m "Poser.Client: requests, timeouts, late replies, bad frames"`

### Task 9: Handle ownership, reconnect, epochs, heartbeat

**Files:**
- Modify: `lib/poser/client.ex`
- Create: `test/poser/client_lifecycle_test.exs`

**Interfaces:**
- Consumes: Task 8's `Poser.Client`.
- Ownership: `owners :: %{pid => MapSet.t(handle_id)}` and `monitors :: %{pid => ref}`.
  - Handles in a successful reply (from `call`, `invoke`, `get_attr`, `batch` or `raw`) are recorded under the caller's pid, which is then monitored.
  - `release/2` removes ids from every owner.
  - `{:DOWN, ...}` for an owner sends a fire-and-forget `R` for its ids.
- Disconnects (transport closed, or a heartbeat timeout):
  - Every pending caller gets `kind: :disconnected`.
  - Owners and monitors are cleared.
  - The `:disconnected` event is dispatched with the reason.
  - A reconnect is scheduled with backoff, re-reading the session file.
- Heartbeat: every `heartbeat_interval` ms, send `{:ping, id}` with `from: nil`. Record `last_inbound` (monotonic ms) on every frame. If `now - last_inbound > heartbeat_timeout`, disconnect with reason `:heartbeat_timeout`.

- [ ] **Step 1: Write failing tests:**
  - `test "handles are released when their owner exits"`: a `Task` calls `call("Scene")` and returns. `stats()["handles"]` reaches 0 within 1 s (poll every 50 ms).
  - `test "explicit release"`: `release(h) == {:ok, 1}`, then `invoke(h, "Frame")` gives `kind: :stale_handle`.
  - `test "generation change stales handles and is broadcast"`: subscribe to `:generation_changed`, then `raw("fake_poser", "NewScene", [])`. Receive `{:poser_event, :generation_changed, 1}`; `invoke(old, "Frame")` gives `kind: :stale_handle`.
  - `test "reconnects after the server restarts, and old handles are stale"`:
    1. Get `h`, then `Standalone.stop!`.
    2. Expect `{:poser_event, :disconnected, _}`; a pending call fails with `:disconnected`.
    3. Run `Standalone.start!(session: same_path)`, which gives a new port and token.
    4. Expect `{:poser_event, :connected, _}` within 5 s.
    5. `invoke(h, "Frame")` gives `kind: :stale_handle` (local epoch check), and `call("Scene")` works.
  - `test "heartbeat timeout drops a silent connection"`: a `ScriptedServer` that answers hello and then `:ignore`s everything. With `heartbeat_interval: 50, heartbeat_timeout: 200`, `{:poser_event, :disconnected, :heartbeat_timeout}` arrives within 1 s.
  - `test "frame events reach subscribers"`: run the standalone server with `--events 0.1` (add an `events:` option to `Standalone.start!`) and receive `{:poser_event, :frame_changed, n}` with an integer `n`.
- [ ] **Step 2: Run** `mix test test/poser/client_lifecycle_test.exs`. Expected: FAIL.
- [ ] **Step 3: Implement ownership, disconnect handling, reconnect and heartbeat.**
- [ ] **Step 4: Run** `mix test`, three times in a row to catch timing flakes. Expected: PASS every time.
- [ ] **Step 5: Commit** `jj commit lib test -m "Poser.Client: handle ownership, reconnect with epochs, heartbeat"`

### Task 10: Live-Poser tests and setup guide

**Files:**
- Create: `test/live/live_poser_test.exs` (`@moduletag :poser`), `guides/setup.md`, `plans/phase1-findings.md`
- Modify: `README.md` (replace the generated stub with a one-paragraph description and links to `guides/setup.md` and `guides/limitations.md`)

**Interfaces:**
- Consumes: the whole stack. The client uses the default session path.

- [ ] **Step 1: Write the live tests**, which must run against a real Poser with a figure loaded:
  - `call("Scene")` gives a `SceneType` handle.
  - `invoke(scene, "NumFrames")` gives a positive integer.
  - `invoke(scene, "Figures")` gives a list of `%Handle{class: "FigureType"}` with labels.
  - `batch` of `Scene` → `Frame` works.
  - `call("AppVersion")` gives a binary.
  - `stats()` shows `handles > 0`, then after `release` of every handle, 0.
  - `ping()` takes under 50 ms.
- [ ] **Step 2: Write `guides/setup.md`**, with every command as one copy-pasteable line:
  - **Firewall rule (one time),** run in an admin PowerShell. This is the exact one-liner from `plans/phase0-findings.md`.
  - **Deploy:** `scripts/deploy_addon.sh`, then **restart Poser** (add-ons can't be reloaded).
  - **Optional strict mode:** `%APPDATA%\PoserBridge\config.json` containing `{"mode": "strict"}`.
  - **Run the tests:** `mix test`, `mix test --only poser`, and the Python unittest command.
- [ ] **Step 3: Live check (user).** The user runs `scripts/deploy_addon.sh`, restarts Poser, loads a scene with a figure, then runs `mix test --only poser`. Expected: all live tests PASS. Record the results, and anything that surprised you, in `plans/phase1-findings.md`.
- [ ] **Step 4: Run** `mix test` and the Python tests one last time. Expected: PASS.
- [ ] **Step 5: Commit** `jj commit test/live guides README.md plans/phase1-findings.md -m "Live-Poser tests and setup guide"`, then `jj bookmark create phase-1 -r @-` and `jj git push --bookmark phase-1`.

---

## Not in this phase

- **`Poser.Launcher`** (start `Poser.exe` and wait for the session file): stays in Phase 5. With no add-on reload, a launcher would be useful earlier; revisit after Phase 2.
- **Generated `Poser.Api.*` modules and docstring signature parsing:** Phase 2. `%Poser.Handle{}` stands in for them until then.
- **Other `SceneObserver` events** (`objects_added` and the rest): Phase 4. Each new event name must be added to `Poser.Codec.known_atoms/0`.
- **TLS, remote access, `with_scope`, `!` variants:** Phases 3 and 5.
