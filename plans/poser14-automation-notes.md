# Poser 14: Automation, Animation and PoserPython Notes

Source: Poser 14 Reference Manual, https://www.posersoftware.com/documentation/14/HTML/
(The linked start page, `idh-topic10.html`, is only the foreword and credits; these notes come from the manual's PoserPython, Animating and Rendering chapters.)

**In short:** the manual explains how scripts are run, packaged and hooked into Poser, but it does not document the Python commands themselves. The animation chapters describe only the menus and palettes, not how to drive them from code.

## What the manual says about PoserPython

### Ways to run a script

- **Menus:** `File > Run Python Script`, the `Scripts` menu (anything placed in `Runtime\Python\PoserScripts\ScriptsMenu`), or buttons on the `Window > Python Scripts` palette.
- **From a pose file:** a `.pz2` pose file can run a script.
  - `runPythonScript "runtime:path:to:script.py"` takes no arguments.
  - `runPythonScriptEx "runtime:path:script.py" apples` passes one, which arrives as `sys.argv[1]`.
  - This lets one library item start a whole automation, such as "apply walk, render frames 1–120".
- **Add-ons that load at startup:** `poserStartup.py` loads packages that subclass `poseraddon.Addon` and call `poser.RegisterAddon()`. This is the main hook for automation that reacts to events:
  - `SceneObserver` gives you callbacks such as `frameChanged`, `objectsAdded`, `sceneCreated`, `cameraChanged` and `lightsChanged`. They fire once Poser returns to idle, not at the moment the change happens.
  - `SceneDataSaver` stores your own data inside the scene file, and `PrefsSaver` stores preferences.
  - The full base classes are in `Runtime/Python/addons/poseraddon.py`.
- **Custom panels:** wxPython panels go through `poser.WxAuiManager().GetManagedWindow()`. The manual's firm rule is to use Poser's managed window and never start your own main event loop.

### Constraints and setup

- The manual says Python 3.7.9, but in a sentence that still refers to Poser 13. Python 2.x scripts may not work.
- Strings should be Unicode.
- Don't call the API from secondary threads.
- Use `\\` or `:` in file paths.
- numpy loads automatically.
- On Windows, extra modules can be installed with pip against Poser's external Python. Inside Poser's Python Shell you can use `pip.main(['install','--target',<site-packages>,pkg])`.
- Saving compiled `.pyc` files is off until you set `ALLOW_PYTHON_PYC 1` in `Poser.ini`.
- Scripts are distributed as a ZIP with one top-level folder containing `install_python.json`. Add `"addon": 1` to make it an add-on. `poser.VerifyPurchase()` lets commercial scripts check that the user bought them.

### Finding the API reference

The API reference isn't in the manual. To see it, open `Scripts > Python Shell` and run:

```python
import pydoc
pydoc.browse(1521)
```

Then click `poser` under Built-In Modules.

The manual's only code sample has bugs: `Poser.Scene()` should be `poser.Scene()`, and `Scene.CurrentActor()` should be `scene.CurrentActor()`. Corrected:

```python
import poser
scene = poser.Scene()
actor = scene.CurrentActor()
parm = actor.ParameterByCode(poser.kParmCodeXSCALE)  # check the constant name in pydoc
parm.SetValue(88)
```

## Animation and render features worth scripting

| Feature | Notes for automation |
|---|---|
| Keyframes / interpolation | Interpolation types are Spline (can overshoot), Linear, Constant and Break Spline, set per element or per frame range. Spline keys affect the frames before them, so check results after setting keys in bulk. |
| Layers (non-linear animation) | The Base layer always runs the full length of the animation; changing its End frame changes the animation length. Other layers have their own start and end frames and are combined at render time. |
| Animation Sets | Reusable clips. They are saved through the Pose library's "Select from Animation Set" option, which means they can then be loaded as `.pz2` files. |
| Bake Transforms | Turns automatic motion (Point At, constraints) into real keyframes. Do this before exporting. It doesn't cover cloth, hair or soft bodies. |
| Constraint channels | `Object > Add Constraint` blends between targets with a 0–1 dial that can be keyframed. |
| Walk Designer / Talk Designer | These are interactive dialogs. Walks save to files, and the Talk Designer uses Rhubarb with WAV/MP3, a transcript and viseme maps in `Runtime\LipSync`. |
| BVH import, Alembic export | BVH import lands on the selected figure. Afterwards, `Scripts > Utility > dropFigToFloorAllFrames` fixes figures floating above the floor. |
| Physics | `Animation > Recalculate Dynamics > All Physics` writes keyframes for every frame. Run it before rendering. |
| Make Movie | Renders numbered images (`name_0001.png`) and then encodes MP4. You can set a frame range, every Nth frame, and the FireFly, SuperFly, Sketch or Preview engine. |
| Queue Manager | Renders movies across a network. "Render Images" now and "Encode Images" later can be split up. Background render only does single frames. |

### Bundled sample scripts worth reading

- `Scripts > RenderControl > RenderPasses`
- `Scripts > Utility > dropFigToFloorAllFrames`
- `Scripts > Utility > gravity`
- `Scripts > GeomMods > randomizeMorphs`
- `Scripts > SampleCallbacks > eventCallback`

## Gaps for automation

- **No documented command-line or headless mode.** Everything runs inside the Poser application. The usual pattern is a script that loops over files: open, apply a pose, set the frame range, render, save.
- **Keyframe and render commands are missing from this manual.** These come from the separate PoserPython Methods Manual, not this one, so check each against pydoc for your build:
  - **Frames:** `scene.SetFrame` / `NumFrames`
  - **Keys and interpolation:** `parm.SetValue` plus `AddKeyFrame` / `DeleteKeyFrame` / `LinearAtFrame` / `SplineAtFrame`
  - **Loading content:** `scene.LoadLibraryPose`
  - **Rendering:** `scene.Render()` / `SaveImage`, and `scene.MovieMaker()` for range, format and `Make()`
  - **Import/export:** `scene.ImExporter()` for BVH and FBX
- **XML-RPC is listed only in the credits.** Nothing in the manual says whether Poser exposes it for remote control.

## Key manual pages

- PoserPython: `developing-with-poserpython.html`, `poserpython-scripts.html`, `poser-python-addons.html`, `writing-python-scripts.html`, `packaging-your-script.html`, `linking-extra-modules-to-poserpython.html`
- Animation: `animating.html`, `working-with-keyframes.html`, `selecting-interpolation-types.html`, `layers-tab.html`, `animation-sets-tab.html`, `advanced-animation-techniques.html`
- Rendering: `rendering-animations.html`, `sending-jobs-to-the-queue-manager.html`, `using-the-queue-manager.html`
