# Batching

Every function in the idiomatic API is a one-op `ExPoser.Batch`. Building one
by hand puts many reads and writes, on any dials and at any frames, into as
few requests as possible.

```elixir
ExPoser.batch(fn b ->
  b
  |> ExPoser.Batch.set(bend, 30.0, frame: 4)     # GUI frame 5
  |> ExPoser.Batch.set(twist, -10.0, frame: 4)
  |> ExPoser.Batch.get(bend, frame: 4)
end)
#=> {:ok, [:ok, :ok, 30.0]}
```

`ExPoser.batch/2` builds and runs in one go; `ExPoser.Batch.new/0` and
`ExPoser.Batch.run/2` do the same in two steps, for a batch built up over
time. Both have `!` variants.

## Results

One result per op you added, in order. Setters and keyframe ops give `:ok`;
`get` gives the value; `ExPoser.Batch.call/5` gives whatever the PoserPython
method returns. The lookups and frame moves the batch adds are not in the
list.

## What goes over the wire

Each struct compiles to the PoserPython lookups that reach it, sent in the
same request as the op. For `bend` on figure "Figure 1":

```text
Scene()
  .FigureByInternalName("Figure 1")
  .ActorByInternalName("lForeArm:1")
  .InternalParameter("yrot")
  .SetValue(30.0)
```

Within a request, each path prefix resolves once. 500 sets on one dial share
one lookup chain, and every dial of one figure shares one scene lookup and
one figure lookup. No handle is kept afterwards: everything the lookups
create is released when the request returns.

## Frames

A batch with any `frame:` op reads Poser's current frame first, and every op
without `frame:` runs at that original frame, not at whatever frame the
previous op left. A frame move is sent only when an op's frame differs from
the previous op's, and the original frame is restored as the batch's last
op. Ops are never reordered, so sort them by frame when you can. See
[Frames and keyframes](frames-and-keyframes.md).

## Chunks

One request is one turn on Poser's Python main thread, and Poser's UI is busy
while it runs. A batch is split into chunks of at most 2000 wire ops,
lookups and frame moves included; each chunk is one request and does its own
lookups. Pass `chunk:` to `ExPoser.Batch.run/2` or `ExPoser.batch/2` to change
the limit:

```elixir
ExPoser.batch(build, chunk: 500)
```

A chunk too small to hold a single op and its lookups raises
`ArgumentError`.

## Failures

> #### No rollback {: .warning}
>
> Poser has no transactions. Ops before a failure stay applied, in the
> failing chunk and in every chunk before it. Later chunks don't run.

On failure, the batch returns `{:error, %ExPoser.Error{}}` with
`details.index`, the index of your op that failed, counting from 0. The frame
is moved back to where the batch found it, and every handle the batch
created is released.

```elixir
ExPoser.batch(fn b ->
  b
  |> ExPoser.Batch.set(bend, 30.0)
  |> ExPoser.Batch.get(missing)
end)
#=> {:error, %ExPoser.Error{kind: :not_found, details: %{index: 1, path: [...], ...}}}
```

One case leaves the frame moved: a `:timeout` or `:disconnected` error on the
first chunk of a batch with `frame:` ops. The original frame is read in that
chunk, and its reply never arrived, so there is nothing to restore. If the
chunk ran in Poser anyway, the timeline is left at the last frame it moved
to. Check `ExPoser.Scene.frame/1` after such an error if it matters.

Error kinds and their `details` are listed in [Errors](errors.md).

## Calls the API doesn't wrap

`ExPoser.Batch.call/5` runs any PoserPython method on `:scene` or on a struct,
with the same shared lookups and `frame:` handling:

```elixir
ExPoser.batch!(fn b ->
  b
  |> ExPoser.Batch.call(:scene, "NumFrames")
  |> ExPoser.Batch.call(bend, "NextKeyFrame", [], frame: 4)
end)
#=> [30, 10]
```

A handle a `call` returns is yours to release with `ExPoser.Client.release/2`.
