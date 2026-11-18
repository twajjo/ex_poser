defmodule ExPoser.ShaderTree do
  @moduledoc """
  A shader tree: the main tree of a material or of a material layer, or the
  scene's atmosphere or background tree.

  `owner` is an `ExPoser.Material`, an `ExPoser.MaterialLayer`,
  `:atmosphere` or `:background`. Build one with `ExPoser.Material.tree/1`,
  `ExPoser.MaterialLayer.tree/1`, `ExPoser.Scene.atmosphere_tree/0` or
  `ExPoser.Scene.background_tree/0`.

      iex> ExPoser.Ref.path(%ExPoser.ShaderTree{owner: :background})
      [tree: :background]
      iex> prop = %ExPoser.Actor{figure: nil, internal: "ball", name: "Ball"}
      iex> skin = %ExPoser.Material{owner: prop, name: "Preview"}
      iex> ExPoser.Ref.path(%ExPoser.ShaderTree{owner: skin})
      [{:actor, "ball"}, {:material, "Preview"}, {:tree, :main}]
  """

  alias ExPoser.{Batch, Error, Material, MaterialLayer, Ref, ShaderNode}

  @enforce_keys [:owner]
  defstruct [:owner]

  @type owner :: Material.t() | MaterialLayer.t() | :atmosphere | :background
  @type t :: %__MODULE__{owner: owner()}

  # kRenderEngineCode*
  @renderers %{preview: 0, firefly: 1, poser4: 2, sketch: 3, superfly: 4}

  @doc group: "Escape hatch"
  @doc """
  The tree's `%ExPoser.Handle{}`, for calls this library doesn't wrap.
  Release it with `ExPoser.Client.release/2`. A tree that doesn't resolve
  gives `:not_found` with `details.path`. Options: `:server`, `:timeout`.

  ## Examples

      {:ok, h} = ExPoser.ShaderTree.handle(tree)
      ExPoser.Client.release([h])
  """
  @spec handle(t(), keyword()) :: {:ok, ExPoser.Handle.t()} | {:error, ExPoser.Error.t()}
  def handle(%__MODULE__{owner: owner} = tree, opts \\ []) do
    {parent, method} = parent_of(owner)
    Ref.fetch_handle(tree, "NumNodes", parent, method, [], opts)
  end

  @doc group: "Escape hatch"
  @doc """
  Like `handle/2`, but returns the handle and raises `ExPoser.Error` on failure.

  ## Examples

      h = ExPoser.ShaderTree.handle!(tree)
      ExPoser.Client.release([h])
  """
  @spec handle!(t(), keyword()) :: ExPoser.Handle.t()
  def handle!(tree, opts \\ []), do: tree |> handle(opts) |> Ref.unwrap!()

  @doc group: "Nodes"
  @doc """
  Finds a node by internal name (`"Image_Map"`) or by display name, with the
  same rules as `ExPoser.Scene.light/2`: the internal name is tried first, and
  a display name shared by several nodes gives `:ambiguous`. No match gives
  `:not_found`. Options: `:server`, `:timeout`.

  ## Examples

      ExPoser.ShaderTree.node(tree, "Image_Map")
      #=> {:ok, #ExPoser.ShaderNode<Image_Map>}
  """
  @spec node(t(), String.t(), keyword()) :: {:ok, ShaderNode.t()} | {:error, Error.t()}
  def node(%__MODULE__{} = tree, name, opts \\ []) when is_binary(name) do
    guess = %ShaderNode{tree: tree, internal: name, name: name}
    Ref.lookup(guess, tree, "Nodes", name, &build(tree, &1), run_opts(opts))
  end

  @doc group: "Nodes"
  @doc """
  Like `node/3`, but returns the struct and raises `ExPoser.Error` on failure.

  ## Examples

      ExPoser.ShaderTree.node!(tree, "Image_Map")
      #=> #ExPoser.ShaderNode<Image_Map>
  """
  @spec node!(t(), String.t(), keyword()) :: ShaderNode.t()
  def node!(tree, name, opts \\ []), do: tree |> node(name, opts) |> Ref.unwrap!()

  @doc group: "Nodes"
  @doc """
  Lists the tree's nodes, in Poser's order. Options: `:server`, `:timeout`.

  ## Examples

      ExPoser.ShaderTree.nodes(tree)
      #=> {:ok, [#ExPoser.ShaderNode<PoserSurface>, #ExPoser.ShaderNode<Image_Map>]}
  """
  @spec nodes(t(), keyword()) :: {:ok, [ShaderNode.t()]} | {:error, Error.t()}
  def nodes(%__MODULE__{} = tree, opts \\ []) do
    with {:ok, rows} <- Ref.children(tree, "Nodes", [], run_opts(opts)),
         do: {:ok, Enum.map(rows, &build(tree, &1))}
  end

  @doc group: "Nodes"
  @doc """
  Like `nodes/2`, but returns the list and raises `ExPoser.Error` on failure.

  ## Examples

      ExPoser.ShaderTree.nodes!(tree)
      #=> [#ExPoser.ShaderNode<PoserSurface>, #ExPoser.ShaderNode<Image_Map>]
  """
  @spec nodes!(t(), keyword()) :: [ShaderNode.t()]
  def nodes!(tree, opts \\ []), do: tree |> nodes(opts) |> Ref.unwrap!()

  @doc false
  # A renderer atom's code; an integer passes through; anything else raises.
  @spec renderer_code!(atom() | integer()) :: integer()
  def renderer_code!(code) when is_integer(code), do: code

  def renderer_code!(renderer) when is_atom(renderer) do
    case @renderers do
      %{^renderer => code} ->
        code

      _ ->
        raise ArgumentError,
              "a renderer is one of #{inspect(Map.keys(@renderers))} or an integer, " <>
                "got #{inspect(renderer)}"
    end
  end

  def renderer_code!(other),
    do: raise(ArgumentError, "a renderer is an atom or an integer, got #{inspect(other)}")

  @doc group: "Roots"
  @doc """
  The node that is the tree's root for `renderer`, or `nil` when it has none.
  A renderer is `:preview`, `:firefly`, `:poser4`, `:sketch`, `:superfly` or
  an integer code; an unknown atom raises `ArgumentError` before any request.
  Takes two data requests, plus the handle releases. Options: `:server`, `:timeout`.

  ## Examples

      ExPoser.ShaderTree.root(tree, :firefly)
      #=> {:ok, #ExPoser.ShaderNode<PoserSurface>}
  """
  @spec root(t(), atom() | integer(), keyword()) ::
          {:ok, ShaderNode.t() | nil} | {:error, Error.t()}
  def root(%__MODULE__{} = tree, renderer, opts \\ []) do
    code = renderer_code!(renderer)
    opts = run_opts(opts)

    with {:ok, [handle]} <-
           Batch.new() |> Batch.call(tree, "RendererRootNode", [code]) |> Batch.run(opts) do
      read_node(tree, handle, opts)
    end
  end

  @doc group: "Roots"
  @doc """
  Like `root/3`, but returns the node (or `nil`) and raises `ExPoser.Error` on
  failure.

  ## Examples

      ExPoser.ShaderTree.root!(tree, :superfly)
      #=> nil
  """
  @spec root!(t(), atom() | integer(), keyword()) :: ShaderNode.t() | nil
  def root!(tree, renderer, opts \\ []), do: tree |> root(renderer, opts) |> Ref.unwrap!()

  @doc group: "Roots"
  @doc """
  Makes `node` the root of its tree for `renderer` (see `root/3`). Poser
  refreshes the tree's preview afterwards. Options: `:server`, `:timeout`.

  ## Examples

      ExPoser.ShaderTree.set_root(image_node, :superfly)
      #=> {:ok, :ok}
  """
  @spec set_root(ShaderNode.t(), atom() | integer(), keyword()) ::
          {:ok, :ok} | {:error, Error.t()}
  def set_root(%ShaderNode{} = node, renderer, opts \\ []) do
    batch = Batch.set_root(Batch.new(), node, renderer)
    with {:ok, _} <- Batch.run(batch, run_opts(opts)), do: {:ok, :ok}
  end

  @doc group: "Roots"
  @doc """
  Like `set_root/3`, but returns `:ok` and raises `ExPoser.Error` on failure.

  ## Examples

      ExPoser.ShaderTree.set_root!(image_node, :superfly)
      #=> :ok
  """
  @spec set_root!(ShaderNode.t(), atom() | integer(), keyword()) :: :ok
  def set_root!(node, renderer, opts \\ []), do: node |> set_root(renderer, opts) |> Ref.unwrap!()

  defp build(tree, row),
    do: %ShaderNode{tree: tree, internal: row["InternalName"], name: row["Name"]}

  defp parent_of(:atmosphere), do: {:scene, "AtmosphereShaderTree"}
  defp parent_of(:background), do: {:scene, "BackgroundShaderTree"}
  defp parent_of(owner), do: {owner, "ShaderTree"}

  defp read_node(_tree, nil, _opts), do: {:ok, nil}

  defp read_node(tree, handle, opts) do
    result = Ref.read_children([handle], ["InternalName", "Name"], opts)
    Ref.release_in(handle, opts)

    with {:ok, [row]} <- result, do: {:ok, build(tree, row)}
  end

  defp run_opts(opts), do: Keyword.validate!(opts, [:server, :timeout])

  defimpl Inspect do
    def inspect(%{owner: owner}, _opts), do: "#ExPoser.ShaderTree<#{label(owner)}>"

    defp label(owner) when is_atom(owner), do: Atom.to_string(owner)
    defp label(%{name: name, material: %{name: material}}), do: "#{material}/#{name}"
    defp label(%{name: name}), do: name
  end
end
