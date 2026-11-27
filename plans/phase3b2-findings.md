# Phase 3b-2 findings

## Live run

### 11a (materials read, flat settings)

2026-11-24: `mix test --only poser test/live/live_poser_test.exs` passed 19 of 19
(16 earlier tests plus 3 new ones: listing and lookup, flat colour set and restore,
snapshot). No handles were left open.

First figure's first material tree: 5 nodes (`poser` plus four `image_map`), and
every renderer root (preview, firefly, poser4, sketch, superfly) is `PoserSurface`.

### 11b (node edits)

2026-11-24, first run: the one-batch test (create an `image_map`, set its
`Image_Source`, link its `Color` to `PoserSurface` `Ambient_Color`, delete it)
crashed Poser; the client saw `:disconnected` (heartbeat timeout).

Bisected with a throwaway script (not kept), one op per request and then in
one batch:

- Separate requests, any mix of the four ops: no crash.
- One batch, create + delete, or create + link + delete: no crash.
- One batch, create + set `Image_Source` + delete: crash (and the full batch).
- In Poser's own Python shell, the same calls without the bridge: no crash.
  Keeping the input, deleting the node, then calling `input.Name()`: crash.

Cause: a bridge bug. `Dispatcher._batch` wrapped every result after all ops
ran, and wrapping labels an object with `Name()`, so it touched the input of
a node the batch had already deleted. Calling a method on an input of a
deleted node crashes Poser outright, with no Python exception. Fixed in #83:
each result is wrapped as its op runs. After the fix both crashing batches run
cleanly. Not run through the bridge, but it follows from the shell check: a
later request that uses a handle to a deleted node's input would still crash
Poser, since the bridge doesn't track deletions.

2026-11-24, after the fix (bridge build c633de4e): 21 of 21 passed, with the
original one-batch test, on a scene with Irika. No handles were left open.

### 11c (layers and roots)

2026-11-24, first run: 21 of 23 passed. Both failures were checked in Poser's
own Python shell, one line at a time, and both are Poser behaviour, not the
bridge.

- Atmosphere root: `SetRendererRootNode(node, 0)`, the order Poser's docstring
  gives, fails with `Error parsing SetRendererRootNode() Usage:
  SetRendererRootNode(<StringType> renderer, <ShaderNodeType> node)`, in the
  shell too. `SetRendererRootNode(0, node)` is accepted: the code comes first.
  Fixed in #86 (`Batch.set_root` sends `[code, node]`). The generated
  `set_renderer_root_node` still follows the docstring; a generator override
  comes after 3b-2. The run reported the failure from the test's restore step,
  which hid the body's own failure; the restore no longer raises.
  The atmosphere tree has one node, `Atmosphere` (type `atmosphere`), and it is
  every renderer's root. `CreateNode` of type `atmosphere` gave `Atmosphere_2`.
- Layer: `CreateLayer(name)` on the first figure material (`4_InnerMouth`)
  fails with `Cannot add Material Layer to Light`, also from an actor's
  material. The scene's current actor was a light (`Reye Light 2`). After
  `SelectActor(Body)` the same call works: CreateLayer needs the material's
  actor to be the current actor.
  The new layer's `Name()` is `Layer_1`, not the name asked for; the requested
  name is its `ExtName()`. So `create_layer` returns `:ok` (#87), as
  `CreateLayer` does, and the test finds the new layer by listing.

2026-11-25, rerun with the order fixed: 22 of 23 passed; the layer test passed
(the new layer's `Name()` was `Layer_1`). The atmosphere test failed:
`set_root!` on `:preview` returned `:ok`, but the preview root was still
`Atmosphere`. Shell probes, one line each:

1. Atmosphere tree, `SetRendererRootNode(0, Atmosphere_2)`: no error, root
   still `Atmosphere`.
2. Irika's first material tree, `SetRendererRootNode(0, PoserSurface_2)`: no
   error, root still `PoserSurface`. So it is not specific to the atmosphere.
3. `UpdatePreview()` and reading again: still `PoserSurface`.
4. A string renderer (`'preview'`, `'Preview'`, `'PREVIEW'`): a parse error
   each time, although the usage message says `<StringType> renderer`. The
   renderer is an integer.
5. Codes 0 to 4 in turn, reading each after its set: code 0 (preview) keeps
   `PoserSurface`; codes 1 to 4 all read `PoserSurface_2`. This was misleading,
   as probes 6 to 8 show: the set for code 1 had already changed codes 2 and 3.
6. Code 1 (firefly) set back to `PoserSurface`: codes 0 to 3 all read
   `PoserSurface`; code 4 (superfly) still reads `PoserSurface_2`.
7. Code 2 (poser4) set to `PoserSurface_2`: nothing changes.
8. Code 3 (sketch) set to `PoserSurface_2`: nothing changes. Code 4 set to
   `PoserSurface`: code 4 reads `PoserSurface`.

So, on a material tree at least, only the firefly and superfly roots can be
set. Poser accepts the call for preview, poser4 and sketch and ignores it, and
those three report firefly's root. The test now sets firefly's root, or
superfly's if firefly has none.

2026-11-25, rerun with the test setting firefly: 23 of 23 passed. On the
atmosphere tree, firefly's root was set to a new `Atmosphere_3` and restored.
The scene still held the probes' leftovers (`Atmosphere_2`, `PoserSurface_2`).

## Probe answers

1. Not settled. For the 5 materials listed (Base, Preview, LongHair,
   LongHair_Front, Hair_Falling), `Name()` equals `ExtName()`, and looking up by it
   works. A material whose two names differ is needed to tell which one
   `Material(name)` matches.
2. Settled: `LayerByName` matches `Name()` only. The first material has one
   layer, `Base`, whose `Name()` equals its `ExtName()`. A layer made by
   `CreateLayer('ExPoser probe')` has `Name()` `Layer_1` and `ExtName()`
   `ExPoser probe`: `LayerByName('Layer_1')` finds it, and
   `LayerByName('ExPoser probe')` fails with `Layer with such name does not
   exist in this Material`.
3. Partly settled. A new `image_map` gets an internal name `Image_Map_<n>`,
   and its `Name()` equals that internal name. Names are reused after `Delete`:
   two create-then-delete runs got the same name. The rule for `<n>` is not
   settled. In a tree with `Image_Map`, `Image_Map_3`, `_4` and `_5` the new
   node was `Image_Map_6`, so it isn't the lowest free number. In a tree with
   `Image_Map`, `Image_Map_4` and `skin2` it was `Image_Map_3`, so it isn't
   the highest number plus one either.
4. Not settled. Linking with a node (not an output) links from its `Color`
   output, but `image_map` has only that one output. A node with several
   outputs is needed to tell its selected output from its first.
5. 

## Timings

- `ShaderTree.snapshot` (5 nodes): 45 ms.
