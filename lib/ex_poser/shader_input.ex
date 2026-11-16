defmodule ExPoser.ShaderInput do
  @moduledoc """
  An input of a shader node, keyed by its internal name.

  `name` is the display name, `nil` on structs built by
  `ExPoser.ShaderNode.input/2`.

      iex> tree = %ExPoser.ShaderTree{owner: :background}
      iex> node = %ExPoser.ShaderNode{tree: tree, internal: "Image_Map"}
      iex> input = ExPoser.ShaderNode.input(node, "Color")
      iex> ExPoser.Ref.path(input)
      [{:tree, :background}, {:node, "Image_Map"}, {:input, "Color"}]
      iex> inspect(input)
      "#ExPoser.ShaderInput<Color>"
  """

  alias ExPoser.{Ref, ShaderNode}

  @enforce_keys [:node, :internal]
  defstruct [:node, :internal, :name]

  @type t :: %__MODULE__{node: ShaderNode.t(), internal: String.t(), name: String.t() | nil}

  @doc group: "Escape hatch"
  @doc """
  The input's `%ExPoser.Handle{}`, for calls this library doesn't wrap.
  Release it with `ExPoser.Client.release/2`. A missing input gives
  `:not_found` with `details.path`. Options: `:server`, `:timeout`.

  ## Examples

      {:ok, h} = ExPoser.ShaderInput.handle(input)
      ExPoser.Client.release([h])
  """
  @spec handle(t(), keyword()) :: {:ok, ExPoser.Handle.t()} | {:error, ExPoser.Error.t()}
  def handle(%__MODULE__{node: node, internal: internal} = input, opts \\ []),
    do: Ref.fetch_handle(input, "InternalName", node, "InputByInternalName", [internal], opts)

  @doc group: "Escape hatch"
  @doc """
  Like `handle/2`, but returns the handle and raises `ExPoser.Error` on failure.

  ## Examples

      h = ExPoser.ShaderInput.handle!(input)
      ExPoser.Client.release([h])
  """
  @spec handle!(t(), keyword()) :: ExPoser.Handle.t()
  def handle!(input, opts \\ []), do: input |> handle(opts) |> Ref.unwrap!()

  defimpl Inspect do
    def inspect(%{name: name, internal: internal}, _opts),
      do: "#ExPoser.ShaderInput<#{name || internal}>"
  end
end
