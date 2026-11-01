defmodule Poserx.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    children = [{Registry, keys: :duplicate, name: Poser.Events.Registry}]
    Supervisor.start_link(children, strategy: :one_for_one, name: Poserx.Supervisor)
  end
end
