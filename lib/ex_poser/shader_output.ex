defmodule ExPoser.ShaderOutput do
  @moduledoc """
  An output of a shader node, keyed by its internal name.

  `name` is the display name, `nil` on structs built by
  `ExPoser.ShaderNode.output/2`.

      iex> tree = %ExPoser.ShaderTree{owner: :background}
      iex> node = %ExPoser.ShaderNode{tree: tree, internal: "Image_Map"}
      iex> output = ExPoser.ShaderNode.output(node, "Color")
      iex> ExPoser.Ref.path(output)
      [{:tree, :background}, {:node, "Image_Map"}, {:output, "Color"}]
      iex> inspect(output)
      "#ExPoser.ShaderOutput<Color>"
  """

  alias ExPoser.{Ref, ShaderNode}

  @enforce_keys [:node, :internal]
  defstruct [:node, :internal, :name]

  @type t :: %__MODULE__{node: ShaderNode.t(), internal: String.t(), name: String.t() | nil}

  @doc group: "Escape hatch"
  @doc """
  The output's `%ExPoser.Handle{}`, for calls this library doesn't wrap.
  Release it with `ExPoser.Client.release/2`. A missing output gives
  `:not_found` with `details.path`. Options: `:server`, `:timeout`.

  ## Examples

      {:ok, h} = ExPoser.ShaderOutput.handle(output)
      ExPoser.Client.release([h])
  """
  @spec handle(t(), keyword()) :: {:ok, ExPoser.Handle.t()} | {:error, ExPoser.Error.t()}
  def handle(%__MODULE__{node: node, internal: internal} = output, opts \\ []),
    do: Ref.fetch_handle(output, "InternalName", node, "OutputByInternalName", [internal], opts)

  @doc group: "Escape hatch"
  @doc """
  Like `handle/2`, but returns the handle and raises `ExPoser.Error` on failure.

  ## Examples

      h = ExPoser.ShaderOutput.handle!(output)
      ExPoser.Client.release([h])
  """
  @spec handle!(t(), keyword()) :: ExPoser.Handle.t()
  def handle!(output, opts \\ []), do: output |> handle(opts) |> Ref.unwrap!()

  defimpl Inspect do
    def inspect(%{name: name, internal: internal}, _opts),
      do: "#ExPoser.ShaderOutput<#{name || internal}>"
  end
end
