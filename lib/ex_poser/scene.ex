defmodule ExPoser.Scene do
  @moduledoc """
  The open Poser scene: its timeline, its figures, and its own props,
  cameras and lights.

  Poser has one scene per session, so nothing here takes a scene value. It
  also has one global current frame, which PoserPython reads and writes
  dials at. Here the `frame:` option of `ExPoser.Parameter` and `ExPoser.Batch`
  takes its place: it moves Poser to a frame for one request and moves it
  back. `set_frame/2` is the only function that moves the timeline and
  leaves it there.

  Frames count from 0, as in PoserPython: `frame: 0` is GUI frame 1.

  ## Common tasks

      {:ok, figs} = ExPoser.Scene.figures()
      {:ok, fig} = ExPoser.Scene.figure("Figure 1")   # internal or display name
      {:ok, ball} = ExPoser.Scene.actor("ball")       # props, cameras, lights
      {:ok, n} = ExPoser.Scene.num_frames()           # frames 0..n-1, GUI 1..n

  Body parts are not scene-level actors: `actors/1` and `actor/2` never
  return them. Find them through their figure with `ExPoser.Figure.actors/2`
  and `ExPoser.Figure.actor/3`.

  Lights and cameras have their own structs, `ExPoser.Light` and
  `ExPoser.Camera`: see `lights/1`, `cameras/1` and `current_camera/1`.

  See [Posing](posing.md) and [Frames and keyframes](frames-and-keyframes.md).
  """

  alias ExPoser.{Actor, Batch, Camera, Client, Codec, Error, Figure, Light, Ref}

  @doc group: "Lookup"
  @doc """
  Finds a scene-level actor by internal name (`"ball"`) or by display name
  (`"Ball"`), with the same rules as `figure/2`. Body parts are not found
  here; look them up through their figure. Options: `:server`, `:timeout`.

  ## Examples

      ExPoser.Scene.actor("ball")
      #=> {:ok, #ExPoser.Actor<ball>}
      ExPoser.Scene.actor("Ball")
      #=> {:ok, #ExPoser.Actor<ball>}
  """
  @spec actor(String.t(), keyword()) :: {:ok, Actor.t()} | {:error, Error.t()}
  def actor(name, opts \\ []) when is_binary(name) do
    opts = run_opts(opts)
    guess = %Actor{figure: nil, internal: name, name: name}

    Ref.lookup(
      guess,
      :scene,
      "Actors",
      name,
      &build_actor/1,
      opts,
      ["IsBodyPart"],
      &scene_level?/1
    )
  end

  @doc group: "Lookup"
  @doc """
  Like `actor/2`, but returns the struct and raises `ExPoser.Error` on failure.

  ## Examples

      ExPoser.Scene.actor!("ball")
      #=> #ExPoser.Actor<ball>
  """
  @spec actor!(String.t(), keyword()) :: Actor.t()
  def actor!(name, opts \\ []), do: name |> actor(opts) |> Ref.unwrap!()

  @doc group: "Lookup"
  @doc """
  Lists the scene's own actors: props, cameras and lights, but no body parts
  (those come from `ExPoser.Figure.actors/2`). They have `figure: nil`.
  Options: `:server`, `:timeout`.

  ## Examples

      ExPoser.Scene.actors()
      #=> {:ok, [#ExPoser.Actor<ball>]}
  """
  @spec actors(keyword()) :: {:ok, [Actor.t()]} | {:error, Error.t()}
  def actors(opts \\ []) do
    opts = run_opts(opts)

    with {:ok, rows} <- Ref.children(:scene, "Actors", ["IsBodyPart"], opts),
         do: {:ok, rows |> Enum.filter(&scene_level?/1) |> Enum.map(&build_actor/1)}
  end

  @doc group: "Lookup"
  @doc """
  Like `actors/1`, but returns the list and raises `ExPoser.Error` on failure.

  ## Examples

      ExPoser.Scene.actors!()
      #=> [#ExPoser.Actor<ball>]
  """
  @spec actors!(keyword()) :: [Actor.t()]
  def actors!(opts \\ []), do: opts |> actors() |> Ref.unwrap!()

  @doc group: "Lights and cameras"
  @doc """
  Finds a camera by internal name (`"MAIN_CAMERA"`) or by display name, with
  the same rules as `figure/2`. A name that belongs to something other than a
  camera gives `:not_found`. Options: `:server`, `:timeout`.

  ## Examples

      ExPoser.Scene.camera("Main Camera")
      #=> {:ok, #ExPoser.Camera<Main Camera>}
  """
  @spec camera(String.t(), keyword()) :: {:ok, Camera.t()} | {:error, Error.t()}
  def camera(name, opts \\ []) when is_binary(name) do
    opts = run_opts(opts)
    guess = %Actor{figure: nil, internal: name, name: name}

    Ref.lookup(guess, :scene, "Cameras", name, &build_camera/1, opts, ["IsCamera"], &camera?/1)
  end

  @doc group: "Lights and cameras"
  @doc """
  Like `camera/2`, but returns the struct and raises `ExPoser.Error` on failure.

  ## Examples

      ExPoser.Scene.camera!("Main Camera")
      #=> #ExPoser.Camera<Main Camera>
  """
  @spec camera!(String.t(), keyword()) :: Camera.t()
  def camera!(name, opts \\ []), do: name |> camera(opts) |> Ref.unwrap!()

  @doc group: "Lights and cameras"
  @doc """
  Lists the scene's cameras, in Poser's order. Options: `:server`, `:timeout`.

  ## Examples

      ExPoser.Scene.cameras()
      #=> {:ok, [#ExPoser.Camera<Main Camera>, #ExPoser.Camera<Aux Camera>]}
  """
  @spec cameras(keyword()) :: {:ok, [Camera.t()]} | {:error, Error.t()}
  def cameras(opts \\ []) do
    opts = run_opts(opts)

    with {:ok, rows} <- Ref.children(:scene, "Cameras", [], opts),
         do: {:ok, Enum.map(rows, &build_camera/1)}
  end

  @doc group: "Lights and cameras"
  @doc """
  Like `cameras/1`, but returns the list and raises `ExPoser.Error` on failure.

  ## Examples

      ExPoser.Scene.cameras!()
      #=> [#ExPoser.Camera<Main Camera>, #ExPoser.Camera<Aux Camera>]
  """
  @spec cameras!(keyword()) :: [Camera.t()]
  def cameras!(opts \\ []), do: opts |> cameras() |> Ref.unwrap!()

  @doc group: "Lights and cameras"
  @doc """
  The camera Poser renders through. Options: `:server`, `:timeout`.

  ## Examples

      ExPoser.Scene.current_camera()
      #=> {:ok, #ExPoser.Camera<Main Camera>}
  """
  @spec current_camera(keyword()) :: {:ok, Camera.t()} | {:error, Error.t()}
  def current_camera(opts \\ []) do
    ops = [
      {:call, "Scene", []},
      {:invoke, {:result, 0}, "CurrentCamera", []},
      {:invoke, {:result, 1}, "InternalName", []},
      {:invoke, {:result, 1}, "Name", []}
    ]

    opts = run_opts(opts)

    case Client.batch(ops, opts) do
      {:ok, [_, _, internal, name] = results} ->
        release(results, opts)
        {:ok, build_camera(%{"InternalName" => internal, "Name" => name})}

      {:error, %Error{kind: :batch_failed, details: %{partial: partial}} = error} ->
        release(partial, opts)
        {:error, error}

      {:error, _} = error ->
        error
    end
  end

  @doc group: "Lights and cameras"
  @doc """
  Like `current_camera/1`, but returns the struct and raises `ExPoser.Error` on failure.

  ## Examples

      ExPoser.Scene.current_camera!()
      #=> #ExPoser.Camera<Main Camera>
  """
  @spec current_camera!(keyword()) :: Camera.t()
  def current_camera!(opts \\ []), do: opts |> current_camera() |> Ref.unwrap!()

  @doc group: "Lookup"
  @doc """
  Finds a figure by internal name (`"figure 1"`) or by display name.

  The internal name is tried first and a hit always wins, even when another
  figure shares that text as its display name. Display names repeat freely
  (two figures can both be "Figure 1"), which gives `:ambiguous` with the
  candidates under `details.matches`. No match gives `:not_found`.
  Options: `:server`, `:timeout`.

  ## Examples

      ExPoser.Scene.figure("figure 2")
      #=> {:ok, #ExPoser.Figure<figure 2>}
      ExPoser.Scene.figure("Figure 1")
      #=> {:error, %ExPoser.Error{kind: :ambiguous, ...}}
  """
  @spec figure(String.t(), keyword()) :: {:ok, Figure.t()} | {:error, Error.t()}
  def figure(name, opts \\ []) when is_binary(name) do
    opts = run_opts(opts)
    guess = %Figure{internal: name, name: name}
    Ref.lookup(guess, :scene, "Figures", name, &build_figure/1, opts)
  end

  @doc group: "Lookup"
  @doc """
  Like `figure/2`, but returns the struct and raises `ExPoser.Error` on failure.

  ## Examples

      ExPoser.Scene.figure!("figure 2")
      #=> #ExPoser.Figure<figure 2>
  """
  @spec figure!(String.t(), keyword()) :: Figure.t()
  def figure!(name, opts \\ []), do: name |> figure(opts) |> Ref.unwrap!()

  @doc group: "Lookup"
  @doc """
  Lists the scene's figures, in Poser's order. Options: `:server`, `:timeout`.

  ## Examples

      ExPoser.Scene.figures()
      #=> {:ok, [#ExPoser.Figure<figure 1>, #ExPoser.Figure<figure 2>]}
  """
  @spec figures(keyword()) :: {:ok, [Figure.t()]} | {:error, Error.t()}
  def figures(opts \\ []) do
    opts = run_opts(opts)

    with {:ok, rows} <- Ref.children(:scene, "Figures", [], opts),
         do: {:ok, Enum.map(rows, &build_figure/1)}
  end

  @doc group: "Lookup"
  @doc """
  Like `figures/1`, but returns the list and raises `ExPoser.Error` on failure.

  ## Examples

      ExPoser.Scene.figures!()
      #=> [#ExPoser.Figure<figure 1>, #ExPoser.Figure<figure 2>]
  """
  @spec figures!(keyword()) :: [Figure.t()]
  def figures!(opts \\ []), do: opts |> figures() |> Ref.unwrap!()

  @doc group: "Timeline"
  @doc """
  Playback rate in frames per second. Options: `:server`, `:timeout`.

  ## Examples

      ExPoser.Scene.fps()
      #=> {:ok, 30}
  """
  @spec fps(keyword()) :: {:ok, number()} | {:error, Error.t()}
  def fps(opts \\ []), do: scene_call("FramesPerSecond", [], opts)

  @doc group: "Timeline"
  @doc """
  Like `fps/1`, but returns the rate and raises `ExPoser.Error` on failure.

  ## Examples

      ExPoser.Scene.fps!()
      #=> 30
  """
  @spec fps!(keyword()) :: number()
  def fps!(opts \\ []), do: opts |> fps() |> Ref.unwrap!()

  @doc group: "Timeline"
  @doc """
  The current frame, counting from 0: `0` is GUI frame 1. Options: `:server`, `:timeout`.

  ## Examples

      ExPoser.Scene.frame()
      #=> {:ok, 0}
  """
  @spec frame(keyword()) :: {:ok, non_neg_integer()} | {:error, Error.t()}
  def frame(opts \\ []), do: scene_call("Frame", [], opts)

  @doc group: "Timeline"
  @doc """
  Like `frame/1`, but returns the frame and raises `ExPoser.Error` on failure.

  ## Examples

      ExPoser.Scene.frame!()
      #=> 0
  """
  @spec frame!(keyword()) :: non_neg_integer()
  def frame!(opts \\ []), do: opts |> frame() |> Ref.unwrap!()

  @doc group: "Lights and cameras"
  @doc """
  Finds a light by internal name (`"light 1"`) or by display name, with the
  same rules as `figure/2`. A name that belongs to something other than a
  light gives `:not_found`. Options: `:server`, `:timeout`.

  ## Examples

      ExPoser.Scene.light("Key")
      #=> {:ok, #ExPoser.Light<Key>}
      ExPoser.Scene.light("Fill")
      #=> {:error, %ExPoser.Error{kind: :ambiguous, ...}}
  """
  @spec light(String.t(), keyword()) :: {:ok, Light.t()} | {:error, Error.t()}
  def light(name, opts \\ []) when is_binary(name) do
    opts = run_opts(opts)
    guess = %Actor{figure: nil, internal: name, name: name}

    Ref.lookup(guess, :scene, "Lights", name, &build_light/1, opts, ["IsLight"], &light?/1)
  end

  @doc group: "Lights and cameras"
  @doc """
  Like `light/2`, but returns the struct and raises `ExPoser.Error` on failure.

  ## Examples

      ExPoser.Scene.light!("Key")
      #=> #ExPoser.Light<Key>
  """
  @spec light!(String.t(), keyword()) :: Light.t()
  def light!(name, opts \\ []), do: name |> light(opts) |> Ref.unwrap!()

  @doc group: "Lights and cameras"
  @doc """
  Lists the scene's lights, in Poser's order. Options: `:server`, `:timeout`.

  ## Examples

      ExPoser.Scene.lights()
      #=> {:ok, [#ExPoser.Light<Key>, #ExPoser.Light<Fill>]}
  """
  @spec lights(keyword()) :: {:ok, [Light.t()]} | {:error, Error.t()}
  def lights(opts \\ []) do
    opts = run_opts(opts)

    with {:ok, rows} <- Ref.children(:scene, "Lights", [], opts),
         do: {:ok, Enum.map(rows, &build_light/1)}
  end

  @doc group: "Lights and cameras"
  @doc """
  Like `lights/1`, but returns the list and raises `ExPoser.Error` on failure.

  ## Examples

      ExPoser.Scene.lights!()
      #=> [#ExPoser.Light<Key>, #ExPoser.Light<Fill>]
  """
  @spec lights!(keyword()) :: [Light.t()]
  def lights!(opts \\ []), do: opts |> lights() |> Ref.unwrap!()

  @doc group: "Timeline"
  @doc """
  How many frames the timeline has. The last is `num_frames - 1` (GUI frame
  `num_frames`). Options: `:server`, `:timeout`.

  ## Examples

      ExPoser.Scene.num_frames()
      #=> {:ok, 30}
  """
  @spec num_frames(keyword()) :: {:ok, pos_integer()} | {:error, Error.t()}
  def num_frames(opts \\ []), do: scene_call("NumFrames", [], opts)

  @doc group: "Timeline"
  @doc """
  Like `num_frames/1`, but returns the count and raises `ExPoser.Error` on failure.

  ## Examples

      ExPoser.Scene.num_frames!()
      #=> 30
  """
  @spec num_frames!(keyword()) :: pos_integer()
  def num_frames!(opts \\ []), do: opts |> num_frames() |> Ref.unwrap!()

  @doc group: "Lights and cameras"
  @doc """
  Makes `camera` the one Poser renders through. Options: `:server`, `:timeout`.

  ## Examples

      ExPoser.Scene.set_current_camera(aux)
      #=> {:ok, :ok}
  """
  @spec set_current_camera(Camera.t(), keyword()) :: {:ok, :ok} | {:error, Error.t()}
  def set_current_camera(%Camera{} = camera, opts \\ []) do
    with {:ok, [_]} <-
           Batch.new()
           |> Batch.call(:scene, "SetCurrentCamera", [camera])
           |> Batch.run(run_opts(opts)),
         do: {:ok, :ok}
  end

  @doc group: "Lights and cameras"
  @doc """
  Like `set_current_camera/2`, but returns `:ok` and raises `ExPoser.Error` on failure.

  ## Examples

      ExPoser.Scene.set_current_camera!(aux)
      #=> :ok
  """
  @spec set_current_camera!(Camera.t(), keyword()) :: :ok
  def set_current_camera!(camera, opts \\ []),
    do: camera |> set_current_camera(opts) |> Ref.unwrap!()

  @doc group: "Timeline"
  @doc """
  Moves the scene to frame `n` (GUI frame `n + 1`), as the GUI's frame slider
  does. The move is deliberate and stays: unlike the `:frame` option, nothing
  moves it back. Options: `:server`, `:timeout`.

  ## Examples

      ExPoser.Scene.set_frame(11)   # GUI frame 12
      #=> {:ok, nil}
  """
  @spec set_frame(non_neg_integer(), keyword()) :: {:ok, term()} | {:error, Error.t()}
  def set_frame(n, opts \\ []) when is_integer(n), do: scene_call("SetFrame", [n], opts)

  @doc group: "Timeline"
  @doc """
  Like `set_frame/2`, but returns the result and raises `ExPoser.Error` on failure.

  ## Examples

      ExPoser.Scene.set_frame!(11)
      #=> nil
  """
  @spec set_frame!(non_neg_integer(), keyword()) :: term()
  def set_frame!(n, opts \\ []), do: n |> set_frame(opts) |> Ref.unwrap!()

  defp build_actor(row), do: %Actor{figure: nil, internal: row["InternalName"], name: row["Name"]}

  defp build_camera(row), do: %Camera{actor: build_actor(row)}

  defp build_figure(row), do: %Figure{internal: row["InternalName"], name: row["Name"]}

  defp build_light(row), do: %Light{actor: build_actor(row)}

  # Poser reports IsCamera and IsLight as 0/1; the fake may send a boolean.
  defp camera?(%{"IsCamera" => v}), do: v not in [0, false, nil]

  defp light?(%{"IsLight" => v}), do: v not in [0, false, nil]

  defp release(results, opts) do
    case Codec.handles_in(results) do
      [] -> :ok
      handles -> Client.release(handles, opts)
    end
  end

  defp run_opts(opts), do: Keyword.validate!(opts, [:server, :timeout])

  defp scene_call(method, args, opts) do
    with {:ok, [v]} <-
           Batch.new() |> Batch.call(:scene, method, args) |> Batch.run(run_opts(opts)),
         do: {:ok, v}
  end

  # Poser reports IsBodyPart as 0/1; the fake may send a boolean.
  defp scene_level?(%{"IsBodyPart" => v}), do: v in [0, false, nil]
end
