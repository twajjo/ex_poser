defmodule Poser.Figure do
  @moduledoc """
  A Poser figure, as listed in the GUI's figure menu (e.g. "Figure 1").

  `internal` is the key; `name` is the GUI label and can be renamed or repeated.
  The struct is plain data and never holds a live handle.

      iex> inspect(%Poser.Figure{internal: "figure 1", name: "Andy"})
      "#Poser.Figure<figure 1>"
  """

  @enforce_keys [:internal, :name]
  defstruct [:internal, :name]

  @type t :: %__MODULE__{internal: String.t(), name: String.t()}

  alias Poser.{Actor, Batch, Error, Parameter, Ref}

  @doc group: "Lookup"
  @doc """
  Lists the figure's body parts, in Poser's order. Props, cameras and lights
  belong to the scene, not the figure; see `Poser.Scene.actors/1`.
  Options: `:server`, `:timeout`.

  ## Examples

      Poser.Figure.actors(figure)
      #=> {:ok, [#Poser.Actor<figure 1/hip>, ...]}
  """
  @spec actors(t(), keyword()) :: {:ok, [Actor.t()]} | {:error, Error.t()}
  def actors(%__MODULE__{} = f, opts \\ []) do
    opts = run_opts(opts)

    with {:ok, rows} <- Ref.children(f, "Actors", [], opts),
         do: {:ok, Enum.map(rows, &build(f, &1))}
  end

  @doc group: "Lookup"
  @doc """
  Like `actors/2`, but returns the list and raises `Poser.Error` on failure.

  ## Examples

      Poser.Figure.actors!(figure)
      #=> [#Poser.Actor<figure 1/hip>, ...]
  """
  @spec actors!(t(), keyword()) :: [Actor.t()]
  def actors!(f, opts \\ []), do: f |> actors(opts) |> Ref.unwrap!()

  @doc group: "Lookup"
  @doc """
  Finds a body part by internal name (`"hip"`) or by display name (`"Hip"`).

  The internal name is tried first and costs one round trip, and a hit always
  wins. A display name costs two more and can match several parts, which gives
  `:ambiguous` with the candidates under `details.matches`. No match gives
  `:not_found`. Options: `:server`, `:timeout`.

  ## Examples

      Poser.Figure.actor(figure, "hip")
      #=> {:ok, #Poser.Actor<figure 1/hip>}
      Poser.Figure.actor(figure, "nope")
      #=> {:error, %Poser.Error{kind: :not_found, ...}}
  """
  @spec actor(t(), String.t(), keyword()) :: {:ok, Actor.t()} | {:error, Error.t()}
  def actor(%__MODULE__{} = f, name, opts \\ []) when is_binary(name) do
    opts = run_opts(opts)
    guess = %Actor{figure: f, internal: name, name: name}
    Ref.lookup(guess, f, "Actors", name, &build(f, &1), opts)
  end

  @doc group: "Lookup"
  @doc """
  Like `actor/3`, but returns the struct and raises `Poser.Error` on failure.

  ## Examples

      Poser.Figure.actor!(figure, "hip")
      #=> #Poser.Actor<figure 1/hip>
  """
  @spec actor!(t(), String.t(), keyword()) :: Actor.t()
  def actor!(f, name, opts \\ []), do: f |> actor(name, opts) |> Ref.unwrap!()

  @doc group: "Lookup"
  @doc """
  Finds a dial on one of the figure's body parts, each by internal or display
  name; see `actor/3` and `Poser.Actor.parameter/3`. Options: `:server`, `:timeout`.

  ## Examples

      Poser.Figure.parameter(figure, "hip", "xtran")
      #=> {:ok, #Poser.Parameter<figure 1/hip/xtran>}
  """
  @spec parameter(t(), String.t(), String.t(), keyword()) ::
          {:ok, Parameter.t()} | {:error, Error.t()}
  def parameter(%__MODULE__{} = f, actor_name, parm_name, opts \\ [])
      when is_binary(actor_name) and is_binary(parm_name) do
    opts = run_opts(opts)
    with {:ok, a} <- actor(f, actor_name, opts), do: Actor.parameter(a, parm_name, opts)
  end

  @doc group: "Lookup"
  @doc """
  Like `parameter/4`, but returns the struct and raises `Poser.Error` on failure.

  ## Examples

      Poser.Figure.parameter!(figure, "hip", "xtran")
      #=> #Poser.Parameter<figure 1/hip/xtran>
  """
  @spec parameter!(t(), String.t(), String.t(), keyword()) :: Parameter.t()
  def parameter!(f, actor_name, parm_name, opts \\ []),
    do: f |> parameter(actor_name, parm_name, opts) |> Ref.unwrap!()

  @doc group: "Escape hatch"
  @doc """
  The figure's `%Poser.Handle{}`, for calls this library doesn't wrap.

  The handle belongs to the caller: release it with `Poser.Client.release/2`.
  Options: `:server`, `:timeout`.

  ## Examples

      {:ok, h} = Poser.Figure.handle(figure)
      Poser.Client.invoke(h, "Name")
      #=> {:ok, "Figure 1"}
      Poser.Client.release([h])
  """
  @spec handle(t(), keyword()) :: {:ok, Poser.Handle.t()} | {:error, Error.t()}
  def handle(%__MODULE__{} = f, opts \\ []) do
    Batch.new()
    |> Batch.call(f, "InternalName", [])
    |> Batch.call(:scene, "FigureByInternalName", [f.internal])
    |> Batch.run(run_opts(opts))
    |> Actor.to_handle(f)
  end

  @doc group: "Escape hatch"
  @doc """
  Like `handle/2`, but returns the handle and raises `Poser.Error` on failure.

  ## Examples

      h = Poser.Figure.handle!(figure)
      Poser.Client.release([h])
  """
  @spec handle!(t(), keyword()) :: Poser.Handle.t()
  def handle!(f, opts \\ []), do: f |> handle(opts) |> Ref.unwrap!()

  defp build(f, row), do: %Actor{figure: f, internal: row["InternalName"], name: row["Name"]}

  defp run_opts(opts), do: Keyword.validate!(opts, [:server, :timeout])

  defimpl Inspect do
    def inspect(%{internal: internal}, _opts), do: "#Poser.Figure<#{internal}>"
  end
end
