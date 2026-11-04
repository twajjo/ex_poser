# Getting started

Poserx drives Poser 14 from Elixir. A small add-on inside Poser serves the
PoserPython `poser` module over a socket, and this library calls it. This
page connects to a running Poser, finds a figure and bends its left forearm.

You need Poser running with the add-on deployed and a scene with a figure
loaded; [Setup](setup.md) covers the add-on and the WSL firewall rule.

## Connect

```elixir
{:ok, _pid} = Poser.Client.start_link()
true = Enum.any?(1..50, fn _ -> Poser.Client.status() == :connected or (Process.sleep(100) && false) end)
```

The handshake runs in the background, so the second line waits for it (up to
five seconds) before the first call. The client reads the add-on's session file to find the host, port and token,
and reconnects on its own if Poser restarts. Nothing below holds anything
that a reconnect would invalidate.

## Find a figure

```elixir
Poser.Scene.figures()
#=> {:ok, [#Poser.Figure<Figure 1>, #Poser.Figure<Figure 2>]}

{:ok, fig} = Poser.Scene.figure("Figure 1")
```

The inspect output shows the figure's *internal* name. `Poser.Scene.figure/2`
also accepts the label the GUI shows in its figure menu, which can be
renamed or repeated; see [Concepts](concepts.md) for why the internal name is
the key.

## Bend an arm

```elixir
{:ok, bend} = Poser.Figure.parameter(fig, "Left Forearm", "Bend")

Poser.Parameter.value(bend)
#=> {:ok, 0.0}

Poser.Parameter.set_value(bend, 45)
#=> {:ok, :ok}
```

`bend` is a `%Poser.Parameter{}`: the dial Poser shows as "Bend" on the left
forearm, named by its path from the scene. It holds no Poser object, so you
can keep it in a module attribute, a GenServer's state or an ETS table and
use it after Poser restarts.

Poser keys a value at the frame it is set at. To set a different frame
without moving Poser's timeline, pass `frame:`. Frames count from 0, so
`frame: 29` is GUI frame 30:

```elixir
Poser.Parameter.set_value(bend, 90, frame: 29)
#=> {:ok, :ok}

Poser.Scene.frame()
#=> {:ok, 0}
```

## Several dials at once

```elixir
{:ok, forearm} = Poser.Figure.actor(fig, "Left Forearm")

Poser.Actor.values(forearm)
#=> {:ok, %{"yrot" => 45.0, "zrot" => 0.0, "xrot" => 0.0, ...}}

Poser.Actor.set(forearm, %{"yrot" => 30.0, "xrot" => -10.0})
#=> {:ok, :ok}
```

The keys are internal names, not the labels the GUI shows: on a forearm,
`"yrot"` is the dial labelled Bend, `"zrot"` is Side-Side and `"xrot"` is
Twist. `Poser.Actor.set/3` with a map sends one request however many dials it
writes. For different actors, frames, reads and writes in one request, see
[Batching](batching.md).

## Where next

- [Concepts](concepts.md): the five ideas the rest of the library follows.
- [Posing](posing.md): figures, actors and dials in depth.
- [Frames and keyframes](frames-and-keyframes.md): `frame:`, auto-keying, keyframes.
- [Cheatsheet](idiomatic-api.cheatmd): each task in the idiomatic API and in `Poser.Api`.
- [Posing Livebook](posing.livemd): this page as a runnable notebook.
