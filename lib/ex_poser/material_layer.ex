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

  alias ExPoser.{Batch, Error, Material, Ref, ShaderTree}

  @enforce_keys [:material, :name]
  defstruct [:material, :name]

  @type t :: %__MODULE__{material: Material.t(), name: String.t()}

  @doc group: "Layers"
  @doc """
  Deletes the layer. Poser deletes by index, so this reads the material's layer
  names first and finds the layer's place. It takes three batch round trips:
  the layer names (two) and one batch that deletes. Each is followed by a
  request that releases its handles, so six requests in all. A missing
  layer gives `:not_found` with `details.path`, and a name shared by several
  layers gives `:ambiguous` with the candidates under `details.matches`;
  neither deletes anything. There is no `Batch` form, because the index needs
  a read first. Options: `:server`, `:timeout`.

  ## Examples

      ExPoser.MaterialLayer.delete(layer)
      #=> {:ok, :ok}
  """
  @spec delete(t(), keyword()) :: {:ok, :ok} | {:error, Error.t()}
  def delete(%__MODULE__{material: material} = layer, opts \\ []) do
    opts = Keyword.validate!(opts, [:server, :timeout])

    with {:ok, [rows]} <- Ref.list([material], "Layers", ["Name"], opts),
         {:ok, index} <- index_of(rows, layer),
         {:ok, _} <-
           Batch.new() |> Batch.call(material, "DeleteLayer", [index]) |> Batch.run(opts),
         do: {:ok, :ok}
  end

  @doc group: "Layers"
  @doc """
  Like `delete/2`, but returns `:ok` and raises `ExPoser.Error` on failure.

  ## Examples

      ExPoser.MaterialLayer.delete!(layer)
      #=> :ok
  """
  @spec delete!(t(), keyword()) :: :ok
  def delete!(layer, opts \\ []), do: layer |> delete(opts) |> Ref.unwrap!()

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

  defp index_of(rows, %__MODULE__{name: name} = layer) do
    case for({row, i} <- Enum.with_index(rows), row["Name"] == name, do: i) do
      [index] ->
        {:ok, index}

      [] ->
        {:error, Error.not_found(Ref.path(layer))}

      indexes ->
        matches = List.duplicate(layer, length(indexes))
        {:error, %Error{kind: :ambiguous, details: %{matches: matches}}}
    end
  end

  defimpl Inspect do
    def inspect(%{name: name}, _opts), do: "#ExPoser.MaterialLayer<#{name}>"
  end
end
