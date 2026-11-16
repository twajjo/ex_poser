# Lights and cameras

## Rigs

A scene's lights and cameras are scene-level actors. `ExPoser.Light` and
`ExPoser.Camera` each wrap one `ExPoser.Actor`, so the internal name is the
key and the display name is the label, as for any actor. The set of lights
or cameras in a scene is a *rig*.

```elixir
ExPoser.Scene.lights!()
#=> [#ExPoser.Light<Key>, #ExPoser.Light<Fill>, #ExPoser.Light<Back>]

key = ExPoser.Scene.light!("Key")
main = ExPoser.Scene.current_camera!()
```

`ExPoser.Scene.light/2` and `ExPoser.Scene.camera/2` find one by display
name. A name shared by several returns `:ambiguous`, as in
[Errors](errors.md).

## Properties and dials

A light has two kinds of value:

- **Properties**, which PoserPython reads and writes with a method pair,
  such as `LightType`/`SetLightType` or `ShadowSamples`/`SetShadowSamples`.
  They are named by atoms (`:type`, `:on`, `:shadow_samples`, …), don't vary
  over time, and ignore `frame:`.
- **Dials**, the light's parameters, named by their internal-name strings
  (`"xtran"`, `"KdIntensity"`, …). They are keyed like any other dial, so
  `frame:` applies, as in [Frames and keyframes](frames-and-keyframes.md).

`:color` is the one value that is neither: it reads and writes the red,
green and blue dials together as `{r, g, b}`. The three dials are found by
their parm codes, not their names.

```elixir
ExPoser.Light.get(key, [:type, :color, "xtran"])
#=> {:ok, %{type: :spot, color: {1.0, 1.0, 1.0}, "xtran" => 0.0}}

ExPoser.Light.set(key, %{type: :point, color: {1.0, 0.8, 0.6}, "xtran" => 2.0})
#=> {:ok, :ok}
```

A camera has only dials.

## Snapshots

A snapshot is a light's or a camera's values at one frame, as plain data:
a `%ExPoser.Light.Snapshot{}` holds the name, type, properties and dials, and
a `%ExPoser.Camera.Snapshot{}` the name and dials. It holds no handles and no
internal name, so it can be stored, compared, edited and applied to another
scene.

```elixir
rig = ExPoser.Light.snapshot_all!(frame: 0)
#=> [%ExPoser.Light.Snapshot{name: "Key", type: :spot, ...}, ...]
```

Reading at `frame:` restores the scene's current frame afterwards.

## Applying snapshots

Applying a snapshot writes its values back. A light snapshot is applied in
one of two modes, chosen by the caller:

- **Merge** (the default) matches each snapshot to a light by display name.
  A matched light is updated. A snapshot that matches no light gets a new
  light with that name. A name that matches several lights returns
  `:ambiguous` before anything changes.
- **Replace** deletes every light in the scene and creates the snapshots'
  lights.

```elixir
ExPoser.Light.apply(rig)                  # merge
ExPoser.Light.apply(rig, mode: :replace)
#=> {:ok, %{skipped: []}}
```

> #### Replace deletes lights {: .warning}
>
> Replace removes every light in the scene, including lights that aren't in
> the snapshots. Only lights are replaced: cameras, figures and props are
> left alone.

Cameras are only matched by name and have their dials set. None is created
or deleted, and a name that matches no camera returns `:not_found` before
anything changes.

For each light the type is written first, then the properties, then the
dials, because a type change can reset dials. Dials are written at
`frame:`, and the current frame is left unchanged.

## Skipped dials

A snapshot can name a dial the target lacks, for example a snapshot from a
different kind of light or another version of Poser. That dial is not
written. It is listed in the result as `{name, dial}` instead, and is not an
error:

```elixir
snap = ExPoser.Light.snapshot!(key)
ExPoser.Light.apply(%{snap | dials: %{"xtran" => 1.0, "nodial" => 2.0}})
#=> {:ok, %{skipped: [{"Key", "nodial"}]}}
```

## No rollback

Poser has no transactions, so applying is not atomic. Bad input (an unknown
property, a dial name that isn't a string, a bad `frame:`) raises before any
request. Lookup errors (`:not_found`, `:ambiguous`) are found before
anything is written. But once writing starts, a failure leaves the scene
part-way.

> #### A failed apply can leave the scene changed {: .warning}
>
> In merge mode, lights created before a failed create stay in the scene. In
> replace mode, a failed delete-and-create can leave some lights deleted or
> created. If the final write fails, some values may already be written.
> Take a snapshot first if you need to put the scene back.

## Round trips

Snapshotting and applying take a fixed number of requests, however many
lights or cameras there are, while the work fits in one batch chunk (see
[Batching](batching.md)): the list, the dial names, then one batch that
reads or writes everything, each followed by a request that releases its
handles.

> #### A fixed cost {: .info}
>
> `snapshot_all` takes ten requests, and so does a merge apply that creates
> no lights; one that creates lights takes twelve, as does replace. The
> exact count is in each function's docs. Poser's own work still grows with
> the rig: replacing 13 lights has been seen to take several seconds.
