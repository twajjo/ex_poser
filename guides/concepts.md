# Concepts

## Poser and Elixir, side by side

| Poser | Elixir | Notes |
|---|---|---|
| The open scene, with its single global current frame | `ExPoser.Scene` functions (no struct; there is one scene) | Poser has one current frame per scene. The `frame:` option sets it, does the work, then restores it. Only `ExPoser.Scene.set_frame/2` leaves it moved. |
| Figure (in the GUI's figure menu, e.g. "Figure 1") | `%ExPoser.Figure{internal, name}` | `internal` is the key. `name` is the GUI label and can be renamed or repeated. |
| Actor: a body part, prop, camera or light | `%ExPoser.Actor{figure, internal, name}` | Body parts have `figure` set. Props, cameras and lights have `figure: nil` and are found with `ExPoser.Scene.actor/2`. |
| Dial, or "parm" in PoserPython | `%ExPoser.Parameter{actor, internal, name}` | The internal name (`InternalParameter`) is the key, e.g. `"yrot"` for the dial labelled "yRotate". |
| Internal name | A step in the struct's path | `ExPoser.Ref.path/1` shows it: `[figure: "Figure 1", actor: "BODY:1", parm: "yrot"]`. |
| Frame number | An integer from 0, as in PoserPython | GUI frame 1 is `frame: 0`. The docs give both numbers wherever a frame appears. |
| Keyframe on a dial | A frame number in `ExPoser.Parameter.keyframes/2` | Every dial has a key at frame 0 (GUI frame 1). Setting a value keys it at that frame. |
| PoserPython object (`ActorType`, `ParmType`, …) | `%ExPoser.Handle{}`, from `handle/2` | A live, server-side reference that goes stale on reconnect. The idiomatic structs never hold one. |
| One Python main-thread turn | One batch chunk | Poser's UI is busy while a chunk runs, which is why chunks are capped at 2000 wire ops. |
| Python exception | `{:error, %ExPoser.Error{kind: :python}}` | With the Python `class`, `message` and `traceback`. |

## The five ideas

### 1. You name things; you don't hold them

A `%ExPoser.Parameter{}` is a path of internal names from the scene down to
one dial. Every call resolves the path inside Poser, in the same request as
the work, and releases what it looked up. Nothing goes stale, so a struct
from yesterday's session works after Poser restarts, as long as the figure
is still in the scene.

```elixir
bend = ExPoser.Figure.parameter!(fig, "Left Forearm", "Bend")
# ... Poser restarts, the client reconnects ...
ExPoser.Parameter.value!(bend)
#=> 45.0
```

### 2. Every call is a batch

Each function is a one-op `ExPoser.Batch`, so single calls and batches behave
the same: same lookups, same frame handling, same errors. Batching by hand is
more of the same, in one round trip.

```elixir
ExPoser.batch!(fn b ->
  b
  |> ExPoser.Batch.set(bend, 30.0)
  |> ExPoser.Batch.set(twist, -10.0)
  |> ExPoser.Batch.get(bend)
end)
#=> [:ok, :ok, 30.0]
```

### 3. Time is an option

Poser has one global current frame, and PoserPython reads and writes dials at
it. Here a frame is an option instead: `frame: 11` (GUI frame 12) moves
Poser there, does the work and moves it back.

```elixir
ExPoser.Parameter.set_value(bend, 30.0, frame: 11)
#=> {:ok, :ok}
ExPoser.Scene.frame()
#=> {:ok, 0}
```

### 4. Failures are values, and there is no rollback

Every function returns `{:ok, value}` or `{:error, %ExPoser.Error{}}`, and a
`!` variant raises. Poser has no transactions: when the second op of a batch
fails, the first stays applied.

```elixir
ExPoser.batch(fn b ->
  b
  |> ExPoser.Batch.set(bend, 30.0)
  |> ExPoser.Batch.set(missing, 1.0)
end)
#=> {:error, %ExPoser.Error{kind: :not_found, details: %{index: 1, ...}}}
# bend is now 30.0
```

### 5. There's always a way down

`handle/2` on a figure, actor or dial gives a live `%ExPoser.Handle{}` for the
generated `ExPoser.Api` modules, which cover every PoserPython method. The
handle is yours to release.

```elixir
{:ok, h} = ExPoser.Parameter.handle(bend)
ExPoser.Api.ParmType.min_value(h)
#=> {:ok, -180.0}
ExPoser.Client.release([h])
```

See [Generated API](generated-api.md) for working with handles directly.
