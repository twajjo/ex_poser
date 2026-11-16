# Phase 3b-2: materials (design)

Status: approved by the user on 2026-11-16.
Builds on Phase 3a (`plans/phase3a-idiomatic-core-design.md`) and follows the patterns of 3b-1 (`plans/phase3b1-lights-cameras-design.md`).

## Intent

| | |
|---|---|
| Why | To finish the idiomatic API for materials, the way the user actually works with them in Poser. |
| What the user changes | Settings on individual nodes of material trees: bitmaps and colours mostly, and sometimes numbers such as U/V offsets. Links between nodes, and links to the material's root. They also create new nodes and link them, and delete nodes, most often ones that no path connects to the root. Often they need no nodes at all and set the flat material settings directly. |
| Downstream | Scene presets and the Postgres catalogue, in a later phase. 3b-2 gives them the data (the whole-tree read). Storing and re-applying trees is designed there. |
| Success | Every operation above can be done through ExPoser's structs, without touching handles. Any number of changes, including creating a node and then linking it and setting its bitmap, goes in one batch and one round trip. Reading a whole tree takes a fixed number of round trips, however many nodes it has. |

## The rule for this phase

ExPoser does only what PoserPython documents (`priv/poser_api.json`). The API is treated as "dumb": it does no thinking for the application layer. Where the docs are silent about what Poser does, ExPoser doesn't guess. It passes values through and returns what Poser reports. Questions only a live Poser can answer go on the black-box probe list (see the end), not into the design.

## Goals

1. **Flat material settings.** Read and set every documented getter/setter pair on `MaterialType`:
   - colours as `{r, g, b}`: ambient, diffuse, reflection, specular, texture;
   - map file names: ambient, bump, reflection, specular, texture, transparency;
   - numbers: bump strength, reflection strength, transparency min, max and falloff (`TransparencyExpo`), and `Ns`;
   - selection (`Selected`/`SetSelected`).
2. **Shader trees.** A material's main tree, each of its layer trees, and the scene's atmosphere and background trees.
3. **Layers.** List a material's layers, reach a layer's tree, and create and delete layers (`CreateLayer`, `DeleteLayer`).
4. **Nodes.**
   - Read a node's type, name, location, whether it's a root, its inputs and its outputs.
   - Create a node by type (`CreateNode(type)`).
   - Delete a node.
   - Set a node's name and location.
5. **Inputs.**
   - Read an input's value (float, `{r, g, b}` or string), type, name, and what's plugged into it (`InNode`, `InOutput`).
   - Set its value with the matching documented setter: `SetString` for a bitmap path, `SetColor` for a colour or vector, `SetFloat` for a float, integer, boolean or menu.
6. **Links.**
   - Connect a node's output (by internal name, or the node's default via `ShaderNodeType.ConnectToInput`) to an input.
   - Disconnect an input.
   - Read and set the root node for a renderer (`RendererRootNode`, `SetRendererRootNode`, with the `kRenderEngineCode*` constants).
7. **Whole-tree read.** One call returns a tree as plain data, in a fixed number of round trips:
   - every node, with its internal name, name, type, location and root flag;
   - each node's inputs, with internal name, name, type, value and what's plugged in (node and output internal names, or none);
   - each node's outputs;
   - the root node for each renderer.
8. **UpdatePreview.** The docs say to call `tree.UpdatePreview()` after modifying a tree. Any call or batch that changes a tree sends it once per changed tree, at the end of the same request.
9. **Batching.** Every operation above has a `Batch` form. A node created earlier in a batch can be used by later ops in the same batch.

## Non-goals (later, or never in this phase)

- **Animated inputs** (`Animated`, `SetAnimated`, `CanBeAnimated`, `Parameters`). They're wanted, but in a later phase. Recorded so it isn't lost.
- **Pruning.** No function finds or deletes unlinked nodes. Which nodes are unused is a decision about the graph and belongs to the application layer: read the tree, decide, then delete the nodes in one batch.
- **Applying a stored tree** (turning tree data back into nodes and links). That's preset work for the catalogue phase.
- **Loading and saving material files** (`LoadMaterialSet`, `SaveMaterialSet`, `LoadMaterialCollection`, `SaveMaterialCollection`). These are library I/O and belong in 3c.
- **Compound nodes** (`CompoundData` and the `ShaderNodeCompoundDataType` methods), texture gamma (`Texture()` and `TextureType`), and the material node manager (clipboard copy and paste). This is the builder's call (see "Left to the builder"). All of them stay reachable through `ExPoser.Api`.

## Anti-goals

- **Invented behaviour.** No name generation, no add-or-replace policy, no reachability rules and no automatic cleanup.
- **A second way of addressing things.** Materials, trees, nodes and inputs are named by struct paths, like figures, actors and dials, not by loose string arguments.
- **Structs that hold handles,** and so go stale after a reconnect.

## Constraints

- **The 3a conventions throughout:**
  - every function returns `{:ok, _} | {:error, %ExPoser.Error{}}` and has a `!` variant;
  - options come last (`:server`, `:timeout`, and `:frame` where time applies);
  - structs are plain data with an `Inspect` implementation;
  - each module has a `handle/2` escape hatch, whose handle the caller releases;
  - public functions come first, A to Z, then private ones, A to Z.
- **Name paths.** Every struct is a path of names, resolved inside Poser in the same request as the work, one documented lookup method per step:
  - material: `FigureType.Material(name)` or `ActorType.Material(name)`, depending on whether it belongs to a figure or a prop;
  - layer: `MaterialType.LayerByName(name)`, then `MaterialLayerType.ShaderTree()`;
  - main tree: `MaterialType.ShaderTree()`;
  - atmosphere and background trees: `SceneType.AtmosphereShaderTree()` and `SceneType.BackgroundShaderTree()`;
  - node: `ShaderTreeType.NodeByInternalName(name)`;
  - input: `ShaderNodeType.InputByInternalName(name)`;
  - output: `ShaderNodeType.OutputByInternalName(name)`.

  `ExPoser.Ref.path/1` and `ExPoser.Ref.lookup_op/3` gain the new steps.
- **Fixed cost.** Reads of many things use a fixed number of round trips while they fit in one batch chunk (2000 wire ops), as `Light.snapshot_all` does.
- **The Fake Poser** gains materials, layers, trees, nodes, inputs and outputs, enough for every unit test. Its behaviour follows the docs and nothing more.
- **Live tests** run against a real Poser, as in 3b-1, and their output is recorded in a findings file.

## Approaches considered

| | Approach | Trade-off | |
|---|---|---|---|
| **A** | One struct per level, like figures, actors and dials: `%Material{}`, `%ShaderTree{}`, `%ShaderNode{}`, `%ShaderInput{}` (and an output struct), each holding names only. | Four or five new modules and small `Batch` additions. It's consistent with the rest of the API, pipe-friendly, and every operation works in a batch. | **Chosen by the user.** |
| B | One `Material` module with path arguments (`Material.set_input(material, "Image_Map", "Image_Source", path)`). | Fewer modules, but a second addressing style. Nodes and inputs can't be passed around or batched like other structs. | Not chosen. |
| C | Edit a tree as data and let ExPoser work out the creates, deletes and links. | Convenient, but working out a diff is invented policy, and it's catalogue-phase preset work. | Dropped. |

## Decided

- Approach A.
- Main trees and layer trees, both readable and changeable. Layers can be created and deleted. *(user)*
- Atmosphere and background trees are included. *(proposed, user agreed)*
- The flat material settings are included. They're often all that's needed. *(user)*
- No pruning function: it's application-layer work. *(user agreed)*
- No applying stored trees in 3b-2. *(user agreed)*
- Animated inputs come in a later phase. *(user)*
- `UpdatePreview` is sent after changes, because the docs tell the caller to do it. *(proposed, user agreed)*

## Settled after review (Claude's calls, for the user to check)

1. **Layers are addressed by name,** like lights, cameras and nodes. A layer struct holds the material and the layer name, and is looked up with `LayerByName`. An index would shift whenever a layer is added or deleted.
   - `DeleteLayer` takes an index, so deleting by name first reads the layer names (one request) and then calls `DeleteLayer(i)` (a second). A name that matches no layer is `:not_found`, and a name that matches several is `:ambiguous`, before anything is deleted.
   - `CreateLayer(name)` returns nothing. ExPoser returns a layer struct with that name, and later calls look it up by name as usual.
2. **A created node comes back as a `%ShaderNode{}`** holding the internal name Poser gave it, read back in the same request (as `Light.create` does).
   - Inside a batch, later ops refer to the new node by a placeholder for that op's result. They don't use a struct.
   - So a node is named in two ways: by its path in a struct, or by a placeholder within one batch. `Ref` and `Batch` support both.
3. **Ops run strictly in order, and ExPoser takes whatever Poser does.** If a batch deletes a node and a later op names a node Poser has reused that name for, the later op acts on the node Poser finds. That follows the "dumb API" rule. There is no "resolve every path first" step.
4. **A material's owner is the struct it was found from:** a `%Figure{}` (lookup through `FigureType.Material`) or an `%Actor{}`, meaning a prop or a body part (lookup through `ActorType.Material`). The docs allow both, and `Ref.path/1` gets a clause for each.
5. **The input setter is chosen by the value's shape:** a string goes to `SetString`, `{r, g, b}` to `SetColor`, and a number to `SetFloat`. Booleans, integers and menus are numbers, as the `SetFloat` doc says, so there's no `true`/`false`.
   - The bridge gets no type-dispatch helper.
   - A value of the wrong kind returns Poser's own error.
   - Reads return what `Value()` gives.
6. **`UpdatePreview` is sent once per changed tree, at the end of each request (each batch chunk) that changed it.** That keeps every request self-contained.
   - A tree counts as changed if the request set an input, linked, unlinked, or created or deleted a node in it. Setting a root counts too.
   - The scene's atmosphere and background trees are trees like any other.
   - Flat material settings don't change a tree, so they don't trigger it.
7. **The whole-tree read is built from ordinary ops,** with no new bridge helper, so the bridge stays generic. Its request count is fixed while the read fits in one 2000-op chunk. A bigger tree takes more chunks and so more requests. A typical material tree fits in one chunk.
8. **Outputs get a struct, `%ShaderOutput{}`,** named by internal name and looked up with `OutputByInternalName`. Linking takes either an output struct or a node, which means the node's default output (`ShaderNodeType.ConnectToInput`), and an input.
9. **Setting a renderer root takes a node and a renderer.** The tree comes from the node's own path, so there's no separate tree argument to disagree with it.

## Left to the builder

- Module and function names, within the 3a conventions. For example `ExPoser.Material`, `ExPoser.MaterialLayer`, `ExPoser.ShaderTree`, `ExPoser.ShaderNode`, `ExPoser.ShaderInput` and `ExPoser.ShaderOutput`.
- The shape of the whole-tree data struct.
- The form of the in-batch placeholder for a created node, for example a `{:result, n}` reference resolved by the bridge, as Task 2 of 3b-1 did for struct arguments.
- How flat colour settings are encoded: `{r, g, b}` like `Light`'s `:color`.
- Whether node types are passed as Poser's type strings (`"image_map"`, `"ccl_ImageTexture"`), as `ExPoser.Const` names, or both. Passing Poser's strings through unchanged is the minimum.
- Whether compound nodes, texture gamma or the node manager get thin wrappers, or stay `ExPoser.Api`-only for now.
- The PR split. Expect several small stacked PRs, as in 3b-1: Fake Poser, paths, flat settings, nodes and inputs, links, create and delete, layers, the whole-tree read, live tests, docs.

## Black-box probes (deferred; not part of this design)

Add these to the probe list for the later application-layer test phase:

1. Does `Material(name)` take the internal `Name()` or the GUI name? The doc says "typically a name displayed in the Poser GUI material pulldown".
2. Does `LayerByName` match `Name()` or `ExtName()`? `LayerByExtName` exists too.
3. What internal name does `CreateNode` give a new node, and are names reused after `Delete`?
4. Does `ShaderNodeType.ConnectToInput` use the node's selected output or its first output?
5. Does a set or a link show without `UpdatePreview`, and does it matter for rendering?

The design doesn't depend on the answers. ExPoser reads back whatever Poser reports.
