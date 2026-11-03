defmodule Poser.Figure do
  @moduledoc """
  A Poser figure, as listed in the GUI's figure menu (e.g. "Figure 1").

  `internal` is the key; `name` is the GUI label and can be renamed or repeated.
  The struct is plain data and never holds a live handle.

      iex> inspect(%Poser.Figure{internal: "figure 1", name: "Andy"})
      "#Poser.Figure<figure 1>"
  """

  @enforce_keys [:internal, :name]
  defstruct [:internal, :name]

  @type t :: %__MODULE__{internal: String.t(), name: String.t()}

  defimpl Inspect do
    def inspect(%{internal: internal}, _opts), do: "#Poser.Figure<#{internal}>"
  end
end
