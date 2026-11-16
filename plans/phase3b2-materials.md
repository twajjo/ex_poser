# Phase 3b-2: Materials Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add materials to the idiomatic layer: flat material settings, shader trees (main, layer, atmosphere, background), layers, nodes, inputs, outputs, links, renderer roots and a whole-tree snapshot. Every single-request operation also has a `Batch` form.

**Architecture:** There are six new name-path structs: `%Material{}`, `%MaterialLayer{}`, `%ShaderTree{}`, `%ShaderNode{}`, `%ShaderInput{}` and `%ShaderOutput{}`. `ExPoser.Ref.path/1` gains a step for each, so every op runs through the existing `ExPoser.Batch`: lookups happen in the same request and no handles are kept. The `Batch` compiler gains three things:
- **Tree changes:** ops that change a tree make the compiler emit `UpdatePreview` once for each changed tree at the end of each chunk.
- **Created nodes:** a placeholder node (`{:created, k}`) refers to the node made by op `k`.
- **Forgetting:** after a delete, the compiler drops its memoized lookups, so later ops look the node up again.

**Tech Stack:** Elixir 1.18+, ExUnit with `PoserTest.ClientCase` (the standalone Python bridge on `python/fake_poser.py`), Python 3 `unittest` for Fake Poser, and jj for commits.

**Spec:** `plans/phase3b2-materials-design.md`

## Global Constraints

- Every public function returns `{:ok, _} | {:error, %ExPoser.Error{}}` and has a `!` variant that raises (via `Ref.unwrap!/1`). Pure struct builders (no request) return the struct and have no `!`.
- Opts are checked with `Keyword.validate!`: `:server` and `:timeout` everywhere. No material function takes `:frame`, because animated inputs come later.
- Structs never hold a `%ExPoser.Handle{}`. Every test ends with `assert_no_handles(c)`.
- Renderer atoms: `:preview` 0, `:firefly` 1, `:poser4` 2, `:sketch` 3, `:superfly` 4 (`kRenderEngineCode*`). Input type atoms: `:none` -1, `:float` 0, `:color` 1, `:vector` 2, `:string` 3, `:boolean` 4, `:integer` 5, `:menu` 6 (`kNodeInputCode*`). An unknown code read from Poser stays an integer, and an integer passes through on the way in. An unknown atom raises `ArgumentError`.
- Input values are chosen by shape: a binary goes to `SetString(s)`, `{r, g, b}` (numbers) to `SetColor(r, g, b)`, and a number to `SetFloat(x * 1.0)`. Anything else raises `ArgumentError` before any request. Reads return `Value()` as Poser gives it.
- Node types are Poser's type strings, passed through unchanged (`"image_map"`, `"ccl_ImageTexture"`).
- `UpdatePreview` is sent on a tree once per chunk, as the chunk's last wire op(s), for each tree that an op in that chunk changed. Tree-changing ops: `set_input`, `link`, `unlink`, `create_node`, `delete_node` and `set_root`. Flat material settings, node name and location, and layer create/delete don't count.
- Batch forms live in `ExPoser.Batch` (doc group "Materials"), and each module's single-request functions are one-op batches built from them. Multi-request operations have no batch form: listings, `ShaderInput.source`, `MaterialLayer.delete` and `ShaderTree.snapshot`.
- Module layout (the user's rule): attributes, aliases, struct and types first; then every `def` A–Z by name then arity; then `@impl` callbacks A–Z; then every `defp` A–Z. An anonymous function bound to a variable spans several lines.
- Each idiomatic public function gets `@doc group:` and an *Examples* section. Doctests are used where no Poser is needed (`Ref.path`, the pure builders).
- Checks for each task: `mix format --check-formatted`, `mix compile --warnings-as-errors`, `mix credo --strict` on the changed files, `mix test`, and `python3 -m unittest discover python/tests`.
- Commits use `jj commit -m "<message>"` with no Claude credit. Each task is one bookmark and one PR to `main`, opened after the PR before it has merged and the user says OK.

## Path steps (used by Tasks 2 onward)

| Struct | Fields | Path |
|---|---|---|
| `%Material{owner, name}` | `owner`: `%Figure{}` or `%Actor{}` | `path(owner) ++ [{:material, name}]`, looked up with `Material(name)` |
| `%MaterialLayer{material, name}` | | `path(material) ++ [{:layer, name}]`, looked up with `LayerByName(name)` |
| `%ShaderTree{owner}` | `owner`: `%Material{}`, `%MaterialLayer{}`, `:atmosphere` or `:background` | material or layer: `path(owner) ++ [{:tree, :main}]` (`ShaderTree()`); scene: `[{:tree, :atmosphere}]` (`AtmosphereShaderTree()`) or `[{:tree, :background}]` (`BackgroundShaderTree()`) |
| `%ShaderNode{tree, internal, name}` | `internal`: a string or `{:created, k}` | `path(tree) ++ [{:node, internal}]` (`NodeByInternalName`) |
| `%ShaderInput{node, internal, name}` | | `path(node) ++ [{:input, internal}]` (`InputByInternalName`) |
| `%ShaderOutput{node, internal, name}` | | `path(node) ++ [{:output, internal}]` (`OutputByInternalName`) |

`name` fields are `nil` on structs built by the pure builders. `Inspect` shows `#ExPoser.ShaderNode<Image_Map>` (the name, or the internal name when the name is `nil`), and likewise for the other structs.

## Review Focus

1. **Using a node after deleting it in the same batch.** `delete_node(n)` followed by `set_input` on an input of `n` must not reuse the memoized handle. It looks the node up again, and gets Poser's `not_found` (or whatever node now has that name, per design call 3). The test goes in Task 8.
2. **A placeholder used across a chunk boundary.** With `chunk: 8`, a `create_node` in chunk 1 and a `set_input` on that node's input in chunk 2 still reach the new node, through `NodeByInternalName` with the internal name read in chunk 1. The test goes in Task 8.
3. **A placeholder from another batch, or one that points forward.** `Batch.run` raises `ArgumentError` before sending anything. The test goes in Task 8.
4. **A failure midway through a tree-changing batch.** The ops before the failure stay applied, `UpdatePreview` is not sent for the failed chunk, and `handles == 0`. The test goes in Task 5, which records what happens; the design doesn't promise a preview after a failure.
5. **A layer name that matches no layer, or several.** `MaterialLayer.delete` returns `:not_found` or `:ambiguous`, and `DeleteLayer` is never called. The test goes in Task 9.

## Tasks and PRs

Each task is one PR to `main`, with bookmark `3b2-<n>-<slug>`:

| Task | Bookmark |
|---|---|
| 0 | `3b2-0-spec-plan` (spec and plan docs) |
| 1 | `3b2-1-fake-materials` |
| 2 | `3b2-2-structs-paths` |
| 3 | `3b2-3-listings` |
| 4 | `3b2-4-flat-settings` |
| 5 | `3b2-5-inputs-preview` |
| 6 | `3b2-6-node-props` |
| 7 | `3b2-7-links-roots` |
| 8 | `3b2-8-create-delete-nodes` |
| 9 | `3b2-9-layers` |
| 10 | `3b2-10-snapshot` |
| 11 | `3b2-11-live-tests` |
| 12 | `3b2-12a-guide`, `3b2-12b-cheatsheet`, `3b2-12c-moduledocs` |

---

### Task 1: Fake Poser materials

**Files:**
- Create: `python/fake_materials.py` (the classes below; `fake_poser.py` imports it, to keep that file small)
- Modify: `python/fake_poser.py` (`FigureType` and `ActorType` get `Materials()` and `Material(name)`; `SceneType` gets `AtmosphereShaderTree()` and `BackgroundShaderTree()`; seed the scene)
- Test: `python/tests/test_fake_materials.py`

**Interfaces:**
- Classes, named as in Poser: `MaterialType`, `MaterialLayerType`, `ShaderTreeType`, `ShaderNodeType`, `ShaderNodeInputType` and `ShaderNodeOutputType`. Only documented methods, plus fake-only `PreviewCount()` on `ShaderTreeType` (how many times `UpdatePreview` ran).
- `MaterialType`: every flat getter and setter in spec Goal 1, with colours as 3-tuples (setters take `r, g, b`). Also `Name`, `ExtName`, `ShaderTree`, `Layers`, `LayerByName` (raises `error` on a miss), `NumLayers`, `CreateLayer(name)` (returns `None`) and `DeleteLayer(i)`.
- `ShaderTreeType`: `Nodes`, `NodeByInternalName` (raises on a miss), `CreateNode(type)`, `RendererRootNode(code)` (`None` when unset), `SetRendererRootNode(node, code)`, `UpdatePreview`, plus `PreviewCount()` (fake only).
  - `CreateNode` gives the internal name `type` the first time and `type_2`, `type_3` and so on after that, with the display name equal to the internal name. Its inputs and outputs come from the type table below; an unknown type raises `error`.
- `ShaderNodeType`: `InternalName`, `Name`, `SetName`, `Type`, `Location` (an `(x, y)` tuple), `SetLocation(x, y)`, `IsRoot`, `Inputs`, `Outputs`, `InputByInternalName`, `OutputByInternalName` (both raise on a miss), `ConnectToInput(input)` (its first output) and `Delete()`. `Delete()` also disconnects every input fed by this node.
- `ShaderNodeInputType`: `InternalName`, `Name`, `Type`, `Value`, `SetFloat`, `SetColor(r, g, b)`, `SetString`, `InNode`, `InOutput` and `Disconnect`. A setter of the wrong kind for the input's type raises `error`.
- `ShaderNodeOutputType`: `InternalName`, `Name` and `ConnectToInput(input)`.
- The type table:
  - `PoserSurface`: inputs `Diffuse_Color` (color), `Diffuse_Value` (float) and `Bump` (float); output `out`; it is a root.
  - `image_map`: inputs `Image_Source` (string, default `""`) and `U_Offset` (float); output `Color`.
  - `atmosphere`: input `Fog_Color` (color); a root.
  - `background`: input `Color` (color); a root.
- The seed:
  - `figure 1` actor `hip` has material `Skin`: main-tree nodes `PoserSurface` (the FireFly root) and `Image_Map` (type `image_map`), with `Image_Map.Color` linked to `PoserSurface.Diffuse_Color`, and one layer `Layer_1` whose tree has a `PoserSurface` node.
  - `FigureType.Materials()` for figure 1 returns `[Skin, Hair]`, where `Hair` is a material with a `PoserSurface`-only tree.
  - Prop `ball` has material `Preview`.
  - The atmosphere and background trees each hold one root node, `atmosphere` and `background`.

- [ ] **Step 1: Write the failing Python tests.** Cover the seed, `CreateNode` naming, link/disconnect/`InNode`, a wrong-kind setter raising, `DeleteLayer`, `Delete()` disconnecting fed inputs, and `PreviewCount`.
- [ ] **Step 2: Run the tests and confirm they fail.** Run `python3 -m unittest python.tests.test_fake_materials -v`. Expected: an `ImportError` or `AttributeError`.
- [ ] **Step 3: Implement the interfaces above.** Rename each class with `__name__` where needed, as `LightActor` does, so the handle table sees Poser's class names.
- [ ] **Step 4: Run the Python tests, then `mix test`, and confirm all pass.** The seed adds no actors, so the existing expectations hold.
- [ ] **Step 5: Commit** with `jj commit -m "Fake Poser: materials, layers, shader trees, nodes, inputs and outputs"`.

### Task 2: Structs and paths

**Files:**
- Create: `lib/ex_poser/material.ex`, `lib/ex_poser/material_layer.ex`, `lib/ex_poser/shader_tree.ex`, `lib/ex_poser/shader_node.ex`, `lib/ex_poser/shader_input.ex`, `lib/ex_poser/shader_output.ex` (each with its struct, type, `Inspect`, `handle/2` and the pure builders below)
- Modify: `lib/ex_poser/ref.ex` (`ref` and `step` types, `path/1`, `ref?/1`, `lookup_op/3`), `lib/ex_poser/scene.ex`
- Test: `test/ex_poser/ref_test.exs`, `test/ex_poser/material_paths_test.exs`

**Interfaces:**
- Produces the structs and paths in the "Path steps" table.
- `Ref.lookup_op/3` clauses:
  - `{:material, n}` → `Material(n)`;
  - `{:layer, n}` → `LayerByName(n)`;
  - `{:tree, :main}` → `ShaderTree()`;
  - `{:tree, :atmosphere}` → `AtmosphereShaderTree()`;
  - `{:tree, :background}` → `BackgroundShaderTree()`;
  - `{:node, i}` → `NodeByInternalName(i)` (for `{:created, k}`, the argument is the marker `{:created_name, k}`, which Task 8 substitutes);
  - `{:input, i}` → `InputByInternalName(i)`;
  - `{:output, i}` → `OutputByInternalName(i)`.
- The pure builders:
  - `Material.tree(material) :: ShaderTree.t()`;
  - `MaterialLayer.tree(layer) :: ShaderTree.t()`;
  - `Scene.atmosphere_tree() :: ShaderTree.t()` and `Scene.background_tree() :: ShaderTree.t()`;
  - `ShaderNode.input(node, internal) :: ShaderInput.t()`;
  - `ShaderNode.output(node, internal) :: ShaderOutput.t()`.
- Each module's `handle(struct, opts)` returns `{:ok, %Handle{}}` like `Actor.handle/2`.

- [ ] **Step 1: Write the failing tests.**
  - Doctests of `Ref.path/1` for each struct.
  - `test "Batch.call on a material input reads its value"`: `Batch.new() |> Batch.call(input, "Value") |> Batch.run(server: c)` for `Skin`'s `PoserSurface/Diffuse_Color` returns a 3-tuple.
  - `test "a missing layer is not_found with its path"`: the error is `:not_found`, and `details.path` ends with `{:layer, "Nope"}`.
  - `test "the atmosphere tree resolves"`: `Batch.call(atmo_tree, "NumNodes")` returns 1.
  - A test that `Scene.atmosphere_tree() |> Ref.path() == [tree: :atmosphere]`.
- [ ] **Step 2: Run `mix test test/ex_poser/ref_test.exs test/ex_poser/material_paths_test.exs` and confirm they fail.** Expected: undefined modules.
- [ ] **Step 3: Implement the structs, `Ref` clauses and builders.**
- [ ] **Step 4: Run the tests and confirm they pass.** Run the full `mix test` too. Expected: all pass, with `handles == 0`.
- [ ] **Step 5: Commit** with `jj commit -m "Material, layer, tree, node, input and output structs with Ref paths"`.

### Task 3: Listings and lookups

**Files:**
- Modify: `lib/ex_poser/ref.ex` (add `list/4`; `children_many/4` calls it), `lib/ex_poser/figure.ex`, `lib/ex_poser/actor.ex`, `lib/ex_poser/material.ex`, `lib/ex_poser/shader_tree.ex`, `lib/ex_poser/shader_node.ex`
- Test: `test/ex_poser/ref_test.exs`, `test/ex_poser/material_test.exs`, `test/ex_poser/shader_tree_test.exs`

**Interfaces:**
- `Ref.list(parents, list_method, methods, opts) :: {:ok, [[map()]]}` (`@doc false`). It is `children_many/4` with the full method list given, because `MaterialType` and `MaterialLayerType` have no `InternalName`. `children_many/4` becomes `list(parents, m, ["InternalName", "Name" | extra], opts)`.
- `Figure.materials(fig, opts)` and `Actor.materials(actor, opts)` return `{:ok, [Material.t()]}`, read with `Name`.
- `Figure.material(fig, name, opts)` and `Actor.material(actor, name, opts)` look the material up through the path, so `Material(name)` runs in one request. They return `{:ok, Material.t()}`, or `:not_found`.
- `Material.layers(m, opts)` returns `{:ok, [MaterialLayer.t()]}`, and `Material.layer(m, name, opts)` looks the layer up through the path.
- `ShaderTree.nodes(tree, opts)` returns `{:ok, [ShaderNode.t()]}`. `ShaderTree.node(tree, name, opts)` takes an internal name or a display name, through `Ref.lookup/8`, as `Scene.light/2` does.
- `ShaderNode.inputs(node, opts)` returns `{:ok, [ShaderInput.t()]}`, and `ShaderNode.outputs(node, opts)` returns `{:ok, [ShaderOutput.t()]}`.

- [ ] **Step 1: Write the failing tests.**
  - `Figure.materials` gives the names `["Skin", "Hair"]`.
  - `Actor.material(ball, "Preview")` succeeds.
  - `Material.layers(skin)` gives the names `["Layer_1"]`.
  - `ShaderTree.nodes(Material.tree(skin))` gives the internal names `["PoserSurface", "Image_Map"]`.
  - `ShaderTree.node(tree, "Image_Map")` succeeds, and `ShaderTree.node(tree, "Nope")` is `:not_found`.
  - `ShaderNode.inputs(surface)` gives the internal names `["Diffuse_Color", "Diffuse_Value", "Bump"]`.
  - Every test ends with `assert_no_handles`.
- [ ] **Step 2: Run the tests and confirm they fail.**
- [ ] **Step 3: Implement.** Use `Ref.list` for the listings, and `Batch` with one lookup op for the by-name material and layer lookups.
- [ ] **Step 4: Run `mix test` and confirm it passes**, including the existing `children` tests, unchanged.
- [ ] **Step 5: Commit** with `jj commit -m "List and look up materials, layers, nodes, inputs and outputs"`.

### Task 4: Flat material settings

**Files:**
- Modify: `lib/ex_poser/material.ex`, `lib/ex_poser/batch.ex`
- Test: `test/ex_poser/material_test.exs`

**Interfaces:**
- `Material.props() :: [atom()]` and the table `key → {getter, setter, kind}`:
  - `:ambient_color`, `:diffuse_color`, `:reflection_color`, `:specular_color` and `:texture_color` (kind `:color`; `XColor`/`SetXColor`);
  - `:ambient_map`, `:bump_map`, `:reflection_map`, `:specular_map`, `:texture_map` and `:transparency_map` (kind `:string`; `XMapFileName`/`SetXMapFileName`);
  - `:bump_strength`, `:reflection_strength`, `:transparency_min`, `:transparency_max`, `:transparency_falloff` (`TransparencyExpo`) and `:ns` (`Ns`) (kind `:float`);
  - `:selected` (`Selected`/`SetSelected`, kind `:int`, passed through).
- `Material.get(m, key | [key], opts) :: {:ok, value | %{key => value}}`, in one batch.
- `Material.set(m, key, value, opts)` and `Material.set(m, %{key => value}, opts) :: {:ok, :ok}`, in one batch. Keys and value kinds are checked before sending. A colour must be a 3-tuple of numbers (it is sent as 3 floats), a `:string` value a binary, and a `:float` value a number (sent as a float).
- `Batch.set_material(b, m, key, value) :: Batch.t()`, whose result is `:ok`. `Material.set` is built from it, and `Material.get` from `Batch.call`.

- [ ] **Step 1: Write the failing tests.**
  - `set(skin, :diffuse_color, {0.1, 0.2, 0.3})` then `get` returns `{0.1, 0.2, 0.3}`.
  - A map set of `:texture_map` and `:bump_strength` reads back.
  - `get(skin, [:ns, :selected])` returns a map.
  - `set(skin, :nope, 1)` and `set(skin, :diffuse_color, {1, 2})` raise `ArgumentError`, and nothing is sent.
  - The tree's `PreviewCount` is unchanged after a flat set.
- [ ] **Step 2: Run the tests and confirm they fail.**
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run `mix test` and confirm it passes.**
- [ ] **Step 5: Commit** with `jj commit -m "Material flat settings: get, set and Batch.set_material"`.

### Task 5: Input values, and UpdatePreview in Batch

**Files:**
- Modify: `lib/ex_poser/batch.ex` (`push` takes an op map with optional `:changes` (a tree ref); `run` handles the `{:preview, k}` role), `lib/ex_poser/batch/compiler.ex`, `lib/ex_poser/shader_input.ex`
- Test: `test/ex_poser/batch_test.exs`, `test/ex_poser/shader_input_test.exs`

**Interfaces:**
- An op may carry `changes: %ShaderTree{}`. The compiler keeps an ordered list of changed tree paths for each chunk. Placing an op whose tree isn't in that list yet costs one more wire op. When a chunk closes (a split, or `finish`), it emits `{:invoke, {:result, memo[tree_path]}, "UpdatePreview", []}` for each tree in the list, with role `{:preview, k}`, where `k` is the last caller op in the chunk that changed that tree. The tree path is always memoized, because the changing op looked it up.
- `Batch.set_input(b, input, value) :: Batch.t()`: the setter is chosen by shape (see Global Constraints), and the result is `:ok`.
- `ShaderInput.get(input, opts) :: {:ok, value}` (`Value()`), `ShaderInput.type(input, opts) :: {:ok, atom() | integer()}`, and `ShaderInput.set(input, value, opts) :: {:ok, :ok}` (a one-op `Batch.set_input`).

- [ ] **Step 1: Write the failing tests.**
  - The compiler: two `set_input` ops on one tree emit one `UpdatePreview`, as the last wire op. Ops on two trees emit two, in first-change order. With `chunk: 6`, ops spread over two chunks give one preview per chunk. A batch of `Batch.call` reads only emits none.
  - Integration: `ShaderInput.set(image_source, "C:/tex/a.png")` then `get` returns the path, and `PreviewCount` went up by 1.
  - `set(diffuse_color, {1, 0, 0})` reads back `{1.0, 0.0, 0.0}`.
  - `set(input, :bad)` raises `ArgumentError`.
  - Setting a string on a colour input returns Poser's error with `details.index == 0`.
  - Review Focus 4: a batch whose second op fails. The first op is applied, record whether `PreviewCount` changed, and `handles == 0`.
  - `ShaderInput.type(diffuse_color)` is `{:ok, :color}`.
- [ ] **Step 2: Run the tests and confirm they fail.**
- [ ] **Step 3: Implement the compiler change, then `set_input` and `ShaderInput`.**
- [ ] **Step 4: Run `mix test` and confirm every existing `batch_test` still passes.** No op without `:changes` may get a new wire op.
- [ ] **Step 5: Commit** with `jj commit -m "Batch: UpdatePreview per changed tree per chunk; ShaderInput get/set"`.

### Task 6: Node properties

**Files:**
- Modify: `lib/ex_poser/shader_node.ex`, `lib/ex_poser/batch.ex`
- Test: `test/ex_poser/shader_node_test.exs`

**Interfaces:**
- `ShaderNode.get(node, key | [key], opts)`, with keys:
  - `:name` (`Name`);
  - `:type` (`Type`);
  - `:location` (`Location`, an `{x, y}` tuple);
  - `:root` (`IsRoot`, passed through as Poser gives it).
- `ShaderNode.set(node, key, value, opts)` and `set(node, %{...}, opts)`, with keys:
  - `:name`, a binary (`SetName`);
  - `:location`, an `{x, y}` pair of integers (`SetLocation(x, y)`).
- `Batch.set_node(b, node, key, value)`, whose result is `:ok`. It doesn't change a tree.

- [ ] **Step 1: Write the failing tests.**
  - `set(img, :location, {120, 40})` then `get` returns `{120, 40}`.
  - Setting `:name` reads back.
  - `get(surface, [:type, :root])` returns a map.
  - An unknown key, or `:location` given `{1.5, 2}`, raises `ArgumentError`.
  - `PreviewCount` is unchanged.
- [ ] **Step 2: Run the tests and confirm they fail.**
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run `mix test` and confirm it passes.**
- [ ] **Step 5: Commit** with `jj commit -m "ShaderNode get/set: name, type, location, root"`.

### Task 7: Links and renderer roots

**Files:**
- Modify: `lib/ex_poser/shader_input.ex`, `lib/ex_poser/shader_tree.ex`, `lib/ex_poser/batch.ex`
- Test: `test/ex_poser/shader_input_test.exs`, `test/ex_poser/shader_tree_test.exs`

**Interfaces:**
- `Batch.link(b, from, input)`, where `from` is a `%ShaderOutput{}` (`OutputType.ConnectToInput(input)`) or a `%ShaderNode{}` (`ShaderNodeType.ConnectToInput(input)`), and the input is a struct argument. `Batch.unlink(b, input)` sends `Disconnect()`. Both change the input's tree.
- `Batch.set_root(b, node, renderer)` sends `SetRendererRootNode(node, code)` on the node's tree, and changes it.
- `ShaderInput.link(input, from, opts)` and `ShaderInput.unlink(input, opts)` return `{:ok, :ok}`.
- `ShaderInput.source(input, opts) :: {:ok, nil | ShaderOutput.t()}` takes two requests: `InNode` and `InOutput` handles, then `InternalName` and `Name` on each non-nil one. The output's node has the input's tree.
- `ShaderTree.root(tree, renderer, opts) :: {:ok, nil | ShaderNode.t()}` and `ShaderTree.set_root(node, renderer, opts) :: {:ok, :ok}`. A renderer is an atom from the table or an integer.

- [ ] **Step 1: Write the failing tests.**
  - `source(diffuse_color)` is `%ShaderOutput{internal: "Color"}` on node `Image_Map`. After `unlink` it is `nil`. Linking by node again restores it.
  - `root(tree, :firefly)` is `PoserSurface`, and `root(tree, :superfly)` is `nil`.
  - `set_root(img, :superfly)` then `root` returns `Image_Map`.
  - `set_root(img, :bogus)` raises `ArgumentError`.
  - Each tree change bumps `PreviewCount` by 1.
- [ ] **Step 2: Run the tests and confirm they fail.**
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run `mix test` and confirm it passes.**
- [ ] **Step 5: Commit** with `jj commit -m "Links, unlink, input source and renderer roots"`.

### Task 8: Create and delete nodes, placeholders and forgetting

**Files:**
- Modify: `lib/ex_poser/batch.ex`, `lib/ex_poser/batch/compiler.ex`, `lib/ex_poser/shader_tree.ex`, `lib/ex_poser/shader_node.ex`
- Test: `test/ex_poser/batch_test.exs`, `test/ex_poser/shader_node_test.exs`

**Interfaces:**
- `Batch.create_node(b, tree, type)`, whose result is a `%ShaderNode{tree, internal, name}`.
  - The compiler emits `CreateNode(type)` (role `{:caller, k}`), then `InternalName` and `Name` on its result (role `{:created, k}`), and memoizes `path(tree) ++ [{:node, {:created, k}}]` to the `CreateNode` wire index. The cost is 3 wire ops plus lookups and a preview. The op changes the tree.
  - `run` builds the struct from the two reads and releases the `CreateNode` handle. It keeps `k => internal` so that later chunks can substitute the `{:created_name, k}` marker in `NodeByInternalName`.
- `Batch.created(b) :: ShaderNode.t()` returns `%ShaderNode{tree, internal: {:created, k}, name: nil}` for the last op. It raises `ArgumentError` if the last op isn't a `create_node`.
- `compile` raises `ArgumentError` for a `{:created, k}` where op `k` isn't a `create_node` in this batch, or where `k` is not less than the index of the op that uses it.
- `Batch.delete_node(b, node)` sends `Delete()`, whose result is `:ok`, and changes the tree. Once it is placed, the compiler deletes every memo key that has `path(node)` as a prefix.
- `ShaderTree.create_node(tree, type, opts) :: {:ok, ShaderNode.t()}` and `ShaderNode.delete(node, opts) :: {:ok, :ok}` are one-op batches.

- [ ] **Step 1: Write the failing tests.**
  - The design's success case: one batch with `create_node(tree, "image_map")`, then `set_input(ShaderNode.input(Batch.created(b), "Image_Source"), path)`, then `link(Batch.created(b), diffuse_color)`. That is one `Client.batch` call (count requests through the fake), and the result's first element is `%ShaderNode{internal: "image_map"}`.
  - Review Focus 1: `delete_node(img)`, then `set_input` on `img`'s `U_Offset` in the same batch, gives `:not_found` with `details.index == 1`, and the delete stays applied.
  - Review Focus 2: the same create, set and link with `chunk: 8` spans chunks and still sets the new node's input.
  - Review Focus 3: a placeholder from another batch, and one that points forward, both raise `ArgumentError`.
  - `ShaderTree.create_node(tree, "nope")` returns Poser's error, with `handles == 0`.
- [ ] **Step 2: Run the tests and confirm they fail.**
- [ ] **Step 3: Implement the compiler (created memo, `{:created, k}` role, forgetting), then `run` (struct building, marker substitution, handle release), then the module functions.**
- [ ] **Step 4: Run `mix test` and confirm it passes.**
- [ ] **Step 5: Commit** with `jj commit -m "Create and delete shader nodes; in-batch placeholders"`.

### Task 9: Layers

**Files:**
- Modify: `lib/ex_poser/material.ex`, `lib/ex_poser/material_layer.ex`, `lib/ex_poser/batch.ex`
- Test: `test/ex_poser/material_layer_test.exs`

**Interfaces:**
- `Batch.create_layer(b, m, name)` sends `CreateLayer(name)`, and its result is `%MaterialLayer{material: m, name: name}`. `Material.create_layer(m, name, opts)` is a one-op batch.
- `MaterialLayer.delete(layer, opts) :: {:ok, :ok}`. It lists the layer names with `Ref.list` (Layers, then `Name`), finds the index, and sends `DeleteLayer(i)`, three requests in all. It returns `:not_found` (with the layer's path) or `:ambiguous` before deleting anything. This has no `Batch` form, because the index needs a read first.

- [ ] **Step 1: Write the failing tests.**
  - `create_layer(skin, "Wet")`, then `layers` includes `"Wet"`, and `MaterialLayer.tree(wet)` resolves.
  - `delete(wet)` removes it.
  - Review Focus 5: deleting `"Nope"` is `:not_found`. With two layers both named `"Dup"`, delete is `:ambiguous`, and both layers are still there.
- [ ] **Step 2: Run the tests and confirm they fail.**
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run `mix test` and confirm it passes.**
- [ ] **Step 5: Commit** with `jj commit -m "Material layers: create and delete"`.

### Task 10: Whole-tree snapshot

**Files:**
- Create: `lib/ex_poser/shader_tree/snapshot.ex`
- Modify: `lib/ex_poser/shader_tree.ex`
- Test: `test/ex_poser/shader_tree_snapshot_test.exs`

**Interfaces:**
- `%ShaderTree.Snapshot{tree: ShaderTree.t(), nodes: [node_map], roots: %{renderer_atom => internal | nil}}`, where:
  - `node_map = %{internal, name, type, location, root, inputs: [input_map], outputs: [%{internal, name}]}`;
  - `input_map = %{internal, name, type, value, from: nil | {node_internal, output_internal}}`.
- `ShaderTree.snapshot(tree, opts) :: {:ok, Snapshot.t()}` takes four requests, whatever the tree's size (while each fits in a chunk):
  1. Look up the tree, then `Nodes()` and `RendererRootNode(c)` for the five codes.
  2. On each node: `InternalName`, `Name`, `Type`, `Location`, `IsRoot`, `Inputs()` and `Outputs()`; and `InternalName` on each non-nil root.
  3. On each input: `InternalName`, `Name`, `Type`, `Value`, `InNode()` and `InOutput()`; and `InternalName` and `Name` on each output.
  4. `InternalName` on each non-nil `InNode` and `InOutput`.
- Each step goes through `ExPoser.Client.batch` directly, as `Ref.read_children` does, and releases every handle on success and on failure.

- [ ] **Step 1: Write the failing tests.**
  - The snapshot of Skin's main tree has 2 nodes.
  - `Diffuse_Color`'s `from` is `{"Image_Map", "Color"}`.
  - `roots.firefly` is `"PoserSurface"`, and the other renderers are `nil`.
  - Counting requests through the fake gives 4 for this tree, and still 4 after adding 5 nodes.
  - `handles == 0`.
  - The atmosphere tree snapshots too.
- [ ] **Step 2: Run the tests and confirm they fail.**
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run `mix test` and confirm it passes.**
- [ ] **Step 5: Commit** with `jj commit -m "ShaderTree.snapshot: whole tree in four requests"`.

### Task 11: Live tests (the user runs them)

**Files:**
- Modify: `test/live/live_poser_test.exs`
- Create: `plans/phase3b2-findings.md`

- [ ] **Step 1: Write the `@tag :poser` tests.** Run each step against the loaded figure's first material: list materials, set and restore a flat colour, read a snapshot, create an `image_map`, set its `Image_Source`, link it and delete it in one batch, create and delete a layer, and read and set the atmosphere tree's root. Each test restores what it changed. Print the answers to the black-box probes from the spec (probes 1–5) and the snapshot timing.
- [ ] **Step 2: Hand the user the one-line command** `mix test --only poser test/live/live_poser_test.exs`. Record the output and the probe answers in the findings file. Fix any failures, one step at a time with the user.
- [ ] **Step 3: Commit** with `jj commit -m "Live tests for materials; 3b-2 findings"`.

### Task 12: Docs (three PRs, as in 3b-1)

- **12a:** `guides/materials.md` (flat settings, trees, nodes, links, batches with `Batch.created`, snapshot), plus the `mix.exs` extras. `mix docs` shows no warnings.
- **12b:** concept rows (Material, layer, shader tree, node, input, output, snapshot) and cheatsheet sections (set a bitmap, swap a texture node, read a tree).
- **12c:** moduledocs link to the guide, and the new modules go in the Idiomatic API group. The `@doc group:` names are checked in the sidebar.
- [ ] Each one: write it, run `mix docs` (no warnings) and `mix test`, then commit.
