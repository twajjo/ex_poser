defmodule ExPoser.Batch.Compiler do
  @moduledoc false
  # Compiles a batch's ops into chunked wire batches, with a role table per
  # chunk: wire index → {:lookup, path_prefix, caller_op} | {:caller, k} |
  # {:frame, caller_op} | {:created, caller_op} | {:preview, caller_op}. An
  # op with `:changes` (a tree ref) makes its chunk end with an UpdatePreview
  # of that tree, once per tree, with the role {:preview, last caller op that
  # changed it}. In chunks
  # after the first, the original frame is the placeholder `:original_frame`,
  # which ExPoser.Batch.run/2 substitutes.

  alias ExPoser.{Ref, ShaderNode}

  @scene {:call, "Scene", []}
  @read_frame {:invoke, {:result, 0}, "Frame", []}

  @spec compile([map()], pos_integer()) :: [
          {list(), %{non_neg_integer() => ExPoser.Batch.role()}}
        ]
  def compile(ops, limit) do
    check_created!(ops)
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
    if reserved(st.cur) + cost(st, st.cur, op, last?) <= st.limit do
      place(st, op, k, last?)
    else
      %{st | cur: nil, done: [close(st.cur) | st.done]} |> open(k) |> place(op, k, last?)
    end
  end

  defp changes(op), do: Map.get(op, :changes)

  # Every `{:created, j}` step of op k's refs must name an earlier create_node op of
  # this batch, on the same tree.
  defp check_created!(ops) do
    indexed = Enum.with_index(ops)

    for {op, k} <- indexed,
        ref <- refs(op),
        path = Ref.path(ref),
        {step, i} <- Enum.with_index(path),
        {:node, {:created, j}} <- [step] do
      unless j < k and creates_on?(Enum.at(ops, j), Enum.take(path, i)) do
        raise ArgumentError,
              "op #{k} uses {:created, #{j}}, which must be a create_node op of this batch " <>
                "on the same tree, earlier than op #{k}"
      end
    end

    :ok
  end

  # A created node's lookup is missing from the chunk only when the create_node
  # was placed in an earlier chunk. Temporary: later chunks will name it by its
  # InternalName.
  defp check_same_chunk!(missing, k) do
    if Enum.any?(missing, &match?({:node, {:created, _}}, List.last(&1))) do
      raise ArgumentError,
            "op #{k} uses a created node in a later request chunk than its create_node; " <>
              "a created node can only be used in the same request chunk for now"
    end
  end

  defp chunk_out(chunk), do: {Enum.reverse(chunk.wire), chunk.roles}

  # Ends a chunk: one UpdatePreview per changed tree, in first-change order.
  defp close(chunk) do
    chunk.previews
    |> Enum.reduce(%{chunk | previews: []}, fn {path, k}, chunk ->
      emit(chunk, {:invoke, {:result, chunk.memo[path]}, "UpdatePreview", []}, {:preview, k})
    end)
  end

  # Wire ops `op` needs in `chunk`: missing lookups, a SetFrame, itself, and
  # the final restore when it is the batch's last op.
  defp cost(st, chunk, op, last?) do
    target = target_frame(op)
    moves = if target != st.frame, do: 1, else: 0
    restore = if last? and (st.moved or moves == 1), do: 1, else: 0

    length(missing(chunk, op)) + moves + 1 + restore + preview_cost(chunk, op) +
      created_cost(op)
  end

  # After a CreateNode: read the new node's InternalName and Name (role
  # {:created, k}), and memoize the node's path, with `{:created, k}` as its
  # name, to the CreateNode wire index.
  defp created(chunk, %{result: {:created, tree}}, k) do
    index = chunk.n - 1
    target = {:result, index}

    chunk
    |> emit({:invoke, target, "InternalName", []}, {:created, k})
    |> emit({:invoke, target, "Name", []}, {:created, k})
    |> put_in([:memo, Ref.path(tree) ++ [{:node, {:created, k}}]], index)
  end

  defp created(chunk, _op, _k), do: chunk

  # A create_node op reads the new node's InternalName and Name right after it.
  defp created_cost(%{result: {:created, _}}), do: 2
  defp created_cost(_op), do: 0

  # Whether `op` is a create_node on the tree at `tree_path`.
  defp creates_on?(%{result: {:created, tree}}, tree_path), do: Ref.path(tree) == tree_path
  defp creates_on?(_op, _tree_path), do: false

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

  defp finish(%{cur: cur, done: done} = st),
    do: finish(%{st | cur: nil, done: [close(cur) | done]})

  # After a node's Delete is placed, its memoized lookups (the node, its inputs and
  # outputs) are stale. Dropping them makes a later op that names the node look it up
  # again, and get whatever Poser says. A plain `Batch.call(node, "Delete")` is caught here
  # on purpose too.
  defp forget(chunk, %{ref: %ShaderNode{} = node, method: "Delete"}) do
    path = Ref.path(node)
    memo = Map.reject(chunk.memo, fn {key, _} -> List.starts_with?(key, path) end)
    %{chunk | memo: memo}
  end

  defp forget(chunk, _op), do: chunk

  # Path prefixes not yet looked up in `chunk`, for the op's target and its
  # struct arguments, each prefix once.
  defp missing(chunk, op) do
    for ref <- refs(op),
        path = Ref.path(ref),
        i <- 1..length(path)//1,
        prefix = Enum.take(path, i),
        not Map.has_key?(chunk.memo, prefix),
        uniq: true,
        do: prefix
  end

  defp note_change(chunk, op, k) do
    case changes(op) do
      nil ->
        chunk

      tree ->
        path = Ref.path(tree)
        %{chunk | previews: List.keystore(chunk.previews, path, 0, {path, k})}
    end
  end

  defp open(st, k) do
    chunk = %{
      wire: [@scene],
      n: 1,
      previews: [],
      roles: %{0 => {:lookup, [], k}},
      memo: %{[] => 0}
    }

    case st do
      %{done: [], framed?: true} ->
        %{st | cur: chunk |> emit(@read_frame, {:frame, k}) |> Map.put(:orig, {:result, 1})}

      _ ->
        %{st | cur: Map.put(chunk, :orig, :original_frame)}
    end
  end

  defp place(st, op, k, last?) do
    if reserved(st.cur) + cost(st, st.cur, op, last?) > st.limit do
      raise ArgumentError,
            "chunk: #{st.limit} is too small for op #{k} on #{inspect(op.ref)}"
    end

    missing = missing(st.cur, op)
    check_same_chunk!(missing, k)
    chunk = Enum.reduce(missing, st.cur, &emit_lookup(&2, &1, k))
    target = target_frame(op)

    {chunk, st} =
      if target == st.frame do
        {chunk, st}
      else
        {emit(chunk, set_frame(chunk, target), {:frame, k}), %{st | frame: target, moved: true}}
      end

    path = Ref.path(op.ref)
    args = Enum.map(op.args, &resolve_arg(&1, chunk))
    wire = {:invoke, {:result, chunk.memo[path]}, op.method, args}
    chunk = chunk |> emit(wire, {:caller, k}) |> forget(op) |> created(op, k)

    chunk =
      if last? and st.moved, do: emit(chunk, set_frame(chunk, :orig), {:frame, k}), else: chunk

    %{st | cur: note_change(chunk, op, k)}
  end

  # One more wire op when the op's tree has no preview in the chunk yet.
  defp preview_cost(chunk, op) do
    case changes(op) do
      nil -> 0
      tree -> if List.keymember?(chunk.previews, Ref.path(tree), 0), do: 0, else: 1
    end
  end

  defp refs(op), do: [op.ref | Enum.filter(op.args, &Ref.ref?/1)] ++ List.wrap(changes(op))

  # The chunk's wire ops so far plus the previews it will end with.
  defp reserved(chunk), do: chunk.n + length(chunk.previews)

  defp resolve_arg(arg, chunk) do
    if Ref.ref?(arg), do: {:result, chunk.memo[Ref.path(arg)]}, else: arg
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
