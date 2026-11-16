defmodule ExPoser.Light do
  @moduledoc """
  A light: a scene-level actor that Poser reports as a light.

  It wraps its `ExPoser.Actor`, which holds the internal name (the key) and
  the GUI label. Find lights with `ExPoser.Scene.lights/1` and
  `ExPoser.Scene.light/2`.

      iex> actor = %ExPoser.Actor{figure: nil, internal: "light 1", name: "Key"}
      iex> inspect(%ExPoser.Light{actor: actor})
      "#ExPoser.Light<Key>"
  """

  import Kernel, except: [apply: 2]

  @enforce_keys [:actor]
  defstruct [:actor]

  @type t :: %__MODULE__{actor: ExPoser.Actor.t()}

  alias ExPoser.{Actor, Batch, Client, Error, Parameter, Ref, Scene}
  alias ExPoser.Light.Snapshot

  @props %{
    type: {"LightType", "SetLightType"},
    attenuation: {"LightAttenType", "SetLightAttenType"},
    on: {"LightOn", "SetLightOn"},
    preview: {"LightPreview", "SetLightPreview"},
    shadow: {"Shadow", "SetShadow"},
    casts_shadows: {"CastsShadows", "SetCastsShadows"},
    ray_trace_shadows: {"RayTraceShadows", "SetRayTraceShadows"},
    shadow_bias_min: {"ShadowBiasMin", "SetShadowBiasMin"},
    shadow_bias_max: {"ShadowBiasMax", "SetShadowBiasMax"},
    shadow_blur_radius: {"ShadowBlurRadius", "SetShadowBlurRadius"},
    shadow_raytrace_softness: {"ShadowRaytraceSoftness", "SetShadowRaytraceSoftness"},
    shadow_samples: {"ShadowSamples", "SetShadowSamples"},
    ambient_occlusion: {"AmbientOcclusion", "SetAmbientOcclusion"},
    ambient_occlusion_bias: {"AmbientOcclusionBias", "SetAmbientOcclusionBias"},
    ambient_occlusion_distance: {"AmbientOcclusionDistance", "SetAmbientOcclusionDistance"},
    ambient_occlusion_strength: {"AmbientOcclusionStrength", "SetAmbientOcclusionStrength"}
  }

  @enums %{
    type: %{infinite: 0, spot: 1, point: 2, image: 3, area: 4},
    attenuation: %{poser: 0, inverse_linear: 1, inverse_square: 2}
  }

  @color_codes [23, 24, 25]

  @doc group: "Snapshots"
  @doc """
  Applies snapshots to the scene's lights. The first argument is one
  `ExPoser.Light.Snapshot` or a list of them. Options: `:server`,
  `:timeout`, `:frame`, the frame dials are set at (default: the scene's
  current frame, which is left unchanged), and `:mode`, `:merge` (the
  default) or `:replace`. Any other mode raises `ArgumentError`.

  With `mode: :replace`, every light in the scene is deleted and the
  snapshots' lights are created, all in one request; no snapshot is matched
  to an existing light, so a name shared by several lights is not
  `:ambiguous`, and snapshots may share a name; Poser adds a number to a
  name another light already has (`"Fill 2"`). The new lights are then
  given their type, props and dials as below. Only lights are replaced. It
  is not atomic: if the delete-and-create request fails, the error is
  returned and some lights may already be deleted or created; if the write
  batch fails, the scene already holds the new lights. An empty list with
  `mode: :replace` deletes every light and returns `{:ok, %{skipped: []}}`.

  In merge mode (the rest of this doc), each snapshot is matched to a light
  by display name. If a name matches several lights the call returns an
  `:ambiguous` error whose `details.matches` holds the lights; the first
  such error in snapshot order is returned, and nothing is created or
  changed. A snapshot that matches no light gets a new one, named by the
  snapshot and then given its type, props and dials like any other. All
  missing lights are created in one request. If that fails, the error is
  returned and no snapshot is written, but lights the request made before
  it failed stay in the scene. In merge mode an empty list sends no
  request.

  Before any request, duplicate snapshot names (merge only), an unknown
  property, an unknown enum atom or an unknown option raise
  `ArgumentError`. A snapshot's `props` can't hold `:color` (colour is in
  its dials) or `:type` (use its `:type` field); either raises too.

  Per light, the type is written first, then the other properties in the
  snapshot (only those present), then the dials. The result is
  `{:ok, %{skipped: skipped}}`, where `skipped` lists `{light_name, dial}`
  for each snapshot dial the light lacks; those are not sent.

  When no light is missing it takes five batch round trips: the lights list
  (two), the dial names (two) and one batch that writes everything. Each is
  followed by a request that releases its handles, so ten requests in all,
  however many snapshots there are, while the writes fit in one
  `ExPoser.Batch` chunk (2000 wire ops). Beyond that limit the write batch
  splits into more requests. Creating the missing lights adds one batch
  (the create request, then its release), so twelve requests in all,
  however many lights are created.

  Replace takes twelve requests however many snapshots there are, measured
  with `ExPoser.Client.request_count/1`: the lights list (four), the
  delete-and-create batch (two), the dial names (four) and the write batch
  (two). An empty replace takes six (the lights list, then the delete batch),
  or two when the scene has no lights.

  ## Examples

      snaps = ExPoser.Light.snapshot_all!()
      ExPoser.Light.apply(snaps, frame: 4)
      #=> {:ok, %{skipped: []}}
  """
  @spec apply(Snapshot.t() | [Snapshot.t()], keyword()) ::
          {:ok, %{skipped: [{String.t(), String.t()}]}} | {:error, Error.t()}
  def apply(snapshot_or_list, opts \\ []) do
    snapshots = List.wrap(snapshot_or_list)
    mode = Keyword.get(opts, :mode, :merge)

    unless mode in [:merge, :replace] do
      raise ArgumentError, "mode must be :merge or :replace, got #{inspect(mode)}"
    end

    {frame, run} = split(opts)
    Enum.each(snapshots, &check_snapshot!/1)
    if mode == :merge, do: check_unique!(snapshots)

    run_apply(snapshots, mode, frame, run)
  end

  @doc group: "Snapshots"
  @doc """
  Like `apply/2`, but returns the `%{skipped: _}` map and raises
  `ExPoser.Error` on failure.

  ## Examples

      ExPoser.Light.apply!(snaps)
      #=> %{skipped: []}
  """
  @spec apply!(Snapshot.t() | [Snapshot.t()], keyword()) :: %{
          skipped: [{String.t(), String.t()}]
        }
  def apply!(snapshot_or_list, opts \\ []), do: snapshot_or_list |> apply(opts) |> Ref.unwrap!()

  @doc group: "Create and delete"
  @doc """
  Creates a light, a spot light, and returns it. With a map, it is given
  those attributes: `:name` (the GUI label) plus any key `set/3` accepts.
  With a keyword list, it is the options. See `create/2`. Attributes must be
  a map: `create(name: "Rim")` raises `ArgumentError`, because a keyword list
  is read as options.

  ## Examples

      ExPoser.Light.create()
      #=> {:ok, #ExPoser.Light<Light 4>}
      ExPoser.Light.create(%{name: "Rim", type: :point})
      #=> {:ok, #ExPoser.Light<Rim>}
  """
  @spec create(map() | keyword()) :: {:ok, t()} | {:error, Error.t()}
  def create(attrs_or_opts \\ [])

  def create(opts) when is_list(opts), do: create(%{}, opts)
  def create(attrs) when is_map(attrs), do: create(attrs, [])

  @doc group: "Create and delete"
  @doc """
  Creates a light with the attributes `attrs`. The new light is made in one
  request, then the remaining attributes are set (as `set/3` does) in a
  second. Options: `:server` and `:timeout`. Dial attributes are set at the
  scene's current frame; `create` takes no `:frame` option, so use `set/3`
  with `frame:` afterwards to key another frame.

  The attributes are checked first: an unknown property or enum atom, a
  malformed colour or a `:name` that isn't a string raises `ArgumentError`
  and creates nothing. If the second request fails, the light already exists
  and the error is returned. The light stays in the scene: find it by its
  `:name`, or as `"Light N"` (Poser's default name) if no name was given.

  ## Examples

      ExPoser.Light.create(%{name: "Rim", color: {0.2, 0.4, 1.0}}, timeout: 10_000)
      #=> {:ok, #ExPoser.Light<Rim>}
  """
  @spec create(map(), keyword()) :: {:ok, t()} | {:error, Error.t()}
  def create(attrs, opts) when is_map(attrs) and is_list(opts) do
    opts = Keyword.validate!(opts, [:server, :timeout])
    {name, rest} = Map.pop(attrs, :name)

    unless is_nil(name) or is_binary(name) do
      raise ArgumentError, "light name must be a string, got #{inspect(name)}"
    end

    Enum.each(rest, fn {key, value} -> encode!(key, value) end)

    with {:ok, [light]} <- create_lights([name], [], opts),
         {:ok, :ok} <- set_unless_empty(light, rest, opts) do
      {:ok, light}
    end
  end

  @doc group: "Create and delete"
  @doc """
  Like `create/1`, but returns the light and raises `ExPoser.Error` on failure.

  ## Examples

      ExPoser.Light.create!(%{name: "Rim"})
      #=> #ExPoser.Light<Rim>
  """
  @spec create!(map() | keyword()) :: t()
  def create!(attrs_or_opts \\ []), do: attrs_or_opts |> create() |> Ref.unwrap!()

  @doc group: "Create and delete"
  @doc """
  Like `create/2`, but returns the light and raises `ExPoser.Error` on failure.

  ## Examples

      ExPoser.Light.create!(%{name: "Rim"}, timeout: 10_000)
      #=> #ExPoser.Light<Rim>
  """
  @spec create!(map(), keyword()) :: t()
  def create!(attrs, opts), do: attrs |> create(opts) |> Ref.unwrap!()

  @doc group: "Create and delete"
  @doc """
  Deletes the light from the scene. Options: `:server` and `:timeout`.

  ## Examples

      ExPoser.Light.delete(rim)
      #=> {:ok, :ok}
  """
  @spec delete(t(), keyword()) :: {:ok, :ok} | {:error, Error.t()}
  def delete(%__MODULE__{} = light, opts \\ []) do
    opts = Keyword.validate!(opts, [:server, :timeout])
    batch = Batch.call(Batch.new(), light, "Delete", [])
    with {:ok, _} <- Batch.run(batch, opts), do: {:ok, :ok}
  end

  @doc group: "Create and delete"
  @doc """
  Like `delete/2`, but returns `:ok` and raises `ExPoser.Error` on failure.

  ## Examples

      ExPoser.Light.delete!(rim)
      #=> :ok
  """
  @spec delete!(t(), keyword()) :: :ok
  def delete!(%__MODULE__{} = light, opts \\ []), do: light |> delete(opts) |> Ref.unwrap!()

  @doc false
  # A dial of `actor`, named by its internal name. Shared with cameras.
  @spec dial(Actor.t(), String.t()) :: Parameter.t()
  def dial(%Actor{} = actor, internal) when is_binary(internal),
    do: %Parameter{actor: actor, internal: internal, name: internal}

  @doc group: "Properties"
  @doc """
  Reads one value or several. A string names a dial (by internal name), an
  atom names a property, and `:color` gives `{r, g, b}`. A list of keys gives a
  map from each key to its value.

  `:type` is `:infinite`, `:spot`, `:point`, `:image` or `:area`, and
  `:attenuation` is `:poser`, `:inverse_linear` or `:inverse_square`. A code
  Poser reports that isn't in those lists stays an integer. The properties are
  `#{@props |> Map.keys() |> Enum.sort() |> Enum.map_join(", ", &inspect/1)}`.

  All of it is one batch (two requests when `:color` is read). Options:
  `:server`, `:timeout`, and `:frame`, the frame dials (and the colour) are
  read at. An unknown property atom raises `ArgumentError`.

  ## Examples

      ExPoser.Light.get(key, :type)
      #=> {:ok, :spot}
      ExPoser.Light.get(key, [:color, "xtran"])
      #=> {:ok, %{color: {1.0, 1.0, 1.0}, "xtran" => 0.0}}
  """
  @spec get(t(), term(), keyword()) :: {:ok, term()} | {:error, Error.t()}
  def get(light, key_or_keys, opts \\ [])

  def get(%__MODULE__{} = light, keys, opts) when is_list(keys) do
    Enum.each(keys, &check_key!/1)
    run_get(light, keys, opts)
  end

  def get(%__MODULE__{} = light, key, opts) do
    with {:ok, map} <- get(light, [key], opts), do: {:ok, Map.fetch!(map, key)}
  end

  @doc group: "Properties"
  @doc """
  Like `get/3`, but returns the value and raises `ExPoser.Error` on failure.

  ## Examples

      ExPoser.Light.get!(key, :type)
      #=> :spot
  """
  @spec get!(t(), term(), keyword()) :: term()
  def get!(light, key_or_keys, opts \\ []), do: light |> get(key_or_keys, opts) |> Ref.unwrap!()

  @doc group: "Escape hatch"
  @doc """
  The light's `%ExPoser.Handle{}`, for calls this library doesn't wrap. Like
  `ExPoser.Actor.handle/2`, whose rules apply: release the handle with
  `ExPoser.Client.release/2`.
  """
  @spec handle(t(), keyword()) :: {:ok, ExPoser.Handle.t()} | {:error, ExPoser.Error.t()}
  def handle(%__MODULE__{actor: actor}, opts \\ []), do: Actor.handle(actor, opts)

  @doc group: "Aiming"
  @doc """
  Aims the light at `target`: any light, camera, figure, actor or parameter
  struct, or `nil` to clear the target. The target is resolved in the same
  request. Options: `:server` and `:timeout`. Any other target raises
  `ArgumentError`.

  ## Examples

      ExPoser.Light.point_at(key, hip)
      #=> {:ok, :ok}
      ExPoser.Light.point_at(key, nil)
      #=> {:ok, :ok}
  """
  @spec point_at(t(), Ref.ref() | nil, keyword()) :: {:ok, :ok} | {:error, Error.t()}
  def point_at(%__MODULE__{} = light, target, opts \\ []), do: run_point_at(light, target, opts)

  @doc group: "Aiming"
  @doc """
  Like `point_at/3`, but returns `:ok` and raises `ExPoser.Error` on failure.

  ## Examples

      ExPoser.Light.point_at!(key, hip)
      #=> :ok
  """
  @spec point_at!(t(), Ref.ref() | nil, keyword()) :: :ok
  def point_at!(%__MODULE__{} = light, target, opts \\ []),
    do: light |> point_at(target, opts) |> Ref.unwrap!()

  @doc false
  # The property table, for tests: atom => {getter, setter}.
  @spec props() :: %{atom() => {String.t(), String.t()}}
  def props, do: @props

  @doc false
  # Reads `keys` (strings are dials; atoms are checked by the caller) of an
  # owner with an `actor` field, a light or a camera.
  @spec run_get(struct(), [term()], keyword()) :: {:ok, map()} | {:error, Error.t()}
  def run_get(owner, keys, opts) do
    {frame, run} = split(opts)

    with {:ok, colors} <- color_dials(owner, keys, run) do
      batch = Enum.reduce(keys, Batch.new(), &add_get(&2, owner, &1, colors, frame))

      with {:ok, results} <- Batch.run(batch, run) do
        {:ok, keys |> decode_all(results) |> Map.new()}
      end
    end
  end

  @doc false
  # Aims a light or camera at a ref struct, or clears the target with nil.
  @spec run_point_at(struct(), term(), keyword()) :: {:ok, :ok} | {:error, Error.t()}
  def run_point_at(owner, target, opts) do
    unless is_nil(target) or Ref.ref?(target) do
      raise ArgumentError, "point_at target must be a ref struct or nil, got #{inspect(target)}"
    end

    opts = Keyword.validate!(opts, [:server, :timeout])
    batch = Batch.call(Batch.new(), owner, "PointAt", [target])
    with {:ok, _} <- Batch.run(batch, opts), do: {:ok, :ok}
  end

  @doc false
  # Sets `{key, value}` pairs, already checked and encoded, in order.
  @spec run_set(struct(), [{term(), term()}], keyword()) :: {:ok, :ok} | {:error, Error.t()}
  def run_set(owner, pairs, opts) do
    {frame, run} = split(opts)

    with {:ok, colors} <- color_dials(owner, Enum.map(pairs, &elem(&1, 0)), run) do
      batch = Enum.reduce(pairs, Batch.new(), &add_set(&2, owner, &1, colors, frame))
      with {:ok, _} <- Batch.run(batch, run), do: {:ok, :ok}
    end
  end

  @doc group: "Properties"
  @doc """
  Sets one value (`set(light, key, value, opts)`) or several
  (`set(light, %{key => value}, opts)`), in one batch. Keys are as for `get/3`.
  Integers pass through for `:type` and `:attenuation`. Options: `:server`,
  `:timeout`, and `:frame`, the frame dials (and the colour) are set at.

  In a map, `:type` is applied before every other key, because a type change
  can reset dials. The order of the other keys is unspecified.

  Only the enum keys (`:type`, `:attenuation`), `:color` and the key names are
  checked before anything is sent: an unknown property atom, an unknown enum
  atom or a malformed colour raises `ArgumentError` and changes nothing. Other
  values go to Poser as they are.

  ## Examples

      ExPoser.Light.set(key, :color, {1.0, 0.5, 0.25})
      #=> {:ok, :ok}
      ExPoser.Light.set(key, %{type: :point, "xtran" => 0.5}, frame: 4)
      #=> {:ok, :ok}
  """
  @spec set(t(), map()) :: {:ok, :ok} | {:error, Error.t()}
  def set(%__MODULE__{} = light, attrs) when is_map(attrs), do: set(light, attrs, [])

  @doc group: "Properties"
  @doc """
  Sets a map of values with options, or one key and value. See `set/2`.

  ## Examples

      ExPoser.Light.set(key, :on, 0)
      #=> {:ok, :ok}
      ExPoser.Light.set(key, %{on: 0}, frame: 4)
      #=> {:ok, :ok}
  """
  @spec set(t(), map(), keyword()) :: {:ok, :ok} | {:error, Error.t()}
  @spec set(t(), String.t() | atom(), term()) :: {:ok, :ok} | {:error, Error.t()}
  def set(%__MODULE__{} = light, attrs, opts) when is_map(attrs) and is_list(opts) do
    pairs =
      attrs
      |> Enum.map(fn {key, value} -> {key, encode!(key, value)} end)
      |> Enum.sort_by(fn {key, _value} -> key != :type end)

    run_set(light, pairs, opts)
  end

  def set(%__MODULE__{} = light, key, value) when not is_map(key) and not is_list(value),
    do: set(light, key, value, [])

  @doc group: "Properties"
  @doc """
  Sets one key and value, with options. See `set/2`.

  ## Examples

      ExPoser.Light.set(key, "xtran", 0.5, frame: 4)
      #=> {:ok, :ok}
  """
  @spec set(t(), String.t() | atom(), term(), keyword()) :: {:ok, :ok} | {:error, Error.t()}
  def set(%__MODULE__{} = light, key, value, opts), do: set(light, %{key => value}, opts)

  @doc group: "Properties"
  @doc """
  Like `set/2`, `set/3` and `set/4`, but returns `:ok` and raises
  `ExPoser.Error` on failure.

  ## Examples

      ExPoser.Light.set!(key, :on, 0)
      #=> :ok
  """
  @spec set!(t(), map()) :: :ok
  def set!(%__MODULE__{} = light, attrs) when is_map(attrs), do: set!(light, attrs, [])

  @doc group: "Properties"
  @doc """
  Sets a map of values with options, or one key and value, and returns `:ok`.
  See `set!/2`.

  ## Examples

      ExPoser.Light.set!(key, :on, 0)
      #=> :ok
  """
  @spec set!(t(), map(), keyword()) :: :ok
  @spec set!(t(), String.t() | atom(), term()) :: :ok
  def set!(%__MODULE__{} = light, attrs, opts) when is_map(attrs) and is_list(opts),
    do: light |> set(attrs, opts) |> Ref.unwrap!()

  def set!(%__MODULE__{} = light, key, value) when not is_map(key) and not is_list(value),
    do: set!(light, key, value, [])

  @doc group: "Properties"
  @doc """
  Sets one key and value, with options, and returns `:ok`. See `set!/2`.

  ## Examples

      ExPoser.Light.set!(key, "xtran", 0.5, frame: 4)
      #=> :ok
  """
  @spec set!(t(), String.t() | atom(), term(), keyword()) :: :ok
  def set!(%__MODULE__{} = light, key, value, opts),
    do: light |> set(key, value, opts) |> Ref.unwrap!()

  @doc group: "Snapshots"
  @doc """
  Reads the light's state at one frame as an `ExPoser.Light.Snapshot`: its
  name, its type, every dial and every other property. Options: `:server`,
  `:timeout`, and `:frame` (default: the scene's current frame). An unknown
  option raises `ArgumentError` before any request.

  It takes three batch round trips when the reads fit in one `ExPoser.Batch`
  chunk (2000 wire ops, far more than one light needs): the dial names (two),
  then one batch that reads everything. Each is followed by a request that
  releases its handles, so six requests in all.

  ## Examples

      ExPoser.Light.snapshot(key, frame: 2)
      #=> {:ok, %ExPoser.Light.Snapshot{name: "Key", type: :spot, dials: %{"xtran" => 0.0, ...}, props: %{on: 1, ...}}}
  """
  @spec snapshot(t(), keyword()) :: {:ok, Snapshot.t()} | {:error, Error.t()}
  def snapshot(%__MODULE__{} = light, opts \\ []) do
    {frame, run} = split(opts)

    with {:ok, [snapshot]} <- read_snapshots([light], frame, run), do: {:ok, snapshot}
  end

  @doc group: "Snapshots"
  @doc """
  Like `snapshot/2`, but returns the snapshot and raises `ExPoser.Error` on
  failure.

  ## Examples

      ExPoser.Light.snapshot!(key)
      #=> %ExPoser.Light.Snapshot{name: "Key", type: :spot, ...}
  """
  @spec snapshot!(t(), keyword()) :: Snapshot.t()
  def snapshot!(%__MODULE__{} = light, opts \\ []), do: light |> snapshot(opts) |> Ref.unwrap!()

  @doc group: "Snapshots"
  @doc """
  Snapshots every light in the scene, in `ExPoser.Scene.lights/1` order, at
  one frame. Options: `:server`, `:timeout`, and `:frame`. The number of
  requests does not grow with the number of lights while the reads fit in one
  `ExPoser.Batch` chunk (2000 wire ops, about 30 per light with 5 dials, so
  roughly 65 such lights; more dials mean fewer lights): five batch round
  trips, the list (two), the dial names (two) and one batch that reads
  everything, each followed by a request that releases its handles, so ten
  requests in all. Beyond that limit the batch splits into more requests.

  ## Examples

      ExPoser.Light.snapshot_all()
      #=> {:ok, [%ExPoser.Light.Snapshot{name: "Key", ...}, ...]}
  """
  @spec snapshot_all(keyword()) :: {:ok, [Snapshot.t()]} | {:error, Error.t()}
  def snapshot_all(opts \\ []) do
    {frame, run} = split(opts)

    with {:ok, lights} <- Scene.lights(run), do: read_snapshots(lights, frame, run)
  end

  @doc group: "Snapshots"
  @doc """
  Like `snapshot_all/1`, but returns the list and raises `ExPoser.Error` on
  failure.

  ## Examples

      ExPoser.Light.snapshot_all!()
      #=> [%ExPoser.Light.Snapshot{name: "Key", ...}, ...]
  """
  @spec snapshot_all!(keyword()) :: [Snapshot.t()]
  def snapshot_all!(opts \\ []), do: opts |> snapshot_all() |> Ref.unwrap!()

  defp add_get(b, light, :color, colors, frame),
    do: Enum.reduce(colors, b, &Batch.get(&2, dial(light.actor, &1), frame: frame))

  defp add_get(b, light, key, _colors, frame) when is_binary(key),
    do: Batch.get(b, dial(light.actor, key), frame: frame)

  defp add_get(b, light, key, _colors, _frame) do
    {getter, _setter} = Map.fetch!(@props, key)
    Batch.call(b, light, getter, [])
  end

  defp add_set(b, light, {:color, {r, g, bl}}, colors, frame) do
    colors
    |> Enum.zip([r, g, bl])
    |> Enum.reduce(b, fn {name, value}, acc ->
      Batch.set(acc, dial(light.actor, name), value, frame: frame)
    end)
  end

  defp add_set(b, light, {key, value}, _colors, frame) when is_binary(key),
    do: Batch.set(b, dial(light.actor, key), value, frame: frame)

  defp add_set(b, light, {key, value}, _colors, _frame) do
    {_getter, setter} = Map.fetch!(@props, key)
    Batch.call(b, light, setter, [value])
  end

  # Splits the results by key type: atom keys are properties (into `props`,
  # minus `:type`), string keys are dial internal names (into `dials`).
  defp build_snapshot(light, keys, results) do
    values = keys |> decode_all(results) |> Map.new()
    {type, values} = Map.pop!(values, :type)
    {props, dials} = Enum.split_with(values, fn {key, _value} -> is_atom(key) end)

    %Snapshot{name: light.actor.name, type: type, dials: Map.new(dials), props: Map.new(props)}
  end

  defp check_key!(key) when is_binary(key) or key == :color, do: :ok
  defp check_key!(key) when is_map_key(@props, key), do: :ok

  defp check_key!(key),
    do: raise(ArgumentError, "unknown light property #{inspect(key)}")

  defp check_snapshot!(%Snapshot{name: name, type: type, dials: dials, props: props}) do
    unless is_binary(name), do: raise(ArgumentError, "snapshot name must be a string")
    encode!(:type, type)

    Enum.each(dials, fn {dial, value} ->
      unless is_binary(dial) and is_number(value) do
        raise ArgumentError,
              "snapshot dials map internal-name strings to numbers, got " <>
                "#{inspect(dial)} => #{inspect(value)}"
      end
    end)

    Enum.each(props, fn {key, value} ->
      case key do
        :color ->
          raise ArgumentError, "a snapshot's props can't hold :color; colour is in its dials"

        :type ->
          raise ArgumentError, "a snapshot's props can't hold :type; use its :type field"

        _ ->
          :ok
      end

      encode!(key, value)
    end)
  end

  defp check_unique!(snapshots) do
    names = Enum.map(snapshots, & &1.name)

    case names -- Enum.uniq(names) do
      [] -> :ok
      [name | _] -> raise ArgumentError, "duplicate snapshot name #{inspect(name)}"
    end
  end

  # The internal names of the three colour dials, found by parm code in one
  # request, when `keys` include :color. Handles are released.
  defp color_dials(light, keys, opts) do
    if :color in keys do
      ops =
        [
          {:call, "Scene", []},
          {:invoke, {:result, 0}, "ActorByInternalName", [light.actor.internal]}
        ] ++
          for(code <- @color_codes, do: {:invoke, {:result, 1}, "ParameterByCode", [code]}) ++
          for(i <- 2..4, do: {:invoke, {:result, i}, "InternalName", []})

      case Client.batch(ops, opts) do
        {:ok, results} ->
          # A failed release is not worth failing the caller's call for.
          Ref.release_in(results, opts)
          {:ok, Enum.drop(results, 5)}

        {:error, %Error{kind: :batch_failed, details: %{partial: partial}} = error} ->
          Ref.release_in(partial, opts)
          {:error, error}

        {:error, _} = error ->
          error
      end
    else
      {:ok, nil}
    end
  end

  # One light per entry of `names` (a string, or nil for Poser's default
  # name), made in one request, in the same order. The `doomed` lights are
  # deleted first, in the same request. Nothing to do sends nothing.
  defp create_lights([], [], _opts), do: {:ok, []}

  defp create_lights(names, doomed, opts) do
    deletes =
      doomed
      |> Enum.with_index()
      |> Enum.flat_map(fn {light, i} ->
        [
          Ref.lookup_op({:actor, light.actor.internal}, {:result, 0}, :scene),
          {:invoke, {:result, 1 + 2 * i}, "Delete", []}
        ]
      end)

    {ops, slots} =
      Enum.reduce(names, {[{:call, "Scene", []}] ++ deletes, []}, fn name, {ops, slots} ->
        at = length(ops)
        named = if(name, do: [{:invoke, {:result, at}, "SetName", [name]}], else: [])
        tail = at + length(named) + 1

        added =
          [{:invoke, {:result, 0}, "CreateLight", []}] ++
            named ++
            [{:invoke, {:result, at}, "InternalName", []}, {:invoke, {:result, at}, "Name", []}]

        {ops ++ added, slots ++ [{tail, tail + 1}]}
      end)

    case Client.batch(ops, opts) do
      {:ok, results} ->
        Ref.release_in(results, opts)

        {:ok,
         for {internal, label} <- slots do
           actor = %Actor{
             figure: nil,
             internal: Enum.at(results, internal),
             name: Enum.at(results, label)
           }

           %__MODULE__{actor: actor}
         end}

      {:error, %Error{kind: :batch_failed, details: %{partial: partial}} = error} ->
        Ref.release_in(partial, opts)
        {:error, error}

      {:error, _} = error ->
        error
    end
  end

  defp decode(:color, [r, g, b]), do: {r, g, b}
  defp decode(key, [value]) when key in [:type, :attenuation], do: decode_enum(key, value)
  defp decode(_key, [value]), do: value

  defp decode_all(keys, results) do
    {pairs, []} =
      Enum.map_reduce(keys, results, fn key, rest ->
        {mine, rest} = Enum.split(rest, if(key == :color, do: 3, else: 1))
        {{key, decode(key, mine)}, rest}
      end)

    pairs
  end

  defp decode_enum(key, code) do
    Enum.find_value(@enums[key], code, fn {atom, value} -> value == code && atom end)
  end

  defp encode!(:color, {r, g, b} = color) when is_number(r) and is_number(g) and is_number(b),
    do: color

  defp encode!(:color, other),
    do: raise(ArgumentError, "color must be {r, g, b}, got #{inspect(other)}")

  defp encode!(key, value) when key in [:type, :attenuation] do
    case {value, @enums[key]} do
      {code, _} when is_integer(code) -> code
      {atom, codes} when is_map_key(codes, atom) -> codes[atom]
      {other, _} -> raise ArgumentError, "unknown #{key} #{inspect(other)}"
    end
  end

  defp encode!(key, value) do
    check_key!(key)
    value
  end

  # Replaces each nil in `matched` with a light created for its snapshot, in
  # one request, or sends nothing when none is missing.
  defp fill_missing(snapshots, matched, run) do
    missing = for {snapshot, nil} <- Enum.zip(snapshots, matched), do: snapshot.name

    with {:ok, created} <- create_lights(missing, [], run) do
      {filled, []} =
        Enum.map_reduce(matched, created, fn
          nil, [light | rest] -> {light, rest}
          light, rest -> {light, rest}
        end)

      {:ok, filled}
    end
  end

  # One light per snapshot, nil where none matches, or the first ambiguous
  # name in snapshot order.
  defp match_lights(snapshots, lights) do
    by_name = Enum.group_by(lights, & &1.actor.name)
    found = Enum.map(snapshots, &Map.get(by_name, &1.name, []))

    case Enum.find(found, &match?([_, _ | _], &1)) do
      nil -> {:ok, Enum.map(found, &List.first/1)}
      matches -> {:error, %Error{kind: :ambiguous, details: %{matches: matches}}}
    end
  end

  defp mutate_batch(rows, frame) do
    Enum.reduce(rows, Batch.new(), fn {light, snapshot, present}, acc ->
      dials = Enum.filter(Enum.sort(snapshot.dials), fn {dial, _value} -> dial in present end)
      pairs = [{:type, snapshot.type} | Enum.sort(snapshot.props)] ++ dials

      Enum.reduce(pairs, acc, fn {key, value}, b ->
        add_set(b, light, {key, encode!(key, value)}, nil, frame)
      end)
    end)
  end

  # One snapshot per light: dial names for all lights (two requests), then
  # one batch that reads every property and dial of every light.
  defp read_snapshots(lights, frame, run) do
    prop_keys = [:type | @props |> Map.keys() |> List.delete(:type) |> Enum.sort()]

    with {:ok, rows} <- Ref.children_many(lights, "Parameters", [], run) do
      keys_per_light =
        Enum.map(rows, fn dials -> prop_keys ++ Enum.map(dials, & &1["InternalName"]) end)

      pairs = Enum.zip(lights, keys_per_light)

      with {:ok, results} <- pairs |> snapshot_batch(frame) |> Batch.run(run) do
        {:ok, snapshots_from(pairs, results)}
      end
    end
  end

  defp run_apply([], :merge, _frame, _run), do: {:ok, %{skipped: []}}

  defp run_apply([], :replace, _frame, run) do
    with {:ok, lights} <- Scene.lights(run),
         {:ok, []} <- create_lights([], lights, run) do
      {:ok, %{skipped: []}}
    end
  end

  defp run_apply(snapshots, :merge, frame, run) do
    with {:ok, lights} <- Scene.lights(run),
         {:ok, matched} <- match_lights(snapshots, lights),
         {:ok, targets} <- fill_missing(snapshots, matched, run) do
      write_snapshots(snapshots, targets, frame, run)
    end
  end

  defp run_apply(snapshots, :replace, frame, run) do
    with {:ok, lights} <- Scene.lights(run),
         {:ok, targets} <- create_lights(Enum.map(snapshots, & &1.name), lights, run) do
      write_snapshots(snapshots, targets, frame, run)
    end
  end

  defp set_unless_empty(_light, rest, _opts) when map_size(rest) == 0, do: {:ok, :ok}
  defp set_unless_empty(light, rest, opts), do: set(light, rest, opts)

  defp skipped(rows) do
    for {_light, snapshot, present} <- rows,
        {dial, _value} <- Enum.sort_by(snapshot.dials, &elem(&1, 0)),
        dial not in present,
        do: {snapshot.name, dial}
  end

  defp snapshot_batch(pairs, frame) do
    Enum.reduce(pairs, Batch.new(), fn {light, keys}, acc ->
      Enum.reduce(keys, acc, &add_get(&2, light, &1, nil, frame))
    end)
  end

  defp snapshots_from(pairs, results) do
    {snapshots, []} =
      Enum.map_reduce(pairs, results, fn {light, keys}, rest ->
        {mine, rest} = Enum.split(rest, length(keys))
        {build_snapshot(light, keys, mine), rest}
      end)

    snapshots
  end

  defp split(opts) do
    opts = Keyword.validate!(opts, [:frame, :mode, :server, :timeout])
    {Batch.check_frame!(opts[:frame]), Keyword.take(opts, [:server, :timeout])}
  end

  # Reads each target's dial names, then writes every snapshot onto its
  # target in one batch.
  defp write_snapshots(snapshots, targets, frame, run) do
    with {:ok, dial_rows} <- Ref.children_many(targets, "Parameters", [], run),
         present = Enum.map(dial_rows, fn rows -> Enum.map(rows, & &1["InternalName"]) end),
         rows = Enum.zip([targets, snapshots, present]),
         {:ok, _} <- rows |> mutate_batch(frame) |> Batch.run(run) do
      {:ok, %{skipped: skipped(rows)}}
    end
  end

  defimpl Inspect do
    def inspect(%{actor: %{name: name}}, _opts), do: "#ExPoser.Light<#{name}>"
  end
end
