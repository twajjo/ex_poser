defmodule ExPoser.Batch do
  @moduledoc """
  Many reads and writes on name-path structs, sent as few requests as
  possible. Every function in `ExPoser.Scene`, `ExPoser.Figure`, `ExPoser.Actor`
  and `ExPoser.Parameter` is a one-op batch, so a hand-built batch behaves the
  same way, only in fewer round trips.

  Build one with `new/0` and the op functions and send it with `run/2`, or
  do both with `ExPoser.batch/2`. Results come back one per op, in order.

  - **Lookups.** Each struct's path is resolved inside Poser in the same
    request as its op, and ops share lookups on a common path prefix. No
    handle is kept, so nothing goes stale. Struct arguments of `call/5`
    (top level only) are resolved the same way, in the same request.
  - **Frames.** Ops with `frame:` run at that frame; every other op runs at
    the frame the batch found, and that frame is restored at the end. Ops
    are never reordered.
  - **Chunks.** A batch over 2000 wire ops (lookups and frame moves
    included) is split into several requests, one Python main-thread turn
    each.
  - **No rollback.** Ops before a failure stay applied.

      iex> fig = %ExPoser.Figure{internal: "figure 1", name: "Andy"}
      iex> hip = %ExPoser.Actor{figure: fig, internal: "hip", name: "Hip"}
      iex> xrot = %ExPoser.Parameter{actor: hip, internal: "xrot", name: "xRotate"}
      iex> b =
      ...>   Enum.reduce(0..29, ExPoser.Batch.new(), fn n, b ->
      ...>     ExPoser.Batch.set(b, xrot, n * 3.0, frame: n)
      ...>   end)
      iex> ExPoser.Batch.size(b)
      30

  See the [Batching](batching.md) guide, and
  [Frames and keyframes](frames-and-keyframes.md) for `frame:`.
  """

  alias ExPoser.{
    Client,
    Codec,
    Error,
    Material,
    Parameter,
    Ref,
    ShaderInput,
    ShaderNode,
    ShaderOutput,
    ShaderTree
  }

  alias ExPoser.Batch.Compiler

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
           result: :ok | :value | {:created, ExPoser.ShaderTree.t()},
           changes: ExPoser.ShaderTree.t() | nil
         }

  @typedoc "Wire index → what the wire op is for."
  @type role ::
          {:lookup, [Ref.step()], non_neg_integer()}
          | {:caller, non_neg_integer()}
          | {:frame, non_neg_integer()}
          | {:created, non_neg_integer()}
          | {:preview, non_neg_integer()}

  @doc group: "Building"
  @doc """
  Adds a keyframe at `frame` without moving the scene's frame. Its result is `:ok`.

  ## Examples

      ExPoser.Batch.new() |> ExPoser.Batch.add_keyframe(bend, 7)
  """
  @spec add_keyframe(t(), Parameter.t(), non_neg_integer()) :: t()
  def add_keyframe(b, %Parameter{} = parm, frame) when is_integer(frame) and frame >= 0 do
    push(b, parm, "AddKeyFrame", [frame], nil, :ok)
  end

  @doc group: "Building"
  @doc """
  Calls `method` on the object `ref` resolves to (`:scene` or a struct).

  Its result is the method's return value. Handles it returns belong to the
  caller, who releases them with `ExPoser.Client.release/2`. Options: `:frame`.

  A figure, actor or parameter struct among `args` is resolved in the same
  request and sent as the object it names. Only top-level elements of `args`
  are resolved, not ones nested in a list or map.

  ## Examples

      ExPoser.Batch.new() |> ExPoser.Batch.call(:scene, "NumFrames", [])
      ExPoser.Batch.new() |> ExPoser.Batch.call(bend, "NextKeyFrame", [], frame: 3)
  """
  @spec call(t(), Ref.ref(), String.t(), list(), keyword()) :: t()
  def call(b, ref, method, args \\ [], opts \\ []) when is_binary(method) and is_list(args) do
    push(b, ref, method, args, frame_opt(opts), :value)
  end

  @doc false
  # Returns a `:frame` option value unchanged when it is nil or a
  # non-negative integer; raises `ArgumentError` otherwise. Shared with
  # callers that check `:frame` before sending any request.
  @spec check_frame!(term()) :: non_neg_integer() | nil
  def check_frame!(frame) when is_nil(frame) or (is_integer(frame) and frame >= 0), do: frame

  def check_frame!(other),
    do: raise(ArgumentError, "frame must be a non-negative integer, got #{inspect(other)}")

  @doc false
  # Returns `[{wire_ops, roles}]`, one per chunk; see ExPoser.Batch.Compiler.
  @spec compile(t(), keyword()) :: [{list(), %{non_neg_integer() => role()}}]
  def compile(%__MODULE__{} = b, opts),
    do: b |> ops() |> Compiler.compile(Keyword.get(opts, :chunk, @default_chunk))

  @doc group: "Materials"
  @doc """
  Creates a layer on `material`. Its result is `:ok`, as `CreateLayer` returns
  nothing. Poser keeps `name` as the layer's display name (`ExtName`) and gives
  the layer its own name, such as `"Layer_1"`, which is the name
  `ExPoser.MaterialLayer` uses; `ExPoser.Material.layers/2` lists it. The
  material's actor must be the scene's current actor: otherwise Poser refuses,
  with a message such as "Cannot add Material Layer to Light".

  ## Examples

      ExPoser.Batch.new() |> ExPoser.Batch.create_layer(skin, "Wet")
  """
  @spec create_layer(t(), Material.t(), String.t()) :: t()
  def create_layer(b, %Material{} = material, name) when is_binary(name),
    do: push(b, material, "CreateLayer", [name], nil, :ok)

  @doc group: "Materials"
  @doc """
  Creates a node of Poser's type `type` (a string, such as `"image_map"`, passed
  through unchanged) in `tree`. Its result is an `ExPoser.ShaderNode` with the
  internal and display names Poser gave it, available once the batch has run.
  The tree changes, so Poser refreshes its preview once per request chunk.
  Poser's error for an unknown type is the batch's error.

  ## Examples

      ExPoser.Batch.new() |> ExPoser.Batch.create_node(tree, "image_map")
  """
  @spec create_node(t(), ShaderTree.t(), String.t()) :: t()
  def create_node(b, %ShaderTree{} = tree, type) when is_binary(type),
    do: push(b, tree, "CreateNode", [type], nil, {:created, tree}, tree)

  @doc group: "Materials"
  @doc """
  A placeholder `ExPoser.ShaderNode` for the node the batch's last op, a
  `create_node/3`, will create. Name its inputs and outputs in later ops of
  the same batch, as `ExPoser.ShaderNode.input/2` and `output/2` allow, in the
  `create_node/3`'s request chunk or a later one. An op naming a created node
  must come after its `create_node/3`, on the same tree, or `run/2` raises
  `ArgumentError` before sending anything. Raises `ArgumentError` when the
  last op isn't a `create_node/3`.

  ## Examples

      b = ExPoser.Batch.new() |> ExPoser.Batch.create_node(tree, "image_map")
      node = ExPoser.Batch.created(b)
      b |> ExPoser.Batch.link(node, diffuse_color)
  """
  @spec created(t()) :: ShaderNode.t()
  def created(%__MODULE__{ops: [%{result: {:created, tree}} | _], size: size}),
    do: %ShaderNode{tree: tree, internal: {:created, size - 1}, name: nil}

  def created(%__MODULE__{}),
    do: raise(ArgumentError, "created/1 needs the batch's last op to be a create_node")

  @doc group: "Building"
  @doc """
  Deletes the keyframe at `frame` without moving the scene's frame. Its result is `:ok`.

  ## Examples

      ExPoser.Batch.new() |> ExPoser.Batch.delete_keyframe(bend, 7)
  """
  @spec delete_keyframe(t(), Parameter.t(), non_neg_integer()) :: t()
  def delete_keyframe(b, %Parameter{} = parm, frame) when is_integer(frame) and frame >= 0 do
    push(b, parm, "DeleteKeyFrame", [frame], nil, :ok)
  end

  @doc group: "Materials"
  @doc """
  Deletes a shader node from its tree. Its result is `:ok`. The tree changes, so
  Poser refreshes its preview once per request chunk. Ops run strictly in order:
  a later op in the batch that names the deleted node, or one of its inputs or
  outputs, looks it up again and gets whatever Poser answers (normally
  `:not_found`), while the delete stays applied.

  ## Examples

      ExPoser.Batch.new() |> ExPoser.Batch.delete_node(image_node)
  """
  @spec delete_node(t(), ShaderNode.t()) :: t()
  def delete_node(b, %ShaderNode{tree: tree} = node),
    do: push(b, node, "Delete", [], nil, :ok, tree)

  @doc group: "Building"
  @doc """
  Reads a parameter's value. Its result is the float value.

  Options: `:frame`, the frame to read at (default: the batch's original frame).

  ## Examples

      ExPoser.Batch.new() |> ExPoser.Batch.get(bend, frame: 12)
  """
  @spec get(t(), Parameter.t(), keyword()) :: t()
  def get(b, %Parameter{} = parm, opts \\ []) do
    push(b, parm, "Value", [], frame_opt(opts), :value)
  end

  @doc group: "Materials"
  @doc """
  Connects `from`, a shader output or a shader node (its first output), to
  `input`. Its result is `:ok`. The input's tree changes, so Poser refreshes
  its preview once per request chunk.

  ## Examples

      ExPoser.Batch.new() |> ExPoser.Batch.link(image_node, diffuse_color)
  """
  @spec link(t(), ShaderOutput.t() | ShaderNode.t(), ShaderInput.t()) :: t()
  def link(b, %type{} = from, %ShaderInput{node: %{tree: tree}} = input)
      when type in [ShaderOutput, ShaderNode],
      do: push(b, from, "ConnectToInput", [input], nil, :ok, tree)

  @doc group: "Building"
  @doc """
  An empty batch.

  ## Examples

      iex> ExPoser.Batch.new()
      %ExPoser.Batch{ops: [], size: 0}
  """
  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc group: "Running"
  @doc """
  Sends the batch. Returns one result per op, in order: `:ok` for setters
  and keyframe ops, the value for `get/3` and `call/5`.

  Options: `:server` and `:timeout` as in `ExPoser.Client`, and `:chunk`, the
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

      ExPoser.Batch.new()
      |> ExPoser.Batch.set(bend, 30.0, frame: 4)
      |> ExPoser.Batch.get(bend, frame: 4)
      |> ExPoser.Batch.run()
      #=> {:ok, [:ok, 30.0]}

      ExPoser.Batch.new() |> ExPoser.Batch.get(missing) |> ExPoser.Batch.run()
      #=> {:error, %ExPoser.Error{kind: :not_found, details: %{index: 0, ...}}}
  """
  @spec run(t(), keyword()) :: {:ok, [term()]} | {:error, Error.t()}
  def run(%__MODULE__{} = b, opts \\ []) do
    {chunk, client_opts} = opts |> run_opts() |> Keyword.pop!(:chunk)

    if b.size == 0 do
      {:ok, []}
    else
      chunks = compile(b, chunk: chunk)
      kinds = b |> ops() |> Enum.map(& &1.result) |> List.to_tuple()
      run_chunks(chunks, kinds, client_opts, %{orig: nil, moved: false, acc: [], created: %{}})
    end
  end

  @doc group: "Running"
  @doc """
  Like `run/2`, but returns the results and raises `ExPoser.Error` on failure.

  ## Examples

      ExPoser.Batch.new()
      |> ExPoser.Batch.set(bend, 30.0, frame: 4)
      |> ExPoser.Batch.get(bend, frame: 4)
      |> ExPoser.Batch.run!()
      #=> [:ok, 30.0]

      ExPoser.Batch.new() |> ExPoser.Batch.get(missing) |> ExPoser.Batch.run!()
      ** (ExPoser.Error) not_found: figure 1/hip/nope
  """
  @spec run!(t(), keyword()) :: [term()]
  def run!(b, opts \\ []), do: b |> run(opts) |> Ref.unwrap!()

  @doc group: "Building"
  @doc """
  Sets a parameter's value. Integers are sent as floats. Its result is `:ok`.

  Poser keys the value at the frame it is set at. Options: `:frame`, the
  frame to set at (default: the batch's original frame).

  ## Examples

      ExPoser.Batch.new() |> ExPoser.Batch.set(bend, 30, frame: 5)
  """
  @spec set(t(), Parameter.t(), number(), keyword()) :: t()
  def set(b, %Parameter{} = parm, value, opts \\ []) when is_number(value) do
    push(b, parm, "SetValue", [value * 1.0], frame_opt(opts), :ok)
  end

  @doc group: "Materials"
  @doc """
  Sets a shader input's value, by the value's shape: a string goes to
  `SetString`, a `{r, g, b}` tuple of numbers to `SetColor`, a number to
  `SetFloat`. Its result is `:ok`. Any other value raises `ArgumentError`
  now. Poser refreshes the tree's preview once per request chunk, after the
  last op that changed it.

  ## Examples

      ExPoser.Batch.new() |> ExPoser.Batch.set_input(color_input, {1, 0, 0})
  """
  @spec set_input(t(), ShaderInput.t(), String.t() | {number(), number(), number()} | number()) ::
          t()
  def set_input(b, %ShaderInput{node: %{tree: tree}} = input, value) do
    {method, args} = ShaderInput.set_call!(value)
    push(b, input, method, args, nil, :ok, tree)
  end

  @doc group: "Materials"
  @doc """
  Sets one flat setting of a material (a key from `ExPoser.Material.props/0`).
  Its result is `:ok`. The key and value are checked now: a bad one raises
  `ArgumentError`.

  ## Examples

      ExPoser.Batch.new() |> ExPoser.Batch.set_material(skin, :diffuse_color, {0.1, 0.2, 0.3})
  """
  @spec set_material(t(), Material.t(), atom(), term()) :: t()
  def set_material(b, %Material{} = material, key, value) do
    {method, args} = Material.set_call!(key, value)
    push(b, material, method, args, nil, :ok)
  end

  @doc group: "Materials"
  @doc """
  Sets a shader node's `:name` (a string) or `:location` (an `{x, y}` pair of
  integers). Its result is `:ok`. The key and value are checked now: a bad
  one raises `ArgumentError`. Renaming or moving a node does not change the
  tree, so no preview refresh follows.

  ## Examples

      ExPoser.Batch.new() |> ExPoser.Batch.set_node(node, :location, {120, 40})
  """
  @spec set_node(t(), ShaderNode.t(), atom(), term()) :: t()
  def set_node(b, %ShaderNode{} = node, key, value) do
    {method, args} = ShaderNode.set_call!(key, value)
    push(b, node, method, args, nil, :ok)
  end

  @doc group: "Materials"
  @doc """
  Makes `node` the root of its tree for `renderer`: `:preview`, `:firefly`,
  `:poser4`, `:sketch`, `:superfly` or an integer code. Its result is `:ok`.
  An unknown atom raises `ArgumentError` now. The tree changes, so Poser
  refreshes its preview once per request chunk.

  Poser only honours this for `:firefly` and `:superfly`. For `:preview`,
  `:poser4` and `:sketch` it returns `:ok` but changes nothing, and
  `ExPoser.ShaderTree.root/3` for those renderers reports firefly's root.

  ## Examples

      ExPoser.Batch.new() |> ExPoser.Batch.set_root(image_node, :superfly)
  """
  @spec set_root(t(), ShaderNode.t(), atom() | integer()) :: t()
  def set_root(b, %ShaderNode{tree: tree} = node, renderer) do
    # Poser takes the renderer code first, though its docstring documents
    # SetRendererRootNode(node, renderer); that order is a parse error.
    push(
      b,
      tree,
      "SetRendererRootNode",
      [ShaderTree.renderer_code!(renderer), node],
      nil,
      :ok,
      tree
    )
  end

  @doc group: "Building"
  @doc """
  The number of ops the caller added.

  ## Examples

      iex> fig = %ExPoser.Figure{internal: "figure 1", name: "Figure 1"}
      iex> hip = %ExPoser.Actor{figure: fig, internal: "hip", name: "hip"}
      iex> p = %ExPoser.Parameter{actor: hip, internal: "xtran", name: "xTran"}
      iex> ExPoser.Batch.new()
      ...> |> ExPoser.Batch.get(p)
      ...> |> ExPoser.Batch.set(p, 1.0)
      ...> |> ExPoser.Batch.size()
      2
  """
  @spec size(t()) :: non_neg_integer()
  def size(%__MODULE__{size: size}), do: size

  @doc group: "Materials"
  @doc """
  Disconnects whatever feeds `input`. Its result is `:ok`. The input's tree
  changes, so Poser refreshes its preview once per request chunk.

  ## Examples

      ExPoser.Batch.new() |> ExPoser.Batch.unlink(diffuse_color)
  """
  @spec unlink(t(), ShaderInput.t()) :: t()
  def unlink(b, %ShaderInput{node: %{tree: tree}} = input),
    do: push(b, input, "Disconnect", [], nil, :ok, tree)

  # Caller results of chunks that already ran; the caller never receives them.
  defp acc_handles(st), do: st.acc |> Enum.concat() |> Codec.handles_in()

  # A caller op whose receiver is a lookup that found nothing is a not_found
  # for that lookup's path; any other failure keeps the caller's index.
  defp caller_error(i, k, cause, partial, wire, roles) do
    with {:result, j} when is_map_key(roles, j) <- wire |> Enum.at(i) |> target(),
         {{:lookup, [_ | _] = prefix, _}, nil} <- {roles[j], Enum.at(partial, j)} do
      not_found(prefix, k, cause)
    else
      _ -> with_index(cause, k)
    end
  end

  defp caller_results(results, roles, kinds) do
    for {result, i} <- Enum.with_index(results), {:caller, k} <- [roles[i]] do
      case elem(kinds, k) do
        :ok -> :ok
        {:created, tree} -> created_node(tree, results, i)
        :value -> result
      end
    end
  end

  # The CreateNode handles of a finished chunk; the caller never gets them.
  defp created_handles(results, roles, kinds) do
    for {result, i} <- Enum.with_index(results),
        {:caller, k} <- [roles[i]],
        match?({:created, _}, elem(kinds, k)),
        do: result
  end

  # k => InternalName for each CreateNode of a finished chunk, for later chunks.
  defp created_names(results, roles, kinds) do
    for {_, i} <- Enum.with_index(results),
        {:caller, k} <- [roles[i]],
        match?({:created, _}, elem(kinds, k)),
        into: %{},
        do: {k, Enum.at(results, i + 1)}
  end

  # The CreateNode handle is at `i`; its InternalName and Name reads follow.
  defp created_node(tree, results, i) do
    %ShaderNode{tree: tree, internal: Enum.at(results, i + 1), name: Enum.at(results, i + 2)}
  end

  defp frame_opt(opts), do: check_frame!(Keyword.validate!(opts, [:frame])[:frame])

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
        caller_error(i, k, cause, partial, wire, roles)
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

  defp push(
         %__MODULE__{ops: ops, size: size} = b,
         ref,
         method,
         args,
         frame,
         result,
         changes \\ nil
       ) do
    op = %{ref: ref, method: method, args: args, frame: frame, result: result, changes: changes}
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
    wire = substitute(wire, st.orig, st.created)

    case Client.batch(wire, opts) do
      {:ok, results} ->
        release(lookup_handles(results, roles) ++ created_handles(results, roles, kinds), opts)

        st = %{
          st
          | orig: orig(st.orig, wire, results),
            moved: st.moved or moves?(wire, roles),
            created: Map.merge(st.created, created_names(results, roles, kinds))
        }

        run_chunks(rest, kinds, opts, %{
          st
          | acc: [caller_results(results, roles, kinds) | st.acc]
        })

      {:error, %Error{kind: :batch_failed, details: details}} ->
        %{index: i, cause: cause, partial: partial} = details
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

  defp substitute(wire, orig, created) do
    Enum.map(wire, fn
      {:invoke, t, "SetFrame", [:original_frame]} when orig != nil ->
        {:invoke, t, "SetFrame", [orig]}

      # Markers only come from creates in earlier chunks, whose names are recorded.
      {:invoke, t, "NodeByInternalName", [{:created_name, k}]} ->
        {:invoke, t, "NodeByInternalName", [Map.fetch!(created, k)]}

      op ->
        op
    end)
  end

  defp target({:invoke, target, _method, _args}), do: target
  defp target(_), do: nil

  defp with_index(%Error{details: details} = cause, k),
    do: %{cause | details: Map.merge(details || %{}, %{index: k})}
end
