defmodule ExPoser.Actor do
  @moduledoc """
  An actor: a figure's body part, or a scene-level prop, camera or light.

  Body parts have `figure` set and are found through their figure. Props,
  cameras and lights have `figure: nil` and are found through
  `ExPoser.Scene`. `internal` is Poser's internal name and the key; `name` is
  the GUI label.

      iex> fig = %ExPoser.Figure{internal: "figure 1", name: "Andy"}
      iex> inspect(%ExPoser.Actor{figure: fig, internal: "lforearm", name: "Left Forearm"})
      "#ExPoser.Actor<figure 1/lforearm>"
      iex> inspect(%ExPoser.Actor{figure: nil, internal: "ball", name: "Ball"})
      "#ExPoser.Actor<ball>"

  ## Getting one

  - Body parts: `ExPoser.Figure.actors/2` and `ExPoser.Figure.actor/3`.
  - Props, cameras and lights: `ExPoser.Scene.actors/1` and `ExPoser.Scene.actor/2`.

  ## Common tasks

  `get/3`, `set/3` and `values/2` read and write dials by internal name
  without a `%ExPoser.Parameter{}`. `set/3` with a map writes several dials in
  one request. Each set is keyed at the current frame; for other frames use
  `ExPoser.Parameter.set_value/3` or `ExPoser.Batch.set/4` with `frame:`.

      {:ok, values} = ExPoser.Actor.values(arm)    # %{"yrot" => 0.0, ...}
      {:ok, :ok} = ExPoser.Actor.set(arm, %{"yrot" => 30.0, "xrot" => -10.0})
      {:ok, bend} = ExPoser.Actor.parameter(arm, "Bend")

  See [Posing](posing.md).
  """

  @enforce_keys [:internal, :name]
  defstruct [:figure, :internal, :name]

  @type t :: %__MODULE__{
          figure: ExPoser.Figure.t() | nil,
          internal: String.t(),
          name: String.t()
        }

  alias ExPoser.{Batch, Error, Parameter, Ref}

  @typedoc "A dial value as Poser reports it; NaN and infinities arrive as atoms."
  @type value :: float() | :nan | :infinity | :neg_infinity

  @doc group: "Values"
  @doc """
  Reads one dial's value by internal name. The value is a `t:value/0`.
  Options: `:server`, `:timeout`.

  ## Examples

      ExPoser.Actor.get(hip, "xtran")
      #=> {:ok, 0.0}
  """
  @spec get(t(), String.t(), keyword()) :: {:ok, value()} | {:error, Error.t()}
  def get(%__MODULE__{} = a, internal, opts \\ []) when is_binary(internal) do
    with {:ok, [v]} <- Batch.new() |> Batch.get(parm(a, internal)) |> Batch.run(run_opts(opts)),
         do: {:ok, v}
  end

  @doc group: "Values"
  @doc """
  Like `get/3`, but returns the value and raises `ExPoser.Error` on failure.

  ## Examples

      ExPoser.Actor.get!(hip, "xtran")
      #=> 0.0
  """
  @spec get!(t(), String.t(), keyword()) :: value()
  def get!(a, internal, opts \\ []), do: a |> get(internal, opts) |> Ref.unwrap!()

  @doc group: "Escape hatch"
  @doc """
  The actor's `%ExPoser.Handle{}`, for calls this library doesn't wrap.

  The handle belongs to the caller: release it with `ExPoser.Client.release/2`.
  A path that doesn't resolve gives `:not_found` with `details.path` and
  `details.index` nil. Options: `:server`, `:timeout`.

  ## Examples

      {:ok, h} = ExPoser.Actor.handle(hip)
      ExPoser.Client.invoke(h, "Name")
      #=> {:ok, "hip"}
      ExPoser.Client.release([h])
  """
  @spec handle(t(), keyword()) :: {:ok, ExPoser.Handle.t()} | {:error, Error.t()}
  def handle(%__MODULE__{} = a, opts \\ []) do
    # The first op makes a missing actor :not_found; the second fetches the handle
    # from the actor's parent, since a ref can't hand out its own handle.
    parent = a.figure || :scene

    batch =
      Batch.new()
      |> Batch.call(a, "InternalName", [])
      |> Batch.call(parent, "ActorByInternalName", [a.internal])

    batch |> Batch.run(run_opts(opts)) |> to_handle(a)
  end

  @doc group: "Escape hatch"
  @doc """
  Like `handle/2`, but returns the handle and raises `ExPoser.Error` on failure.

  ## Examples

      h = ExPoser.Actor.handle!(hip)
      ExPoser.Client.release([h])
  """
  @spec handle!(t(), keyword()) :: ExPoser.Handle.t()
  def handle!(a, opts \\ []), do: a |> handle(opts) |> Ref.unwrap!()

  @doc group: "Parameters"
  @doc """
  Finds a dial by internal name (`"xtran"`) or by display name (`"xTran"`).

  The internal name is tried first and costs one round trip. A display name
  costs two more and can match several dials, which gives `:ambiguous` with
  the candidates under `details.matches`. No match gives `:not_found`.
  Display names repeat within an actor: on a forearm, `"xrot"` and `"twistx"`
  are both labelled "Twist", so `"Twist"` is `:ambiguous` there.
  Options: `:server`, `:timeout`.

  ## Examples

      ExPoser.Actor.parameter(hip, "xtran")
      #=> {:ok, #ExPoser.Parameter<figure 1/hip/xtran>}
      ExPoser.Actor.parameter(hip, "xTran")
      #=> {:ok, #ExPoser.Parameter<figure 1/hip/xtran>}
      ExPoser.Actor.parameter(hip, "nope")
      #=> {:error, %ExPoser.Error{kind: :not_found, ...}}
  """
  @spec parameter(t(), String.t(), keyword()) :: {:ok, Parameter.t()} | {:error, Error.t()}
  def parameter(%__MODULE__{} = a, name, opts \\ []) when is_binary(name) do
    opts = run_opts(opts)
    guess = %Parameter{actor: a, internal: name, name: name}
    Ref.lookup(guess, a, "Parameters", name, &build_parameter(a, &1), opts)
  end

  @doc group: "Parameters"
  @doc """
  Like `parameter/3`, but returns the struct and raises `ExPoser.Error` on failure.

  ## Examples

      ExPoser.Actor.parameter!(hip, "xtran")
      #=> #ExPoser.Parameter<figure 1/hip/xtran>
  """
  @spec parameter!(t(), String.t(), keyword()) :: Parameter.t()
  def parameter!(a, name, opts \\ []), do: a |> parameter(name, opts) |> Ref.unwrap!()

  @doc group: "Parameters"
  @doc """
  Lists the actor's dials, in Poser's order. Options: `:server`, `:timeout`.

  ## Examples

      ExPoser.Actor.parameters(hip)
      #=> {:ok, [#ExPoser.Parameter<figure 1/hip/xtran>, ...]}
  """
  @spec parameters(t(), keyword()) :: {:ok, [Parameter.t()]} | {:error, Error.t()}
  def parameters(%__MODULE__{} = a, opts \\ []) do
    opts = run_opts(opts)

    with {:ok, rows} <- Ref.children(a, "Parameters", [], opts),
         do: {:ok, Enum.map(rows, &build_parameter(a, &1))}
  end

  @doc group: "Parameters"
  @doc """
  Like `parameters/2`, but returns the list and raises `ExPoser.Error` on failure.

  ## Examples

      ExPoser.Actor.parameters!(hip)
      #=> [#ExPoser.Parameter<figure 1/hip/xtran>, ...]
  """
  @spec parameters!(t(), keyword()) :: [Parameter.t()]
  def parameters!(a, opts \\ []), do: a |> parameters(opts) |> Ref.unwrap!()

  @doc group: "Values"
  @doc """
  Sets dials by internal name, either one (`set(a, "xtran", 1.0)`) or several
  in one round trip (`set(a, %{"xtran" => 1.0, "ytran" => 2.0})`). Integers are
  sent as floats. Poser keys each value at the current frame. Options:
  `:server`, `:timeout`.

  ## Examples

      ExPoser.Actor.set(hip, "xtran", 0.25)
      #=> {:ok, :ok}
      ExPoser.Actor.set(hip, %{"xtran" => 0.25, "ytran" => 1})
      #=> {:ok, :ok}
  """
  @spec set(t(), String.t() | %{String.t() => number()}, number() | keyword()) ::
          {:ok, :ok} | {:error, Error.t()}
  def set(a, name_or_map, value_or_opts \\ [])

  def set(%__MODULE__{} = a, values, opts) when is_map(values) and is_list(opts),
    do: set_all(a, Enum.to_list(values), opts)

  def set(%__MODULE__{} = a, internal, value) when is_binary(internal) and is_number(value),
    do: set(a, internal, value, [])

  @doc group: "Values"
  @doc """
  Sets one dial; see `set/3`.

  ## Examples

      ExPoser.Actor.set(hip, "xtran", 0.25, timeout: 10_000)
      #=> {:ok, :ok}
  """
  @spec set(t(), String.t(), number(), keyword()) :: {:ok, :ok} | {:error, Error.t()}
  def set(%__MODULE__{} = a, internal, value, opts)
      when is_binary(internal) and is_number(value) and is_list(opts),
      do: set_all(a, [{internal, value}], opts)

  @doc group: "Values"
  @doc """
  Like `set/3`, but returns `:ok` and raises `ExPoser.Error` on failure.

  ## Examples

      ExPoser.Actor.set!(hip, "xtran", 0.25)
      #=> :ok
  """
  @spec set!(t(), String.t() | %{String.t() => number()}, number() | keyword()) :: :ok
  def set!(a, name_or_map, value_or_opts \\ []),
    do: a |> set(name_or_map, value_or_opts) |> Ref.unwrap!()

  @doc group: "Values"
  @doc """
  Like `set/4`, but returns `:ok` and raises `ExPoser.Error` on failure.

  ## Examples

      ExPoser.Actor.set!(hip, "xtran", 0.25, timeout: 10_000)
      #=> :ok
  """
  @spec set!(t(), String.t(), number(), keyword()) :: :ok
  def set!(a, internal, value, opts), do: a |> set(internal, value, opts) |> Ref.unwrap!()

  @doc false
  @spec to_handle({:ok, list()} | {:error, Error.t()}, t()) ::
          {:ok, ExPoser.Handle.t()} | {:error, Error.t()}
  def to_handle({:ok, [_, %ExPoser.Handle{} = h]}, _a), do: {:ok, h}
  def to_handle({:ok, [_, nil]}, a), do: {:error, Error.not_found(Ref.path(a))}

  def to_handle({:error, %Error{kind: :not_found} = e}, _a),
    do: {:error, %{e | details: %{e.details | index: nil}}}

  def to_handle({:error, _} = error, _a), do: error

  @doc group: "Values"
  @doc """
  Reads every dial at once, as a map from internal name to `t:value/0`.
  Two round trips however many dials there are. Options: `:server`, `:timeout`.

  ## Examples

      ExPoser.Actor.values(hip)
      #=> {:ok, %{"xtran" => 0.0, "ytran" => 0.0}}
  """
  @spec values(t(), keyword()) :: {:ok, %{String.t() => value()}} | {:error, Error.t()}
  def values(%__MODULE__{} = a, opts \\ []) do
    opts = run_opts(opts)

    with {:ok, rows} <- Ref.children(a, "Parameters", ["Value"], opts),
         do: {:ok, Map.new(rows, &{&1["InternalName"], &1["Value"]})}
  end

  @doc group: "Values"
  @doc """
  Like `values/2`, but returns the map and raises `ExPoser.Error` on failure.

  ## Examples

      ExPoser.Actor.values!(hip)
      #=> %{"xtran" => 0.0, "ytran" => 0.0}
  """
  @spec values!(t(), keyword()) :: %{String.t() => value()}
  def values!(a, opts \\ []), do: a |> values(opts) |> Ref.unwrap!()

  defp build_parameter(a, row),
    do: %Parameter{actor: a, internal: row["InternalName"], name: row["Name"]}

  defp parm(a, internal), do: %Parameter{actor: a, internal: internal, name: internal}

  defp run_opts(opts), do: Keyword.validate!(opts, [:server, :timeout])

  defp set_all(a, pairs, opts) do
    batch = Enum.reduce(pairs, Batch.new(), fn {k, v}, b -> Batch.set(b, parm(a, k), v) end)
    with {:ok, _} <- Batch.run(batch, run_opts(opts)), do: {:ok, :ok}
  end

  defimpl Inspect do
    def inspect(actor, _opts), do: "#ExPoser.Actor<#{ExPoser.Ref.path_string(actor)}>"
  end
end
