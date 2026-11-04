# Posing

A pose is a set of dial values on a figure's body parts. This guide covers
finding those dials and reading and writing them. Timing is in
[Frames and keyframes](frames-and-keyframes.md).

## The tree

```text
Poser.Scene
├── %Poser.Figure{}                 Scene.figures/1, Scene.figure/2
│   └── %Poser.Actor{figure: fig}   Figure.actors/2, Figure.actor/3   (body parts)
│       └── %Poser.Parameter{}      Actor.parameters/2, Actor.parameter/3
└── %Poser.Actor{figure: nil}       Scene.actors/1, Scene.actor/2     (props, cameras, lights)
    └── %Poser.Parameter{}
```

Body parts belong to their figure and are only found through it.
`Poser.Scene.actors/1` and `Poser.Scene.actor/2` return scene-level actors
only, never body parts, even though PoserPython's `Scene.Actors()` lists both.

## Names

Every struct has two names:

- `internal`: Poser's internal name. It is the key in the struct's path, and
  it is what `inspect/1` prints. PoserPython's `FigureByInternalName`,
  `ActorByInternalName` and `InternalParameter` find objects by it.
- `name`: the label the GUI shows. It can be renamed, and two figures can
  both be labelled "Figure 1".

Lookups (`Poser.Scene.figure/2`, `Poser.Scene.actor/2`,
`Poser.Figure.actor/3`, `Poser.Actor.parameter/3`) take either:

1. The text is tried as an internal name first. A hit wins, even if another
   object has that text as its display name. This costs one round trip.
2. Otherwise the siblings are listed and matched by display name (two more
   round trips). One match resolves; several give `:ambiguous` with the
   candidates in `details.matches`; none gives `:not_found`.

```elixir
Poser.Scene.figure("Figure 2")
#=> {:ok, #Poser.Figure<Figure 2>}

Poser.Scene.figure("Andy")
#=> {:error, %Poser.Error{kind: :ambiguous, details: %{matches: [...]}}}
```

In code that runs often, look a struct up once and keep it, or build it by
internal name (below), so the display-name fallback never runs.

## Building structs by hand

The structs are plain data. If you already know the internal names, build
the path yourself; nothing is checked until it is used, and a missing step
then gives `:not_found` with `details.path`.

```elixir
fig = %Poser.Figure{internal: "Figure 1", name: "Figure 1"}
body = %Poser.Actor{figure: fig, internal: "BODY:1", name: "Body"}
yrot = %Poser.Parameter{actor: body, internal: "yrot", name: "yRotate"}
```

Only `internal` takes part in lookups; `name` is for display.

## Listings

`Poser.Scene.figures/1`, `Poser.Scene.actors/1`, `Poser.Figure.actors/2` and
`Poser.Actor.parameters/2` return structs in Poser's order.

> #### Listings take two requests {: .info}
>
> One request resolves the parent and fetches its children as handles; a
> second reads each child's internal and display names. Every handle is then
> released. A listing costs two round trips however many children there are,
> and a figure with 80 body parts is still two requests.

`Poser.Actor.values/2` is a listing too: every dial's value in two requests,
as `%{internal_name => value}`.

## Values

A value is a float, or one of `:nan`, `:infinity` and `:neg_infinity`, which
is how the wire carries those IEEE values. Integers you pass are sent as
floats.

```elixir
Poser.Parameter.value(yrot)
#=> {:ok, 0.0}
Poser.Parameter.set_value(yrot, 15)
#=> {:ok, :ok}
Poser.Parameter.min_max(yrot)
#=> {:ok, {-180.0, 180.0}}
```

`Poser.Actor.get/3` and `Poser.Actor.set/3` address dials by internal name on
an actor, without a `%Poser.Parameter{}`. They never fall back to display
names, so each is exactly one request:

```elixir
Poser.Actor.get(body, "yrot")
#=> {:ok, 15.0}

Poser.Actor.set(body, "yrot", 20.0)
#=> {:ok, :ok}

Poser.Actor.set(body, %{"xrot" => 5.0, "yrot" => 20.0, "zrot" => 0.0})
#=> {:ok, :ok}
```

The map form sends one batch for all its dials. Dials on several actors, or
at several frames, go in a `Poser.Batch`; see [Batching](batching.md).

Every set is keyed by Poser at the frame it happens at. Read
[Frames and keyframes](frames-and-keyframes.md) before writing poses into an
animation.
