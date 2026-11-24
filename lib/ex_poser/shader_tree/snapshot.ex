defmodule ExPoser.ShaderTree.Snapshot do
  @moduledoc """
  A shader tree's state, as read by `ExPoser.ShaderTree.snapshot/2`.

  `tree` is the tree that was read. `nodes` has one map per node, in Poser's
  order, with the keys `:internal`, `:name`, `:type`, `:location`, `:root`,
  `:inputs` and `:outputs`. `type`, `location` and `root` are what Poser
  returns from `Type()`, `Location()` and `IsRoot()`, as the codec decodes
  them. The node's inputs and outputs are not read yet, so `:inputs` and
  `:outputs` are empty lists. `roots` maps each renderer atom (`:preview`,
  `:firefly`, `:poser4`, `:sketch`, `:superfly`) to its root node's internal
  name, or `nil` when the renderer has no root.
  """

  @enforce_keys [:tree, :nodes, :roots]
  defstruct [:tree, :nodes, :roots]

  @type node_map :: %{
          internal: String.t(),
          name: String.t(),
          type: term(),
          location: term(),
          root: term(),
          inputs: list(),
          outputs: list()
        }
  @type t :: %__MODULE__{
          tree: ExPoser.ShaderTree.t(),
          nodes: [node_map()],
          roots: %{atom() => String.t() | nil}
        }
end
