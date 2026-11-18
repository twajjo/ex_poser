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

  alias ExPoser.{Batch, Error, Ref, ShaderInput, ShaderOutput, ShaderTree}

  @enforce_keys [:tree, :internal]
  defstruct [:tree, :internal, :name]

  @type internal :: String.t() | {:created, non_neg_integer()}
  @type t :: %__MODULE__{tree: ShaderTree.t(), internal: internal(), name: String.t() | nil}

  # key => {getter, setter}
  @props %{
    location: {"Location", "SetLocation"},
    name: {"Name", "SetName"},
    root: {"IsRoot", nil},
    type: {"Type", nil}
  }

  @doc group: "Properties"
  @doc """
  Reads one property (`:name`, `:type`, `:location` or `:root`) or several (a
  list of them, which gives a map from each key to its value), in one batch.
  `:location` is an `{x, y}` tuple; the others are as Poser gives them.
  Options: `:server`, `:timeout`. An unknown key or option raises
  `ArgumentError` before any request.

  ## Examples

      ExPoser.ShaderNode.get(node, :location)
      #=> {:ok, {120, 40}}
      ExPoser.ShaderNode.get(node, [:type, :root])
      #=> {:ok, %{type: "image_map", root: 0}}
  """
  @spec get(t(), atom() | [atom()], keyword()) :: {:ok, term()} | {:error, Error.t()}
  def get(node, key_or_keys, opts \\ [])

  def get(%__MODULE__{} = node, keys, opts) when is_list(keys) do
    Enum.each(keys, &fetch_prop!/1)
    opts = run_opts(opts)

    batch =
      Enum.reduce(keys, Batch.new(), fn key, b ->
        {getter, _setter} = fetch_prop!(key)
        Batch.call(b, node, getter)
      end)

    with {:ok, results} <- Batch.run(batch, opts) do
      {:ok,
       keys |> Enum.zip(results) |> Map.new(fn {key, value} -> {key, decode(key, value)} end)}
    end
  end

  def get(%__MODULE__{} = node, key, opts) do
    with {:ok, map} <- get(node, [key], opts), do: {:ok, Map.fetch!(map, key)}
  end

  @doc group: "Properties"
  @doc """
  Like `get/3`, but returns the value and raises `ExPoser.Error` on failure.

  ## Examples

      ExPoser.ShaderNode.get!(node, :name)
      #=> "Image_Map"
  """
  @spec get!(t(), atom() | [atom()], keyword()) :: term()
  def get!(node, key_or_keys, opts \\ []), do: node |> get(key_or_keys, opts) |> Ref.unwrap!()

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

  @doc group: "Properties"
  @doc """
  Sets several properties (`set(node, %{key => value})`), in one batch. `:name`
  takes a string and `:location` an `{x, y}` pair of integers. Keys and values
  are checked before anything is sent: a bad one raises `ArgumentError` and
  changes nothing. Options: `:server`, `:timeout`. Renaming or moving a node
  does not refresh Poser's preview.

  ## Examples

      ExPoser.ShaderNode.set(node, %{name: "Colour map", location: {120, 40}})
      #=> {:ok, :ok}
  """
  @spec set(t(), map()) :: {:ok, :ok} | {:error, Error.t()}
  def set(%__MODULE__{} = node, attrs) when is_map(attrs), do: set(node, attrs, [])

  @doc group: "Properties"
  @doc """
  Sets a map of properties with options, or one property and value. See `set/2`.

  ## Examples

      ExPoser.ShaderNode.set(node, %{name: "Colour map"}, timeout: 5_000)
      #=> {:ok, :ok}
      ExPoser.ShaderNode.set(node, :location, {120, 40})
      #=> {:ok, :ok}
  """
  @spec set(t(), map(), keyword()) :: {:ok, :ok} | {:error, Error.t()}
  @spec set(t(), atom(), term()) :: {:ok, :ok} | {:error, Error.t()}
  def set(%__MODULE__{} = node, attrs, opts) when is_map(attrs) and is_list(opts) do
    pairs = Map.to_list(attrs)
    Enum.each(pairs, fn {key, value} -> set_call!(key, value) end)
    opts = run_opts(opts)

    batch =
      Enum.reduce(pairs, Batch.new(), fn {key, value}, b ->
        Batch.set_node(b, node, key, value)
      end)

    with {:ok, _} <- Batch.run(batch, opts), do: {:ok, :ok}
  end

  def set(%__MODULE__{} = node, key, value) when not is_map(key) and not is_list(value),
    do: set(node, key, value, [])

  @doc group: "Properties"
  @doc """
  Sets one property and value, with options. See `set/2`.

  ## Examples

      ExPoser.ShaderNode.set(node, :name, "Colour map", timeout: 5_000)
      #=> {:ok, :ok}
  """
  @spec set(t(), atom(), term(), keyword()) :: {:ok, :ok} | {:error, Error.t()}
  def set(%__MODULE__{} = node, key, value, opts), do: set(node, %{key => value}, opts)

  @doc group: "Properties"
  @doc """
  Like `set/2`, `set/3` and `set/4`, but returns `:ok` and raises
  `ExPoser.Error` on failure.

  ## Examples

      ExPoser.ShaderNode.set!(node, :name, "Colour map")
      #=> :ok
  """
  @spec set!(t(), map()) :: :ok
  def set!(%__MODULE__{} = node, attrs) when is_map(attrs), do: set!(node, attrs, [])

  @doc group: "Properties"
  @doc """
  Sets a map of properties with options, or one property and value, and
  returns `:ok`. See `set!/2`.

  ## Examples

      ExPoser.ShaderNode.set!(node, %{name: "Colour map"}, timeout: 5_000)
      #=> :ok
  """
  @spec set!(t(), map(), keyword()) :: :ok
  @spec set!(t(), atom(), term()) :: :ok
  def set!(%__MODULE__{} = node, attrs, opts) when is_map(attrs) and is_list(opts),
    do: node |> set(attrs, opts) |> Ref.unwrap!()

  def set!(%__MODULE__{} = node, key, value) when not is_map(key) and not is_list(value),
    do: set!(node, key, value, [])

  @doc group: "Properties"
  @doc """
  Sets one property and value, with options, and returns `:ok`. See `set!/2`.

  ## Examples

      ExPoser.ShaderNode.set!(node, :name, "Colour map", timeout: 5_000)
      #=> :ok
  """
  @spec set!(t(), atom(), term(), keyword()) :: :ok
  def set!(%__MODULE__{} = node, key, value, opts),
    do: node |> set(key, value, opts) |> Ref.unwrap!()

  @doc false
  # Checks `key` and `value` and returns the setter's `{method, args}`.
  # Raises `ArgumentError` for an unknown or read-only key or a bad value.
  @spec set_call!(term(), term()) :: {String.t(), list()}
  def set_call!(:name, value) when is_binary(value), do: {"SetName", [value]}

  def set_call!(:location, {x, y}) when is_integer(x) and is_integer(y),
    do: {"SetLocation", [x, y]}

  def set_call!(:name, value),
    do: raise(ArgumentError, ":name takes a string, got #{inspect(value)}")

  def set_call!(:location, value),
    do: raise(ArgumentError, ":location takes an {x, y} pair of integers, got #{inspect(value)}")

  def set_call!(key, _value) do
    raise ArgumentError,
          "cannot set node key #{inspect(key)}, expected :name or :location"
  end

  defp decode(:location, [x, y]), do: {x, y}
  defp decode(_key, value), do: value

  defp fetch_prop!(key) do
    case @props do
      %{^key => prop} ->
        prop

      _ ->
        raise ArgumentError,
              "unknown node key #{inspect(key)}, expected one of #{inspect(Map.keys(@props))}"
    end
  end

  defp run_opts(opts), do: Keyword.validate!(opts, [:server, :timeout])

  defimpl Inspect do
    def inspect(%{name: name, internal: internal}, _opts),
      do: "#ExPoser.ShaderNode<#{name || label(internal)}>"

    defp label(internal) when is_binary(internal), do: internal
    defp label(internal), do: Kernel.inspect(internal)
  end
end
