defmodule Trolleybus.Handler do
  @moduledoc """
  Defines a handler for events published via `Trolleybus`

  An event handler is expected to implement `handle_event/1` callback.

  ## Example

      defmodule App.Handlers.StripeHandler do
        use Trolleybus.Handler

        def handle_event(%EmailInvitedToDocument{email: email} = event) do
          ...
        end

        def handle_event(%UserInvitedToDocument{user: user, document: document) do
          ...
        end
      end

  The shape of the function head for the callback is expected to meet certain
  criteria. Each implemented clause must have one of the following shapes:

      def handle_event(%EventModule{...}) do
        ...
      end

  or:

      def handle_event(%EventModule{...} = event) do
        ...
      end

  Any other pattern in any of the clauses is going to result in raising an
  error. This restriction allows to implicitly infer a list of events
  supported by the handler, which is later used when validating handlers
  declared for the published event in `Trolleybus.Event`. This also
  enforces consistent pattern matching on exact events across
  all implemented handlers.
  """

  @callback handle_event(struct()) :: term()
  @callback __handled_events__() :: [module()]

  defmodule Error do
    defexception [:message]
  end

  defmacro __using__(_opts) do
    quote location: :keep do
      @behaviour Trolleybus.Handler

      Module.register_attribute(__MODULE__, :handler_args, accumulate: true)

      @on_definition Trolleybus.Handler
      @before_compile Trolleybus.Handler
    end
  end

  @spec __on_definition__(Macro.Env.t(), :def | :defp, atom(), list(), list(), term()) :: :ok
  def __on_definition__(env, :def, :handle_event, args, _guards, _body) do
    Module.put_attribute(env.module, :handler_args, args)

    :ok
  end

  def __on_definition__(_env, _kind, _name, _args, _guards, _body) do
    :ok
  end

  defmacro __before_compile__(env) do
    handler_args = Module.get_attribute(env.module, :handler_args, [])

    handled_events =
      handler_args
      |> Enum.map(fn
        [{:%, _, [{:__aliases__, _, alias}, {:%{}, _, _}]}] ->
          {:__aliases__, [], alias}

        [{:=, _, [{:%, _, [{:__aliases__, _, alias}, {:%{}, _, _}]}, _]}] ->
          {:__aliases__, [], alias}

        other ->
          raise Trolleybus.Handler.Error,
            message:
              "Invalid handle_event clause. Expecting struct pattern match. " <>
                "Got: #{inspect(other)}"
      end)
      |> Enum.uniq()

    quote do
      @impl true
      def __handled_events__() do
        unquote(handled_events)
      end
    end
  end
end
