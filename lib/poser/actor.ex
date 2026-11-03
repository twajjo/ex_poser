defmodule Poser.Actor do
  @moduledoc """
  A Poser actor: a body part, prop, camera or light.

  Body parts have `figure` set; props, cameras and lights have `figure: nil`.

      iex> fig = %Poser.Figure{internal: "figure 1", name: "Andy"}
      iex> inspect(%Poser.Actor{figure: fig, internal: "lforearm", name: "Left Forearm"})
      "#Poser.Actor<figure 1/lforearm>"
      iex> inspect(%Poser.Actor{figure: nil, internal: "ball", name: "Ball"})
      "#Poser.Actor<ball>"
  """

  @enforce_keys [:internal, :name]
  defstruct [:figure, :internal, :name]

  @type t :: %__MODULE__{
          figure: Poser.Figure.t() | nil,
          internal: String.t(),
          name: String.t()
        }

  alias Poser.{Batch, Error, Parameter, Ref}

  @typedoc "A dial value as Poser reports it; NaN and infinities arrive as atoms."
  @type value :: float() | :nan | :infinity | :neg_infinity

  @doc group: "Parameters"
  @doc """
  Lists the actor's dials, in Poser's order. Options: `:server`, `:timeout`.

  ## Examples

      Poser.Actor.parameters(hip)
      #=> {:ok, [#Poser.Parameter<figure 1/hip/xtran>, ...]}
  """
  @spec parameters(t(), keyword()) :: {:ok, [Parameter.t()]} | {:error, Error.t()}
  def parameters(%__MODULE__{} = a, opts \\ []) do
    with {:ok, rows} <- Ref.children(a, "Parameters", [], opts),
         do: {:ok, Enum.map(rows, &build_parameter(a, &1))}
  end

  @doc group: "Parameters"
  @doc """
  Like `parameters/2`, but returns the list and raises `Poser.Error` on failure.

  ## Examples

      Poser.Actor.parameters!(hip)
      #=> [#Poser.Parameter<figure 1/hip/xtran>, ...]
  """
  @spec parameters!(t(), keyword()) :: [Parameter.t()]
  def parameters!(a, opts \\ []), do: a |> parameters(opts) |> Ref.unwrap!()

  @doc group: "Parameters"
  @doc """
  Finds a dial by internal name (`"xtran"`) or by display name (`"xTran"`).

  The internal name is tried first and costs one round trip. A display name
  costs two more and can match several dials, which gives `:ambiguous` with
  the candidates under `details.matches`. No match gives `:not_found`.
  Options: `:server`, `:timeout`.

  ## Examples

      Poser.Actor.parameter(hip, "xtran")
      #=> {:ok, #Poser.Parameter<figure 1/hip/xtran>}
      Poser.Actor.parameter(hip, "xTran")
      #=> {:ok, #Poser.Parameter<figure 1/hip/xtran>}
      Poser.Actor.parameter(hip, "nope")
      #=> {:error, %Poser.Error{kind: :not_found, ...}}
  """
  @spec parameter(t(), String.t(), keyword()) :: {:ok, Parameter.t()} | {:error, Error.t()}
  def parameter(%__MODULE__{} = a, name, opts \\ []) when is_binary(name) do
    guess = %Parameter{actor: a, internal: name, name: name}

    batch =
      Batch.new() |> Batch.call(guess, "InternalName", []) |> Batch.call(guess, "Name", [])

    case Batch.run(batch, run_opts(opts)) do
      {:ok, [internal, display]} ->
        {:ok, %Parameter{actor: a, internal: internal, name: display}}

      {:error, %Error{kind: :not_found, details: %{path: path}}} ->
        if path == Ref.path(guess) do
          Ref.find(a, "Parameters", name, &build_parameter(a, &1), opts)
        else
          {:error, Error.not_found(path)}
        end

      {:error, _} = error ->
        error
    end
  end

  @doc group: "Parameters"
  @doc """
  Like `parameter/3`, but returns the struct and raises `Poser.Error` on failure.

  ## Examples

      Poser.Actor.parameter!(hip, "xtran")
      #=> #Poser.Parameter<figure 1/hip/xtran>
  """
  @spec parameter!(t(), String.t(), keyword()) :: Parameter.t()
  def parameter!(a, name, opts \\ []), do: a |> parameter(name, opts) |> Ref.unwrap!()

  @doc group: "Values"
  @doc """
  Reads one dial's value by internal name. The value is a `t:value/0`.
  Options: `:server`, `:timeout`.

  ## Examples

      Poser.Actor.get(hip, "xtran")
      #=> {:ok, 0.0}
  """
  @spec get(t(), String.t(), keyword()) :: {:ok, value()} | {:error, Error.t()}
  def get(%__MODULE__{} = a, internal, opts \\ []) when is_binary(internal) do
    with {:ok, [v]} <- Batch.new() |> Batch.get(parm(a, internal)) |> Batch.run(run_opts(opts)),
         do: {:ok, v}
  end

  @doc group: "Values"
  @doc """
  Like `get/3`, but returns the value and raises `Poser.Error` on failure.

  ## Examples

      Poser.Actor.get!(hip, "xtran")
      #=> 0.0
  """
  @spec get!(t(), String.t(), keyword()) :: value()
  def get!(a, internal, opts \\ []), do: a |> get(internal, opts) |> Ref.unwrap!()

  @doc group: "Values"
  @doc """
  Sets dials by internal name, either one (`set(a, "xtran", 1.0)`) or several
  in one round trip (`set(a, %{"xtran" => 1.0, "ytran" => 2.0})`). Integers are
  sent as floats. Poser keys each value at the current frame. Options:
  `:server`, `:timeout`.

  ## Examples

      Poser.Actor.set(hip, "xtran", 0.25)
      #=> {:ok, :ok}
      Poser.Actor.set(hip, %{"xtran" => 0.25, "ytran" => 1})
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

      Poser.Actor.set(hip, "xtran", 0.25, timeout: 10_000)
      #=> {:ok, :ok}
  """
  @spec set(t(), String.t(), number(), keyword()) :: {:ok, :ok} | {:error, Error.t()}
  def set(%__MODULE__{} = a, internal, value, opts)
      when is_binary(internal) and is_number(value) and is_list(opts),
      do: set_all(a, [{internal, value}], opts)

  @doc group: "Values"
  @doc """
  Like `set/3`, but returns `:ok` and raises `Poser.Error` on failure.

  ## Examples

      Poser.Actor.set!(hip, "xtran", 0.25)
      :ok
  """
  @spec set!(t(), String.t() | %{String.t() => number()}, number() | keyword()) :: :ok
  def set!(a, name_or_map, value_or_opts \\ []),
    do: a |> set(name_or_map, value_or_opts) |> Ref.unwrap!()

  @doc group: "Values"
  @doc """
  Like `set/4`, but returns `:ok` and raises `Poser.Error` on failure.

  ## Examples

      Poser.Actor.set!(hip, "xtran", 0.25, timeout: 10_000)
      :ok
  """
  @spec set!(t(), String.t(), number(), keyword()) :: :ok
  def set!(a, internal, value, opts), do: a |> set(internal, value, opts) |> Ref.unwrap!()

  defp set_all(a, pairs, opts) do
    batch = Enum.reduce(pairs, Batch.new(), fn {k, v}, b -> Batch.set(b, parm(a, k), v) end)
    with {:ok, _} <- Batch.run(batch, run_opts(opts)), do: {:ok, :ok}
  end

  @doc group: "Values"
  @doc """
  Reads every dial at once, as a map from internal name to `t:value/0`.
  Two round trips however many dials there are. Options: `:server`, `:timeout`.

  ## Examples

      Poser.Actor.values(hip)
      #=> {:ok, %{"xtran" => 0.0, "ytran" => 0.0}}
  """
  @spec values(t(), keyword()) :: {:ok, %{String.t() => value()}} | {:error, Error.t()}
  def values(%__MODULE__{} = a, opts \\ []) do
    with {:ok, rows} <- Ref.children(a, "Parameters", ["Value"], opts),
         do: {:ok, Map.new(rows, &{&1["InternalName"], &1["Value"]})}
  end

  @doc group: "Values"
  @doc """
  Like `values/2`, but returns the map and raises `Poser.Error` on failure.

  ## Examples

      Poser.Actor.values!(hip)
      #=> %{"xtran" => 0.0, "ytran" => 0.0}
  """
  @spec values!(t(), keyword()) :: %{String.t() => value()}
  def values!(a, opts \\ []), do: a |> values(opts) |> Ref.unwrap!()

  @doc group: "Escape hatch"
  @doc """
  The actor's `%Poser.Handle{}`, for calls this library doesn't wrap.

  The handle belongs to the caller: release it with `Poser.Client.release/2`.
  Options: `:server`, `:timeout`.

  ## Examples

      {:ok, h} = Poser.Actor.handle(hip)
      Poser.Client.invoke(h, "Name")
      #=> {:ok, "hip"}
      Poser.Client.release([h])
  """
  @spec handle(t(), keyword()) :: {:ok, Poser.Handle.t()} | {:error, Error.t()}
  def handle(%__MODULE__{} = a, opts \\ []) do
    # The first op makes a missing actor :not_found; the second fetches the handle
    # from the actor's parent, since a ref can't hand out its own handle.
    parent = a.figure || :scene

    batch =
      Batch.new()
      |> Batch.call(a, "InternalName", [])
      |> Batch.call(parent, "ActorByInternalName", [a.internal])

    with {:ok, [_, %Poser.Handle{} = h]} <- Batch.run(batch, run_opts(opts)), do: {:ok, h}
  end

  @doc group: "Escape hatch"
  @doc """
  Like `handle/2`, but returns the handle and raises `Poser.Error` on failure.

  ## Examples

      h = Poser.Actor.handle!(hip)
      Poser.Client.release([h])
  """
  @spec handle!(t(), keyword()) :: Poser.Handle.t()
  def handle!(a, opts \\ []), do: a |> handle(opts) |> Ref.unwrap!()

  defp parm(a, internal), do: %Parameter{actor: a, internal: internal, name: internal}

  defp build_parameter(a, row),
    do: %Parameter{actor: a, internal: row["InternalName"], name: row["Name"]}

  defp run_opts(opts), do: Keyword.validate!(opts, [:server, :timeout])

  defimpl Inspect do
    def inspect(actor, _opts), do: "#Poser.Actor<#{Poser.Ref.path_string(actor)}>"
  end
end
