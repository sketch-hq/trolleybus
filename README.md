# Trolleybus

Local, application-level PubSub API for dispatching side effects.

**TODO: More extensive description**

## TODOs

- [ ] make event macro generate typespecs for the struct as well
- [ ] turn event handler clause validation into a compile-time event
- [ ] tighten event handler clause check to enforce exhaustive matches on events
- [ ] make `full_sync?` first-class option and make it a default
- [ ] make struct field definition in event more strict (don't accept populated map)
- [ ] polish up documentation

## Installation

If [available in Hex](https://hex.pm/docs/publish), the package can be installed
by adding `trolleybus` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:trolleybus, "~> 0.1.0"}
  ]
end
```

Documentation can be generated with [ExDoc](https://github.com/elixir-lang/ex_doc)
and published on [HexDocs](https://hexdocs.pm). Once published, the docs can
be found at [https://hexdocs.pm/trolleybus](https://hexdocs.pm/trolleybus).

