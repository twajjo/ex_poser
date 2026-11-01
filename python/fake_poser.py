"""A small stand-in for Poser's `poser` module, for tests and the standalone server.

Class names match Poser's (SceneType, FigureType, ActorType, ParmType) so the
handle table and the strict policy see the same names they would inside Poser.
"""

import sys
import time
import types

NUM_FRAMES = 30


class error(Exception):
    """Poser raises poser.error for API failures."""


class ParmType(object):
    def __init__(self, name, value):
        self._name, self._value = name, value

    def Name(self):
        return self._name

    def Value(self):
        return self._value

    def SetValue(self, v):
        self._value = v


class ActorType(object):
    def __init__(self, name):
        self._name = name
        self._parms = [ParmType("xTran", 0.0), ParmType("Weird", float("nan"))]

    def Name(self):
        return self._name

    def InternalName(self):
        return self._name.lower()

    def Parameter(self, name):
        for p in self._parms:
            if p.Name() == name:
                return p
        return None

    def Parameters(self):
        return list(self._parms)


class FigureType(object):
    def __init__(self, name, actors):
        self._name, self._actors = name, actors

    def Name(self):
        return self._name

    def InternalName(self):
        return self._name.lower()

    def Actors(self):
        return list(self._actors)


class SceneType(object):
    def __init__(self):
        self._frame = 0
        actors = [ActorType("hip"), ActorType("chest"), ActorType(u"Ünïcode 頭")]
        self._figures = [FigureType("Figure 1", actors)]
        self._actors = actors

    def Frame(self):
        return self._frame

    def SetFrame(self, n):
        if not 0 <= n < NUM_FRAMES:
            raise ValueError("frame out of range")
        self._frame = n

    def NumFrames(self):
        return NUM_FRAMES

    def Figures(self):
        return list(self._figures)

    def Figure(self, name):
        for f in self._figures:
            if f.Name() == name:
                return f
        raise error("no figure named %s" % name)

    def Actors(self):
        return list(self._actors)

    def Actor(self, name):
        for a in self._actors:
            if a.Name() == name:
                return a
        raise error("no actor named %s" % name)


def install():
    """Build a fresh fake `poser` module and register it as sys.modules['poser']."""
    mod = types.ModuleType("poser")
    state = {"scene": SceneType()}

    def Scene():
        return state["scene"]

    def AppVersion():
        return "fake-14"

    def Sleep(seconds):
        time.sleep(seconds)

    def SleepThenScene(seconds):
        time.sleep(seconds)
        return state["scene"]

    def Cyclic():
        x = []
        x.append(x)
        return x

    def NewScene():
        state["scene"] = SceneType()
        mod.on_new_scene()

    mod.Scene, mod.AppVersion, mod.Sleep = Scene, AppVersion, Sleep
    mod.SleepThenScene, mod.Cyclic, mod.NewScene = SleepThenScene, Cyclic, NewScene
    mod.on_new_scene = lambda: None
    mod.error = error
    mod.SceneType, mod.FigureType, mod.ActorType, mod.ParmType = (
        SceneType, FigureType, ActorType, ParmType)
    mod.kParmCodeXTRAN = 1
    sys.modules["poser"] = mod
    return mod


def NewScene():
    """Module-level entry point for the dev-mode X op: replace the current scene."""
    sys.modules["poser"].NewScene()
