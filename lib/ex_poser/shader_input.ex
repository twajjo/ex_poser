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

  alias ExPoser.{Batch, Error, Ref, ShaderNode}

  @enforce_keys [:node, :internal]
  defstruct [:node, :internal, :name]

  @type t :: %__MODULE__{node: ShaderNode.t(), internal: String.t(), name: String.t() | nil}

  # kNodeInputCode*
  @types %{
    -1 => :none,
    0 => :float,
    1 => :color,
    2 => :vector,
    3 => :string,
    4 => :boolean,
    5 => :integer,
    6 => :menu
  }

  @doc group: "Values"
  @doc """
  Reads the input's value (`Value()`), as Poser gives it: a number, a string,
  or a tuple for a colour or vector. Options: `:server`, `:timeout`.

  ## Examples

      ExPoser.ShaderInput.get(image_source)
      #=> {:ok, "C:/tex/a.png"}
  """
  @spec get(t(), keyword()) :: {:ok, term()} | {:error, Error.t()}
  def get(%__MODULE__{} = input, opts \\ []) do
    with {:ok, [value]} <- Batch.new() |> Batch.call(input, "Value") |> Batch.run(run_opts(opts)),
         do: {:ok, value}
  end

  @doc group: "Values"
  @doc """
  Like `get/2`, but returns the value and raises `ExPoser.Error` on failure.

  ## Examples

      ExPoser.ShaderInput.get!(image_source)
      #=> "C:/tex/a.png"
  """
  @spec get!(t(), keyword()) :: term()
  def get!(input, opts \\ []), do: input |> get(opts) |> Ref.unwrap!()

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

  @doc group: "Values"
  @doc """
  Sets the input's value, chosen by its shape: a string, a `{r, g, b}` tuple
  of numbers (a colour), or a number (sent as a float). Any other value
  raises `ArgumentError` before any request. Poser refreshes the tree's
  preview afterwards. Options: `:server`, `:timeout`.

  ## Examples

      ExPoser.ShaderInput.set(image_source, "C:/tex/a.png")
      #=> {:ok, :ok}
      ExPoser.ShaderInput.set(diffuse_color, {1, 0, 0})
      #=> {:ok, :ok}
  """
  @spec set(t(), String.t() | {number(), number(), number()} | number(), keyword()) ::
          {:ok, :ok} | {:error, Error.t()}
  def set(%__MODULE__{} = input, value, opts \\ []) do
    batch = Batch.set_input(Batch.new(), input, value)
    with {:ok, _} <- Batch.run(batch, run_opts(opts)), do: {:ok, :ok}
  end

  @doc group: "Values"
  @doc """
  Like `set/3`, but returns `:ok` and raises `ExPoser.Error` on failure.

  ## Examples

      ExPoser.ShaderInput.set!(image_source, "C:/tex/a.png")
      #=> :ok
  """
  @spec set!(t(), String.t() | {number(), number(), number()} | number(), keyword()) :: :ok
  def set!(input, value, opts \\ []), do: input |> set(value, opts) |> Ref.unwrap!()

  @doc false
  # Checks `value` and returns the setter's `{method, args}`. Raises
  # `ArgumentError` for a value of no accepted shape.
  @spec set_call!(term()) :: {String.t(), list()}
  def set_call!(value) when is_binary(value), do: {"SetString", [value]}

  def set_call!({r, g, b}) when is_number(r) and is_number(g) and is_number(b),
    do: {"SetColor", [r * 1.0, g * 1.0, b * 1.0]}

  def set_call!(value) when is_number(value), do: {"SetFloat", [value * 1.0]}

  def set_call!(value) do
    raise ArgumentError,
          "an input value is a string, a {r, g, b} tuple of numbers or a number, " <>
            "got #{inspect(value)}"
  end

  @doc group: "Values"
  @doc """
  The input's type as an atom: `:none`, `:float`, `:color`, `:vector`,
  `:string`, `:boolean`, `:integer` or `:menu`. A code this library doesn't
  know stays an integer. Options: `:server`, `:timeout`.

  ## Examples

      ExPoser.ShaderInput.type(diffuse_color)
      #=> {:ok, :color}
  """
  @spec type(t(), keyword()) :: {:ok, atom() | integer()} | {:error, Error.t()}
  def type(%__MODULE__{} = input, opts \\ []) do
    with {:ok, [code]} <- Batch.new() |> Batch.call(input, "Type") |> Batch.run(run_opts(opts)),
         do: {:ok, Map.get(@types, code, code)}
  end

  @doc group: "Values"
  @doc """
  Like `type/2`, but returns the type and raises `ExPoser.Error` on failure.

  ## Examples

      ExPoser.ShaderInput.type!(diffuse_color)
      #=> :color
  """
  @spec type!(t(), keyword()) :: atom() | integer()
  def type!(input, opts \\ []), do: input |> type(opts) |> Ref.unwrap!()

  defp run_opts(opts), do: Keyword.validate!(opts, [:server, :timeout])

  defimpl Inspect do
    def inspect(%{name: name, internal: internal}, _opts),
      do: "#ExPoser.ShaderInput<#{name || internal}>"
  end
end
