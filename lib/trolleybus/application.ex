defmodule Trolleybus.Application do
  @moduledoc """
  Application definition for Trolleybus.

  Starts a `Task.Supervisor` instance for running tasks
  executing handlers when publishing events.
  """

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Task.Supervisor, name: Trolleybus.TaskSupervisor}
    ]

    opts = [strategy: :one_for_one, name: Trolleybus.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
