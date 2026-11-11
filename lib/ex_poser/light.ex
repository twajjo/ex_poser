defmodule ExPoser.Light do
  @moduledoc """
  A light: a scene-level actor that Poser reports as a light.

  It wraps its `ExPoser.Actor`, which holds the internal name (the key) and
  the GUI label. Find lights with `ExPoser.Scene.lights/1` and
  `ExPoser.Scene.light/2`.

      iex> actor = %ExPoser.Actor{figure: nil, internal: "light 1", name: "Key"}
      iex> inspect(%ExPoser.Light{actor: actor})
      "#ExPoser.Light<Key>"
  """

  @enforce_keys [:actor]
  defstruct [:actor]

  @type t :: %__MODULE__{actor: ExPoser.Actor.t()}

  alias ExPoser.Actor

  @doc group: "Escape hatch"
  @doc """
  The light's `%ExPoser.Handle{}`, for calls this library doesn't wrap. Like
  `ExPoser.Actor.handle/2`, whose rules apply: release the handle with
  `ExPoser.Client.release/2`.
  """
  @spec handle(t(), keyword()) :: {:ok, ExPoser.Handle.t()} | {:error, ExPoser.Error.t()}
  def handle(%__MODULE__{actor: actor}, opts \\ []), do: Actor.handle(actor, opts)

  defimpl Inspect do
    def inspect(%{actor: %{name: name}}, _opts), do: "#ExPoser.Light<#{name}>"
  end
end
