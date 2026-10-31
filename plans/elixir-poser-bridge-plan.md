# Plan: An Elixir API for Poser 14 via an ErlPort-style bridge

Sources:
- ErlPort Python docs: http://erlport.org/docs/python.html
- ErlPort source: https://github.com/erlport/erlport (Hex: `erlport` 0.11.0, July 2023, maintained fork)
- Poser 14 manual, PoserPython chapter (see `poser14-automation-discussion.md`)
- Local install: `D:\Program Files\Poser Software\Poser 14`

## Goals (decided)

| Question | Decision | Effect on the plan |
|---|---|---|
| Use case | **A general-purpose library first**: Elixir modules covering the **complete PoserPython API**. Use cases such as animation come afterwards. | Generating bindings from introspection is the backbone. A general handle system covers every Poser object type. Animation helpers move to the last phase. |
| Host | **Same machine now, remote later** | Loopback TCP first, behind a `Poser.Transport` behaviour, so TLS or an SSH tunnel can be added without touching the API. |
| Audience | **Me first, publish later** | Dev-mode passthrough is on by default. The whitelist, protocol versioning and packaging layout are designed in from Phase 1, so publishing means switching modes rather than rewriting. |

---

## 1. The key finding: ErlPort can't be used as-is

ErlPort works by **spawning** a Python interpreter as an OS process and talking to it over stdin/stdout (`python:start/1` → Erlang port). Its Python side (`erlport/erlproto.py`) reads with `os.read()` on file descriptors 0/1 (or 3/4; `nouse_stdio` isn't supported on Windows).

The `poser` module only exists **inside `Poser.exe`**. It runs an embedded Python 3.7 (`python37.dll`, Python files in `Runtime\Python`). Elixir can't spawn that interpreter, and Poser has no documented headless or command-line scripting mode. A `python.exe` started by ErlPort could never `import poser`.

**So:** keep ErlPort's **wire format and term codec**, and replace its **process transport** with a socket served by a Poser add-on.

| ErlPort piece | Reuse? | Notes |
|---|---|---|
| `erlport/erlterms.py`: Erlang External Term Format codec (pure Python, includes `Map`) | **Yes, vendor it** | BSD-3, keep the notice. Works on Python 3.7. |
| Message shapes `('C', id, …)`, `('r', id, value)`, `('e', id, error)`, `('M', payload)` | **Yes, extend** | Errors come back as `{:python, class, message, traceback}`, same as ErlPort. |
| `erlport/erlproto.py` `Port` (fd transport) | No | Replaced by a socket reader. |
| `erlport/erlang.py` `MessageHandler` | Only as a model | Its call loop runs on the reader thread; Poser needs calls on the main thread. |
| Elixir/Erlang `python:start`/`call` (Hex `erlport`) | No | It expects an Erlang port. A small client over `Poser.Transport` replaces it. |
| Pythonx and other embedded-CPython NIFs | Not applicable | They embed their *own* Python. You need the one inside Poser. |

One codec detail matters. ErlPort encodes Python `str` as an Erlang **charlist**, `bytes` as a binary and `None` as `undefined`. The bridge's encoder should turn `str` into UTF-8 binaries and `None` into `nil`.

---

## 2. What the local Poser 14 install provides

Checked on this machine:

- **Embedded Python 3.7** with `wx` (wxPython 4.1.2a1), `numpy` 1.19, `scipy`, `twisted`, `debugpy`, `requests` and `pip` in `Runtime\Python\lib\site-packages`. ErlPort isn't installed, and it doesn't need to be because we vendor one file.
- **Add-on auto-loading** (`Runtime\Python\poserScripts\poserStartup.py`) at startup:
  - imports every folder in `Runtime\Python\addons\`;
  - also imports any `install_python.json` package with `"addon": 1` found under each Library's `Runtime\Python\<product>\<folder>\`.
- **Add-on base classes** in `Runtime\Python\addons\poseraddon.py`:
  - `Addon` (`load`/`unload`);
  - `SceneObserver` (`objectsAdded`, `objectsDeleted`, `objectsRenamed`, `objectSelected`, `sceneCreated`, `sceneDeleting`, `frameChanged`, `materialsChanged`, `cameraChanged`, `lightsChanged`);
  - `SceneDataSaver`, `PrefsSaver`.
- **`debugpy`** is bundled, so the add-on can be stepped through from VS Code while Poser runs.

Constraints from the manual:
- Don't call the Poser API from secondary threads.
- Don't create your own wx event loop.
- Strings are Unicode.

---

## 3. Architecture

```
┌──────────────── Elixir (BEAM) ────────────────┐        ┌──────────────── Poser.exe ─────────────────────┐
│ Poser.* idiomatic layer (hand-written)        │        │ addons/poser_bridge/                           │
│ Poser.Api.* generated: one module per class   │        │   Bridge(poseraddon.Addon, SceneObserver)      │
│        │                                      │        │   handles.py   (object table + generations)    │
│ Poser.Client (GenServer: ids, timeouts,       │        │   dispatch.py  (C / I / B / G ops, policy)     │
│              handles, events)                 │        │   codec.py     (vendored erlterms + hooks)     │
│        │                                      │        │                                                │
│ Poser.Transport  (behaviour)                  │ frames │  reader thread ── recv frame ──┐               │
│   ├─ Poser.Transport.TCP   (now, loopback)    │◄──────►│  (no Poser API calls here)     │ wx.CallAfter  │
│   └─ Poser.Transport.TLS   (later, remote)    │  ETF   │                                ▼               │
│        │                                      │        │  main thread: dispatch ──► poser.* API         │
│ Poser.Events (Registry) ◄──── {:M, event} ────│        │  SceneObserver / callbacks ──► {M, event}      │
└───────────────────────────────────────────────┘        └────────────────────────────────────────────────┘
```

### Wire protocol (v1, versioned from day one)

Every frame is a 4-byte big-endian length followed by an ETF term. This is ErlPort's default `packet: 4`. Elixir decodes with `:erlang.binary_to_term(bin, [:safe])`.

| Direction | Term | Meaning |
|---|---|---|
| E→P | `{:hello, %{protocol: 1, token: t, client: "poserx x.y"}}` | Handshake. The reply carries `%{protocol: 1, poser_version, python_version, api_hash, mode: :dev \| :strict}`. |
| E→P | `{:C, id, "poser.Scene", args, kwargs}` | Call a **module-level** function of `poser`. |
| E→P | `{:I, id, handle, "SetValue", args, kwargs}` | **Invoke a method** on a live object. |
| E→P | `{:G, id, handle, "attr"}` | Read an attribute (rare; most of the API is methods). |
| E→P | `{:B, id, [op, ...]}` | **Batch** of `C`/`I` ops in one main-thread tick. Later ops can use earlier results via `{:result, n}`. |
| E→P | `{:R, id, [handle, ...]}` | Release handles. |
| E→P | `{:X, id, module, function, args}` | **Dev mode only**: raw ErlPort-style call into any Python module. |
| P→E | `{:r, id, value}` / `{:e, id, {:python, class, msg, traceback}}` | Result / error. |
| P→E | `{:M, {event, payload}}` | Async event or callback. |

A protocol mismatch fails the handshake with a clear error, so later versions of the add-on and the Hex package can't silently disagree.

### Threading model (the crux)

1. A daemon **reader thread** owns the socket. It decodes frames and never touches `poser`.
2. For each request it calls `wx.CallAfter(dispatch, msg)`. `wx.CallAfter` is thread-safe, and the work then runs on Poser's main (GUI) thread.
3. `dispatch` calls the Poser API, encodes the result, and writes the reply under a write lock.
4. Consequences:
   - Calls execute **one at a time, in order**.
   - A long render blocks both Poser's UI and the bridge until it finishes. The Elixir side needs per-call timeouts (default 30 s, `:infinity` for render).
   - If Poser shows a modal dialog (missing texture, etc.), the queue stalls. This needs testing (see Risks).
   - Batches (`B`) are the main performance tool. Each round trip costs one event-loop turn.

### Object handles (general, covers every Poser type)

Full API coverage means dozens of object types: scene, figures, actors, parameters, materials, shader trees and nodes, cameras, lights, geometry, render options, MovieMaker, ImExporter, dialogs and more. Name paths don't scale to that, so use a **handle table**:

- **Python side:**
  - Any result that isn't a plain value (number, str, bool, None, list/tuple/dict of those, numpy array) is stored in `handles[id] = obj`.
  - It is returned as `{:poser_obj, class_name, id, generation, label}`, where `label` is the object's `Name()`/`InternalName()` when it has one, for debugging.
- **Generation counter:**
  - It is bumped on `sceneCreated` / `sceneDeleting`, which clears the table.
  - Using a stale handle returns `{:e, id, {:stale_handle, …}}`, never a crash.
- **Release:**
  - Elixir releases handles explicitly (`Poser.release/1`), by scope (`Poser.with_scope/1`), or by owner-process monitoring in `Poser.Client`.
  - The table is also bounded (LRU) as a safety net.
- **Elixir side:** handles decode to structs per class, e.g. `%Poser.Api.ActorType{ref: …}`, so pattern matching and protocols (`Inspect`, `String.Chars`) work.
- **Stable references for the idiomatic layer:** path helpers (`Poser.Figure.by_name/1`, `Poser.Actor.by_internal_name/2`) re-resolve a fresh handle when the old one is stale.

### Security and modes

| | Dev mode (default for now) | Strict mode (for publishing) |
|---|---|---|
| Bind | `127.0.0.1` plus, when configured, the **WSL virtual adapter** (`vEthernet (WSL)`) address only (see section 8) | `127.0.0.1`, or TLS listener when remote is enabled |
| Auth | Token from `%APPDATA%\PoserBridge\session.json` (read from WSL at `/mnt/c/Users/<you>/AppData/Roaming/PoserBridge/`) | Token, plus TLS client cert or SSH tunnel for remote |
| `C`/`I`/`G` | Anything on `poser` objects | Only names present in the generated `poser_api.json` **allowlist** |
| `X` raw call | Allowed | Disabled |

The allowlist comes from introspection, so strict mode still exposes the **complete** PoserPython API while blocking arbitrary Python (`os`, `subprocess`, …).

---

## 4. Generated bindings: how "complete" is achieved

Phase 0's introspection script runs inside Poser and writes `poser_api.json`:

- every attribute of the `poser` module: functions, classes and **constants** (`kParmCode*`, `kLightType*`, `kImExport*`, …);
- for each class (`SceneType`, `FigureType`, `ActorType`, `ParmType`, `MaterialType`, `ShaderTreeType`, `ShaderNodeType`, `GeomType`, `FireFlyOptionsType`, `MovieMakerType`, `ImExporterType`, … whatever really exists): its methods and docstrings;
- signatures where `inspect.signature` works. Builtin C methods often have no signature, so fall back to parsing the docstring, then to variadic args;
- the Poser version, the Python version, and a hash of the whole file.

A Mix task `mix poser.gen priv/poser_api.json` then generates:

| Generated | Example |
|---|---|
| One module per Python class | `Poser.Api.ActorType.set_parameter/3`, … with `@doc` from the docstring and `@spec` where a signature is known |
| Module-level functions | `Poser.Api.scene/0` → `poser.Scene()`, `Poser.Api.process_command/1` |
| Constants | `Poser.Const.parm_code(:xscale)`; compile-time lookup with friendly atoms |
| Typespecs and structs | `%Poser.Api.ActorType{}` and so on |
| A manifest | Coverage report: every Python method mapped, with any skipped ones listed and the reason |

Rules:
- Names become snake_case (`SetValue` → `set_value`). The original name stays in `@doc` and in the wire call.
- Python's keyword arguments become a trailing `opts` keyword list.
- Methods that take Python **callbacks** (for example `SetEventCallback`, `SetUpdateCallback`, if present) are mapped to Elixir subscriptions. The bridge registers a Python stub that emits `{:M, {:callback, ref, args}}`, and the reply is not awaited.
- Generated code is committed, so diffs show API changes between Poser versions. When a Poser update changes the hash, regenerate.

On top of the generated layer sits a **thin hand-written idiomatic layer**: `Poser.Scene`, `Poser.Figure`, `Poser.Actor`, `Poser.Parameter`, `Poser.Material`, `Poser.Camera`, `Poser.Light`, `Poser.Render`, `Poser.IO`. It provides pipe-friendly functions, `!` variants, tagged tuples and batching helpers. It must never be the *only* way to reach a feature: the generated layer always is.

---

## 5. Phased plan

### Phase 0: Spikes and API discovery (1–2 days)
1. Install a minimal add-on folder `Runtime\Python\addons\poser_bridge\` that prints from `load()`, and confirm Poser imports it at startup.
2. Spike the threading model: a background thread with `wx.CallAfter` → `poser.Scene().Frame()`. Confirm there are no crashes, and measure the latency of a round trip.
3. Spike the transport: a loopback socket plus the vendored `erlterms.py`. Ping it from `iex` with `:gen_tcp`, and check whether a Windows Firewall prompt appears.
4. **Write `poser_api.json`** with the introspection script described in section 4. Review it together: how many classes and methods there are, how many have usable signatures, and which ones take callbacks.

**Exit criteria:** an iex round trip works, and `poser_api.json` exists with a size and coverage summary.

### Phase 1: Protocol and transport core
- **Python** (`poser_bridge` package):
  - handshake with versioning, session file and token;
  - codec hooks (`str`, `None`, numpy, handles);
  - handle table with generations;
  - `C`/`I`/`G`/`B`/`R`/`X` dispatch;
  - dev and strict policy, with strict reading the allowlist from `poser_api.json`;
  - clean shutdown in `unload()`.
- **Elixir** (`mix new poserx --sup`, app `:poserx`):
  - `Poser.Transport` behaviour plus `Poser.Transport.TCP`;
  - `Poser.Client` GenServer: pending map, per-call timeouts, handle ownership and release, reconnect with backoff, and handles marked stale on reconnect;
  - a minimal `Poser.Events` Registry.
- **Tests:**
  - Python dispatcher tests with a **fake `poser` module**, run under any Python 3.7 (with `-I` off; the embedded `python.exe` needs its `._pth`).
  - Elixir tests against that same server running outside Poser.
  - Integration tests tagged `@tag :poser` run only when a live Poser is reachable.

### Phase 2: Code generation and full raw coverage
- `mix poser.gen`: modules, constants, docs, specs and the coverage manifest.
- Smoke-test every generated *getter* against a sample scene (no side effects), to catch signature and encoding problems at scale.
- Map return types: lists of objects become lists of handles, tuples stay tuples, numpy arrays become `{:ndarray, dtype, shape, binary}` (with optional Nx conversion).

### Phase 3: Idiomatic layer
- Hand-written modules over the most-used types (listed in section 4).
- Batching helpers: `Poser.batch(fn b -> … end)` collects ops into one `B` frame.
- Error normalisation into `%Poser.Error{class, message, traceback}`, and stale-handle recovery for path-based references.

### Phase 4: Events and callbacks
- `SceneObserver` callbacks become `Poser.Events` topics (`:frame_changed`, `:objects_added`, `:scene_created`, …).
- Python API callbacks are bridged as subscriptions (see section 4).

### Phase 5: Packaging, docs, remote readiness
- Python package:
  - ZIP with one top-level folder;
  - `install_python.json` with `"addon": 1`, installable via Poser's *Install from ZIP Archive*.
- Elixir package:
  - ExDoc site including the generated modules, plus a Livebook getting-started guide;
  - `Poser.Launcher` starts `Poser.exe` via a `Port` and waits for the session file.
- **Remote:**
  - `Poser.Transport.TLS` and a TLS listener option in the add-on (Python 3.7 `ssl` is enough);
  - strict mode on by default when remote;
  - documented SSH-tunnel alternative.
- Switch the default to strict mode and publish (Hex plus the add-on ZIP).

### Phase 6: Use cases (after the library is solid)
- **Animation:**
  - a keyframe DSL (tracks as Elixir data, compiled to one batch);
  - interpolation helpers;
  - pose and BVH pipelines;
  - dynamics recalculation.
- **Rendering pipelines:** a batch job runner with a manifest and retries; Queue Manager hand-off.
- Live control: LiveView or Livebook panels driven by `Poser.Events`.

---

## 6. Risks and open questions

| Risk | Mitigation |
|---|---|
| The manual has no method reference, so "complete" is defined by what introspection finds | Phase 0 review of `poser_api.json`; the coverage manifest makes any gaps explicit. |
| Builtin methods may lack signatures, so arity and kwargs are unknown | Fall back to docstring parsing, then a variadic `args` list; fix individual methods in a small overrides file. |
| Handles can leak, or refer to deleted objects | Generations, owner monitoring, LRU cap, the `R` op. |
| Main-thread execution: renders freeze the bridge, and modal dialogs stall the queue | Async render pattern with completion events; generous timeouts; test with missing-texture scenes. |
| Some features (Talk/Walk Designer, Bake Transforms) may be GUI-only | `poser.ProcessCommand(id)` if introspection shows it; otherwise list them as unsupported in the manifest. |
| Callback-taking methods, and re-entrancy when a callback fires during a call | Callbacks only enqueue events, never block on Elixir. |
| Remote access widens the attack surface | Strict mode plus TLS or SSH; dev mode refuses any bind other than loopback and the WSL adapter. |
| WSL 2 on Windows 10 uses NAT, so `localhost` from WSL doesn't reach Windows, and the host's WSL-adapter IP can change on reboot | Bridge binds to the adapter address it finds at startup and records it in `session.json`; one firewall rule scoped to that adapter (section 8). |
| Python 3.7 is end-of-life; Poser updates change the API | Stdlib-only Python side; regenerate on api_hash change and diff the generated code. |

---

## 7. Starting skeletons (untested sketches)

**Poser side, `Runtime\Python\addons\poser_bridge\__init__.py`:**

```python
import json, os, secrets, socket, struct, threading
import wx, poser, poseraddon
from . import erlterms                  # vendored from erlport (BSD-3)
from .handles import HandleTable
from .policy import Policy              # dev / strict (allowlist from poser_api.json)

A = erlterms.Atom
PROTOCOL = 1

class Bridge(poseraddon.Addon, poseraddon.SceneObserver):
    def __init__(self):
        self.addonInfo = dict(poseraddon.Addon.addonInfo, id="com.example.poserBridge",
                              name="Poser Bridge", version="0.1", observer=1, apiversion="1.2")
        self.handles, self.policy = HandleTable(), Policy.load()
        self.conn, self.wlock = None, threading.Lock()

    def load(self):
        self.token = secrets.token_hex(16)
        self.srv = socket.socket()               # create_server() is 3.8+; Poser has 3.7
        self.srv.bind(("127.0.0.1", 0)); self.srv.listen(1)
        d = os.path.join(os.environ["APPDATA"], "PoserBridge"); os.makedirs(d, exist_ok=True)
        with open(os.path.join(d, "session.json"), "w") as f:
            json.dump({"port": self.srv.getsockname()[1], "token": self.token, "protocol": PROTOCOL}, f)
        threading.Thread(target=self._accept, daemon=True).start()

    def _accept(self):                   # background thread: socket only, never poser
        while True:
            self.conn, _ = self.srv.accept()
            try:
                while True:
                    wx.CallAfter(self._dispatch, self._read())
            except (EOFError, OSError):
                self.conn = None

    def _dispatch(self, msg):            # main thread: safe to call poser
        tag, mid = msg[0], msg[1]
        try:
            if tag == b"C":              # module-level poser function
                _, _, name, args, kw = msg
                value = self.policy.module_fn(name)(*self._in(args), **self._in(kw))
            elif tag == b"I":            # method on a handle
                _, _, h, meth, args, kw = msg
                obj = self.handles.get(h)                  # raises StaleHandle
                value = self.policy.method(obj, meth)(*self._in(args), **self._in(kw))
            # ... G, B, R, X, hello
            self._send((A(b"r"), mid, self._out(value)))
        except Exception as e:
            self._send((A(b"e"), mid, (A(b"python"), type(e).__name__, str(e), [])))

    def _out(self, v):                   # plain values pass through; objects become handles
        return self.handles.wrap(v)

    def sceneDeleting(self, scene):
        self.handles.new_generation()

    def frameChanged(self):
        self._send((A(b"M"), (A(b"frame_changed"), poser.Scene().Frame())))

    # _in/_read/_send: decode handles, 4-byte framing, erlterms with str->binary / None->nil hooks

poser.RegisterAddon("com.example.poserBridge", Bridge())
```

**Elixir side, transport behaviour and client:**

```elixir
defmodule Poser.Transport do
  @callback connect(opts :: keyword) :: {:ok, term} | {:error, term}
  @callback send_frame(conn :: term, iodata) :: :ok | {:error, term}
  @callback close(conn :: term) :: :ok
  # incoming frames arrive as {:poser_frame, binary} / {:poser_closed, reason} messages
end

defmodule Poser.Client do
  use GenServer

  def call(fun, args \\ [], opts \\ []), do: request({:C, fun, args, Keyword.get(opts, :kw, [])}, opts)
  def invoke(%{ref: h}, meth, args \\ [], opts \\ []),
    do: request({:I, h, meth, args, Keyword.get(opts, :kw, [])}, opts)

  defp request(req, opts),
    do: GenServer.call(__MODULE__, {:req, req}, Keyword.get(opts, :timeout, 30_000))

  @impl true
  def handle_call({:req, req}, from, s) do
    id = System.unique_integer([:positive])
    frame = req |> Tuple.insert_at(1, id) |> :erlang.term_to_binary()
    :ok = s.transport.send_frame(s.conn, frame)
    {:noreply, put_in(s.pending[id], from)}
  end

  @impl true
  def handle_info({:poser_frame, bin}, s) do
    case :erlang.binary_to_term(bin, [:safe]) |> Poser.Codec.decode() do
      {:r, id, v} -> reply(s, id, {:ok, v})
      {:e, id, err} -> reply(s, id, {:error, Poser.Error.from(err)})
      {:M, event} -> Poser.Events.dispatch(event); {:noreply, s}
    end
  end

  defp reply(s, id, r) do
    {from, pending} = Map.pop(s.pending, id)
    if from, do: GenServer.reply(from, r)
    {:noreply, %{s | pending: pending}}
  end
end

# Generated (by mix poser.gen), e.g.:
defmodule Poser.Api.ActorType do
  @moduledoc "PoserPython `ActorType` (generated from poser_api.json)."
  defstruct [:ref, :label]

  @doc "Python: `actor.Parameter(name)`. Docstring text from Poser here."
  def parameter(%__MODULE__{} = actor, name), do: Poser.Client.invoke(actor, "Parameter", [name])
end
```

The init, handshake, reconnect and handle-release logic are left for Phase 1.

---

## 8. Development environment

Two machines, one toolchain:

| | Poser PC (Windows 10 Pro 22H2, build 19045) | Laptop |
|---|---|---|
| Linux | WSL 2, Ubuntu (same release as the laptop) | WSL 2, Ubuntu |
| Toolchain | mise → Erlang, Elixir, Python 3.7 (for testing the add-on outside Poser), jj | same `mise.toml` |
| Version control | jj (colocated with Git) → GitHub | jj → GitHub |
| Poser | Poser 14 on Windows | none: Phase 1 fake-`poser` tests only |

**Checked on the Poser PC (2026-10-30):**
- WSL is installed with default version 2 and the hypervisor is running. There are no distributions yet, and the WSL component dates from 2022, so update it.
- 48 GB RAM; 69 GB free on C:, 1.4 TB free on D:.
- No git, jj, mise, Erlang or Elixir on Windows. VS Code and winget are present.

**Cygwin/MSYS2: not recommended.** Erlang, Elixir, mise and jj all have native Linux builds that run unchanged in WSL. Under Cygwin they would be different builds, behave differently from the laptop, and Erlang isn't supported there.

### Repo layout and deploy

One repository, `poserx`, kept in the **WSL filesystem** (`~/src/elixir/poserx`). Building there is much faster than on `/mnt/c`.

```
poserx/
  plans/                  # this plan and the Poser research notes
  mise.toml               # erlang, elixir, python 3.7, jj
  mix.exs, lib/, test/    # Elixir library
  python/poser_bridge/    # the Poser add-on (vendored erlterms.py, dispatch, handles, ...)
  python/tests/           # fake-poser tests, run with mise's Python 3.7
  priv/poser_api.json     # introspection output, committed
  scripts/deploy_addon.sh # rsync python/poser_bridge -> Poser's addons folder
```

- `deploy_addon.sh` copies the add-on to `/mnt/d/Program Files/Poser Software/Poser 14/Runtime/Python/addons/poser_bridge/`. Restart Poser (or reload the add-on) to pick it up.
- Poser should import from a real Windows folder, not a `\\wsl$` UNC path.
- On the laptop, the same repo runs all non-`@tag :poser` tests.

### Networking: WSL 2 on Windows 10 is NAT only

- Mirrored networking (where `localhost` is shared both ways) requires **Windows 11 22H2+**. On Windows 10, WSL falls back to NAT.
- From WSL, Windows is reachable at the **host's WSL-adapter IP**: the default gateway in `ip route show default`, or the `nameserver` in `/etc/resolv.conf` on older setups.
- So, during development:
  1. The bridge binds to `127.0.0.1` **and** the `vEthernet (WSL)` adapter address. That address can change after a reboot, so the bridge looks it up at startup and writes it into `session.json`.
  2. Elixir in WSL reads `session.json` through `/mnt/c/...`, connects to that host and port, and sends the token.
  3. A Windows Firewall inbound rule allows the bridge's fixed dev port **only on the WSL adapter**. This means the dev port is fixed (e.g. 47800) rather than random.
- This makes WSL a real second host from Phase 1. The token, handshake, protocol versioning and `Poser.Transport` behaviour get exercised early, which is a good rehearsal for the remote phase.

Sources: [WSL networking](https://learn.microsoft.com/en-us/windows/wsl/networking), [WSL config (networkingMode needs Windows 11 22H2+)](https://learn.microsoft.com/en-us/windows/wsl/wsl-config), [WSL interop](https://learn.microsoft.com/en-us/windows/dev-environment/wsl-interop).
