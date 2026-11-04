# Frames and keyframes

## Two frame numbers

PoserPython counts frames from 0; the GUI counts from 1. This library uses
PoserPython's numbers, so `frame: 0` is GUI frame 1 and `frame: 29` is GUI
frame 30. `Poser.Scene.num_frames/1` returns a count, so the last frame of a
30-frame timeline is `frame: 29`.

## The `frame:` option

Poser has one current frame per scene, and PoserPython reads and writes dials
at it. Here a frame is an option on anything time-based:
`Poser.Parameter.value/2`, `Poser.Parameter.set_value/3`,
`Poser.Batch.get/3`, `Poser.Batch.set/4` and `Poser.Batch.call/5`.

```elixir
Poser.Scene.frame()
#=> {:ok, 0}

Poser.Parameter.set_value(bend, 30.0, frame: 11)   # GUI frame 12
#=> {:ok, :ok}

Poser.Parameter.value(bend, frame: 11)
#=> {:ok, 30.0}

Poser.Scene.frame()
#=> {:ok, 0}
```

Each call moves Poser to the frame, does the work, and moves it back to the
frame it found, in the same request. An op without `frame:` runs at that
original frame. In a batch, the move is only sent when an op's frame differs
from the previous op's, and ops are never reordered, so group ops by frame
to keep the moves down.

`Poser.Scene.set_frame/2` is the exception: it moves the timeline on purpose
and leaves it there, as the GUI's frame slider does.

```elixir
Poser.Scene.set_frame(11)   # GUI frame 12
#=> {:ok, nil}
Poser.Parameter.value(bend)
#=> {:ok, 30.0}
```

If a batch with `frame:` fails, the frame is still restored; the one case
where it isn't is in [Batching](batching.md#failures).

## Auto-keying

Poser keys a value at the frame it is set at. Two facts follow:

- **Every dial has a key at frame 0** (GUI frame 1) from the start.
- **Setting a value adds or moves a key** at the frame it is set at, with or
  without `frame:`.

So setting a dial at `frame: 4` (GUI frame 5) on a dial with only its frame-0
key gives it two keys. Frames between 0 and 4 interpolate, and frames after 4
hold the new value:

```elixir
Poser.Parameter.set_value(bend, 30.0, frame: 4)
Poser.Parameter.keyframes(bend)
#=> {:ok, [0, 4]}
Poser.Parameter.value(bend, frame: 11)
#=> {:ok, 30.0}
```

Setting a value at frame 0 with no other keys changes the whole animation,
since the frame-0 key is then the only one.

## Keyframes

`Poser.Parameter.add_keyframe/3` keys the value the dial already has at a
frame; `Poser.Parameter.delete_keyframe/3` removes a key. Neither moves the
current frame. In a batch, use `Poser.Batch.add_keyframe/3` and
`Poser.Batch.delete_keyframe/3`.

```elixir
Poser.Parameter.add_keyframe(bend, 7)      # GUI frame 8
#=> {:ok, :ok}
Poser.Parameter.keyframes(bend)
#=> {:ok, [0, 4, 7]}
Poser.Parameter.delete_keyframe(bend, 7)
#=> {:ok, :ok}
```

`Poser.Parameter.keyframes/2` walks PoserPython's `NextKeyFrame` one key at a
time: one request per key, plus one. It is not a snapshot, so keys another
client adds or removes during the walk may or may not appear.

## Writing an animation

A pose per frame is a batch with `frame:` on each set. Order the ops by frame
so each frame is visited once:

```elixir
poses = %{0 => 0.0, 10 => 45.0, 20 => 90.0, 29 => 0.0}  # GUI frames 1, 11, 21, 30

Poser.batch!(fn b ->
  poses
  |> Enum.sort()
  |> Enum.reduce(b, fn {frame, v}, b -> Poser.Batch.set(b, bend, v, frame: frame) end)
end)
#=> [:ok, :ok, :ok, :ok]
```

The keys land at 0, 10, 20 and 29, and the timeline ends where it started.
