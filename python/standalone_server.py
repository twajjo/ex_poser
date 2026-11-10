"""Run the bridge server outside Poser, with a fake `poser` module.

Tests the transport, codec, dispatcher and threading model without Poser:

    python3 python/standalone_server.py --session /tmp/session.json

--port 0 picks a free port (written to the session file). The Elixir tests
start it with --exit-on-stdin-eof so it dies with the test run.
"""

import argparse
import os
import queue
import secrets
import sys
import threading

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import fake_poser  # noqa: E402
from ex_poser_bridge import net  # noqa: E402
from ex_poser_bridge.policy import Policy  # noqa: E402
from ex_poser_bridge.server import PROTOCOL, Server  # noqa: E402


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--port", type=int, default=net.DEV_PORT)
    p.add_argument("--host", action="append", help="bind address (repeatable)")
    p.add_argument("--wsl", action="store_true", help="also bind the WSL adapter")
    p.add_argument("--session", help="session file path (default: %%APPDATA%%)")
    p.add_argument("--events", type=float, default=1.0,
                   help="seconds between fake frame_changed events (0 = off)")
    p.add_argument("--mode", choices=["dev", "strict"], default="dev")
    p.add_argument("--api", default=os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                                 "..", "priv", "poser_api.json"),
                   help="API dump used as the strict-mode allowlist")
    p.add_argument("--exit-on-stdin-eof", action="store_true",
                   help="exit when stdin closes (for test harnesses)")
    opts = p.parse_args()

    if opts.exit_on_stdin_eof:
        def watch_stdin():
            sys.stdin.read()
            os._exit(0)
        threading.Thread(target=watch_stdin, daemon=True).start()

    hosts = opts.host or ["127.0.0.1"]
    if opts.wsl:
        ip = net.wsl_adapter_ip()
        if not ip:
            sys.exit("no WSL adapter found")
        hosts.append(ip)

    fake = fake_poser.install()
    policy = Policy.load(opts.mode, opts.api)
    work = queue.Queue()
    info = {"poser_version": "standalone", "python_version": sys.version.split()[0]}
    log = lambda msg: print(msg, flush=True)  # noqa: E731
    server = Server(hosts, opts.port, secrets.token_hex(16), work.put, info, log,
                    poser=fake, policy=policy)
    fake.on_new_scene = lambda: work.put(server.new_generation)
    server.start()
    path = net.write_session({"port": server.port, "token": server.token,
                              "protocol": PROTOCOL, "hosts": hosts}, opts.session)
    print("session file %s" % path, flush=True)

    def schedule_tick():
        t = threading.Timer(opts.events, lambda: work.put(tick))
        t.daemon = True
        t.start()

    def tick():
        scene = fake.Scene()
        scene.SetFrame((scene.Frame() + 1) % scene.NumFrames())
        server.send_event("frame_changed", scene.Frame())
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
