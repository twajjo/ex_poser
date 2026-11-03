defmodule Poser.Actor do
  @moduledoc """
  A Poser actor: a body part, prop, camera or light.

  Body parts have `figure` set; props, cameras and lights have `figure: nil`.

      iex> fig = %Poser.Figure{internal: "figure 1", name: "Andy"}
      iex> inspect(%Poser.Actor{figure: fig, internal: "lforearm", name: "Left Forearm"})
      "#Poser.Actor<figure 1/lforearm>"
      iex> inspect(%Poser.Actor{figure: nil, internal: "ball", name: "Ball"})
      "#Poser.Actor<ball>"
  """

  @enforce_keys [:internal, :name]
  defstruct [:figure, :internal, :name]

  @type t :: %__MODULE__{
          figure: Poser.Figure.t() | nil,
          internal: String.t(),
          name: String.t()
        }

  defimpl Inspect do
    def inspect(actor, _opts), do: "#Poser.Actor<#{Poser.Ref.path_string(actor)}>"
  end
end
