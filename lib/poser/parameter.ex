defmodule Poser.Parameter do
  @moduledoc """
  A Poser dial (a "parm" in PoserPython) on an actor.

  Every function takes one trailing options list: `:server` and `:timeout`
  (as for `Poser.Batch.run/2`) and, where a frame makes sense, `:frame`
  (0-based). Each call is a single round trip (`keyframes/2` takes one per
  key), leaves the scene's current frame where it was, and releases every
  handle it creates, except the one `handle/2` returns. To combine several
  reads and writes in one round trip, use `Poser.Batch` directly.

      iex> fig = %Poser.Figure{internal: "figure 1", name: "Andy"}
      iex> actor = %Poser.Actor{figure: fig, internal: "lforearm", name: "Left Forearm"}
      iex> inspect(%Poser.Parameter{actor: actor, internal: "bend", name: "Bend"})
      "#Poser.Parameter<figure 1/lforearm/bend>"
  """

  @enforce_keys [:actor, :internal, :name]
  defstruct [:actor, :internal, :name]

  alias Poser.{Batch, Error, Ref}

  @type t :: %__MODULE__{actor: Poser.Actor.t(), internal: String.t(), name: String.t()}

  @doc group: "Values"
  @doc """
  Reads the value, as a float. Options: `:frame` (default: the current frame).

  ## Examples

      Poser.Parameter.value(bend)
      #=> {:ok, 0.0}
      Poser.Parameter.value(bend, frame: 12)
      #=> {:ok, 30.0}
  """
  @spec value(t(), keyword()) :: {:ok, float()} | {:error, Error.t()}
  def value(%__MODULE__{} = p, opts \\ []) do
    {op, run} = split(opts)
    with {:ok, [v]} <- Batch.new() |> Batch.get(p, op) |> Batch.run(run), do: {:ok, v}
  end

  @doc group: "Values"
  @doc """
  Like `value/2`, but returns the float and raises `Poser.Error` on failure.

  ## Examples

      Poser.Parameter.value!(bend)
      #=> 0.0
  """
  @spec value!(t(), keyword()) :: float()
  def value!(p, opts \\ []), do: p |> value(opts) |> Ref.unwrap!()

  @doc group: "Values"
  @doc """
  Reads the value at `frame`, like `value/2` with `frame:`.

  ## Examples

      Poser.Parameter.value_at(bend, 12)
      #=> {:ok, 30.0}
  """
  @spec value_at(t(), non_neg_integer(), keyword()) :: {:ok, float()} | {:error, Error.t()}
  def value_at(p, frame, opts \\ []), do: value(p, Keyword.put(opts, :frame, frame))

  @doc group: "Values"
  @doc """
  Like `value_at/3`, but returns the float and raises `Poser.Error` on failure.

  ## Examples

      Poser.Parameter.value_at!(bend, 12)
      #=> 30.0
  """
  @spec value_at!(t(), non_neg_integer(), keyword()) :: float()
  def value_at!(p, frame, opts \\ []), do: p |> value_at(frame, opts) |> Ref.unwrap!()

  @doc group: "Values"
  @doc """
  Sets the value. Integers are sent as floats. Poser keys the value at the
  frame it is set at. Options: `:frame` (default: the current frame).

  ## Examples

      Poser.Parameter.set_value(bend, 30)
      #=> {:ok, :ok}
      Poser.Parameter.set_value(bend, 45.0, frame: 12)
      #=> {:ok, :ok}
  """
  @spec set_value(t(), number(), keyword()) :: {:ok, :ok} | {:error, Error.t()}
  def set_value(%__MODULE__{} = p, number, opts \\ []) when is_number(number) do
    {op, run} = split(opts)
    with {:ok, [:ok]} <- Batch.new() |> Batch.set(p, number, op) |> Batch.run(run), do: {:ok, :ok}
  end

  @doc group: "Values"
  @doc """
  Like `set_value/3`, but returns `:ok` and raises `Poser.Error` on failure.

  ## Examples

      Poser.Parameter.set_value!(bend, 30)
      :ok
  """
  @spec set_value!(t(), number(), keyword()) :: :ok
  def set_value!(p, number, opts \\ []), do: p |> set_value(number, opts) |> Ref.unwrap!()

  @doc group: "Values"
  @doc """
  The dial's limits as `{min, max}` floats. Options: `:server`, `:timeout`.

  ## Examples

      Poser.Parameter.min_max(bend)
      #=> {:ok, {-180.0, 180.0}}
  """
  @spec min_max(t(), keyword()) :: {:ok, {float(), float()}} | {:error, Error.t()}
  def min_max(%__MODULE__{} = p, opts \\ []) do
    {_op, run} = split(opts)

    batch =
      Batch.new() |> Batch.call(p, "MinValue", []) |> Batch.call(p, "MaxValue", [])

    with {:ok, [min, max]} <- Batch.run(batch, run), do: {:ok, {min, max}}
  end

  @doc group: "Values"
  @doc """
  Like `min_max/2`, but returns the tuple and raises `Poser.Error` on failure.

  ## Examples

      Poser.Parameter.min_max!(bend)
      #=> {-180.0, 180.0}
  """
  @spec min_max!(t(), keyword()) :: {float(), float()}
  def min_max!(p, opts \\ []), do: p |> min_max(opts) |> Ref.unwrap!()

  @doc group: "Keyframes"
  @doc """
  Adds a keyframe at `frame` (0-based), keeping the value Poser has there.
  The current frame does not move. Options: `:server`, `:timeout`.

  ## Examples

      Poser.Parameter.add_keyframe(bend, 7)
      #=> {:ok, :ok}
  """
  @spec add_keyframe(t(), non_neg_integer(), keyword()) :: {:ok, :ok} | {:error, Error.t()}
  def add_keyframe(%__MODULE__{} = p, frame, opts \\ []) do
    {_op, run} = split(opts)

    with {:ok, [:ok]} <- Batch.new() |> Batch.add_keyframe(p, frame) |> Batch.run(run),
         do: {:ok, :ok}
  end

  @doc group: "Keyframes"
  @doc """
  Like `add_keyframe/3`, but returns `:ok` and raises `Poser.Error` on failure.

  ## Examples

      Poser.Parameter.add_keyframe!(bend, 7)
      :ok
  """
  @spec add_keyframe!(t(), non_neg_integer(), keyword()) :: :ok
  def add_keyframe!(p, frame, opts \\ []), do: p |> add_keyframe(frame, opts) |> Ref.unwrap!()

  @doc group: "Keyframes"
  @doc """
  Deletes the keyframe at `frame` (0-based). The current frame does not move.
  Options: `:server`, `:timeout`.

  ## Examples

      Poser.Parameter.delete_keyframe(bend, 7)
      #=> {:ok, :ok}
  """
  @spec delete_keyframe(t(), non_neg_integer(), keyword()) :: {:ok, :ok} | {:error, Error.t()}
  def delete_keyframe(%__MODULE__{} = p, frame, opts \\ []) do
    {_op, run} = split(opts)

    with {:ok, [:ok]} <- Batch.new() |> Batch.delete_keyframe(p, frame) |> Batch.run(run),
         do: {:ok, :ok}
  end

  @doc group: "Keyframes"
  @doc """
  Like `delete_keyframe/3`, but returns `:ok` and raises `Poser.Error` on failure.

  ## Examples

      Poser.Parameter.delete_keyframe!(bend, 7)
      :ok
  """
  @spec delete_keyframe!(t(), non_neg_integer(), keyword()) :: :ok
  def delete_keyframe!(p, frame, opts \\ []),
    do: p |> delete_keyframe(frame, opts) |> Ref.unwrap!()

  @doc group: "Keyframes"
  @doc """
  The frames that hold a keyframe, sorted, as 0-based integers.

  Poser can only walk keys one at a time, so this takes one round trip per
  key (plus one for frame 0). Options: `:server`, `:timeout`.

  ## Examples

      Poser.Parameter.keyframes(bend)
      #=> {:ok, [0, 3, 7]}
  """
  @spec keyframes(t(), keyword()) :: {:ok, [non_neg_integer()]} | {:error, Error.t()}
  def keyframes(%__MODULE__{} = p, opts \\ []) do
    {_op, run} = split(opts)

    # PrevKeyFrame looks strictly before the current frame, so from frame 1 it
    # finds a key at 0. NextKeyFrame then walks strictly forward from there.
    with {:ok, [prev]} <-
           Batch.new() |> Batch.call(p, "PrevKeyFrame", [], frame: 1) |> Batch.run(run),
         start = if(prev == nil, do: [], else: [0]),
         {:ok, rest} <- walk_keys(p, 0, run, []) do
      {:ok, start ++ rest}
    end
  end

  defp walk_keys(p, k, run, acc) do
    batch = Batch.new() |> Batch.call(p, "NextKeyFrame", [], frame: k)

    case Batch.run(batch, run) do
      {:ok, [nil]} -> {:ok, Enum.reverse(acc)}
      {:ok, [next]} -> walk_keys(p, trunc(next), run, [trunc(next) | acc])
      {:error, _} = error -> error
    end
  end

  @doc group: "Keyframes"
  @doc """
  Like `keyframes/2`, but returns the list and raises `Poser.Error` on failure.

  ## Examples

      Poser.Parameter.keyframes!(bend)
      #=> [0, 3, 7]
  """
  @spec keyframes!(t(), keyword()) :: [non_neg_integer()]
  def keyframes!(p, opts \\ []), do: p |> keyframes(opts) |> Ref.unwrap!()

  @doc group: "Escape hatch"
  @doc """
  The dial's `%Poser.Handle{}`, for calls this library doesn't wrap.

  The handle belongs to the caller: release it with `Poser.Client.release/2`
  (the dial lives in Poser, so releasing only drops the bridge's reference).
  Options: `:server`, `:timeout`.

  ## Examples

      {:ok, h} = Poser.Parameter.handle(bend)
      Poser.Client.invoke(h, "Value")
      #=> {:ok, 0.0}
      Poser.Client.release([h])
  """
  @spec handle(t(), keyword()) :: {:ok, Poser.Handle.t()} | {:error, Error.t()}
  def handle(%__MODULE__{} = p, opts \\ []) do
    {_op, run} = split(opts)
    batch = Batch.new() |> Batch.call(p.actor, "InternalParameter", [p.internal])

    case Batch.run(batch, run) do
      {:ok, [nil]} ->
        {:error, %Error{kind: :not_found, details: %{path: Ref.path(p), index: 0, cause: nil}}}

      {:ok, [%Poser.Handle{} = h]} ->
        {:ok, h}

      {:error, _} = error ->
        error
    end
  end

  @doc group: "Escape hatch"
  @doc """
  Like `handle/2`, but returns the handle and raises `Poser.Error` on failure.

  ## Examples

      h = Poser.Parameter.handle!(bend)
      Poser.Client.release([h])
  """
  @spec handle!(t(), keyword()) :: Poser.Handle.t()
  def handle!(p, opts \\ []), do: p |> handle(opts) |> Ref.unwrap!()

  # :frame goes to the op builder; :server and :timeout go to Batch.run/2.
  defp split(opts) do
    opts = Keyword.validate!(opts, [:frame, :server, :timeout])
    {Keyword.take(opts, [:frame]), Keyword.take(opts, [:server, :timeout])}
  end

  defimpl Inspect do
    def inspect(parm, _opts), do: "#Poser.Parameter<#{Poser.Ref.path_string(parm)}>"
  end
end
