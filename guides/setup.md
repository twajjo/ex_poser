# Setup

Poserx talks to Poser 14 through the Poser Bridge add-on. Poser runs on
Windows; Elixir can run on the same machine or in WSL 2.

## 1. Deploy the add-on

From the repo root (in WSL):

```
scripts/deploy_addon.sh
```

This copies `python/poser_bridge/` and `priv/poser_api.json` into
`Runtime/Python/addons/poser_bridge/`. Set `POSER_ADDONS` if Poser is
installed somewhere else.

**Restart Poser after every deploy.** Poser imports add-ons once, at startup,
and has no way to reload them.

When the add-on starts, Poser's Python output shows:

```
poser_bridge: listening on 127.0.0.1:47800
poser_bridge: listening on 172.22.192.1:47800
poser_bridge: loaded (dev mode), session file C:\Users\<you>\AppData\Roaming\PoserBridge\session.json
```

## 2. Allow WSL through the Windows Firewall (once)

Windows treats the `vEthernet (WSL)` adapter as an unidentified network and
silently drops inbound connections on it, so connecting from WSL times out.
Run this once in an **administrator** PowerShell:

```
New-NetFirewallRule -DisplayName "Poser bridge (WSL only)" -Direction Inbound -Action Allow -Protocol TCP -LocalPort 47800 -InterfaceAlias "vEthernet (WSL)" -Program "D:\Program Files\Poser Software\Poser 14\Poser.exe"
```

Adjust `-Program` if Poser is installed elsewhere. If Windows created a
*block* rule for Poser earlier, remove it first; block rules win over allow
rules:

```
Get-NetFirewallApplicationFilter | ? Program -like '*Poser*' | Get-NetFirewallRule | ? Action -eq Block | Remove-NetFirewallRule
```

## 3. Connect

```elixir
{:ok, _} = Poser.Client.start_link()
{:ok, scene} = Poser.Client.call("Scene")
{:ok, frame} = Poser.Client.invoke(scene, "Frame")
```

The client finds the session file on its own (through `/mnt/c` in WSL); set
`POSERX_SESSION` to point somewhere else.

## 4. Strict mode (optional)

Dev mode allows raw Python calls and any public method. Strict mode only
allows what `poser_api.json` lists and refuses raw calls. To turn it on,
create `%APPDATA%\PoserBridge\config.json` containing:

```
{"mode": "strict"}
```

Then restart Poser. The log line says `loaded (strict mode)`.

## 5. Tests

The Python tests that send numpy arrays need numpy 1.19.5 (Poser bundles numpy 1.19), installed once:

```
mise exec -- python -m pip install -r python/requirements-dev.txt
```

Without it those tests are skipped.

Fake-poser tests (no Poser needed):

```
mix test
```

```
mise exec -- python -m unittest discover -s python/tests -t python -v
```

Live tests, with Poser running and a scene with a figure loaded:

```
mix test --only poser
```

## 6. Generated API

`lib/poser/api/` holds one module per PoserPython class, `lib/poser/api.ex`
the module-level functions and `lib/poser/const.ex` the constants. All three
are generated from `priv/poser_api.json` and committed. Don't edit them: put
corrections in `priv/poser_api_overrides.json` and regenerate.

Regenerate:

```
mix poser.gen
```

Check that the committed files are up to date (`mix test` also does this):

```
mix poser.gen --check
```

`priv/poser_api_manifest.json` records what was generated, what was skipped
and why. To print a summary:

```
elixir scripts/summarize_api.exs
```

When Poser is updated, its `api_hash` changes: run the introspection script
again (see `plans/phase0-findings.md`), copy the new `poser_api.json` into
`priv/`, regenerate and review the diff.

Smoke test: with Poser running and a scene loaded, call every generated
getter on up to 3 objects of each class. It prints a summary and writes
`tmp/poser_smoke.json`:

```
mix poser.smoke
```

Getters that return one handle per vertex or polygon are skipped unless you
add `--include-heavy`.
