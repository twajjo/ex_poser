defmodule ExPoser.Camera do
  @moduledoc """
  A camera: a scene-level actor that Poser reports as a camera.

  It wraps its `ExPoser.Actor`, which holds the internal name (the key) and
  the GUI label. Find cameras with `ExPoser.Scene.cameras/1` and
  `ExPoser.Scene.camera/2`.

      iex> actor = %ExPoser.Actor{figure: nil, internal: "MAIN_CAMERA", name: "Main Camera"}
      iex> inspect(%ExPoser.Camera{actor: actor})
      "#ExPoser.Camera<Main Camera>"
  """

  @enforce_keys [:actor]
  defstruct [:actor]

  @type t :: %__MODULE__{actor: ExPoser.Actor.t()}

  alias ExPoser.Actor

  @doc group: "Escape hatch"
  @doc """
  The camera's `%ExPoser.Handle{}`, for calls this library doesn't wrap. Like
  `ExPoser.Actor.handle/2`, whose rules apply: release the handle with
  `ExPoser.Client.release/2`.
  """
  @spec handle(t(), keyword()) :: {:ok, ExPoser.Handle.t()} | {:error, ExPoser.Error.t()}
  def handle(%__MODULE__{actor: actor}, opts \\ []), do: Actor.handle(actor, opts)

  defimpl Inspect do
    def inspect(%{actor: %{name: name}}, _opts), do: "#ExPoser.Camera<#{name}>"
  end
end
