# Concepts

## Poser and Elixir, side by side

| Poser | Elixir | Notes |
|---|---|---|
| The open scene, with its single global current frame | `Poser.Scene` functions (no struct; there is one scene) | Poser has one current frame per scene. The `frame:` option sets it, does the work, then restores it. Only `Poser.Scene.set_frame/2` leaves it moved. |
| Figure (in the GUI's figure menu, e.g. "Figure 1") | `%Poser.Figure{internal, name}` | `internal` is the key. `name` is the GUI label and can be renamed or repeated. |
| Actor: a body part, prop, camera or light | `%Poser.Actor{figure, internal, name}` | Body parts have `figure` set. Props, cameras and lights have `figure: nil` and are found with `Poser.Scene.actor/2`. |
| Dial, or "parm" in PoserPython | `%Poser.Parameter{actor, internal, name}` | The internal name (`InternalParameter`) is the key, e.g. `"yrot"` for the dial labelled "yRotate". |
| Internal name | A step in the struct's path | `Poser.Ref.path/1` shows it: `[figure: "Figure 1", actor: "BODY:1", parm: "yrot"]`. |
| Frame number | An integer from 0, as in PoserPython | GUI frame 1 is `frame: 0`. The docs give both numbers wherever a frame appears. |
| Keyframe on a dial | A frame number in `Poser.Parameter.keyframes/2` | Every dial has a key at frame 0 (GUI frame 1). Setting a value keys it at that frame. |
| PoserPython object (`ActorType`, `ParmType`, …) | `%Poser.Handle{}`, from `handle/2` | A live, server-side reference that goes stale on reconnect. The idiomatic structs never hold one. |
| One Python main-thread turn | One batch chunk | Poser's UI is busy while a chunk runs, which is why chunks are capped at 2000 wire ops. |
| Python exception | `{:error, %Poser.Error{kind: :python}}` | With the Python `class`, `message` and `traceback`. |

## The five ideas

### 1. You name things; you don't hold them

A `%Poser.Parameter{}` is a path of internal names from the scene down to
one dial. Every call resolves the path inside Poser, in the same request as
the work, and releases what it looked up. Nothing goes stale, so a struct
from yesterday's session works after Poser restarts, as long as the figure
is still in the scene.

```elixir
bend = Poser.Figure.parameter!(fig, "Left Forearm", "Bend")
# ... Poser restarts, the client reconnects ...
Poser.Parameter.value!(bend)
#=> 45.0
```

### 2. Every call is a batch

Each function is a one-op `Poser.Batch`, so single calls and batches behave
the same: same lookups, same frame handling, same errors. Batching by hand is
more of the same, in one round trip.

```elixir
Poser.batch!(fn b ->
  b
  |> Poser.Batch.set(bend, 30.0)
  |> Poser.Batch.set(twist, -10.0)
  |> Poser.Batch.get(bend)
end)
#=> [:ok, :ok, 30.0]
```

### 3. Time is an option

Poser has one global current frame, and PoserPython reads and writes dials at
it. Here a frame is an option instead: `frame: 11` (GUI frame 12) moves
Poser there, does the work and moves it back.

```elixir
Poser.Parameter.set_value(bend, 30.0, frame: 11)
#=> {:ok, :ok}
Poser.Scene.frame()
#=> {:ok, 0}
```

### 4. Failures are values, and there is no rollback

Every function returns `{:ok, value}` or `{:error, %Poser.Error{}}`, and a
`!` variant raises. Poser has no transactions: when the second op of a batch
fails, the first stays applied.

```elixir
Poser.batch(fn b ->
  b
  |> Poser.Batch.set(bend, 30.0)
  |> Poser.Batch.set(missing, 1.0)
end)
#=> {:error, %Poser.Error{kind: :not_found, details: %{index: 1, ...}}}
# bend is now 30.0
```

### 5. There's always a way down

`handle/2` on a figure, actor or dial gives a live `%Poser.Handle{}` for the
generated `Poser.Api` modules, which cover every PoserPython method. The
handle is yours to release.

```elixir
{:ok, h} = Poser.Parameter.handle(bend)
Poser.Api.ParmType.min_value(h)
#=> {:ok, -180.0}
Poser.Client.release([h])
```

See [Generated API](generated-api.md) for working with handles directly.
