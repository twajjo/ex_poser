# Setup

ExPoser talks to Poser 14 through the Poser Bridge add-on. Poser runs on
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
New-NetFirewallRule -DisplayName "Poser bridge (WSL only)" -Direction Inbound -Action Allow -Protocol TCP -LocalPort 47800 -InterfaceAlias "vEthernet (WSL)" -Program "D:\Program Files\Poser Software\Poser 14\ExPoser.exe"
```

Adjust `-Program` if Poser is installed elsewhere. If Windows created a
*block* rule for Poser earlier, remove it first; block rules win over allow
rules:

```
Get-NetFirewallApplicationFilter | ? Program -like '*Poser*' | Get-NetFirewallRule | ? Action -eq Block | Remove-NetFirewallRule
```

## 3. Connect

```elixir
{:ok, _} = ExPoser.Client.start_link()
:ok = ExPoser.Client.await_connected()
{:ok, scene} = ExPoser.Client.call("Scene")
{:ok, frame} = ExPoser.Client.invoke(scene, "Frame")
```

`ExPoser.Client.await_connected/1` waits for the handshake, which runs in the
background, so the first call doesn't fail with `:disconnected`. The client
finds the session file on its own (through `/mnt/c` in WSL); set
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

Regenerating the `ExPoser.Api` modules and the smoke test are in
[Generated API](generated-api.md#regenerating).
