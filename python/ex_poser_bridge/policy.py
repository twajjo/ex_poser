"""Dev and strict access policy. Never imports poser or wx.

dev:    anything public (no leading underscore); raw X calls allowed.
strict: only what priv/poser_api.json lists; raw X calls refused.
"""

import json
import re


class NotAllowed(Exception):
    def __init__(self, kind, name):
        Exception.__init__(self, "%s %s not allowed" % (kind, name))
        self.kind, self.name = kind, name


class Policy(object):
    def __init__(self, mode, api_hash=None, functions=None, methods=None, attributes=None):
        self.mode, self.api_hash = mode, api_hash
        self._functions = functions or frozenset()
        self._methods = methods or {}
        self._attributes = attributes or {}

    @classmethod
    def dev(cls):
        return cls("dev")

    @classmethod
    def load(cls, mode, api_path):
        if mode not in ("dev", "strict"):
            raise ValueError("unknown mode %r" % (mode,))
        try:
            with open(api_path, encoding="utf-8") as f:
                api = json.load(f)
        except (OSError, ValueError):  # missing, unreadable or corrupt
            if mode == "strict":
                raise
            return cls("dev")
        api_hash = (api.get("meta") or {}).get("api_hash")
        if mode == "dev":
            return cls("dev", api_hash)
        classes = api["classes"]
        constructors = [c for c, v in classes.items()
                        if re.search(r"\bposer\.%s\(" % re.escape(c), v.get("doc") or "")]
        return cls("strict", api_hash,
                   frozenset([f["name"] for f in api["functions"]] + constructors),
                   dict((c, _collect(classes, c, "methods")) for c in classes),
                   dict((c, _collect(classes, c, "attributes")) for c in classes))

    def check_call(self, name):
        self._check("call", name, name in self._functions)

    def check_method(self, obj, name):
        allowed = self._methods.get(type(obj).__name__, ())
        self._check("invoke", name, name in allowed)

    def check_attr(self, obj, name):
        allowed = self._attributes.get(type(obj).__name__, ())
        self._check("get_attr", name, name in allowed)

    def check_raw(self, module, function):
        if self.mode != "dev":
            raise NotAllowed("raw", "%s.%s" % (module, function))

    def _check(self, kind, name, listed):
        if not isinstance(name, str) or name.startswith("_"):
            raise NotAllowed(kind, name)
        if self.mode == "strict" and not listed:
            raise NotAllowed(kind, name)


def _collect(classes, name, key, seen=None):
    """Names under `key` for class `name` and every class reachable through bases."""
    seen = seen if seen is not None else set()
    if name in seen or name not in classes:
        return frozenset()
    seen.add(name)
    c = classes[name]
    names = set(x["name"] if isinstance(x, dict) else x for x in c.get(key, ()))
    for base in c.get("bases", ()):
        names |= _collect(classes, base, key, seen)
    return frozenset(names)
