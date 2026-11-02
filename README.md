# Poserx

An Elixir client for Poser 14's Python API. A small add-on inside Poser serves
the `poser` module over a socket (ErlPort's term format); `Poser.Client` calls
any `poser` function or object method and gets Poser objects back as handles.

Every PoserPython function and method also has a generated Elixir function:

```elixir
{:ok, _} = Poser.Client.start_link()
{:ok, scene} = Poser.Api.scene()
{:ok, [figure | _]} = Poser.Api.SceneType.figures(scene)
{:ok, actor} = Poser.Api.FigureType.actor(figure, "hip")
{:ok, parm} = Poser.Api.ActorType.parameter(actor, "xRotate")
{:ok, nil} = Poser.Api.ParmType.set_value(parm, 15.0, do_update: 1)
```

Optional Python arguments are keyword options; `server:` and `timeout:` go
to the client. Constants live in `Poser.Const`, e.g. `Poser.Const.parm_code(:xrot)`.

- [Setup](guides/setup.md): deploying the add-on, the WSL firewall rule, tests
- [Limitations](guides/limitations.md): what can't be covered, and workarounds
