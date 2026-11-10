# Generated API

`ExPoser.Api` and its `ExPoser.Api.*` modules have one Elixir function per
PoserPython function and method, generated from what Poser 14 reports about
itself. They work on `%ExPoser.Handle{}` values, the bridge's references to
live Python objects. Use them for anything the idiomatic modules don't wrap.

## From a struct to a handle

`handle/2` on `ExPoser.Figure`, `ExPoser.Actor` and `ExPoser.Parameter` resolves the
struct and returns its handle:

```elixir
{:ok, h} = ExPoser.Parameter.handle(bend)
ExPoser.Api.ParmType.internal_name(h)
#=> {:ok, "yrot"}
ExPoser.Api.ParmType.next_key_frame(h)
#=> {:ok, 4}
ExPoser.Client.release([h])
```

The handle belongs to you. Release it when you're done: the add-on keeps
every handle it hands out until it is released or the connection drops.
Releasing only drops the bridge's reference; the object stays in Poser.

A handle goes stale when the connection it came from closes, or when Poser
creates or deletes a scene, and is then refused with `:stale_handle`. Keep structs, not handles, in anything that
outlives a reconnect.

## Calling conventions

- Function names are PoserPython's in snake case: `SetValue` is
  `ExPoser.Api.ParmType.set_value/3`.
- Required Python arguments are positional; optional ones are keyword
  options, e.g. `ExPoser.Api.ParmType.set_value(h, 15.0, do_update: 1)`.
- `:server` and `:timeout` go to `ExPoser.Client`.
- Methods whose Python signature couldn't be discovered take a plain
  argument list.
- Constants are in `ExPoser.Const`, e.g. `ExPoser.Const.parm_code(:xrot)`.

Unlike the idiomatic API, these calls run at Poser's current frame and don't
batch: each is one request. `ExPoser.Batch.call/5` runs a PoserPython method by
name on a struct inside a batch, which keeps `frame:` and shared lookups.
`ExPoser.Client.invoke/4` calls any method by name on a handle, generated or
not.

## Regenerating

`lib/ex_poser/api/` holds one module per PoserPython class, `lib/ex_poser/api.ex`
the module-level functions and `lib/ex_poser/const.ex` the constants. All three
are generated from `priv/poser_api.json` and committed. Don't edit them: put
corrections in `priv/poser_api_overrides.json` and regenerate.

Regenerate:

```
mix poser.gen
```

Check that the committed files are up to date (`mix test` also does this):

```
mix poser.gen --check
```

`priv/poser_api_manifest.json` records what was generated, what was skipped
and why. To print a summary:

```
elixir scripts/summarize_api.exs
```

When Poser is updated, its `api_hash` changes: run the introspection script
again (see `plans/phase0-findings.md`), copy the new `poser_api.json` into
`priv/`, regenerate and review the diff.

Smoke test: with Poser running and a scene loaded, call every generated
getter on up to 3 objects of each class. It prints a summary and writes
`tmp/poser_smoke.json`:

```
mix poser.smoke
```

Getters that return one handle per vertex or polygon are skipped unless you
add `--include-heavy`.
