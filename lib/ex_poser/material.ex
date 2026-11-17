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

  alias ExPoser.{Actor, Batch, Error, Figure, MaterialLayer, Ref, ShaderTree}

  @enforce_keys [:owner, :name]
  defstruct [:owner, :name]

  @type t :: %__MODULE__{owner: Figure.t() | Actor.t(), name: String.t()}

  @doc false
  # One request: reads the name through the path, so a missing material is
  # `:not_found` with its path.
  @spec find(t(), keyword()) :: {:ok, t()} | {:error, ExPoser.Error.t()}
  def find(%__MODULE__{} = material, opts) do
    with {:ok, _} <- Batch.new() |> Batch.call(material, "Name") |> Batch.run(opts),
         do: {:ok, material}
  end

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

  @doc group: "Layers"
  @doc """
  Finds one of the material's layers by name. A name Poser doesn't have gives
  `:not_found`. Options: `:server`, `:timeout`.

  ## Examples

      ExPoser.Material.layer(skin, "Layer_1")
      #=> {:ok, #ExPoser.MaterialLayer<Layer_1>}
  """
  @spec layer(t(), String.t(), keyword()) :: {:ok, MaterialLayer.t()} | {:error, Error.t()}
  def layer(%__MODULE__{} = material, name, opts \\ []) when is_binary(name) do
    layer = %MaterialLayer{material: material, name: name}

    with {:ok, _} <-
           Batch.new() |> Batch.call(layer, "Name") |> Batch.run(run_opts(opts)),
         do: {:ok, layer}
  end

  @doc group: "Layers"
  @doc """
  Like `layer/3`, but returns the struct and raises `ExPoser.Error` on failure.

  ## Examples

      ExPoser.Material.layer!(skin, "Layer_1")
      #=> #ExPoser.MaterialLayer<Layer_1>
  """
  @spec layer!(t(), String.t(), keyword()) :: MaterialLayer.t()
  def layer!(material, name, opts \\ []), do: material |> layer(name, opts) |> Ref.unwrap!()

  @doc group: "Layers"
  @doc """
  Lists the material's layers, in Poser's order. Options: `:server`, `:timeout`.

  ## Examples

      ExPoser.Material.layers(skin)
      #=> {:ok, [#ExPoser.MaterialLayer<Layer_1>]}
  """
  @spec layers(t(), keyword()) :: {:ok, [MaterialLayer.t()]} | {:error, Error.t()}
  def layers(%__MODULE__{} = material, opts \\ []) do
    with {:ok, [rows]} <- Ref.list([material], "Layers", ["Name"], run_opts(opts)),
         do: {:ok, Enum.map(rows, &%MaterialLayer{material: material, name: &1["Name"]})}
  end

  @doc group: "Layers"
  @doc """
  Like `layers/2`, but returns the list and raises `ExPoser.Error` on failure.

  ## Examples

      ExPoser.Material.layers!(skin)
      #=> [#ExPoser.MaterialLayer<Layer_1>]
  """
  @spec layers!(t(), keyword()) :: [MaterialLayer.t()]
  def layers!(material, opts \\ []), do: material |> layers(opts) |> Ref.unwrap!()

  @doc false
  # The `owner`'s materials, read with `Name` only: materials have no `InternalName`.
  @spec list(Figure.t() | Actor.t(), keyword()) :: {:ok, [t()]} | {:error, ExPoser.Error.t()}
  def list(owner, opts) do
    with {:ok, [rows]} <- Ref.list([owner], "Materials", ["Name"], opts),
         do: {:ok, Enum.map(rows, &%__MODULE__{owner: owner, name: &1["Name"]})}
  end

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

  defp run_opts(opts), do: Keyword.validate!(opts, [:server, :timeout])

  defimpl Inspect do
    def inspect(%{name: name}, _opts), do: "#ExPoser.Material<#{name}>"
  end
end
