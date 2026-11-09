defmodule Poser.Events do
  @moduledoc """
  Fan-out of bridge events to subscribed processes.

  Subscribers receive `{:poser_event, event, payload}`. Events from Poser:
  `:frame_changed`, `:generation_changed`. From the client: `:connected`,
  `:disconnected`.
  """

  @registry Poser.Events.Registry

  @spec subscribe(atom()) :: :ok
  def subscribe(event) when is_atom(event) do
    {:ok, _} = Registry.register(@registry, event, nil)
    :ok
  end

  @spec unsubscribe(atom()) :: :ok
  def unsubscribe(event) when is_atom(event), do: Registry.unregister(@registry, event)

  @spec dispatch(atom(), term()) :: :ok
  def dispatch(event, payload) do
    Registry.dispatch(@registry, event, fn entries ->
      for {pid, _} <- entries, do: send(pid, {:poser_event, event, payload})
    end)
  end
end
