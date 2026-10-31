"""Phase 0 helpers, called on the main thread through the dev-mode X op."""

import poser


def frame():
    return poser.Scene().Frame()


def scene_summary():
    scene = poser.Scene()
    return {
        "frame": scene.Frame(),
        "num_frames": scene.NumFrames(),
        "figures": [f.Name() for f in scene.Figures()],
        "actors": len(scene.Actors()),
    }
