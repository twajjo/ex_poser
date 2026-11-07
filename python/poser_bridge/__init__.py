"""Poser Bridge add-on: serves the PoserPython API to Elixir over a socket.

Poser's poserStartup.py imports this package from Runtime\\Python\\addons.
Outside Poser (standalone server, tests) the add-on is not registered, so the
Poser-free modules (codec, server, net) can still be imported.
"""

try:
    import poser
except ImportError:
    poser = None

if poser is not None:
    from . import addon  # noqa: F401  (registers the add-on with Poser)
