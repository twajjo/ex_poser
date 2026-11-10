"""The Poser add-on: starts the bridge server on load and forwards scene events."""

import os
import secrets
import sys

import poser
import poseraddon
import wx

from . import net
from .policy import Policy
from .server import PROTOCOL, Server

ADDON_ID = "com.geekware.exPoserBridge"


class Bridge(poseraddon.Addon, poseraddon.SceneObserver):
    def __init__(self):
        # Our own dict: poseraddon.Addon.addonInfo is class-level state shared
        # by every add-on that mutates it in place.
        self.addonInfo = {
            "id": ADDON_ID,
            "author": "Jeff Osborn",
            "copyright": "(c) 2026 Jeff Osborn",
            "name": "ExPoser Bridge",
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
            print("ex_poser_bridge: no WSL adapter found; listening on loopback only")
        mode = net.read_config().get("mode", "dev")
        api_path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "poser_api.json")
        try:
            policy = Policy.load(mode, api_path)
        except (OSError, ValueError) as e:
            print("ex_poser_bridge: strict mode needs poser_api.json: %s" % (e,))
            return
        info = {"poser_version": _poser_version(), "python_version": sys.version.split()[0]}
        server = Server(hosts, net.DEV_PORT, secrets.token_hex(16), wx.CallAfter, info,
                        poser=poser, policy=policy)
        try:
            server.start()
        except OSError as e:
            server.stop()
            print("ex_poser_bridge: cannot listen on port %d: %s" % (net.DEV_PORT, e))
            return
        self.server = server
        path = net.write_session({"port": net.DEV_PORT, "token": server.token,
                                  "protocol": PROTOCOL, "hosts": hosts})
        print("ex_poser_bridge: loaded (%s mode), session file %s" % (policy.mode, path))

    def unload(self):
        if self.server:
            self.server.stop()
            self.server = None

    def sceneCreated(self, scene):
        if self.server:
            self.server.new_generation()

    def sceneDeleting(self, scene):
        if self.server:
            self.server.new_generation()

    def frameChanged(self):
        if self.server:
            try:
                self.server.send_event("frame_changed", poser.Scene().Frame())
            except Exception as e:
                print("ex_poser_bridge: frameChanged: %r" % (e,))


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
