defmodule Poser.NDArray do
  @moduledoc "A numpy array returned by Poser: raw bytes plus numpy dtype string and shape."

  @enforce_keys [:dtype, :shape, :data]
  defstruct [:dtype, :shape, :data]

  @type t :: %__MODULE__{dtype: String.t(), shape: tuple(), data: binary()}
end
