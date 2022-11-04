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

Copyright (c) 2022 Sketch B.V.

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at [http://www.apache.org/licenses/LICENSE-2.0](http://www.apache.org/licenses/LICENSE-2.0)

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
