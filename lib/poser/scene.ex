defmodule Poser.Scene do
  @moduledoc """
  The open Poser scene: its timeline, its figures, and its own props,
  cameras and lights.

  Poser has one scene per session, so nothing here takes a scene value. It
  also has one global current frame, which PoserPython reads and writes
  dials at. Here the `frame:` option of `Poser.Parameter` and `Poser.Batch`
  takes its place: it moves Poser to a frame for one request and moves it
  back. `set_frame/2` is the only function that moves the timeline and
  leaves it there.

  Frames count from 0, as in PoserPython: `frame: 0` is GUI frame 1.

  ## Common tasks

      {:ok, figs} = Poser.Scene.figures()
      {:ok, fig} = Poser.Scene.figure("Figure 1")   # internal or display name
      {:ok, ball} = Poser.Scene.actor("ball")       # props, cameras, lights
      {:ok, n} = Poser.Scene.num_frames()           # frames 0..n-1, GUI 1..n

  Body parts are not scene-level actors: `actors/1` and `actor/2` never
  return them. Find them through their figure with `Poser.Figure.actors/2`
  and `Poser.Figure.actor/3`.

  See [Posing](posing.md) and [Frames and keyframes](frames-and-keyframes.md).
  """

  alias Poser.{Actor, Batch, Error, Figure, Ref}

  @doc group: "Lookup"
  @doc """
  Finds a scene-level actor by internal name (`"ball"`) or by display name
  (`"Ball"`), with the same rules as `figure/2`. Body parts are not found
  here; look them up through their figure. Options: `:server`, `:timeout`.

  ## Examples

      Poser.Scene.actor("ball")
      #=> {:ok, #Poser.Actor<ball>}
      Poser.Scene.actor("Ball")
      #=> {:ok, #Poser.Actor<ball>}
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
  Like `actor/2`, but returns the struct and raises `Poser.Error` on failure.

  ## Examples

      Poser.Scene.actor!("ball")
      #=> #Poser.Actor<ball>
  """
  @spec actor!(String.t(), keyword()) :: Actor.t()
  def actor!(name, opts \\ []), do: name |> actor(opts) |> Ref.unwrap!()

  @doc group: "Lookup"
  @doc """
  Lists the scene's own actors: props, cameras and lights, but no body parts
  (those come from `Poser.Figure.actors/2`). They have `figure: nil`.
  Options: `:server`, `:timeout`.

  ## Examples

      Poser.Scene.actors()
      #=> {:ok, [#Poser.Actor<ball>]}
  """
  @spec actors(keyword()) :: {:ok, [Actor.t()]} | {:error, Error.t()}
  def actors(opts \\ []) do
    opts = run_opts(opts)

    with {:ok, rows} <- Ref.children(:scene, "Actors", ["IsBodyPart"], opts),
         do: {:ok, rows |> Enum.filter(&scene_level?/1) |> Enum.map(&build_actor/1)}
  end

  @doc group: "Lookup"
  @doc """
  Like `actors/1`, but returns the list and raises `Poser.Error` on failure.

  ## Examples

      Poser.Scene.actors!()
      #=> [#Poser.Actor<ball>]
  """
  @spec actors!(keyword()) :: [Actor.t()]
  def actors!(opts \\ []), do: opts |> actors() |> Ref.unwrap!()

  @doc group: "Lookup"
  @doc """
  Finds a figure by internal name (`"figure 1"`) or by display name.

  The internal name is tried first and a hit always wins, even when another
  figure shares that text as its display name. Display names repeat freely
  (two figures can both be "Figure 1"), which gives `:ambiguous` with the
  candidates under `details.matches`. No match gives `:not_found`.
  Options: `:server`, `:timeout`.

  ## Examples

      Poser.Scene.figure("figure 2")
      #=> {:ok, #Poser.Figure<figure 2>}
      Poser.Scene.figure("Figure 1")
      #=> {:error, %Poser.Error{kind: :ambiguous, ...}}
  """
  @spec figure(String.t(), keyword()) :: {:ok, Figure.t()} | {:error, Error.t()}
  def figure(name, opts \\ []) when is_binary(name) do
    opts = run_opts(opts)
    guess = %Figure{internal: name, name: name}
    Ref.lookup(guess, :scene, "Figures", name, &build_figure/1, opts)
  end

  @doc group: "Lookup"
  @doc """
  Like `figure/2`, but returns the struct and raises `Poser.Error` on failure.

  ## Examples

      Poser.Scene.figure!("figure 2")
      #=> #Poser.Figure<figure 2>
  """
  @spec figure!(String.t(), keyword()) :: Figure.t()
  def figure!(name, opts \\ []), do: name |> figure(opts) |> Ref.unwrap!()

  @doc group: "Lookup"
  @doc """
  Lists the scene's figures, in Poser's order. Options: `:server`, `:timeout`.

  ## Examples

      Poser.Scene.figures()
      #=> {:ok, [#Poser.Figure<figure 1>, #Poser.Figure<figure 2>]}
  """
  @spec figures(keyword()) :: {:ok, [Figure.t()]} | {:error, Error.t()}
  def figures(opts \\ []) do
    opts = run_opts(opts)

    with {:ok, rows} <- Ref.children(:scene, "Figures", [], opts),
         do: {:ok, Enum.map(rows, &build_figure/1)}
  end

  @doc group: "Lookup"
  @doc """
  Like `figures/1`, but returns the list and raises `Poser.Error` on failure.

  ## Examples

      Poser.Scene.figures!()
      #=> [#Poser.Figure<figure 1>, #Poser.Figure<figure 2>]
  """
  @spec figures!(keyword()) :: [Figure.t()]
  def figures!(opts \\ []), do: opts |> figures() |> Ref.unwrap!()

  @doc group: "Timeline"
  @doc """
  Playback rate in frames per second. Options: `:server`, `:timeout`.

  ## Examples

      Poser.Scene.fps()
      #=> {:ok, 30}
  """
  @spec fps(keyword()) :: {:ok, number()} | {:error, Error.t()}
  def fps(opts \\ []), do: scene_call("FramesPerSecond", [], opts)

  @doc group: "Timeline"
  @doc """
  Like `fps/1`, but returns the rate and raises `Poser.Error` on failure.

  ## Examples

      Poser.Scene.fps!()
      #=> 30
  """
  @spec fps!(keyword()) :: number()
  def fps!(opts \\ []), do: opts |> fps() |> Ref.unwrap!()

  @doc group: "Timeline"
  @doc """
  The current frame, counting from 0: `0` is GUI frame 1. Options: `:server`, `:timeout`.

  ## Examples

      Poser.Scene.frame()
      #=> {:ok, 0}
  """
  @spec frame(keyword()) :: {:ok, non_neg_integer()} | {:error, Error.t()}
  def frame(opts \\ []), do: scene_call("Frame", [], opts)

  @doc group: "Timeline"
  @doc """
  Like `frame/1`, but returns the frame and raises `Poser.Error` on failure.

  ## Examples

      Poser.Scene.frame!()
      #=> 0
  """
  @spec frame!(keyword()) :: non_neg_integer()
  def frame!(opts \\ []), do: opts |> frame() |> Ref.unwrap!()

  @doc group: "Timeline"
  @doc """
  How many frames the timeline has. The last is `num_frames - 1` (GUI frame
  `num_frames`). Options: `:server`, `:timeout`.

  ## Examples

      Poser.Scene.num_frames()
      #=> {:ok, 30}
  """
  @spec num_frames(keyword()) :: {:ok, pos_integer()} | {:error, Error.t()}
  def num_frames(opts \\ []), do: scene_call("NumFrames", [], opts)

  @doc group: "Timeline"
  @doc """
  Like `num_frames/1`, but returns the count and raises `Poser.Error` on failure.

  ## Examples

      Poser.Scene.num_frames!()
      #=> 30
  """
  @spec num_frames!(keyword()) :: pos_integer()
  def num_frames!(opts \\ []), do: opts |> num_frames() |> Ref.unwrap!()

  @doc group: "Timeline"
  @doc """
  Moves the scene to frame `n` (GUI frame `n + 1`), as the GUI's frame slider
  does. The move is deliberate and stays: unlike the `:frame` option, nothing
  moves it back. Options: `:server`, `:timeout`.

  ## Examples

      Poser.Scene.set_frame(11)   # GUI frame 12
      #=> {:ok, nil}
  """
  @spec set_frame(non_neg_integer(), keyword()) :: {:ok, term()} | {:error, Error.t()}
  def set_frame(n, opts \\ []) when is_integer(n), do: scene_call("SetFrame", [n], opts)

  @doc group: "Timeline"
  @doc """
  Like `set_frame/2`, but returns the result and raises `Poser.Error` on failure.

  ## Examples

      Poser.Scene.set_frame!(11)
      #=> nil
  """
  @spec set_frame!(non_neg_integer(), keyword()) :: term()
  def set_frame!(n, opts \\ []), do: n |> set_frame(opts) |> Ref.unwrap!()

  defp build_actor(row), do: %Actor{figure: nil, internal: row["InternalName"], name: row["Name"]}

  defp build_figure(row), do: %Figure{internal: row["InternalName"], name: row["Name"]}

  defp run_opts(opts), do: Keyword.validate!(opts, [:server, :timeout])

  defp scene_call(method, args, opts) do
    with {:ok, [v]} <-
           Batch.new() |> Batch.call(:scene, method, args) |> Batch.run(run_opts(opts)),
         do: {:ok, v}
  end

  # Poser reports IsBodyPart as 0/1; the fake may send a boolean.
  defp scene_level?(%{"IsBodyPart" => v}), do: v in [0, false, nil]
end
