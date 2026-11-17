defmodule ExPoser.Material do
  @moduledoc """
  A material of a figure or an actor, named by its display name.

  The struct is a name path, not a live handle: `owner` is the
  `ExPoser.Figure` or `ExPoser.Actor` that holds it, and `name` is the name
  Poser's `Material(name)` looks up.

      iex> fig = %ExPoser.Figure{internal: "figure 1", name: "Andy"}
      iex> hip = %ExPoser.Actor{figure: fig, internal: "hip", name: "Hip"}
      iex> skin = %ExPoser.Material{owner: hip, name: "Skin"}
      iex> ExPoser.Ref.path(skin)
      [{:figure, "figure 1"}, {:actor, "hip"}, {:material, "Skin"}]
      iex> inspect(skin)
      "#ExPoser.Material<Skin>"
  """

  alias ExPoser.{Actor, Figure, Ref, ShaderTree}

  @enforce_keys [:owner, :name]
  defstruct [:owner, :name]

  @type t :: %__MODULE__{owner: Figure.t() | Actor.t(), name: String.t()}

  @doc group: "Escape hatch"
  @doc """
  The material's `%ExPoser.Handle{}`, for calls this library doesn't wrap.
  Release it with `ExPoser.Client.release/2`. A missing material gives
  `:not_found` with `details.path`. Options: `:server`, `:timeout`.

  ## Examples

      {:ok, h} = ExPoser.Material.handle(skin)
      ExPoser.Client.release([h])
  """
  @spec handle(t(), keyword()) :: {:ok, ExPoser.Handle.t()} | {:error, ExPoser.Error.t()}
  def handle(%__MODULE__{owner: owner, name: name} = material, opts \\ []),
    do: Ref.fetch_handle(material, "Name", owner, "Material", [name], opts)

  @doc group: "Escape hatch"
  @doc """
  Like `handle/2`, but returns the handle and raises `ExPoser.Error` on failure.

  ## Examples

      h = ExPoser.Material.handle!(skin)
      ExPoser.Client.release([h])
  """
  @spec handle!(t(), keyword()) :: ExPoser.Handle.t()
  def handle!(material, opts \\ []), do: material |> handle(opts) |> Ref.unwrap!()

  @doc group: "Shader trees"
  @doc """
  The material's main shader tree, as a struct. Nothing is sent.

  ## Examples

      iex> fig = %ExPoser.Figure{internal: "figure 1", name: "Andy"}
      iex> skin = %ExPoser.Material{owner: fig, name: "Skin"}
      iex> ExPoser.Material.tree(skin)
      #ExPoser.ShaderTree<Skin>
  """
  @spec tree(t()) :: ShaderTree.t()
  def tree(%__MODULE__{} = material), do: %ShaderTree{owner: material}

  defimpl Inspect do
    def inspect(%{name: name}, _opts), do: "#ExPoser.Material<#{name}>"
  end
end
