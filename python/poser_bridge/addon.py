"""The Poser add-on: starts the bridge server on load and forwards scene events."""

import secrets
import sys

import poser
import poseraddon
import wx

from . import net
from .server import PROTOCOL, Server

ADDON_ID = "com.geekware.poserBridge"


class Bridge(poseraddon.Addon, poseraddon.SceneObserver):
    def __init__(self):
        # Our own dict: poseraddon.Addon.addonInfo is class-level state shared
        # by every add-on that mutates it in place.
        self.addonInfo = {
            "id": ADDON_ID,
            "author": "Jeff Osborn",
            "copyright": "(c) 2026 Jeff Osborn",
            "name": "Poser Bridge",
            "version": "0.1",
            "observer": 1,
            "scenedata": 0,
            "prefsdata": 0,
            "apiversion": "1.2",
        }
        self.server = None

    def load(self):
        hosts = ["127.0.0.1"]
        wsl = net.wsl_adapter_ip()
        if wsl:
            hosts.append(wsl)
        else:
            print("poser_bridge: no WSL adapter found; listening on loopback only")
        info = {"poser_version": _poser_version(), "python_version": sys.version.split()[0]}
        server = Server(hosts, net.DEV_PORT, secrets.token_hex(16), wx.CallAfter, info)
        try:
            server.start()
        except OSError as e:
            server.stop()
            print("poser_bridge: cannot listen on port %d: %s" % (net.DEV_PORT, e))
            return
        self.server = server
        path = net.write_session({"port": net.DEV_PORT, "token": server.token,
                                  "protocol": PROTOCOL, "hosts": hosts})
        print("poser_bridge: loaded, session file %s" % path)

    def unload(self):
        if self.server:
            self.server.stop()
            self.server = None

    def frameChanged(self):
        if self.server:
            try:
                self.server.send_event("frame_changed", poser.Scene().Frame())
            except Exception as e:
                print("poser_bridge: frameChanged: %r" % (e,))


def _poser_version():
    for name in ("Version", "AppVersion"):
        fn = getattr(poser, name, None)
        if callable(fn):
            try:
                return str(fn())
            except Exception:
                pass
    return "unknown"


poser.RegisterAddon(ADDON_ID, Bridge())
