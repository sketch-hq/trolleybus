defmodule Mix.Tasks.Trolleybus.Routes do
  @shortdoc "List all event <-> handler relations set up by Trolleybus"

  @moduledoc """
  This task prints routing between events and handlers setup by `Trolleybus`.

  ## Usage

      mix trolleybus.routes
  """

  use Mix.Task

  @impl true
  def run(args) do
    Mix.Task.run("compile", args)
    Mix.Task.reenable("trolleybus.routes")

    app_name =
      Mix.Project.config()
      |> Keyword.fetch!(:app)

    :ok = Application.ensure_loaded(app_name)

    IO.puts("")

    Enum.each(collect_routes(app_name), fn {event, handlers} ->
      print_route(event, handlers)
      IO.puts("")
    end)
  end

  defp print_route(event, []) do
    IO.puts("* #{inspect(event)} => [No handlers]")
  end

  defp print_route(event, handlers) do
    event_str = inspect(event)

    IO.puts("* #{event_str}")

    Enum.each(handlers, fn handler ->
      handler_str = "    => #{inspect(handler)}"
      IO.puts("#{handler_str}")
    end)
  end

  defp collect_routes(app_name) do
    app_name
    |> Application.spec(:modules)
    |> Enum.reduce([], fn module, routes ->
      event? =
        :attributes
        |> module.__info__()
        |> Enum.member?({:behaviour, [Trolleybus.Event]})

      if event? do
        [{module, Enum.sort(module.__handlers__())} | routes]
      else
        routes
      end
    end)
    |> Enum.sort()
  end
end
