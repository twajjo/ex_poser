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
    """A parameter with per-frame keys. Every parm starts keyed at frame 0.

    Value() at a frame without its own key reads the nearest earlier key (no
    interpolation). SetValue creates a key at the current frame.
    """

    def __init__(self, name, value, scene_frame=lambda: 0, internal=None, code=0):
        self._name = name
        self._internal = name.lower() if internal is None else internal
        self._code = code
        self._frame = scene_frame
        self._keys = {0: float(value)}

    def Name(self):
        return self._name

    def InternalName(self):
        return self._internal

    def Code(self):
        return self._code

    def _key_at_or_before(self, frame):
        return max(k for k in self._keys if k <= frame)

    def Value(self):
        return self._keys[self._key_at_or_before(self._frame())]

    def SetValue(self, v):
        self._keys[self._frame()] = float(v)

    def AddKeyFrame(self, frame=None):
        frame = self._frame() if frame is None else frame
        self._keys[frame] = self._keys[self._key_at_or_before(frame)]

    def DeleteKeyFrame(self, frame=None):
        self._keys.pop(self._frame() if frame is None else frame, None)

    def NextKeyFrame(self):
        later = [k for k in self._keys if k > self._frame()]
        return min(later) if later else None

    def PrevKeyFrame(self):
        earlier = [k for k in self._keys if k < self._frame()]
        return max(earlier) if earlier else None

    def MinValue(self):
        return -180.0

    def MaxValue(self):
        return 180.0


class LinkType(object):
    """A chain whose links arrive one at a time (smoke-walk test)."""

    def __init__(self, n):
        self._n = n

    def Next(self):
        return LinkType(self._n + 1)


class VertexType(object):
    def __init__(self, x):
        self._x = x

    def X(self):
        return self._x


class ImageType(object):
    def __init__(self, path):
        self._path = path

    def Path(self):
        return self._path


class GeomType(object):
    def __init__(self):
        self._positions = None
        self._vertices = [VertexType(float(i)) for i in range(5)]

    def Vertices(self):
        return list(self._vertices)

    def Node(self, index):
        return index

    def numVertices(self):
        return self.NumVertices()

    def NumVertices(self):
        return 0 if self._positions is None else len(self._positions)

    def VertexPositions(self):
        return self._positions

    def SetVertexPositions(self, positions):
        self._positions = positions


class ActorType(object):
    def __init__(self, name, internal=None, scene_frame=lambda: 0, body_part=True, kind=None):
        self._name = name
        self.kind = kind
        self._scene = None
        self._point_at = None
        self._internal = name.lower() if internal is None else internal
        self._body_part = body_part
        self.visible = True
        self._parms = [ParmType("xTran", 0.0, scene_frame, code=1),
                       ParmType("Weird", float("nan"), scene_frame)]
        self._geom = GeomType()

    def Name(self):
        return self._name

    def InternalName(self):
        return self._internal

    def IsBodyPart(self):
        return 1 if self._body_part else 0

    def Parameter(self, name):
        for p in self._parms:
            if p.Name() == name:
                return p
        return None

    def InternalParameter(self, name):
        # Deliberately returns None on a miss (as Poser does), unlike the
        # figure/actor lookups, which raise; the Elixir side handles both.
        for p in self._parms:
            if p.InternalName() == name:
                return p
        return None

    def Parameters(self):
        return list(self._parms)

    def ParameterByCode(self, code):
        for p in self._parms:
            if p.Code() == code:
                return p
        return None

    def IsLight(self):
        return 1 if self.kind == "light" else 0

    def IsCamera(self):
        return 1 if self.kind == "camera" else 0

    def PointAt(self, target):
        self._point_at = target

    def PointAtTarget(self):
        """Test-only: Poser has no getter for the point-at target."""
        return self._point_at

    def Delete(self):
        self._scene._remove(self)

    def Geometry(self):
        return self._geom

    def BrokenGetter(self):
        raise RuntimeError("broken getter")

    def Odd(self, *args):
        return len(args)

    def SetUpdateCallback(self, callback, args=None):
        self._callback = callback


class LightActor(ActorType):
    """A light: an ActorType with the Poser light properties and Kd dials."""

    def __init__(self, name, internal, light_type, scene_frame=lambda: 0):
        ActorType.__init__(self, name, internal=internal, scene_frame=scene_frame,
                           body_part=False, kind="light")
        self._parms = [ParmType("xTran", 0.0, scene_frame, code=1),
                       ParmType("KdRed", 1.0, scene_frame, code=23),
                       ParmType("KdGreen", 1.0, scene_frame, code=24),
                       ParmType("KdBlue", 1.0, scene_frame, code=25),
                       ParmType("KdIntensity", 1.0, scene_frame, code=29)]
        self._props = {
            "light_type": light_type, "atten_type": 0, "on": 1, "preview": 1,
            "shadow": 1, "casts_shadows": 1, "ray_trace_shadows": 0,
            "shadow_bias_min": 0.0, "shadow_bias_max": 0.0,
            "shadow_blur_radius": 0.0, "shadow_raytrace_softness": 0.0,
            "shadow_samples": 0, "ambient_occlusion": 0,
            "ambient_occlusion_bias": 0.0, "ambient_occlusion_distance": 0.0,
            "ambient_occlusion_strength": 0.0}

    def LightType(self):
        return self._props["light_type"]

    def SetLightType(self, v):
        self._props["light_type"] = v

    def LightAttenType(self):
        return self._props["atten_type"]

    def SetLightAttenType(self, v):
        self._props["atten_type"] = v

    def LightOn(self):
        return self._props["on"]

    def SetLightOn(self, v):
        self._props["on"] = v

    def LightPreview(self):
        return self._props["preview"]

    def SetLightPreview(self, v):
        self._props["preview"] = v

    def Shadow(self):
        return self._props["shadow"]

    def SetShadow(self, v):
        self._props["shadow"] = v

    def CastsShadows(self):
        return self._props["casts_shadows"]

    def SetCastsShadows(self, v):
        self._props["casts_shadows"] = v

    def RayTraceShadows(self):
        return self._props["ray_trace_shadows"]

    def SetRayTraceShadows(self, v):
        self._props["ray_trace_shadows"] = v

    def ShadowBiasMin(self):
        return self._props["shadow_bias_min"]

    def SetShadowBiasMin(self, v):
        self._props["shadow_bias_min"] = v

    def ShadowBiasMax(self):
        return self._props["shadow_bias_max"]

    def SetShadowBiasMax(self, v):
        self._props["shadow_bias_max"] = v

    def ShadowBlurRadius(self):
        return self._props["shadow_blur_radius"]

    def SetShadowBlurRadius(self, v):
        self._props["shadow_blur_radius"] = v

    def ShadowRaytraceSoftness(self):
        return self._props["shadow_raytrace_softness"]

    def SetShadowRaytraceSoftness(self, v):
        self._props["shadow_raytrace_softness"] = v

    def ShadowSamples(self):
        return self._props["shadow_samples"]

    def SetShadowSamples(self, v):
        self._props["shadow_samples"] = v

    def AmbientOcclusion(self):
        return self._props["ambient_occlusion"]

    def SetAmbientOcclusion(self, v):
        self._props["ambient_occlusion"] = v

    def AmbientOcclusionBias(self):
        return self._props["ambient_occlusion_bias"]

    def SetAmbientOcclusionBias(self, v):
        self._props["ambient_occlusion_bias"] = v

    def AmbientOcclusionDistance(self):
        return self._props["ambient_occlusion_distance"]

    def SetAmbientOcclusionDistance(self, v):
        self._props["ambient_occlusion_distance"] = v

    def AmbientOcclusionStrength(self):
        return self._props["ambient_occlusion_strength"]

    def SetAmbientOcclusionStrength(self, v):
        self._props["ambient_occlusion_strength"] = v

    def GetLightIntensity(self):
        return self.ParameterByCode(29).Value()

    def SetLightIntensity(self, v):
        self.ParameterByCode(29).SetValue(v)


class CameraActor(ActorType):
    """A camera: an ActorType with xTran and Focal dials."""

    def __init__(self, name, internal, scene_frame=lambda: 0):
        ActorType.__init__(self, name, internal=internal, scene_frame=scene_frame,
                           body_part=False, kind="camera")
        self._parms = [ParmType("xTran", 0.0, scene_frame, code=1),
                       ParmType("Focal", 55.0, scene_frame, code=12)]


class FigureType(object):
    def __init__(self, name, actors, internal=None):
        self._name, self._actors = name, actors
        self._internal = name.lower() if internal is None else internal

    def Name(self):
        return self._name

    def InternalName(self):
        return self._internal

    def Actors(self):
        return list(self._actors)

    def ActorByInternalName(self, name):
        for a in self._actors:
            if a.InternalName() == name:
                return a
        raise error("Figure has no actor by that name")


class SceneType(object):
    def __init__(self):
        self._frame = 0
        frame = self.Frame
        actors = [ActorType("hip", scene_frame=frame), ActorType("chest", scene_frame=frame),
                  ActorType(u"Ünïcode 頭", scene_frame=frame)]
        head = [ActorType("head", scene_frame=frame)]
        ball = ActorType("Ball", internal="ball", scene_frame=frame, body_part=False)
        self._figures = [FigureType("Figure 1", actors),
                         FigureType("Figure 1", head, internal="figure 2")]
        lights = [LightActor("Key", "light 1", 1, frame),
                  LightActor("Fill", "light 2", 2, frame),
                  LightActor("Fill", "light 3", 3, frame)]
        cameras = [CameraActor("Main Camera", "MAIN_CAMERA", frame),
                   CameraActor("Aux Camera", "AUX_CAMERA", frame)]
        self._actors = actors + head + [ball] + lights + cameras
        self._current_camera = cameras[0]
        for a in self._actors:
            a._scene = self

    def Frame(self):
        return self._frame

    def SetFrame(self, n):
        if not 0 <= n < NUM_FRAMES:
            raise ValueError("frame out of range")
        self._frame = n

    def NumFrames(self):
        return NUM_FRAMES

    def FramesPerSecond(self):
        return 30

    def FigureByInternalName(self, name):
        for f in self._figures:
            if f.InternalName() == name:
                return f
        raise error("Unknown/invalid figure name")

    def ActorByInternalName(self, name):
        for a in self._actors:
            if a.InternalName() == name:
                return a
        raise error("Named actor could not be found")

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

    def Lights(self):
        return [a for a in self._actors if a.IsLight()]

    def Cameras(self):
        return [a for a in self._actors if a.IsCamera()]

    def CurrentCamera(self):
        return self._current_camera

    def SetCurrentCamera(self, actor):
        self._current_camera = actor

    def CreateLight(self):
        taken = set(a.InternalName() for a in self._actors)
        n = 1
        while "light %d" % n in taken:
            n += 1
        light = LightActor("Light %d" % n, "light %d" % n, 1, self.Frame)
        light._scene = self
        self._actors.append(light)
        return light

    def _remove(self, actor):
        self._actors.remove(actor)


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

    def FirstLink():
        return LinkType(0)

    def NewScene():
        state["scene"] = SceneType()
        mod.on_new_scene()

    mod.Scene, mod.AppVersion, mod.Sleep = Scene, AppVersion, Sleep
    mod.SleepThenScene, mod.Cyclic, mod.NewScene = SleepThenScene, Cyclic, NewScene
    mod.FirstLink = FirstLink
    mod.on_new_scene = lambda: None
    mod.error = error
    mod.SceneType, mod.FigureType, mod.ActorType, mod.ParmType, mod.GeomType = (
        SceneType, FigureType, ActorType, ParmType, GeomType)
    mod.VertexType, mod.ImageType, mod.LinkType = VertexType, ImageType, LinkType
    mod.LightActor, mod.CameraActor = LightActor, CameraActor
    mod.kParmCodeXTRAN = 1
    mod.kParmCodeFOCAL = 12
    sys.modules["poser"] = mod
    return mod


def NewScene():
    """Module-level entry point for the dev-mode X op: replace the current scene."""
    sys.modules["poser"].NewScene()
