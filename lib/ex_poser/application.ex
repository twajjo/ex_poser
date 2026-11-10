defmodule ExPoser.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Registry, keys: :duplicate, name: ExPoser.Events.Registry},
      {Task.Supervisor, name: ExPoser.TaskSupervisor}
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: ExPoser.Supervisor)
  end
end
