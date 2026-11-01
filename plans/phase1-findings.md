# Phase 1 findings

Implementation plan: `plans/phase1-protocol-and-transport.md`.

## Live Poser (2026-11-01)

The add-on was deployed with `scripts/deploy_addon.sh` and Poser 14 was restarted. The scene had 464 actors, 9 figures and 30 frames.

### Phase 0 ping script against the Phase 1 add-on
- The hello reply now includes `mode: :dev` and `api_hash`, so the new add-on is the one running, and protocol 1 works from WSL over the `vEthernet (WSL)` adapter.
- Latency is unchanged from Phase 0 (200 samples):

  | | median | p95 |
  |---|---|---|
  | `ping` (reader thread) | 380 µs | 557 µs |
  | `ping_main` (`wx.CallAfter`) | 484 µs | 647 µs |

  One earlier run had a single 5.8 ms reader-thread outlier; nothing repeatable.
- `scene_summary` matched the open scene. The error path still returns a `ValueError` with its traceback.
- Scrubbing the timeline sends `frame_changed` events (for example frames 16 and 10).

### Live tests
`mix test --only poser`: 5 tests, 0 failures, 4.2 s. These cover:
- a `SceneType` handle from `Scene`;
- `NumFrames`;
- `Figures` as labelled `FigureType` handles;
- a `Scene` → `Frame` batch;
- `AppVersion`;
- `stats` handle counts dropping to 0 after `release`;
- `ping` under 50 ms.

### Surprises
- A scene with no figures makes `Figures` return `[]`, and the live tests need at least one figure. `guides/setup.md` already says to load a figure first.

## Automated suites
- Elixir: `mix test`, 55 passed, 5 excluded (the live tests).
- Python 3.7.9: `mise exec -- python -m unittest discover -s python/tests -t python`, 58 tests OK.

## Final review
A fresh reviewer read the whole branch. One Critical and four Important findings were fixed, each with a test that failed first:
- Old handles could resolve to a different object after a reconnect. Handle ids are now server-wide with a random start, and client epochs are unique in the VM.
- Bad arguments (malformed batch steps, pids, dates, invalid UTF-8, bad options) crashed the client. They now return `:bad_request`.
- An undecodable request dropped the connection. Elixir now rejects such arguments before sending, and the add-on answers `bad_request` and keeps the connection.
- A slow handshake blocked every caller. The handshake now runs in a task, so requests fail fast while disconnected.
- Connect failures were silent. They are now logged once per distinct error, and `:disconnected` errors carry `details.reason`.

## Deferred to later phases
- Late `batch_failed` replies don't release their partial handles.
- Handles stored just before a failed wrap or encode stay in the table until the LRU cap evicts them.
- Main-thread socket sends have no timeout, so a client that stops reading could stall Poser's UI.
- A malformed `config.json`, or an API dump without `classes`, stops the add-on with a raw traceback.
- `:nan` and `:infinity` read from Poser go back out as strings rather than floats.
- There's no frame-size or connection limit before a client authenticates.
- Empty owner records and monitors aren't cleaned up.
