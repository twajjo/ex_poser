# Posing

A pose is a set of dial values on a figure's body parts. This guide covers
finding those dials and reading and writing them. Timing is in
[Frames and keyframes](frames-and-keyframes.md).

## The tree

```text
ExPoser.Scene
├── %ExPoser.Figure{}                 Scene.figures/1, Scene.figure/2
│   └── %ExPoser.Actor{figure: fig}   Figure.actors/2, Figure.actor/3   (body parts)
│       └── %ExPoser.Parameter{}      Actor.parameters/2, Actor.parameter/3
└── %ExPoser.Actor{figure: nil}       Scene.actors/1, Scene.actor/2     (props, cameras, lights)
    └── %ExPoser.Parameter{}
```

Body parts belong to their figure and are only found through it.
`ExPoser.Scene.actors/1` and `ExPoser.Scene.actor/2` return scene-level actors
only, never body parts, even though PoserPython's `Scene.Actors()` lists both.

## Names

Every struct has two names:

- `internal`: Poser's internal name. It is the key in the struct's path, and
  it is what `inspect/1` prints. PoserPython's `FigureByInternalName`,
  `ActorByInternalName` and `InternalParameter` find objects by it.
- `name`: the label the GUI shows. It can be renamed, and two figures can
  both be labelled "Figure 1".

Lookups (`ExPoser.Scene.figure/2`, `ExPoser.Scene.actor/2`,
`ExPoser.Figure.actor/3`, `ExPoser.Actor.parameter/3`) take either:

1. The text is tried as an internal name first. A hit wins, even if another
   object has that text as its display name. This costs one round trip.
2. Otherwise the siblings are listed and matched by display name (two more
   round trips). One match resolves; several give `:ambiguous` with the
   candidates in `details.matches`; none gives `:not_found`.

```elixir
ExPoser.Scene.figure("Figure 2")
#=> {:ok, #ExPoser.Figure<Figure 2>}

ExPoser.Scene.figure("Andy")
#=> {:error, %ExPoser.Error{kind: :ambiguous, details: %{matches: [...]}}}
```

Display names aren't unique within an actor either. On a forearm, the
internal dials `"xrot"` and `"twistx"` are both labelled "Twist", so
`ExPoser.Actor.parameter(arm, "Twist")` gives `:ambiguous`; ask for `"xrot"`
(or `"twistx"`) by internal name instead. The forearm's Bend is `"yrot"` and
its Side-Side is `"zrot"`.

In code that runs often, look a struct up once and keep it, or build it by
internal name (below), so the display-name fallback never runs.

## Building structs by hand

The structs are plain data. If you already know the internal names, build
the path yourself; nothing is checked until it is used, and a missing step
then gives `:not_found` with `details.path`.

```elixir
fig = %ExPoser.Figure{internal: "Figure 1", name: "Figure 1"}
body = %ExPoser.Actor{figure: fig, internal: "BODY:1", name: "Body"}
yrot = %ExPoser.Parameter{actor: body, internal: "yrot", name: "yRotate"}
```

Only `internal` takes part in lookups; `name` is for display.

## Listings

`ExPoser.Scene.figures/1`, `ExPoser.Scene.actors/1`, `ExPoser.Figure.actors/2` and
`ExPoser.Actor.parameters/2` return structs in Poser's order.

> #### Listings take two requests {: .info}
>
> One request resolves the parent and fetches its children as handles; a
> second reads each child's internal and display names. Every handle is then
> released. A listing costs two round trips however many children there are,
> and a figure with 80 body parts is still two requests.

`ExPoser.Actor.values/2` is a listing too: every dial's value in two requests,
as `%{internal_name => value}`.

## Values

A value is a float, or one of `:nan`, `:infinity` and `:neg_infinity`, which
is how the wire carries those IEEE values. Integers you pass are sent as
floats.

```elixir
ExPoser.Parameter.value(yrot)
#=> {:ok, 0.0}
ExPoser.Parameter.set_value(yrot, 15)
#=> {:ok, :ok}
ExPoser.Parameter.min_max(yrot)
#=> {:ok, {-180.0, 180.0}}
```

`ExPoser.Actor.get/3` and `ExPoser.Actor.set/3` address dials by internal name on
an actor, without a `%ExPoser.Parameter{}`. They never fall back to display
names, so each is exactly one request:

```elixir
ExPoser.Actor.get(body, "yrot")
#=> {:ok, 15.0}

ExPoser.Actor.set(body, "yrot", 20.0)
#=> {:ok, :ok}

ExPoser.Actor.set(body, %{"xrot" => 5.0, "yrot" => 20.0, "zrot" => 0.0})
#=> {:ok, :ok}
```

The map form sends one batch for all its dials. Dials on several actors, or
at several frames, go in a `ExPoser.Batch`; see [Batching](batching.md).

Every set is keyed by Poser at the frame it happens at. Read
[Frames and keyframes](frames-and-keyframes.md) before writing poses into an
animation.
