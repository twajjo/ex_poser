"""Run the bridge server outside Poser, with a fake `poser` module.

Tests the transport, codec and threading model without Poser:

    python3 python/standalone_server.py --session /tmp/session.json

Run it with Poser's own python.exe to check Python 3.7 compatibility and the
WSL -> Windows network path (add --wsl to also bind the WSL adapter).
"""

import argparse
import os
import queue
import secrets
import sys
import threading
import types

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from poser_bridge import net  # noqa: E402  (imported before the fake poser exists)
from poser_bridge.server import PROTOCOL, Server  # noqa: E402


class _Named(object):
    def __init__(self, name):
        self._name = name

    def Name(self):
        return self._name


class _FakeScene(object):
    def __init__(self):
        self.frame = 0

    def Frame(self):
        return self.frame

    def NumFrames(self):
        return 30

    def Figures(self):
        return [_Named("FakeFigure")]

    def Actors(self):
        return [_Named("hip"), _Named("chest"), _Named("head")]


def _install_fake_poser():
    scene = _FakeScene()
    fake = types.ModuleType("poser")
    fake.Scene = lambda: scene
    sys.modules["poser"] = fake
    return scene


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--port", type=int, default=net.DEV_PORT)
    p.add_argument("--host", action="append", help="bind address (repeatable)")
    p.add_argument("--wsl", action="store_true", help="also bind the WSL adapter")
    p.add_argument("--session", help="session file path (default: %%APPDATA%%)")
    p.add_argument("--events", type=float, default=1.0,
                   help="seconds between fake frame_changed events (0 = off)")
    opts = p.parse_args()

    hosts = opts.host or ["127.0.0.1"]
    if opts.wsl:
        ip = net.wsl_adapter_ip()
        if not ip:
            sys.exit("no WSL adapter found")
        hosts.append(ip)

    scene = _install_fake_poser()
    work = queue.Queue()
    info = {"poser_version": "standalone", "python_version": sys.version.split()[0]}
    log = lambda msg: print(msg, flush=True)  # noqa: E731
    server = Server(hosts, opts.port, secrets.token_hex(16), work.put, info, log)
    server.start()
    path = net.write_session({"port": opts.port, "token": server.token,
                              "protocol": PROTOCOL, "hosts": hosts}, opts.session)
    print("session file %s" % path, flush=True)

    def schedule_tick():
        t = threading.Timer(opts.events, lambda: work.put(tick))
        t.daemon = True
        t.start()

    def tick():
        scene.frame = (scene.frame + 1) % scene.NumFrames()
        server.send_event("frame_changed", scene.frame)
        schedule_tick()

    if opts.events > 0:
        schedule_tick()

    # this thread plays Poser's main thread; the timeout keeps Ctrl-C working on Windows
    try:
        while True:
            try:
                fn = work.get(timeout=0.5)
            except queue.Empty:
                continue
            fn()
    except KeyboardInterrupt:
        server.stop()


if __name__ == "__main__":
    main()
