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

## Probe answers

1. Not settled. For the 5 materials listed (Base, Preview, LongHair,
   LongHair_Front, Hair_Falling), `Name()` equals `ExtName()`, and looking up by it
   works. A material whose two names differ is needed to tell which one
   `Material(name)` matches.
2. Not settled. The first material has one layer, `Base`, whose `Name()` equals
   its `ExtName()`, and `LayerByName` finds it. A layer whose names differ is
   needed.
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
