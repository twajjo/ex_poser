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

The real `wx.CallAfter` latency inside Poser is still to be measured.

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

## Pending: needs live Poser

- [ ] **Add-on load.** It is deployed to `…/Runtime/Python/addons/poser_bridge/`. Start Poser and check its Python output for `poser_bridge: listening on …` and `loaded, session file …`.
- [ ] **Firewall.** Is there a prompt when Poser binds `172.22.192.1:47800`? If so, add a rule scoped to the WSL adapter (see the plan) rather than accepting the prompt's defaults.
- [ ] **Round trip from WSL.** Run `elixir scripts/phase0_ping.exs`, record the real `ping_main` latency, check that `scene_summary` matches the open scene, and watch for `frame_changed` while scrubbing.
- [ ] **Stalls.** Measure `ping_main` during a render and while a modal dialog is open (for example, a missing texture).
- [ ] **Reload.** Can the add-on be reloaded without restarting Poser, or does port 47800 stay bound?
- [ ] **Introspection.** Load a figure, run *File > Run Python Script* on `\\wsl.localhost\Ubuntu-22.04\home\twajjo\src\elixir\poserx\python\introspect_poser.py`, copy `%APPDATA%\PoserBridge\poser_api.json` to `priv/`, run `elixir scripts/summarize_api.exs`, and review the results.
