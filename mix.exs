defmodule Trolleybus.MixProject do
  use Mix.Project

  def project do
    [
      app: :trolleybus,
      version: "0.1.0",
      elixir: "~> 1.12",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {Trolleybus.Application, []}
    ]
  end

  defp deps do
    [
      {:ecto, "~> 3.0", optional: true}
    ]
  end
end
