# Generated API

`Poser.Api` and its `Poser.Api.*` modules have one Elixir function per
PoserPython function and method, generated from what Poser 14 reports about
itself. They work on `%Poser.Handle{}` values, the bridge's references to
live Python objects. Use them for anything the idiomatic modules don't wrap.

## From a struct to a handle

`handle/2` on `Poser.Figure`, `Poser.Actor` and `Poser.Parameter` resolves the
struct and returns its handle:

```elixir
{:ok, h} = Poser.Parameter.handle(bend)
Poser.Api.ParmType.internal_name(h)
#=> {:ok, "bend"}
Poser.Api.ParmType.next_key_frame(h)
#=> {:ok, 4}
Poser.Client.release([h])
```

The handle belongs to you. Release it when you're done: the add-on keeps
every handle it hands out until it is released or the connection drops.
Releasing only drops the bridge's reference; the object stays in Poser.

A handle goes stale when the connection it came from closes, or when Poser
creates or deletes a scene, and is then refused with `:stale_handle`. Keep structs, not handles, in anything that
outlives a reconnect.

## Calling conventions

- Function names are PoserPython's in snake case: `SetValue` is
  `Poser.Api.ParmType.set_value/3`.
- Required Python arguments are positional; optional ones are keyword
  options, e.g. `Poser.Api.ParmType.set_value(h, 15.0, do_update: 1)`.
- `:server` and `:timeout` go to `Poser.Client`.
- Methods whose Python signature couldn't be discovered take a plain
  argument list.
- Constants are in `Poser.Const`, e.g. `Poser.Const.parm_code(:xrot)`.

Unlike the idiomatic API, these calls run at Poser's current frame and don't
batch: each is one request. `Poser.Batch.call/5` runs a PoserPython method by
name on a struct inside a batch, which keeps `frame:` and shared lookups.
`Poser.Client.invoke/4` calls any method by name on a handle, generated or
not.

## Regenerating

`lib/poser/api/` holds one module per PoserPython class, `lib/poser/api.ex`
the module-level functions and `lib/poser/const.ex` the constants. All three
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
