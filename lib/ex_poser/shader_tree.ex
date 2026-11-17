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

  alias ExPoser.{Material, MaterialLayer, Ref}

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

  defp parent_of(:atmosphere), do: {:scene, "AtmosphereShaderTree"}
  defp parent_of(:background), do: {:scene, "BackgroundShaderTree"}
  defp parent_of(owner), do: {owner, "ShaderTree"}

  defimpl Inspect do
    def inspect(%{owner: owner}, _opts), do: "#ExPoser.ShaderTree<#{label(owner)}>"

    defp label(owner) when is_atom(owner), do: Atom.to_string(owner)
    defp label(%{name: name, material: %{name: material}}), do: "#{material}/#{name}"
    defp label(%{name: name}), do: name
  end
end
