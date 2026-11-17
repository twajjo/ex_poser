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

  # key => {getter, setter, kind}
  @props %{
    ambient_color: {"AmbientColor", "SetAmbientColor", :color},
    diffuse_color: {"DiffuseColor", "SetDiffuseColor", :color},
    reflection_color: {"ReflectionColor", "SetReflectionColor", :color},
    specular_color: {"SpecularColor", "SetSpecularColor", :color},
    texture_color: {"TextureColor", "SetTextureColor", :color},
    ambient_map: {"AmbientMapFileName", "SetAmbientMapFileName", :string},
    bump_map: {"BumpMapFileName", "SetBumpMapFileName", :string},
    reflection_map: {"ReflectionMapFileName", "SetReflectionMapFileName", :string},
    specular_map: {"SpecularMapFileName", "SetSpecularMapFileName", :string},
    texture_map: {"TextureMapFileName", "SetTextureMapFileName", :string},
    transparency_map: {"TransparencyMapFileName", "SetTransparencyMapFileName", :string},
    bump_strength: {"BumpStrength", "SetBumpStrength", :float},
    reflection_strength: {"ReflectionStrength", "SetReflectionStrength", :float},
    transparency_min: {"TransparencyMin", "SetTransparencyMin", :float},
    transparency_max: {"TransparencyMax", "SetTransparencyMax", :float},
    transparency_falloff: {"TransparencyExpo", "SetTransparencyExpo", :float},
    ns: {"Ns", "SetNs", :float},
    selected: {"Selected", "SetSelected", :int}
  }

  @doc false
  # One request: reads the name through the path, so a missing material is
  # `:not_found` with its path.
  @spec find(t(), keyword()) :: {:ok, t()} | {:error, ExPoser.Error.t()}
  def find(%__MODULE__{} = material, opts) do
    with {:ok, _} <- Batch.new() |> Batch.call(material, "Name") |> Batch.run(opts),
         do: {:ok, material}
  end

  @doc group: "Settings"
  @doc """
  Reads one flat setting (an atom from `props/0`) or several (a list of them,
  which gives a map from each key to its value), in one batch. A colour is a
  `{r, g, b}` tuple. Options: `:server`, `:timeout`. An unknown key or option
  raises `ArgumentError` before any request.

  ## Examples

      ExPoser.Material.get(skin, :diffuse_color)
      #=> {:ok, {1.0, 1.0, 1.0}}
      ExPoser.Material.get(skin, [:ns, :selected])
      #=> {:ok, %{ns: 50.0, selected: 0}}
  """
  @spec get(t(), atom() | [atom()], keyword()) :: {:ok, term()} | {:error, Error.t()}
  def get(material, key_or_keys, opts \\ [])

  def get(%__MODULE__{} = material, keys, opts) when is_list(keys) do
    Enum.each(keys, &fetch_prop!/1)
    opts = run_opts(opts)

    batch =
      Enum.reduce(keys, Batch.new(), fn key, b ->
        {getter, _setter, _kind} = fetch_prop!(key)
        Batch.call(b, material, getter)
      end)

    with {:ok, results} <- Batch.run(batch, opts) do
      {:ok,
       keys |> Enum.zip(results) |> Map.new(fn {key, value} -> {key, decode(key, value)} end)}
    end
  end

  def get(%__MODULE__{} = material, key, opts) do
    with {:ok, map} <- get(material, [key], opts), do: {:ok, Map.fetch!(map, key)}
  end

  @doc group: "Settings"
  @doc """
  Like `get/3`, but returns the value and raises `ExPoser.Error` on failure.

  ## Examples

      ExPoser.Material.get!(skin, :ns)
      #=> 50.0
  """
  @spec get!(t(), atom() | [atom()], keyword()) :: term()
  def get!(material, key_or_keys, opts \\ []),
    do: material |> get(key_or_keys, opts) |> Ref.unwrap!()

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

  @doc group: "Settings"
  @doc """
  The flat setting keys that `get/3` and `set/4` accept.

  ## Examples

      iex> :diffuse_color in ExPoser.Material.props()
      true
      iex> :nope in ExPoser.Material.props()
      false
  """
  @spec props() :: [atom()]
  def props, do: @props |> Map.keys() |> Enum.sort()

  @doc group: "Settings"
  @doc """
  Sets several flat settings (`set(material, %{key => value})`), in one batch.
  Keys are as for `get/3`. A colour is a `{r, g, b}` tuple of numbers, a map
  file name is a string, and a float setting is a number. Keys and values
  are checked before anything is sent: a bad one raises `ArgumentError` and
  changes nothing. Options: `:server`, `:timeout`. A flat setting does not
  refresh Poser's preview.

  ## Examples

      ExPoser.Material.set(skin, %{texture_map: "skin.png", bump_strength: 0.5})
      #=> {:ok, :ok}
  """
  @spec set(t(), map()) :: {:ok, :ok} | {:error, Error.t()}
  def set(%__MODULE__{} = material, attrs) when is_map(attrs), do: set(material, attrs, [])

  @doc group: "Settings"
  @doc """
  Sets a map of settings with options, or one setting and value. See `set/2`.

  ## Examples

      ExPoser.Material.set(skin, %{ns: 20.0}, timeout: 5_000)
      #=> {:ok, :ok}
      ExPoser.Material.set(skin, :diffuse_color, {0.1, 0.2, 0.3})
      #=> {:ok, :ok}
  """
  @spec set(t(), map(), keyword()) :: {:ok, :ok} | {:error, Error.t()}
  @spec set(t(), atom(), term()) :: {:ok, :ok} | {:error, Error.t()}
  def set(%__MODULE__{} = material, attrs, opts) when is_map(attrs) and is_list(opts) do
    pairs = Map.to_list(attrs)
    Enum.each(pairs, fn {key, value} -> set_call!(key, value) end)
    opts = run_opts(opts)

    batch =
      Enum.reduce(pairs, Batch.new(), fn {key, value}, b ->
        Batch.set_material(b, material, key, value)
      end)

    with {:ok, _} <- Batch.run(batch, opts), do: {:ok, :ok}
  end

  def set(%__MODULE__{} = material, key, value) when not is_map(key) and not is_list(value),
    do: set(material, key, value, [])

  @doc group: "Settings"
  @doc """
  Sets one setting and value, with options. See `set/2`.

  ## Examples

      ExPoser.Material.set(skin, :ns, 20.0, timeout: 5_000)
      #=> {:ok, :ok}
  """
  @spec set(t(), atom(), term(), keyword()) :: {:ok, :ok} | {:error, Error.t()}
  def set(%__MODULE__{} = material, key, value, opts), do: set(material, %{key => value}, opts)

  @doc group: "Settings"
  @doc """
  Like `set/2`, `set/3` and `set/4`, but returns `:ok` and raises
  `ExPoser.Error` on failure.

  ## Examples

      ExPoser.Material.set!(skin, :ns, 20.0)
      #=> :ok
  """
  @spec set!(t(), map()) :: :ok
  def set!(%__MODULE__{} = material, attrs) when is_map(attrs), do: set!(material, attrs, [])

  @doc group: "Settings"
  @doc """
  Sets a map of settings with options, or one setting and value, and returns
  `:ok`. See `set!/2`.

  ## Examples

      ExPoser.Material.set!(skin, %{ns: 20.0}, timeout: 5_000)
      #=> :ok
  """
  @spec set!(t(), map(), keyword()) :: :ok
  @spec set!(t(), atom(), term()) :: :ok
  def set!(%__MODULE__{} = material, attrs, opts) when is_map(attrs) and is_list(opts),
    do: material |> set(attrs, opts) |> Ref.unwrap!()

  def set!(%__MODULE__{} = material, key, value) when not is_map(key) and not is_list(value),
    do: set!(material, key, value, [])

  @doc group: "Settings"
  @doc """
  Sets one setting and value, with options, and returns `:ok`. See `set!/2`.

  ## Examples

      ExPoser.Material.set!(skin, :ns, 20.0, timeout: 5_000)
      #=> :ok
  """
  @spec set!(t(), atom(), term(), keyword()) :: :ok
  def set!(%__MODULE__{} = material, key, value, opts),
    do: material |> set(key, value, opts) |> Ref.unwrap!()

  @doc false
  # Checks `key` and `value` and returns the setter's `{method, args}`.
  # Raises `ArgumentError` for an unknown key or a value of the wrong shape.
  @spec set_call!(term(), term()) :: {String.t(), list()}
  def set_call!(key, value) do
    {_getter, setter, kind} = fetch_prop!(key)
    {setter, encode!(kind, key, value)}
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

  defp decode(key, value) do
    case @props[key] do
      {_, _, :color} when is_list(value) -> List.to_tuple(value)
      _ -> value
    end
  end

  defp encode!(:color, _key, {r, g, b}) when is_number(r) and is_number(g) and is_number(b),
    do: [r * 1.0, g * 1.0, b * 1.0]

  defp encode!(:string, _key, value) when is_binary(value), do: [value]
  defp encode!(:float, _key, value) when is_number(value), do: [value * 1.0]
  defp encode!(:int, _key, value), do: [value]

  defp encode!(kind, key, value) do
    raise ArgumentError,
          "#{inspect(key)} takes a #{kind_label(kind)}, got #{inspect(value)}"
  end

  defp fetch_prop!(key) do
    case @props do
      %{^key => prop} ->
        prop

      _ ->
        raise ArgumentError,
              "unknown material key #{inspect(key)}, expected one of #{inspect(props())}"
    end
  end

  defp kind_label(:color), do: "{r, g, b} tuple of numbers"
  defp kind_label(:string), do: "string"
  defp kind_label(:float), do: "number"

  defp run_opts(opts), do: Keyword.validate!(opts, [:server, :timeout])

  defimpl Inspect do
    def inspect(%{name: name}, _opts), do: "#ExPoser.Material<#{name}>"
  end
end
