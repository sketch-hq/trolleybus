# Trolleybus

[![CI](https://github.com/sketch-hq/trolleybus/actions/workflows/ci.yml/badge.svg)](https://github.com/sketch-hq/trolleybus/actions/workflows/ci.yml) [![Hex.pm](https://img.shields.io/hexpm/v/trolleybus.svg)](https://hex.pm/packages/trolleybus) [![Documentation](https://img.shields.io/badge/documentation-gray)](https://hexdocs.pm/trolleybus/)

Local, application-level PubSub API for dispatching side effects.

Full documentation can be found on [Hex](https://hexdocs.pm/trolleybus/).

## Installation

The package can be installed by adding `trolleybus` to your list of
dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:trolleybus, "~> 0.1.0"}
  ]
end
```

## Running tests

Clone the repo and fetch its dependencies:

```bash
git clone https://github.com/sketch-hq/trolleybus.git
cd trolleybus
mix deps.get
mix test
```

## License

Elixir source code is released under MIT License.

Check [LICENSE](LICENSE) file for more information.
