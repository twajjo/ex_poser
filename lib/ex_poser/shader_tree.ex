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

  alias ExPoser.{Error, Material, MaterialLayer, Ref, ShaderNode}

  @enforce_keys [:owner]
  defstruct [:owner]

  @type owner :: Material.t() | MaterialLayer.t() | :atmosphere | :background
  @type t :: %__MODULE__{owner: owner()}

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

  defp build(tree, row),
    do: %ShaderNode{tree: tree, internal: row["InternalName"], name: row["Name"]}

  defp parent_of(:atmosphere), do: {:scene, "AtmosphereShaderTree"}
  defp parent_of(:background), do: {:scene, "BackgroundShaderTree"}
  defp parent_of(owner), do: {owner, "ShaderTree"}

  defp run_opts(opts), do: Keyword.validate!(opts, [:server, :timeout])

  defimpl Inspect do
    def inspect(%{owner: owner}, _opts), do: "#ExPoser.ShaderTree<#{label(owner)}>"

    defp label(owner) when is_atom(owner), do: Atom.to_string(owner)
    defp label(%{name: name, material: %{name: material}}), do: "#{material}/#{name}"
    defp label(%{name: name}), do: name
  end
end
