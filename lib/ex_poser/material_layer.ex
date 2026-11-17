defmodule ExPoser.MaterialLayer do
  @moduledoc """
  A layer of a material, named by its display name.

  The struct is a name path: `material` is the `ExPoser.Material` and `name`
  is the name Poser's `LayerByName(name)` looks up.

      iex> prop = %ExPoser.Actor{figure: nil, internal: "ball", name: "Ball"}
      iex> skin = %ExPoser.Material{owner: prop, name: "Preview"}
      iex> layer = %ExPoser.MaterialLayer{material: skin, name: "Layer_1"}
      iex> ExPoser.Ref.path(layer)
      [{:actor, "ball"}, {:material, "Preview"}, {:layer, "Layer_1"}]
      iex> inspect(layer)
      "#ExPoser.MaterialLayer<Layer_1>"
  """

  alias ExPoser.{Material, Ref, ShaderTree}

  @enforce_keys [:material, :name]
  defstruct [:material, :name]

  @type t :: %__MODULE__{material: Material.t(), name: String.t()}

  @doc group: "Escape hatch"
  @doc """
  The layer's `%ExPoser.Handle{}`, for calls this library doesn't wrap.
  Release it with `ExPoser.Client.release/2`. A missing layer gives
  `:not_found` with `details.path`. Options: `:server`, `:timeout`.

  ## Examples

      {:ok, h} = ExPoser.MaterialLayer.handle(layer)
      ExPoser.Client.release([h])
  """
  @spec handle(t(), keyword()) :: {:ok, ExPoser.Handle.t()} | {:error, ExPoser.Error.t()}
  def handle(%__MODULE__{material: material, name: name} = layer, opts \\ []),
    do: Ref.fetch_handle(layer, "Name", material, "LayerByName", [name], opts)

  @doc group: "Escape hatch"
  @doc """
  Like `handle/2`, but returns the handle and raises `ExPoser.Error` on failure.

  ## Examples

      h = ExPoser.MaterialLayer.handle!(layer)
      ExPoser.Client.release([h])
  """
  @spec handle!(t(), keyword()) :: ExPoser.Handle.t()
  def handle!(layer, opts \\ []), do: layer |> handle(opts) |> Ref.unwrap!()

  @doc group: "Shader trees"
  @doc """
  The layer's shader tree, as a struct. Nothing is sent.

  ## Examples

      iex> prop = %ExPoser.Actor{figure: nil, internal: "ball", name: "Ball"}
      iex> skin = %ExPoser.Material{owner: prop, name: "Preview"}
      iex> layer = %ExPoser.MaterialLayer{material: skin, name: "Layer_1"}
      iex> ExPoser.MaterialLayer.tree(layer)
      #ExPoser.ShaderTree<Preview/Layer_1>
  """
  @spec tree(t()) :: ShaderTree.t()
  def tree(%__MODULE__{} = layer), do: %ShaderTree{owner: layer}

  defimpl Inspect do
    def inspect(%{name: name}, _opts), do: "#ExPoser.MaterialLayer<#{name}>"
  end
end
