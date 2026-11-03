defmodule Poser.Parameter do
  @moduledoc """
  A Poser dial (a "parm" in PoserPython) on an actor.

      iex> fig = %Poser.Figure{internal: "figure 1", name: "Andy"}
      iex> actor = %Poser.Actor{figure: fig, internal: "lforearm", name: "Left Forearm"}
      iex> inspect(%Poser.Parameter{actor: actor, internal: "bend", name: "Bend"})
      "#Poser.Parameter<figure 1/lforearm/bend>"
  """

  @enforce_keys [:actor, :internal, :name]
  defstruct [:actor, :internal, :name]

  @type t :: %__MODULE__{actor: Poser.Actor.t(), internal: String.t(), name: String.t()}

  defimpl Inspect do
    def inspect(parm, _opts), do: "#Poser.Parameter<#{Poser.Ref.path_string(parm)}>"
  end
end
