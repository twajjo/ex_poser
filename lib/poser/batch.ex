defmodule Poser.Batch do
  @moduledoc """
  Many reads and writes on name-path structs, sent as few requests as
  possible. Every function in `Poser.Scene`, `Poser.Figure`, `Poser.Actor`
  and `Poser.Parameter` is a one-op batch, so a hand-built batch behaves the
  same way, only in fewer round trips.

  Build one with `new/0` and the op functions and send it with `run/2`, or
  do both with `Poser.batch/2`. Results come back one per op, in order.

  - **Lookups.** Each struct's path is resolved inside Poser in the same
    request as its op, and ops share lookups on a common path prefix. No
    handle is kept, so nothing goes stale.
  - **Frames.** Ops with `frame:` run at that frame; every other op runs at
    the frame the batch found, and that frame is restored at the end. Ops
    are never reordered.
  - **Chunks.** A batch over 2000 wire ops (lookups and frame moves
    included) is split into several requests, one Python main-thread turn
    each.
  - **No rollback.** Ops before a failure stay applied.

      iex> fig = %Poser.Figure{internal: "figure 1", name: "Andy"}
      iex> hip = %Poser.Actor{figure: fig, internal: "hip", name: "Hip"}
      iex> xrot = %Poser.Parameter{actor: hip, internal: "xrot", name: "xRotate"}
      iex> b = Enum.reduce(0..29, Poser.Batch.new(), &Poser.Batch.set(&2, xrot, &1 * 3.0, frame: &1))
      iex> Poser.Batch.size(b)
      30

  See the [Batching](batching.md) guide, and
  [Frames and keyframes](frames-and-keyframes.md) for `frame:`.
  """

  alias Poser.{Client, Codec, Error, Parameter, Ref}
  alias Poser.Batch.Compiler

  @default_chunk 2000
  @scene {:call, "Scene", []}
  @read_frame {:invoke, {:result, 0}, "Frame", []}

  defstruct ops: [], size: 0

  @typedoc "A batch under construction. Treat it as opaque."
  @type t :: %__MODULE__{ops: [op()], size: non_neg_integer()}

  @typep op :: %{
           ref: Ref.ref(),
           method: String.t(),
           args: list(),
           frame: non_neg_integer() | nil,
           result: :ok | :value
         }

  @typedoc "Wire index → what the wire op is for."
  @type role ::
          {:lookup, [Ref.step()], non_neg_integer()}
          | {:caller, non_neg_integer()}
          | {:frame, non_neg_integer()}

  @doc group: "Building"
  @doc """
  Adds a keyframe at `frame` without moving the scene's frame. Its result is `:ok`.

  ## Examples

      Poser.Batch.new() |> Poser.Batch.add_keyframe(bend, 7)
  """
  @spec add_keyframe(t(), Parameter.t(), non_neg_integer()) :: t()
  def add_keyframe(b, %Parameter{} = parm, frame) when is_integer(frame) and frame >= 0 do
    push(b, parm, "AddKeyFrame", [frame], nil, :ok)
  end

  @doc group: "Building"
  @doc """
  Calls `method` on the object `ref` resolves to (`:scene` or a struct).

  Its result is the method's return value. Handles it returns belong to the
  caller, who releases them with `Poser.Client.release/2`. Options: `:frame`.

  ## Examples

      Poser.Batch.new() |> Poser.Batch.call(:scene, "NumFrames", [])
      Poser.Batch.new() |> Poser.Batch.call(bend, "NextKeyFrame", [], frame: 3)
  """
  @spec call(t(), Ref.ref(), String.t(), list(), keyword()) :: t()
  def call(b, ref, method, args \\ [], opts \\ []) when is_binary(method) and is_list(args) do
    push(b, ref, method, args, frame_opt(opts), :value)
  end

  @doc false
  # Returns `[{wire_ops, roles}]`, one per chunk; see Poser.Batch.Compiler.
  @spec compile(t(), keyword()) :: [{list(), %{non_neg_integer() => role()}}]
  def compile(%__MODULE__{} = b, opts),
    do: b |> ops() |> Compiler.compile(Keyword.get(opts, :chunk, @default_chunk))

  @doc group: "Building"
  @doc """
  Deletes the keyframe at `frame` without moving the scene's frame. Its result is `:ok`.

  ## Examples

      Poser.Batch.new() |> Poser.Batch.delete_keyframe(bend, 7)
  """
  @spec delete_keyframe(t(), Parameter.t(), non_neg_integer()) :: t()
  def delete_keyframe(b, %Parameter{} = parm, frame) when is_integer(frame) and frame >= 0 do
    push(b, parm, "DeleteKeyFrame", [frame], nil, :ok)
  end

  @doc group: "Building"
  @doc """
  Reads a parameter's value. Its result is the float value.

  Options: `:frame`, the frame to read at (default: the batch's original frame).

  ## Examples

      Poser.Batch.new() |> Poser.Batch.get(bend, frame: 12)
  """
  @spec get(t(), Parameter.t(), keyword()) :: t()
  def get(b, %Parameter{} = parm, opts \\ []) do
    push(b, parm, "Value", [], frame_opt(opts), :value)
  end

  @doc group: "Building"
  @doc """
  An empty batch.

  ## Examples

      iex> Poser.Batch.new()
      %Poser.Batch{ops: [], size: 0}
  """
  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc group: "Running"
  @doc """
  Sends the batch. Returns one result per op, in order: `:ok` for setters
  and keyframe ops, the value for `get/3` and `call/5`.

  Options: `:server` and `:timeout` as in `Poser.Client`, and `:chunk`, the
  most wire ops per request, lookups and frame moves included (default
  #{@default_chunk}). An unknown option, a `:chunk` that isn't a positive
  integer, or a chunk too small for a single op raises `ArgumentError`.

  > #### No rollback {: .warning}
  >
  > Poser has no transactions. On failure the ops before the failing one
  > stay applied, in its chunk and in every earlier chunk, and later chunks
  > don't run.

  On failure the frame is moved back to where the batch found it, and every
  handle the batch created is released, including `call/5` results from
  earlier chunks. A path that doesn't resolve gives `:not_found` with
  `details.path`. Every error raised by an op gains `details.index`, the
  index of the caller's op; `:timeout` and `:disconnected` errors concern the
  whole request and have no `index`. Other `details` keys are kept (for `:not_allowed`,
  `details.op` stays the refused wire op kind, such as `:invoke`).

  One case leaves the frame moved: a `:timeout` or `:disconnected` error in
  the first chunk of a batch with `frame:` ops. That chunk reads the original
  frame, and its reply never arrived, so there is no frame to restore; if
  Poser ran the chunk anyway, its timeline stays at the last frame the chunk
  moved to.

  ## Examples

      Poser.Batch.new()
      |> Poser.Batch.set(bend, 30.0, frame: 4)
      |> Poser.Batch.get(bend, frame: 4)
      |> Poser.Batch.run()
      #=> {:ok, [:ok, 30.0]}

      Poser.Batch.new() |> Poser.Batch.get(missing) |> Poser.Batch.run()
      #=> {:error, %Poser.Error{kind: :not_found, details: %{index: 0, ...}}}
  """
  @spec run(t(), keyword()) :: {:ok, [term()]} | {:error, Error.t()}
  def run(%__MODULE__{} = b, opts \\ []) do
    {chunk, client_opts} = opts |> run_opts() |> Keyword.pop!(:chunk)

    if b.size == 0 do
      {:ok, []}
    else
      chunks = compile(b, chunk: chunk)
      kinds = b |> ops() |> Enum.map(& &1.result) |> List.to_tuple()
      run_chunks(chunks, kinds, client_opts, %{orig: nil, moved: false, acc: []})
    end
  end

  @doc group: "Running"
  @doc """
  Like `run/2`, but returns the results and raises `Poser.Error` on failure.

  ## Examples

      Poser.Batch.new()
      |> Poser.Batch.set(bend, 30.0, frame: 4)
      |> Poser.Batch.get(bend, frame: 4)
      |> Poser.Batch.run!()
      #=> [:ok, 30.0]

      Poser.Batch.new() |> Poser.Batch.get(missing) |> Poser.Batch.run!()
      ** (Poser.Error) not_found: figure 1/hip/nope
  """
  @spec run!(t(), keyword()) :: [term()]
  def run!(b, opts \\ []), do: b |> run(opts) |> Ref.unwrap!()

  @doc group: "Building"
  @doc """
  Sets a parameter's value. Integers are sent as floats. Its result is `:ok`.

  Poser keys the value at the frame it is set at. Options: `:frame`, the
  frame to set at (default: the batch's original frame).

  ## Examples

      Poser.Batch.new() |> Poser.Batch.set(bend, 30, frame: 5)
  """
  @spec set(t(), Parameter.t(), number(), keyword()) :: t()
  def set(b, %Parameter{} = parm, value, opts \\ []) when is_number(value) do
    push(b, parm, "SetValue", [value * 1.0], frame_opt(opts), :ok)
  end

  @doc group: "Building"
  @doc """
  The number of ops the caller added.

  ## Examples

      iex> fig = %Poser.Figure{internal: "figure 1", name: "Figure 1"}
      iex> hip = %Poser.Actor{figure: fig, internal: "hip", name: "hip"}
      iex> p = %Poser.Parameter{actor: hip, internal: "xtran", name: "xTran"}
      iex> Poser.Batch.new() |> Poser.Batch.get(p) |> Poser.Batch.set(p, 1.0) |> Poser.Batch.size()
      2
  """
  @spec size(t()) :: non_neg_integer()
  def size(%__MODULE__{size: size}), do: size

  # Caller results of chunks that already ran; the caller never receives them.
  defp acc_handles(st), do: st.acc |> Enum.concat() |> Codec.handles_in()

  defp caller_results(results, roles, kinds) do
    for {result, i} <- Enum.with_index(results), {:caller, k} <- [roles[i]] do
      if elem(kinds, k) == :ok, do: :ok, else: result
    end
  end

  defp frame_opt(opts) do
    case Keyword.validate!(opts, [:frame])[:frame] do
      frame when is_nil(frame) or (is_integer(frame) and frame >= 0) -> frame
      other -> raise ArgumentError, "frame must be a non-negative integer, got #{inspect(other)}"
    end
  end

  defp lookup_handles(results, roles) do
    results
    |> Enum.with_index()
    |> Enum.filter(fn {_, i} -> match?({:lookup, _, _}, roles[i]) end)
    |> Enum.map(&elem(&1, 0))
    |> Codec.handles_in()
  end

  defp map_error(i, cause, partial, wire, roles) do
    case roles[i] do
      {:lookup, [_ | _] = prefix, k} ->
        not_found(prefix, k, cause)

      {:lookup, [], k} ->
        with_index(cause, k)

      {_, k} ->
        case wire |> Enum.at(i) |> target() do
          {:result, j} when is_map_key(roles, j) ->
            case {roles[j], Enum.at(partial, j)} do
              {{:lookup, [_ | _] = prefix, _}, nil} -> not_found(prefix, k, cause)
              _ -> with_index(cause, k)
            end

          _ ->
            with_index(cause, k)
        end
    end
  end

  defp moves?(wire, roles) do
    wire
    |> Enum.with_index()
    |> Enum.any?(fn {op, i} ->
      match?({:invoke, _, "SetFrame", _}, op) and match?({:frame, _}, roles[i])
    end)
  end

  defp not_found(path, k, cause), do: Error.not_found(path, k, cause)

  defp ops(%__MODULE__{ops: ops}), do: Enum.reverse(ops)

  # The first chunk of a framed batch reads the original frame at wire op 1.
  defp orig(nil, [_, @read_frame | _], [_, frame | _]), do: frame
  defp orig(orig, _wire, _results), do: orig

  defp push(%__MODULE__{ops: ops, size: size} = b, ref, method, args, frame, result) do
    op = %{ref: ref, method: method, args: args, frame: frame, result: result}
    %{b | ops: [op | ops], size: size + 1}
  end

  defp release([], _opts), do: :ok
  defp release(handles, opts), do: Client.release(handles, opts)

  defp restore(nil, _opts), do: :ok

  defp restore(orig, opts) do
    ops = [@scene, {:invoke, {:result, 0}, "SetFrame", [orig]}]

    case Client.batch(ops, opts) do
      {:ok, results} ->
        release(Codec.handles_in(results), opts)

      {:error, %Error{kind: :batch_failed, details: %{partial: p}}} ->
        release(Codec.handles_in(p), opts)

      {:error, _} ->
        :ok
    end
  end

  defp run_chunks([], _kinds, _opts, st), do: {:ok, st.acc |> Enum.reverse() |> Enum.concat()}

  defp run_chunks([{wire, roles} | rest], kinds, opts, st) do
    wire = substitute(wire, st.orig)

    case Client.batch(wire, opts) do
      {:ok, results} ->
        release(lookup_handles(results, roles), opts)
        st = %{st | orig: orig(st.orig, wire, results), moved: st.moved or moves?(wire, roles)}

        run_chunks(rest, kinds, opts, %{
          st
          | acc: [caller_results(results, roles, kinds) | st.acc]
        })

      {:error, %Error{kind: :batch_failed, details: %{index: i, cause: cause, partial: partial}}} ->
        release(Codec.handles_in(partial) ++ acc_handles(st), opts)
        orig = orig(st.orig, wire, partial)
        if st.moved or moves?(Enum.take(wire, i), roles), do: restore(orig, opts)
        {:error, map_error(i, cause, partial, wire, roles)}

      {:error, error} ->
        release(acc_handles(st), opts)
        if st.moved or moves?(wire, roles), do: restore(st.orig, opts)
        {:error, error}
    end
  end

  defp run_opts(opts) do
    opts = Keyword.validate!(opts, [:server, :timeout, chunk: @default_chunk])

    case opts[:chunk] do
      chunk when is_integer(chunk) and chunk > 0 -> opts
      other -> raise ArgumentError, "chunk must be a positive integer, got #{inspect(other)}"
    end
  end

  defp substitute(wire, nil), do: wire

  defp substitute(wire, orig) do
    Enum.map(wire, fn
      {:invoke, t, "SetFrame", [:original_frame]} -> {:invoke, t, "SetFrame", [orig]}
      op -> op
    end)
  end

  defp target({:invoke, target, _method, _args}), do: target
  defp target(_), do: nil

  defp with_index(%Error{details: details} = cause, k),
    do: %{cause | details: Map.merge(details || %{}, %{index: k})}
end
