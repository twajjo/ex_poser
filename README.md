# Poserx

An Elixir client for Poser 14's Python API. A small add-on inside Poser serves
the `poser` module over a socket (ErlPort's term format), and Poserx calls it.

Figures, body parts and dials are plain structs that name a path through the
scene, so they survive a Poser restart. Each call resolves its path in the
same request as the work, `frame:` reads or writes at a frame and puts
Poser's timeline back, and a batch sends many operations in one request:

```elixir
{:ok, _} = ExPoser.Client.start_link()
# The handshake runs in the background; wait for it before the first call.
:ok = ExPoser.Client.await_connected()
{:ok, fig} = ExPoser.Scene.figure("Figure 1")
{:ok, bend} = ExPoser.Figure.parameter(fig, "Left Forearm", "Bend")

{:ok, :ok} = ExPoser.Parameter.set_value(bend, 30.0, frame: 4)   # GUI frame 5

ExPoser.batch!(fn b ->
  b
  |> ExPoser.Batch.set(bend, 45.0, frame: 9)
  |> ExPoser.Batch.get(bend, frame: 9)
end)
#=> [:ok, 45.0]
```

Every PoserPython function and method also has a generated function in
`ExPoser.Api`, working on handles to live Python objects:

```elixir
{:ok, scene} = ExPoser.Api.scene()
{:ok, [figure | _]} = ExPoser.Api.SceneType.figures(scene)
{:ok, actor} = ExPoser.Api.FigureType.actor(figure, "hip")
{:ok, parm} = ExPoser.Api.ActorType.parameter(actor, "xRotate")
{:ok, nil} = ExPoser.Api.ParmType.set_value(parm, 15.0, do_update: 1)
```

Optional Python arguments are keyword options; `server:` and `timeout:` go
to the client. Constants live in `ExPoser.Const`, e.g. `ExPoser.Const.parm_code(:xrot)`.

## Guides

Build the docs with `mix docs` and open `doc/index.html`, or read the guides
here:

- [Getting started](guides/getting-started.md): connect, find a figure, bend an arm
- [Concepts](guides/concepts.md): Poser and Elixir side by side, and the five ideas
- [Posing](guides/posing.md), [Frames and keyframes](guides/frames-and-keyframes.md),
  [Batching](guides/batching.md), [Errors](guides/errors.md),
  [Generated API](guides/generated-api.md)
- [Cheatsheet](guides/idiomatic-api.cheatmd) and a [Livebook tour](guides/posing.livemd)
- [Setup](guides/setup.md): deploying the add-on, the WSL firewall rule, tests
- [Limitations](guides/limitations.md): what can't be covered, and workarounds
