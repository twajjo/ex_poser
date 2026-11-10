defmodule ExPoser.Parameter do
  @moduledoc """
  A dial on an actor: a "parm" (`ParmType`) in PoserPython.

  `internal` is the name `InternalParameter` takes (e.g. `"yrot"` for the dial
  labelled "yRotate") and the key; `name` is the GUI label.

      iex> fig = %ExPoser.Figure{internal: "figure 1", name: "Andy"}
      iex> actor = %ExPoser.Actor{figure: fig, internal: "lForeArm:1", name: "Left Forearm"}
      iex> bend = %ExPoser.Parameter{actor: actor, internal: "yrot", name: "Bend"}
      iex> inspect(bend)
      "#ExPoser.Parameter<figure 1/lForeArm:1/yrot>"
      iex> ExPoser.Ref.path(bend)
      [figure: "figure 1", actor: "lForeArm:1", parm: "yrot"]

  ## Getting one

  `ExPoser.Actor.parameters/2` and `ExPoser.Actor.parameter/3`, or
  `ExPoser.Figure.parameter/4` from a figure in one call.

  ## Time

  Where PoserPython reads and writes at the scene's current frame, `value/2`
  and `set_value/3` take `frame:` (from 0: `frame: 0` is GUI frame 1). Poser
  moves to that frame for the request and back again. Without `frame:` they
  work at the current frame.

  Poser keys every set at the frame it happens at, and every dial has a key
  at frame 0 (GUI frame 1) from the start.

  ## Common tasks

      {:ok, :ok} = ExPoser.Parameter.set_value(bend, 30.0, frame: 4)  # GUI frame 5
      {:ok, 30.0} = ExPoser.Parameter.value_at(bend, 4)
      {:ok, [0, 4]} = ExPoser.Parameter.keyframes(bend)
      {:ok, {min, max}} = ExPoser.Parameter.min_max(bend)

  Each call is one request, except `keyframes/2`, which takes one per key.
  Each releases every handle it creates, except the one `handle/2` returns.
  Options: `:server` and `:timeout` (as for `ExPoser.Batch.run/2`), and
  `:frame` where a frame makes sense.

  See [Posing](posing.md) and [Frames and keyframes](frames-and-keyframes.md).
  """

  @enforce_keys [:actor, :internal, :name]
  defstruct [:actor, :internal, :name]

  alias ExPoser.{Batch, Error, Ref}

  @type t :: %__MODULE__{actor: ExPoser.Actor.t(), internal: String.t(), name: String.t()}

  @doc group: "Keyframes"
  @doc """
  Adds a keyframe at `frame` (from 0: `7` is GUI frame 8), keeping the value
  the dial has there.
  The current frame does not move. Options: `:server`, `:timeout`.

  ## Examples

      ExPoser.Parameter.add_keyframe(bend, 7)
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
  Like `add_keyframe/3`, but returns `:ok` and raises `ExPoser.Error` on failure.

  ## Examples

      ExPoser.Parameter.add_keyframe!(bend, 7)
      #=> :ok
  """
  @spec add_keyframe!(t(), non_neg_integer(), keyword()) :: :ok
  def add_keyframe!(p, frame, opts \\ []), do: p |> add_keyframe(frame, opts) |> Ref.unwrap!()

  @doc group: "Keyframes"
  @doc """
  Deletes the keyframe at `frame` (from 0: `7` is GUI frame 8). The current
  frame does not move.
  Options: `:server`, `:timeout`.

  ## Examples

      ExPoser.Parameter.delete_keyframe(bend, 7)
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
  Like `delete_keyframe/3`, but returns `:ok` and raises `ExPoser.Error` on failure.

  ## Examples

      ExPoser.Parameter.delete_keyframe!(bend, 7)
      #=> :ok
  """
  @spec delete_keyframe!(t(), non_neg_integer(), keyword()) :: :ok
  def delete_keyframe!(p, frame, opts \\ []),
    do: p |> delete_keyframe(frame, opts) |> Ref.unwrap!()

  @doc group: "Escape hatch"
  @doc """
  The dial's `%ExPoser.Handle{}`, for calls this library doesn't wrap.

  The handle belongs to the caller: release it with `ExPoser.Client.release/2`
  (the dial lives in Poser, so releasing only drops the bridge's reference).
  A path that doesn't resolve gives `:not_found` with `details.path` and
  `details.index` nil. Options: `:server`, `:timeout`.

  ## Examples

      {:ok, h} = ExPoser.Parameter.handle(bend)
      ExPoser.Client.invoke(h, "Value")
      #=> {:ok, 0.0}
      ExPoser.Client.release([h])
  """
  @spec handle(t(), keyword()) :: {:ok, ExPoser.Handle.t()} | {:error, Error.t()}
  def handle(%__MODULE__{} = p, opts \\ []) do
    {_op, run} = split(opts)
    batch = Batch.new() |> Batch.call(p.actor, "InternalParameter", [p.internal])

    case Batch.run(batch, run) do
      {:ok, [nil]} ->
        {:error, Error.not_found(Ref.path(p))}

      {:ok, [%ExPoser.Handle{} = h]} ->
        {:ok, h}

      {:error, %Error{kind: :not_found} = e} ->
        {:error, %{e | details: %{e.details | index: nil}}}

      {:error, _} = error ->
        error
    end
  end

  @doc group: "Escape hatch"
  @doc """
  Like `handle/2`, but returns the handle and raises `ExPoser.Error` on failure.

  ## Examples

      h = ExPoser.Parameter.handle!(bend)
      ExPoser.Client.release([h])
  """
  @spec handle!(t(), keyword()) :: ExPoser.Handle.t()
  def handle!(p, opts \\ []), do: p |> handle(opts) |> Ref.unwrap!()

  @doc group: "Keyframes"
  @doc """
  The frames that hold a keyframe, sorted, counting from 0 (`[0, 3, 7]` is
  GUI frames 1, 4 and 8). Every dial starts with a key at frame 0.

  PoserPython walks keys one at a time, so this takes one round trip per key
  (plus one for frame 0). It is not a snapshot: keys added or deleted during
  the walk may or may not appear. Options: `:server`, `:timeout`.

  ## Examples

      ExPoser.Parameter.keyframes(bend)
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

  @doc group: "Keyframes"
  @doc """
  Like `keyframes/2`, but returns the list and raises `ExPoser.Error` on failure.

  ## Examples

      ExPoser.Parameter.keyframes!(bend)
      #=> [0, 3, 7]
  """
  @spec keyframes!(t(), keyword()) :: [non_neg_integer()]
  def keyframes!(p, opts \\ []), do: p |> keyframes(opts) |> Ref.unwrap!()

  @doc group: "Values"
  @doc """
  The dial's limits as `{min, max}` floats. Options: `:server`, `:timeout`.

  ## Examples

      ExPoser.Parameter.min_max(bend)
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
  Like `min_max/2`, but returns the tuple and raises `ExPoser.Error` on failure.

  ## Examples

      ExPoser.Parameter.min_max!(bend)
      #=> {-180.0, 180.0}
  """
  @spec min_max!(t(), keyword()) :: {float(), float()}
  def min_max!(p, opts \\ []), do: p |> min_max(opts) |> Ref.unwrap!()

  @doc group: "Values"
  @doc """
  Sets the value. Integers are sent as floats. Poser keys the value at the
  frame it is set at. Frames between keys follow Poser's interpolation, and
  after the last key the value holds. Options: `:frame` (default: the current frame), `:server`, `:timeout`.

  ## Examples

      ExPoser.Parameter.set_value(bend, 30)
      #=> {:ok, :ok}
      ExPoser.Parameter.set_value(bend, 45.0, frame: 11)   # GUI frame 12
      #=> {:ok, :ok}
  """
  @spec set_value(t(), number(), keyword()) :: {:ok, :ok} | {:error, Error.t()}
  def set_value(%__MODULE__{} = p, number, opts \\ []) when is_number(number) do
    {op, run} = split(opts)
    with {:ok, [:ok]} <- Batch.new() |> Batch.set(p, number, op) |> Batch.run(run), do: {:ok, :ok}
  end

  @doc group: "Values"
  @doc """
  Like `set_value/3`, but returns `:ok` and raises `ExPoser.Error` on failure.

  ## Examples

      ExPoser.Parameter.set_value!(bend, 30)
      #=> :ok
  """
  @spec set_value!(t(), number(), keyword()) :: :ok
  def set_value!(p, number, opts \\ []), do: p |> set_value(number, opts) |> Ref.unwrap!()

  @doc group: "Values"
  @doc """
  Reads the value, as a float. Options: `:frame` (default: the current
  frame), `:server`, `:timeout`.

  ## Examples

      ExPoser.Parameter.value(bend)
      #=> {:ok, 0.0}
      ExPoser.Parameter.value(bend, frame: 12)
      #=> {:ok, 30.0}
  """
  @spec value(t(), keyword()) :: {:ok, ExPoser.Actor.value()} | {:error, Error.t()}
  def value(%__MODULE__{} = p, opts \\ []) do
    {op, run} = split(opts)
    with {:ok, [v]} <- Batch.new() |> Batch.get(p, op) |> Batch.run(run), do: {:ok, v}
  end

  @doc group: "Values"
  @doc """
  Like `value/2`, but returns the float and raises `ExPoser.Error` on failure.

  ## Examples

      ExPoser.Parameter.value!(bend)
      #=> 0.0
  """
  @spec value!(t(), keyword()) :: ExPoser.Actor.value()
  def value!(p, opts \\ []), do: p |> value(opts) |> Ref.unwrap!()

  @doc group: "Values"
  @doc """
  Reads the value at `frame`, like `value/2` with `frame:`.

  ## Examples

      ExPoser.Parameter.value_at(bend, 12)
      #=> {:ok, 30.0}
  """
  @spec value_at(t(), non_neg_integer(), keyword()) ::
          {:ok, ExPoser.Actor.value()} | {:error, Error.t()}
  def value_at(p, frame, opts \\ []), do: value(p, Keyword.put(opts, :frame, frame))

  @doc group: "Values"
  @doc """
  Like `value_at/3`, but returns the float and raises `ExPoser.Error` on failure.

  ## Examples

      ExPoser.Parameter.value_at!(bend, 12)
      #=> 30.0
  """
  @spec value_at!(t(), non_neg_integer(), keyword()) :: ExPoser.Actor.value()
  def value_at!(p, frame, opts \\ []), do: p |> value_at(frame, opts) |> Ref.unwrap!()

  # :frame goes to the op builder; :server and :timeout go to Batch.run/2.
  defp split(opts) do
    opts = Keyword.validate!(opts, [:frame, :server, :timeout])
    {Keyword.take(opts, [:frame]), Keyword.take(opts, [:server, :timeout])}
  end

  defp walk_keys(p, k, run, acc) do
    batch = Batch.new() |> Batch.call(p, "NextKeyFrame", [], frame: k)

    case Batch.run(batch, run) do
      {:ok, [nil]} -> {:ok, Enum.reverse(acc)}
      {:ok, [next]} -> walk_keys(p, trunc(next), run, [trunc(next) | acc])
      {:error, _} = error -> error
    end
  end

  defimpl Inspect do
    def inspect(parm, _opts), do: "#ExPoser.Parameter<#{ExPoser.Ref.path_string(parm)}>"
  end
end
