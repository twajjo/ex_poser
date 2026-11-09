# Phase 2: Code Generation and Full API Coverage — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Generate an Elixir function for every PoserPython function and method in `priv/poser_api.json`, generate the constants, record coverage in a manifest, and smoke-test every generated getter against a real scene.

**Architecture:**
- A docstring signature parser plus a small overrides file turn the dump into a model.
- `mix poser.gen` renders the model into committed modules under `lib/poser/api/`, plus `lib/poser/const.ex` and a JSON manifest.
- Generated functions are thin calls into a hand-written runtime (`Poser.Call`) that maps optional arguments and calls `Poser.Client`.
- `mix poser.smoke` walks the live scene through the generated getters and reports every outcome.
- On the Python side, numpy arrays now travel in both directions, and numpy scalars are converted to plain values.

**Tech Stack:** Elixir 1.20 / OTP 29 and the Phase 1 `Poser.Client`. Python 3.7.9 with numpy 1.19.5 (Poser bundles numpy 1.19). Nx 1.0 is an optional dependency.

**Spec:**
- `plans/elixir-poser-bridge-plan.md`, sections 4 and 5 (Phase 2).
- `plans/phase0-findings.md`: `inspect.signature` fails everywhere, but every docstring carries a typed signature.
- `plans/phase1-findings.md`: deferred minors.

## Global Constraints

- **Add-on dependencies:** the stdlib plus `numpy` only. The add-on runs on Python 3.7 and must import when numpy is missing (the standalone tests still run without it).
- **Generated code is committed.** Regenerating from the same dump gives byte-identical files, formatted with `Code.format_string!/1`.
- **Naming:** Python names become snake_case (`SetValue` → `set_value`). The Python name appears in `@doc` and in the wire call.
- **Keyword arguments:** Python optional arguments become a trailing `opts` keyword list. Poser's C methods take arguments positionally only, so `Poser.Call` turns opts into positional arguments.
- **Not generated in this phase:**
  - Callback-taking methods (a `<FunctionType>` parameter) are skipped and listed in the manifest. Callbacks are Phase 4.
  - `!` variants, `with_scope` and per-class structs are Phase 3. Handles stay `%Poser.Handle{}`, and the generated `@type t` is `Poser.Handle.t()`.
- **Timeouts:** client calls keep the Phase 1 default of 120 000 ms.
- **Authorship:** no Claude credit in commits or files.
- **Version control:** commit with `jj commit <paths> -m`.
- **Commands for the user:** give them as single lines.

## Review Focus

1. **Wrong arity from an odd docstring, with no error at generation time.** For example, an optional group mid-list (`SetValue(<FloatType> value {, <IntType> doUpdate) }`) or an unclosed brace. Expect the parser to reject anything it can't read fully, and the override, or the variadic fallback recorded in the manifest, to take its place. Pinned in Task 3.
2. **Gaps in optional arguments.** If an earlier optional argument without a known default is left out while a later one is given, the arguments must not shift into the wrong positions. Expect `ArgumentError`, and the same for unknown opts keys. Pinned in Task 2.
3. **Name clashes.** `HairType.SetPullDown` and `setPullDown` collide, and `ShaderTreeType.Node` clashes with `Kernel.node/1`. Expect the code to compile with no warnings, and every clash to be resolved in the manifest. Pinned in Tasks 4 and 7.
4. **The smoke walk flushing the handle table.** List getters create hundreds of handles, and the 10 000-handle LRU can evict the scene handle the walk still holds. That would show up as fake `stale_handle` failures. Expect results not enqueued for the walk to be released after each call. Pinned in Task 8.
5. **numpy values the codec can't encode.** These are `np.int64` scalars, object arrays and bool arrays. Expect plain values, or a list for object arrays, and never an `EncodeError`. Pinned in Task 1.

---

### Task 1: numpy in both directions; constructors in strict mode

**Files:**
- Modify: `python/poser_bridge/handles.py`, `python/poser_bridge/policy.py`, `python/fake_poser.py`
- Create: `python/requirements-dev.txt` (`numpy==1.19.5`)
- Test: `python/tests/test_handles.py`, `python/tests/test_policy.py`, `python/tests/test_dispatch.py`

**Interfaces:**
- Produces:
  - `HandleTable.resolve` turns `(NDARRAY, dtype, shape, bytes)` into `numpy.frombuffer(bytes, dtype).reshape(shape).copy()`.
  - `wrap` turns numpy scalars into `.item()`. An object-dtype array becomes `wrap(arr.tolist())`, so its elements may become handles.
  - `Policy.load` in strict mode also allows `check_call(name)` for every class whose `doc` contains `poser.<Class>(`.

- [ ] **Step 1:** Run `mise exec -- python -m pip install -r python/requirements-dev.txt`. Expected: numpy 1.19.5 is installed.
- [ ] **Step 2: Write failing tests.** Decorate them with `@unittest.skipUnless(numpy, "numpy not installed")`.
  - `test_ndarray_round_trip`: `resolve(wrap(np.arange(6, dtype="<f4").reshape(2, 3)))` equals the original. Check the dtype and shape too.
  - `test_numpy_scalars_become_plain`: `wrap(np.int64(3))` is `3` with `type int`, `wrap(np.float32(0.5))` is `0.5`, and `wrap(np.bool_(True))` is `True`.
  - `test_object_array_becomes_list`: `wrap(np.array([obj1, obj2], dtype=object))` is a list of two `POSER_OBJ` tuples.
  - `test_bool_array_is_ndarray`: `wrap(np.array([True, False]))[1] == "|b1"`.
  - `test_resolve_ndarray_without_numpy_is_bad_request`: patch the module's numpy reference to `None`, then resolve. Expected: `BadRequest`. This test is not skipped.
  - `test_strict_allows_documented_constructor` (`test_policy.py`): add a `ImageType` class with `doc: "... <ImageType> poser.ImageType(<StringType> fullImagePath)"` to `fixtures/mini_api.json`. Strict `check_call("ImageType")` passes, and `check_call("Unlisted")` still raises.
  - `test_dispatch_numpy_arg` (`test_dispatch.py`): fake `GeomType.SetVertexPositions(arr)` stores the array, and `GeomType.VertexPositions()` returns it. Sent as an ndarray tuple, the array comes back equal.
- [ ] **Step 3:** Run `mise exec -- python -m unittest discover -s python/tests -t python`. Expected: the new tests FAIL.
- [ ] **Step 4: Implement.**
  - Import numpy inside `try`/`except ImportError` (`numpy = None`).
  - Detect numpy scalars with `isinstance(value, numpy.generic)`. Check this before the `numbers.Number` pass-through, because `np.int64` is registered as a Number but erlterms can't encode it.
  - Add `GeomType` to `fake_poser`, reachable through `ActorType.Geometry()`.
- [ ] **Step 5:** Run the same command. Expected: OK. Also run it once with numpy uninstalled from a scratch venv, or reason from the skip decorators. Expected: the skips show and nothing errors.
- [ ] **Step 6:** Commit: `jj commit python -m "numpy arrays in both directions, numpy scalars as plain values, constructors in strict mode"`

### Task 2: `Poser.NDArray` on the wire, Nx, and the `Poser.Call` runtime

**Files:**
- Modify: `lib/poser/codec.ex`, `lib/poser/nd_array.ex`, `mix.exs` (add `{:nx, "~> 1.0", optional: true}`)
- Create: `lib/poser/call.ex`
- Test: `test/poser/codec_test.exs`, `test/poser/nd_array_test.exs`, `test/poser/call_test.exs`

**Interfaces:**
- Produces:
  - `Codec.to_wire(%Poser.NDArray{})` → `{:ndarray, dtype, shape, data}`.
  - `Poser.NDArray.to_nx/1` and `from_nx/1`, compiled only when `Code.ensure_loaded?(Nx)`.
  - `Poser.Call.function(py_name :: String.t(), args :: list(), optional :: [{atom(), default}], opts :: keyword())` and `Poser.Call.method(%Poser.Handle{}, py_name, args, optional, opts)`. Both return `{:ok, term} | {:error, Poser.Error.t()}`.
  - `optional` is the ordered list of optional Python parameters. Each default is `{:default, value}` or `:none` (no known default).
  - The opts keys `:server` and `:timeout` go to `Poser.Client`. Every other key must be in `optional`.

- [ ] **Step 1: Write failing tests.**
  - `to_wire` round trip of an NDArray. `NDArray.from_nx(Nx.tensor([[1.0, 2.0]], type: :f32))` gives `%NDArray{dtype: "<f4", shape: {1, 2}}`, and `to_nx` reverses it. Supported dtypes: `<f4 <f8 <i4 <i8 |u1 |b1`. Anything else raises `ArgumentError` naming the dtype.
  - `call_test.exs`, against the standalone server:
    - `Poser.Call.method(scene, "SetFrame", [3], [], server: c)` → `{:ok, nil}`.
    - With `optional = [a: :none, b: {:default, 0}]`:
      - opts `[b: 5]` → `ArgumentError` mentioning `:a`;
      - opts `[a: 1]` → args `[..., 1, 0]`;
      - opts `[c: 1]` → `ArgumentError` mentioning `:c`.
    - Unit-test the arg builder directly as `Poser.Call.build_args/3`, which is public with `@doc false`.
- [ ] **Step 2:** Run `mix deps.get`, then `mix test`. Expected: the new tests FAIL.
- [ ] **Step 3: Implement.**
  - Trailing omitted optionals are dropped, not filled with defaults: Python already applies its own default.
  - A gap is filled with the known default. If there is no known default, raise.
- [ ] **Step 4:** Run `mix test`. Expected: all tests pass and the build has no warnings.
- [ ] **Step 5:** Commit: `jj commit lib test mix.exs mix.lock -m "NDArray on the wire, optional Nx conversion, Poser.Call runtime"`

### Task 3: Docstring signature parser and overrides

**Files:**
- Create:
  - `lib/poser/gen/signature.ex` (`Poser.Gen.Signature`);
  - `lib/poser/gen/types.ex` (`Poser.Gen.Types`);
  - `priv/poser_api_overrides.json`.
- Test: `test/poser/gen/signature_test.exs`, `test/poser/gen/types_test.exs`, `test/poser/gen/real_dump_test.exs`

**Interfaces:**
- Produces:
  - `Signature.parse(py_name, doc) :: {:ok, sig} | {:error, reason}`, where `sig = %{returns: type, params: [%{name: String.t(), type: type, optional: boolean, default: {:default, term} | :none}]}`.
  - `type` is the raw type text, such as `"IntType"` or `"ActorType List"`, or `{:tuple, [type]}`.
  - `Types.spec(type, :arg | :return, classes) :: Macro.t()`.

**Grammar:**
- **Signature line:** the last docstring line containing `<` and `Name(`.
- **Line form:** `RET Name ( PARAMS ) [.]`, where `RET` is `<type>`, `( <type> [ident], … )` (nested allowed) or empty.
- **Params:** comma-separated. A `{ … }` group marks every parameter inside it as optional, and groups can nest.
- **Param form:** `<type> ident [= default]`.
- **Defaults:**
  - integer, float, quoted string, `true`/`false`/`None`;
  - `poser.kName`, resolved from the dump's constants.
- **Several signature lines with the same parameters:** union the returns (`ShaderNodeInputType.Value`).
- **Everything else is `{:error, reason}`:** a stray `)` or `>`, an unbalanced `{`, a type with no parameter name, text after `)` other than `.`, a `[` group.

**Overrides file** (`priv/poser_api_overrides.json`):
- `"signatures"` maps `"Class.Method"` or `"poser.Function"` to a corrected signature line, parsed by the same parser.
- `"skip"` maps a name to its reason.
- `"smoke_skip"` maps a name to its reason.
- `"constant_groups"` is an ordered list of constant prefixes (used by Task 6).

**Types map** (`:arg` / `:return`):
- `IntType`, `LongType`, `EnumType` → `integer()`
- `FloatType`, `FloatValue` → `number()` / `float()`
- `StringType`, `String`, `StringValue`, `String Type` → `String.t()`
- `BoolType`, `boolType` → `boolean()` / `boolean() | integer()`
- `NoneType` → `nil`
- a class in the dump → `Poser.Handle.t()`
- `X List`, `X list`, `List of X`, `list X` → `[spec(X)]`
- `{:tuple, ts}` → a tuple of specs
- `… Numeric.Array` → `Poser.NDArray.t()`
- `DictType` → `map()`
- `ListType` → `list()`
- `TupleType`, `… Tuple` → `tuple()`
- anything else → `term()`, recorded as an unknown type

- [ ] **Step 1: Write failing tests.** Real docstrings, copied verbatim from the dump, assert:
  - `CloseDocument`: one optional `discardChanges` with `{:default, 0}`;
  - `AddKeyFrame`: one optional, `:none`;
  - `CopyMorphsFromFigure` (override form): defaults `false` and `poser.kMirrorTypeNone` resolved to the constant's value;
  - `AlignmentRotationXYZ` returns `{:tuple, [FloatType ×3]}`;
  - `ParmType.SetValue` as written: `{:error, _}`;
  - `CredManagerType.GetPassword`: `{:error, _}`;
  - `PrefsLocation` (`[...]`): `{:error, _}`;
  - `Palettes`: picks `<list Palettes> Palettes()`, not the example line;
  - `ShaderNodeInputType.Value`: union of three returns;
  - `SceneType.Actors` → `"ActorType List"`.
  
  `types_test.exs` covers each row of the map.
- [ ] **Step 2:** Run `mix test test/poser/gen`. Expected: FAIL (modules undefined).
- [ ] **Step 3:** Implement the parser as a small hand-written tokenizer plus recursive descent. Don't use one regex.
- [ ] **Step 4: Write `real_dump_test.exs`.** It parses every function and method in `priv/poser_api.json`, after applying overrides. It asserts that the only failures are names in `overrides.skip`.
  - Survey numbers: 474 lines with parameters parse, 588 have no parameters, and about 47 fail or have no signature line (the "36 odd + 11 none" list from planning).
  - For each failure, write the corrected signature into `overrides.signatures`, taken from the docstring text. For example, `GetLightIntensity` → `<FloatType> GetLightIntensity()` and `SetName` → `<NoneType> SetName(<StringType> name)`.
  - Use `skip` only for:
    - `HairType.setPullDown`, a lowercase alias of `SetPullDown`;
    - `ClothSimulatorType.CalculateDyamics`, a misspelt alias kept for backwards compatibility;
    - everything in the `error` class.
- [ ] **Step 5:** Run `mix test`. Expected: all tests pass.
- [ ] **Step 6:** Commit: `jj commit lib test priv/poser_api_overrides.json -m "Docstring signature parser, type mapping, overrides for the real dump"`

### Task 4: The generation model

**Files:**
- Create: `lib/poser/gen/model.ex` (`Poser.Gen.Model`), `test/fixtures/gen_api.json`
- Test: `test/poser/gen/model_test.exs`

**Interfaces:**
- Consumes: Task 3's `Signature` and `Types`.
- Produces `Model.build(dump :: map, overrides :: map, namespace :: module) :: %{modules: [mod], functions: mod, constants: [...], manifest: map}`.
  - `mod = %{module: atom, py_class: String.t(), accepts: [String.t()], constructor: fun | nil, funs: [fun]}`.
  - `fun = %{name: atom, py_name, kind: :method | :function, required: [param], optional: [{atom, default}], returns: type, spec: Macro.t(), doc: String.t(), source: :docstring | :override | :variadic, getter?: boolean}`.
  - Skipped items go in `manifest.skipped` with a reason.

**Rules:**
- **Module name:** `namespace <> "." <> py_class`, for example `Poser.Api.ActorType`. Module-level functions go in `namespace` itself.
- **`accepts`:** the class itself plus every class whose `bases` chain (from the dump) contains it. `SceneObjectType` accepts `ActorType`, `FigureType` and `ParmType`.
- **Naming:**
  - snake_case splits acronym runs (`AlignmentRotationXYZ` → `alignment_rotation_xyz`) and names starting with lowercase.
  - Python parameter names are snake_cased the same way.
  - A required parameter whose name is an Elixir reserved word gets a `_arg` suffix.
- **Exact snake_case collisions within a module:** the PascalCase name wins, and the other goes to `skipped` ("alias of …").
- **Clashes with `Kernel` imports** (name and arity): the module gets `import Kernel, except: [...]` for them. The model records this as `mod.kernel_except`.
- **Skipped methods:**
  - any with a `<FunctionType>` parameter: "callback: Phase 4";
  - every method of a class that subclasses `BaseException`.
- **Constructors:** a class whose `doc` has `<X> poser.X(...)` gets `new/N` with the kind `:function` and py_name `X`.
- **Getters:** `getter?` is true when all of these hold:
  - the function takes no required parameters;
  - its return isn't `NoneType`;
  - its name doesn't start with one of: `Set Add Create Delete Remove Load Save Import Export Render Make Run Process Open Close New Copy Apply Reset Clear Update Drop Spawn Bake Convert Weld Zero Memorize Restore Undo Redo Exec Quit Calculate Select Mark Begin End Show Hide Lock Unlock Register Unregister Swap Reload Recalculate Simulate Install Uninstall Start Stop Play Pause Dialog Wx`;
  - it isn't in `overrides.smoke_skip`.
- **Variadic fallback:** if parsing fails and there is no override, generate `name(handle, args \\ [], opts \\ [])` with the source `:variadic`. After Task 3 the real dump has none, but the fixture keeps one to test the path.

- [ ] **Step 1: Write `test/fixtures/gen_api.json`.** It is a hand-written dump, in the same shape as the real one, covering exactly what `python/fake_poser.py` has:
  - `Scene`, `AppVersion`, `Sleep`, `SleepThenScene`, `NewScene`;
  - `SceneType`: `Frame`, `SetFrame`, `NumFrames`, `Actor`, `Actors`, `Figures`;
  - `SceneObjectType` → `ActorType`: `Name`, `Parameter`, `Parameters`, `Geometry`;
  - `ParmType`: `Value`, `SetValue`;
  - `GeomType`: `VertexPositions`, `SetVertexPositions`;
  - an `ImageType` constructor.
  
  Add one method each with a `<FunctionType>` parameter, an unparseable docstring, a Kernel clash (`Node`), and a lowercase alias. Also add `ActorType.BrokenGetter`, a getter that `fake_poser` raises `RuntimeError` from (Task 8 uses it), and `GeomType.Vertices`, which returns a `VertexType List` (the heavy case). Add both to `fake_poser.py` too. Use Poser's docstring style.
- [ ] **Step 2: Write failing tests** for every rule above against the fixture:
  - `accepts` of `SceneObjectType`;
  - collisions and the `kernel_except` entry;
  - skips with reasons;
  - `new/1` for `ImageType`;
  - `getter?` for `Frame` (true), `SetFrame` (false) and `Actor` (false, since it has a required parameter);
  - the variadic fallback.
- [ ] **Step 3:** Run `mix test test/poser/gen/model_test.exs`. Expected: FAIL.
- [ ] **Step 4:** Implement.
- [ ] **Step 5:** Run `mix test`. Expected: all tests pass.
- [ ] **Step 6:** Commit: `jj commit lib test -m "Generation model: modules, naming, skips, constructors, getters"`

### Task 5: Renderer and `mix poser.gen`

**Files:**
- Create: `lib/poser/gen/render.ex` (`Poser.Gen.Render`), `lib/mix/tasks/poser.gen.ex`
- Test: `test/poser/gen/render_test.exs`, `test/poser/gen/generated_fake_test.exs`

**Interfaces:**
- Consumes: `Model.build/3`, `Poser.Call` (Task 2).
- Produces:
  - `Render.files(model) :: [{relative_path, iodata}]`;
  - `mix poser.gen [DUMP] [--out DIR] [--namespace MOD] [--check]`:
    - defaults: `priv/poser_api.json`, `lib`, `Poser.Api`;
    - writes `lib/poser/api.ex`, `lib/poser/api/<snake_class>.ex`, `lib/poser/const.ex` and `priv/poser_api_manifest.json`;
    - `--check` writes nothing and exits 1 if any file would change.

**Generated function shape** (the spec and doc come from the model):

```elixir
@doc ~S"""
Python: `ActorType.Parameter`

<docstring>
"""
@spec parameter(Poser.Handle.t(), String.t(), keyword()) :: {:ok, Poser.Handle.t()} | {:error, Poser.Error.t()}
def parameter(%Poser.Handle{class: c} = handle, parm_name, opts \\ []) when c in @accepts,
  do: Poser.Call.method(handle, "Parameter", [parm_name], [], opts)
```

- Each module has a `@moduledoc` naming the Python class, the `api_hash` and the Poser version.
- Each module defines `@accepts` and `@type t :: Poser.Handle.t()`.
- **Docstring escaping:** put the doc in `~S"""`. Replace `"""` inside it with `\"\"\"`. Interpolation is already inert under `~S`.

- [ ] **Step 1: Write failing tests.**
  - `render_test.exs`:
    - output is stable across two runs;
    - a docstring containing `"""` and `#{x}` renders and compiles;
    - the variadic shape;
    - a constructor renders as `new/N` and calls `Poser.Call.function`.
  - `generated_fake_test.exs`:
    1. Generate the fixture into a temp dir with the namespace `PoserTest.GenApi`. Do this in `test/support/gen_fixture.ex` (`PoserTest.GenFixture.ensure_compiled/0`), which compiles only once per test run so Task 8 can reuse it without module-redefinition warnings.
    2. Compile every file with `Code.compile_file/1`, using `Code.with_diagnostics` to assert no warnings.
    3. Against the standalone server (`start_standalone`/`start_client`):
       - `PoserTest.GenApi.scene(server: c)` gives a `SceneType` handle;
       - `PoserTest.GenApi.SceneType.set_frame(scene, 3, server: c)` and then `frame/2` give `3`;
       - `ActorType.parameter(actor, "xTran", server: c)`, then `ParmType.value/2`, give a float;
       - `GeomType.vertex_positions/2` round-trips a `%Poser.NDArray{}`, skipped unless the standalone Python has numpy;
       - calling a `SceneType` function with an `ActorType` handle raises `FunctionClauseError`;
       - an inherited `SceneObjectType.name/2` accepts an `ActorType` handle.
- [ ] **Step 2:** Run `mix test test/poser/gen`. Expected: FAIL.
- [ ] **Step 3:** Implement.
  - The task calls `Mix.Task.run("app.config")`, not `app.start`, because generating needs no running client.
  - Write the manifest JSON with sorted keys so diffs stay readable.
- [ ] **Step 4:** Run `mix test`. Expected: all tests pass.
- [ ] **Step 5:** Commit: `jj commit lib test -m "Renderer and mix poser.gen"`

### Task 6: Constants

**Files:**
- Modify: `lib/poser/gen/model.ex`, `lib/poser/gen/render.ex`, `priv/poser_api_overrides.json` (`constant_groups`)
- Test: `test/poser/gen/constants_test.exs`

**Interfaces:**
- Produces `Poser.Const` (generated) with:
  - `fetch(String.t()) :: {:ok, integer | String.t()} | :error`, keyed by the Python name;
  - `all() :: %{String.t() => integer | String.t()}`;
  - one function per group: `parm_code(atom) :: integer | String.t()`, which raises `FunctionClauseError` for an unknown key;
  - `<group>_keys() :: [atom]`.

**Grouping:**
- Strip the leading `k` from each constant name.
- Match the longest prefix from `constant_groups`. The real dump starts with these groups, longest first:
  - `NodeTypeCodeCycles`, `PreviewRenderEngineTypeCode`, `TextureCompressorCode`, `RayAcceleratorCode`, `RenderEngineCode`, `PixelFilterCode`, `ValueOpTypeCode`;
  - `NodeInputCode`, `NodeTypeCode`, `ClothParmCode`, `ParmCode`, `ExOptCode`, `ImOptCode`, `MetadataProperty`;
  - `CmdCode`, `DisplayCode`, `EventCode`, `LightCode`, `OutlineCode`, `LanguageCode`, `ZoneTypeCode`, `MirrorType`, `SkinType`, `Gimbal`, `CB`, `TIFF_`, `Store`.
- **Group function name:** snake_case of the group, with trailing underscores trimmed (`parm_code`, `tiff`).
- **Key:** snake_case of the remainder, with `_` trimmed (`kParmCodeXSCALE` → `:xscale`).
- Constants with no group are available only through `fetch/1`.
- Two constants that would get the same key within a group fail generation, with both names in the error.

- [ ] **Step 1: Write failing tests** against the fixture, after adding three constants there:
  - `kParmCodeXSCALE` → `parm_code(:xscale)`;
  - longest-prefix matching (`kNodeTypeCodeCyclesX` goes to `node_type_code_cycles`);
  - `fetch` for a constant with no group;
  - the key-collision error.
- [ ] **Step 2:** Run `mix test test/poser/gen/constants_test.exs`. Expected: FAIL.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** Run `mix test`. Expected: all tests pass.
- [ ] **Step 5:** Commit: `jj commit lib test priv/poser_api_overrides.json -m "Generate Poser.Const with grouped constants"`

### Task 7: Generate from the real dump and commit

**Files:**
- Create (generated): `lib/poser/api.ex`, `lib/poser/api/*.ex`, `lib/poser/const.ex`, `priv/poser_api_manifest.json`
- Modify: `scripts/summarize_api.exs` (print the manifest's coverage section when the manifest exists)
- Test: `test/poser/gen/real_generated_test.exs`

- [ ] **Step 1: Write failing tests.**
  - `mix poser.gen --check` exits 0, so the committed output is up to date.
  - Manifest summary:
    - generated plus skipped equals 1,109;
    - `source: :variadic` count is 0;
    - every skip has a reason;
    - unknown types are listed.
  - Spot checks:
    - `function_exported?(Poser.Api, :scene, 1)`;
    - `Poser.Api.ParmType.set_value/3`;
    - `Poser.Api.SceneType.actors/2`;
    - `Poser.Const.parm_code(:xscale)` is a binary.
- [ ] **Step 2:** Run `mix test test/poser/gen/real_generated_test.exs`. Expected: FAIL.
- [ ] **Step 3:** Run `mix poser.gen`, then `mix compile --warnings-as-errors`. Expected: it compiles cleanly. Fix the model or the overrides, never the generated files.
- [ ] **Step 4:** Run `mix test`. Expected: all tests pass. Also record the full and incremental compile times in the ledger.
- [ ] **Step 5:** Commit: `jj commit lib priv scripts test -m "Generated Poser.Api modules and constants from the Poser 14 dump"`

### Task 8: `mix poser.smoke`

**Files:**
- Create: `lib/poser/smoke.ex` (`Poser.Smoke`), `lib/mix/tasks/poser.smoke.ex`
- Test: `test/poser/smoke_test.exs`; add a smoke test to `test/live/live_poser_test.exs`

**Interfaces:**
- Consumes: the manifest (the `getter?` flag and the module and function per class) and the generated modules.
- Produces:
  - `Poser.Smoke.run(manifest, opts) :: report`. Opts: `server`, `per_class` (default 3), `timeout` (default 30_000), `include_heavy` (default false).
  - The report has one entry per getter: `%{module, function, py_name, calls, outcomes: %{ok: n, python: %{class => n}, timeout: n, stale_handle: n, bad_request: n, other: n}, sample: inspect(value, limit: 5)}`.
  - `mix poser.smoke [--per-class N] [--include-heavy] [--out PATH]`: the default output is `tmp/poser_smoke.json`. The task prints a summary and exits 0. Failures are data, not errors.

**Walk:**
1. Start from every module-level getter, then queue the handles they return.
2. Take the next handle. If fewer than `per_class` handles of its class have been explored, call every getter of that module on it.
3. Collect the handles in each result (`Codec.handles_in/1`). Enqueue those whose class still has room, and release the rest at once with `Poser.Client.release/2`.
4. Repeat until the queue is empty, then release everything.

**Heavy getters:** a getter whose return type is a list of `VertexType`, `TexVertexType`, `PolygonType` or `TexPolygonType` is skipped unless `include_heavy` is set. The report gives the reason as "one handle per element; would flush the 10,000-handle table".

- [ ] **Step 1: Write failing tests** (`smoke_test.exs`), using the fixture-generated namespace and the standalone server:
  - the report lists `SceneType.frame` as `ok`;
  - a fake getter that raises shows up under `python`;
  - after the run, `Client.stats` shows `handles == 0`;
  - with `per_class: 1`, each class is explored at most once;
  - a heavy getter is skipped with the reason above.
- [ ] **Step 2:** Run `mix test test/poser/smoke_test.exs`. Expected: FAIL.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** Add the live test. It runs `Poser.Smoke.run` with `per_class: 2` and asserts:
  - no outcome is `bad_request`, `stale_handle` or `other`;
  - at least 300 getters returned `ok`.
  
  Python errors are allowed, because many getters raise on an actor of the wrong kind.
- [ ] **Step 5:** Run `mix test`. Expected: all tests pass, with the live tests excluded.
- [ ] **Step 6:** Commit: `jj commit lib test -m "mix poser.smoke: walk the scene through every generated getter"`

### Task 9: Live check, docs and findings

**Files:**
- Modify: `guides/setup.md` (a "Generated API" section: `mix poser.gen`, `--check`, `mix poser.smoke`, and regenerating when `api_hash` changes), `README.md` (one example using `Poser.Api`)
- Create: `plans/phase2-findings.md`

- [ ] **Step 1: Live check (user).**
  1. Run `scripts/deploy_addon.sh` and restart Poser, because Task 1 changed the add-on.
  2. Load the 9-figure scene.
  3. Run `mix test --only poser`.
  4. Run `mix poser.smoke`.
  
  Expected: the live tests PASS, and the smoke summary shows no `bad_request`, `stale_handle` or `other` outcomes.
- [ ] **Step 2:** Write `plans/phase2-findings.md`. Include:
  - coverage numbers from the manifest;
  - the smoke summary: counts by outcome, the most common Python error classes, and the slowest getters;
  - every new override or `smoke_skip` the live run needed.
  
  Encoding failures found live are fixed with a test first, before writing the findings.
- [ ] **Step 3:** Run `mix test` and the Python tests. Expected: PASS.
- [ ] **Step 4:** Commit with `jj commit guides README.md plans/phase2-findings.md -m "Phase 2 findings and generated-API guide"`, create the bookmark with `jj bookmark create phase-2 -r @-`, then run `jj git push --bookmark phase-2`.

---

## Not in this phase

- **Callbacks** (14 flagged methods, including `SetUpdateCallback`, `RegisterEventCallback` and `ImExporterType.Export`'s selection callback): Phase 4. They are generated as skips.
- **Phase 3 work:** per-class structs, `!` variants, `with_scope`, `Poser.batch` helpers and the idiomatic modules.
- **ndarray-based bulk geometry access** as an alternative to per-vertex handles: Phase 3, informed by the heavy-getter numbers from the smoke run.
- **Phase 1 deferred minors:** they stay deferred unless the smoke run hits one. `:nan` read back as a string is the most likely.
