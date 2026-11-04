defmodule Poser.Scene do
  @moduledoc """
  The open Poser scene: its timeline, its figures and its loose actors.

  There is one scene per Poser session, so nothing here takes a scene value.
  Frames start at 0. Figures hold body parts (`Poser.Figure.actors/2`); the
  actors listed here are the scene's own props, cameras and lights.
  """

  alias Poser.{Actor, Batch, Error, Figure, Ref}

  @doc group: "Timeline"
  @doc """
  The current frame, counting from 0. Options: `:server`, `:timeout`.

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
  Moves the scene to frame `n`. The move is deliberate and stays: unlike the
  `:frame` option of `Poser.Batch`, nothing moves it back. Options:
  `:server`, `:timeout`.

  ## Examples

      Poser.Scene.set_frame(12)
      #=> {:ok, nil}
  """
  @spec set_frame(non_neg_integer(), keyword()) :: {:ok, term()} | {:error, Error.t()}
  def set_frame(n, opts \\ []) when is_integer(n), do: scene_call("SetFrame", [n], opts)

  @doc group: "Timeline"
  @doc """
  Like `set_frame/2`, but returns the result and raises `Poser.Error` on failure.

  ## Examples

      Poser.Scene.set_frame!(12)
      #=> nil
  """
  @spec set_frame!(non_neg_integer(), keyword()) :: term()
  def set_frame!(n, opts \\ []), do: n |> set_frame(opts) |> Ref.unwrap!()

  @doc group: "Timeline"
  @doc """
  How many frames the timeline has. Options: `:server`, `:timeout`.

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

    case Batch.new()
         |> Batch.call(guess, "InternalName", [])
         |> Batch.call(guess, "Name", [])
         |> Batch.run(opts) do
      {:ok, [internal, display]} ->
        {:ok, %Figure{internal: internal, name: display}}

      {:error, %Error{kind: :not_found, details: %{path: path}}} ->
        if path == Ref.path(guess),
          do: Ref.find(:scene, "Figures", name, &build_figure/1, opts),
          else: {:error, Error.not_found(path)}

      {:error, _} = error ->
        error
    end
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
         do: {:ok, rows |> Enum.reject(&body_part?/1) |> Enum.map(&build_actor/1)}
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

    case Batch.new()
         |> Batch.call(guess, "InternalName", [])
         |> Batch.call(guess, "Name", [])
         |> Batch.call(guess, "IsBodyPart", [])
         |> Batch.run(opts) do
      {:ok, [internal, display, body_part]} ->
        if body_part?(%{"IsBodyPart" => body_part}),
          do: {:error, Error.not_found(Ref.path(guess))},
          else: {:ok, %Actor{figure: nil, internal: internal, name: display}}

      {:error, %Error{kind: :not_found, details: %{path: path}}} ->
        if path == Ref.path(guess),
          do: find_by_name(name, opts),
          else: {:error, Error.not_found(path)}

      {:error, _} = error ->
        error
    end
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

  defp find_by_name(name, opts) do
    with {:ok, actors} <- actors(opts) do
      case Enum.filter(actors, &(&1.name == name)) do
        [a] -> {:ok, a}
        [] -> {:error, Error.not_found([{:name, name}])}
        many -> {:error, %Error{kind: :ambiguous, details: %{matches: many}}}
      end
    end
  end

  defp scene_call(method, args, opts) do
    with {:ok, [v]} <-
           Batch.new() |> Batch.call(:scene, method, args) |> Batch.run(run_opts(opts)),
         do: {:ok, v}
  end

  # Poser reports IsBodyPart as 0/1; the fake may send a boolean.
  defp body_part?(%{"IsBodyPart" => v}), do: v not in [0, false, nil]

  defp build_figure(row), do: %Figure{internal: row["InternalName"], name: row["Name"]}

  defp build_actor(row), do: %Actor{figure: nil, internal: row["InternalName"], name: row["Name"]}

  defp run_opts(opts), do: Keyword.validate!(opts, [:server, :timeout])
end
