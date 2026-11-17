defmodule ExPoser.ShaderNode do
  @moduledoc """
  A node of a shader tree, keyed by its internal name.

  `internal` is a string, or `{:created, k}` for the node a later batch step
  creates. `name` is the display name, `nil` on structs built here.

      iex> tree = %ExPoser.ShaderTree{owner: :atmosphere}
      iex> node = %ExPoser.ShaderNode{tree: tree, internal: "Image_Map"}
      iex> ExPoser.Ref.path(node)
      [{:tree, :atmosphere}, {:node, "Image_Map"}]
      iex> inspect(node)
      "#ExPoser.ShaderNode<Image_Map>"
  """

  alias ExPoser.{Error, Ref, ShaderInput, ShaderOutput, ShaderTree}

  @enforce_keys [:tree, :internal]
  defstruct [:tree, :internal, :name]

  @type internal :: String.t() | {:created, non_neg_integer()}
  @type t :: %__MODULE__{tree: ShaderTree.t(), internal: internal(), name: String.t() | nil}

  @doc group: "Escape hatch"
  @doc """
  The node's `%ExPoser.Handle{}`, for calls this library doesn't wrap.
  Release it with `ExPoser.Client.release/2`. A missing node gives
  `:not_found` with `details.path`. Options: `:server`, `:timeout`.

  ## Examples

      {:ok, h} = ExPoser.ShaderNode.handle(node)
      ExPoser.Client.release([h])
  """
  @spec handle(t(), keyword()) :: {:ok, ExPoser.Handle.t()} | {:error, ExPoser.Error.t()}
  def handle(%__MODULE__{tree: tree, internal: internal} = node, opts \\ []),
    do: Ref.fetch_handle(node, "InternalName", tree, "NodeByInternalName", [internal], opts)

  @doc group: "Escape hatch"
  @doc """
  Like `handle/2`, but returns the handle and raises `ExPoser.Error` on failure.

  ## Examples

      h = ExPoser.ShaderNode.handle!(node)
      ExPoser.Client.release([h])
  """
  @spec handle!(t(), keyword()) :: ExPoser.Handle.t()
  def handle!(node, opts \\ []), do: node |> handle(opts) |> Ref.unwrap!()

  @doc group: "Inputs and outputs"
  @doc """
  An input of the node by internal name, as a struct. Nothing is sent.

  ## Examples

      iex> tree = %ExPoser.ShaderTree{owner: :atmosphere}
      iex> node = %ExPoser.ShaderNode{tree: tree, internal: "Image_Map"}
      iex> ExPoser.ShaderNode.input(node, "Diffuse_Color")
      #ExPoser.ShaderInput<Diffuse_Color>
  """
  @spec input(t(), String.t()) :: ShaderInput.t()
  def input(%__MODULE__{} = node, internal) when is_binary(internal),
    do: %ShaderInput{node: node, internal: internal}

  @doc group: "Inputs and outputs"
  @doc """
  Lists the node's inputs, in Poser's order. Options: `:server`, `:timeout`.

  ## Examples

      ExPoser.ShaderNode.inputs(node)
      #=> {:ok, [#ExPoser.ShaderInput<Diffuse_Color>, ...]}
  """
  @spec inputs(t(), keyword()) :: {:ok, [ShaderInput.t()]} | {:error, Error.t()}
  def inputs(%__MODULE__{} = node, opts \\ []) do
    with {:ok, rows} <- Ref.children(node, "Inputs", [], run_opts(opts)),
         do:
           {:ok,
            Enum.map(
              rows,
              &%ShaderInput{node: node, internal: &1["InternalName"], name: &1["Name"]}
            )}
  end

  @doc group: "Inputs and outputs"
  @doc """
  Like `inputs/2`, but returns the list and raises `ExPoser.Error` on failure.

  ## Examples

      ExPoser.ShaderNode.inputs!(node)
      #=> [#ExPoser.ShaderInput<Diffuse_Color>, ...]
  """
  @spec inputs!(t(), keyword()) :: [ShaderInput.t()]
  def inputs!(node, opts \\ []), do: node |> inputs(opts) |> Ref.unwrap!()

  @doc group: "Inputs and outputs"
  @doc """
  An output of the node by internal name, as a struct. Nothing is sent.

  ## Examples

      iex> tree = %ExPoser.ShaderTree{owner: :atmosphere}
      iex> node = %ExPoser.ShaderNode{tree: tree, internal: "Image_Map"}
      iex> ExPoser.ShaderNode.output(node, "Color")
      #ExPoser.ShaderOutput<Color>
  """
  @spec output(t(), String.t()) :: ShaderOutput.t()
  def output(%__MODULE__{} = node, internal) when is_binary(internal),
    do: %ShaderOutput{node: node, internal: internal}

  @doc group: "Inputs and outputs"
  @doc """
  Lists the node's outputs, in Poser's order. Options: `:server`, `:timeout`.

  ## Examples

      ExPoser.ShaderNode.outputs(node)
      #=> {:ok, [#ExPoser.ShaderOutput<Diffuse_Color>, ...]}
  """
  @spec outputs(t(), keyword()) :: {:ok, [ShaderOutput.t()]} | {:error, Error.t()}
  def outputs(%__MODULE__{} = node, opts \\ []) do
    with {:ok, rows} <- Ref.children(node, "Outputs", [], run_opts(opts)),
         do:
           {:ok,
            Enum.map(
              rows,
              &%ShaderOutput{node: node, internal: &1["InternalName"], name: &1["Name"]}
            )}
  end

  @doc group: "Inputs and outputs"
  @doc """
  Like `outputs/2`, but returns the list and raises `ExPoser.Error` on failure.

  ## Examples

      ExPoser.ShaderNode.outputs!(node)
      #=> [#ExPoser.ShaderOutput<Diffuse_Color>, ...]
  """
  @spec outputs!(t(), keyword()) :: [ShaderOutput.t()]
  def outputs!(node, opts \\ []), do: node |> outputs(opts) |> Ref.unwrap!()

  defp run_opts(opts), do: Keyword.validate!(opts, [:server, :timeout])

  defimpl Inspect do
    def inspect(%{name: name, internal: internal}, _opts),
      do: "#ExPoser.ShaderNode<#{name || label(internal)}>"

    defp label(internal) when is_binary(internal), do: internal
    defp label(internal), do: Kernel.inspect(internal)
  end
end
