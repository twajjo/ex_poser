defmodule Poser.Batch do
  @moduledoc """
  Several operations on name-path structs, sent as few requests as possible.

  Build a batch with `new/0` and the op functions, then send it with `run/2`
  (or use `Poser.batch/2`). Each chunk resolves the structs' internal-name
  paths in the same request as the ops, sharing lookups between ops, so no
  handle is ever cached and nothing goes stale.

  Ops with `frame:` run at that frame; every other op runs at the frame the
  batch started at, and that frame is restored at the end, also on failure.
  Ops are never reordered. There is no rollback: ops before a failure stay
  applied.

      iex> Poser.Batch.new() |> Poser.Batch.size()
      0
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

  @doc """
  An empty batch.

  ## Examples

      iex> Poser.Batch.new()
      %Poser.Batch{ops: [], size: 0}
  """
  @spec new() :: t()
  def new, do: %__MODULE__{}

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

  @doc """
  Adds a keyframe at `frame` without moving the scene's frame. Its result is `:ok`.

  ## Examples

      Poser.Batch.new() |> Poser.Batch.add_keyframe(bend, 7)
  """
  @spec add_keyframe(t(), Parameter.t(), non_neg_integer()) :: t()
  def add_keyframe(b, %Parameter{} = parm, frame) when is_integer(frame) and frame >= 0 do
    push(b, parm, "AddKeyFrame", [frame], nil, :ok)
  end

  @doc """
  Deletes the keyframe at `frame` without moving the scene's frame. Its result is `:ok`.

  ## Examples

      Poser.Batch.new() |> Poser.Batch.delete_keyframe(bend, 7)
  """
  @spec delete_keyframe(t(), Parameter.t(), non_neg_integer()) :: t()
  def delete_keyframe(b, %Parameter{} = parm, frame) when is_integer(frame) and frame >= 0 do
    push(b, parm, "DeleteKeyFrame", [frame], nil, :ok)
  end

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

  @doc """
  Sends the batch. Returns one result per op, in order.

  Options: `:server` and `:timeout` as in `Poser.Client`, and `:chunk`, the
  most wire ops per request, lookups included (default #{@default_chunk}).
  A chunk too small for a single op raises `ArgumentError`.

  On failure, later chunks don't run and earlier ones stay applied, and
  handles from earlier chunks' `call/5` results are released. A path that
  doesn't resolve gives `:not_found`; every error gains `details.index`, the
  index of the caller's op. Other `details` keys are kept (for `:not_allowed`,
  `details.op` stays the refused op kind, such as `:invoke`).

  ## Examples

      Poser.Batch.new()
      |> Poser.Batch.set(bend, 30.0, frame: 5)
      |> Poser.Batch.get(bend)
      |> Poser.Batch.run()
      #=> {:ok, [:ok, 0.0]}

      Poser.Batch.new() |> Poser.Batch.get(missing) |> Poser.Batch.run()
      #=> {:error, %Poser.Error{kind: :not_found, details: %{index: 0, ...}}}
  """
  @spec run(t(), keyword()) :: {:ok, [term()]} | {:error, Error.t()}
  def run(b, opts \\ [])
  def run(%__MODULE__{size: 0}, _opts), do: {:ok, []}

  def run(%__MODULE__{} = b, opts) do
    chunks = compile(b, chunk: Keyword.get(opts, :chunk, @default_chunk))
    kinds = b |> ops() |> Enum.map(& &1.result) |> List.to_tuple()
    client_opts = Keyword.take(opts, [:server, :timeout])
    run_chunks(chunks, kinds, client_opts, %{orig: nil, moved: false, acc: []})
  end

  @doc """
  Like `run/2`, but returns the results and raises `Poser.Error` on failure.

  ## Examples

      Poser.Batch.new()
      |> Poser.Batch.set(bend, 30.0, frame: 5)
      |> Poser.Batch.get(bend)
      |> Poser.Batch.run!()
      #=> [:ok, 0.0]

      Poser.Batch.new() |> Poser.Batch.get(missing) |> Poser.Batch.run!()
      ** (Poser.Error) not_found: figure 1/hip/nope
  """
  @spec run!(t(), keyword()) :: [term()]
  def run!(b, opts \\ []), do: b |> run(opts) |> Ref.unwrap!()

  # --- Building ---

  defp push(%__MODULE__{ops: ops, size: size} = b, ref, method, args, frame, result) do
    op = %{ref: ref, method: method, args: args, frame: frame, result: result}
    %{b | ops: [op | ops], size: size + 1}
  end

  defp ops(%__MODULE__{ops: ops}), do: Enum.reverse(ops)

  defp frame_opt(opts) do
    case Keyword.validate!(opts, [:frame])[:frame] do
      frame when is_nil(frame) or (is_integer(frame) and frame >= 0) -> frame
      other -> raise ArgumentError, "frame must be a non-negative integer, got #{inspect(other)}"
    end
  end

  @doc false
  # Returns `[{wire_ops, roles}]`, one per chunk; see Poser.Batch.Compiler.
  @spec compile(t(), keyword()) :: [{list(), %{non_neg_integer() => role()}}]
  def compile(%__MODULE__{} = b, opts),
    do: b |> ops() |> Compiler.compile(Keyword.get(opts, :chunk, @default_chunk))

  # --- Running ---

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

  # Caller results of chunks that already ran; the caller never receives them.
  defp acc_handles(st), do: st.acc |> Enum.concat() |> Codec.handles_in()

  defp substitute(wire, nil), do: wire

  defp substitute(wire, orig) do
    Enum.map(wire, fn
      {:invoke, t, "SetFrame", [:original_frame]} -> {:invoke, t, "SetFrame", [orig]}
      op -> op
    end)
  end

  # The first chunk of a framed batch reads the original frame at wire op 1.
  defp orig(nil, [_, @read_frame | _], [_, frame | _]), do: frame
  defp orig(orig, _wire, _results), do: orig

  defp moves?(wire, roles) do
    wire
    |> Enum.with_index()
    |> Enum.any?(fn {op, i} ->
      match?({:invoke, _, "SetFrame", _}, op) and match?({:frame, _}, roles[i])
    end)
  end

  defp lookup_handles(results, roles) do
    results
    |> Enum.with_index()
    |> Enum.filter(fn {_, i} -> match?({:lookup, _, _}, roles[i]) end)
    |> Enum.map(&elem(&1, 0))
    |> Codec.handles_in()
  end

  defp caller_results(results, roles, kinds) do
    for {result, i} <- Enum.with_index(results), {:caller, k} <- [roles[i]] do
      if elem(kinds, k) == :ok, do: :ok, else: result
    end
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

  defp target({:invoke, target, _method, _args}), do: target
  defp target(_), do: nil

  defp not_found(path, k, cause), do: Error.not_found(path, k, cause)

  defp with_index(%Error{details: details} = cause, k),
    do: %{cause | details: Map.merge(details || %{}, %{index: k})}
end
