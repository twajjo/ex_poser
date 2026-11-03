defmodule Poser.Ref do
  @moduledoc """
  Internal: compiles name-path structs into wire batch ops.

  A ref is `:scene` or a `Poser.Figure`, `Poser.Actor` or `Poser.Parameter`.
  Its path is a list of internal-name steps, never a live handle.

      iex> Poser.Ref.path(%Poser.Figure{internal: "figure 1", name: "Andy"})
      [figure: "figure 1"]
  """

  alias Poser.{Actor, Figure, Parameter}

  @type ref :: :scene | Figure.t() | Actor.t() | Parameter.t()
  @type step :: {:figure, String.t()} | {:actor, String.t()} | {:parm, String.t()}

  @doc "The internal-name path from the scene to `ref`. `:scene` gives `[]`."
  @spec path(ref()) :: [step()]
  def path(:scene), do: []
  def path(%Figure{internal: internal}), do: [{:figure, internal}]
  def path(%Actor{figure: nil, internal: internal}), do: [{:actor, internal}]
  def path(%Actor{figure: figure, internal: internal}), do: path(figure) ++ [{:actor, internal}]
  def path(%Parameter{actor: actor, internal: internal}), do: path(actor) ++ [{:parm, internal}]

  @doc false
  @spec path_string(ref()) :: String.t()
  def path_string(ref), do: ref |> path() |> Enum.map_join("/", &elem(&1, 1))

  @doc false
  # `scope` says what the parent is (`:scene` or `:figure`); the method is the
  # same either way, only the parent result differs.
  @spec lookup_op(step(), {:result, non_neg_integer()}, :scene | :figure) :: tuple()
  def lookup_op({:figure, internal}, parent, _scope),
    do: {:invoke, parent, "FigureByInternalName", [internal]}

  def lookup_op({:actor, internal}, parent, scope) when scope in [:scene, :figure],
    do: {:invoke, parent, "ActorByInternalName", [internal]}

  def lookup_op({:parm, internal}, parent, _scope),
    do: {:invoke, parent, "InternalParameter", [internal]}

  @doc false
  @spec unwrap!({:ok, v} | {:error, Exception.t()}) :: v when v: term()
  def unwrap!({:ok, value}), do: value
  def unwrap!({:error, error}), do: raise(error)
end
