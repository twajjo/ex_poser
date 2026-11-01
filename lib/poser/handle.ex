defmodule Poser.Handle do
  @moduledoc """
  A reference to a live Poser object held in the add-on's handle table.

  `epoch` is the client connection it came from; a handle from an earlier
  connection is stale and is rejected without being sent.
  """

  @enforce_keys [:class, :id, :generation]
  defstruct [:class, :id, :generation, :label, :epoch]

  @type t :: %__MODULE__{
          class: String.t(),
          id: pos_integer(),
          generation: non_neg_integer(),
          label: String.t() | nil,
          epoch: non_neg_integer() | nil
        }
end
