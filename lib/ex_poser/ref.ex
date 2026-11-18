defmodule ExPoser.Ref do
  @moduledoc """
  Internal: compiles name-path structs into wire batch ops.

  A ref is `:scene` or an `ExPoser.Figure`, `ExPoser.Actor`, `ExPoser.Light`,
  `ExPoser.Camera`, `ExPoser.Parameter`, `ExPoser.Material`,
  `ExPoser.MaterialLayer`, `ExPoser.ShaderTree`, `ExPoser.ShaderNode`,
  `ExPoser.ShaderInput` or `ExPoser.ShaderOutput`.
  Its path is a list of internal-name steps, never a live handle.

      iex> ExPoser.Ref.path(%ExPoser.Figure{internal: "figure 1", name: "Andy"})
      [figure: "figure 1"]
  """

  alias ExPoser.{
    Actor,
    Camera,
    Figure,
    Light,
    Material,
    MaterialLayer,
    Parameter,
    ShaderInput,
    ShaderNode,
    ShaderOutput,
    ShaderTree
  }

  @type ref ::
          :scene
          | Figure.t()
          | Actor.t()
          | Light.t()
          | Camera.t()
          | Parameter.t()
          | Material.t()
          | MaterialLayer.t()
          | ShaderTree.t()
          | ShaderNode.t()
          | ShaderInput.t()
          | ShaderOutput.t()
  @type step ::
          {:figure, String.t()}
          | {:actor, String.t()}
          | {:parm, String.t()}
          | {:material, String.t()}
          | {:layer, String.t()}
          | {:tree, :main | :atmosphere | :background}
          | {:node, ShaderNode.internal()}
          | {:input, String.t()}
          | {:output, String.t()}

  @doc false
  # Lists `parent`'s children with `list_method` (one request), then reads
  # `InternalName`, `Name` and each `extra` method on every child (a second).
  # Every child handle is released, on success and on failure.
  @spec children(ref(), String.t(), [String.t()], keyword()) ::
          {:ok, [%{String.t() => term()}]} | {:error, ExPoser.Error.t()}
  def children(parent, list_method, extra, opts) do
    with {:ok, [rows]} <- children_many([parent], list_method, extra, opts) do
      {:ok, rows}
    end
  end

  @doc false
  # Like `children/4` for many parents, still in two requests: one lists every
  # parent's children, one reads every child. Gives one row list per parent, in
  # the order of `parents`; a parent without children gets `[]`. No parents,
  # no request.
  @spec children_many([ref()], String.t(), [String.t()], keyword()) ::
          {:ok, [[%{String.t() => term()}]]} | {:error, ExPoser.Error.t()}
  def children_many(parents, list_method, extra, opts),
    do: list(parents, list_method, ["InternalName", "Name" | extra], opts)

  @doc false
  # The handle of `ref`, which `parent` hands out with `method(args)`. The first
  # op, `probe` on `ref`, makes a missing `ref` :not_found with its path; a ref
  # can't hand out its own handle.
  @spec fetch_handle(ref(), String.t(), ref(), String.t(), list(), keyword()) ::
          {:ok, ExPoser.Handle.t()} | {:error, ExPoser.Error.t()}
  def fetch_handle(ref, probe, parent, method, args, opts) do
    opts = Keyword.validate!(opts, [:server, :timeout])

    batch =
      ExPoser.Batch.new()
      |> ExPoser.Batch.call(ref, probe, [])
      |> ExPoser.Batch.call(parent, method, args)

    batch |> ExPoser.Batch.run(opts) |> Actor.to_handle(ref)
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
  # Like `children_many/4` with the full `methods` list given: for children that
  # have no `InternalName`, such as materials and layers. Two requests: one lists
  # every parent's children, one reads `methods` on every child. No parents, no
  # request.
  @spec list([ref()], String.t(), [String.t()], keyword()) ::
          {:ok, [[%{String.t() => term()}]]} | {:error, ExPoser.Error.t()}
  def list([], _list_method, _methods, _opts), do: {:ok, []}

  def list(parents, list_method, methods, opts) do
    batch =
      Enum.reduce(parents, ExPoser.Batch.new(), &ExPoser.Batch.call(&2, &1, list_method, []))

    with {:ok, handle_lists} <- ExPoser.Batch.run(batch, opts) do
      try do
        with {:ok, rows} <- read_children(Enum.concat(handle_lists), methods, opts) do
          {:ok, regroup(rows, Enum.map(handle_lists, &length/1))}
        end
      after
        release_in(handle_lists, opts)
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

  def lookup_op({:material, name}, parent, _scope), do: {:invoke, parent, "Material", [name]}
  def lookup_op({:layer, name}, parent, _scope), do: {:invoke, parent, "LayerByName", [name]}
  def lookup_op({:tree, :main}, parent, _scope), do: {:invoke, parent, "ShaderTree", []}

  def lookup_op({:tree, :atmosphere}, parent, _scope),
    do: {:invoke, parent, "AtmosphereShaderTree", []}

  def lookup_op({:tree, :background}, parent, _scope),
    do: {:invoke, parent, "BackgroundShaderTree", []}

  def lookup_op({:node, {:created, k}}, parent, _scope),
    do: {:invoke, parent, "NodeByInternalName", [{:created_name, k}]}

  def lookup_op({:node, internal}, parent, _scope),
    do: {:invoke, parent, "NodeByInternalName", [internal]}

  def lookup_op({:input, internal}, parent, _scope),
    do: {:invoke, parent, "InputByInternalName", [internal]}

  def lookup_op({:output, internal}, parent, _scope),
    do: {:invoke, parent, "OutputByInternalName", [internal]}

  @doc "The internal-name path from the scene to `ref`. `:scene` gives `[]`."
  @spec path(ref()) :: [step()]
  def path(:scene), do: []
  def path(%Figure{internal: internal}), do: [{:figure, internal}]
  def path(%Actor{figure: nil, internal: internal}), do: [{:actor, internal}]
  def path(%Actor{figure: figure, internal: internal}), do: path(figure) ++ [{:actor, internal}]
  def path(%Light{actor: actor}), do: path(actor)
  def path(%Camera{actor: actor}), do: path(actor)
  def path(%Parameter{actor: actor, internal: internal}), do: path(actor) ++ [{:parm, internal}]
  def path(%Material{owner: owner, name: name}), do: path(owner) ++ [{:material, name}]
  def path(%MaterialLayer{material: material, name: name}), do: path(material) ++ [{:layer, name}]
  def path(%ShaderTree{owner: :atmosphere}), do: [{:tree, :atmosphere}]
  def path(%ShaderTree{owner: :background}), do: [{:tree, :background}]
  def path(%ShaderTree{owner: owner}), do: path(owner) ++ [{:tree, :main}]
  def path(%ShaderNode{tree: tree, internal: internal}), do: path(tree) ++ [{:node, internal}]
  def path(%ShaderInput{node: node, internal: internal}), do: path(node) ++ [{:input, internal}]
  def path(%ShaderOutput{node: node, internal: internal}), do: path(node) ++ [{:output, internal}]

  @doc false
  @spec path_string(ref()) :: String.t()
  def path_string(ref), do: ref |> path() |> Enum.map_join("/", &elem(&1, 1))

  @doc false
  # Reads each of `methods` on every handle, in one request, and releases the
  # handles the reads return. The caller still owns `handles`. One row per handle.
  @spec read_children([ExPoser.Handle.t()], [String.t()], keyword()) ::
          {:ok, [%{String.t() => term()}]} | {:error, ExPoser.Error.t()}
  def read_children([], _methods, _opts), do: {:ok, []}

  def read_children(handles, methods, opts) do
    ops = for h <- handles, m <- methods, do: {:invoke, h, m, []}

    case ExPoser.Client.batch(ops, Keyword.take(opts, [:server, :timeout])) do
      {:ok, results} ->
        release_in(results, opts)

        {:ok,
         results |> Enum.chunk_every(length(methods)) |> Enum.map(&Map.new(Enum.zip(methods, &1)))}

      {:error, %ExPoser.Error{kind: :batch_failed, details: %{partial: partial}} = error} ->
        release_in(partial, opts)
        {:error, error}

      {:error, _} = error ->
        error
    end
  end

  @doc "True for the structs that name a Poser object: figure, actor, light, camera, parameter, material, layer, shader tree, node, input and output."
  @spec ref?(term()) :: boolean()
  def ref?(%Figure{}), do: true
  def ref?(%Actor{}), do: true
  def ref?(%Light{}), do: true
  def ref?(%Camera{}), do: true
  def ref?(%Parameter{}), do: true
  def ref?(%Material{}), do: true
  def ref?(%MaterialLayer{}), do: true
  def ref?(%ShaderTree{}), do: true
  def ref?(%ShaderNode{}), do: true
  def ref?(%ShaderInput{}), do: true
  def ref?(%ShaderOutput{}), do: true
  def ref?(_other), do: false

  @doc false
  # Releases the handles found anywhere in `term`, a batch result or its partial.
  @spec release_in(term(), keyword()) :: :ok | {:error, ExPoser.Error.t()}
  def release_in(term, opts) do
    case ExPoser.Codec.handles_in(term) do
      [] -> :ok
      handles -> ExPoser.Client.release(handles, Keyword.take(opts, [:server, :timeout]))
    end
  end

  @doc false
  @spec unwrap!({:ok, v} | {:error, Exception.t()}) :: v when v: term()
  def unwrap!({:ok, value}), do: value
  def unwrap!({:error, error}), do: raise(error)

  # The default `keep`: every row counts.
  defp keep_all(_row), do: true

  defp regroup(rows, sizes) do
    {groups, []} =
      Enum.map_reduce(sizes, rows, fn size, rest ->
        Enum.split(rest, size)
      end)

    groups
  end
end
