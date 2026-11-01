# Poserx

An Elixir client for Poser 14's Python API. A small add-on inside Poser serves
the `poser` module over a socket (ErlPort's term format); `Poser.Client` calls
any `poser` function or object method and gets Poser objects back as handles.

- [Setup](guides/setup.md): deploying the add-on, the WSL firewall rule, tests
- [Limitations](guides/limitations.md): what can't be covered, and workarounds
