defmodule ExPoser.Batch.Compiler do
  @moduledoc false
  # Compiles a batch's ops into chunked wire batches, with a role table per
  # chunk: wire index → {:lookup, path_prefix, caller_op} | {:caller, k} |
  # {:frame, caller_op}. In chunks after the first, the original frame is the
  # placeholder `:original_frame`, which ExPoser.Batch.run/2 substitutes.

  alias ExPoser.Ref

  @scene {:call, "Scene", []}
  @read_frame {:invoke, {:result, 0}, "Frame", []}

  @spec compile([map()], pos_integer()) :: [
          {list(), %{non_neg_integer() => ExPoser.Batch.role()}}
        ]
  def compile(ops, limit) do
    last = length(ops) - 1

    st = %{
      limit: limit,
      framed?: Enum.any?(ops, &(&1.frame != nil)),
      frame: :orig,
      moved: false,
      cur: nil,
      done: []
    }

    ops
    |> Enum.with_index()
    |> Enum.reduce(st, fn {op, k}, st -> add_op(st, op, k, k == last) end)
    |> finish()
  end

  defp add_op(%{cur: nil} = st, op, k, last?), do: st |> open(k) |> place(op, k, last?)

  defp add_op(st, op, k, last?) do
    if st.cur.n + cost(st, st.cur, op, last?) <= st.limit do
      place(st, op, k, last?)
    else
      %{st | cur: nil, done: [st.cur | st.done]} |> open(k) |> place(op, k, last?)
    end
  end

  defp chunk_out(chunk), do: {Enum.reverse(chunk.wire), chunk.roles}

  # Wire ops `op` needs in `chunk`: missing lookups, a SetFrame, itself, and
  # the final restore when it is the batch's last op.
  defp cost(st, chunk, op, last?) do
    target = target_frame(op)
    moves = if target != st.frame, do: 1, else: 0
    restore = if last? and (st.moved or moves == 1), do: 1, else: 0
    length(missing(chunk, op.ref)) + moves + 1 + restore
  end

  defp emit(chunk, wire, role) do
    %{
      chunk
      | wire: [wire | chunk.wire],
        roles: Map.put(chunk.roles, chunk.n, role),
        n: chunk.n + 1
    }
  end

  defp emit_lookup(chunk, prefix, k) do
    {parent_path, [step]} = Enum.split(prefix, -1)
    op = Ref.lookup_op(step, {:result, chunk.memo[parent_path]}, scope(parent_path))
    chunk |> emit(op, {:lookup, prefix, k}) |> put_in([:memo, prefix], chunk.n)
  end

  defp finish(%{cur: nil, done: done}), do: done |> Enum.reverse() |> Enum.map(&chunk_out/1)
  defp finish(%{cur: cur, done: done} = st), do: finish(%{st | cur: nil, done: [cur | done]})

  defp missing(chunk, ref) do
    path = Ref.path(ref)

    for i <- 1..length(path)//1,
        prefix = Enum.take(path, i),
        not Map.has_key?(chunk.memo, prefix),
        do: prefix
  end

  defp open(st, k) do
    chunk = %{wire: [@scene], n: 1, roles: %{0 => {:lookup, [], k}}, memo: %{[] => 0}}

    case st do
      %{done: [], framed?: true} ->
        %{st | cur: chunk |> emit(@read_frame, {:frame, k}) |> Map.put(:orig, {:result, 1})}

      _ ->
        %{st | cur: Map.put(chunk, :orig, :original_frame)}
    end
  end

  defp place(st, op, k, last?) do
    if st.cur.n + cost(st, st.cur, op, last?) > st.limit do
      raise ArgumentError,
            "chunk: #{st.limit} is too small for op #{k} on #{inspect(op.ref)}"
    end

    chunk = Enum.reduce(missing(st.cur, op.ref), st.cur, &emit_lookup(&2, &1, k))
    target = target_frame(op)

    {chunk, st} =
      if target == st.frame do
        {chunk, st}
      else
        {emit(chunk, set_frame(chunk, target), {:frame, k}), %{st | frame: target, moved: true}}
      end

    path = Ref.path(op.ref)
    wire = {:invoke, {:result, chunk.memo[path]}, op.method, op.args}
    chunk = emit(chunk, wire, {:caller, k})

    chunk =
      if last? and st.moved, do: emit(chunk, set_frame(chunk, :orig), {:frame, k}), else: chunk

    %{st | cur: chunk}
  end

  # What the parent of a lookup is: an actor step under a figure uses the
  # figure's lookup, one directly under the scene uses the scene's.
  defp scope(parent_path) do
    case List.last(parent_path) do
      {:figure, _} -> :figure
      _ -> :scene
    end
  end

  defp set_frame(chunk, :orig), do: {:invoke, {:result, 0}, "SetFrame", [chunk.orig]}
  defp set_frame(_chunk, n), do: {:invoke, {:result, 0}, "SetFrame", [n]}

  defp target_frame(%{frame: nil}), do: :orig
  defp target_frame(%{frame: frame}), do: frame
end
