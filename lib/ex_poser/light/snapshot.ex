defmodule ExPoser.Light.Snapshot do
  @moduledoc """
  A light's state at one frame, as read by `ExPoser.Light.snapshot/2`.

  `name` is the light's GUI name, `type` its type atom (or the raw integer
  for a code this library doesn't know), `dials` maps each dial's internal
  name to its value, and `props` holds every other light property, decoded as
  `ExPoser.Light.get/3` decodes it.
  """

  @enforce_keys [:name, :type, :dials, :props]
  defstruct [:name, :type, :dials, :props]

  @type t :: %__MODULE__{
          name: String.t(),
          type: atom() | integer(),
          dials: %{String.t() => number()},
          props: %{atom() => term()}
        }
end
