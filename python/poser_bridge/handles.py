"""Handle table: Poser objects live here; Elixir holds {:poser_obj, ...} tuples.

Only touched on the main thread. Never imports poser or wx.
"""

import collections
import itertools
import numbers

from .erlterms import Atom

POSER_OBJ = Atom(b"poser_obj")
NDARRAY = Atom(b"ndarray")
RESULT = Atom(b"result")

MAX_DEPTH = 100
_PLAIN = (type(None), bool, str, bytes, Atom)


class StaleHandle(Exception):
    def __init__(self, hid, generation):
        Exception.__init__(self, "stale handle %r (generation %r)" % (hid, generation))
        self.id, self.generation = hid, generation


class BadRequest(Exception):
    pass


class HandleTable(object):
    def __init__(self, current_generation, cap=10000):
        self.current_generation = current_generation
        self.cap = cap
        self._objs = collections.OrderedDict()
        self._ids = itertools.count(1)

    def __len__(self):
        return len(self._objs)

    def wrap(self, value, depth=0):
        if depth > MAX_DEPTH:
            raise ValueError("value nested too deeply")
        if isinstance(value, _PLAIN) or isinstance(value, numbers.Number):
            return value
        t = type(value)
        if t is list or t is tuple:
            return t(self.wrap(x, depth + 1) for x in value)
        if t is dict:
            return dict((k, self.wrap(x, depth + 1)) for k, x in value.items())
        if t.__name__ == "ndarray" and all(hasattr(value, a) for a in ("dtype", "shape", "tobytes")):
            return (NDARRAY, value.dtype.str, tuple(value.shape), value.tobytes())
        return self._store(value)

    def resolve(self, term, refs=None):
        t = type(term)
        if t is tuple:
            if len(term) == 5 and term[0] == POSER_OBJ:
                return self._get(term[2], term[3])
            if len(term) == 2 and term[0] == RESULT:
                n = term[1]
                if refs is None or type(n) is not int or not 0 <= n < len(refs):
                    raise BadRequest("bad result reference %r" % (n,))
                return refs[n]
            return tuple(self.resolve(x, refs) for x in term)
        if t is list:
            return [self.resolve(x, refs) for x in term]
        if t is dict:
            return dict((k, self.resolve(x, refs)) for k, x in term.items())
        return term

    def release(self, handle_terms):
        n = 0
        for h in handle_terms:
            if type(h) is tuple and len(h) == 5 and h[0] == POSER_OBJ:
                if self._objs.pop(h[2], None) is not None:
                    n += 1
        return n

    def clear(self):
        self._objs.clear()

    def _store(self, obj):
        hid = next(self._ids)
        self._objs[hid] = obj
        while len(self._objs) > self.cap:
            self._objs.popitem(last=False)
        return (POSER_OBJ, type(obj).__name__, hid, self.current_generation(), _label(obj))

    def _get(self, hid, generation):
        if generation != self.current_generation() or hid not in self._objs:
            raise StaleHandle(hid, generation)
        self._objs.move_to_end(hid)
        return self._objs[hid]


def _label(obj):
    fn = getattr(obj, "Name", None)
    if not callable(fn):
        return None
    try:
        name = fn()
    except Exception:
        return None
    return name if isinstance(name, str) else None
