defmodule ExPoser.ShaderTree do
  @moduledoc """
  A shader tree: the main tree of a material or of a material layer, or the
  scene's atmosphere or background tree.

  `owner` is an `ExPoser.Material`, an `ExPoser.MaterialLayer`,
  `:atmosphere` or `:background`. Build one with `ExPoser.Material.tree/1`,
  `ExPoser.MaterialLayer.tree/1`, `ExPoser.Scene.atmosphere_tree/0` or
  `ExPoser.Scene.background_tree/0`.

      iex> ExPoser.Ref.path(%ExPoser.ShaderTree{owner: :background})
      [tree: :background]
      iex> prop = %ExPoser.Actor{figure: nil, internal: "ball", name: "Ball"}
      iex> skin = %ExPoser.Material{owner: prop, name: "Preview"}
      iex> ExPoser.Ref.path(%ExPoser.ShaderTree{owner: skin})
      [{:actor, "ball"}, {:material, "Preview"}, {:tree, :main}]
  """

  alias ExPoser.{Batch, Client, Error, Material, MaterialLayer, Ref, ShaderNode}
  alias ExPoser.ShaderTree.Snapshot

  @enforce_keys [:owner]
  defstruct [:owner]

  @type owner :: Material.t() | MaterialLayer.t() | :atmosphere | :background
  @type t :: %__MODULE__{owner: owner()}

  # kRenderEngineCode*
  @renderers %{preview: 0, firefly: 1, poser4: 2, sketch: 3, superfly: 4}
  @node_methods ["InternalName", "Name", "Type", "Location", "IsRoot", "Inputs", "Outputs"]
  @input_methods ["InternalName", "Name", "Type", "Value", "InNode", "InOutput"]
  @output_methods ["InternalName", "Name"]

  @doc group: "Nodes"
  @doc """
  Creates a node of Poser's type `type` (such as `"image_map"`, passed through
  unchanged) in the tree, in one batch. Poser refreshes the tree's preview.
  An unknown type gives Poser's error. Options: `:server`, `:timeout`.

  ## Examples

      ExPoser.ShaderTree.create_node(tree, "image_map")
      #=> {:ok, #ExPoser.ShaderNode<image_map>}
  """
  @spec create_node(t(), String.t(), keyword()) :: {:ok, ShaderNode.t()} | {:error, Error.t()}
  def create_node(%__MODULE__{} = tree, type, opts \\ []) when is_binary(type) do
    batch = Batch.create_node(Batch.new(), tree, type)

    with {:ok, [node]} <- Batch.run(batch, run_opts(opts)), do: {:ok, node}
  end

  @doc group: "Nodes"
  @doc """
  Like `create_node/3`, but returns the node and raises `ExPoser.Error` on failure.

  ## Examples

      ExPoser.ShaderTree.create_node!(tree, "image_map")
      #=> #ExPoser.ShaderNode<image_map>
  """
  @spec create_node!(t(), String.t(), keyword()) :: ShaderNode.t()
  def create_node!(tree, type, opts \\ []), do: tree |> create_node(type, opts) |> Ref.unwrap!()

  @doc group: "Escape hatch"
  @doc """
  The tree's `%ExPoser.Handle{}`, for calls this library doesn't wrap.
  Release it with `ExPoser.Client.release/2`. A tree that doesn't resolve
  gives `:not_found` with `details.path`. Options: `:server`, `:timeout`.

  ## Examples

      {:ok, h} = ExPoser.ShaderTree.handle(tree)
      ExPoser.Client.release([h])
  """
  @spec handle(t(), keyword()) :: {:ok, ExPoser.Handle.t()} | {:error, ExPoser.Error.t()}
  def handle(%__MODULE__{owner: owner} = tree, opts \\ []) do
    {parent, method} = parent_of(owner)
    Ref.fetch_handle(tree, "NumNodes", parent, method, [], opts)
  end

  @doc group: "Escape hatch"
  @doc """
  Like `handle/2`, but returns the handle and raises `ExPoser.Error` on failure.

  ## Examples

      h = ExPoser.ShaderTree.handle!(tree)
      ExPoser.Client.release([h])
  """
  @spec handle!(t(), keyword()) :: ExPoser.Handle.t()
  def handle!(tree, opts \\ []), do: tree |> handle(opts) |> Ref.unwrap!()

  @doc group: "Nodes"
  @doc """
  Finds a node by internal name (`"Image_Map"`) or by display name, with the
  same rules as `ExPoser.Scene.light/2`: the internal name is tried first, and
  a display name shared by several nodes gives `:ambiguous`. No match gives
  `:not_found`. Options: `:server`, `:timeout`.

  ## Examples

      ExPoser.ShaderTree.node(tree, "Image_Map")
      #=> {:ok, #ExPoser.ShaderNode<Image_Map>}
  """
  @spec node(t(), String.t(), keyword()) :: {:ok, ShaderNode.t()} | {:error, Error.t()}
  def node(%__MODULE__{} = tree, name, opts \\ []) when is_binary(name) do
    guess = %ShaderNode{tree: tree, internal: name, name: name}
    Ref.lookup(guess, tree, "Nodes", name, &build(tree, &1), run_opts(opts))
  end

  @doc group: "Nodes"
  @doc """
  Like `node/3`, but returns the struct and raises `ExPoser.Error` on failure.

  ## Examples

      ExPoser.ShaderTree.node!(tree, "Image_Map")
      #=> #ExPoser.ShaderNode<Image_Map>
  """
  @spec node!(t(), String.t(), keyword()) :: ShaderNode.t()
  def node!(tree, name, opts \\ []), do: tree |> node(name, opts) |> Ref.unwrap!()

  @doc group: "Nodes"
  @doc """
  Lists the tree's nodes, in Poser's order. Options: `:server`, `:timeout`.

  ## Examples

      ExPoser.ShaderTree.nodes(tree)
      #=> {:ok, [#ExPoser.ShaderNode<PoserSurface>, #ExPoser.ShaderNode<Image_Map>]}
  """
  @spec nodes(t(), keyword()) :: {:ok, [ShaderNode.t()]} | {:error, Error.t()}
  def nodes(%__MODULE__{} = tree, opts \\ []) do
    with {:ok, rows} <- Ref.children(tree, "Nodes", [], run_opts(opts)),
         do: {:ok, Enum.map(rows, &build(tree, &1))}
  end

  @doc group: "Nodes"
  @doc """
  Like `nodes/2`, but returns the list and raises `ExPoser.Error` on failure.

  ## Examples

      ExPoser.ShaderTree.nodes!(tree)
      #=> [#ExPoser.ShaderNode<PoserSurface>, #ExPoser.ShaderNode<Image_Map>]
  """
  @spec nodes!(t(), keyword()) :: [ShaderNode.t()]
  def nodes!(tree, opts \\ []), do: tree |> nodes(opts) |> Ref.unwrap!()

  @doc false
  # A renderer atom's code; an integer passes through; anything else raises.
  @spec renderer_code!(atom() | integer()) :: integer()
  def renderer_code!(code) when is_integer(code), do: code

  def renderer_code!(renderer) when is_atom(renderer) do
    case @renderers do
      %{^renderer => code} ->
        code

      _ ->
        raise ArgumentError,
              "a renderer is one of #{inspect(Map.keys(@renderers))} or an integer, " <>
                "got #{inspect(renderer)}"
    end
  end

  def renderer_code!(other),
    do: raise(ArgumentError, "a renderer is an atom or an integer, got #{inspect(other)}")

  @doc group: "Roots"
  @doc """
  The node that is the tree's root for `renderer`, or `nil` when it has none.
  A renderer is `:preview`, `:firefly`, `:poser4`, `:sketch`, `:superfly` or
  an integer code; an unknown atom raises `ArgumentError` before any request.
  Takes two data requests, plus the handle releases. Options: `:server`, `:timeout`.

  ## Examples

      ExPoser.ShaderTree.root(tree, :firefly)
      #=> {:ok, #ExPoser.ShaderNode<PoserSurface>}
  """
  @spec root(t(), atom() | integer(), keyword()) ::
          {:ok, ShaderNode.t() | nil} | {:error, Error.t()}
  def root(%__MODULE__{} = tree, renderer, opts \\ []) do
    code = renderer_code!(renderer)
    opts = run_opts(opts)

    with {:ok, [handle]} <-
           Batch.new() |> Batch.call(tree, "RendererRootNode", [code]) |> Batch.run(opts) do
      read_node(tree, handle, opts)
    end
  end

  @doc group: "Roots"
  @doc """
  Like `root/3`, but returns the node (or `nil`) and raises `ExPoser.Error` on
  failure.

  ## Examples

      ExPoser.ShaderTree.root!(tree, :superfly)
      #=> nil
  """
  @spec root!(t(), atom() | integer(), keyword()) :: ShaderNode.t() | nil
  def root!(tree, renderer, opts \\ []), do: tree |> root(renderer, opts) |> Ref.unwrap!()

  @doc group: "Roots"
  @doc """
  Makes `node` the root of its tree for `renderer` (see `root/3`). Poser
  refreshes the tree's preview afterwards. Options: `:server`, `:timeout`.

  ## Examples

      ExPoser.ShaderTree.set_root(image_node, :superfly)
      #=> {:ok, :ok}
  """
  @spec set_root(ShaderNode.t(), atom() | integer(), keyword()) ::
          {:ok, :ok} | {:error, Error.t()}
  def set_root(%ShaderNode{} = node, renderer, opts \\ []) do
    batch = Batch.set_root(Batch.new(), node, renderer)
    with {:ok, _} <- Batch.run(batch, run_opts(opts)), do: {:ok, :ok}
  end

  @doc group: "Roots"
  @doc """
  Like `set_root/3`, but returns `:ok` and raises `ExPoser.Error` on failure.

  ## Examples

      ExPoser.ShaderTree.set_root!(image_node, :superfly)
      #=> :ok
  """
  @spec set_root!(ShaderNode.t(), atom() | integer(), keyword()) :: :ok
  def set_root!(node, renderer, opts \\ []), do: node |> set_root(renderer, opts) |> Ref.unwrap!()

  @doc group: "Snapshots"
  @doc """
  Reads the tree's nodes (internal name, name, type, location, root flag, and
  each node's inputs and outputs with the links between them) and its root
  node's internal name for each renderer, as an `ExPoser.ShaderTree.Snapshot`.
  It takes four batch round trips: the nodes and roots, each node's fields with
  its inputs and outputs lists, the inputs' and outputs' own reads, and the
  names of the nodes and outputs the inputs are connected to. Each of the
  first three returns handles, which a request after it releases; the fourth
  returns only names. Releasing the connected nodes' and outputs' handles
  takes one more request, so eight requests in all, however many nodes there
  are, while the reads fit in one `ExPoser.Batch` chunk (2000 wire ops). When
  no input is connected, the fourth round trip and that release are not sent,
  so six. Options: `:server`, `:timeout`.

  ## Examples

      ExPoser.ShaderTree.snapshot(tree)
      #=> {:ok, %ExPoser.ShaderTree.Snapshot{tree: tree, nodes: [...], roots: %{...}}}
  """
  @spec snapshot(t(), keyword()) :: {:ok, Snapshot.t()} | {:error, Error.t()}
  def snapshot(%__MODULE__{} = tree, opts \\ []) do
    opts = run_opts(opts)
    batch = Batch.call(Batch.new(), tree, "Nodes", [])

    batch =
      Enum.reduce(renderer_codes(), batch, fn {_renderer, code}, acc ->
        Batch.call(acc, tree, "RendererRootNode", [code])
      end)

    with {:ok, [nodes | roots] = handles} <- Batch.run(batch, opts) do
      try do
        read_snapshot(tree, nodes, roots, opts)
      after
        Ref.release_in(handles, opts)
      end
    end
  end

  @doc group: "Snapshots"
  @doc """
  Like `snapshot/2`, but returns the snapshot and raises `ExPoser.Error` on
  failure.

  ## Examples

      ExPoser.ShaderTree.snapshot!(tree)
      #=> %ExPoser.ShaderTree.Snapshot{tree: tree, nodes: [...], roots: %{...}}
  """
  @spec snapshot!(t(), keyword()) :: Snapshot.t()
  def snapshot!(tree, opts \\ []), do: tree |> snapshot(opts) |> Ref.unwrap!()

  defp build(tree, row),
    do: %ShaderNode{tree: tree, internal: row["InternalName"], name: row["Name"]}

  defp input_maps(in_rows, links) do
    {maps, []} =
      Enum.map_reduce(in_rows, links, fn
        [internal, name, type, value, node, output], rest when node != nil and output != nil ->
          [[node_internal, output_internal] | rest] = rest

          {%{
             internal: internal,
             name: name,
             type: type,
             value: value,
             from: {node_internal, output_internal}
           }, rest}

        [internal, name, type, value, _node, _output], rest ->
          {%{internal: internal, name: name, type: type, value: value, from: nil}, rest}
      end)

    maps
  end

  defp node_maps(rows, inputs, outputs) do
    {maps, {[], []}} =
      Enum.map_reduce(rows, {inputs, outputs}, fn
        [internal, name, type, location, root, in_handles, out_handles], {ins, outs} ->
          {mine_in, rest_in} = Enum.split(ins, length(in_handles))
          {mine_out, rest_out} = Enum.split(outs, length(out_handles))

          node = %{
            internal: internal,
            name: name,
            type: type,
            location: location,
            root: root,
            inputs: mine_in,
            outputs: mine_out
          }

          {node, {rest_in, rest_out}}
      end)

    maps
  end

  defp output_maps(out_values) do
    for [internal, name] <- Enum.chunk_every(out_values, length(@output_methods)),
        do: %{internal: internal, name: name}
  end

  defp parent_of(:atmosphere), do: {:scene, "AtmosphereShaderTree"}
  defp parent_of(:background), do: {:scene, "BackgroundShaderTree"}
  defp parent_of(owner), do: {owner, "ShaderTree"}

  defp read_node(_tree, nil, _opts), do: {:ok, nil}

  defp read_node(tree, handle, opts) do
    result = Ref.read_children([handle], ["InternalName", "Name"], opts)
    Ref.release_in(handle, opts)

    with {:ok, [row]} <- result, do: {:ok, build(tree, row)}
  end

  # Step 4: the internal names of the nodes and outputs the inputs are connected to.
  defp read_links(in_rows, opts) do
    ops =
      for [_, _, _, _, node, output] <- in_rows,
          node != nil and output != nil,
          h <- [node, output],
          do: {:invoke, h, "InternalName", []}

    case ops do
      [] -> {:ok, []}
      _ -> with {:ok, names} <- run_batch(ops, opts), do: {:ok, Enum.chunk_every(names, 2)}
    end
  end

  # Step 3: every input's and output's own reads, then step 4. The step-2 handles
  # are released by the caller; the InNode and InOutput handles here, after step 4.
  defp read_ports(rows, opts) do
    in_handles = for [_, _, _, _, _, ins, _outs] <- rows, h <- ins, do: h
    out_handles = for [_, _, _, _, _, _ins, outs] <- rows, h <- outs, do: h

    ops =
      for(h <- in_handles, m <- @input_methods, do: {:invoke, h, m, []}) ++
        for h <- out_handles, m <- @output_methods, do: {:invoke, h, m, []}

    with {:ok, values} <- run_batch(ops, opts) do
      try do
        {in_values, out_values} = Enum.split(values, length(in_handles) * length(@input_methods))
        in_rows = Enum.chunk_every(in_values, length(@input_methods))

        with {:ok, links} <- read_links(in_rows, opts) do
          {:ok, {input_maps(in_rows, links), output_maps(out_values)}}
        end
      after
        Ref.release_in(values, opts)
      end
    end
  end

  # Step 2: the nodes' own reads, with their Inputs() and Outputs() handle lists.
  # Those are released after step 3, on success and on failure.
  defp read_snapshot(tree, nodes, roots, opts) do
    live_roots = Enum.reject(roots, &is_nil/1)

    ops =
      for(h <- nodes, m <- @node_methods, do: {:invoke, h, m, []}) ++
        for h <- live_roots, do: {:invoke, h, "InternalName", []}

    with {:ok, values} <- run_batch(ops, opts) do
      try do
        {node_values, root_values} = Enum.split(values, length(nodes) * length(@node_methods))
        rows = Enum.chunk_every(node_values, length(@node_methods))

        with {:ok, {inputs, outputs}} <- read_ports(rows, opts) do
          {:ok,
           %Snapshot{
             tree: tree,
             nodes: node_maps(rows, inputs, outputs),
             roots: root_map(roots, root_values)
           }}
        end
      after
        Ref.release_in(values, opts)
      end
    end
  end

  defp renderer_codes, do: Enum.sort_by(@renderers, fn {_renderer, code} -> code end)

  defp root_map(roots, root_values) do
    {pairs, []} =
      renderer_codes()
      |> Enum.zip(roots)
      |> Enum.map_reduce(root_values, fn
        {{renderer, _code}, nil}, rest -> {{renderer, nil}, rest}
        {{renderer, _code}, _handle}, [internal | rest] -> {{renderer, internal}, rest}
      end)

    Map.new(pairs)
  end

  # Client.batch, releasing the handles of a failed batch's partial results.
  defp run_batch(ops, opts) do
    case Client.batch(ops, opts) do
      {:error, %Error{kind: :batch_failed, details: %{partial: partial}}} = error ->
        Ref.release_in(partial, opts)
        error

      other ->
        other
    end
  end

  defp run_opts(opts), do: Keyword.validate!(opts, [:server, :timeout])

  defimpl Inspect do
    def inspect(%{owner: owner}, _opts), do: "#ExPoser.ShaderTree<#{label(owner)}>"

    defp label(owner) when is_atom(owner), do: Atom.to_string(owner)
    defp label(%{name: name, material: %{name: material}}), do: "#{material}/#{name}"
    defp label(%{name: name}), do: name
  end
end
