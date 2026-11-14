defmodule ExPoser.Camera.Snapshot do
  @moduledoc """
  A camera's state at one frame, as read by `ExPoser.Camera.snapshot/2`.

  `name` is the camera's GUI name and `dials` maps each dial's internal name
  to its value.
  """

  @enforce_keys [:name, :dials]
  defstruct [:name, :dials]

  @type t :: %__MODULE__{
          name: String.t(),
          dials: %{String.t() => number()}
        }
end
