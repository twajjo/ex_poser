# Phase 3b-2 findings

## Live run

### 11a (materials read, flat settings)

2026-11-24: `mix test --only poser test/live/live_poser_test.exs` passed 19 of 19
(16 earlier tests plus 3 new ones: listing and lookup, flat colour set and restore,
snapshot). No handles were left open.

First figure's first material tree: 5 nodes (`poser` plus four `image_map`), and
every renderer root (preview, firefly, poser4, sketch, superfly) is `PoserSurface`.

### 11b (node edits)

### 11c (layers and roots)

## Probe answers

1. Not settled. For the 5 materials listed (Base, Preview, LongHair,
   LongHair_Front, Hair_Falling), `Name()` equals `ExtName()`, and looking up by it
   works. A material whose two names differ is needed to tell which one
   `Material(name)` matches.
2. Not settled. The first material has one layer, `Base`, whose `Name()` equals
   its `ExtName()`, and `LayerByName` finds it. A layer whose names differ is
   needed.
3. 
4. 
5. 

## Timings

- `ShaderTree.snapshot` (5 nodes): 45 ms.
