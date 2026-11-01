"""Framing and term conversion for the bridge wire protocol.

Frames are a 4-byte big-endian length followed by an Erlang external term
(the Elixir side uses :gen_tcp with packet: 4).

Conventions:
  outbound  str -> binary, None -> nil, bool -> true/false, dict -> map,
            nan / +inf / -inf -> nan / infinity / neg_infinity atoms,
            non-plain objects -> {:obj, class_name, repr}
  inbound   binary -> str, {:bytes, bin} -> bytes, nil -> None
"""

import math
import numbers
import struct

from . import erlterms
from .erlterms import Atom

MAX_FRAME = 64 * 1024 * 1024

_len = struct.Struct(">I")
NIL = Atom(b"nil")
OBJ = Atom(b"obj")
BYTES = Atom(b"bytes")
NAN = Atom(b"nan")
INFINITY = Atom(b"infinity")
NEG_INFINITY = Atom(b"neg_infinity")


def atom(name):
    return Atom(name.encode("utf-8"))


def to_wire(v):
    if v is None:
        return NIL
    t = type(v)
    if t is float:
        return _float(v)
    if t is Atom or t is bool or t is int or t is bytes:
        return v
    if t is str:
        return v.encode("utf-8")
    if t is tuple:
        return tuple(to_wire(x) for x in v)
    if t is list or t is erlterms.List:
        return [to_wire(x) for x in v]
    if t is dict or t is erlterms.Map:
        return dict((to_wire(k), to_wire(x)) for k, x in v.items())
    # numpy scalars and other registered number types
    if isinstance(v, numbers.Integral):
        return int(v)
    if isinstance(v, numbers.Real):
        return _float(float(v))
    return (OBJ, type(v).__name__.encode("utf-8"), _safe_repr(v).encode("utf-8"))


def _float(v):
    # Erlang has no NaN or infinity; binary_to_term rejects them.
    if math.isnan(v):
        return NAN
    if math.isinf(v):
        return INFINITY if v > 0 else NEG_INFINITY
    return v


def from_wire(v):
    t = type(v)
    if t is Atom:
        return None if v == NIL else v
    if t is bytes:
        return v.decode("utf-8")
    if t is tuple:
        if len(v) == 2 and v[0] == BYTES and type(v[1]) is bytes:
            return v[1]
        return tuple(from_wire(x) for x in v)
    if t is erlterms.List:
        return [from_wire(x) for x in v]
    if t is erlterms.Map:
        return dict((from_wire(k), from_wire(x)) for k, x in v.items())
    return v


def encode(term):
    return erlterms.encode(to_wire(term))


def decode(data):
    term, tail = erlterms.decode(data)
    if tail:
        raise ValueError("trailing data after term: %d bytes" % len(tail))
    return from_wire(term)


def _recv_exact(sock, n):
    buf = bytearray()
    while len(buf) < n:
        chunk = sock.recv(n - len(buf))
        if not chunk:
            raise EOFError("connection closed")
        buf.extend(chunk)
    return bytes(buf)


def read_frame(sock):
    (n,) = _len.unpack(_recv_exact(sock, 4))
    if n > MAX_FRAME:
        raise ValueError("frame too large: %d bytes" % n)
    return decode(_recv_exact(sock, n))


def write_frame(sock, term):
    data = encode(term)
    sock.sendall(_len.pack(len(data)) + data)


def _safe_repr(v):
    try:
        return repr(v)
    except Exception:
        return "<unrepresentable>"
