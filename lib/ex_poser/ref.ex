defmodule ExPoser.Ref do
  @moduledoc """
  Internal: compiles name-path structs into wire batch ops.

  A ref is `:scene` or a `ExPoser.Figure`, `ExPoser.Actor` or `ExPoser.Parameter`.
  Its path is a list of internal-name steps, never a live handle.

      iex> ExPoser.Ref.path(%ExPoser.Figure{internal: "figure 1", name: "Andy"})
      [figure: "figure 1"]
  """

  alias ExPoser.{Actor, Figure, Parameter}

  @type ref :: :scene | Figure.t() | Actor.t() | Parameter.t()
  @type step :: {:figure, String.t()} | {:actor, String.t()} | {:parm, String.t()}

  @doc false
  # Lists `parent`'s children with `list_method` (one request), then reads
  # `InternalName`, `Name` and each `extra` method on every child (a second).
  # Every child handle is released, on success and on failure.
  @spec children(ref(), String.t(), [String.t()], keyword()) ::
          {:ok, [%{String.t() => term()}]} | {:error, ExPoser.Error.t()}
  def children(parent, list_method, extra, opts) do
    methods = ["InternalName", "Name" | extra]
    batch = ExPoser.Batch.new() |> ExPoser.Batch.call(parent, list_method, [])

    with {:ok, [handles]} <- ExPoser.Batch.run(batch, opts) do
      try do
        read_children(handles, methods, opts)
      after
        release(handles, opts)
      end
    end
  end

  @doc false
  # Finds the child of `parent` whose display name is `name`. `extra` methods are
  # read into each row; rows for which `keep` is false are ignored.
  @spec find(
          ref(),
          String.t(),
          String.t(),
          (map() -> struct()),
          keyword(),
          [String.t()],
          (map() -> boolean())
        ) ::
          {:ok, struct()} | {:error, ExPoser.Error.t()}
  def find(parent, list_method, name, build, opts, extra \\ [], keep \\ &keep_all/1) do
    with {:ok, rows} <- children(parent, list_method, extra, opts) do
      case Enum.filter(rows, &(keep.(&1) and &1["Name"] == name)) do
        [row] ->
          {:ok, build.(row)}

        [] ->
          {:error, ExPoser.Error.not_found(path(parent) ++ [{:name, name}])}

        rows ->
          {:error, %ExPoser.Error{kind: :ambiguous, details: %{matches: Enum.map(rows, build)}}}
      end
    end
  end

  @doc false
  # Resolves `name` under `parent`: first as an internal name (one round trip, via
  # `guess`, a ref built from `name`), then as a display name with `find/7`. A
  # not_found for any other path means a missing ancestor, which is reported as is.
  # `build` takes a row with "InternalName", "Name" and the `extra` methods; a hit
  # that `keep` rejects is not_found.
  @spec lookup(
          ref(),
          ref(),
          String.t(),
          String.t(),
          (map() -> struct()),
          keyword(),
          [String.t()],
          (map() -> boolean())
        ) ::
          {:ok, struct()} | {:error, ExPoser.Error.t()}
  def lookup(guess, parent, list_method, name, build, opts, extra \\ [], keep \\ &keep_all/1) do
    methods = ["InternalName", "Name" | extra]
    batch = Enum.reduce(methods, ExPoser.Batch.new(), &ExPoser.Batch.call(&2, guess, &1, []))

    case ExPoser.Batch.run(batch, opts) do
      {:ok, values} ->
        row = Map.new(Enum.zip(methods, values))

        if keep.(row),
          do: {:ok, build.(row)},
          else: {:error, ExPoser.Error.not_found(path(guess))}

      {:error, %ExPoser.Error{kind: :not_found, details: %{path: path}}} ->
        if path == path(guess),
          do: find(parent, list_method, name, build, opts, extra, keep),
          else: {:error, ExPoser.Error.not_found(path)}

      {:error, _} = error ->
        error
    end
  end

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

  @doc "True for the structs that name a Poser object: a figure, actor or parameter."
  @spec ref?(term()) :: boolean()
  def ref?(%Figure{}), do: true
  def ref?(%Actor{}), do: true
  def ref?(%Parameter{}), do: true
  def ref?(_other), do: false

  @doc false
  @spec unwrap!({:ok, v} | {:error, Exception.t()}) :: v when v: term()
  def unwrap!({:ok, value}), do: value
  def unwrap!({:error, error}), do: raise(error)

  # The default `keep`: every row counts.
  defp keep_all(_row), do: true

  defp read_children([], _methods, _opts), do: {:ok, []}

  defp read_children(handles, methods, opts) do
    ops = for h <- handles, m <- methods, do: {:invoke, h, m, []}

    case ExPoser.Client.batch(ops, Keyword.take(opts, [:server, :timeout])) do
      {:ok, results} ->
        release(ExPoser.Codec.handles_in(results), opts)

        {:ok,
         results |> Enum.chunk_every(length(methods)) |> Enum.map(&Map.new(Enum.zip(methods, &1)))}

      {:error, %ExPoser.Error{kind: :batch_failed, details: %{partial: partial}} = error} ->
        release(ExPoser.Codec.handles_in(partial), opts)
        {:error, error}

      {:error, _} = error ->
        error
    end
  end

  defp release([], _opts), do: :ok

  defp release(handles, opts),
    do: ExPoser.Client.release(handles, Keyword.take(opts, [:server, :timeout]))
end
