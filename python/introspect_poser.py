"""Dump the PoserPython API to poser_api.json.

Run inside Poser with File > Run Python Script, ideally with a scene that has
a figure, a few materials and lights loaded so live discovery finds more
classes. Writes %APPDATA%\\PoserBridge\\poser_api.json and prints a summary.

Classes are found two ways:
  module  type objects exposed as attributes of the poser module
  live    type() of objects reached from poser.Scene() through SAFE_GETTERS,
          which are zero-argument (or index-argument) accessors with no side
          effects. A getter an object doesn't have is simply skipped; one
          that raises is recorded under discovery_errors.
"""

import hashlib
import inspect
import json
import os
import sys
import time

import poser

# (method name, args). Lists returned by a getter are sampled, not walked fully.
SAFE_GETTERS = [
    ("CurrentActor", ()), ("CurrentFigure", ()), ("CurrentCamera", ()),
    ("CurrentLight", ()), ("CurrentMaterial", ()),
    ("Figures", ()), ("Actors", ()), ("Cameras", ()), ("Lights", ()),
    ("Materials", ()), ("Parameters", ()), ("Children", ()), ("Parent", ()),
    ("ShaderTree", ()), ("Nodes", ()), ("Inputs", ()),
    ("Geometry", ()), ("Vertex", (0,)), ("Polygon", (0,)), ("TexVertex", (0,)),
    ("TexPolygon", (0,)),
    ("CurrentFireFlyOptions", ()), ("CurrentSuperFlyOptions", ()),
    ("MovieMaker", ()), ("ImExporter", ()),
    ("Layers", ()), ("CurrentLayer", ()),
]
LIST_SAMPLE = 2       # elements taken from each list result
PER_TYPE = 3          # instances explored per class
MAX_DEPTH = 7


def describe_callable(name, fn):
    doc = getattr(fn, "__doc__", None)
    doc = doc if isinstance(doc, str) else None
    sig, source = None, None
    try:
        sig, source = str(inspect.signature(fn)), "inspect"
    except (TypeError, ValueError):
        text = getattr(fn, "__text_signature__", None)
        if text:
            sig, source = text, "text_signature"
    return {
        "name": name,
        "doc": doc,
        "signature": sig,
        "signature_source": source,
        "callback": bool(doc and "callback" in doc.lower()),
    }


def describe_class(cls, via):
    methods, attributes, errors = [], [], []
    for name in sorted(dir(cls)):
        if name.startswith("__"):
            continue
        try:
            attr = getattr(cls, name)
        except Exception as e:
            errors.append({"name": name, "error": repr(e)})
            continue
        if callable(attr):
            methods.append(describe_callable(name, attr))
        else:
            attributes.append({"name": name, "repr": _short_repr(attr)})
    return {
        "name": cls.__name__,
        "module": getattr(cls, "__module__", None),
        "bases": [b.__name__ for b in cls.__mro__[1:] if b is not object],
        "doc": cls.__doc__ if isinstance(cls.__doc__, str) else None,
        "via": [via],
        "methods": methods,
        "attributes": attributes,
        "errors": errors,
    }


def scan_module():
    functions, classes, constants, other = [], {}, {}, []
    for name in sorted(dir(poser)):
        if name.startswith("__"):
            continue
        obj = getattr(poser, name)
        if isinstance(obj, type):
            classes[obj.__name__] = describe_class(obj, "module:" + name)
        elif callable(obj):
            functions.append(describe_callable(name, obj))
        elif isinstance(obj, (int, float, str)) and not isinstance(obj, bool):
            constants[name] = obj
        else:
            other.append({"name": name, "type": type(obj).__name__, "repr": _short_repr(obj)})
    return functions, classes, constants, other


def discover_live(classes, errors):
    seen = {}
    stack = [("poser.Scene()", poser.Scene(), 0)]
    while stack:
        path, obj, depth = stack.pop()
        cls = type(obj)
        if seen.get(cls, 0) >= PER_TYPE:
            continue
        seen[cls] = seen.get(cls, 0) + 1
        entry = classes.get(cls.__name__)
        if entry is None:
            classes[cls.__name__] = describe_class(cls, "live:" + path)
        elif seen[cls] == 1:
            entry["via"].append("live:" + path)
        if depth >= MAX_DEPTH:
            continue
        for name, args in SAFE_GETTERS:
            fn = getattr(obj, name, None)
            if not callable(fn):
                continue
            step = "%s.%s(%s)" % (path, name, ", ".join(map(repr, args)))
            try:
                result = fn(*args)
            except Exception as e:
                errors.append({"path": step, "error": "%s: %s" % (type(e).__name__, e)})
                continue
            is_seq = isinstance(result, (list, tuple))
            items = result[:LIST_SAMPLE] if is_seq else [result]
            for i, item in enumerate(items):
                if _is_poser_object(item):
                    sub = "%s[%d]" % (step, i) if is_seq else step
                    stack.append((sub, item, depth + 1))


def _is_poser_object(v):
    return v is not None and not isinstance(v, (int, float, str, bytes, list, tuple, dict))


def _short_repr(v):
    try:
        r = repr(v)
    except Exception:
        r = "<unrepresentable>"
    return r if len(r) <= 200 else r[:200] + "..."


def _poser_version():
    for name in ("Version", "AppVersion"):
        fn = getattr(poser, name, None)
        if callable(fn):
            try:
                return str(fn())
            except Exception:
                pass
    return "unknown"


def summarize(classes, functions, constants):
    methods = [m for c in classes.values() for m in c["methods"]]
    with_sig = [m for m in methods + functions if m["signature"]]
    return {
        "classes": len(classes),
        "classes_live_only": sum(1 for c in classes.values()
                                 if not any(v.startswith("module:") for v in c["via"])),
        "methods": len(methods),
        "functions": len(functions),
        "with_signature": len(with_sig),
        "callback_flagged": sum(1 for m in methods + functions if m["callback"]),
        "constants": len(constants),
    }


def main(path=None):
    functions, classes, constants, other = scan_module()
    errors = []
    discover_live(classes, errors)
    body = {
        "functions": functions,
        "classes": classes,
        "constants": constants,
        "other_module_attributes": other,
    }
    api_hash = hashlib.sha256(json.dumps(body, sort_keys=True).encode("utf-8")).hexdigest()
    summary = summarize(classes, functions, constants)
    data = dict(body, meta={
        "poser_version": _poser_version(),
        "python_version": sys.version,
        "generated_at": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
        "api_hash": api_hash,
        "summary": summary,
        "discovery_errors": errors,
    })
    path = path or os.path.join(os.environ.get("APPDATA", "."), "PoserBridge", "poser_api.json")
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as f:
        json.dump(data, f, indent=1, sort_keys=True)
    print("poser_api.json written to %s" % path)
    print(json.dumps(summary, indent=1))
    print("%d discovery errors" % len(errors))
    return summary


if __name__ != "introspect_poser":  # run when executed, not when imported
    main()
