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

  @doc false
  # Lists `parent`'s children with `list_method` (one request), then reads
  # `InternalName`, `Name` and each `extra` method on every child (a second).
  # Every child handle is released, on success and on failure.
  @spec children(ref(), String.t(), [String.t()], keyword()) ::
          {:ok, [%{String.t() => term()}]} | {:error, Poser.Error.t()}
  def children(parent, list_method, extra, opts) do
    methods = ["InternalName", "Name" | extra]
    batch = Poser.Batch.new() |> Poser.Batch.call(parent, list_method, [])

    with {:ok, [handles]} <- Poser.Batch.run(batch, opts) do
      try do
        read_children(handles, methods, opts)
      after
        release(handles, opts)
      end
    end
  end

  defp read_children([], _methods, _opts), do: {:ok, []}

  defp read_children(handles, methods, opts) do
    ops = for h <- handles, m <- methods, do: {:invoke, h, m, []}

    case Poser.Client.batch(ops, Keyword.take(opts, [:server, :timeout])) do
      {:ok, results} ->
        release(Poser.Codec.handles_in(results), opts)

        {:ok,
         results |> Enum.chunk_every(length(methods)) |> Enum.map(&Map.new(Enum.zip(methods, &1)))}

      {:error, %Poser.Error{kind: :batch_failed, details: %{partial: partial}} = error} ->
        release(Poser.Codec.handles_in(partial), opts)
        {:error, error}

      {:error, _} = error ->
        error
    end
  end

  defp release([], _opts), do: :ok

  defp release(handles, opts),
    do: Poser.Client.release(handles, Keyword.take(opts, [:server, :timeout]))

  @doc false
  # Finds the child of `parent` whose display name is `name`.
  @spec find(ref(), String.t(), String.t(), (map() -> struct()), keyword()) ::
          {:ok, struct()} | {:error, Poser.Error.t()}
  def find(parent, list_method, name, build, opts) do
    with {:ok, rows} <- children(parent, list_method, [], opts) do
      case Enum.filter(rows, &(&1["Name"] == name)) do
        [row] ->
          {:ok, build.(row)}

        [] ->
          {:error, Poser.Error.not_found(path(parent) ++ [{:name, name}])}

        rows ->
          {:error, %Poser.Error{kind: :ambiguous, details: %{matches: Enum.map(rows, build)}}}
      end
    end
  end
end
