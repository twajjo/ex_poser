# Limitations

Poserx aims to cover the whole PoserPython API, meaning everything the
`poser` module exposes inside Poser 14. This guide lists what it can't
cover, or can only cover differently from Python, and what to do instead.

> **Status:** written during Phase 0, before the library exists. The Elixir
> examples use the API planned in `plans/elixir-poser-bridge-plan.md`
> (`Poser.Client`, the generated `Poser.Api.*` modules and `Poser.Events`).
> Poser method names follow the manual and research notes; confirm them
> against `priv/poser_api.json` and update this guide as the library ships.

## 1. "Complete" means "found by introspection"

The Poser 14 manual has no method reference. The generated bindings come from
`priv/poser_api.json`, which `python/introspect_poser.py` writes from inside
Poser. It finds:

- everything visible through `dir(poser)`: functions, classes and constants;
- the classes of objects reachable from `poser.Scene()` through a list of
  getters with no side effects (figures, actors, parameters, materials,
  shader trees, cameras, lights and so on).

A class that only appears in an unusual scene, such as a cloth simulator or
hair group when the sample scene had none, can be missing from the dump, and
so has no generated module. The coverage manifest from `mix poser.gen` lists
what was found and what was skipped.

**Workaround:** call any method by its Python name on any handle.

```elixir
# No generated function for this method? Call it by name.
{:ok, value} = Poser.Client.invoke(handle, "SomeUndocumentedMethod", [1, "two"])
```

**Fix:** load a scene that contains the missing object type, run the
introspection again, and regenerate with `mix poser.gen`. Use the overrides
file for methods whose signatures can't be discovered.

### Signatures may be unknown

Builtin C methods often have no Python signature. When neither
`inspect.signature` nor the docstring gives one, the generated function takes
a plain argument list:

```elixir
# Signature known:
Poser.Api.ParmType.set_value(parm, 88.0)

# Signature unknown: arguments go in a list, unchecked until Poser runs them
Poser.Api.SomeType.some_method(obj, [arg1, arg2])
```

Python raises any argument error, and it comes back as
`{:error, %Poser.Error{class: "TypeError", ...}}` instead of failing at
compile time.

## 2. Features that need a person at the Poser window

Some Poser features are interactive dialogs or palettes rather than API calls:

| Feature | What happens |
|---|---|
| wxPython panels and windows (`poser.WxAuiManager()`, `wx.*`) | Not exposed. A UI built in Poser's window belongs in a Python add-on, not in Elixir. |
| Poser dialog classes (file pickers, message boxes) | Calling one opens a **modal dialog on the Poser screen** and stalls the bridge until someone closes it (see section 5). Strict mode will block them. |
| Walk Designer, Talk Designer | Interactive tools. Use their output files instead: load a saved walk or lip-sync result as a pose. |
| Bake Transforms, Recalculate Dynamics and other menu commands | Supported only if introspection shows a matching API call or `poser.ProcessCommand` id; otherwise listed as unsupported in the manifest. |

```elixir
# Works: applying the result of an interactive tool
Poser.Api.SceneType.load_library_pose(scene, "Runtime:Libraries:Pose:MyWalk.pz2")

# Blocks the bridge: a dialog waits for a person at the Poser window
Poser.Client.call("poser.DialogFileChooser", [...])   # don't do this
```

## 3. Callbacks become events

Some PoserPython methods take a Python function and call it later, for
example an update or event callback on a parameter or the scene. A Python
function can't be passed across the bridge, so poserx registers a Python stub
that sends the callback's arguments to Elixir as an event.

```elixir
# Python:  parm.SetUpdateCallback(my_fn)
# Elixir:  subscribe, then receive messages
{:ok, ref} = Poser.Api.ParmType.set_update_callback(parm)
receive do
  {:poser_callback, ^ref, args} -> IO.inspect(args, label: "parameter updated")
end
```

**The limitation:** Poser never waits for the Elixir side.

- A callback whose **return value** matters to Poser (for example one meant
  to change a parameter's value as it's computed) can't be written in Elixir.
  The stub returns a fixed default. Write that logic as a Python helper in
  the add-on.
- Events arrive **later than the change**, after Poser returns to idle and
  after a network hop. Use them to react, not to step in mid-change.

`SceneObserver` notifications such as `frameChanged` and `objectsAdded`
arrive the same way, as `Poser.Events` topics:

```elixir
Poser.Events.subscribe(:frame_changed)
receive do
  {:poser_event, :frame_changed, frame} -> IO.puts("now on frame #{frame}")
end
```

## 4. Add-on hooks outside the `poser` module

`SceneDataSaver` (custom data saved inside `.pz3` files) and `PrefsSaver`
(add-on preferences) are methods Poser calls on a registered add-on class,
not functions in the `poser` API. Poser calls them synchronously while saving
or loading, so Elixir can't answer them live.

| Hook | Status |
|---|---|
| `SceneObserver` callbacks | Supported, as events (section 3) |
| `SceneDataSaver.saveData` / `loadData` | Not supported yet. A possible design: the bridge stores a map Elixir set earlier and hands it to Poser on save. |
| `PrefsSaver` | Not supported. Keep Elixir-side configuration in your application. |

## 5. Performance and blocking

Poser's API may only be called on its main (GUI) thread, so every bridge call
is queued there and runs **one at a time, in order**. That has three effects.

**Each call costs a round trip.** A loop that's instant in local Python is
slow call by call over the bridge:

```elixir
# Slow: one round trip per vertex (could be tens of thousands)
for i <- 0..(n - 1) do
  {:ok, v} = Poser.Api.GeomType.vertex(geom, i)
  Poser.Api.VertType.x(v)
end

# Better: send many operations as one batch frame (one main-thread turn)
Poser.batch(fn b ->
  for i <- 0..(n - 1), do: Poser.Batch.invoke(b, geom, "Vertex", [i])
end)
```

**Heavy work belongs inside Poser.** For bulk geometry or per-frame keyframe
work, write a small Python helper in the add-on and call it once. Results can
come back as numpy arrays, which arrive as `{:ndarray, dtype, shape, binary}`.

**Long calls block everything.** While Poser renders, the main thread is
busy: the bridge, every other call and Poser's own UI wait until it finishes.
A modal dialog (missing texture, overwrite prompt) stalls the queue until
someone clicks it.

```elixir
# Renders need a long or :infinity timeout; the default is 30 s
Poser.Api.SceneType.render(scene, timeout: :infinity)
```

Expect `{:error, %Poser.Error{kind: :timeout}}` when Poser is stuck behind a dialog. The call may
still run once the dialog is dismissed.

## 6. Object handles

Poser objects (scenes, figures, actors, parameters and so on) never leave
Poser. Elixir holds **handles** to them: `%Poser.Handle{class: "ActorType", ...}`.

- **Handles go stale** when the scene is replaced (new scene, scene opened)
  or when the bridge reconnects. Using one returns
  `{:error, %Poser.Error{kind: :stale_handle}}`. The idiomatic structs
  (`Poser.Figure`, `Poser.Actor`, `Poser.Parameter`) hold no handle and
  resolve their path on every call, so they don't go stale:

  ```elixir
  {:ok, actor} = Poser.Figure.actor(figure, "hip")  # works after a reconnect too
  ```

- **A deleted object** can leave a handle that Poser itself rejects. That
  shows up as a Python error, never as a crash.
- **Handles are held until released.** Release them with
  `Poser.Client.release/2`; the add-on also drops a connection's handles when
  it closes.

## 7. Strict mode blocks arbitrary Python

Dev mode (the default before publishing) allows the raw `X` call into any
Python module. Strict mode (the default when published, and always for remote
access) allows only names in the generated allowlist, which is the full
`poser` API and nothing else.

```elixir
# Dev mode: works.  Strict mode: {:error, %Poser.Error{kind: :not_allowed}}
Poser.Client.raw("os", "listdir", ["C:\\"])

# Both modes: everything in the poser API
Poser.Api.scene()
```

If you rely on a Python helper of your own in strict mode, add it to the
add-on and the allowlist explicitly.

## 8. Environment

- **Poser must be running.** PoserPython only exists inside `Poser.exe`, and
  Poser has no headless or command-line scripting mode. `Poser.Launcher`
  (planned) can start it and wait for the bridge.
- **One Poser per bridge port.** A second Poser instance can't bind the same
  dev port.
- **Python 3.7.** The add-on runs on Poser's embedded Python 3.7.9 and uses
  only the standard library, so it can't depend on newer packages.
- **Poser updates can change the API.** When the `api_hash` in the handshake
  changes, run the introspection again and regenerate the bindings.
- **WSL 2 on Windows 10** reaches Poser through the WSL adapter address, not
  `localhost`, and needs a firewall rule scoped to that adapter (see the
  development setup in the plan).
