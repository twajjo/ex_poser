"""Socket server for the bridge. Never imports poser or wx.

Threading: accept and reader threads only touch sockets. Anything that may
call the Poser API is handed to `submit(fn)`, which is wx.CallAfter inside
Poser and a queue-draining fake main thread when run standalone.
"""

import hmac
import socket
import threading
import traceback

from . import codec
from .codec import atom
from .dispatch import raw_call

PROTOCOL = 1

A_HELLO = atom("hello")
A_PING = atom("ping")
A_PING_MAIN = atom("ping_main")
A_X = atom("X")
A_R = atom("r")
A_E = atom("e")
A_M = atom("M")
A_PYTHON = atom("python")


class Server(object):
    def __init__(self, hosts, port, token, submit, info=None, log=print):
        self.hosts, self.port, self.token = hosts, port, token
        self.submit, self.log = submit, log
        self.info = dict(info or {})
        self.listeners, self.conns = [], []
        self.lock = threading.Lock()

    def start(self):
        for host in self.hosts:
            srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            if hasattr(socket, "SO_EXCLUSIVEADDRUSE"):  # Windows: no port hijacking
                srv.setsockopt(socket.SOL_SOCKET, socket.SO_EXCLUSIVEADDRUSE, 1)
            else:
                srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            srv.bind((host, self.port))
            srv.listen(4)
            self.listeners.append(srv)
            threading.Thread(target=self._accept, args=(srv,), daemon=True,
                             name="poser_bridge accept %s" % host).start()
            self.log("poser_bridge: listening on %s:%d" % (host, self.port))

    def stop(self):
        with self.lock:
            socks = self.listeners + [c.sock for c in self.conns]
            self.listeners, self.conns = [], []
        for s in socks:
            try:
                s.close()
            except OSError:
                pass

    def send_event(self, name, payload):
        with self.lock:
            conns = [c for c in self.conns if c.authed]
        for c in conns:
            c.send((A_M, (atom(name), payload)))

    def _accept(self, srv):
        while True:
            try:
                sock, addr = srv.accept()
            except OSError:
                return  # listener closed by stop()
            sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
            conn = Connection(self, sock, addr)
            with self.lock:
                self.conns.append(conn)
            threading.Thread(target=conn.run, daemon=True,
                             name="poser_bridge reader %s:%d" % addr).start()

    def _forget(self, conn):
        with self.lock:
            if conn in self.conns:
                self.conns.remove(conn)


class Connection(object):
    def __init__(self, server, sock, addr):
        self.server, self.sock, self.addr = server, sock, addr
        self.wlock = threading.Lock()
        self.authed = False

    def run(self):
        log = self.server.log
        try:
            if not self._handshake(codec.read_frame(self.sock)):
                return
            log("poser_bridge: client %s:%d connected" % self.addr)
            while True:
                self._dispatch(codec.read_frame(self.sock))
        except (EOFError, OSError):
            pass
        except Exception as e:
            log("poser_bridge: dropping %s:%d: %r" % (self.addr + (e,)))
        finally:
            self.authed = False
            self.server._forget(self)
            try:
                self.sock.close()
            except OSError:
                pass
            log("poser_bridge: client %s:%d disconnected" % self.addr)

    def _handshake(self, msg):
        if not (type(msg) is tuple and len(msg) == 2 and msg[0] == A_HELLO
                and isinstance(msg[1], dict)):
            self.server.log("poser_bridge: rejected %s:%d (no hello)" % self.addr)
            return False
        token = msg[1].get(atom("token"))
        if not (isinstance(token, str)
                and hmac.compare_digest(token.encode("utf-8"),
                                        self.server.token.encode("utf-8"))):
            self.server.log("poser_bridge: rejected %s:%d (bad token)" % self.addr)
            return False
        theirs = msg[1].get(atom("protocol"))
        if theirs != PROTOCOL:
            self.send((A_E, 0, (atom("protocol_mismatch"), PROTOCOL, theirs)))
            return False
        reply = dict((atom(k), v) for k, v in self.server.info.items())
        reply[atom("protocol")] = PROTOCOL
        reply[atom("mode")] = atom("dev")
        self.authed = True
        self.send((A_R, 0, reply))
        return True

    def _dispatch(self, msg):
        if type(msg) is not tuple or len(msg) < 2 or not isinstance(msg[1], int):
            raise ValueError("malformed request: %r" % (msg,))
        tag, mid = msg[0], msg[1]
        if tag == A_PING:
            self.send((A_R, mid, atom("pong")))
        elif tag == A_PING_MAIN:
            self.server.submit(lambda: self.send((A_R, mid, atom("pong"))))
        elif tag == A_X and len(msg) == 5:
            _, _, module, function, args = msg
            self.server.submit(lambda: self._call(mid, raw_call, module, function, args))
        else:
            self.send((A_E, mid, (atom("bad_request"), repr(msg))))

    def _call(self, mid, fn, *args):
        # main thread: must never raise back into Poser's event loop
        try:
            value = fn(*args)
        except Exception as e:
            tb = traceback.format_exception(type(e), e, e.__traceback__)
            self.send((A_E, mid, (A_PYTHON, type(e).__name__, str(e), tb)))
        else:
            self.send((A_R, mid, value))

    def send(self, term):
        try:
            with self.wlock:
                codec.write_frame(self.sock, term)
        except OSError:
            pass  # reader thread notices the dead socket and cleans up
        except Exception as e:
            self.server.log("poser_bridge: cannot encode reply: %r" % (e,))

