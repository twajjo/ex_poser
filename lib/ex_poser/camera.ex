defmodule ExPoser.Camera do
  @moduledoc """
  A camera: a scene-level actor that Poser reports as a camera.

  It wraps its `ExPoser.Actor`, which holds the internal name (the key) and
  the GUI label. Find cameras with `ExPoser.Scene.cameras/1` and
  `ExPoser.Scene.camera/2`.

      iex> actor = %ExPoser.Actor{figure: nil, internal: "MAIN_CAMERA", name: "Main Camera"}
      iex> inspect(%ExPoser.Camera{actor: actor})
      "#ExPoser.Camera<Main Camera>"
  """

  @enforce_keys [:actor]
  defstruct [:actor]

  @type t :: %__MODULE__{actor: ExPoser.Actor.t()}

  alias ExPoser.{Actor, Batch, Error, Light, Ref, Scene}
  alias ExPoser.Camera.Snapshot

  @doc group: "Properties"
  @doc """
  Reads one dial (a string, its internal name, such as `"focal"`) or several (a list of them,
  which gives a map from each name to its value). Options: `:server`,
  `:timeout`, and `:frame`. Any key that isn't a string raises `ArgumentError`.

  ## Examples

      ExPoser.Camera.get(main, "focal")
      #=> {:ok, 55.0}
  """
  @spec get(t(), String.t() | [String.t()], keyword()) :: {:ok, term()} | {:error, Error.t()}
  def get(camera, name_or_names, opts \\ [])

  def get(%__MODULE__{} = camera, names, opts) when is_list(names) do
    Enum.each(names, &check_key!/1)
    Light.run_get(camera, names, opts)
  end

  def get(%__MODULE__{} = camera, name, opts) do
    with {:ok, map} <- get(camera, [name], opts), do: {:ok, Map.fetch!(map, name)}
  end

  @doc group: "Properties"
  @doc """
  Like `get/3`, but returns the value and raises `ExPoser.Error` on failure.

  ## Examples

      ExPoser.Camera.get!(main, "focal")
      #=> 55.0
  """
  @spec get!(t(), String.t() | [String.t()], keyword()) :: term()
  def get!(camera, name_or_names, opts \\ []),
    do: camera |> get(name_or_names, opts) |> Ref.unwrap!()

  @doc group: "Escape hatch"
  @doc """
  The camera's `%ExPoser.Handle{}`, for calls this library doesn't wrap. Like
  `ExPoser.Actor.handle/2`, whose rules apply: release the handle with
  `ExPoser.Client.release/2`.
  """
  @spec handle(t(), keyword()) :: {:ok, ExPoser.Handle.t()} | {:error, ExPoser.Error.t()}
  def handle(%__MODULE__{actor: actor}, opts \\ []), do: Actor.handle(actor, opts)

  @doc group: "Aiming"
  @doc """
  Aims the camera at `target`: any light, camera, figure, actor or parameter
  struct, or `nil` to clear the target. See `ExPoser.Light.point_at/3`.

  ## Examples

      ExPoser.Camera.point_at(main, key)
      #=> {:ok, :ok}
  """
  @spec point_at(t(), Ref.ref() | nil, keyword()) :: {:ok, :ok} | {:error, Error.t()}
  def point_at(%__MODULE__{} = camera, target, opts \\ []),
    do: Light.run_point_at(camera, target, opts)

  @doc group: "Aiming"
  @doc """
  Like `point_at/3`, but returns `:ok` and raises `ExPoser.Error` on failure.

  ## Examples

      ExPoser.Camera.point_at!(main, key)
      #=> :ok
  """
  @spec point_at!(t(), Ref.ref() | nil, keyword()) :: :ok
  def point_at!(%__MODULE__{} = camera, target, opts \\ []),
    do: camera |> point_at(target, opts) |> Ref.unwrap!()

  @doc group: "Properties"
  @doc """
  Sets one dial (`set(camera, name, value, opts)`) or several
  (`set(camera, %{name => value}, opts)`), in one batch. Options: `:server`,
  `:timeout`, and `:frame`. Any key that isn't a string raises `ArgumentError`
  before anything is sent.

  ## Examples

      ExPoser.Camera.set(main, %{"focal" => 50.0})
      #=> {:ok, :ok}
  """
  @spec set(t(), map()) :: {:ok, :ok} | {:error, Error.t()}
  def set(%__MODULE__{} = camera, attrs) when is_map(attrs), do: set(camera, attrs, [])

  @doc group: "Properties"
  @doc """
  Sets a map of dials with options, or one dial and value. See `set/2`.

  ## Examples

      ExPoser.Camera.set(main, %{"focal" => 50.0}, frame: 4)
      #=> {:ok, :ok}
      ExPoser.Camera.set(main, "focal", 50.0)
      #=> {:ok, :ok}
  """
  @spec set(t(), map(), keyword()) :: {:ok, :ok} | {:error, Error.t()}
  @spec set(t(), String.t(), term()) :: {:ok, :ok} | {:error, Error.t()}
  def set(%__MODULE__{} = camera, attrs, opts) when is_map(attrs) and is_list(opts) do
    pairs = Map.to_list(attrs)
    Enum.each(pairs, fn {key, _value} -> check_key!(key) end)
    Light.run_set(camera, pairs, opts)
  end

  def set(%__MODULE__{} = camera, key, value) when not is_map(key) and not is_list(value),
    do: set(camera, key, value, [])

  @doc group: "Properties"
  @doc """
  Sets one dial and value, with options. See `set/2`.

  ## Examples

      ExPoser.Camera.set(main, "focal", 50.0, frame: 4)
      #=> {:ok, :ok}
  """
  @spec set(t(), String.t(), term(), keyword()) :: {:ok, :ok} | {:error, Error.t()}
  def set(%__MODULE__{} = camera, key, value, opts), do: set(camera, %{key => value}, opts)

  @doc group: "Properties"
  @doc """
  Like `set/2`, `set/3` and `set/4`, but returns `:ok` and raises
  `ExPoser.Error` on failure.

  ## Examples

      ExPoser.Camera.set!(main, "focal", 50.0)
      #=> :ok
  """
  @spec set!(t(), map()) :: :ok
  def set!(%__MODULE__{} = camera, attrs) when is_map(attrs), do: set!(camera, attrs, [])

  @doc group: "Properties"
  @doc """
  Sets a map of dials with options, or one dial and value, and returns `:ok`.
  See `set!/2`.

  ## Examples

      ExPoser.Camera.set!(main, %{"focal" => 50.0}, frame: 4)
      #=> :ok
  """
  @spec set!(t(), map(), keyword()) :: :ok
  @spec set!(t(), String.t(), term()) :: :ok
  def set!(%__MODULE__{} = camera, attrs, opts) when is_map(attrs) and is_list(opts),
    do: camera |> set(attrs, opts) |> Ref.unwrap!()

  def set!(%__MODULE__{} = camera, key, value) when not is_map(key) and not is_list(value),
    do: set!(camera, key, value, [])

  @doc group: "Properties"
  @doc """
  Sets one dial and value, with options, and returns `:ok`. See `set!/2`.

  ## Examples

      ExPoser.Camera.set!(main, "focal", 50.0, frame: 4)
      #=> :ok
  """
  @spec set!(t(), String.t(), term(), keyword()) :: :ok
  def set!(%__MODULE__{} = camera, key, value, opts),
    do: camera |> set(key, value, opts) |> Ref.unwrap!()

  @doc group: "Snapshots"
  @doc """
  Reads the camera's state at one frame as an `ExPoser.Camera.Snapshot`: its
  name and every dial. Options: `:server`, `:timeout`, and `:frame` (default:
  the scene's current frame). An unknown option raises `ArgumentError` before
  any request.

  While the reads fit in one `ExPoser.Batch` chunk (2000 wire ops), it takes
  three batch round trips: the dial names (two), then one batch that reads
  every dial. Each is followed by a request that releases its handles,
  so six requests in all.

  ## Examples

      ExPoser.Camera.snapshot(main, frame: 2)
      #=> {:ok, %ExPoser.Camera.Snapshot{name: "Main Camera", dials: %{"focal" => 55.0, ...}}}
  """
  @spec snapshot(t(), keyword()) :: {:ok, Snapshot.t()} | {:error, Error.t()}
  def snapshot(%__MODULE__{} = camera, opts \\ []) do
    {frame, run} = split(opts)

    with {:ok, [snapshot]} <- read_snapshots([camera], frame, run), do: {:ok, snapshot}
  end

  @doc group: "Snapshots"
  @doc """
  Like `snapshot/2`, but returns the snapshot and raises `ExPoser.Error` on
  failure.

  ## Examples

      ExPoser.Camera.snapshot!(main)
      #=> %ExPoser.Camera.Snapshot{name: "Main Camera", ...}
  """
  @spec snapshot!(t(), keyword()) :: Snapshot.t()
  def snapshot!(%__MODULE__{} = camera, opts \\ []),
    do: camera |> snapshot(opts) |> Ref.unwrap!()

  @doc group: "Snapshots"
  @doc """
  Snapshots every camera in the scene, in `ExPoser.Scene.cameras/1` order, at
  one frame. Options: `:server`, `:timeout`, and `:frame`. The number of
  requests does not grow with the number of cameras while the reads fit in one
  `ExPoser.Batch` chunk (2000 wire ops): five batch round trips, the list
  (two), the dial names (two) and one batch that reads everything, each
  followed by a request that releases its handles, so ten requests in all.

  ## Examples

      ExPoser.Camera.snapshot_all()
      #=> {:ok, [%ExPoser.Camera.Snapshot{name: "Main Camera", ...}, ...]}
  """
  @spec snapshot_all(keyword()) :: {:ok, [Snapshot.t()]} | {:error, Error.t()}
  def snapshot_all(opts \\ []) do
    {frame, run} = split(opts)

    with {:ok, cameras} <- Scene.cameras(run), do: read_snapshots(cameras, frame, run)
  end

  @doc group: "Snapshots"
  @doc """
  Like `snapshot_all/1`, but returns the list and raises `ExPoser.Error` on
  failure.

  ## Examples

      ExPoser.Camera.snapshot_all!()
      #=> [%ExPoser.Camera.Snapshot{name: "Main Camera", ...}, ...]
  """
  @spec snapshot_all!(keyword()) :: [Snapshot.t()]
  def snapshot_all!(opts \\ []), do: opts |> snapshot_all() |> Ref.unwrap!()

  defp check_key!(key) when is_binary(key), do: :ok

  defp check_key!(key),
    do: raise(ArgumentError, "a camera takes dial names (strings), got #{inspect(key)}")

  # One snapshot per camera: dial names for all cameras (two requests), then
  # one batch that reads every dial of every camera.
  defp read_snapshots(cameras, frame, run) do
    with {:ok, rows} <- Ref.children_many(cameras, "Parameters", [], run) do
      pairs =
        Enum.zip(cameras, Enum.map(rows, fn dials -> Enum.map(dials, & &1["InternalName"]) end))

      batch =
        Enum.reduce(pairs, Batch.new(), fn {camera, keys}, acc ->
          Enum.reduce(keys, acc, &Batch.get(&2, Light.dial(camera.actor, &1), frame: frame))
        end)

      with {:ok, results} <- Batch.run(batch, run) do
        {:ok, snapshots_from(pairs, results)}
      end
    end
  end

  defp snapshots_from(pairs, results) do
    {snapshots, []} =
      Enum.map_reduce(pairs, results, fn {camera, keys}, rest ->
        {mine, rest} = Enum.split(rest, length(keys))

        {%Snapshot{name: camera.actor.name, dials: Map.new(Enum.zip(keys, mine))}, rest}
      end)

    snapshots
  end

  defp split(opts) do
    opts = Keyword.validate!(opts, [:frame, :server, :timeout])
    {opts[:frame], Keyword.take(opts, [:server, :timeout])}
  end

  defimpl Inspect do
    def inspect(%{actor: %{name: name}}, _opts), do: "#ExPoser.Camera<#{name}>"
  end
end
