# Errors

Every function returns `{:ok, value}` or `{:error, %Poser.Error{}}`. The
`!` variants raise the same struct. `kind` says what went wrong and
`details` carries the specifics; `class`, `message` and `traceback` are set
for Python errors.

## Kinds you'll handle

### `:not_found`

A struct's path didn't resolve: the figure, actor or dial isn't in the scene
(any more). `details.path` is the part of the path that failed, as
`Poser.Ref.path/1` steps, so it tells you *which* step is missing:

```elixir
nope = %Poser.Actor{figure: fig, internal: "nope", name: "nope"}
Poser.Actor.get(nope, "yrot")
#=> {:error, %Poser.Error{kind: :not_found,
#=>   details: %{path: [figure: "Figure 1", actor: "nope"], index: 0, cause: %Poser.Error{kind: :python, ...}}}}
```

`details.cause` is what Poser said, when it said anything: PoserPython's
`FigureByInternalName` and `ActorByInternalName` raise a Python error for a
missing name, and `InternalParameter` returns `None`, which leaves `cause`
nil. A display-name lookup that matched nothing ends its path with a
`{:name, text}` step.

### `:ambiguous`

A lookup by display name matched more than one object, which happens
whenever two figures share a GUI label. `details.matches` holds every
candidate as a struct; pick one, or look it up by internal name instead.

```elixir
case Poser.Scene.figure("Andy") do
  {:ok, fig} -> fig
  {:error, %Poser.Error{kind: :ambiguous, details: %{matches: [fig | _]}}} -> fig
end
```

The message names them: `ambiguous: "Andy" matches Figure 1, Figure 3`.

### `:python`

Poser raised. `class` is the Python exception class (`"error"` for
PoserPython's own `poser.error`), `message` its text and `traceback` the
formatted lines.

## Errors in a batch

An error from an op on structs, meaning a batch or a `Poser.Parameter` or
`Poser.Actor` value call, gains `details.index`: the index of *your* op that
failed, counting from 0. The batch's own lookups and frame moves are never
counted. Lookup-by-name errors (`Scene.figure`, `Figure.actor`, `Scene.actor`,
...) have `index` nil or absent. Other `details` keys
are kept; for `:not_allowed`, `details.op` is the wire op kind Poser's strict
mode refused, such as `:invoke`.

There is no rollback; see [Batching](batching.md#failures).

## Connection and protocol errors

| Kind | Meaning | `details` |
|---|---|---|
| `:timeout` | No reply within `:timeout` ms. The request may still have run in Poser. | |
| `:disconnected` | No connection, or it dropped mid-request. The client reconnects on its own. | `reason` |
| `:stale_handle` | A `%Poser.Handle{}` from an earlier connection or an earlier add-on handle table. Idiomatic structs never cause this. | `id`, `generation` |
| `:not_allowed` | Strict mode refused a method, or a raw call. `message` is the method name. | `op` |
| `:bad_request` | The add-on couldn't decode the request, or an option was invalid. | |
| `:batch_failed` | A `Poser.Client.batch/2` request failed part-way. `Poser.Batch` unwraps it into its cause; a listing's second request can return it as is. | `index` (wire op), `cause`, `partial` |
| `:protocol_mismatch` | The add-on speaks a different protocol version. Redeploy it. | `ours`, `theirs` |
| `:handshake_failed` | The add-on didn't answer the hello. | |

`:timeout` and `:disconnected` on the first chunk of a batch with `frame:`
ops can leave Poser's frame moved; see [Batching](batching.md#failures).
