defmodule ExPoser.ShaderTree.Snapshot do
  @moduledoc """
  A shader tree's state, as read by `ExPoser.ShaderTree.snapshot/2`.

  `tree` is the tree that was read. `nodes` has one map per node, in Poser's
  order, with the keys `:internal`, `:name`, `:type`, `:location`, `:root`,
  `:inputs` and `:outputs`. `type`, `location` and `root` are what Poser
  returns from `Type()`, `Location()` and `IsRoot()`, as the codec decodes
  them. `inputs` is a list of input maps in Poser's `Inputs()` order, each
  with `:internal`, `:name`, `:type`, `:value` and `:from`. `type` and `value`
  are what Poser returns from `Type()` and `Value()`, as the codec decodes
  them. `from` is `{node_internal, output_internal}` from `InNode()` and
  `InOutput()`, or `nil` unless both are set (Poser sets both when the input
  is connected, and neither when it is not). `outputs` is a list of
  `%{internal: ..., name: ...}` in `Outputs()` order. `roots` maps each
  renderer atom (`:preview`, `:firefly`, `:poser4`, `:sketch`, `:superfly`)
  to its root node's internal name, or `nil` when the renderer has no root.
  """

  @enforce_keys [:tree, :nodes, :roots]
  defstruct [:tree, :nodes, :roots]

  @type input_map :: %{
          internal: String.t(),
          name: String.t(),
          type: term(),
          value: term(),
          from: {String.t(), String.t()} | nil
        }
  @type output_map :: %{internal: String.t(), name: String.t()}
  @type node_map :: %{
          internal: String.t(),
          name: String.t(),
          type: term(),
          location: term(),
          root: term(),
          inputs: [input_map()],
          outputs: [output_map()]
        }
  @type t :: %__MODULE__{
          tree: ExPoser.ShaderTree.t(),
          nodes: [node_map()],
          roots: %{atom() => String.t() | nil}
        }
end
