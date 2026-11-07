# Phase 0 findings

Implementation plan: `plans/read-the-plans-in-melodic-cerf.md`.

## Done and verified (2026-10-30, without Poser)

### Vendored codec (`python/poser_bridge/erlterms.py`)
- erlport has no v0.11.0 tag on GitHub (the newest is v0.10.1). The file was taken from the Hex tarball `erlport-0.11.0`, `priv/python3/erlport/erlterms.py`.
- Four local changes, each marked `poserx:` in the file:
  1. **Security.** The decoder ran `pickle.loads` on opaque `python` terms, so anyone who could send a frame could run code inside Poser. Removed.
  2. The encoder no longer pickles unknown types. It raises an error instead; `codec.to_wire` turns objects into `{:obj, class, repr}` first.
  3. **OTP 26+ atoms.** `term_to_binary` writes atoms as `SMALL_ATOM_UTF8_EXT` (tag 119), which erlport couldn't decode. Tags 118 and 119 are now supported.
  4. Atoms are encoded as `SMALL_ATOM_UTF8_EXT`.

### Transport and threading model (standalone server, fake `poser`)
Loopback in WSL, 200 samples each. `ping` is answered on the reader thread; `ping_main` goes through the fake-main-thread queue:

| Python | ping median / p95 | ping_main median / p95 |
|---|---|---|
| 3.10.12 | 144 / 246 µs | 223 / 324 µs |
| 3.7.9 | 156 / 269 µs | 260 / 380 µs |

The real `wx.CallAfter` latency inside Poser is under "Live Poser" below.

Also verified on both Python versions:
- the hello handshake returns `%{mode: :dev, protocol: 1, poser_version, python_version}`;
- `X poser_bridge.spike scene_summary` returns a map with string keys;
- `X math sqrt [-1]` returns `{:e, id, {:python, "ValueError", "math domain error", traceback}}`;
- `frame_changed` events arrive between replies;
- a bad token closes the connection.

### Python 3.7
- **Poser's `Runtime\Python\python.exe` can't run on its own.** `python37._pth` lists a `python37.zip` that doesn't exist, so the stdlib in `lib\` is never found ("No module named 'encodings'"). Poser must set these paths itself when it embeds Python.
- So the 3.7 check uses mise `python 3.7.9`, now in `mise.toml` (the plan had put this in Phase 1). All add-on files byte-compile and run under it.
- Because of this, the WSL → Windows network path can't be tested before Poser itself runs.

### WSL networking
- `ipconfig` shows `Ethernet adapter vEthernet (WSL)` with IPv4 `172.22.192.1`. This matches `ip route show default` in WSL, and `net.wsl_adapter_ip()` parses it correctly.

### Introspection script
- Run against a fake `poser` under 3.7, it found module classes, live-discovered classes and constants. It flagged `SetUpdateCallback` as a callback, and recorded a raising getter under `discovery_errors`. `scripts/summarize_api.exs` prints the summary.

## Live Poser (2026-11-01, Poser 14, embedded Python 3.7.9)

### Add-on load
- [x] The add-on loads at startup. Poser listens on `127.0.0.1:47800` and `172.22.192.1:47800` (`Get-NetTCPConnection`), and `%APPDATA%\PoserBridge\session.json` is written with both hosts.

### Firewall
- [x] **No prompt appeared, but the connection was silently blocked.** From WSL, `connect` timed out (dropped packets, not refused). Windows doesn't classify `vEthernet (WSL)` as a known network, so the default inbound block applies.
- Fix, run once in an admin PowerShell:
  `New-NetFirewallRule -DisplayName "Poser bridge (WSL only)" -Direction Inbound -Action Allow -Protocol TCP -LocalPort 47800 -InterfaceAlias "vEthernet (WSL)" -Program "D:\Program Files\Poser Software\Poser 14\Poser.exe"`
- The rule names the adapter, not an address, because the WSL NAT address can change after a reboot. Any existing *block* rule for `Poser.exe` must be removed first, because block rules take precedence over allow rules.

### Round trip from WSL
- [x] The handshake returns `%{mode: :dev, protocol: 1, poser_version: "14", python_version: "3.7.9"}`.
- [x] `scene_summary` matches the open scene (464 actors, 9 figures, 30 frames). The error path returns a Python `ValueError` with its traceback.
- Latency at idle, 200 samples:

| | median | p95 | max |
|---|---|---|---|
| `ping` (reader thread) | 339 µs | 501 µs | 764 µs |
| `ping_main` (`wx.CallAfter`) | 445 µs | 584 µs | 739 µs |

  Across runs, `ping_main` p95 ranged from 0.6 to 2 ms, with one outlier at 9.6 ms.

### `frame_changed` events
- [x] `frameChanged` fires once per committed frame change, and `Scene().Frame()` already holds the new value when it runs. Pressing *next frame* three times gave 1, 2, 3.
- **Dragging the slider sends one event, on release** (19), not one per frame passed. A client that needs live updates during a drag has to poll.

### Stalls
`ping_main` at 20 samples (30 s timeout), by phase:

| Situation | `ping` median | `ping_main` median | `ping_main` max |
|---|---|---|---|
| Idle | 0.34 ms | 0.45 ms | 0.74 ms |
| Modal dialog (Render Settings) | 0.47 ms | 0.47 ms | 0.67 ms |
| Render: texture loading | 0.35 ms | **no reply within 30 s** | — |
| Render: indirect light precalc | 0.86 ms | 173 ms | 2.05 s |
| Render: subsurface scattering | 0.63 ms | 116 ms | 287 ms |
| Render: rendering | 0.89 ms | 127 ms | 388 ms |

- The reader thread (`ping`) answers in about 1 ms in every phase. Use it as the liveness check, to tell "Poser is busy" apart from "the bridge is dead".
- Modal dialogs don't block `wx.CallAfter`; wxPython's modal loop keeps processing queued calls.
- During a render, the main thread processes queued calls between chunks of work, with delays of 0.1–0.4 s (up to about 2 s during indirect light). **Texture loading blocks the main thread completely.** Client timeouts for main-thread calls must allow for that, and it can exceed 30 s on large scenes.
- Not tested yet: `poser.SetRenderInSeparateProcess(...)` may keep the main thread free during renders.

### Reload
- [x] **Add-ons can't be reloaded without restarting Poser.** `poserScripts/poserStartup.py` imports each folder in `addons/` once, at startup. The `poser` module has `RegisterAddon` but no unregister or reload function, and no UI option to reload was found. After running `scripts/deploy_addon.sh`, restart Poser.

### Introspection
- [x] `priv/poser_api.json` (322 KiB, `api_hash 4ebd1aa0…`) contains 64 module functions, 37 classes, 1,045 methods, 514 constants, 14 callback-related methods and 0 discovery errors. The largest classes are `ActorType` (182 methods), `SceneType` (175), `TempestOptionsType` (92) and `FigureType` (88).
- `inspect.signature` fails on every function and method (0 of 1,109) because they're implemented in C. Every docstring includes a typed signature, e.g. `<StringType> AppVersion()`. Wrapper generation should parse signatures from the docstrings.
