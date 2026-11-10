"""Executes protocol requests against the poser module. Runs on the main thread.

Never imports poser or wx: the module is passed in. `run` never raises; every
outcome is a reply term (r or e) ready for the codec.
"""

import importlib
import traceback

from .codec import atom
from .handles import BadRequest, StaleHandle
from .policy import NotAllowed

A_C, A_I, A_G, A_B, A_R_OP, A_S, A_X = (atom(t) for t in "CIGBRSX")
A_R, A_E = atom("r"), atom("e")
A_PYTHON = atom("python")
A_STALE = atom("stale_handle")
A_NOT_ALLOWED = atom("not_allowed")
A_BAD_REQUEST = atom("bad_request")
A_BATCH_FAILED = atom("batch_failed")


class Dispatcher(object):
    def __init__(self, poser, handles, policy):
        self.poser, self.handles, self.policy = poser, handles, policy

    def stats(self):
        return {"handles": len(self.handles), "generation": self.handles.current_generation()}

    def run(self, msg):
        mid = msg[1] if type(msg) is tuple and len(msg) > 1 else 0
        try:
            tag = msg[0]
            if tag == A_B:
                return self._batch(msg)
            if tag == A_R_OP:
                _expect(msg, 3, list)
                return (A_R, mid, self.handles.release(msg[2]))
            if tag == A_S:
                _expect(msg, 2)
                return (A_R, mid, self.stats())
            return (A_R, mid, self.handles.wrap(self._exec(msg, None)))
        except Exception as e:
            return (A_E, mid, _reason(e, msg))

    def _batch(self, msg):
        _expect(msg, 3, list)
        mid, ops = msg[1], msg[2]
        raw = []
        for i, op in enumerate(ops):
            try:
                if type(op) is not tuple or not op:
                    raise BadRequest("batch op must be a tuple")
                raw.append(self._exec((op[0], None) + op[1:], raw))
            except Exception as e:
                partial = [self.handles.wrap(v) for v in raw]
                return (A_E, mid, (A_BATCH_FAILED, i, _reason(e, op), partial))
        return (A_R, mid, [self.handles.wrap(v) for v in raw])

    def _exec(self, msg, refs):
        """Run one C/I/G/X request (id at index 1 is ignored) and return the raw value."""
        tag = msg[0]
        if tag == A_C:
            _expect(msg, 5, str, list, dict)
            _, _, name, args, kwargs = msg
            self.policy.check_call(name)
            fn = getattr(self.poser, name)
            return fn(*self._args(args, refs), **self._args(kwargs, refs))
        if tag == A_I:
            _expect(msg, 6, None, str, list, dict)
            _, _, handle, method, args, kwargs = msg
            obj = self._target(handle, refs)
            self.policy.check_method(obj, method)
            fn = getattr(obj, method)
            return fn(*self._args(args, refs), **self._args(kwargs, refs))
        if tag == A_G:
            _expect(msg, 4, None, str)
            _, _, handle, attr = msg
            obj = self._target(handle, refs)
            self.policy.check_attr(obj, attr)
            return getattr(obj, attr)
        if tag == A_X:
            _expect(msg, 5, str, str, list)
            _, _, module, function, args = msg
            self.policy.check_raw(module, function)
            return raw_call(module, function, self._args(args, refs))
        raise BadRequest("unknown op %r" % (tag,))

    def _target(self, handle, refs):
        if type(handle) is not tuple:
            raise BadRequest("target must be a handle, got %r" % (handle,))
        return self.handles.resolve(handle, refs)

    def _args(self, value, refs):
        return self.handles.resolve(value, refs)


def _expect(msg, n, *types):
    """Check arity, then the types of the fields after the id (None = any)."""
    if type(msg) is not tuple or len(msg) != n:
        raise BadRequest("expected %d fields" % n)
    for v, t in zip(msg[2:], types):
        if t is not None and not isinstance(v, t):
            raise BadRequest("expected %s, got %r" % (t.__name__, v))


def _reason(e, msg):
    if isinstance(e, StaleHandle):
        return (A_STALE, e.id, e.generation)
    if isinstance(e, NotAllowed):
        return (A_NOT_ALLOWED, atom(e.kind), e.name)
    if isinstance(e, BadRequest):
        return (A_BAD_REQUEST, "%s: %r" % (e, msg))
    tb = traceback.format_exception(type(e), e, e.__traceback__)
    return (A_PYTHON, type(e).__name__, str(e), tb)


def raw_call(module, function, args):
    """Dev mode only: call module.function(*args) (dotted function names allowed)."""
    target = importlib.import_module(module)
    for part in function.split("."):
        target = getattr(target, part)
    return target(*args)
