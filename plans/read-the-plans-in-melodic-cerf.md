# Phase 0 implementation: spikes and API discovery

## Context

`plans/elixir-poser-bridge-plan.md` describes an Elixir library that drives Poser 14. It talks to a Poser add-on over a socket, using ErlPort's term format. Phase 0 is meant to prove three risky points before any real protocol or library code gets written:

1. Poser auto-loads our add-on from `Runtime\Python\addons\`.
2. A background socket thread can hand work to Poser's main thread with `wx.CallAfter` without crashing, at a latency we can live with.
3. Elixir in WSL 2 can reach a socket served from Poser on Windows. Windows 10 WSL is NAT only, so this has to go through the WSL adapter IP, a firewall rule and a token.

Phase 0 also produces `priv/poser_api.json`. This introspection dump defines what "complete PoserPython API" means for the code generator in Phase 2.

**Exit criteria (from the main plan):** an iex/Elixir round trip to the live Poser works, and `poser_api.json` exists with a size and coverage summary.

### Facts checked on this machine
- This is the Poser PC. Poser is at `/mnt/d/Program Files/Poser Software/Poser 14/`. `addons/` holds `poseraddon.py` and `PythonShell/__init__.py`, the reference add-on pattern.
- `poserStartup.py` does `__import__(folder)` for every folder in `addons/`, with `addons/` on `sys.path`. So `addons/poser_bridge/__init__.py` must call `poser.RegisterAddon(...)`.
- `poseraddon.Addon.addonInfo` is a **class-level dict**. PythonShell mutates it in place, which leaks into every add-on. We build our own dict instead and set `apiversion: "1.2"`, which is needed for `cameraChanged`/`lightsChanged`.
- Poser's `Runtime/Python/python.exe` is a real CPython 3.7 with `python37._pth`. We can run it from WSL as the **Python 3.7 compatibility check**, with no mise Python 3.7 needed yet.
- The tools on hand are Elixir 1.20.4, OTP 29 (with the built-in `JSON` module), jj and system `python3` 3.10. The Windows user is `Jeff`, so `APPDATA` is at `/mnt/c/Users/Jeff/AppData/Roaming`. The repo is not yet a jj repo; leave that to the user (`jj git init --colocate`).

## Design decisions for the spike

- **Wire format:** 4-byte big-endian length followed by ETF. On the Elixir side that's `:gen_tcp` with `packet: 4`, decoded with `:erlang.binary_to_term(bin, [:safe])`.
- **Codec conventions** (fixed now; Phase 1 builds on them):
  - Outbound: `str` becomes a UTF-8 binary, `None` becomes `nil`, `bool` becomes `true`/`false`, `dict` becomes a map, and tuples and lists keep their shape.
  - Inbound: every binary decodes to `str`. Raw bytes, when needed later, arrive as `{:bytes, bin}`. The atom `nil` becomes `None`.
  - Non-plain values have no handle table yet (that's Phase 1), so they come back as `{:obj, class_name, repr}`.
- **Phase 0 ops**, a subset of protocol v1:
  - `{:hello, %{token, protocol: 1}}` must be the first frame, or the connection is closed. The reply is `{:r, 0, %{protocol, poser_version, python_version, mode: :dev}}`.
  - `{:ping, id}` is answered **on the reader thread**, which measures transport latency alone.
  - `{:ping_main, id}` goes through `wx.CallAfter`, which measures transport plus event loop.
  - `{:X, id, module, function, args}` is the dev-mode raw call, run on the main thread. For the spike it calls helpers in `poser_bridge.spike`, for example `frame()` or `scene_summary()`.
  - Errors return `{:e, id, {:python, class, message, traceback_lines}}`.
  - Events go out as `{:M, {:frame_changed, n}}`, sent from `SceneObserver.frameChanged`.
- **Bind addresses:** `127.0.0.1` plus the `vEthernet (WSL…)` adapter IPv4, on a fixed dev port **47800**. The adapter IP comes from parsing `ipconfig` output with stdlib `subprocess` in `load()`. If the adapter isn't up because WSL isn't running yet, bind loopback only and log it; this is a known limitation for now.
- **Session file:** `%APPDATA%\PoserBridge\session.json` holds `{port, token, protocol, hosts}`.
- **Poser-free core:** `codec.py`, `server.py` and `net.py` never import `poser` or `wx`. The server takes a `submit(fn)` callable: `wx.CallAfter` inside Poser, and a queue drained by a fake "main" thread when standalone. `__init__.py` registers the add-on only if `import poser` succeeds, so the package also imports outside Poser. All Python code must run on 3.7: no walrus operator, no `socket.create_server`.

## Files to create

| Path | Purpose |
|---|---|
| `mise.toml` | Pin `erlang = "29.1.2"`, `elixir = "1.20.4-otp-29"` (Python 3.7 is added in Phase 1) |
| `python/poser_bridge/__init__.py` | Guarded `from . import addon`, which registers the add-on when `poser` exists |
| `python/poser_bridge/erlterms.py` | Vendored from erlport v0.11.0 `priv/python3/erlport/erlterms.py`, keeping the BSD-3 notice. Adjust any `erlport.*` imports to be self-contained |
| `python/poser_bridge/codec.py` | `read_frame(sock)`, `write_frame(sock, term)`, `to_wire`/`from_wire` conversion walks over erlterms |
| `python/poser_bridge/server.py` | `Server(hosts, port, token, submit, log)`: one listener socket per host, accept/reader daemon threads, write lock, op dispatch, `send_event`, `stop()` |
| `python/poser_bridge/net.py` | `wsl_adapter_ip()` (parses `ipconfig`), `write_session(...)` |
| `python/poser_bridge/addon.py` | `Bridge(poseraddon.Addon, poseraddon.SceneObserver)` with its own `addonInfo`. `load()` starts the Server with `submit=wx.CallAfter`; `unload()` stops it; `frameChanged` emits the event; ends with `poser.RegisterAddon("com.geekware.poserBridge", Bridge())` |
| `python/poser_bridge/spike.py` | Main-thread helpers: `frame()`, `scene_summary()` (frame, frame count, figure names, actor count) |
| `python/standalone_server.py` | Runs `Server` outside Poser with a queue-based fake main thread and a fake `spike`, for testing transport and networking without Poser |
| `python/introspect_poser.py` | Run in Poser via *File > Run Python Script*. Writes `%APPDATA%\PoserBridge\poser_api.json` (see below) |
| `scripts/deploy_addon.sh` | Copies `python/poser_bridge/` to `…/Runtime/Python/addons/poser_bridge/`, excluding `__pycache__`, then reminds you to restart Poser |
| `scripts/phase0_ping.exs` | Elixir client (details below) |
| `scripts/summarize_api.exs` | Reads `priv/poser_api.json` with `JSON.decode!/1` and prints the coverage summary |
| `priv/poser_api.json` | Committed introspection output |
| `plans/phase0-findings.md` | Results: latencies, firewall behaviour, load and reload behaviour, API counts, surprises |

The Elixir app structure (`mix.exs`, `--sup`, `lib/`) is left alone until Phase 1.

### `scripts/phase0_ping.exs`
- **Session file:** taken from `--session PATH`, else `/mnt/c/Users/Jeff/AppData/Roaming/PoserBridge/session.json`. Detect the user with `cmd.exe /c echo %APPDATA%` plus `wslpath`, falling back to `Jeff`.
- **Host:** `--host`, else the WSL adapter IP from `session.hosts`, else the default gateway from `ip route show default`.
- **Run:** connect, send `hello`, then 200× `ping` and 200× `ping_main`. Print min, median, p95 and max in µs. Call `X poser_bridge.spike scene_summary`, then wait 10 s and print any `frame_changed` events while you scrub the timeline in Poser.

### `python/introspect_poser.py` output
- `meta`: Poser version (`poser.Version()` or whatever exists), `sys.version`, timestamp, and the sha256 of the canonical JSON body.
- `functions`: every callable in `dir(poser)` that isn't a class, with `name`, `doc`, `signature` (from `inspect.signature`, then `__text_signature__`, else null) and a `callback` flag (whether the doc mentions "callback").
- `classes`: found two ways.
  - (a) Module attributes that are types.
  - (b) `type()` of live objects reached through a **curated list of side-effect-free accessors** on the current scene: `Scene`, `CurrentActor`/`CurrentFigure`, `Figures`, `Actors`, `Parameters`, `Materials`, `ShaderTree`, `Nodes`, `Inputs`, `Cameras`, `Lights`, `Geometry`, `CurrentFireFlyOptions`, `CurrentSuperFlyOptions`, `MovieMaker`, `ImExporter`, and so on.
  - Each class records how it was found (`via`) and its methods, with the same fields as `functions`.
  - Every accessor is wrapped in try/except and logged, so a missing method only shows up in the JSON as `"discovery_errors"`.
- `constants`: `k*` names mapped to their values.
- Run it with a sample scene that has a figure loaded, so (b) finds as much as possible.

## Execution order
1. Scaffold `mise.toml`, the `python/` and `scripts/` folders, and vendor `erlterms.py` (download from the erlport GitHub tag v0.11.0).
2. Write `codec.py`, `server.py`, `net.py`, then `standalone_server.py` and `phase0_ping.exs`.
3. Test standalone in WSL first, then with Poser's Windows `python.exe`. That is the Python 3.7 check plus the WSL→Windows network and firewall path, all without Poser.
4. Write `addon.py`, `spike.py` and `__init__.py`. Deploy, start Poser, and run the ping.
5. Write `introspect_poser.py`, run it in Poser, copy the JSON to `priv/`, and run the summary.
6. Record everything in `plans/phase0-findings.md`.

## Verification
- **Standalone (WSL):** `python3 python/standalone_server.py --session /tmp/...` alongside `elixir scripts/phase0_ping.exs --session ... --host 127.0.0.1`. Check that the hello reply arrives, latency stats print, `X` returns the fake summary, a bad token closes the connection, and a raised exception comes back as `{:e, …}` with a traceback.
- **3.7 + Windows networking:** run `"/mnt/d/…/Runtime/Python/python.exe" python\standalone_server.py` (Windows path), then ping from WSL using the WSL adapter IP. Note whether a Windows Firewall prompt appears. If it does, create the scoped rule from an elevated PowerShell: `New-NetFirewallRule -DisplayName "PoserBridge dev (WSL)" -Direction Inbound -Protocol TCP -LocalPort 47800 -InterfaceAlias "vEthernet (WSL*)" -Action Allow`. Check the real alias with `Get-NetAdapter`.
- **Live Poser:**
  - `scripts/deploy_addon.sh`, then start Poser. The load message appears in Poser's Python output, and `session.json` is written.
  - Run `phase0_ping.exs`. `scene_summary` matches the open scene, and `frame_changed` events arrive while scrubbing.
  - Also run `ping_main` during a render and with a missing-texture dialog open, and record the stall behaviour.
- **Introspection:** `elixir scripts/summarize_api.exs` prints counts of classes, methods, methods with signatures, callback-flagged methods and constants. Review these together, as Phase 0 step 4 asks.
